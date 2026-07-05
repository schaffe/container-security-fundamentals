---
title: "System Design: AI Agent Runtime"
section: "Durable Execution"
order: 11
---

# System Design: AI Agent Runtime

## Overview

"Design a runtime for AI agents" is the 2026-relevant skin over
[the workflow-engine question](design-a-workflow-engine.md): an agent is a loop of plan → act →
observe that may run for hours or days, calls slow flaky expensive APIs (LLMs, tools), waits on
humans, and must never lose progress or double-spend. The engine internals — event log, outbox,
sharding — are unchanged and covered in the workflow-engine article; this article covers the
mapping and the agent-specific pressure points interviewers actually probe: cost control,
non-determinism discipline, history growth, and payload limits. It's also why agents became
durable execution's killer workload
([landscape](durable-execution-fundamentals.md#why-ai-agents-became-the-killer-workload)).

## Key Insight

The agent loop **is** a workflow; every LLM call and tool call **is** an activity. That one
mapping buys the whole reliability story for free — crash-proof loop state, retries with backoff
for rate limits, heartbeats for long calls, signals for human approval — *provided* you hold the
determinism line: the LLM's output is a **recorded activity result**, replayed from history,
never recomputed. An agent that re-asked the model on replay would be nondeterministic (models
aren't pure functions) and would re-pay for every past call. Everything agent-specific in this
design is a consequence of holding that line.

---

## Requirements and API Sketch

**Functional:**

- Start an agent run with a goal/prompt; it loops: ask LLM → parse decision → execute tool →
  feed observation back → repeat until done.
- Tool calls hit external systems (search, code exec, email, payments) — retries, timeouts,
  idempotency all required.
- Human-in-the-loop: pause for approval before irreversible actions; wait indefinitely.
- Budgets: hard caps on tokens/dollars/steps per run — enforced, not advisory.
- Multi-agent: a supervisor fans out to specialist sub-agents and aggregates.

**Non-functional:**

- No run loses progress on any crash — a run that has paid for 30 LLM calls must resume, not
  restart. The headline requirement, and the reason "retry the whole loop" is disqualifying.
- LLM calls: seconds to minutes, rate-limited, occasionally hung — the flakiest dependency
  you'll ever orchestrate. Cost per call is real money, so at-most-once *payment* pressure
  coexists with at-least-once *delivery* reality.
- Runs from seconds to weeks (human waits dominate wall-clock time).

```
StartAgent(goal, budget, tools) -> run_id        Approve(run_id, decision)   # signal/update
GetState(run_id) -> transcript/status            Cancel(run_id)
```

---

## The Design: Mapping Agent Concepts onto Durable Execution

Don't rebuild the engine — state that the substrate is the
[workflow engine](design-a-workflow-engine.md) (event log + replay, transactional outbox, sharded
single-writer orchestrator) and spend the interview on the mapping:

| Agent concept | Durable-execution primitive | Why |
|---|---|---|
| Plan → act → observe loop | Workflow code (deterministic) | Loop counter, transcript refs, budget — all durable local state; crash ⇒ replay, not restart |
| LLM call | Activity with retry policy | Flaky + slow + expensive ⇒ backoff on 429s, timeout per attempt |
| Tool call | Activity with idempotency key | Side effects are at-least-once ⇒ dedup at the target ([foundations](distributed-systems-foundations.md#idempotency-and-dedup)) |
| Human approval | Signal / update + unbounded wait | Durable wait costs nothing while blocked ([timers/signals](temporal-programming-model.md#interacting-with-running-workflows)) |
| Token/cost budget | Workflow state checked each iteration | Enforced in orchestration code ⇒ survives crashes, can't be bypassed by a retrying activity |
| Sub-agents | Child workflows | Independent histories, parallel fan-out, failure isolation ([child workflows](temporal-programming-model.md#child-workflows)) |
| Cross-team/cross-cluster agents | Nexus operations | Contract-first calls across namespace boundaries ([Nexus](multi-cluster-nexus-advanced.md#nexus)) |
| Long transcript | Blob storage + references in history | Payload limits; history carries pointers, not megabytes |

The agent-specific design decisions, each one interview-defensible:

1. **LLM calls as activities, tuned for the failure mode.** Rate limits (429) want retries with
   exponential backoff + jitter and a low per-attempt timeout; hung streaming calls want
   **heartbeats** so a dead worker is detected in seconds, not at the end of a generous timeout
   ([activity timeouts](temporal-programming-model.md#activity-timeouts)). Retrying an LLM call
   re-pays for it — acceptable for a failed call, so keep attempts bounded and surface
   non-retryable errors (content policy, invalid request) as such instead of burning budget.
2. **Budgets as workflow state with hard stops.** After each LLM activity completes, workflow
   code adds the recorded token/cost usage to a durable counter; when the cap is hit, the loop
   exits to a "needs human decision" state — a signal wait, not an exception swallowed by a
   retry policy. Because the counter lives in orchestration state, it's crash-proof and replay
   reconstructs it exactly; a budget enforced inside the activity would reset on retry.
3. **Human-in-the-loop via signals/updates.** Before an irreversible tool call, the workflow
   waits on an approval signal — for minutes or weeks, consuming no worker resources. Pair the
   wait with a durable timer for escalation ("no answer in 48h ⇒ ping the manager, then
   auto-reject"). Use *update* (not bare signal) when the approver needs a validated,
   synchronous response.
4. **Non-determinism discipline.** Workflow code may branch on LLM output (it's in history), but
   must never *produce* it: no model calls, no sampling, no `random()`/`now()` outside the SDK's
   deterministic wrappers ([determinism constraints](temporal-programming-model.md#determinism-constraints-and-replay)).
   Same rule for tool selection if it involves any randomness — push it into the activity.
5. **Payloads: references, not transcripts.** Histories have per-payload and per-history size
   limits; a 200KB context window passed to every LLM activity blows them fast. Store transcript
   turns and artifacts (files, images, tool outputs) in blob storage; activities take and return
   references plus small summaries. The history stays a compact decision log.
6. **History growth ⇒ continue-as-new.** Every loop iteration appends events (activity
   scheduled/started/completed × calls per turn); a 200-turn agent approaches history limits and
   slows replay. Check `should_continue_as_new` each iteration and roll over, carrying only the
   compact state: goal, budget spent, loop counter, blob references to the transcript — not the
   event history itself ([continue-as-new](temporal-programming-model.md#continue-as-new-and-the-history-limit)).
7. **Multi-agent fan-out via child workflows.** Supervisor spawns specialist children (research,
   code, review), each with its own history, budget slice, and continue-as-new schedule;
   supervisor aggregates results and enforces the global budget. For agents owned by *other
   teams*, call them as Nexus operations across namespaces rather than reaching into their
   workflows.

---

## Deep-Dive Prompts Interviewers Pull

**"The agent crashed after paying for 30 LLM calls — what re-executes?"**
Nothing. The 30 completed calls exist in history as recorded activity results; a new worker
replays the workflow code, and each `execute_activity` call is satisfied from history — no
network call, no tokens, no money. Only an activity that was *in flight* at crash time runs
again, under its retry policy — which is why tool calls carry idempotency keys and why LLM calls
bound their attempts. This is the recorded-result rule paying off; it's the single best answer in
this interview.

**"How do you stop a retry storm from bankrupting me during an LLM outage?"**
Layered: per-attempt timeout + capped exponential backoff with jitter on the activity; a maximum
attempt count so the activity *fails* rather than retries forever; the workflow-level budget
counter as the backstop (retries that do succeed still consume budget); and worker-side
concurrency limits so a thousand agents don't synchronize their retries into the provider. The
budget check lives in workflow code precisely because activity-level state resets on retry.

**"Human approval takes two weeks. What does that cost?"**
Almost nothing — a blocked workflow is rows in the store, not a running process. No worker slot,
no container, no connection is held. This is the durable-timer/signal machinery from the
[engine design](design-a-workflow-engine.md); the agent skin adds only the escalation pattern
(timer racing the signal). Contrast explicitly with "agent framework holds the loop in memory,"
which turns two weeks of waiting into two weeks of process babysitting and loses the run on any
deploy.

**"Histories are exploding — a chatty agent does 500 turns."**
Two independent fixes, name both: keep per-event payloads small (blob refs, not transcripts) so
the history is a decision log; and continue-as-new on a turn/size threshold so no single
execution's history is unbounded. Be precise about what crosses the continue-as-new boundary:
inputs to the next execution (goal, counters, refs) — pending signals and in-flight activities
need draining first, which is why the check happens at the top of the loop, not mid-turn.

**"Why not just LangChain/LangGraph a loop with a database checkpoint?"**
Checkpointing state is the easy half; the hard half is everything around it — exactly-once state
transitions, at-least-once dispatch with lease expiry, durable timers that survive restarts,
signal delivery racing completions — i.e., the [workflow engine](design-a-workflow-engine.md).
A hand-rolled checkpoint loop is v1 of that article with the same four failure modes (crash
mid-step double-fires the tool, DB-as-queue, fused orchestration/execution, opaque blob). Framing
the agent framework as the *programming model* and durable execution as the *substrate* — they
compose, not compete — is the senior answer.

**"The model provider returns different outputs for identical requests. Doesn't that break replay?"**
No — and explaining *why not* proves you understand the mechanism. Determinism is required of the
*workflow code*, not the world: the activity ran once, its result was recorded, and replay feeds
the recording back. The model could be discontinued tomorrow and old runs still replay. It breaks
only if someone calls the model *from workflow code* — the number-one code-review rule for this
platform.

## Interview Angle

- Open with the mapping table, not architecture: loop = workflow, LLM/tool = activities,
  approval = signals, budgets = workflow state, fan-out = child workflows. Then say the substrate
  is the [durable workflow engine](design-a-workflow-engine.md) and go deep only where the agent
  workload stresses it: cost, payloads, history growth.
- The recorded-result rule is the load-bearing insight — volunteer the "crash after 30 paid
  calls" story before it's asked.
- Show cost-consciousness as a first-class requirement: budgets in workflow state, bounded
  retries, non-retryable error classification. This is what distinguishes 2026 agent-runtime
  answers from generic workflow answers.
- Keep the framing vendor-neutral with Temporal as the reference implementation; the
  at-least-once + idempotency vocabulary comes from
  [foundations](distributed-systems-foundations.md#at-least-once-at-most-once-exactly-once), the
  primitives from the [programming model](temporal-programming-model.md).
