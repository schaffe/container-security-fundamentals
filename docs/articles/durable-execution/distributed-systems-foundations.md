---
title: "Distributed Systems Foundations"
section: "Durable Execution"
order: 6
---

# Distributed Systems Foundations

## Overview

The distributed-systems vocabulary a Temporal interview assumes — delivery guarantees, idempotency,
event sourcing, sharding, coordination — mapped onto where Temporal actually uses each concept.
Learning the concepts through a system that exercises all of them beats memorizing definitions:
every abstraction here has a concrete "and this is where it lives in Temporal" anchor.

---

## At-Least-Once, At-Most-Once, "Exactly-Once"

For message delivery between two parties over a lossy network, only two primitives exist:

- **At-most-once** — send, don't retry. Failures lose messages.
- **At-least-once** — retry until acknowledged. Failures duplicate messages (the ack, not the
  delivery, is what gets lost — the receiver may have processed it already).

**Exactly-once *delivery* is impossible** (the sender cannot distinguish "receiver never got it"
from "receiver processed it and the ack was lost" — a corollary of the Two Generals problem). What
*is* achievable is **exactly-once processing** (a.k.a. effectively-once): deliver at-least-once,
then make duplicate deliveries harmless via deduplication or idempotency at the receiver.

Where Temporal gives which guarantee:

| Layer | Guarantee | Mechanism |
|---|---|---|
| Workflow state transitions | Effectively-once | Every transition is a conditional write against event history; duplicates/stale attempts fail the condition |
| Internal task processing (transfer/timer/…) | At-least-once execution, effectively-once outcome | [Transactional outbox](history-service-internals.md#internal-task-queues-and-the-transactional-outbox) + idempotent/deduped task effects |
| Task dispatch to workers | At-least-once | Redelivery on timeout; completion validated against current state |
| **Activity execution** | **At-least-once** | Server retries; *your* code must tolerate re-execution |
| Signal delivery | Effectively-once (deduped by request ID) | Recorded in history exactly once |

The last row people get wrong in interviews: Temporal does **not** make your side effects
exactly-once. It makes its *own* state exactly-once and hands you at-least-once activity
execution; closing the gap is your job, via idempotency.

## Idempotency and Dedup

An operation is idempotent if performing it twice has the same effect as once. The standard tools:

- **Idempotency keys** — the caller supplies a unique key per logical operation; the receiver
  stores key → result and returns the stored result on replays. In Temporal activities, derive
  the key from stable identity: `workflow_id + activity_id` (or a business key from the input) —
  *not* a random UUID generated inside the activity, which changes on retry and defeats the
  purpose.
- **Natural idempotency** — upserts, absolute writes (`SET balance = 100` vs `ADD 10`),
  create-if-not-exists.
- **Dedup at the boundary** — Temporal itself dedupes `StartWorkflowExecution` by **request ID**
  (client retries of the same start don't create two executions) and by **workflow ID**: at most
  one open execution per ID per namespace, with a reuse policy controlling whether a completed
  ID can be reused (allow duplicate / allow only if failed / reject). Workflow ID = business key
  (e.g. `order-4711`) is the idiom — it turns the uniqueness constraint into a free distributed
  lock.

---

## Event Sourcing and CQRS

**Event sourcing**: persist the sequence of state-changing events as the source of truth; current
state is a fold (reduction) over the log. Temporal's event history is a textbook implementation,
with [deterministic replay](durable-execution-fundamentals.md#the-core-mechanism-event-sourcing-deterministic-replay)
as the fold — and the workflow *code* as the fold function.

**CQRS** (Command Query Responsibility Segregation): separate the write path from the read path,
letting each use a representation optimized for its job. Temporal implements it twice:

- **Mutable state** is a write-side projection of history — a summary the server maintains so
  transitions don't re-read the log ([details](history-service-internals.md#mutable-state-event-history)).
- **Visibility** is a read-side projection — executions asynchronously indexed into Elasticsearch
  for list/search queries, eventually consistent with core state
  ([details](temporal-architecture.md#persistence-layer)).

Contrast with classic app-level event sourcing: there, *you* design events, projections, and
schema evolution. Temporal internalizes all of it — events are SDK-defined protocol events, the
projection is replay. You get event sourcing's guarantees without designing an event schema; you
give up direct control of the log's contents.

---

## Sharding and Coordination Without Consensus

**Hash vs. range sharding**: hash sharding (Temporal: `hash(namespace, workflow_id) % N`)
distributes load uniformly and needs no directory, but loses locality and makes resharding hard —
which is exactly Temporal's trade: uniform distribution, fixed shard count, no range scans needed
(all access is point-lookup by workflow ID). Range sharding (HBase, CockroachDB, Spanner) preserves
locality for scans and splits dynamically, at the cost of hot-range management.

The more interesting design decision: **Temporal runs no consensus protocol of its own.** No Raft
group per shard, no Paxos in the History service. Instead:

1. **Membership + routing** via Ringpop (SWIM gossip + consistent hashing) — determines who
   *should* own each shard. Gossip is eventually consistent and can be briefly wrong.
2. **Correctness** via **fencing tokens + conditional writes at the database**: shard ownership
   carries a monotonically increasing `range_id`; every write is conditional on it. A stale owner's
   writes fail atomically. (This is Lamport's fencing-token pattern — the same one that fixes
   naive distributed locks.)

Consensus does exist in the stack — *delegated to the persistence layer*: Cassandra LWT runs Paxos
per partition; an RDBMS serializes via its transaction machinery (and its own HA replication).
The layering is the lesson: **routing can be sloppy if writes are fenced; push agreement down to
one place that already does it well.** Compare Kafka (Raft/ZooKeeper for partition leadership) or
CockroachDB (Raft per range), which own consensus themselves — different placement of the same
responsibility.

---

## Persistence Trade-offs

Temporal's persistence is pluggable, and the choice is a classic interview discussion:

| | Cassandra | MySQL / PostgreSQL |
|---|---|---|
| Write scaling | Horizontal, linear with nodes — matches the shard model | Vertical (single primary), then app-level sharding pain |
| Conditional writes | LWT = Paxos round per write — correct but costly (multiple round trips) | Native transactions / optimistic concurrency — cheap |
| Operations | A distributed system of its own: compactions, repairs, tombstones | Boring, well-understood, managed offerings everywhere |
| Fit | Large clusters, very high transition rates | Most deployments below that scale |

The meta-point: Temporal pays LWT costs to buy linear scale; **DBOS bets the exact opposite** —
that one Postgres instance (transactions are free, ops are boring) covers the majority of real
workloads, and durable execution should be a library over it rather than a service cluster.
Neither is wrong; they target different points on the scale/operability curve. Being able to argue
both sides, with the crossover criteria (sustained state-transitions/sec, multi-region needs, team
ops capacity), is senior-interview material.

---

## Interview Angle

- **"Exactly-once" is a trap phrase** — immediately split it: delivery (impossible) vs. processing
  (achievable via at-least-once + idempotency). Then place Temporal's guarantees on that map,
  ending with "activities are at-least-once, so idempotency is the developer's contract."
- **Fencing tokens** — the Temporal shard `range_id` is the cleanest production example of the
  pattern; it also answers "how do you handle split-brain without consensus?"
- **Event sourcing + CQRS** — be ready to point at three projections of one log (replay for
  workers, mutable state for the server, visibility for search) — it shows the concepts as tools
  rather than buzzwords.
- **Trade-off fluency** — hash vs. range sharding, Cassandra vs. Postgres, consensus-in-the-store
  vs. consensus-in-the-service: each has a "Temporal chose X because Y; the opposite choice is
  right when Z" answer.
