---
title: "Durable Execution Fundamentals"
section: "Durable Execution"
order: 1
---

# Durable Execution Fundamentals

## Overview

Imagine writing a program that says: charge the customer's card, wait thirty days, then send them
a review request. Three lines of code. Now imagine that program actually running for thirty days —
across deploys, server crashes, and network outages — and still finishing correctly, picking up
exactly where it left off no matter what died underneath it.

That is durable execution: a programming model in which the full execution state of a program
survives any crash. The code looks like ordinary sequential code, but the runtime guarantees it
runs to completion even if every machine involved is replaced along the way.

It's worth stressing that durable execution is a *category* of system, not a single product.
Temporal is the best-known implementation, but the same idea appears in Cadence, Azure Durable
Functions, Restate, DBOS, and Inngest. What matters — especially in an interview — is understanding
the underlying mechanism, which is the same everywhere: event sourcing combined with deterministic
replay. Once you understand that mechanism, every vendor's API becomes a thin skin over it.

---

## The Problem It Solves

Any business process that spans multiple steps and outlives a single request eventually hits the
same wall: partial failure. Consider order fulfillment. The happy path is simple — charge the card,
reserve inventory, ship the package, email the customer. But what happens when the process crashes
after charging the card and before reserving inventory? The customer has paid for something that
nobody is going to ship.

The way most teams handle this — because it's the natural first design — is to scatter the
process's state across several pieces of infrastructure. There's a status column in the database
("this order is in state PAID"). There's a message queue carrying "do the next step" messages.
There's a cron job that periodically sweeps for orders stuck in intermediate states. There are
retry tables and dead-letter queues for steps that failed.

Look at what has happened here: the actual state machine — the answer to "where is order 4711 in
its lifecycle, and what happens to it next?" — no longer exists anywhere as a coherent thing. It
exists only implicitly, spread across status columns, in-flight queue messages, and the logic of
sweeper jobs. And every failure mode needs its own hand-written recovery path:

- If the process crashes between steps two and three, you need a reconciliation job to find the
  orphaned orders and push them forward.
- If the payment succeeded but the database write recording it failed, you need idempotency keys
  and deduplication logic so the retry doesn't charge the customer twice.
- If step three must happen thirty days after step two, you need a durable timer — which in this
  world means yet another table and yet another cron job.
- If a later step fails and an earlier step must be undone (refund the charge because shipping
  fell through), you need hand-rolled compensation logic.

Each of these pieces is individually simple. The composition is where systems rot: five simple
mechanisms interacting produce failure modes nobody designed for, and the team ends up maintaining
a distributed state machine that was never written down.

Durable execution collapses all of this into one abstraction. The workflow *is* the state machine,
expressed directly as code, and the platform makes the code's execution state durable. Here is the
entire order lifecycle, crash-proof:

```python
async def order_workflow(order):
    charge = await execute_activity(charge_card, order)      # retried until success
    try:
        await execute_activity(reserve_inventory, order)
        await execute_activity(ship, order)
    except ApplicationError:
        await execute_activity(refund, charge)                # saga compensation
        raise
    await sleep(timedelta(days=30))                           # durable timer
    await execute_activity(send_review_request, order)
```

If the worker process running this code dies at any line, another worker picks it up and continues
from that exact line — with all local variables intact. The retry logic, the durable timer, the
compensation-on-failure, and the "where is this order?" question are all just... the code.

The natural reaction to that claim is disbelief. How can local variables survive the death of the
process that held them? That's the interesting part.

---

## The Core Mechanism: Event Sourcing + Deterministic Replay

The trick is *not* checkpointing memory. No durable execution engine serializes your process's
heap and ships it somewhere. Instead, the engine records every **non-deterministic decision** the
workflow makes — every activity result, every timer, every random number — as an event in an
append-only log. For the order workflow above, the log looks like this:

