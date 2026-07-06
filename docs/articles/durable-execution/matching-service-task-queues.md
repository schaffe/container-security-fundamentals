---
title: "Matching Service and Task Queues"
section: "Durable Execution"
order: 5
---

# Matching Service and Task Queues

## Overview

Matching is the service that pairs tasks with workers, and it exists to answer a skeptical
question you should expect in any Temporal conversation: "isn't this just a database-backed job
queue?" The answer is no, and the reason is Matching's defining feature — the **sync-match fast
path**, which hands a task directly to a worker that's already waiting, without the task ever
touching the database. When workers are keeping up, a Temporal task queue is not a table being
polled; it's a rendezvous point.

---

## The Task Queue Model

Task queues in Temporal are deliberately lightweight — closer to a naming convention with
machinery behind it than to provisioned infrastructure.

A queue is **created on demand**: the first reference to its name, whether a workflow scheduling
work onto it or a worker polling it, brings it into existence. There is no provisioning step, no
capacity declaration, no CRUD API to manage.

Under each queue name there are actually **two queues**: one delivering workflow tasks ("run this
workflow's code forward") and one delivering activity tasks. A worker polling the queue `orders`
polls both.

The queue name is Temporal's **routing unit** — the mechanism by which work is directed to the
workers able to do it. Different services own different queues. An activity that needs a GPU gets
its own queue, served only by GPU workers. A noisy tenant gets a dedicated queue so it can't
starve anyone else. Queues are cheap enough that even per-entity queues — say, one per physical
host, for tasks that must run on a particular machine — are a supported pattern.

Finally, a hot queue doesn't bottleneck on a single Matching node: internally it splits into N
**partitions** (the count grows with load), each owned by a Matching node, with pollers and tasks
spread across them. A background forwarder drains the non-root partitions toward wherever pollers
are waiting when traffic is light, so partitioning doesn't strand tasks.

---

## Sync Match vs. Async Match

The dispatch path has a fast lane and a slow lane, and which one a task takes depends on a single
question: is a worker already waiting?

```
History ──ProduceTask──► Matching partition
                            │
                            ├─ worker long-poll already parked?
                            │        │
                       yes ─┘        └─ no
                        │                │
              SYNC MATCH:           ASYNC MATCH:
              hand task directly    persist task to backlog
              to the poller —       (DB write); deliver later
              no DB write           when a poller arrives;
                                    delete after ack
```

**Sync match** is the healthy steady state. Workers long-poll the queue, and when they're keeping
up with the load, there is always a poll parked at the partition when a new task arrives. Matching
hands the task straight to that poller and acknowledges History — the task never touches
persistence. Latency is single-digit milliseconds and the persistence cost is zero. In this
regime, Temporal is behaving like an RPC router, not a queue — which is the crisp answer to "why
not just poll a Postgres jobs table with `SELECT ... FOR UPDATE SKIP LOCKED`?"

**Async match** is the degraded-but-correct path. When no poller is available — a backlog has
formed, workers are mid-deploy, traffic spiked — the task is written to the matching store,
becomes backlog, and is read back out when pollers return. Backlog drains roughly in order, but
ordering is explicitly *not* guaranteed — and doesn't need to be, because workflows never depend
on task-queue ordering. Causality lives in the event history, not the queue.

Either way, delivery is **at-least-once**: a task handed to a worker that then dies is redelivered
after a timeout, and History validates every completion against the workflow's current state, so
a duplicate or zombie delivery resolves to exactly one recorded outcome.

One design choice underlies all of this: workers **pull** via long-poll rather than the server
pushing. Pull keeps the connection model outbound-only from the workers' side (no inbound
firewall holes) and gives flow control for free — a worker with no free capacity simply doesn't
poll.

---

## Sticky Queues

There's a performance problem hiding in the replay model. Naively, *every* workflow task — every
single "advance this workflow" step — would require the worker to fetch and replay the workflow's
entire event history, because the worker starts with no state. That's O(history) work per
transition, and for a workflow with thousands of events it would be crippling.

Sticky queues remove replay from the hot path. After a worker executes a workflow task, it keeps
that workflow's reconstructed state cached in memory and advertises a **sticky queue** — a private
task queue unique to that worker process. The server then schedules subsequent workflow tasks for
that execution onto the sticky queue first, so the same worker continues from its cached state and
processes only the *new* events since last time. Replay becomes the exception — the recovery path
— rather than the rule.

And the fallback is airtight: if the sticky worker doesn't pick the task up within a short
schedule-to-start timeout (it died, its cache evicted the workflow, a deploy replaced it), the
server reschedules the task onto the normal shared queue, any worker picks it up, and a full
replay reconstructs the state from history. Correctness never depends on the cache. This is the
pattern to name explicitly in interviews: *a cache with a durable fallback, not a correctness
dependency*.

---

## Flow Control

A few knobs and signals keep the dispatch pipeline healthy, and they're worth knowing as a set.

**Worker slots** cap each worker's concurrency — separate limits for workflow tasks and
activities. A worker polls only when it has a free slot, which is the pull model's flow control in
action. Since 2025, resource-based **auto-tuning** can size the slot counts from observed CPU and
memory pressure instead of hand-tuned constants.

**Task queue rate limits** cap dispatch rate per queue on the server side — the blunt instrument
for protecting a fragile downstream, like capping the `payment-gateway` activity queue at 100
tasks per second across the whole fleet.

**Schedule-to-start latency** is *the* backlog health metric: how long tasks wait between being
scheduled and being picked up. Near zero means sync-matching is happening and workers are keeping
up. Sustained growth means either the worker fleet is undersized — the fix is scaling *your* pods,
per [the deployment model](temporal-architecture.md#workers-are-yours-not-theirs) — or a
downstream rate limit is binding.

Put together, these give the system a distinctive **backpressure shape**. Because workers pull,
overload cannot manifest as dropped work or crushed workers; it manifests as growing backlog and
rising schedule-to-start latency. The system degrades by getting *later*, never by getting
*lossy* — a line worth delivering verbatim in a reliability-focused design round.

---

## Interview Angle

- **Sync match is the headline.** "When workers keep up, tasks never hit the database" is what
  separates this design from polling a jobs table, and it's the prepared answer to "why not just
  use Postgres as the queue?"
- **Sticky queues are memoized replay.** Know the mechanism *and* the property that makes it safe:
  it's correctness-irrelevant, because full replay is always available as the fallback.
- **Pull beats push three ways here**: outbound-only networking, per-worker flow control, and
  graceful backlog behavior — three answers for the price of one design choice.
- **Know the ops signals**: schedule-to-start latency for fleet sizing, queue rate limits for
  downstream protection, partitions for hot queues.
