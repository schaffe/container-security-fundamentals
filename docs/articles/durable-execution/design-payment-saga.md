---
title: "System Design: Payment Saga Orchestrator"
section: "Durable Execution"
order: 12
---

# System Design: Payment Saga Orchestrator

## Overview

"Design a payment saga orchestrator" is the money-flavored skin on the
[workflow-engine question](design-a-workflow-engine.md): a service that drives a multi-step
payment — hold funds, capture, credit the ledger, notify — across services that each fail
independently, with no distributed transaction available to hide behind. What the interviewer is
really testing is whether you can name what *replaces* the transaction: the saga pattern,
compensation, idempotency on every money movement, and an audit trail. This article covers the
saga design itself, the deep-dive prompts, and where the workflow-engine machinery slots in
underneath.

## Key Insight

A saga replaces atomicity with **compensation**. Each forward step has an undo — release the
hold, refund the capture — and the orchestrator guarantees that either every step completes or
every completed step is compensated. That's the sequence-level story.

But notice what compensation does *not* give you: it makes the sequence recoverable, not the
individual steps safe. A step that gets retried can still execute its side effect twice — and
"charged twice, then compensated once" is not a comfort to anyone. Making each step safe under
retry takes **idempotency keys on every money movement**, with "exactly-once" ledger semantics
built by deduplicating **at the ledger** — not by hoping the caller never retries. The complete
formula: compensation for the sequence, idempotency for each step, and an event log so you can
prove what happened.

---

## Requirements and API Sketch

Functional:

- Execute a payment as an ordered sequence of steps — `AuthorizeCard → HoldFunds → Capture →
  CreditLedger → Notify` — each calling a separate service (the payment service provider, the
  internal ledger, email).
- On a failure after earlier steps have taken effect, run their compensations in reverse order:
  release the hold, refund the capture.
- Query a payment's state at any time; surface stuck payments for human review.
- Payments may take days — 3-D Secure challenges, bank transfers, manual fraud review.

Non-functional:

- The headline, stronger than the generic engine's "no workflow lost": **no money lost or
  duplicated under any single-component crash.**
- Every state change auditable — who moved what money, when, why, and what the counterparty
  responded. Regulators demand it, and so does every dispute.
- Scale is modest by engine standards — 100K payments a day is a big shop. Correctness dominates
  throughput, and saying so out loud licenses simple, serialized designs.

```
StartPayment(payment_id, amount, instrument) -> handle    Signal(payment_id, "3ds_completed", ...)
GetPayment(payment_id) -> status/steps/audit              ListStuck(older_than) -> for ops review
```

---

## Design

### Orchestration vs. Choreography

There are two ways to run a saga, and the choice is the first thing to get on the table.

**Choreography** has no coordinator: each service reacts to the previous service's events — the
capture service sees "FundsHeld" and acts. It's cheap to start and loosely coupled, but the
saga's logic ends up smeared across every participant. Nobody owns the state machine; failure
paths multiply combinatorially as services are added; and answering "where is payment X, and
why?" means joining logs across half the company.

**Orchestration** puts one component in charge of the payment's state machine: it *tells* each
service what to do and records every command and response.

For money, orchestration wins — and the interview point is saying *why*, not just picking it.
Money demands a single authoritative answer to "what state is this payment in?", a single place
where compensation ordering is encoded, and a single audit trail. Choreography trades all three
away for looser coupling — a fine trade for notification fan-out, a bad one for funds.

### The Saga as a Workflow

The orchestrator doesn't need to be designed from scratch — it is exactly the
[durable workflow engine](design-a-workflow-engine.md). The saga is a workflow; each money
movement is an activity (at-least-once, retried, timed out); and compensation is nothing more
exotic than a try/catch in workflow code that runs compensating activities:

```
try:
    AuthorizeCard(...)
    hold = HoldFunds(...);        compensations.push(ReleaseHold(hold))
    cap  = Capture(...);          compensations.push(Refund(cap))
    CreditLedger(...)
except StepFailed:
    for c in reversed(compensations): run_with_retries(c)   # compensations can ALSO fail
```

Two caveats separate senior answers from junior ones here.

First, **compensations can also fail** — `Refund` calls the same flaky payment provider that
`Capture` did. So compensations get the full treatment forward steps get: retries, idempotency
keys, timeouts. And a compensation that exhausts its retries escalates to human review; it never
silently drops.

Second, **not everything is compensatable.** A completed payout to an external bank account
cannot be clawed back by an API call. The design consequence: order the steps so the
hardest-to-undo step — the "pivot" — comes last, after everything that might still force a
rollback has already succeeded.

### Idempotency on Every Money Movement

Every activity that moves money carries an idempotency key **derived from the workflow's durable
identity** — workflow ID plus step, something like `pay-42:capture:1` — and that key is
propagated to the payment provider and to the internal ledger. Because the key derives from
durable identity, it is stable across retry attempts. The classic bug — the one interviewers
probe for — is generating the key *per attempt*, which makes every retry look like a fresh
operation and silently defeats the dedup.

