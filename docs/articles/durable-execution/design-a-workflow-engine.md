---
title: "System Design: Durable Workflow Engine"
section: "Durable Execution"
order: 8
---

# System Design: Durable Workflow Engine

## Overview

"Design a durable workflow engine" is Temporal's home-field system-design question, and a
reliability-focused classic anywhere else. The task: a service where users submit multi-step
programs that must run to completion — with retries, timers, and human-in-the-loop waits —
surviving the crash of any component. This article builds the design up in three iterations,
arriving at a Temporal-shaped architecture *by necessity*, then covers the deep-dive prompts
interviewers pull and the common variants.

## Key Insight

Separate **deciding** from **doing**. Deciding what happens next (orchestration) can be made
deterministic and replayable from a log; doing it (side effects) can't, but can be made retryable
and idempotent. Once split, reliability decomposes: an event log with atomic appends makes
decisions effectively-once; at-least-once dispatch plus idempotency makes side effects safe. Every
iteration below is a step toward that separation.

---

## Requirements and API Sketch

**Functional:**

- Start a workflow (multi-step program) with input; get an ID; query its state.
- Steps ("activities") call external services; each needs configurable retries and timeouts.
- Durable timers: "wait 30 days" must survive restarts.
- External events: signal a running workflow ("payment arrived", "human approved").
- Workflows may run for months; code deploys happen weekly.

**Non-functional:**

- No workflow lost or stuck due to any single component crash — the headline requirement.
- Scale targets to state up front: ~1M workflow starts/day, ~10M open workflows,
  ~10K state transitions/sec peak, activities from milliseconds to hours.
- Latency is secondary to durability (this is a *state* system, not a serving system) — but say
  so explicitly; it licenses trade-offs later.

```
StartWorkflow(type, id, input) -> run_handle     Signal(id, name, payload)
GetState(id) -> status/result                    ListWorkflows(filter)   # note: search ≠ state
```

---

## Iterative Design

### v1: A Database and a Poller

Workflows as rows: `(id, type, current_step, state_blob, status, wake_at)`. A fleet of poller
processes: `SELECT ... WHERE status='runnable' FOR UPDATE SKIP LOCKED`, load state, run the next
step in-process, write back.

Why it breaks — enumerate these *before* the interviewer does:

1. **Crash mid-step**: side effect happened, row not updated → step re-runs on another poller.
   Duplicate charge. (No dispatch/completion protocol.)
2. **The DB is the queue**: polling burns the database; hot table, lock contention; latency =
   poll interval.
3. **Orchestration and execution are fused**: a step that takes 2 hours pins a poller and a row
   lock; scaling "more steps/sec" and "more concurrent slow steps" are the same knob.
4. **`state_blob` is opaque**: no audit of how state evolved, no way to fix a bug and recover
   affected workflows, queries limited to what you denormalized.

v1 is not a strawman — it's what most teams actually build first, and naming its exact failure
modes is the credibility move.

### v2: Separate the Queue, Add a Protocol

Split executors from decider; put a real task queue between them; make completion explicit.

