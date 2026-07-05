---
title: "History Service Internals"
section: "Durable Execution"
order: 4
---

# History Service Internals

## Overview

The history service is where Temporal's hard distributed-systems work lives: an event-sourced,
sharded, single-writer-per-workflow state machine. Every reliability guarantee the platform makes
traces back to one of four mechanisms in this service — shard ownership, mutable state with
conditional writes, the transactional outbox of internal task queues, and shard-local timer
processing.

---

## History Shards

The workflow keyspace is statically partitioned:

```
shard = hash(namespace_id, workflow_id) % num_shards
```

- **Shard count is fixed at cluster creation** and stored in persistence. It cannot be changed
  in place — resharding means standing up a new cluster and migrating (via multi-cluster
  replication). Sizing it is a genuine capacity-planning decision: too few shards caps parallelism
  (each shard's transitions are serialized); too many adds per-shard overhead. Production clusters
  run hundreds to thousands.
- **Each shard is owned by exactly one History node at a time.** The **ShardController** on each
  node acquires and releases shards as membership changes, using a **Ringpop** (consistent-hash
  ring, SWIM gossip membership) view of live History nodes: shard → ring position → owning node.
- **Ownership is fenced by a range ID**: each time a shard is acquired, the node bumps a
  `range_id` in the shard's persistence record; every subsequent write for that shard is
  conditional on the range ID still matching. A stale owner (network partition, slow rebalance —
  two nodes both believing they own the shard) fails its writes at the database. Membership gossip
  is an *optimization* for routing; **correctness comes from the conditional writes**, not from
  the ring.

What rebalancing does to in-flight work: when a node dies or joins, its shards move; the new owner
reloads shard state and resumes task-queue processing from persisted ack levels. In-flight
transitions on the old owner fail their conditional writes and are retried by callers against the
new owner. Result: shard movement causes latency blips, never lost or duplicated state
transitions.

---

## Mutable State + Event History

Per workflow execution, two representations, one truth:

| | Event history | Mutable state |
|---|---|---|
| Shape | Append-only log of events | Single row/record, updated in place |
| Role | **Source of truth** | Materialized summary / cache |
| Contents | Every state transition ever | Pending activities, timers, child workflows, signal/update bookkeeping, next event ID, version histories |
| Used for | Worker replay, audit, debugging | Fast server-side decisions without reading history |

Mutable state exists so History can answer "is activity X still pending? has this request ID been
seen? what's the next event ID?" without scanning the log on every transition. It is rebuildable
from history (and that's exactly what conflict resolution and some recovery paths do). Hot
workflows' mutable state is kept in an in-memory per-shard cache, making the common transition
path: read cache → validate → append events + update mutable state in one conditional transaction.

**Single-writer per workflow** falls out of the layering: a workflow maps to one shard, one shard
has one owner, and the owner's writes are fenced. On Cassandra the conditional write is a
lightweight transaction (LWT, Paxos per partition); on SQL it's optimistic concurrency
(`UPDATE ... WHERE range_id = ? AND next_event_id = ?`). Either way, two racing writers cannot
both commit — the loser gets a condition failure and must re-read and retry.

---

## Internal Task Queues and the Transactional Outbox

A state transition rarely ends with "write the event" — something must *happen next*: dispatch a
workflow task, fire a timer, index visibility, replicate to another cluster. History models each
as an internal task, in four shard-local queues:

| Queue | Carries |
|---|---|
| **Transfer** | "Push this workflow/activity task to Matching", start child workflow, etc. — transitions crossing service boundaries |
| **Timer** | Durable timers, activity/workflow timeout enforcement, retry backoff firings |
| **Visibility** | Upserts to the visibility store (Elasticsearch) |
| **Replication** | History event batches for cross-cluster replication |

The crucial property: **tasks are written in the same transaction as the events and mutable
state**. This is the transactional-outbox pattern — there is no window where state says "activity
scheduled" but no task exists to dispatch it, and no task can exist for state that failed to
commit.

Each shard runs **queue processors** that read tasks in order, execute them (e.g., RPC to
Matching), and advance a persisted **ack level** (watermark). Processing is at-least-once — a
crash between executing a task and persisting the ack means redelivery — so every task's effect
must be idempotent or deduplicated downstream (Matching dedupes task IDs; visibility upserts are
naturally idempotent; replication applies by event ID). The composition — atomic task creation +
at-least-once processing + idempotent effects — is how Temporal gets **effectively-once
side-effect orchestration without distributed transactions across services**.

---

## Timers at Scale

"Millions of durable timers" sounds like a scan-the-world problem; the shard model dissolves it:

- A timer is just a **timer task with a fire timestamp**, written to the shard's timer queue in
  the same transaction as the `TimerStarted` event.
- Each shard's **timer queue processor** reads its own queue ordered by fire time — effectively a
  persisted per-shard priority queue. It needs only the head: sleep until the nearest deadline,
  wake, fire due tasks (each firing = a conditional state transition appending `TimerFired` + a
  transfer task to schedule a workflow task), advance the ack level.
- Load is spread across all shards automatically, because timers live with their workflow's
  shard. No global timer service, no fleet-wide scan; adding History nodes adds timer throughput.
- The same machinery drives **timeouts and retry backoff** — an activity's start-to-close timeout
  is a timer task racing the completion; whichever transition commits first wins, and the loser's
  conditional write fails harmlessly.

---

## Interview Angle

This article is deep-dive ammunition — the follow-ups after you draw the
[four-service architecture](temporal-architecture.md):

- **"How do you guarantee only one node processes a workflow?"** — shard hashing gives locality;
  Ringpop gives routing; but *fencing via range-ID conditional writes* gives correctness. Saying
  "the ring is an optimization, the database condition is the guarantee" is the senior answer.
- **"How do you avoid distributed transactions between History and Matching?"** — transactional
  outbox: task written atomically with state, delivered at-least-once, deduped downstream.
- **"How do timers scale?"** — per-shard persisted priority queues; timers colocated with workflow
  state; no global scanner.
- **"What limits throughput?"** — per-workflow: serialized conditional writes (a single hot
  workflow caps at low tens of transitions/sec — by design). Cluster-wide: shard count × per-shard
  throughput, then the persistence layer. This maps directly onto "why is workflow ID choice a
  design decision" in system-design rounds.
