---
title: "Temporal Programming Model"
section: "Durable Execution"
order: 2
---

# Temporal Programming Model

## Overview

Temporal's API surface — workflows, activities, signals, queries, updates, timers, child workflows
— is a thin veneer over one rule: **workflow code must be deterministic; everything
non-deterministic goes through the server and gets recorded in event history**. Every feature in
this article is a disciplined answer to "how do I do X without breaking replay?"

---

## Workflows vs. Activities: The Determinism Boundary

A **workflow** is the orchestration logic — durable, replayable, deterministic. An **activity** is
a single side-effecting operation — an HTTP call, a DB write, an LLM invocation — that may fail
and be retried. The boundary between them is the most important design decision in any Temporal
application:

| | Workflow code | Activity code |
|---|---|---|
| Determinism | Required | Not required |
| Side effects | Forbidden (only via activities) | The whole point |
| Failure model | Cannot "fail" from infra errors; replays forever | Fails, retried per policy |
| Duration | Unbounded (years) | Bounded by timeouts |
| Delivery guarantee | State transitions effectively-once | At-least-once execution |
| Runs on | Worker, reconstructed by replay | Worker, plain function call |

### Activity Timeouts

Every activity needs at least one timeout — without it, a lost worker means the activity hangs
forever. Four knobs:

```
 schedule ──────────────────────────────────────────► close
 │◄─────────────── schedule-to-close ───────────────►│
 │◄─ schedule-to-start ─►│◄────── start-to-close ───►│
                         │   ▲ heartbeat interval ▲   │
```

- **start-to-close** — max duration of a single attempt. The one you should always set.
- **schedule-to-start** — max time in queue before a worker picks it up. Detects worker-fleet
  starvation; usually left unset in favor of monitoring the metric.
- **schedule-to-close** — total budget across all retries.
- **heartbeat timeout** — for long activities: the worker must call `heartbeat()` periodically or
  the server presumes it dead and retries elsewhere. Heartbeats can carry progress details, so the
  retry can resume mid-task (e.g., "resume file processing from record 1,400,000").

Retry policy (initial interval, backoff coefficient, max attempts, non-retryable error types) is
declared alongside; the server drives retries — the workflow code just sees one awaited call that
eventually succeeds or exhausts its policy.

**Idempotency lives in activities.** The server guarantees it will run the activity *at least*
once per logical scheduling; an activity can succeed and crash before acking, then run again.
Design activities around idempotency keys derived from workflow ID + activity input.

---

## Determinism Constraints and Replay

