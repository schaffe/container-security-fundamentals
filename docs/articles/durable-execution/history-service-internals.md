---
title: "History Service Internals"
section: "Durable Execution"
order: 4
---

# History Service Internals

## Overview

The history service is where Temporal's hard distributed-systems work lives. Strip away the
surface and it is an event-sourced, sharded state machine with exactly one writer per workflow —
and every reliability guarantee the platform makes traces back to one of four mechanisms inside
it: shard ownership with fencing, mutable state guarded by conditional writes, internal task
queues used as a transactional outbox, and shard-local timer processing. This article takes the
four in turn. If [the architecture article](temporal-architecture.md) is the map, this is the
terrain — the material for the deep-dive follow-ups.

---

## History Shards

The workflow keyspace is partitioned statically, by pure arithmetic:

```
shard = hash(namespace_id, workflow_id) % num_shards
```

The shard count is **fixed at cluster creation** and stored in persistence; it cannot be changed
in place. Resharding a live cluster means standing up a new one and migrating via multi-cluster
replication — a genuinely painful operation, which makes the initial choice a real
capacity-planning decision. Too few shards caps parallelism, because each shard's transitions are
processed serially; too many adds per-shard overhead. Production clusters typically run hundreds
to thousands.

Each shard is owned by **exactly one History node at a time**. A component called the
ShardController on every node acquires and releases shards as cluster membership changes, using
Ringpop — a consistent-hash ring built on SWIM gossip — to agree (loosely) on which node should
own what: shard number maps to a ring position, ring position maps to a node.

But gossip is eventually consistent, and "loosely agree" is doing real work in that sentence.
During a network partition or a slow rebalance, two nodes can *both* believe they own the same
shard. Temporal's answer is not a stronger coordination protocol — it's **fencing**. Every time a
node acquires a shard, it increments a `range_id` in the shard's persistence record, and every
subsequent write for that shard is conditional on the `range_id` still matching. A stale owner's
writes simply fail at the database. This division of labor is the key insight of the whole design:
the membership ring is an *optimization* that makes routing usually correct; the conditional write
is what makes the system *actually* correct.

What does a rebalance do to in-flight work? When a node dies or a new one joins, shards move. The
new owner reloads shard state from persistence and resumes processing from persisted ack levels
(watermarks — more on those below). Any transition that was in flight on the old owner fails its
conditional write and is retried by its caller against the new owner. The observable result is a
latency blip during shard movement — never a lost or duplicated state transition.

---

## Mutable State and Event History

For every workflow execution, History maintains two representations of one truth.

The **event history** is the append-only log of everything that has ever happened to the workflow
— the source of truth, the thing workers replay, the audit trail.

**Mutable state** is a single record, updated in place, that summarizes the parts of that history
the server needs constantly: which activities are pending, which timers are open, which child
workflows exist, which request IDs have been seen, what the next event ID is. It exists purely so
that History can answer questions like "is activity X still pending?" without scanning the log on
every transition — it is a materialized cache, rebuildable from history whenever needed (and
conflict resolution and certain recovery paths do exactly that rebuild).

For hot workflows, mutable state is additionally cached in memory, per shard. So the common
transition path is: read the cached mutable state, validate the incoming completion or command
against it, then append the new events and update mutable state **in one conditional
transaction**.

That conditional transaction is where "single writer per workflow" becomes real rather than
aspirational. The layering goes: a workflow maps to one shard; a shard has one owner; and the
owner's writes are fenced by the `range_id`. On Cassandra the conditional write is a lightweight
transaction — Paxos per partition; on SQL it's optimistic concurrency, an
`UPDATE ... WHERE range_id = ? AND next_event_id = ?`. Either way, if two writers race, exactly
one commits; the loser gets a condition failure, re-reads the current state, and retries against
reality.

---

## Internal Task Queues and the Transactional Outbox

