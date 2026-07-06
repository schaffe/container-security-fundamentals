---
title: "Temporal Architecture"
section: "Durable Execution"
order: 3
---

# Temporal Architecture

## Overview

A Temporal cluster is four Go services sitting on top of a pluggable persistence layer, plus a
fleet of worker processes that *you* run. That last clause is the single most important fact about
the architecture, so it bears stating immediately: the Temporal server never executes user code.
It is a state-transition and task-dispatch engine; your workflows and activities run in your own
processes, which connect out to the cluster and ask it for work.

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

The best way to understand this diagram is to trace one request through it, which the second half
of this article does. First, what each box is for.

---

## The Four Services

### Frontend

The Frontend is the stateless gRPC gateway — every call from a client or a worker lands here
first. It validates requests, enforces authorization and per-namespace rate limits, and routes:
given a workflow ID, it computes which history shard owns that workflow (a hash of the namespace
and workflow ID) and forwards the request to whichever History node currently owns that shard.
Being stateless, it scales horizontally behind a load balancer like any API tier.

### History

History is the stateful core — the service where workflow state lives and where every state
transition is decided. Its keyspace is divided into a **fixed number of shards**, set at cluster
creation (512 and 4096 are common choices), and each shard is owned by exactly one History node at
a time, with ownership distributed across nodes via a membership ring.

For each workflow execution, History maintains two things: the append-only **event history**,
which is the source of truth, and **mutable state**, a compact summary record (pending activities,
open timers, child workflows) that lets the server make decisions without re-reading the whole
log. History also runs the internal task-queue processors — transfer, timer, visibility, and
replication queues — which are covered in depth in
[History Service Internals](history-service-internals.md).

Scaling History means adding nodes so the shards spread across more machines. But note the
ceiling: the shard count itself is fixed and cannot be changed in place — raising it means
standing up a new cluster and migrating. This is a classic Temporal operational gotcha and worth
volunteering in any capacity-planning discussion.

### Matching

Matching owns **task queues** — the buffers between the server deciding "this activity should run"
and one of your workers actually running it. It handles worker long-polls, dispatches tasks, and
manages queue partitioning and sticky queues. Its signature trick, the *sync-match* fast path,
hands a task directly to a waiting worker without ever writing it to the database — the subject of
[its own article](matching-service-task-queues.md).

### Worker Service

Confusingly named: this is *not* your workers. It's an internal service that runs *system*
workflows — history archival, batch operations like mass-terminate, replication bookkeeping, and
the machinery behind Schedules. It consumes exactly the same workflow machinery your code does,
which is a tidy dogfooding story: Temporal's own features are built as Temporal workflows.

---

## The Persistence Layer

Temporal uses two separate stores with deliberately different jobs.

**Core persistence** (Cassandra, MySQL, or PostgreSQL) holds everything the system's correctness
depends on: event histories, mutable state, the internal task queues, matching's task backlogs,
shard metadata, and namespace configuration.

**Visibility** (Elasticsearch for the full feature set, or SQL for basic setups) holds a
searchable index of executions — status, type, timestamps, and custom search attributes.

Why two stores? Because the two workloads have opposite shapes. Core persistence is all point
lookups and conditional writes against a single workflow: fetch by shard and workflow ID, update
if the expected version matches. A query like "list all failed `order-*` workflows started last
week where `customerTier=gold`" is a search problem — the wrong shape for Cassandra entirely, and
a load profile you do not want competing with state transitions on the same store. So History
emits visibility tasks that asynchronously upsert an execution record into Elasticsearch, and the
list/search APIs read only from there.

The consequence worth carrying into interviews: **visibility is eventually consistent** with core
state. A workflow can be closed for a few seconds before a list query shows it closed. State reads
by ID are strongly consistent; search is not; and that split is a design decision, not a bug.