Here's how "exactly-once" ledger semantics are really built, stated as a chain: the engine
guarantees `CreditLedger` runs *at least* once; the ledger records the idempotency key alongside
the entry, under a unique constraint; a duplicate execution hits the constraint and returns the
original result instead of writing a second entry. The dedup lives **at the ledger** because the
receiver is the only party that can atomically check-and-write — dedup at the caller is hope, not
a mechanism. This is the
[effectively-once recipe](distributed-systems-foundations.md#idempotency-and-dedup) applied to
money.

### Event History as the Audit Trail

A pleasant surprise falls out of building on a workflow engine: the per-workflow event log —
every command issued, every provider response, every retry, every compensation — *is* the audit
trail regulators want. You don't build a separate audit system; you expose the history you
already persist for replay. When a dispute arrives ("you captured twice"), the answer is the
capture command, its idempotency key, and the provider's dedup response, read straight from the
log.

### Stuck States: Timeouts and Human Review

Money gets stuck in limbo: funds held, capture failing, refund also failing. A credible design
names its escape hatch. Every step has a timeout budget, and exhausting retries within it doesn't
loop forever — it transitions the payment to a `NEEDS_REVIEW` state and pages a human. The
human's resolution — "the provider confirms the capture actually went through," or "cancel and
release" — re-enters the workflow as a **signal**, which means the resolution itself lands in the
history. Even manual intervention is audited.

### Reconciliation as a Backstop

Finally, a periodic job compares the ledger against the provider's settlement reports and flags
discrepancies. Include it — but frame its role precisely: **reconciliation is a backstop, not the
mechanism.** If your correctness story is "reconciliation will catch it," you have designed a
system that loses money for a day and then notices. Idempotency and the saga's state machine are
the mechanism; reconciliation catches the residue — provider bugs, out-of-band operations, cosmic
rays.

### Happy Path and Compensation Path

```
Happy:        Orchestrator          PSP              Ledger
              Authorize(key a1) ──▶ ok
              HoldFunds(key h1) ──▶ held
              Capture(key c1)   ──▶ captured
              Credit(key l1)    ─────────────────▶  entry written (dedup on l1)
              Notify             ⇒ payment COMPLETED

Compensation: Capture(key c1)   ──▶ ✗ hard decline (after retries)
              Refund? nothing captured — skip
              ReleaseHold(key rh1) ─▶ released      (compensations retried like forward steps)
                                   ⇒ payment FAILED, history shows full trail
```

---

## Deep-Dive Prompts Interviewers Pull

**"Capture succeeded but the response timed out — the retry would double-charge."**
This is the defining question of the interview. The retry goes out with the *same* idempotency
key — `pay-42:capture:1` — and the provider recognizes it and returns the original result. **The
retry becomes a read**, not a second charge. Then pre-empt the follow-ups: providers only
remember keys for a finite **dedup window** (commonly 24 hours to 30 days), so a retry after the
window would be a fresh charge — cap retry horizons below the window, or verify-before-retry
beyond it. And keys must be **scoped per logical operation**, not per payment: capture and refund
need different keys, and a retried step must *reuse* its key, never regenerate it.

**"Why not a distributed transaction across the provider and the ledger?"**
Because you can't have one: the provider is a third party offering an API, not a two-phase-commit
participant. And even internally, 2PC couples availability — a stuck coordinator blocks
everyone — and still wouldn't cover the external call. The saga is what remains once 2PC is off
the table: sequence, compensation, idempotency.

**"What if the compensation fails permanently?"**
Retries with backoff, then `NEEDS_REVIEW` with funds-in-limbo alerting. The workflow stays open —
durable timers make "wait for a human" free — the history shows exactly what was attempted, and
the human's decision re-enters as a signal. The rule: never auto-abandon with funds held.

**"How do you prove to an auditor that no double-credit happened?"**
Two artifacts, one structural and one historical. Structural: the ledger's unique constraint on
idempotency keys makes a duplicate entry per key *impossible*, not merely unlikely. Historical:
the workflow event history shows every credit command and its outcome. Reconciliation reports add
independent confirmation on top.

**"One customer fires 500 payments at once — hot workflow?"**
No — and the reason is instructive. Each payment is its own workflow, so per-*payment*
serialization is exactly what you want (a payment's steps must be ordered), while the 500
payments parallelize across shards for free. Contrast with the engine question's hot-workflow
prompt: there the entity had to be split; here the entity split is natural to the domain.

## Interview Angle

Lead with orchestration over choreography and *why money forces it* — single owner of state,
compensation ordering, one audit trail. Don't redesign the engine; reference
[the design](design-a-workflow-engine.md) and spend your time on the money-specific layers:
idempotency keys derived from workflow identity, dedup at the ledger, compensations as fallible
activities, and the `NEEDS_REVIEW` escape hatch. The double-charge timeout question is
near-guaranteed — answer with "the retry becomes a read" and volunteer the dedup-window caveat
before it's asked. Close with reconciliation, framed correctly: backstop, not mechanism. The
[foundations vocabulary](distributed-systems-foundations.md) — at-least-once, effectively-once,
dedup at the receiver — carries the cross-questioning.
