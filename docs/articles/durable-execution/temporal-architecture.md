---
title: "Temporal Architecture"
section: "Durable Execution"
order: 3
---

# Temporal Architecture

## Overview

A Temporal cluster is four Go services over a pluggable persistence layer, plus a worker fleet that
*you* run. The server never executes user code — it is a state-transition and task-dispatch engine.
Understanding one request's path through the services explains the whole system.

```
                        ┌────────────────────────── Temporal Cluster ─┐
  ┌─────────┐  gRPC     │  ┌──────────┐    ┌─────────┐   ┌──────────┐ │
  │ Client  ├───────────┼─►│ Frontend │───►│ History │──►│ Matching │ │
  │ SDK     │           │  │(stateless)│   │(sharded) │  │(queues)  │ │
  └─────────┘           │  └──────────┘    └────┬────┘   └────▲─────┘ │
                        │  ┌──────────┐         │             │       │
  ┌─────────┐ long-poll │  │ Worker   │    ┌────▼─────────────┴────┐  │
  │ Your    ├───────────┼─►│ service  │    │      Persistence      │  │
  │ workers │           │  │(system   │    │ Cassandra/MySQL/PG    │  │
  └─────────┘           │  │ workflows)│   │ + Elasticsearch (vis) │  │
                        │  └──────────┘    └───────────────────────┘  │
                        └─────────────────────────────────────────────┘
```

---

## The Four Services

### Frontend

The stateless gRPC gateway. Every client and worker call lands here first. Responsibilities:
request validation, authorization, per-namespace rate limiting, and routing — it computes which
history shard owns a workflow (hash of namespace + workflow ID) and forwards to the History node
that currently owns that shard. Scales horizontally like any stateless tier; sits behind a load
balancer.

### History

The stateful core — where workflow state lives and every state transition is decided. The keyspace
is divided into a **fixed number of shards** (set at cluster creation, e.g. 512 or 4096); each
shard is owned by exactly one History node at a time, with ownership distributed via a membership
ring. Per workflow, History maintains **mutable state** (a summary record: pending activities,
timers, children) plus the append-only **event history** (source of truth). It also runs the
internal task-queue processors (transfer, timer, visibility, replication). Detailed internals:
[History Service Internals](history-service-internals.md).

Scaling History = adding nodes so shards spread across more machines. The shard count itself is
the ceiling — it cannot be changed without a cluster migration, which is a classic Temporal
operations gotcha.

### Matching

Owns **task queues** — the buffers between the server deciding "this activity should run" and a
worker actually running it. Handles worker long-polls, dispatches tasks (with a sync-match fast
path that skips persistence when a worker is already waiting), manages queue partitions and sticky
queues. Details: [Matching Service and Task Queues](matching-service-task-queues.md).

### Worker Service

Not your workers — an internal service running *system* workflows: archival, batch operations
(e.g. batch terminate), cross-cluster replication bookkeeping, and the implementation behind
schedules. It's a consumer of the same machinery user workflows use, which is a nice dogfooding
story: Temporal features are built as Temporal workflows.

---

## Persistence Layer

Two separate stores with different jobs:

| Store | Backends | Holds |
|---|---|---|
| **Core persistence** | Cassandra, MySQL, PostgreSQL | Event histories, mutable state, internal task queues, matching task backlogs, shard metadata, namespace config |
| **Visibility** | Elasticsearch (advanced), or SQL (basic) | Searchable index of executions: status, type, custom search attributes |

Why visibility is separate: core persistence is optimized for point lookups and conditional writes
on a single workflow (get/update by shard + workflow ID). "List all failed `order-*` workflows
started last week where `customerTier=gold`" is a search problem — wrong shape for Cassandra
entirely, and a load profile you don't want competing with state transitions. So History emits
visibility tasks that asynchronously upsert an execution record into Elasticsearch; the list/search
APIs read only from there. Consequence worth knowing: visibility is eventually consistent with core
state.

