---
title: "System Design: Distributed Cron"
section: "Durable Execution"
order: 10
---

# System Design: Distributed Cron

## Overview

"Design distributed cron" is the compact cousin of the
[workflow-engine question](design-a-workflow-engine.md): users register schedules — "run job J
every five minutes," "at 02:00 daily" — and the system fires them reliably across a fleet where no
machine is special and any node can die, yet each tick must fire exactly once.

The state involved is tiny — a schedule is a few hundred bytes — and that smallness fools
candidates into thinking the problem is small. It isn't. The hard parts are *exactly-one-firing*
across many nodes, *missed ticks* when the whole system was down over a fire time, and
*overlapping runs* when a job outlives its own interval. This article builds the design
iteratively, then walks the deep-dive prompts. Temporal's
[Schedules](multi-cluster-nexus-advanced.md#schedules-and-cron) serve as the reference
implementation throughout — not because they're the only answer, but because they have explicit
answers exactly where hand-rolled designs go vague.

## Key Insight

A schedule is **durable state with a timer, not a process**. The instinctive framing — "which node
runs the cron loop?" — is the wrong question, and designs built on it inherit its wrongness. The
right question is: where does the schedule's state live, and who is allowed to write it?

Give each schedule a **single fenced writer** — one owner at a time, whose writes are conditional
on an ownership token — and "which node fires the tick?" stops being a coordination problem and
becomes a placement detail. Firing a tick is then just a state transition: read the next fire
time, append "tick N fired," start the job, compute the next fire time. Everything else the
problem demands — catch-up, overlap handling, backfill, pause — is policy layered on that one
transition.

---

## Requirements and API Sketch

Functional requirements:

- CRUD on schedules, with interval or calendar (cron-expression) specs; a schedule triggers an
  *action* — start job J with input X.
- Each due tick fires **exactly once** across the fleet — never zero times, never twice.
- An explicit policy for **missed ticks** (the system was down over a fire time): run late, or
  skip?
- An explicit policy for **overlap** (the previous run is still going when the next tick is due).
- Pause and resume; manual "run now"; **backfill** over a historical time range.
- Auditability: "did tick N fire, and what happened to the run it started?" must be answerable.

Non-functional:

- Scale on the order of a million schedules, mostly minutes-to-daily cadence. Note one property up
  front: fire-time load is *spiky by nature*, because humans schedule things at :00 — peak
  alignment is a feature of the domain, not an accident.
- A tick may fire seconds late; it must never be silently lost. Like the workflow engine, this is
  a state system where durability outranks latency — and saying so explicitly licenses the
  trade-offs to come.

```
CreateSchedule(id, spec, action, policies) -> handle     Pause(id) / Unpause(id)
UpdateSchedule(id, spec/policies)                        TriggerNow(id)
DescribeSchedule(id) -> spec, next ticks, recent runs    Backfill(id, from, to, overlap_policy)
```

---

## Iterative Design

### v1: Crontab on Every Node, Plus a Lock

The instinctive design: every node loads all the schedules, evaluates the cron specs each minute,
and the nodes race for a distributed lock — a Redis `SETNX`, a lock row — before firing. Whoever
wins the lock fires the tick.

Three failures, one of them fatal.

The fatal one: **locks don't give you exactly-once.** Walk the crash timings. Node A takes the
lock, fires the job, and dies before recording that it fired — the lock expires, node B acquires
it, sees no record, and fires again. Two firings. Or: node A takes the lock and dies *before*
firing — the tick is lost until someone notices. Zero firings. A lease-based lock bounds
*concurrency*; it says nothing about *effects*. Unless the act of firing is a conditional write
against durable schedule state, you get at-most-once or at-least-once, selected by crash timing.

The other two: every node parses every spec every minute — O(nodes × schedules) work for the
privilege of mostly losing lock races — and there is **no memory of missed ticks**. If the whole
fleet is down from 01:58 to 02:03, the 02:00 tick never existed anywhere. Single-machine cron has
this bug too; distributing it didn't fix it.

### v2: Central Store, Polling Workers

Move the state into a database: rows of `(schedule_id, spec, next_fire_at, paused, ...)`. A
worker fleet polls: `SELECT ... WHERE next_fire_at <= now() FOR UPDATE SKIP LOCKED`, fires,
computes and writes the next fire time.

This is genuine progress — the firing and the state now change together, and a fleet outage
leaves `next_fire_at` sitting in the past, so missed ticks are at least *visible* on recovery.
But three holes remain:

1. **The dual write.** Firing means starting a job in some other system *and* updating the row.
   Crash between the two and you're back to lost-or-duplicated ticks. The fix — and it will carry
   into v3 — is an outbox: record "tick N fired, start job" in the same transaction that advances
   `next_fire_at`, deliver the start at-least-once, and dedupe downstream on
   `(schedule_id, tick_N)` as the idempotency key.
2. **The database is the timer.** Polling the world burns the database and floors precision at
   the poll interval — and the hot `next_fire_at` index becomes a contention point at exactly the
   :00 spikes the domain guarantees.
3. **Row locks are still locks.** `SKIP LOCKED` serializes per row, but ownership is per-tick and
   transient. There's no stable writer per schedule — and overlap policy, which needs to reason
   about the *previous* run's status when deciding about the next tick, requires exactly that
   stable writer to avoid races.

### v3: Sharded Single-Writer Owners, Per-Shard Timer Queues

This is the durable-execution shape, and it's where having internalized the
[workflow-engine design](design-a-workflow-engine.md) pays rent — the skeleton is identical.

**Shard the schedules**: `hash(schedule_id) % N`, each shard owned by exactly one node at a time,
placement via a membership ring, and — the load-bearing part — **correctness via fencing**. The
owner holds an epoch (a range ID), and every write for the shard is conditional on it at the
store. A stale owner's fires fail at the database, not at a lock server. This is
[the same mechanism as Temporal's history shards](history-service-internals.md#history-shards).

**Timers live with the shard**: each schedule's next fire time is a timer task in the shard's
persisted priority queue, and the shard's processor sleeps until the head deadline. No global
scan, no polling; timer capacity scales with shard count
([timers at scale](history-service-internals.md#timers-at-scale)).

**Firing is one conditional transition**: append `TickFired(N)`, write the action's outbox
record, and write the next timer task — all in one write, conditional on the fencing token. And
now exactly-one-firing simply *falls out*: if two would-be owners race, one write commits and the
other fails its condition and re-reads, discovering tick N already fired. This is exactly why
Temporal Schedules get the classic hard part for free — a schedule lives on one shard, so
["which node fires the tick?" never arises](multi-cluster-nexus-advanced.md#schedules-and-cron).

With that skeleton in place, the cron-specific policies become small, explicit state machines
layered on the firing transition:

- **Catch-up window** (missed ticks): on recovery, the owner finds fire times in the past. Ticks
  within the window — say, an hour — fire late; older ones are recorded as skipped. Which
  behavior you want is per-schedule semantics: "send the daily report" should catch up, while
  "poll for new files every minute" should collapse the backlog into one run. Making this a
  per-schedule knob rather than a global guess is the point.
- **Overlap policies**: what happens when the previous run is still going? Enumerate all six —
  skip the new tick; buffer one (run it when the current run ends, collapsing further ticks);
  buffer all; cancel the running one; terminate the running one; allow parallel. Note *why* these
  are implementable at all: only a single writer that sees both the tick and the previous run's
  completion as serialized transitions on the same state can enforce any of them without races.
- **Jitter**: spread each schedule's fire time within a small window to break the :00 thundering
  herd — ten thousand "hourly" schedules shouldn't hit downstream as one spike. Make the jitter
  deterministic (hash the schedule ID) so a schedule's offset stays stable across ownership
  changes.
- **Backfill**: replay a historical range as synthetic ticks through the *same* firing path, with
  an explicit overlap policy, since a backfill is a deliberate herd. Reusing the tick machinery
  means backfilled runs get the same audit records as real ones.
- **Pause/resume**: a bit on the schedule state, checked at fire time. Paused ticks are recorded
  as skipped, not silently swallowed — so resume can decide whether they fall in the catch-up
  window.
- **Observability**: the per-schedule event log *is* the answer to "did tick N fire?" Every due
  tick becomes an appended event with an outcome — fired, skipped-for-overlap, skipped-paused,
  skipped-outside-catch-up — and a pointer to the run it started. Recent runs and the next N
  ticks fall out of `Describe`; listing is served by a search projection, which is eventually
  consistent, and you should say so.

```
API gateway (stateless, routes by hash(schedule_id))
   │
Schedule owner shards (schedule state + tick log + timer queue + outbox; single fenced writer)
   │  fire actions (outbox, at-least-once, deduped on (schedule_id, tick))
Job execution layer (workers / workflow engine — owns retries, timeouts, run status)
   │
Stores: state store (conditional point writes)  |  search projection (async)
```

One boundary worth drawing aloud: cron owns *when and whether* to start a run; the execution
layer owns *how the run goes* — retries, timeouts, heartbeats. If the interviewer lets you, make
the action "start a workflow" and inherit the entire
[workflow engine](design-a-workflow-engine.md). Temporal literally builds Schedules this way — as
system state on the same timer and shard machinery as workflows.

---

## Deep-Dive Prompts Interviewers Pull

**"Two scheduler nodes both think they own a schedule — what fires?"**
This prompt is fishing for leader-election hand-waving; don't bite. The answer: both may *try*,
and exactly one fires. Ownership is fenced — every transition is a conditional write checked
against the owner's epoch, so the stale node's `TickFired(N)` append fails at the store, it
re-reads, and it finds tick N already fired. The membership ring is a routing optimization; **the
database condition is the guarantee** — the
[same answer as for history shards](history-service-internals.md#history-shards). Leader election
without fencing just recreates v1's lock with more machinery.

**"The whole cluster was down from 01:55 to 02:20. What happens to the 02:00 daily tick?"**
Nothing was lost, because the tick's timer task is durable state and is still due. When the shard
is reacquired, the owner finds the fire time in the past and applies the catch-up policy: inside
the window, the tick fires late and is recorded as fired-late; outside it, it's recorded as
skipped — visible and alertable, never silently absent. Contrast with v1, where that tick never
existed anywhere.

**"A job takes 90 minutes but runs hourly."**
That's the overlap policy, and it's chosen per schedule based on what the job *means*. Skip drops
ticks while a run is active — right for idempotent syncs. Buffer-one runs again immediately after
the current run finishes, collapsing the backlog — "don't miss, but don't pile up."
Cancel-or-terminate-other is for when freshness beats completion — dashboards. Allow-parallel
only if runs are truly independent. The senior move is asking about the job's semantics before
choosing — and noting the mechanism requirement underneath: only a single writer that serializes
ticks against run-completions can enforce any of these without races.

**"Everyone schedules at :00 — 100K fires in one second."**
There are two herds here, with two different answers. On the fire side, per-schedule jitter
spreads the fires, and the per-shard timer queues already spread the processing across the
cluster. On the downstream side, fires flow through the outbox as queued starts, so a spike
becomes backlog and rising start latency — the system gets later, not lossy — with rate limits
protecting fragile targets. And flag backfill as a *self-inflicted* herd that gets rate-limited
explicitly.

**"How do I know tick N fired? Prove it."**
Point at the tick log. Every due tick produces exactly one event with an outcome and, if it
fired, a run ID — and because the tick append, the outbox record, and the next timer are one
atomic write, no state exists where a tick fired without a record, or a record exists without the
fire. Dashboards are projections of this log: last-fire lag per schedule (now minus expected fire
time) is *the* health metric, and skipped-tick counts by reason catch policy misconfiguration.

**"Why not just use Kubernetes CronJob, or a message queue with delayed delivery?"**
Take these seriously rather than dismissing them — knowing where they run out is worth more.
Kubernetes CronJob *is* this problem, solved inside one cluster with weaker knobs: missed ticks
governed by `startingDeadlineSeconds` (a catch-up window), overlap by `concurrencyPolicy` (three
of our six policies), documented double-fire and skip edge cases in the controller, and no
backfill or per-tick audit. Delayed-delivery queues give you *a* timer, but not schedule state:
recurrence, catch-up, overlap, and pause all need a stateful owner anyway — at which point you're
building v3.

---

## Interview Angle

- This question is the [workflow-engine design](design-a-workflow-engine.md#variants) with the
  state shrunk and the policies grown: the same skeleton — single fenced writer, colocated
  timers, transactional outbox — with a different emphasis. Lead with the key insight ("a
  schedule is durable state with a timer, owned by one fenced writer") and spend the interview
  time on the policy surface, which is where weak answers stay vague.
- Every answer must survive three questions: **who fires** (single writer plus fencing — not
  locks, not leader election), **what about missed ticks** (durable timers plus an explicit
  per-schedule catch-up window), and **what about overlap** (named policies, serialized by the
  owner).
- Name the failure asymmetry: a late tick is an incident; a lost tick is a lie. A design that can
  say "skipped, and here's the record" beats a design that can only say "probably fired."
- The Temporal-fluency version: Schedules replaced legacy cron workflows precisely to make these
  policies first-class ([details](multi-cluster-nexus-advanced.md#schedules-and-cron)), and the
  shard/fencing/timer machinery underneath is the
  [history service](history-service-internals.md) — your depth reserve for follow-ups.