- **Orchestrator** owns workflow state; on each transition it enqueues *task* records ("run step
  3 of wf-42") onto a queue consumed by a stateless **executor fleet**.
- **Dispatch protocol**: tasks are leased (visibility timeout), executed, then explicitly
  completed back to the orchestrator; lease expiry ⇒ redelivery. Delivery is now at-least-once
  *by contract*, so executors must be **idempotent** — the requirement is now explicit instead of
  accidental.
- **Timers**: a `wake_at` index scanned by the orchestrator becomes "timer tasks" in the same
  store — fire ⇒ enqueue continuation.

Remaining hole — the one that matters: **the dual write**. Orchestrator updates workflow state
*and* enqueues a task to a separate queue system. Crash between the two ⇒ state says "step
scheduled," queue has nothing (stuck workflow) — or the reverse (phantom task). Distributed
transaction across DB and queue? No — that's the cue for the outbox.

### v3: Event Log + Transactional Outbox + Sharding

Three moves, each fixing a named v2 hole:

1. **Event-source the workflow state.** Replace `state_blob` with an append-only per-workflow
   event log (`StepScheduled`, `StepCompleted`, `TimerFired`, `SignalReceived`); current state is
   a replay/fold of the log, with a materialized summary for fast decisions. Buys: audit,
   debuggability, recovery-by-replay, and — if user code *is* the fold function — workflow-as-code
   with all local state durable ([the mechanism](durable-execution-fundamentals.md#the-core-mechanism-event-sourcing-deterministic-replay)).
2. **Transactional outbox.** Task records are written *in the same transaction* as the events
   that imply them; a per-shard processor delivers them to the queue at-least-once, deduped
   downstream. The dual-write hole is closed without cross-system transactions
   ([Temporal's version](history-service-internals.md#internal-task-queues-and-the-transactional-outbox)).
3. **Shard the orchestrator.** `hash(workflow_id) % N` shards; one owner per shard;
   ownership via membership ring, **correctness via fencing** (epoch/range-id conditional writes —
   a stale owner's writes fail at the store). Single-writer per workflow ⇒ transitions are
   serialized ⇒ conditional appends are simple. Timers become per-shard priority queues —
   no global scan ([Temporal's version](history-service-internals.md#history-shards)).

Add the two performance moves that make it production-shaped: **long-poll dispatch with sync
match** (skip the queue write when an executor is parked waiting) and **sticky execution**
(route consecutive decisions of one workflow to the same executor, cached state, full replay as
fallback) — both pure optimizations over a correct slow path
([details](matching-service-task-queues.md)).

What you've arrived at is Temporal's history/matching split — say so, and say *why each piece
exists*, which is worth more than having memorized the diagram:

```
API gateway (stateless, routes by hash)
   │
Orchestrator shards (event log + summary + outbox, single fenced writer each)
   │  transfer/timer tasks (outbox)
Task dispatch (queues; long-poll; sync-match fast path; sticky routing)
   │
Executor fleet (customer-owned; at-least-once; idempotent; heartbeats)
   │
Stores: log+state store (point ops)  |  search index (async projection)
```

---

## Deep-Dive Prompts Interviewers Pull

**"How is a state transition exactly-once if everything retries?"**
It isn't exactly-once *delivery* — it's at-least-once everything, converging via conditional
writes: every transition is an append conditional on (fencing token, next-event-id). Duplicates
and stale writers fail the condition and re-read. Side effects stay at-least-once; idempotency
keys close that gap at the executor.

**"Millions of durable timers — how?"**
Colocate timers with their workflow's shard: per-shard persisted priority queue, processor sleeps
until the head's deadline. No global scanner; capacity scales with shards. Timer firing is itself
a conditional transition, so a timer racing a completion resolves cleanly.

**"A workflow ID gets hot — 500 transitions/sec on one workflow."**
Per-workflow serialization is *by design* (it's what makes the log coherent) — so the answer is
modeling, not tuning: split the entity (child workflows / sub-entities), batch signals, or absorb
reads via queries against a projection. Distinguish hot *workflow* (model problem) from hot
*shard* (placement problem — more shards, better hash).

**"You deployed new orchestration code; replays now diverge."**
Non-determinism on replay: replayed code emits different commands than history records. Fixes:
version-gate code paths (patch markers), or pin executions to the worker version they started on
and drain ([versioning](temporal-programming-model.md#evolving-workflow-code)); prevention:
replay tests in CI against sampled production histories.

**"What's the backpressure story?"**
Pull-based dispatch: executors poll only with free slots, so overload accumulates as queue backlog
+ rising schedule-to-start latency — the system gets *later*, never *lossy*. Protect fragile
downstreams with per-queue rate limits; protect tenants from each other with per-namespace
API rate limits.

**"Where are the consistency boundaries for reads?"**
State reads (by ID, from the log's shard) are strongly consistent; search/list reads hit an async
projection and are eventually consistent. Declaring that split up front — and defending it (search
load must not compete with state transitions) — is a senior move.

---

## Variants

Same skeleton, different emphasis — recognize the mapping and reuse the core:

- **"Design distributed cron"** — the schedule state is a tiny workflow; the hard parts are
  missed ticks (catch-up window), overlapping runs (overlap policy), and exactly-one-firing
  (single-writer shard answers it for free). See
  [Schedules](multi-cluster-nexus-advanced.md#schedules-and-cron).
- **"Design a payment saga orchestrator"** — the workflow is the saga; compensation is a `try/
  catch` running compensating activities; emphasize idempotency keys on every money movement and
  the audit value of the event log.
- **"Design an AI-agent runtime"** — agent loop = workflow; LLM/tool calls = activities (slow,
  flaky, expensive ⇒ retries + heartbeats); human-in-the-loop = signals/updates; token budgets ⇒
  continue-as-new on history growth. The 2026-relevant skin on the same design.

## Temporal Loop Notes

What the Senior SDE loop reportedly looks like (recruiter screen → coding → onsite):

- **Coding rounds** — DSA-medium plus a **difficult concurrency round**, Go-flavored: build a job
  queue / worker pool / rate limiter with goroutines and channels; correctness under cancellation
  and shutdown matters more than raw speed. Practice: bounded worker pool with graceful drain,
  `context` propagation, `select` with timeout.
- **AI-assisted coding is allowed** — they evaluate how you drive the tool: decompose the problem,
  review generated code critically, test it. Don't hide the tool; direct it well.
- **System design** — reliability-first, workflow-engine-adjacent (this article's question or a
  variant). Lead with durability guarantees and failure modes, not features.
- **Domain fluency** — the [architecture](temporal-architecture.md) and
  [internals](history-service-internals.md) articles are the depth reserve for follow-ups; the
  [foundations](distributed-systems-foundations.md) vocabulary carries the cross-questioning.