Cassandra vs. SQL trade-off: Cassandra scales writes linearly and matches the shard model
naturally, but conditional updates use LWT (Paxos rounds — expensive). Postgres/MySQL are far
simpler to operate and fine into surprisingly high throughput, with a vertical ceiling. See
[Distributed Systems Foundations](distributed-systems-foundations.md#persistence-trade-offs).

---

## Life of a Workflow

Trace `StartWorkflowExecution` end to end — this is the single best mental model to carry into a
Temporal interview:

```
Client                Frontend        History(shard N)      Matching           Worker
  │ Start(wf-id, input) │                  │                   │                 │
  ├────────────────────►│ hash(ns,wf-id)=N │                   │                 │
  │                     ├─────────────────►│ 1. append event   │                 │
  │                     │                  │    WFExecStarted  │                 │
  │                     │                  │ 2. write mutable  │                 │
  │                     │                  │    state + xfer   │                 │
  │                     │                  │    task (1 txn)   │                 │
  │  run-id             │◄─────────────────┤                   │                 │
  │◄────────────────────┤                  │ 3. xfer processor │                 │
  │                     │                  │    reads task ────► add WF task     │
  │                     │                  │                   │ 4. sync-match ──► (parked
  │                     │                  │                   │    or persist   │  long-poll)
  │                     │                  │                   │                 │ 5. replay/run
  │                     │                  │                   │                 │    wf code →
  │                     │ RespondWorkflowTaskCompleted(commands: schedule        │    commands
  │                     │◄────────────────────────────────────────────────────── ┤
  │                     ├─────────────────►│ 6. validate cmds, │                 │
  │                     │                  │    append events, │                 │
  │                     │                  │    write activity │                 │
  │                     │                  │    xfer tasks (txn)                 │
  │                     │                  │    ... loop ...   │                 │
```

Key beats:

1. **Frontend routes by shard** — deterministic hash, no lookup service needed for the mapping
   (only for which node owns the shard).
2. **History does an atomic write**: the started event, mutable state, and a *transfer task*
   ("a workflow task needs to go to queue Q") in one transaction. This is the transactional-outbox
   pattern — the task cannot be lost, and cannot exist without the state that spawned it.
3. **Transfer processor** on the shard pushes the task to Matching.
4. **Matching dispatches** to a long-polling worker — directly (sync match) if one is parked,
   otherwise persisting to the backlog.
5. **The worker runs workflow code** (replaying history first if it doesn't have the workflow
   cached) and returns a batch of **commands**: schedule these activities, start this timer,
   complete the workflow.
6. **History validates and applies** the commands as new events + new tasks, again atomically.
   Loop until a command completes the workflow.

Every arrow in this diagram is at-least-once with retries; every state transition is guarded by a
conditional write, which is how the loop stays effectively-once. Activity execution follows the
same shape (activity task → matching → worker → `RespondActivityTaskCompleted` → History appends
`ActivityTaskCompleted` → new workflow task so the workflow can react).

---

## Workers Are Yours, Not Theirs

The deployment model people most often get wrong: **Temporal Server never runs user code.**
Workflows and activities execute in worker processes you build with the SDK and deploy yourself —
your containers, your VPC, your secrets. Workers connect *outbound* to the cluster and long-poll
task queues; the server never connects to workers.

Consequences:

- **Security story**: code, credentials, and data-plane traffic stay in your environment; Temporal
  Cloud only ever sees workflow inputs/results and event histories (which can be client-side
  encrypted via a codec). No inbound firewall holes.
- **Scaling story**: server capacity (state transitions/sec) and execution capacity (your worker
  count) scale independently. A backlogged task queue is fixed by adding *your* pods, not by
  scaling Temporal.
- **Polyglot story**: any SDK language can host workers; different task queues can be served by
  different services/teams/languages.
- **Tuning**: workers have slot limits (concurrent workflow tasks / activities). Resource-based
  **auto-tuning** (GA 2025) sizes slots from actual CPU/memory pressure instead of hand-set
  constants. The key health metric is **schedule-to-start latency** — time tasks sit in the queue
  before a worker picks them up; sustained growth means the fleet is undersized.

---

## Interview Angle

- Be able to **draw the four services and trace a start-to-completion request** unprompted — this
  is table stakes for a Temporal loop and a strong artifact in any workflow-engine design round.
- **Name the atomic write** (events + mutable state + internal tasks in one transaction) as the
  mechanism behind reliability — it's the transactional outbox, and identifying it by name signals
  pattern literacy.
- **Explain why workers are client-side** from both the security and scale angles.
- Know the operational sharp edges: fixed shard count, visibility eventual consistency,
  schedule-to-start latency as the fleet-sizing signal.
