---
title: "System Design: Distributed Cron"
section: "Durable Execution"
order: 10
---

# System Design: Distributed Cron

## Overview

"Design distributed cron" is the compact cousin of the
[workflow-engine question](design-a-workflow-engine.md): a service where users register schedules
("run job J every 5 minutes / at 02:00 daily") and the system fires them reliably across a fleet —
no machine is special, any node can die, and yet each tick fires exactly once. The state is tiny
(a schedule is a few hundred bytes), which fools candidates into thinking the problem is small.
It isn't: the hard parts are *exactly-one-firing* across many nodes, *missed ticks* when the
system was down over a fire time, and *overlapping runs* when a job outlives its interval. This
article builds the design iteratively, then covers the deep-dive prompts. Temporal's
[Schedules](multi-cluster-nexus-advanced.md#schedules-and-cron) are the reference implementation
throughout — not because it's the only answer, but because it has explicit answers exactly where
hand-rolled designs go vague.

## Key Insight

A schedule is **durable state with a timer**, not a process. Stop thinking "which node runs the
cron loop?" and start thinking "where does the schedule's state live, and who is allowed to write
it?" Once each schedule has a **single fenced writer** — one owner, whose writes are conditional
on an ownership token — "which node fires the tick?" stops being a coordination problem and
becomes a placement detail. Firing a tick is then just a state transition: read next-fire-time,
append "tick N fired," start the job, compute next-fire-time. Everything else (catch-up, overlap,
backfill, pause) is policy layered on that transition.

---

## Requirements and API Sketch

**Functional:**

- CRUD schedules: interval or calendar (cron-expression) specs; a schedule triggers an *action*
  (start job J with input X).
- Each due tick fires **exactly once** across the fleet — never zero times, never twice.
- Policy for **missed ticks** (system down over a fire time): run late, or skip?
- Policy for **overlap** (previous run still going when the next tick is due).
- Pause/resume a schedule; manual "run now"; **backfill** a historical time range.
- Answer "did tick N fire, and what happened to the run it started?" — auditable per-tick history.

**Non-functional:**

- Scale: ~1M schedules, mostly minutes-to-daily cadence; peak alignment (everyone schedules
  at :00) means fire-time load is *spiky by nature* — name this up front.
- A tick may fire seconds late; it must never be silently lost. Like the workflow engine, this is
  a state system: durability over latency, and saying so licenses trade-offs later.

```
CreateSchedule(id, spec, action, policies) -> handle     Pause(id) / Unpause(id)
UpdateSchedule(id, spec/policies)                        TriggerNow(id)
DescribeSchedule(id) -> spec, next ticks, recent runs    Backfill(id, from, to, overlap_policy)
```

---

## Iterative Design

### v1: Crontab on Every Node + a Lock

The instinctive design: every node loads all schedules, evaluates the cron spec each minute, and
races for a distributed lock (Redis `SETNX`, a lock row) before firing. Why it breaks:

1. **Locks don't give exactly-once.** Node A takes the lock, fires, dies before recording it —
   the lock expires and node B fires again (twice); or A takes the lock and dies before firing —
   tick lost until someone notices (zero times). A lease-based lock bounds *concurrency*, not
   *effects*. Without the firing being a conditional write against durable schedule state, you get
   at-most-once or at-least-once, chosen by your crash timing.
2. **O(nodes × schedules) evaluation** — every node parses every spec every minute for the
   privilege of losing a lock race.
3. **No memory of missed ticks.** If the whole fleet is down 01:58–02:03, the 02:00 tick simply
   never existed. Cron-on-a-box has this bug too; distributing it doesn't fix it.

### v2: Central Store + Polling Workers

Move state into a database: `(schedule_id, spec, next_fire_at, paused, ...)`. A worker fleet
polls: `SELECT ... WHERE next_fire_at <= now() FOR UPDATE SKIP LOCKED`, fires, computes and
writes the next fire time. Real progress — firing and state now change together, and a fleet
outage leaves `next_fire_at` in the past, so missed ticks are at least *visible*. Remaining
holes:

1. **Dual write.** Firing means starting a job in some other system *and* updating the row. Crash
   between them and you're back to lost-or-duplicate ticks. Needs an outbox: record "tick N
   fired, start job" in the same transaction as advancing `next_fire_at`; deliver at-least-once;
   dedupe downstream on `(schedule_id, tick_N)` as the idempotency key.
2. **The DB is the timer.** Poll-the-world burns the database and floors your precision at the
   poll interval; the hot `next_fire_at` index is a contention point exactly at :00 spikes.
3. **Row locks are still locks.** `SKIP LOCKED` serializes per row, but ownership is per-tick and
   transient — there's no stable writer per schedule, so per-schedule invariants (overlap policy
   needs to know about the *previous* run) require extra reads and races.

