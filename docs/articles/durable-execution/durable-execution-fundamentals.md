---
title: "Durable Execution Fundamentals"
section: "Durable Execution"
order: 1
---

# Durable Execution Fundamentals

## Overview

Durable execution is a programming model where the full execution state of a program survives any
crash — process death, node failure, deploy, network partition — and resumes exactly where it left
off. The application code looks like ordinary sequential code ("call service A, wait 30 days, call
service B"), but the runtime guarantees it runs to completion even if every machine involved is
replaced along the way.

It is a *category*, not a single product. Temporal is the best-known implementation, but the same
idea appears in Cadence, Azure Durable Functions, Restate, DBOS, and Inngest. Understanding the
mechanism — event sourcing plus deterministic replay — matters more than any one vendor's API.

---

## What Problem It Solves

Any multi-step business process that outlives a single request hits the same wall: partial failure.
Consider order fulfillment — charge the card, reserve inventory, ship, email the customer. The
naive implementation scatters state across five systems:

```
┌──────────┐   ┌───────┐   ┌──────────┐   ┌──────────┐
│ DB rows   │  │ Queues │  │ Cron jobs │  │ Retry     │
│ (status   │  │ (next  │  │ (sweep    │  │ tables +  │
│  columns) │  │  step) │  │  stuck    │  │ dead-letter│
│           │  │        │  │  orders)  │  │ queues    │
└──────────┘   └───────┘   └──────────┘   └──────────┘
```

The actual state machine — "where is order 4711 in its lifecycle?" — exists only implicitly, spread
across status columns, in-flight queue messages, and sweeper cron jobs. Every failure mode needs
hand-written recovery:

- **Process crashes between step 2 and 3** — need a reconciliation job to find orphans.
- **Payment succeeded but the DB write failed** — need idempotency keys and dedup logic.
- **Step 3 must happen 30 days after step 2** — need a durable timer, so another table + cron.
- **Compensation on failure** (refund the charge if shipping fails) — hand-rolled saga logic.

Each piece is individually simple; the composition is where systems rot. Durable execution
collapses all of it into one abstraction: the workflow *is* the state machine, expressed as code,
and the platform makes the code's execution state durable.

```python
# The entire order lifecycle, crash-proof:
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

If the worker running this dies at any line, another worker picks up and continues from that exact
line — with all local variables intact.

---

## The Core Mechanism: Event Sourcing + Deterministic Replay

The trick is *not* checkpointing memory. Durable execution engines record every **non-deterministic
decision** the workflow makes as an event in an append-only log:

```
1  WorkflowExecutionStarted   {input: order-4711}
2  ActivityTaskScheduled      {activity: charge_card}
3  ActivityTaskCompleted      {result: charge-991}
4  ActivityTaskScheduled      {activity: reserve_inventory}
5  ActivityTaskCompleted      {result: ok}
6  TimerStarted               {duration: 30d}
...
```

To recover after a crash, the engine **re-executes the workflow function from the beginning** on a
fresh worker. Every time the code reaches a point that previously produced an event (an activity
call, a timer, a random number), the SDK doesn't re-perform the side effect — it feeds back the
recorded result from history. The code deterministically retraces its own steps until it reaches
the first point with no recorded event, and from there continues live.

This imposes the one iron rule of the model: **workflow code must be deterministic**. Same history
in, same decisions out. Side effects, wall-clock reads, randomness, and iteration-order-dependent
logic must be pushed into **activities** — ordinary functions that may fail and be retried, whose
*results* are what gets recorded.

Two consequences worth internalizing:

1. **Workflow state transitions are effectively-once.** The event log is the source of truth,
   written with transactional guarantees; replay reconstructs identical state.
2. **Activity execution is at-least-once.** An activity may run, succeed, and crash before
   reporting completion — the engine will retry it. Activities must be idempotent; the platform
   cannot make external side effects exactly-once for you.

### Workflow-as-Code vs. Workflow-as-DSL

The older generation of orchestrators (BPMN engines, AWS Step Functions) expresses workflows as
declarative state machines — JSON/XML documents interpreted by the engine. Durable execution's bet
is that real business logic (loops, conditionals, error handling, data transformation) is better
expressed in a general-purpose language with its native control flow, debugger, and test tooling.
The cost is the determinism constraint; the payoff is that a 40-state JSON document becomes 40
lines of readable code.

---

## Lineage: SWF → Cadence → Temporal

The model has a direct genealogy:

| Year | System | Contribution |
|---|---|---|
| 2012 | **AWS Simple Workflow (SWF)** | Introduced task lists, decision tasks, and the replay model; API too low-level for adoption |
| 2016 | **Cadence** (Uber) | Maxim Fateev and Samar Abbas (both ex-SWF) rebuilt the model as OSS: workflow-as-code SDKs, Cassandra persistence, multi-tenant clusters. Ran Uber's driver payments, trip processing |
| 2019 | **Temporal** | Fateev and Abbas forked Cadence into a company. Same architecture lineage, rewritten internals, commercial cloud offering |

Cadence proved the model at scale and still exists as an independent Uber-led project; Temporal is
where the ecosystem's momentum went. The core architecture ideas — sharded history service, matching
service with long-poll dispatch, event-sourced workflow state — carried through the whole lineage.

---

## The Landscape (2026)

| System | Model | Persistence | Operational weight | Sweet spot |
|---|---|---|---|---|
| **Temporal** | Workflow-as-code, replay-based; polyglot SDKs (Go, Java, TS, Python, .NET, Ruby, PHP) | Cassandra / MySQL / Postgres + Elasticsearch for visibility | Heavy: 4-service cluster + DB + your worker fleet (or Temporal Cloud) | Proven scale (Uber-lineage; Snap, Netflix, Stripe, Coinbase); complex, long-lived, high-value workflows |
| **Cadence** | Same model (common ancestor) | Cassandra / SQL | Same shape as Temporal | Existing Uber-ecosystem shops |
| **DBOS** | Library, not server: durable execution as Postgres transactions in-process | Postgres only | Minimal — "one database, one deploy" | Postgres-centric apps that want durability without new infrastructure |
| **Restate** | Log-based sidecar/server; durable RPC + virtual objects | Own embedded log (RocksDB-based) | Light single binary | Latency-sensitive durable services, event-driven state machines |
| **Inngest** | Step functions over an event bus, serverless-first | Managed | Near-zero (SaaS) | Product teams on serverless; AI/agent step orchestration |
| **Azure Durable Functions** | Replay-based (same mechanism), C#/JS on Azure Functions | Azure Storage / Durable Task Scheduler | Managed | Azure-native shops |
| **AWS Step Functions** | Declarative JSON state machine (not durable *code*) | Managed | Zero | AWS-native glue, simple linear flows |

The recurring trade-off: **Temporal's operational weight buys proven horizontal scale and the
richest programming model; the lightweight entrants bet most teams don't need that scale.** DBOS
argues a single Postgres carries you further than people think; Restate attacks latency (its log
sits in the request path, replacing several Temporal round-trips); Step Functions concedes the
programming model to stay serverless.

### Why AI Agents Became the Killer Workload

Since ~2024 the fastest-growing durable-execution workload is AI agent orchestration. An agent loop
is precisely the pathological case the model was built for: long-running, many external calls
(LLM APIs, tools) each of which is slow and flaky, human-in-the-loop pauses of unbounded duration,
and expensive partial progress you cannot afford to lose. "Retry the failed LLM call, don't rerun
the whole 40-step agent session" is durable execution's value proposition verbatim. Temporal
reported that AI-native companies generate a dominant share of new cloud usage, and every
competitor (Inngest, Restate, DBOS) now leads with agent-orchestration messaging.

---

## Interview Angle

Senior-level signals to hit when this topic comes up:

- **Name the mechanism precisely**: event sourcing of non-deterministic decisions + deterministic
  replay — not "checkpointing", not "saving memory snapshots".
- **State the guarantee split unprompted**: workflow state transitions effectively-once, activity
  execution at-least-once, therefore activities must be idempotent.
- **Frame it as a consolidation play**: durable execution replaces the queue + status-column +
  cron + reconciliation-job stack with one primitive. Be ready to argue when that trade is *not*
  worth it (simple request/response services, extreme low-latency paths, teams unwilling to
  operate the cluster).
- **Know the lineage** (SWF → Cadence → Temporal, same founders) — it explains why the
  architecture looks the way it does and signals genuine familiarity in a Temporal interview.
