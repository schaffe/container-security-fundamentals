---
title: "Temporal Programming Model"
section: "Durable Execution"
order: 2
---

# Temporal Programming Model

## Overview

Temporal's API surface looks large at first — workflows, activities, signals, queries, updates,
timers, child workflows, continue-as-new, patching. But all of it is a thin veneer over a single
rule: **workflow code must be deterministic, and everything non-deterministic must go through the
server so it gets recorded in event history**. Every feature in this article is a disciplined
answer to the question "how do I do X without breaking replay?" If you keep that framing, the API
stops being a list to memorize and becomes a set of corollaries.

---

## Workflows vs. Activities: The Determinism Boundary

The first and most important design decision in any Temporal application is drawing the line
between workflow code and activity code.

A **workflow** is the orchestration logic: it decides what happens next, in what order, and under
what conditions. Because it is reconstructed by replay (as described in
[the fundamentals article](durable-execution-fundamentals.md#the-core-mechanism-event-sourcing-deterministic-replay)),
it must be deterministic, it cannot perform side effects directly, and in exchange it becomes
effectively immortal — it can run for years, and infrastructure failures cannot make it fail.

An **activity** is a single side-effecting operation: an HTTP call, a database write, an LLM
invocation. Activities are ordinary functions with no determinism requirement — they are where the
messy real world is allowed in. The price of that freedom is that activities can fail, will be
retried, and may execute more than once.

The two halves have opposite characters, and the contrast is worth having crisp:

| | Workflow code | Activity code |
|---|---|---|
| Determinism | Required | Not required |
| Side effects | Forbidden — only via activities | The whole point |
| Failure model | Cannot fail from infra errors; replays forever | Fails and is retried per policy |
| Duration | Unbounded (years) | Bounded by timeouts |
| Guarantee | State transitions effectively-once | Execution at-least-once |

### Activity Timeouts

Because activities interact with an unreliable world, every one of them needs at least one timeout
— without a timeout, an activity dispatched to a worker that then dies would simply hang forever,
and nothing would ever notice. Temporal gives you four knobs, which fit together like this:

```
 schedule ──────────────────────────────────────────► close
 │◄─────────────── schedule-to-close ───────────────►│
 │◄─ schedule-to-start ─►│◄────── start-to-close ───►│
                         │   ▲ heartbeat interval ▲   │
```

**Start-to-close** is the maximum duration of a single attempt, and it's the one you should always
set — it's what lets the server detect that an attempt died and schedule a retry.

**Schedule-to-start** bounds how long a task may sit in the queue before a worker picks it up. It
detects a starved worker fleet, though in practice most teams leave it unset and monitor the
corresponding latency metric instead.

**Schedule-to-close** is the total budget across all retries — "give up on this entirely after an
hour, however many attempts that took."

**Heartbeat timeout** matters for long-running activities. A single attempt that legitimately takes
an hour would otherwise leave the server blind for that whole hour: if the worker died five minutes
in, nobody would notice for fifty-five more. With a heartbeat timeout set, the worker must call
`heartbeat()` periodically, and the server declares the attempt dead within seconds of heartbeats
stopping. Better still, heartbeats can carry a progress payload, and the *last recorded payload is
handed to the retry attempt* — so a file-processing activity that dies at record 1,400,000 can
resume from there instead of from zero.

Alongside the timeouts, each activity declares a **retry policy**: initial retry interval, backoff
coefficient, maximum attempts, and a list of error types that should *not* be retried (an invalid
credit card will not become valid on the fifth attempt; a `ServiceUnavailable` will). The server
drives all of this. From the workflow's point of view there is just one awaited call that
eventually produces a result or a final failure.

One more thing belongs in this section because it belongs in every section: **idempotency lives in
activities**. The server guarantees at-least-once execution — an activity can succeed and crash
before acknowledging, then run again. Design activities so that running twice is harmless,
typically via an idempotency key derived from the workflow ID and the activity's identity.

---

## Determinism Constraints and Replay

What does "workflow code must be deterministic" actually forbid? Anything that could produce a
different answer when the code is re-executed during replay. The banned list, with the sanctioned
replacement for each:

| Banned in workflow code | Use instead |
|---|---|
| `time.Now()` / `Date.now()` | `workflow.Now()` — a deterministic timestamp taken from history |
| `rand()` / `uuid()` | `workflow.SideEffect` or the SDK's deterministic random |
| `time.Sleep()` | `workflow.Sleep()` — a durable, server-side timer |
| Direct I/O, HTTP, database calls | Activities |
| Spawning raw threads/goroutines | SDK coroutines (`workflow.Go`) scheduled deterministically |
| Iterating a map in random order (Go) | Sort the keys first; the SDK linters catch this |
| Reading env vars or config that can change | Pass as workflow input, or fetch via an activity |
| Global mutable state | Workflow-local state only |

It's worth understanding how a violation actually surfaces, because it's subtler than "the program
crashes." During replay, the SDK re-executes your code and matches the *commands* it emits against
what history recorded. Suppose the original run scheduled activity `A`, but on replay — because of
a random branch, or a code change — the code schedules activity `B` instead. The commands no longer
match history, the SDK throws a **non-determinism error**, and the workflow task fails and retries
indefinitely until a human intervenes.

That loud failure is actually the *lucky* case. The insidious case is a violation that doesn't
change which commands are emitted — say, a branch on the real wall clock, `if now > deadline`,
that silently takes the other path on replay. Nothing errors; your workflow's state is just quietly
wrong. Non-determinism is both a crash bug and a correctness bug, and only the crash variety
announces itself.

The most common source of non-determinism in practice isn't `rand()` — it's deploying new code
while old workflows are mid-flight. That problem gets its own section below.

---

## Interacting with Running Workflows

A workflow that runs for weeks is not much use if nothing outside can talk to it. Temporal gives
you three verbs, distinguished by direction and synchrony.

A **signal** writes information *into* a running workflow, fire-and-forget. Signals are the
workhorse of long-running workflows: the code blocks on "wait for the `payment_received` signal"
for days, and when some external system sends it, the workflow wakes and continues. Signals are
durable — if no worker is running when one is sent, it is recorded in history and delivered when
the workflow next executes. What signals cannot do is return a value to the sender.

A **query** reads information *out* of a running workflow, synchronously: "what step are you on?"
Queries run on a worker against the workflow's current state and are *not* recorded in history —
which is exactly why they must be read-only. Any state a query handler mutated would never be
recorded and would evaporate on the next replay. Queries are for dashboards and debugging.

An **update** (generally available since 2024) does both: it writes into the workflow *and*
returns a result to the caller, synchronously. An update runs a *validator* first — which can
reject the request without touching history at all — and then a handler that may mutate workflow
state and return a value. The canonical use case is a validated mutation like "change the order
quantity, but reject if it already shipped." Before updates existed, people simulated this with a
signal followed by a polling query, which was clumsy and racy; knowing that updates replaced that
pattern is a small but effective currency signal in interviews.

| | Direction | Synchronous? | In history? | Typical use |
|---|---|---|---|---|
| **Signal** | in | No | Yes | "Payment received", "human approved" |
| **Query** | out | Yes | No | "What step are you on?" |
| **Update** | in + out | Yes | Yes | "Change quantity — reject if shipped" |

---

## Long-Running Patterns

### Durable Timers

`workflow.Sleep(30 * days)` creates a timer *on the server*, as durable state. No worker holds
anything in memory for those thirty days — the workflow is evicted from worker caches entirely.
When the timer fires, the server schedules a workflow task, some worker replays the workflow, and
the code continues from the line after the sleep. This is why "send a follow-up email in 45 days"
is one line of code in Temporal, versus a scheduled-jobs table, a cron sweep, and a recovery story
everywhere else.

### Child Workflows

A workflow can start other workflows as children — separate executions with their own event
histories, their own IDs, and their own retention, linked to the parent. Children are the tool for
three situations: partitioning a huge job so no single execution's history grows unmanageably,
giving a subtask independent retry and timeout semantics, and crossing task-queue or team
boundaries. A *parent close policy* controls what happens to children when the parent goes away:
terminate them, abandon them to run free, or request cancellation.

### Continue-As-New and the History Limit

Event history is not free — it has hard limits, roughly 50,000 events or 50MB per execution. A
workflow that loops forever, like an entity workflow or a poller, would eventually blow past them,
and long before that its replays would grow slow. **Continue-as-new** is the escape valve: it
atomically completes the current execution and starts a fresh one with the same workflow ID,
passing whatever state matters forward as the new execution's input. The history resets to empty;
the logical workflow continues. The rule of thumb: any workflow with an unbounded loop needs a
continue-as-new check on an iteration count or history-size threshold.

### The Entity Workflow Pattern

Combine everything above and you get one of Temporal's most useful idioms. Model a long-lived
business entity — a user's subscription, a shopping cart, an AI agent session — as a single
workflow per entity ID that runs indefinitely: it blocks on signals, mutates its local state in
response, and occasionally continue-as-news to keep history bounded. The workflow ID *is* the
entity key, and because Temporal guarantees at most one open execution per ID per namespace, you
get a single-writer guarantee — effectively a free distributed lock — per entity.

---

## Evolving Workflow Code

Here is the hardest operational problem in the whole model, stated plainly: workflows run for
months, and you deploy every week. Replay re-executes *today's code* against *history recorded by
last month's code*. If your change alters the sequence of commands the code emits — reordering two
activities, adding a new one in the middle — then every execution that started on the old code
will hit a non-determinism error the next time it replays. Deploying a innocent-looking change can
break ten thousand in-flight workflows at once.

Temporal offers two mechanisms, one in code and one in infrastructure.

### Patching (`patched()` / `GetVersion`)

The in-code mechanism is to branch on a patch marker:

```go
if workflow.GetVersion(ctx, "add-fraud-check", workflow.DefaultVersion, 1) == 1 {
    // new path: recorded for new executions
    err = workflow.ExecuteActivity(ctx, FraudCheck, order).Get(ctx, nil)
}
```

Executions whose histories predate the patch replay down the old branch; new executions record the
marker and take the new one. Both populations run correctly on the same deployed code. The cost is
hygiene: patches accumulate, and each one must eventually be garbage-collected in a follow-up
change once the old executions have drained.

### Worker Versioning (Pinned Deployments)

The infrastructure-level mechanism, generally available as of 2025–26, moves the problem out of
your code entirely. Worker deployments carry a version, and a workflow can be **pinned** to the
version it started on. Old executions keep routing to old-version workers while new executions
start on the new version — so you run multiple worker versions side by side ("rainbow deploys")
until the pinned workflows drain, then retire the old version. This removes the need for in-code
patches for short- and medium-lived workflows. Patching remains necessary for workflows too
long-lived to wait out a drain.

One historical note worth knowing: Temporal's earlier experimental "build ID" versioning API was
scrapped and replaced by this deployment-pinning model. Interviewers at Temporal will know the
current state; an answer citing the dead API dates you.

---

## Interview Angle

- **Lead with the boundary.** "Orchestration in workflows, side effects in activities" — and then
  show you know *why*: replay. A favorite probe is whether you'd put an HTTP call directly in
  workflow code; the answer is never, and the reason is the mechanism, not a style rule.
- **Timeout literacy.** Start-to-close is mandatory in practice; heartbeats are how long
  activities get fast failure detection and resumable progress. Being fluent here signals
  production experience.
- **Signal vs. update.** The pre-2024 answer to "synchronous validated mutation" was signal plus
  polling query; the current answer is an update with a validator. Giving the current answer shows
  currency.
- **Versioning is the senior question.** Expect some form of "you deployed new code and 10,000
  workflows broke — what happened, and how do you prevent it?" The answer: non-determinism on
  replay; prevented by patching or worker versioning with pinning, and caught in CI by replay
  tests against sampled production histories.
