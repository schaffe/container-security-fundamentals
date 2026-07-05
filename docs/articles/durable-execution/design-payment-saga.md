---
title: "System Design: Payment Saga Orchestrator"
section: "Durable Execution"
order: 12
---

# System Design: Payment Saga Orchestrator

## Overview

"Design a payment saga orchestrator" is the money-flavored skin on the
[workflow engine question](design-a-workflow-engine.md#variants): a service that drives a
multi-step payment — hold funds, capture, credit the ledger, notify — across services that can
each fail independently, with no distributed transaction to hide behind. The interviewer is
testing whether you can name what replaces the transaction: the **saga pattern**, compensation,
idempotency on every money movement, and an audit trail. This article covers the saga design
itself, the deep-dive prompts, and where the workflow-engine machinery slots in underneath.

## Key Insight

A saga replaces atomicity with **compensation**: each step has an undo (refund, release hold),
and the orchestrator guarantees that either all steps complete or all completed steps are
compensated. But compensation only makes the sequence *recoverable* — it doesn't make individual
steps safe to retry. That takes **idempotency keys on every money movement**, and "exactly-once"
ledger semantics built by deduplicating **at the ledger**, not by hoping the caller never
retries. Saga = compensation for the sequence + idempotency for each step + an event log so you
can prove what happened.

---

## Requirements and API Sketch

**Functional:**

- Execute a payment as an ordered sequence of steps: `AuthorizeCard → HoldFunds → Capture →
  CreditLedger → Notify`, each calling a separate service (PSP, internal ledger, email).
- On failure past the point of no return for earlier steps, run compensations in reverse order
  (release hold, refund capture).
- Query payment state at any time; expose stuck payments for human review.
- Payments may take days (3-D Secure challenges, bank transfers, manual fraud review).

**Non-functional:**

- **No money lost or duplicated** under any single-component crash — the headline requirement,
  stronger than the generic engine's "no workflow lost."
- Every state change must be auditable: who moved what money, when, why, and what the response
  was — regulators and disputes both demand it.
- Scale: modest by engine standards (~100K payments/day is a big shop); correctness dominates
  throughput. Say so — it licenses simple, serialized designs.

```
StartPayment(payment_id, amount, instrument) -> handle    Signal(payment_id, "3ds_completed", ...)
GetPayment(payment_id) -> status/steps/audit              ListStuck(older_than) -> for ops review
```

---

## Design

### Orchestration vs. Choreography

Two ways to run a saga:

- **Choreography**: no coordinator; each service reacts to the previous service's event
  ("FundsHeld" ⇒ capture service acts). Cheap to start, but the saga's logic is smeared across
  every participant: nobody owns the state machine, failure paths multiply combinatorially, and
  answering "where is payment X and why?" means joining logs across services.
- **Orchestration**: one component owns the payment's state machine and *tells* each service
  what to do, recording every command and response.

**Orchestration wins for money**, and you should say why, not just that: money demands a single
authoritative answer to "what state is this payment in," a single place to encode compensation
ordering, and a single audit trail. Choreography trades those away for looser coupling — a good
trade for notification fan-out, a bad one for funds.

### The Saga as a Workflow

The orchestrator is exactly the [durable workflow engine](design-a-workflow-engine.md): the saga
is a workflow, each money movement is an activity (at-least-once, retried, timed out), and
compensation is a `try/catch` in workflow code that runs compensating activities:

```
try:
    AuthorizeCard(...)
    hold = HoldFunds(...);        compensations.push(ReleaseHold(hold))
    cap  = Capture(...);          compensations.push(Refund(cap))
    CreditLedger(...)
except StepFailed:
    for c in reversed(compensations): run_with_retries(c)   # compensations can ALSO fail
```

Two caveats that separate senior answers:

1. **Compensations can also fail.** `Refund` calls the same flaky PSP that `Capture` did. So
   compensations get the same treatment as forward steps — retries, idempotency keys, timeouts —
   and a compensation that exhausts retries escalates to human review; it does not silently drop.
2. **Not everything is compensatable.** A completed payout to an external bank account can't be
   clawed back by an API call. Order steps so the hardest-to-undo step (the "pivot") comes last,
   after everything that might force a rollback.

### Idempotency on Every Money Movement

Every activity that moves money carries an **idempotency key derived from workflow ID + step**
(e.g. `pay-42:capture:1`), propagated to the PSP and to the internal ledger. The key is stable
across retries because it's derived from durable workflow identity, not generated per attempt —
generate-per-attempt is the classic bug, and interviewers probe for it.

**Exactly-once ledger semantics are built on at-least-once activity execution**: the workflow
engine will run `CreditLedger` at least once; the ledger makes duplicates harmless by recording
the idempotency key with the entry (unique constraint) and returning the original result on
replay. Dedup lives **at the ledger, not as hope at the caller** — the receiver is the only
party that can atomically check-and-write. This is the
[effectively-once recipe](distributed-systems-foundations.md#idempotency-and-dedup) applied to
money.

### Event History as the Audit Trail

The engine's per-workflow event log — every command issued, every PSP response, every retry,
every compensation — *is* the audit trail regulators actually want. You don't build a separate
audit system; you expose the history you already persist for replay. Disputes ("we never
captured twice — here's the capture command, its idempotency key, and the PSP's dedup response")
and compliance reviews read the same log.

### Stuck States: Timeouts and Human Review

Money gets stuck in limbo: funds held, capture failing, refund also failing. The design must
name the escape hatch:

- Every step has a **timeout budget**; exhausting retries within it doesn't loop forever — it
  transitions the payment to `NEEDS_REVIEW` and pages/queues for a human.
- Human resolution is a **signal** back into the workflow ("PSP confirms capture went through" /
  "cancel and release"), so the resolution is itself recorded in the history.

### Reconciliation as a Backstop

A periodic job compares the ledger against PSP settlement reports and flags discrepancies.
State this — and state its role: **reconciliation is a backstop, not the mechanism**. If your
correctness story is "reconciliation will catch it," you've designed a system that loses money
for a day and then notices. Idempotency + the saga's state machine are the mechanism;
reconciliation catches the residue (PSP bugs, out-of-band operations, cosmic rays).

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
The defining question. The activity retries with the *same* idempotency key (`pay-42:capture:1`);
the PSP recognizes the key and returns the original result — **the retry becomes a read**, not a
second charge. Follow-ups to expect and pre-empt: the **PSP's dedup window** (many PSPs only
remember keys for 24h–30 days — a retry after the window is a fresh charge, so cap retry
horizons below the window or verify-before-retry) and **key scoping** (the key must be unique
per logical operation, not per payment — capture and refund need different keys, and a re-tried
saga step must reuse, not regenerate).

**"Why not a distributed transaction across PSP and ledger?"**
You can't — the PSP is a third party that offers an API, not a 2PC participant. Even internally,
2PC couples availability (a stuck coordinator blocks everyone) and doesn't cover the external
call anyway. The saga is what's left: sequence + compensation + idempotency.

**"What if the compensation fails permanently?"**
Retries with backoff, then `NEEDS_REVIEW` with funds-in-limbo alerting. The workflow stays open
(durable timers make "wait for human" free), the history shows exactly what was attempted, and
the human's decision re-enters as a signal. Never auto-abandon with funds held.

**"How do you prove to an auditor that no double-credit happened?"**
Two artifacts: the ledger's unique constraint on idempotency keys (structural impossibility of
duplicate entries per key) and the workflow event history showing every credit command and its
outcome. Plus reconciliation reports as independent confirmation.

**"One customer fires 500 payments at once — hot workflow?"**
No — each payment is its own workflow; per-*payment* serialization is what you want (a payment's
steps must be ordered), and payments parallelize across shards for free. Contrast with the
engine question's hot-workflow prompt: here the entity split is natural.

## Interview Angle

Lead with orchestration-over-choreography and *why money forces it* (single owner of state,
compensation ordering, audit). Build the orchestrator as a durable workflow — don't redesign the
engine; reference it ([the design](design-a-workflow-engine.md)) and spend your time on the
money-specific layers: idempotency keys derived from workflow ID + step, dedup at the ledger,
compensations-as-fallible-activities, and the `NEEDS_REVIEW` escape hatch. The double-charge
timeout question is near-guaranteed — answer it with "the retry becomes a read" and volunteer
the dedup-window caveat before they ask. Close with reconciliation, framed correctly: backstop,
not mechanism. The [foundations vocabulary](distributed-systems-foundations.md) (at-least-once,
effectively-once, dedup at the receiver) carries the cross-questioning.