During [replay](durable-execution-fundamentals.md#the-core-mechanism-event-sourcing-deterministic-replay),
the SDK re-executes workflow code against recorded history. Anything that could produce a different
answer on re-execution is banned in workflow code:

| Banned | Replacement |
|---|---|
| `time.Now()` / `Date.now()` | `workflow.Now()` — deterministic, from history |
| `rand()` / `uuid()` | `workflow.SideEffect` / SDK-provided deterministic random |
| Sleeping (`time.Sleep`) | `workflow.Sleep()` — a durable server-side timer |
| Direct I/O, HTTP, DB calls | Activities |
| Spawning threads/goroutines | SDK coroutines (`workflow.Go`) scheduled deterministically |
| Iterating maps in random order (Go) | Sort keys first; SDKs lint for this |
| Reading env vars/config that changes | Pass as workflow input or read via activity |
| Global mutable state | Workflow-local state only |

How a violation actually manifests: replay executes the code, and the commands the code emits are
matched against history. If the code (say) schedules activity `B` where history recorded activity
`A` scheduled, the SDK throws a **non-determinism error**; the workflow task fails and retries
forever until a human intervenes (or, with newer server versions, per-policy fails the workflow).
The insidious case is code that *was* deterministic but was changed by a deploy — see versioning
below.

---

## Interacting with Running Workflows

Three verbs, distinguished by direction and synchrony:

| | Direction | Synchronous? | Recorded in history? | Use for |
|---|---|---|---|---|
| **Signal** | write in | No (fire-and-forget, durable) | Yes | External events: "payment received", "human approved" |
| **Query** | read out | Yes | No (runs on worker against current state) | Dashboards, debugging: "what step are you on?" |
| **Update** | write in + read out | Yes (caller waits for result) | Yes | Validated mutations: "change quantity — reject if already shipped" |

- **Signals** are the workhorse. A workflow blocks on `await signal_received` for days; signals are
  durable — delivered even if no worker is running when sent. They cannot return a value.
- **Queries** must be read-only (they don't append history, so any state change would be lost) and
  cannot block.
- **Updates** (GA since 2024) close the gap: a synchronous call that runs a *validator* (can reject
  without touching history) then a handler that may mutate state and return a result. Before
  updates, people simulated this with signal + poll-query, which was clumsy and racy.

---

## Long-Running Patterns

### Durable Timers

`workflow.Sleep(30 * days)` creates a server-side timer task. No worker holds anything in memory;
the workflow is evicted, and 30 days later the timer fires, a workflow task is scheduled, and some
worker replays and continues. Timers are why "send a follow-up email in 45 days" is one line
instead of a cron + table.

### Child Workflows

A workflow can start child workflows — separate executions with their own history, ID, and
retention, linked to the parent. Use them to: partition a huge job (each child's history stays
small), get independent retry/timeout semantics per subtask, or cross task-queue/team boundaries.
Parent-close policy controls what happens to children if the parent dies (terminate, abandon,
request-cancel).

### Continue-As-New and the History Limit

Event history has hard limits (~50K events / 50MB per execution). A workflow that loops forever —
an entity workflow, a poller — would blow past it. **Continue-as-new** atomically completes the
current execution and starts a fresh one with the same workflow ID, passing forward carry-over
state as input. History resets; the logical workflow continues. Rule of thumb: any workflow with an
unbounded loop needs continue-as-new on a count or size threshold.

### The Entity Workflow Pattern

Model a long-lived business entity (a user's subscription, a shopping cart, an AI agent session)
as one workflow per entity ID, running indefinitely: block on signals, mutate state, occasionally
continue-as-new. The workflow ID *is* the entity key — Temporal guarantees at most one execution
per ID per namespace, giving you a free distributed lock / single-writer per entity.

---

## Evolving Workflow Code

The hardest operational problem in the model: workflows run for months, and you deploy weekly. A
code change that alters the sequence of commands breaks replay for every execution that started on
the old code.

### Patching (`patched()` / `GetVersion`)

The in-code mechanism. You branch on a patch marker:

```go
if workflow.GetVersion(ctx, "add-fraud-check", workflow.DefaultVersion, 1) == 1 {
    // new path: recorded in history for new executions
    err = workflow.ExecuteActivity(ctx, FraudCheck, order).Get(ctx, nil)
}
```

Old histories replay the old branch; new executions record and take the new one. Works, but
patches accumulate and must be garbage-collected in a later cleanup pass once old executions
drain.

### Worker Versioning (Pinned Deployments)

The infrastructure-level mechanism, GA as of 2025–26. Worker deployments carry a version; a
workflow can be **pinned** to the version it started on, so old executions keep routing to old
workers ("rainbow deploys" — multiple worker versions running side by side until their pinned
workflows drain), while new executions start on the new version. Removes the need for in-code
patches for short-to-medium-lived workflows; patching remains for workflows too long-lived to wait
for drain. (The earlier experimental build-ID versioning API was scrapped and replaced by this
model — worth knowing the current state in an interview.)

---

## Interview Angle

- **Lead with the boundary**: "orchestration in workflows, side effects in activities" — then show
  you know *why* (replay). Interviewers probe whether you'd put an HTTP call in workflow code.
- **Timeout literacy**: know that start-to-close is mandatory-in-practice and heartbeats are how
  long activities get fast failure detection + resumable progress.
- **Signal vs. update**: pre-2024 answers say "signal + query poll"; the current answer is update
  with validator. Shows currency.
- **Versioning is the senior question**: expect "you deployed new code and 10K workflows broke —
  what happened, and how do you prevent it?" Answer: non-determinism on replay; prevention:
  patching, worker versioning/pinning, replay tests in CI against sampled production histories.