As for choosing a core store: Cassandra scales writes linearly with nodes and matches the shard
model naturally, but its conditional writes use lightweight transactions — a Paxos round per write,
which is expensive. Postgres and MySQL are far simpler to operate and handle surprisingly high
throughput, but scale vertically until you hit a single-primary ceiling. The full trade-off
discussion lives in [Distributed Systems Foundations](distributed-systems-foundations.md#persistence-trade-offs).

---

## Life of a Workflow

Now the payoff: tracing `StartWorkflowExecution` end to end. This is the single best mental model
to carry into a Temporal interview, because almost every deep-dive question is a question about
one arrow in this diagram.

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

Walking through the beats:

**The Frontend routes by shard.** It hashes the namespace and workflow ID to a shard number —
a pure function, no lookup service needed for the mapping itself, only for finding which node
currently owns that shard.

**History performs one atomic write.** In a single database transaction it appends the
`WorkflowExecutionStarted` event, writes the initial mutable state, and writes a *transfer task* —
an internal record saying "a workflow task needs to go to queue Q." This is the
**transactional outbox** pattern, and it's the crux of the whole system's reliability: because the
task is created in the same transaction as the state, there is no window where the state says
"task scheduled" but no task exists, and no task can exist for state that failed to commit.

**The transfer processor pushes the task to Matching.** A background processor on the shard reads
the transfer task and delivers it, at-least-once, to the Matching service.

**Matching dispatches to a worker.** If a worker's long-poll is already parked and waiting — the
healthy steady state — Matching hands the task straight through without persisting it (sync
match). Otherwise the task is written to the backlog and delivered when a poller shows up.

**The worker runs workflow code.** If it doesn't have this workflow's state cached, it fetches the
event history and replays first. Then it executes the code forward and returns not side effects
but a batch of **commands**: schedule these activities, start this timer, complete the workflow.

**History validates and applies the commands** — appending new events and writing new internal
tasks, again in one transaction. The loop repeats until some command completes the workflow.

Two properties of this loop deserve emphasis. Every arrow in the diagram is at-least-once, with
retries. And yet every state transition is guarded by a conditional write, so duplicated or stale
attempts fail harmlessly at the database — which is how a system built entirely from at-least-once
parts produces effectively-once outcomes. Activity execution, by the way, follows exactly the same
shape: activity task through Matching to a worker, `RespondActivityTaskCompleted` back to History,
which appends `ActivityTaskCompleted` and schedules a new workflow task so the workflow can react.

---

## Workers Are Yours, Not Theirs

The part of the deployment model people most often get wrong deserves its own section: **the
Temporal server never runs user code**. Workflows and activities execute inside worker processes
that you build with an SDK and deploy yourself — your containers, your VPC, your secrets. Workers
connect *outbound* to the cluster and long-poll for tasks; the server never opens a connection to
a worker.

This one design choice generates several stories at once.

The **security story**: your code, credentials, and data-plane traffic never leave your
environment. Temporal Cloud sees only workflow inputs, results, and event histories — and even
those can be client-side encrypted with a payload codec, so the cloud stores ciphertext. No
inbound firewall holes, ever.

The **scaling story**: server capacity (state transitions per second) and execution capacity (how
many workers you run) scale independently. If a task queue is backlogged, the fix is adding *your*
pods — the cluster is fine.

The **polyglot story**: any SDK language can host workers, and different task queues can be served
by different services, teams, and languages within one cluster.

Operationally, workers have **slot limits** — caps on concurrently executing workflow tasks and
activities — and since 2025 a resource-based auto-tuner can size those slots from observed CPU and
memory pressure rather than hand-set constants. The health metric to watch is
**schedule-to-start latency**: how long tasks sit in a queue before a worker picks them up.
Near-zero means workers are keeping up; sustained growth means the fleet is undersized.

---

## Interview Angle

- Be able to **draw the four services and trace a start-to-completion request** unprompted. This
  is table stakes in a Temporal loop and a strong artifact in any workflow-engine design round.
- **Name the atomic write** — events, mutable state, and internal tasks in one transaction — as
  the mechanism behind reliability. Identifying it as the transactional outbox pattern signals
  pattern literacy.
- **Explain why workers are client-side** from both the security angle and the
  independent-scaling angle.
- Know the operational sharp edges: the fixed shard count, visibility's eventual consistency, and
  schedule-to-start latency as the fleet-sizing signal.