### v3: Sharded Single-Writer Owners + Per-Shard Timer Queues

The durable-execution shape — and where the workflow-engine design pays rent:

1. **Shard the schedules**: `hash(schedule_id) % N`; each shard has exactly one owner node at a
   time, placement via a membership ring, **correctness via fencing** — the owner holds an epoch
   (range ID), and every write for the shard is conditional on it at the store. A stale owner's
   fires fail at the database, not at a lock server
   ([the mechanism, in Temporal's history service](history-service-internals.md#history-shards)).
2. **Timers live with the shard**: each schedule's next fire time is a timer task in the shard's
   persisted priority queue; the shard processor sleeps until the head deadline. No global scan,
   no polling; timer capacity scales with shards
   ([timers at scale](history-service-internals.md#timers-at-scale)).
3. **Firing is one conditional transition**: append `TickFired(N)` + the action's outbox record +
   the next timer task, all in one write conditional on the fencing token. Exactly-one-firing
   falls out: two would-be owners race, one write commits, the other fails its condition and
   re-reads. This is exactly why Temporal Schedules get the classic hard part "for free" — a
   schedule lives on one shard, so
   ["which node fires the tick?" never arises](multi-cluster-nexus-advanced.md#schedules-and-cron).

On this skeleton, the cron-specific policies are small, explicit state machines:

- **Catch-up window** (missed ticks): on recovery, the owner sees fire times in the past. Ticks
  within the window (e.g. 1 hour) fire late; older ones are recorded as skipped. Which you want is
  per-schedule semantics — "send daily report" should catch up; "poll for new files every minute"
  should collapse to one run. Making it a per-schedule knob, not a global guess, is the point.
- **Overlap policies** — what if the previous run is still going? Enumerate all six: **skip** the
  new tick; **buffer one** (start it when the current run ends, collapsing further ticks);
  **buffer all** (queue every tick); **cancel-other** / **terminate-other** (kill the old run,
  start the new); **allow parallel**. Implementable only because the single writer sees both the
  tick and the previous run's completion as serialized transitions on the same state.
- **Jitter**: spread fire times within a per-schedule window to break the :00 thundering herd —
  10K schedules at "hourly" shouldn't hit downstream as one spike. Deterministic jitter
  (hash of schedule ID) keeps a given schedule's offset stable across owners.
- **Backfill**: replay a time range as synthetic ticks through the same firing path (with an
  explicit overlap policy, since a backfill is a deliberate herd). Reusing the tick machinery
  means backfilled runs get the same audit records as real ones.
- **Pause/resume**: a bit on the schedule state checked at fire time — paused ticks are recorded
  as skipped, not silently swallowed, so resume can decide whether they're in the catch-up window.
- **Observability**: the per-schedule event log *is* the answer to "did tick N fire" — each tick
  is an appended event with outcome (fired / skipped: overlap / skipped: paused / skipped: outside
  catch-up) and a pointer to the run it started. Recent-runs and next-N-ticks fall out of
  `Describe`; a search projection (eventually consistent, and say so) serves listing.

```
API gateway (stateless, routes by hash(schedule_id))
   │
Schedule owner shards (schedule state + tick log + timer queue + outbox; single fenced writer)
   │  fire actions (outbox, at-least-once, deduped on (schedule_id, tick))
Job execution layer (workers / workflow engine — owns retries, timeouts, run status)
   │
Stores: state store (conditional point writes)  |  search projection (async)
```

One boundary worth drawing aloud: cron owns *when* and *whether* to start a run; the execution
layer owns *how the run goes* (retries, timeouts, heartbeats). If the interviewer lets you, make
the action "start a workflow" and inherit all of the
[workflow engine](design-a-workflow-engine.md) — Temporal literally builds Schedules this way, as
system state on the same timer and shard machinery as workflows.

---

## Deep-Dive Prompts Interviewers Pull

**"Two scheduler nodes both think they own a schedule — what fires?"**
The prompt is fishing for leader-election hand-waving; don't bite. Answer: both may *try*, one
fires. Ownership is fenced — the owner's epoch/range ID is checked by a conditional write on every
transition, so the stale node's `TickFired(N)` append fails at the store and it re-reads (finding
tick N already fired). The membership ring is a routing optimization; **the database condition is
the guarantee** ([same answer as history shards](history-service-internals.md#history-shards)).
Leader election without fencing just recreates v1's lock, with more machinery.

**"The whole cluster was down from 01:55 to 02:20. The 02:00 daily tick — what happens?"**
Nothing was lost: the tick's timer task is durable state, still due. On shard reacquisition the
owner finds it in the past and applies the catch-up policy — inside the window, fire late and
record the tick as fired-late; outside, record it as skipped (visible, alertable — never silently
absent). Contrast with v1, where the tick never existed anywhere.

**"A job takes 90 minutes but runs hourly."**
Overlap policy, chosen per schedule: skip (drop ticks while running — fine for idempotent syncs),
buffer-one (run again immediately after, collapsing the backlog — "don't miss, don't pile up"),
cancel/terminate-other (freshness beats completion — dashboards), allow-parallel (only if runs
are independent). The senior move is asking *what the job means* before picking, and noting the
mechanism requirement: only a single writer that serializes ticks against run-completions can
enforce any of these without races.

**"Everyone schedules at :00 — 100K fires in one second."**
Two herds, two answers. Fire-side: per-schedule jitter spreads the fires; the per-shard timer
queues already spread the *processing* across shards. Downstream-side: the fire path enqueues
starts through the outbox, so a spike becomes queue backlog and rising start latency — later, not
lossy — plus rate limits protecting fragile targets. Also flag backfill as a self-inflicted herd
and rate-limit it explicitly.

**"How do I know tick N fired? Prove it."**
Point at the tick log: every due tick produces exactly one event with an outcome and, if fired, a
run ID — because the tick append, the outbox record, and the next timer are one atomic write, there
is no state where a tick fired without a record or vice versa. Dashboards project this: last-fire
lag per schedule (now − expected fire time) is *the* health metric; skipped-tick counts by reason
catch policy misconfiguration.

**"Why not just use Kubernetes CronJob / a message queue with delayed delivery?"**
K8s CronJob is fine inside one cluster but is this problem, solved with weaker knobs: missed ticks
governed by `startingDeadlineSeconds` (a catch-up window), overlap by `concurrencyPolicy` (three
of the six policies), and its controller has documented double-fire and skip edge cases — plus no
backfill and no per-tick audit. Delayed-delivery queues give you *a* timer but not schedule state:
recurrence, catch-up, overlap, and pause all need a stateful owner anyway. Knowing the shape of
the off-the-shelf answers and where they run out is worth more than dismissing them.

---

## Interview Angle

- This question is the [workflow-engine design](design-a-workflow-engine.md#variants) with the
  state shrunk and the policies grown: same skeleton (single fenced writer, colocated timers,
  transactional outbox), different emphasis. If you've internalized that design, lead with the
  Key Insight — "a schedule is durable state with a timer, owned by one fenced writer" — and
  spend the interview on the policy surface, which is where weak answers stay vague.
- The three questions every answer must survive: **who fires** (single writer + fencing, not
  locks or leader election), **what about missed ticks** (durable timers + explicit catch-up
  window, per schedule), **what about overlap** (named policies, serialized by the owner).
- Name the failure asymmetry: a late tick is an incident, a lost tick is a lie. Designs that can
  say "skipped, and here's the record" beat designs that can only say "probably fired."
- Temporal fluency version: Schedules replaced legacy cron workflows precisely to make these
  policies first-class ([details](multi-cluster-nexus-advanced.md#schedules-and-cron)); the
  underlying shard/fencing/timer machinery is the
  [history service](history-service-internals.md) — the depth reserve for follow-ups.
