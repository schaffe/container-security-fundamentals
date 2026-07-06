---
title: "Multi-Cluster, Nexus, and Advanced Platform Features"
section: "Durable Execution"
order: 7
---

# Multi-Cluster, Nexus, and Advanced Platform Features

## Overview

Everything so far describes a single Temporal cluster serving a single team. This article covers
the features that turn "a cluster" into "a platform": namespaces for multi-tenancy, cross-cluster
replication for disaster recovery, Nexus for cross-team service boundaries, and Schedules for
distributed cron. Each one is prime senior-interview material for the same reason — behind each
feature sits a general distributed-systems problem (tenant isolation, async replication with
conflict resolution, RPC across trust boundaries, reliable scheduling), and Temporal's solution is
concrete enough to inspect and argue about.

---

## Namespaces and Multi-Tenancy

A **namespace** is the unit of isolation within a cluster. Workflow IDs are unique per namespace;
task queues, custom search attributes, and retention policies are all namespace-scoped. In
practice, each team or application gets its own namespace, which means teams cannot collide on
names and cannot read each other's executions.

Namespaces are also the unit of **blast-radius control**. The frontend enforces per-namespace rate
limits (actions per second), so one tenant's runaway workflow — a signal loop, a retry storm —
degrades that tenant rather than starving everyone. Retention (how long closed-workflow histories
are kept), archival, and search attributes are likewise configured per namespace.

One honest caveat for self-hosted deployments: a namespace is a *scoping* boundary, not by itself
a *security* boundary. Authorization in the open-source server is pluggable (a claims-mapper
interface), and real tenant isolation requires actually wiring up authentication and
authorization. Temporal Cloud hardens this and adds a further layer worth knowing: **cell-based
architecture**. Namespaces are placed into cells — independent, full-stack failure domains — so a
bad deploy or an overload in one cell cannot take down every customer. This is the same cell
pattern AWS and Slack use, and citing it by name plays well in reliability-focused design rounds:
namespaces for scoping, rate limits for blast radius, cells for failure domains — three layers of
isolation, each catching what the previous one can't.

---

## Multi-Cluster Replication (XDC)

Temporal's disaster-recovery story starts with making a namespace **global**: it exists on
multiple clusters, one of which is **active** and takes all writes, while the others are
**standby**, receiving the active cluster's history asynchronously.

