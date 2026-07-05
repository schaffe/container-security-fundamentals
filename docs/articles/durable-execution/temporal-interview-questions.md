---
title: "Temporal Interview Q&A"
section: "Durable Execution"
order: 9
---

# Temporal Interview Q&A

## Overview

A question bank in interview format: nine questions an interviewer at a Temporal-adjacent company
(or any team running workflow orchestration) actually asks, each with a senior-level answer you
could deliver in two minutes. The answers assume the concepts from the previous eight articles and
link back to them instead of re-explaining — treat this as a rehearsal script, not a primer.

---

## Temporal Concepts

### Given a block of logic, how do you decide whether it belongs in a workflow or an activity?

Apply the [determinism boundary](temporal-programming-model.md#workflows-vs-activities-the-determinism-boundary):
if the code decides *what happens next*, it's workflow; if it *touches the outside world*, it's an
activity.

| Signal | Placement |
|---|---|
| Branching, sequencing, waiting, aggregating results | Workflow |
| HTTP/DB/queue call, file I/O, anything that can fail from infra | Activity |
| Needs retry semantics of its own | Activity |
| Pure computation on workflow state, cheap and deterministic | Workflow (it replays for free) |
| Pure but expensive (minutes of CPU) | Activity — replay would re-pay the cost otherwise |

Two refinements show seniority: granularity — each activity should be a unit that is independently
retryable and idempotent, so "charge card and send email" is two activities, not one; and payload
size — large data should pass by reference (object-store key) because every activity input/output
is recorded in event history, which has hard size limits.

### Why must workflow code be deterministic, and how does `UUID.random()` or unmocked system time break replay?

Because a workflow's "memory" is not process state — it is
[event history plus re-execution](durable-execution-fundamentals.md#the-core-mechanism-event-sourcing-deterministic-replay).
After a crash or cache eviction, a worker rebuilds state by running the code again and feeding it
recorded results. That only works if the code emits the *same commands in the same order* every
run.

`UUID.random()` breaks this subtly: first execution generates ID `abc` and, say, passes it to an
activity; on replay the code generates `xyz`, so the command it emits no longer matches the
recorded `ActivityTaskScheduled` event — the SDK throws a non-determinism error and the workflow
task fails repeatedly. Unmocked `time.Now()` is worse because it often *doesn't* fail loudly: a
branch like `if now > deadline` can silently take the other path on replay, corrupting state.
Non-determinism is therefore both a crash bug and a correctness bug — the loud failure is the
lucky case.

### How do you handle non-deterministic operations or external API calls inside a workflow?

Route every non-deterministic result through the server so it lands in history once and replays
from the record:

- **External API calls, I/O** — activities, always. The result is recorded in
  `ActivityTaskCompleted`; replay reads it back instead of re-calling the API.
- **Time** — `workflow.Now()` (the timestamp of the current workflow task, from history) and
  `workflow.Sleep()` (a durable server-side timer), never `time.Now()`/`time.Sleep()`.
- **Random values, UUIDs** — `SideEffect`/`workflow.newRandom()`: executed once, value recorded,
  replays return the recorded value. Note `SideEffect` is not retried and must not fail — anything
  fallible belongs in an activity.
- **Config/env reads** — pass as workflow input, or read via an activity if it must be fresh.
- **Code changes** (deploy-induced non-determinism) — patching (`GetVersion`/`patched()`) or
  worker versioning with pinned deployments, plus replay tests in CI against sampled production
  histories.

---

## Concurrency & Failure Semantics

### How do you implement custom retry policies, exponential backoff, and heartbeats for long-running activities?

You mostly *declare* rather than implement: each activity carries a retry policy — initial
interval, backoff coefficient (e.g., 1s × 2.0 up to a max interval), maximum attempts, and a list
of non-retryable error types (`InvalidCardError` should fail fast; `ServiceUnavailable` should
back off). The server drives the retries; workflow code just sees one awaited call.

For long-running activities, set a **heartbeat timeout** and call `heartbeat(progress)`
periodically. This buys two things: fast failure detection (without it, a dead worker isn't
noticed until start-to-close expires — potentially hours), and resumability — the last heartbeat
payload is delivered to the retry attempt, so a file-processing activity can resume from record
1.4M instead of zero.

Custom logic beyond the declarative policy — e.g., retry with a *different* activity, or
escalate to a human after N failures — lives in the workflow: catch the `ActivityFailure` after
the policy exhausts and branch. Policy for the mechanical retries, workflow code for the
business-level fallback.

### An activity may execute multiple times — retries, worker crashes. How do you guarantee idempotency?

Start by naming the guarantee: activities are
[at-least-once](distributed-systems-foundations.md#at-least-once-at-most-once-exactly-once) — an
activity can complete its side effect, crash before reporting, and be retried. Temporal cannot fix
that; the effect already escaped. So idempotency is the activity author's job:

1. **Derive an idempotency key** from stable workflow facts — workflow ID + activity/step
   identifier (`order-4711:charge`), *not* a random UUID generated per attempt.
2. **Push the key to the downstream system** if it supports one (Stripe's `Idempotency-Key`,
   conditional writes, `INSERT ... ON CONFLICT DO NOTHING`).
3. **Or make the operation naturally idempotent** — set-based writes ("set status=SHIPPED")
   rather than increments.
4. **Or dedup yourself** — a
   [processed-keys table checked transactionally](distributed-systems-foundations.md#idempotency-and-dedup)
   with the side effect.

The interview trap is claiming "Temporal gives exactly-once." Correct framing: exactly-once
*workflow state transitions*, at-least-once *activity execution*, and effectively-once end-to-end
only when activities are idempotent.

### Concurrency coding rounds: rate limiting, worker pools for millions of requests, deadlock avoidance — what patterns do you reach for (Go)?

- **Rate limiting** — `golang.org/x/time/rate` (token bucket) shared across goroutines:
  `limiter.Wait(ctx)` before each request. For a hand-rolled version: a buffered channel refilled
  by a ticker. Mention distributed rate limiting needs a shared store or per-node quota splitting.
- **Worker pool** — fixed goroutine count draining a channel; never one goroutine per request at
  millions-scale:

```go
jobs := make(chan Job, 1024)
for i := 0; i < nWorkers; i++ {
    g.Go(func() error {
        for j := range jobs { process(ctx, j) }
        return nil
    })
}
```

  Backpressure falls out naturally — a full channel blocks producers, which is what
  [Temporal's own worker does](matching-service-task-queues.md#flow-control) with slot limits and
  poller counts.
- **Deadlock avoidance** — acquire locks in a global order; keep critical sections tiny; prefer
  channels/ownership transfer over shared memory; always take locks with a `ctx`/timeout escape
  hatch. In Temporal specifically, workflow code is single-threaded coroutines — the SDK's
  deadlock detector kills any workflow task that blocks the scheduler (~1s), which is why you
  never do real blocking work there.

---

## Distributed System Design

### Walk me through a worker crashing mid-task. How does another worker take over?

The concrete sequence:

1. Worker A is executing a workflow task when it dies. The server notices via **workflow task
   timeout** (default 10s) — no heartbeat magic here; the task simply isn't completed in time.
2. History service marks the task timed out and **reschedules it**. It was likely targeted at
   A's [sticky queue](matching-service-task-queues.md#sticky-queues); after the sticky
   schedule-to-start timeout (~5s) it falls back to the **normal task queue** that all workers
   poll.
3. Worker B picks it up. It has no cached state for this execution, so it requests the **full
   event history** from the history service.
4. B **replays**: re-executes the workflow function from the top; every awaited call is satisfied
   from recorded events (`ActivityTaskCompleted` results, timer firings) instead of re-executing
   side effects.
5. Replay reaches the first point with **no recorded event** — that is exactly where A died —
   and continues live from there, emitting new commands.

Completed activities are not re-run; an activity that was *in flight* on A is governed separately
by its own timeouts and retry policy.

### How would you scale a workflow orchestration system — hot partitions, shard allocation, rebalancing under load?

Partition by workflow ID into a **fixed set of logical shards** (`hash(namespace, workflowID) %
N`, N in the thousands), each shard single-owner so per-workflow ordering needs no cross-node
consensus — this is [Temporal's history shard design](history-service-internals.md#history-shards).
Key points:

- **Allocation** — a membership ring (gossip/consistent hashing) maps shards to history nodes;
  many logical shards per node means adding a node moves ~1/n of shards, no data migration, since
  shard state lives in the database, not on the node.
- **Rebalancing under load** — shard *ownership* moves, data doesn't; fencing tokens
  (monotonic `rangeID`) make a stale ex-owner's writes fail rather than corrupt state during
  handoff.
- **Hot shards** — hashing spreads workflows, but a single hot *workflow* (signal storm, huge
  history) can't be split; mitigate at the app layer by fanning out to child workflows or
  sharding the entity key. Hot *task queues* are a separate axis — scale queue partitions.
- Fixed N is a genuine limit: resharding is effectively a migration, so overprovision N upfront.

### Append-only event log vs. relational storage for execution history — what are the trade-offs?

| | Append-only event log | Relational/mutable rows |
|---|---|---|
| Write path | Sequential appends — fast, contention-free | Read-modify-write on status row |
| Concurrency | New events don't contend with old | Updates fight over the same row |
| Audit/debug | Full causal record; replay any execution | Only current state; history is lost |
| Read "current state" | Must fold the whole log — O(history) | One row read |
| Storage | Grows unboundedly; needs retention/archival | Compact |
| Schema evolution | Old events immutable — versioning pain | `ALTER TABLE` |

The log gives you the replay mechanism, a perfect audit trail, and cheap writes; it costs you
expensive state reconstruction and unbounded growth. Temporal's answer is the hybrid: the event
log as source of truth plus **mutable state** — a
[materialized snapshot updated transactionally with each append](history-service-internals.md#mutable-state-event-history)
— so hot-path reads never fold the log, echoing the classic
[event-sourcing + CQRS](distributed-systems-foundations.md#event-sourcing-and-cqrs) resolution.
Growth is bounded by history limits plus continue-as-new, and closed histories archive to blob
storage. Strong answers name the hybrid, not one side.
