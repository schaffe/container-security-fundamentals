---
title: "Distributed Systems Foundations"
section: "Durable Execution"
order: 6
---

# Distributed Systems Foundations

## Overview

A Temporal interview assumes a distributed-systems vocabulary: delivery guarantees, idempotency,
event sourcing, sharding, coordination. You could learn these from a textbook, but there's a
better way — learn them through a single system that exercises all of them. Every concept in this
article comes with a concrete "and here is where it lives in Temporal" anchor, which is worth far
more in an interview than a memorized definition, because it proves you've seen the concept doing
work.

---

## At-Least-Once, At-Most-Once, and the Myth of Exactly-Once

Start with the most misused phrase in distributed systems.

When one party sends a message to another over a network that can lose packets, there are exactly
two delivery strategies available. You can send once and never retry — **at-most-once** — in which
case a lost message stays lost. Or you can retry until you receive an acknowledgment —
**at-least-once** — in which case you risk duplicates. The duplicate case is worth understanding
precisely: it's usually not the message that gets lost, but the *acknowledgment*. The receiver
processed the message, sent an ack, the ack vanished, and now the sender retries something that
already happened.

Could a sender ever be smart enough to avoid both failure modes? No — and this is a theorem, not
an engineering gap. The sender fundamentally cannot distinguish "the receiver never got my
message" from "the receiver processed it and the ack was lost." (This is a corollary of the Two
Generals problem.) **Exactly-once *delivery* is impossible.**

What *is* achievable is **exactly-once processing**, sometimes called effectively-once: deliver
at-least-once, then make the duplicates harmless — the receiver deduplicates, or the operation is
idempotent so running it twice equals running it once. Every system that claims "exactly-once" is
doing some version of this, and knowing that lets you ask the right question of any such claim:
*where does the dedup happen?*

Here is where Temporal lands on that map, layer by layer:

| Layer | Guarantee | How |
|---|---|---|
| Workflow state transitions | Effectively-once | Every transition is a conditional write against event history; duplicates and stale attempts fail the condition |
| Internal task processing | At-least-once execution, effectively-once outcome | [Transactional outbox](history-service-internals.md#internal-task-queues-and-the-transactional-outbox) plus idempotent, deduplicated task effects |
| Task dispatch to workers | At-least-once | Redelivery on timeout; completions validated against current state |
| **Activity execution** | **At-least-once** | The server retries; *your* code must tolerate re-execution |
| Signal delivery | Effectively-once | Deduplicated by request ID; recorded in history exactly once |

The row people get wrong in interviews is the bolded one. Temporal does **not** make your side
effects exactly-once — it cannot, per the theorem above. It makes its *own* state effectively-once
and hands you at-least-once activity execution. Closing that last gap is the application
developer's job, and the tool for the job is idempotency.

## Idempotency and Dedup

An operation is **idempotent** if performing it twice has the same effect as performing it once.
Since at-least-once delivery is what the world gives you, idempotency is how you build
exactly-once processing on top of it. The standard toolkit:

**Idempotency keys.** The caller attaches a unique key to each logical operation; the receiver
remembers which keys it has processed (key → result) and, on seeing a repeat, returns the stored
result instead of re-executing. The subtlety is where the key comes from. In a Temporal activity,
derive it from *stable identity* — the workflow ID plus the activity's identity, or a business key
from the input. A random UUID generated *inside* the activity is the classic bug: it changes on
every retry attempt, so every retry looks like a fresh operation and the dedup never triggers.

**Natural idempotency.** Some operations are idempotent by construction: upserts,
create-if-not-exists, and absolute writes. `SET balance = 100` can run five times harmlessly;
`ADD 10` cannot. Where you control the operation's shape, prefer the absolute form.

**Dedup at the boundary.** Temporal practices what it preaches at its own front door.
`StartWorkflowExecution` is deduplicated by **request ID**, so a client that retries the same
start call doesn't create two executions. And it's deduplicated by **workflow ID**: at most one
open execution per ID per namespace, with a configurable reuse policy for completed IDs (allow
reuse, allow only after failure, reject outright). This is why the idiom is to make the workflow
ID a business key — `order-4711` — which turns the uniqueness constraint into a free distributed
lock: two racing attempts to process order 4711 collapse into one execution, structurally.

---

## Event Sourcing and CQRS

**Event sourcing** means persisting the sequence of state-changing events as the source of truth,
and deriving current state by *folding* (reducing) over that log, rather than storing current
state and losing the past. Temporal's event history is a textbook implementation with a twist that
makes it special:
[deterministic replay](durable-execution-fundamentals.md#the-core-mechanism-event-sourcing-deterministic-replay)
is the fold, and *your workflow code is the fold function*. You never design the events or write
the reducer; the SDK derives both from ordinary code.

**CQRS** — Command Query Responsibility Segregation — is the companion pattern: separate the write
path from the read path, so each can use a representation optimized for its job. Temporal
implements it twice over, and being able to point at both instances turns a buzzword into a
demonstrated tool:

- **Mutable state** is the write-side projection: a compact summary of the history that the
  server maintains so state transitions don't have to re-read the log
  ([details](history-service-internals.md#mutable-state-and-event-history)).
- **Visibility** is the read-side projection: executions asynchronously indexed into
  Elasticsearch for list and search queries, eventually consistent with core state
  ([details](temporal-architecture.md#the-persistence-layer)).

It's also worth articulating how this differs from event sourcing at the application level. In a
classic app-level event-sourced system, *you* design the event schema, write the projections, and
manage schema evolution as events age. Temporal internalizes all of that: the events are
SDK-defined protocol events, and the projection is replay itself. You get event sourcing's
guarantees without designing an event schema — at the cost of not controlling what goes in the
log.

---

## Sharding and Coordination Without Consensus

Two ways to partition a keyspace: **hash sharding** (apply a hash function, take a modulus) and
**range sharding** (split the key range into contiguous chunks). Hash sharding spreads load
uniformly and needs no directory to locate a key, but destroys locality — adjacent keys land on
different shards — and makes resharding hard. Range sharding (HBase, CockroachDB, Spanner)
preserves locality for scans and can split hot ranges dynamically, at the cost of managing those
ranges.

Temporal chose hash sharding — `hash(namespace, workflow_id) % N` with fixed N — and it's a clean
fit for its access pattern: every access is a point lookup by workflow ID, range scans never
happen, so locality is worthless and uniform distribution is everything. The fixed shard count is
the trade's cost, accepted consciously.

The more interesting design decision sits on top: **Temporal runs no consensus protocol of its
own**. No Raft group per shard, no Paxos in the History service. For a system whose correctness
depends on exactly one writer per shard, that should sound alarming — until you see the two-layer
trick:

1. **Routing** is handled by Ringpop (SWIM gossip plus consistent hashing), which determines who
   *should* own each shard. Gossip is eventually consistent and can be briefly wrong — two nodes
   can simultaneously believe they own a shard.
2. **Correctness** is handled by **fencing tokens and conditional writes at the database**. Shard
   ownership carries a monotonically increasing `range_id`; every write is conditional on it. When
   the gossip layer is wrong, the stale owner's writes fail atomically at the store. (This is
   Lamport's fencing-token pattern — the same one that fixes naive distributed locks.)

Consensus hasn't vanished from the stack; it's been *delegated to the persistence layer*, which
already does it well: Cassandra's lightweight transactions run Paxos per partition, and an RDBMS
serializes through its transaction machinery. The layering is the transferable lesson — **routing
can afford to be sloppy if writes are fenced; push agreement down to the one component that
already provides it.** Contrast Kafka (Raft or ZooKeeper for partition leadership) or CockroachDB
(Raft per range), which own consensus themselves: the same responsibility, placed differently.

---

## Persistence Trade-offs

Temporal's persistence layer is pluggable, and the choice between Cassandra and a SQL database is
a classic interview discussion because there is no dominant answer — only a trade:

| | Cassandra | MySQL / PostgreSQL |
|---|---|---|
| Write scaling | Horizontal, linear with nodes — matches the shard model | Vertical, single primary — then app-level sharding pain |
| Conditional writes | LWT: a Paxos round per write — correct but costly | Native transactions — cheap |
| Operations | A distributed system of its own: compaction, repair, tombstones | Boring, well understood, managed offerings everywhere |
| Fits | Large clusters, very high transition rates | Most deployments below that scale |

The meta-point elevates this beyond a feature comparison. Temporal pays Cassandra's LWT cost to
buy linear write scaling — a bet that its target users need that scale. **DBOS bets the exact
opposite**: that one Postgres instance, with free transactions and boring operations, covers the
large majority of real workloads, and that durable execution should therefore be a library over
Postgres rather than a service cluster. Neither is wrong; they sit at different points on the
scale-versus-operability curve. What reads as senior in an interview is arguing both sides and
naming the crossover criteria: sustained state transitions per second, multi-region requirements,
and the team's capacity to operate Cassandra.

---

## Interview Angle

- **"Exactly-once" is a trap phrase.** The moment it appears, split it: delivery (impossible)
  versus processing (achievable via at-least-once plus idempotency). Then place Temporal's layers
  on that map, ending with "activities are at-least-once, so idempotency is the developer's side
  of the contract."
- **Fencing tokens.** Temporal's shard `range_id` is the cleanest production example of the
  pattern, and it doubles as the answer to "how do you handle split-brain without running
  consensus?"
- **Event sourcing and CQRS.** Be ready to point at three projections of one log — replay for
  workers, mutable state for the server, visibility for search. Concepts demonstrated as tools
  beat concepts recited as definitions.
- **Trade-off fluency.** Hash versus range sharding, Cassandra versus Postgres,
  consensus-in-the-store versus consensus-in-the-service — each deserves a "Temporal chose X
  because Y; the opposite is right when Z" answer.
