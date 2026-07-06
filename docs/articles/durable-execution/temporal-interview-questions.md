---
title: "Temporal Interview Q&A"
section: "Durable Execution"
order: 9
---

# Temporal Interview Q&A

## Overview

This is a rehearsal script: nine questions an interviewer at a Temporal-adjacent company — or any
team running workflow orchestration — actually asks, each answered the way a senior engineer would
answer it out loud, in about two minutes. The answers are written to be *spoken*: full sentences,
one idea leading to the next, with the technical depth layered in rather than front-loaded. They
draw on the concepts from the previous articles and link back to them, so if an answer's
foundation feels shaky, the link is the remediation.

---

## Temporal Concepts

### Given a block of logic, how do you decide whether it belongs in a workflow or an activity?

The test I apply is a single question: does this code decide *what happens next*, or does it
*touch the outside world*? Decision-making — branching, sequencing, waiting on events,
aggregating results — belongs in the workflow, because the workflow is the durable, replayable
record of what was decided. Anything that touches the world — an HTTP call, a database write, a
queue publish, file I/O, anything that can fail because infrastructure failed — belongs in an
activity, because activities are the layer where failure and retry are allowed to exist. That's
the [determinism boundary](temporal-programming-model.md#workflows-vs-activities-the-determinism-boundary),
and nearly every placement question dissolves once you ask it.

There are a couple of edge cases worth handling explicitly. Pure computation on workflow state —
cheap and deterministic — can stay in the workflow; it just replays for free. But pure computation
that's *expensive*, say minutes of CPU, should move into an activity anyway, because otherwise
every replay re-pays that cost. And code that needs its own retry semantics is an activity by
definition — retry policy is an activity-level concept.

Then two refinements show seniority. The first is granularity: each activity should be a unit
that's independently retryable and idempotent. "Charge the card and send the confirmation email"
is two activities, not one — if the email fails, you want to retry the email, not re-charge the
card. The second is payload size: every activity input and output gets recorded in event history,
which has hard size limits, so large data should pass by reference — an object-store key — not by
value.

### Why must workflow code be deterministic, and how does `UUID.random()` or unmocked system time break replay?

The reason is that a workflow's "memory" isn't process state — it's
[event history plus re-execution](durable-execution-fundamentals.md#the-core-mechanism-event-sourcing-deterministic-replay).
When a worker crashes or evicts a workflow from cache, the next worker rebuilds the workflow's
state by running the code again from the top, feeding it recorded results wherever the code makes
a call that previously produced an event. That reconstruction is only valid if the code emits the
same commands in the same order every time it runs. Determinism isn't a style preference; it's
the precondition for the entire recovery mechanism.

Now the two examples, because they fail in interestingly different ways. `UUID.random()` breaks
replay *loudly*. The first execution generates ID `abc` and, say, passes it to an activity. On
replay, the code generates `xyz` instead, so the command it emits no longer matches the
`ActivityTaskScheduled` event recorded in history — the SDK detects the mismatch, throws a
non-determinism error, and the workflow task fails repeatedly until a human steps in. Painful, but
at least visible.

Unmocked system time is worse, because it often *doesn't* fail loudly. A branch like
`if now > deadline` can evaluate one way in the original execution and the other way on replay —
and if both paths happen to emit compatible commands, nothing errors at all. Your workflow's state
is just silently wrong. That's the point I'd want to land in an interview: non-determinism is both
a crash bug and a correctness bug, and the crash is the *lucky* outcome.

### How do you handle non-deterministic operations or external API calls inside a workflow?

The principle is always the same: route every non-deterministic result through the server, so it
lands in history exactly once and replays from the record instead of being recomputed. Then it's a
matter of knowing which tool applies to which kind of non-determinism.

External API calls and any I/O go in activities — always. The result gets recorded in an
`ActivityTaskCompleted` event, and replay reads it back rather than re-calling the API. For time,
the SDK provides `workflow.Now()`, which returns the timestamp of the current workflow task from
history, and `workflow.Sleep()`, which is a durable server-side timer — never `time.Now()` or
`time.Sleep()`. For random values and UUIDs, there's `SideEffect` (or the SDK's deterministic
random): the value is computed once, recorded, and replay returns the recording. One caveat worth
volunteering: `SideEffect` is not retried and must not fail — anything fallible belongs in an
activity, full stop.

Two less obvious cases round out the answer. Configuration and environment reads should be passed
in as workflow input, or read via an activity if they must be fresh — a config value that changes
between the original run and a replay is non-determinism wearing a disguise. And the biggest
source of non-determinism in practice isn't any of these — it's *deploying new code* over running
workflows. That's handled with patching (`GetVersion` / `patched()`) or worker versioning with
pinned deployments, and defended in CI with replay tests against sampled production histories.

---

## Concurrency & Failure Semantics

### How do you implement custom retry policies, exponential backoff, and heartbeats for long-running activities?

The first thing to say is that in Temporal you mostly *declare* retries rather than implement
them. Each activity carries a retry policy — initial interval, backoff coefficient (say, one
second doubling up to a max), maximum attempts, and a list of non-retryable error types. That
last one matters: an `InvalidCardError` should fail immediately, because no amount of retrying
makes a bad card good, while a `ServiceUnavailable` should back off and try again. The server
drives all of this; workflow code just sees one awaited call that eventually succeeds or
definitively fails.

For long-running activities, the tool is the **heartbeat**. You set a heartbeat timeout and have
the activity call `heartbeat(progress)` periodically, and that buys two distinct things. The
first is fast failure detection: without heartbeats, a worker that dies ten minutes into a
two-hour activity isn't noticed until the full start-to-close timeout expires. With them, the
server notices within seconds. The second is resumability: the last heartbeat payload is handed
to the retry attempt, so a file-processing activity that recorded "I'm at record 1.4 million" can
resume from there rather than from zero.

And when the declarative policy isn't enough — you want to retry with a *different* activity, or
escalate to a human after N failures — that logic lives in the workflow: catch the
`ActivityFailure` after the policy exhausts, and branch. The division of labor is clean: the
policy handles mechanical retries, workflow code handles business-level fallback.

### An activity may execute multiple times — retries, worker crashes. How do you guarantee idempotency?

I'd start by naming the guarantee precisely, because the framing is half the answer: activity
execution is
[at-least-once](distributed-systems-foundations.md#at-least-once-at-most-once-and-the-myth-of-exactly-once).
An activity can complete its side effect, crash before reporting completion, and be retried —
and Temporal cannot fix that, because the effect already escaped into the world before anyone
knew the report was lost. So idempotency is the activity author's job, and there's a standard
playbook.

Step one is deriving an idempotency key from *stable* workflow facts — the workflow ID plus a
step identifier, something like `order-4711:charge`. Not a random UUID generated inside the
activity: that changes on every retry attempt, which defeats the entire purpose, and it's the
single most common bug in this area. Step two is pushing that key to the downstream system, if it
supports one — Stripe's `Idempotency-Key` header, a conditional write, an
`INSERT ... ON CONFLICT DO NOTHING`. If the downstream doesn't support keys, option three is
making the operation naturally idempotent — set-based writes like "set status to SHIPPED" rather
than increments. And failing all of that, option four is deduplicating yourself, with a
[processed-keys table checked in the same transaction](distributed-systems-foundations.md#idempotency-and-dedup)
as the side effect.

The interview trap here is claiming "Temporal gives you exactly-once." The correct framing, which
I'd state explicitly: workflow *state transitions* are exactly-once, activity *execution* is
at-least-once, and the end-to-end system is effectively-once precisely when activities are
idempotent. That last clause is the developer's side of the contract.

### Concurrency coding rounds: rate limiting, worker pools for millions of requests, deadlock avoidance — what patterns do you reach for in Go?

For rate limiting, the standard tool is `golang.org/x/time/rate` — a token bucket — shared across
goroutines, with `limiter.Wait(ctx)` before each request so callers block until a token is
available and respect cancellation. If asked to hand-roll it, a buffered channel refilled by a
ticker gets you the same shape. And it's worth mentioning unprompted that this is *per-process*
rate limiting; a distributed limit needs a shared store or per-node quota splitting.

For handling millions of requests, the pattern is a fixed-size worker pool draining a channel —
never a goroutine per request at that scale:

```go
jobs := make(chan Job, 1024)
for i := 0; i < nWorkers; i++ {
    g.Go(func() error {
        for j := range jobs { process(ctx, j) }
        return nil
    })
}
```

The elegant property to point out is that backpressure falls out for free: when the channel
fills, producers block, which is exactly the behavior you want. It's also exactly what
[Temporal's own worker does](matching-service-task-queues.md#flow-control) with slot limits and
poller counts — a worker with no free slots simply doesn't poll.

For deadlock avoidance: acquire locks in a globally consistent order, keep critical sections
tiny, prefer channels and ownership transfer over shared memory, and always take locks with a
context or timeout escape hatch. And there's a Temporal-specific twist worth knowing: workflow
code runs as single-threaded coroutines, and the SDK ships a deadlock detector that kills any
workflow task blocking the scheduler for about a second — which is precisely why real blocking
work never goes in workflow code.

---

## Distributed System Design

### Walk me through a worker crashing mid-task. How does another worker take over?

Let me trace the concrete sequence. Worker A is executing a workflow task when it dies. There's
no heartbeat magic for workflow tasks — the server notices through the **workflow task timeout**,
default ten seconds: the task simply isn't completed in time.

The history service marks the task timed out and reschedules it. Here's a subtlety worth
including: the original task was probably targeted at worker A's
[sticky queue](matching-service-task-queues.md#sticky-queues) — a private queue that routes a
workflow's tasks back to the worker holding its state in cache. Worker A is dead, so nobody polls
that queue; after the sticky schedule-to-start timeout, around five seconds, the server gives up
on stickiness and reschedules onto the normal shared queue that every worker polls.

Worker B picks it up. B has no cached state for this execution, so it requests the full event
history and **replays**: it re-executes the workflow function from the top, and every awaited
call is satisfied from recorded events — activity results, timer firings — rather than by
re-executing side effects. Replay runs until it reaches the first point with no recorded event.
That point is, by construction, exactly where worker A died. From there, B continues live,
emitting new commands as if nothing happened.

The clean separation to close on: completed activities are never re-run — their results are in
history. An activity that was *in flight* on the dead worker is a separate story, governed by its
own timeouts and retry policy — which is where at-least-once execution and idempotency come in.

### How would you scale a workflow orchestration system — hot partitions, shard allocation, rebalancing under load?

The foundation is partitioning by workflow ID into a **fixed set of logical shards** —
`hash(namespace, workflowID) % N` with N in the thousands — where each shard has a single owner
node at a time. Single ownership is what makes per-workflow ordering free: transitions for a
given workflow serialize on its shard's owner, with no cross-node consensus per operation. This
is [Temporal's history shard design](history-service-internals.md#history-shards).

For allocation, a membership ring — gossip plus consistent hashing — maps shards to nodes. The
reason you want many logical shards per node is elasticity: adding a node moves roughly 1/n of
the shards to it, and because shard *state* lives in the database rather than on the node,
"moving a shard" means transferring ownership, not migrating data.

Rebalancing under load is where the correctness question hides, and the answer is **fencing**:
shard ownership carries a monotonically increasing token — Temporal's `range_id` — and every
write is conditional on it. During a handoff, a stale ex-owner's writes fail at the database
rather than corrupting state. The gossip ring can be briefly wrong; the conditional write can't.

On hot spots, I'd distinguish two different problems. Hashing spreads *workflows* evenly, but a
single hot workflow — a signal storm, an enormous history — can't be split by any partitioning
scheme, because its ordering guarantee is the thing being protected. That's a modeling problem:
fan out to child workflows or shard the entity key at the application layer. A hot *task queue*
is a different axis entirely, solved by scaling queue partitions.

And the honest limitation to volunteer: fixed N is a real ceiling. Resharding is effectively a
cluster migration, so you overprovision the shard count up front.

### Append-only event log vs. relational storage for execution history — what are the trade-offs?

Let me argue both sides, because the strong answer here is the hybrid, not a winner.

The append-only log wins on the write path: appends are sequential and contention-free, and new
events never fight old ones for locks — whereas a mutable status row makes every update a
read-modify-write contending on the same row. The log also gives you a complete causal record:
you can audit any execution, debug by replaying it, and answer "how did this workflow get into
this state?" — a question mutable rows structurally cannot answer, because they've forgotten. And
in a durable-execution system the log isn't just nice to have; it *is* the replay mechanism.

The log's costs are real, though. Reading current state means folding the entire log — O(history)
where the relational row is a single read. Storage grows without bound, so you need retention and
archival. And schema evolution is painful, because old events are immutable — you version and
translate rather than `ALTER TABLE`.

Temporal's answer — and the classic
[event-sourcing-plus-CQRS](distributed-systems-foundations.md#event-sourcing-and-cqrs)
resolution — is to refuse the either/or: the event log remains the source of truth, and
**mutable state** — a
[materialized snapshot updated transactionally with every append](history-service-internals.md#mutable-state-and-event-history)
— serves hot-path reads so the server never folds the log during normal operation. Unbounded
growth is handled with per-execution history limits plus continue-as-new, and closed histories
archive to blob storage. If I'm scoring answers to this question: naming the hybrid is the senior
answer; picking one side is the junior one.
