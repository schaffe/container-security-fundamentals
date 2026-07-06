---
title: "System Design: Durable Workflow Engine"
section: "Durable Execution"
order: 8
---

# System Design: Durable Workflow Engine

## Overview

"Design a durable workflow engine" is Temporal's home-field system-design question and a
reliability classic anywhere else. The brief: build a service where users submit multi-step
programs that must run to completion — with retries, durable timers, and human-in-the-loop waits —
and where the crash of any single component never loses or wedges a workflow.

The approach in this article is to build the design in three iterations, starting from what most
teams would actually build first and fixing each design's specific failure modes, until the
architecture arrives — by necessity, not by memorization — at something Temporal-shaped. Along the
way it covers the deep-dive prompts interviewers reliably pull and the common variant questions.

## Key Insight

If you carry only one idea into this interview, carry this: **separate deciding from doing.**

Deciding what happens next — the orchestration — can be made deterministic and therefore
replayable from a log. Doing it — the side effects — can never be made replayable, but it *can* be
made retryable and idempotent. Once you split the two, the reliability problem decomposes cleanly:
an event log with atomic appends makes the decisions effectively-once, and at-least-once dispatch
plus idempotency makes the side effects safe. Every iteration below is a step toward completing
that separation.

---

## Requirements and API Sketch

Functional requirements to establish up front:

- Start a workflow — a multi-step program — with input; get back an ID; query its state.
- Steps ("activities") call external services, and each needs configurable retries and timeouts.
- Durable timers: "wait 30 days" must survive any restart.
- External events: a running workflow can be signaled ("payment arrived," "human approved").
- Workflows may run for months, while code deploys happen weekly — so old and new code coexist.

And non-functional:

- The headline requirement: **no workflow is lost or stuck because any single component crashed.**
- State scale targets explicitly: on the order of a million workflow starts per day, ten million
  open workflows, ten thousand state transitions per second at peak, activities lasting from
  milliseconds to hours.
- Latency is secondary to durability. This is a *state* system, not a serving system — and saying
  that explicitly is worth doing, because it licenses trade-offs you'll want later (an extra
  database round-trip per transition is fine; losing a transition is not).

```
StartWorkflow(type, id, input) -> run_handle     Signal(id, name, payload)
GetState(id) -> status/result                    ListWorkflows(filter)   # note: search ≠ state
```

---

## Iterative Design

### v1: A Database and a Poller

Start with what nearly every team builds first. Workflows are rows in a table —
`(id, type, current_step, state_blob, status, wake_at)` — and a fleet of poller processes runs
`SELECT ... WHERE status='runnable' FOR UPDATE SKIP LOCKED`, loads a workflow's state, executes
its next step in-process, and writes the updated row back.

This is not a strawman; it works, at small scale, for a while. Naming its exact failure modes —
before the interviewer does — is the credibility move. There are four:

1. **A crash mid-step loses the plot.** The poller executes the step's side effect (charges the
   card), then dies before writing the row. The lock expires, another poller picks up the row —
   which still says the step hasn't run — and charges the card again. There is no protocol
   distinguishing "dispatched" from "completed," so crash timing decides between duplicate and
   lost work.
2. **The database is the queue.** Every poller hammers the same table on an interval. You pay
   constant polling load for the privilege of latency floored at the poll interval, plus lock
   contention on the hot rows.
3. **Orchestration and execution are fused.** A step that takes two hours pins a poller process
   *and* a row lock for two hours. Scaling "more steps per second" and scaling "more concurrent
   slow steps" are the same knob, and they shouldn't be.
4. **`state_blob` is opaque.** You can see where a workflow *is*, but not how it got there — no
   audit trail, no way to diagnose a corrupted workflow, no way to fix a bug and recover the
   executions it damaged, and queries are limited to whatever you denormalized into columns.

### v2: Separate the Queue, Add a Protocol

Fix the structural problems first: split the executors from the decision-maker, put a real task
queue between them, and make completion explicit.

An **orchestrator** now owns workflow state. On each transition it enqueues *task* records —
"run step 3 of workflow-42" — onto a queue consumed by a stateless **executor fleet**. Tasks are
**leased** (a visibility timeout), executed, and explicitly *completed* back to the orchestrator;
if the lease expires without a completion, the task is redelivered. Timers stop being a scanned
`wake_at` column and become timer tasks in the same store — when one fires, it enqueues the
workflow's continuation.

Notice what the lease-and-complete protocol did to failure semantics: delivery is now
at-least-once *by explicit contract* rather than by accident, which means executors must be
**idempotent** — and now that requirement is visible in the design instead of being discovered in
production.