A state transition almost never ends with "write the event." Something must *happen next*: a
workflow task must be dispatched to Matching, a timer must fire later, the visibility index must
be updated, events must replicate to another cluster. History models each of these follow-on
actions as an internal task, organized into four shard-local queues:

| Queue | What it carries |
|---|---|
| **Transfer** | "Push this workflow/activity task to Matching," "start this child workflow" — any transition that crosses a service boundary |
| **Timer** | Durable timers, activity and workflow timeout enforcement, retry backoff firings |
| **Visibility** | Upserts to the visibility store (Elasticsearch) |
| **Replication** | Batches of history events bound for other clusters |

Here is the property everything hinges on: **internal tasks are written in the same database
transaction as the events and mutable state that imply them**. This is the transactional outbox
pattern. There is no moment in any failure schedule where the state says "activity scheduled" but
no task exists to dispatch it — and no task can exist for a transition that failed to commit. The
classic dual-write problem (update the database, then tell the queue, and pray you don't crash
in between) is closed structurally, without a distributed transaction across services.

Delivery is the other half. Each shard runs **queue processors** that read their queue's tasks in
order, execute them (for a transfer task, an RPC to Matching), and then advance a persisted
**ack level** — a watermark recording "everything before here is done." Processing is
at-least-once: crash after executing a task but before persisting the ack, and the task is
redelivered on recovery. So every task's *effect* must be idempotent or deduplicated downstream —
and each one is: Matching dedupes on task IDs, visibility upserts are naturally idempotent, and
replication applies events by ID.

Step back and look at the composition, because it's the answer to a whole family of interview
questions: atomic task creation (outbox) + at-least-once delivery (queue processors) + idempotent
effects (downstream dedup) = **effectively-once orchestration of side effects, with no distributed
transactions anywhere**.

---

## Timers at Scale

"Support millions of durable timers" sounds like it demands some global scanning service —
something that periodically asks "which timers in the whole system are due?" The shard model
dissolves the problem instead.

A timer is just a **timer task with a fire timestamp**, written to its shard's timer queue — in
the same transaction as the `TimerStarted` event, per the outbox pattern above. Each shard's timer
queue processor reads its own queue ordered by fire time, which makes the queue a persisted
per-shard priority queue. The processor only ever needs the head: sleep until the nearest
deadline, wake, fire whatever is due, advance the ack level. Firing a timer is itself a normal
conditional state transition — append `TimerFired`, write a transfer task so a workflow task gets
scheduled.

Because timers live with their workflow's shard, load spreads across all shards automatically, and
adding History nodes adds timer throughput. No global timer service, no fleet-wide scan, nothing
special to keep alive.

The same machinery quietly drives **timeouts and retry backoff**. An activity's start-to-close
timeout is just a timer task racing the activity's completion: whichever transition commits first
wins, and the loser's conditional write fails harmlessly. Elegant — one mechanism, three features.

---

## Interview Angle

This article is deep-dive ammunition — the follow-up answers for after you've drawn the
[four-service architecture](temporal-architecture.md).

- **"How do you guarantee only one node processes a given workflow?"** Shard hashing gives
  locality, the ring gives routing, but *fencing via range-ID conditional writes* gives
  correctness. The senior phrasing: "the ring is an optimization; the database condition is the
  guarantee."
- **"How do you avoid distributed transactions between History and Matching?"** The transactional
  outbox: the task is written atomically with the state, delivered at-least-once, deduplicated
  downstream.
- **"How do millions of timers scale?"** Per-shard persisted priority queues, colocated with
  workflow state. No global scanner exists, so there's nothing to bottleneck.
- **"What limits throughput?"** Per workflow: serialized conditional writes — a single hot
  workflow tops out at low tens of transitions per second, *by design*, because serialization is
  what keeps its log coherent. Cluster-wide: shard count times per-shard throughput, and
  eventually the persistence layer. This maps directly onto "why is workflow ID choice a design
  decision" in system-design rounds.