```
1  WorkflowExecutionStarted   {input: order-4711}
2  ActivityTaskScheduled      {activity: charge_card}
3  ActivityTaskCompleted      {result: charge-991}
4  ActivityTaskScheduled      {activity: reserve_inventory}
5  ActivityTaskCompleted      {result: ok}
6  TimerStarted               {duration: 30d}
...
```

Now suppose the worker crashes at event six, with twenty-nine days left on the timer. How does a
fresh worker — a process with no memory of this workflow at all — resume from that point?

It **re-executes the workflow function from the beginning**. That sounds wasteful and dangerous
(surely re-running the code would charge the card again?), but here is the key: during this
re-execution, called *replay*, the SDK intercepts every call that previously produced an event.
When the code reaches `execute_activity(charge_card, ...)`, the SDK does not call the payment
service — it sees that history already contains the result (`charge-991`) and feeds that recorded
result straight back to the code. The code assigns it to `charge` and moves on, exactly as it did
the first time.

So the code deterministically retraces its own footsteps, rebuilding all of its local state —
variables, loop counters, its position in the control flow — until it reaches the first point that
has no recorded event. That point is precisely where the old worker died, and from there the code
continues live, producing new events. Replay is how a program's "memory" survives without anyone
ever saving its memory: the memory is reconstructed from the decision log every time it's needed.

This mechanism imposes the one iron rule of the model: **workflow code must be deterministic**.
Replay only works if the code, given the same history, makes the same decisions in the same order
every time. If the code called `random()` or read the wall clock directly, replay would diverge
from the recorded history and the reconstruction would be wrong. So anything non-deterministic —
side effects, clock reads, randomness, network calls — must be pushed out of the workflow and into
**activities**: ordinary functions that may fail and be retried, and whose *results* are what gets
recorded in the log.

Two consequences of this design are worth internalizing, because they define the guarantees you
actually get:

**Workflow state transitions are effectively-once.** The event log is the source of truth, written
with transactional guarantees, and replay reconstructs identical state from it. The workflow's
*decisions* never happen twice.

**Activity execution is at-least-once.** An activity can run, succeed, and then crash before
reporting its completion back to the server. The server, seeing no completion, will retry it — and
the side effect happens again. The platform cannot prevent this; the effect already escaped into
the outside world before anyone knew the report was lost. This is why activities must be written to
be **idempotent**: safe to run more than once. The platform makes its own state exactly-once; making
your side effects safe under retry is your job, and no platform can do it for you.

### Workflow-as-Code vs. Workflow-as-DSL

There is an older answer to workflow orchestration: express the workflow as a declarative state
machine — a JSON or XML document — and have an engine interpret it. BPMN engines work this way, and
so does AWS Step Functions.

Durable execution makes a different bet: that real business logic — loops, conditionals, error
handling, data transformation — is better expressed in a general-purpose programming language,
where you get native control flow, a debugger, unit tests, and code review for free. The cost of
that bet is the determinism constraint described above. The payoff is that a forty-state JSON
document becomes forty lines of readable code.

---

## Where It Came From: SWF → Cadence → Temporal

The model has a direct genealogy, and knowing it explains a lot about why Temporal looks the way
it does.

In 2012, AWS launched **Simple Workflow Service (SWF)**, which introduced the core ideas: task
lists, decision tasks, and the replay model. The ideas were right but the API was too low-level,
and adoption stayed niche.

In 2016, two of SWF's engineers — Maxim Fateev and Samar Abbas — rebuilt the model as an
open-source project at Uber, called **Cadence**. Cadence added the thing SWF lacked: workflow-as-code
SDKs that made the replay model pleasant to program against. It ran on Cassandra, supported
multi-tenant clusters, and proved the model at serious scale, powering Uber's driver payments and
trip processing.

In 2019, Fateev and Abbas forked Cadence to found **Temporal** as a company — same architectural
lineage, rewritten internals, plus a commercial cloud offering. Cadence still exists as an
independent Uber-led project, but Temporal is where the ecosystem's momentum went.