But one hole remains, and it's the one that matters most. The orchestrator performs a **dual
write**: it updates workflow state in the database *and* enqueues a task in a separate queue
system. Crash between the two and either the state says "step scheduled" while the queue holds
nothing — a permanently stuck workflow — or the reverse, a phantom task for a transition that
never committed. Reaching for a distributed transaction across the database and the queue is the
wrong move (fragile, slow, and most queues can't participate anyway). This is the cue for the
outbox pattern.

### v3: Event Log, Transactional Outbox, and Sharding

Three moves, each closing a named hole from v2.

**First, event-source the workflow state.** Replace the opaque `state_blob` with an append-only
per-workflow event log — `StepScheduled`, `StepCompleted`, `TimerFired`, `SignalReceived` —
folded into a materialized summary for fast decisions. This buys the audit trail, debuggability,
and recovery-by-replay that v1's blob could never offer. And it enables the model's signature
trick: if the user's *code* is the fold function, you get workflow-as-code, with all local
variables durable via
[deterministic replay](durable-execution-fundamentals.md#the-core-mechanism-event-sourcing-deterministic-replay).

**Second, close the dual write with a transactional outbox.** Write task records *in the same
database transaction* as the events that imply them; a per-shard background processor then
delivers those tasks to the queue at-least-once, with deduplication downstream. No state without
its task, no task without its state, no cross-system transaction —
[exactly as Temporal's history service does it](history-service-internals.md#internal-task-queues-and-the-transactional-outbox).

**Third, shard the orchestrator.** Partition workflows by `hash(workflow_id) % N`; give each
shard one owner at a time, placed via a membership ring; and — critically — enforce correctness
not by the ring but by **fencing**: each owner holds an epoch (range ID), and every write is
conditional on it, so a stale owner's writes fail at the store. Single writer per workflow means
transitions are serialized, which keeps the conditional appends simple. And timers become
per-shard priority queues, colocated with their workflows — no global timer scan
([Temporal's version](history-service-internals.md#history-shards)).

Two performance moves complete the production shape, and both are pure optimizations over a
correct slow path: **long-poll dispatch with a sync-match fast path** (skip the queue write
entirely when an executor is parked and waiting) and **sticky execution** (route consecutive
decisions of one workflow to the same executor's cached state, with full replay as the fallback) —
both detailed in [the matching article](matching-service-task-queues.md).

What you've arrived at is Temporal's history/matching split. Say so — and say *why each piece
exists*, which is worth more than a memorized diagram:

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
Reframe it: nothing here is exactly-once *delivered* — every arrow is at-least-once — but the
system *converges* to exactly-once outcomes through conditional writes. Every transition is an
append conditional on the fencing token and the expected next event ID; a duplicate or a stale
writer fails the condition, re-reads, and discovers the transition already happened. Side effects
remain genuinely at-least-once, and idempotency keys at the executor close that final gap.

**"Millions of durable timers — how?"**
Don't build a timer service; colocate timers with their workflow's shard. Each shard keeps a
persisted priority queue of timer tasks, and its processor sleeps until the head's deadline. No
global scan exists, and timer capacity scales with shard count. A timer firing is itself a
conditional state transition, so a timer racing a completion resolves cleanly — one of them loses
the conditional write, harmlessly.

**"One workflow ID gets hot — 500 transitions per second on a single workflow."**
The trap is answering with tuning. Per-workflow serialization is *by design* — it's what keeps
that workflow's log coherent — so a single workflow has a hard ceiling of low tens of transitions
per second, and the answer is *modeling*: split the entity into child workflows or sub-entities,
batch the incoming signals, or absorb read load with queries against a projection. Distinguish
the hot *workflow* (a modeling problem) from a hot *shard* (a placement problem — more shards, a
better hash).

**"You deployed new orchestration code and replays now diverge."**
Name the disease: non-determinism on replay — the redeployed code emits different commands than
history records. Fixes: version-gate the change in code (patch markers), or pin executions to the
worker version they started on and drain the old version
([versioning](temporal-programming-model.md#evolving-workflow-code)). Prevention: replay tests in
CI against sampled production histories.

**"What's the backpressure story?"**
Dispatch is pull-based: executors poll only when they have free slots, so overload cannot crush
them or drop work — it accumulates as queue backlog and rising schedule-to-start latency. The
system degrades by getting *later*, never *lossy*. Fragile downstreams get per-queue rate limits;
tenants get per-namespace API rate limits.

**"Where are the consistency boundaries for reads?"**
State reads by ID go to the workflow's shard and are strongly consistent. List and search queries
hit an asynchronously updated projection and are eventually consistent. Declaring that split up
front — and defending it, because search load must never compete with state transitions — is a
senior move.

---

## Variants

The same skeleton wears different skins. Recognize the mapping and reuse the core:

- **"Design distributed cron"** — a schedule is a tiny workflow; the hard parts are missed ticks
  (catch-up windows), overlapping runs (overlap policies), and exactly-one-firing, which the
  single-writer shard answers for free. [Full treatment](design-distributed-cron.md).
- **"Design a payment saga orchestrator"** — the workflow is the saga; compensation is a
  try/catch running compensating activities; the emphasis shifts to idempotency keys on every
  money movement and the event log as audit trail. [Full treatment](design-payment-saga.md).
- **"Design an AI-agent runtime"** — the agent loop is a workflow; LLM and tool calls are
  activities (slow, flaky, expensive — hence retries and heartbeats); human-in-the-loop is
  signals; token budgets force continue-as-new. The 2026-relevant skin.
  [Full treatment](design-ai-agent-runtime.md).

## Temporal Loop Notes

What the Senior SDE loop reportedly looks like, from recruiter screen through onsite:

- **Coding rounds**: DSA-medium plus a genuinely difficult concurrency round, Go-flavored —
  build a job queue, worker pool, or rate limiter with goroutines and channels, where correctness
  under cancellation and shutdown matters more than raw speed. Worth practicing: a bounded worker
  pool with graceful drain, `context` propagation, and `select` with timeout.
- **AI-assisted coding is allowed**, and they evaluate how you drive the tool: decomposing the
  problem, reviewing generated code critically, testing it. Don't hide the tool; direct it well.
- **System design** is reliability-first and workflow-engine-adjacent — this article's question
  or a variant. Lead with durability guarantees and failure modes, not features.
- **Domain fluency**: the [architecture](temporal-architecture.md) and
  [internals](history-service-internals.md) articles are the depth reserve for follow-ups, and
  the [foundations](distributed-systems-foundations.md) vocabulary carries the cross-questioning.