The mechanism reuses machinery you've already seen. Every state transition on the active cluster
emits **replication tasks** through the same
[transactional outbox](history-service-internals.md#internal-task-queues-and-the-transactional-outbox)
that drives everything else; standby clusters pull batches of history events and apply them to
their own copies of each workflow.

The crucial word is *asynchronously*. The active cluster never waits for a remote region before
committing — which keeps local latency flat, but means a failover can lose the tail: events that
committed in the active region and hadn't yet replicated are gone from the standby's view. In DR
terms, the recovery point objective (RPO) is greater than zero, and saying so out loud, as a
consequence of a latency choice rather than a flaw, is the senior framing.

**Failover** itself is a designation flip: the standby becomes active, and workers connected to it
resume workflows from whatever state replicated. Failover is per-namespace, which means it can be
rehearsed on low-stakes namespaces and rolled out incrementally during a real incident.

### Conflict Resolution

Now the genuinely interesting case. Suppose the "failed" cluster wasn't dead — just partitioned —
and kept taking writes while the new active cluster also made progress on the same workflow. There
are now two divergent versions of one workflow's history. What happens when the partition heals?

Temporal's model allows histories to **branch**. Every event carries a failover **version** from a
cluster-versioning scheme that makes versions globally ordered and attributable to a cluster, and
each workflow's mutable state tracks its **version histories** — which branch is current. On
reconnection, the branch with the higher version wins deterministically. The losing branch's
divergent tail is abandoned, and a workflow that had progressed down that tail is reset to the
fork point to re-execute from there.

But note the sting in that last clause: **activities on the abandoned tail may have already run**.
Their side effects escaped into the world before the branch lost. At-least-once strikes again —
and this is why idempotent activities are part of the *disaster-recovery design*, not just a
retry nicety. The full senior narrative chains together: async replication trades RPO for latency;
divergence under split-brain is impossible to prevent, so conflict resolution makes convergence
deterministic and attributable instead; and idempotency is the application-level contract that
makes the whole arrangement safe.

---

## Nexus

As Temporal adoption grows inside a company, a new problem appears: team A's workflow needs to
invoke team B's workflow, but the teams share neither a namespace nor, possibly, a cluster.
Reaching directly into another team's namespace — signaling their workflows by ID, starting their
workflow types — couples the teams at the implementation level, exactly the way calling another
service's database would.

**Nexus** (generally available since 2025, and always enabled on current versions) is the answer:
**durable RPC across namespace and cluster boundaries, with explicit contracts.**

The shape is service-oriented. A team exposes a **Nexus endpoint** — a named contract of
operations with typed inputs and outputs — backed by handlers in their own namespace, typically
implemented as workflows or activities. Endpoints live in a cluster-level registry. A caller
invokes a Nexus **operation** from workflow code much as it would an activity, but the call
crosses into the callee's namespace, with the callee's own access control, worker fleet, and
deployment cadence on the other side.

Operations come in two flavors that look identical to the caller: **synchronous** (the handler
answers quickly) and **asynchronous** (the handler starts a workflow and the machinery delivers a
callback when it completes) — with retries and failure propagation handled durably on both sides.

Why not the older alternatives? A **child workflow** doesn't cross namespaces at all, and it
couples the caller to the callee's workflow signature — an implementation detail. **Signaling a
foreign workflow** crosses namespaces awkwardly and offers no contract whatsoever, just
stringly-typed payloads aimed at an ID you have to know. Nexus gives the thing microservices
learned to demand long ago: an owned, versioned interface. The framing for a design round:
*Nexus is to workflows what gRPC plus API contracts were to microservices* — it replaces "everyone
shares one giant namespace" with service boundaries.

---

## Schedules and Cron

Schedules are Temporal's distributed-cron primitive — "run workflow W every five minutes / at
02:00 daily" — and the replacement for the older, weaker cron-workflow feature.

Under the hood there is pleasingly little new machinery: a schedule is durable system state driven
by the same timer and shard infrastructure as everything else. When the timer fires, the schedule
starts a workflow execution and records the outcome. There is no separate scheduler service to
keep alive, and — because a schedule lives on exactly one shard with one fenced writer — the
classic hard question of distributed cron, "which node fires the tick?", simply never arises.

Where Schedules earn their keep is the policy surface, which has explicit answers exactly where
naive cron goes vague:

- **Overlap policies** answer "what if the previous run is still going when the next tick is
  due?" — a question plain cron ignores entirely. The options: skip the new tick, buffer one,
  buffer all, cancel the running one, terminate the running one, or allow them in parallel.
- **Catch-up windows and backfill** answer "what about ticks that were due while the cluster was
  down?" A catch-up window controls whether missed ticks fire late or are skipped; explicit
  backfill replays a historical time range on demand.
- Pause/resume, per-schedule jitter (to break thundering herds at the top of the hour), and an
  immediate "run now" round out the operational surface.

If you're handed the interview classic "design distributed cron," this feature is the reference
implementation — the [dedicated design article](design-distributed-cron.md) builds it from
scratch, and most hand-rolled designs struggle precisely where Schedules have explicit knobs:
missed ticks, overlapping runs, and exactly-one-firing across a fleet.

---

## Interview Angle

- **Multi-tenancy** has a clean three-layer answer: namespaces for scoping, per-namespace rate
  limits for blast radius, cells for failure domains. The structure generalizes to any
  platform-design question.
- **XDC is a complete DR case study** you can narrate end to end: async replication → nonzero
  RPO → branching histories under split-brain → version-based conflict resolution → idempotency
  as the application-level contract. Walking that chain is a standout answer to "how would you
  make this multi-region?"
- **Nexus** in one line: durable RPC with contracts across namespaces. Know when to prefer it
  over child workflows — team and trust boundaries — and note it's new enough that knowing it at
  all signals currency.
- **Schedules**: overlap policies and catch-up windows are the two follow-ups interviewers use to
  separate people who have run cron in production from people who haven't.