The through-line matters: the sharded history service, the matching service with long-poll
dispatch, the event-sourced workflow state — these ideas carried through the entire lineage and
were battle-tested at Uber scale before Temporal existed as a product.

---

## The Landscape in 2026

Temporal is not the only game in town, and the alternatives are best understood as different
answers to one question: how much operational weight are you willing to carry for how much scale?

| System | Model | Operational weight | Sweet spot |
|---|---|---|---|
| **Temporal** | Workflow-as-code, replay-based; SDKs in Go, Java, TypeScript, Python, .NET, Ruby, PHP | Heavy: a four-service cluster plus a database plus your worker fleet (or Temporal Cloud) | Complex, long-lived, high-value workflows at proven scale |
| **Cadence** | Same model (common ancestor) | Same shape as Temporal | Shops already in the Uber ecosystem |
| **DBOS** | A library, not a server — durability via Postgres transactions in your own process | Minimal: one database, one deploy | Postgres-centric apps that want durability without new infrastructure |
| **Restate** | Log-based server; durable RPC and virtual objects | Light: a single binary | Latency-sensitive durable services |
| **Inngest** | Step functions over an event bus, serverless-first | Near zero (SaaS) | Product teams on serverless; AI-step orchestration |
| **Azure Durable Functions** | Replay-based, same mechanism as Temporal | Managed | Azure-native shops |
| **AWS Step Functions** | Declarative JSON state machine — not durable *code* | Zero | Simple linear flows glued to AWS services |

The recurring trade-off across this table: Temporal's operational weight buys proven horizontal
scale and the richest programming model, while the lightweight entrants bet that most teams never
need that scale. DBOS argues that a single Postgres instance carries you much further than people
assume, so durable execution should be a library rather than a cluster. Restate attacks latency —
its log sits directly in the request path, replacing several of Temporal's round trips. Step
Functions concedes the programming model entirely in exchange for being fully serverless. None of
these positions is wrong; they target different points on the scale-versus-operability curve, and
being able to argue for each is exactly the kind of judgment interviews probe for.

### Why AI Agents Became the Killer Workload

Since around 2024, the fastest-growing workload on durable execution platforms has been AI agent
orchestration — and once you see why, it feels inevitable. An agent loop is precisely the
pathological case this model was built for. It runs for a long time. It makes many external calls
— to LLM APIs and tools — each of which is slow, rate-limited, and flaky. It pauses for human
approval for unbounded stretches. And its partial progress is genuinely expensive: an agent that
has paid for thirty LLM calls must resume after a crash, not start over and pay for them again.

"Retry the one failed LLM call, don't rerun the whole forty-step agent session" is durable
execution's value proposition stated verbatim. Temporal has reported that AI-native companies
generate a dominant share of new cloud usage, and every competitor — Inngest, Restate, DBOS — now
leads its marketing with agent orchestration.

---

## Interview Angle

When this topic comes up in a senior-level interview, these are the signals to hit:

- **Name the mechanism precisely.** It's event sourcing of non-deterministic decisions plus
  deterministic replay — not "checkpointing," not "saving memory snapshots." Getting this right is
  the difference between having used the tool and understanding it.
- **State the guarantee split unprompted.** Workflow state transitions are effectively-once;
  activity execution is at-least-once; therefore activities must be idempotent. Volunteering this
  before being asked shows you know where the model's edges are.
- **Frame it as a consolidation play.** Durable execution replaces the queue + status-column +
  cron + reconciliation-job stack with a single primitive. Then be ready to argue when that trade
  is *not* worth it: simple request/response services, extreme low-latency paths, or teams
  unwilling to operate the cluster.
- **Know the lineage** — SWF to Cadence to Temporal, same founders throughout. It explains why the
  architecture looks the way it does, and in a Temporal interview it signals genuine familiarity
  rather than a weekend of docs-skimming.
