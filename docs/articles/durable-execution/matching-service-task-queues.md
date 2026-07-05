---
title: "Matching Service and Task Queues"
section: "Durable Execution"
order: 5
---

# Matching Service and Task Queues

## Overview

Matching is the service that pairs tasks with workers. Its defining feature — the **sync-match
fast path**, which hands a task directly to a parked long-poll without touching the database — is
the answer to "isn't Temporal just a database-backed queue?" No: when workers keep up, the queue
is a rendezvous point, not a table.

---

## Task Queue Model

Task queues are lightweight and dynamic:

- **Created on demand** — first reference (a workflow scheduling onto it, or a worker polling it)
  brings a queue into existence. No provisioning, no capacity declaration, no CRUD API needed.
- **Two kinds per name**: a workflow task queue (delivering "run workflow code" tasks) and an
  activity task queue (delivering activity executions). A worker polling task queue `orders`
  polls both kinds.
- **Routing unit** — the task queue name is how work is directed: different services own
  different queues; a GPU-only activity gets its own queue served only by GPU workers; per-tenant
  queues isolate noisy neighbors. Queues are cheap enough that per-entity queues (e.g., one per
  physical host, for host-affine tasks) are a supported pattern.
- **Partitions** — a hot queue is internally split into N partitions (default grows with load),
  each owned by a Matching node, so one queue's throughput isn't capped by one node. Pollers and
  tasks are spread across partitions; a background forwarder drains non-root partitions toward
  pollers when traffic is light.

---

## Sync Match vs. Async Match

The dispatch path has a fast and a slow lane:

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

- **Sync match** — when workers are keeping up (the healthy steady state), there is a parked
  long-poll waiting at the partition when the task arrives. Matching hands the task straight
  through and acks History; the task never touches persistence. Latency: single-digit
  milliseconds; persistence cost: zero. Under sync match, Temporal behaves like an RPC router,
  not a queue.
- **Async match** — no poller available (backlog, worker deploy, traffic spike): the task is
  written to the matching store, becomes backlog, and is read back out when pollers return.
  Backlog is drained roughly in order (ordering is *not* guaranteed — workflows never depend on
  task-queue order; causality lives in event history).
- **Delivery is at-least-once** — a task delivered to a worker that dies is redelivered after its
  timeout; History validates staleness on completion, so duplicate/zombie deliveries resolve to
  one recorded outcome.

Long-polling (not push) keeps the connection model outbound-only from workers and gives natural
flow control: a worker with no free slots simply doesn't poll.

---

## Sticky Queues

Naively, *every* workflow task would require the worker to replay the workflow's whole event
history — O(history) work per transition. Sticky queues remove this from the hot path:

- After a worker executes a workflow task, it keeps the workflow's state cached in memory and
  advertises a **sticky queue** — a private task queue unique to that worker process.
- Subsequent workflow tasks for that execution are scheduled to the sticky queue first, so the
  same worker continues from cached state, processing only the *new* events. Replay becomes the
  exception, not the rule.
- **Fallback**: if the sticky worker doesn't pick up the task within a short
  schedule-to-start timeout (worker died, cache evicted, deploy), the server reschedules the task
  onto the normal shared queue, any worker picks it up, and full replay reconstructs the state.
  Correctness never depends on the cache — stickiness is purely a performance optimization, which
  is the pattern to name in interviews: *cache with a durable fallback, not a correctness
  dependency*.

---

## Flow Control

The knobs and signals that keep the pipeline healthy:

- **Worker slots** — per-worker concurrency limits for workflow tasks and activities. A worker
  only polls when it has a free slot. **Resource-based auto-tuning** (GA 2025) adjusts slot counts
  from observed CPU/memory instead of hand-tuned constants.
- **Task queue rate limits** — server-enforced dispatch rate per queue; the blunt instrument for
  protecting a fragile downstream (e.g., cap `payment-gateway` activities at 100/s fleet-wide).
- **Schedule-to-start latency** — *the* backlog health metric: how long tasks wait between
  scheduling and worker pickup. Near-zero means sync-matching; sustained growth means the worker
  fleet is undersized (scale *your* pods — see
  [workers are yours](temporal-architecture.md#workers-are-yours-not-theirs)) or a downstream
  rate limit is binding.
- **Backpressure shape** — because workers pull, overload manifests as growing backlog +
  schedule-to-start latency, not as dropped work or overwhelmed workers. The system degrades by
  getting *later*, never by getting *lossy* — a line worth saying verbatim in a reliability-focused
  design round.

---

## Interview Angle

- **Sync match is the headline**: "when workers keep up, tasks never hit the database" — this is
  what separates the design from `SELECT ... FOR UPDATE SKIP LOCKED` polling on a jobs table, and
  the natural answer to "why not just use Postgres as the queue?"
- **Sticky queues = memoized replay**: know the mechanism *and* the property that it's
  correctness-irrelevant (durable fallback to full replay).
- **Pull vs. push**: long-polling gives outbound-only networking, per-worker flow control, and
  graceful backlog behavior — three answers for the price of one design choice.
- **Know the ops signals**: schedule-to-start latency for fleet sizing, queue rate limits for
  downstream protection, partitions for hot queues.
