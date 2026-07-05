---
title: "Multi-Cluster, Nexus, and Advanced Platform Features"
section: "Durable Execution"
order: 7
---

# Multi-Cluster, Nexus, and Advanced Platform Features

## Overview

Namespaces, cross-cluster replication, Nexus, and schedules are how Temporal grows from "a
cluster" into "a platform" — multi-tenancy, disaster recovery, cross-team service boundaries, and
distributed cron. These are prime senior-level design-discussion material: each is a general
distributed-systems problem (tenancy isolation, async replication and conflict resolution, RPC
across trust boundaries, reliable scheduling) with a concrete, inspectable solution.

---

## Namespaces and Multi-Tenancy

A **namespace** is the isolation unit within a cluster:

- **Scoping** — workflow IDs are unique per namespace; task queues, search attributes, and
  retention policies are namespace-scoped. Teams or applications get their own namespace and
  cannot name-collide or read each other's executions.
- **Blast-radius control** — per-namespace rate limits (actions/sec at the frontend) stop one
  tenant's runaway workflow from starving others; per-namespace config covers retention (how long
  closed-workflow histories are kept), archival, and custom search attributes.
- **Not a security boundary by itself** in self-hosted OSS — authorization is pluggable
  (claims-mapper interface); actual tenant isolation requires wiring authn/authz. Temporal Cloud
  hardens this and adds **cell-based architecture**: namespaces are placed into isolated cells
  (independent failure domains of the whole stack), so a bad deploy or overload in one cell can't
  take down every customer — the same cell pattern used by AWS and Slack, worth citing in
  reliability design rounds.

---

## Multi-Cluster Replication (XDC)

Temporal's disaster-recovery story: a namespace can be **global**, existing on multiple clusters
with one **active** cluster taking writes and others as **standby**, receiving asynchronous
replication.

Mechanism:

- History transitions emit **replication tasks** through the same
  [transactional outbox](history-service-internals.md#internal-task-queues-and-the-transactional-outbox)
  as everything else; standby clusters pull event batches and apply them to their copy of each
  workflow's history.
- Replication is **async** — the active cluster never waits on a remote region to commit. This
  keeps local latency flat but means **failover can lose the tail** (RPO > 0): events committed in
  the active region but not yet replicated.
- **Failover** flips the active designation; workers connected to the new active cluster resume
  workflows from replicated state. Failover is per-namespace, so it can be rehearsed and rolled
  out incrementally.

### Conflict Resolution

The interesting case: a **split-brain failover** — the old active kept taking writes (partition,
not death) while the new active also progressed the same workflow. Now one workflow has two
divergent history tails. Temporal's model:

- Histories can **branch**: each cluster's events carry a failover **version** (from a
  cluster-versioning scheme that makes versions globally ordered and attributable); **version
  histories** in mutable state track which branch is current.
- On reconnection, the branch with the higher version wins; the losing branch's divergent tail is
  abandoned. A workflow on the losing branch is reset to the fork point and re-executes from
  there — with the crucial caveat that **activities on the lost tail may have already run**:
  at-least-once strikes again, and idempotent activities are what make failover safe, not just
  retries.

The senior framing: async replication trades RPO for latency; conflict resolution turns
"impossible to prevent divergence" into "deterministic, attributable convergence"; and the
application-level contract (idempotency) is part of the DR design, not an afterthought.

---

## Nexus

Nexus (GA 2025, always-enabled since) is Temporal's answer to "how do two teams' workflows call
each other without sharing a namespace?" — **durable RPC across namespace and cluster
boundaries**.

- A team exposes a **Nexus endpoint** — a named service contract (operations with typed
  input/output) backed by handlers in their namespace, typically implemented by workflows or
  activities. Endpoints are registered in a cluster-level registry and routed via tokens.
- A caller workflow invokes a Nexus **operation** like an activity — but the call crosses into the
  callee's namespace with its own access control, worker fleet, and deployment cadence.
- Operations can be **synchronous** (quick handler) or **asynchronous** (starts a workflow, calls
  back on completion) — the caller's code looks the same; the machinery handles the callback,
  retries, and failure propagation with durable-execution semantics on both sides.

Versus the older alternatives:

| | Child workflow | Signal to foreign workflow | Nexus |
|---|---|---|---|
| Crosses namespaces | No (same namespace) | Awkwardly | Yes, by design |
| Contract | Callee's workflow signature (implementation leaks) | None (stringly-typed) | Explicit operation contract |
| Team autonomy | Coupled deploys/registries | Coupled IDs | Independent — like a service API |

The design-round framing: Nexus is a **service mesh boundary for durable execution** — it does for
workflows what gRPC + API contracts did for microservices, replacing "everyone shares one giant
namespace" with owned, versioned interfaces.

---

## Schedules and Cron

Schedules (the replacement for legacy cron workflows) are Temporal's distributed-cron primitive:
"run workflow W every interval / calendar spec."

- Implemented as system state driven by the same timer machinery as everything else — a schedule
  is durable state that fires, starts a workflow execution, and records the result; no separate
  scheduler service to keep alive.
- **Overlap policies** answer the question naive cron ignores — what if the previous run is still
  going? Skip, buffer one, buffer all, cancel-other, terminate-other, or allow parallel.
- **Catch-up/backfill** — if the cluster was down over a fire time, catch-up windows control
  whether missed runs execute late or are skipped; explicit backfill replays a time range.
- Pause/resume, jitter, and "run now" round out the operational surface.

Contrast with the interview classic "design distributed cron" (see the
[workflow-engine design article](design-a-workflow-engine.md#variants)): most hand-rolled designs
struggle exactly where schedules have explicit answers — missed ticks, overlapping runs, and
exactly-one-firing across a fleet. Temporal gets the last one free from the single-writer shard
model: a schedule lives on one shard, so "which node fires the tick?" never arises.

---

## Interview Angle

- **Multi-tenancy**: namespaces for scoping + rate limits for blast radius + cells for failure
  domains — a three-layer isolation answer that generalizes to any platform design question.
- **XDC is a full DR case study**: async replication → nonzero RPO → branching histories →
  version-based conflict resolution → idempotency as the app-level contract. Walking that chain
  end-to-end is a standout answer to "how would you make this multi-region?"
- **Nexus**: know it as "durable RPC with contracts across namespaces" and when to prefer it over
  child workflows (team/trust boundaries) — it's new enough that knowing it signals currency.
- **Schedules**: overlap policies and catch-up windows are the two follow-ups interviewers use to
  separate people who've run cron in production from people who haven't.
