---
title: "System Design: AI Agent Runtime"
section: "Durable Execution"
order: 11
---

# System Design: AI Agent Runtime

## Overview

"Design a runtime for AI agents" is the 2026-relevant skin over the
[workflow-engine question](design-a-workflow-engine.md). An agent is a loop — plan, act, observe —
that may run for hours or days, calls slow, flaky, *expensive* APIs (LLMs and tools), waits on
humans, and must never lose progress or double-spend. The engine internals underneath — event log,
transactional outbox, sharding — are unchanged from the workflow-engine article, so this one
covers what's actually different: the mapping of agent concepts onto durable-execution primitives,
and the agent-specific pressure points interviewers probe — cost control, non-determinism
discipline, history growth, and payload limits. It is also the explanation for why agents became
durable execution's
[killer workload](durable-execution-fundamentals.md#why-ai-agents-became-the-killer-workload).

## Key Insight

The agent loop **is** a workflow, and every LLM call and tool call **is** an activity. That single
mapping buys the entire reliability story at once: crash-proof loop state, retries with backoff
for rate limits, heartbeats for long calls, signals for human approval.

But the mapping holds only if you hold the determinism line: **the LLM's output is a recorded
activity result, replayed from history, never recomputed.** An agent that re-asked the model
during replay would be non-deterministic — models are not pure functions — and would re-*pay* for
every past call besides. Every agent-specific decision in this design is a consequence of holding
that line.

---

## Requirements and API Sketch

Functional:

- Start an agent run with a goal; it loops — ask the LLM, parse the decision, execute the chosen
  tool, feed the observation back — until done.
- Tool calls hit external systems (search, code execution, email, payments), so retries,
  timeouts, and idempotency are all required.
- Human-in-the-loop: pause before irreversible actions and wait — possibly indefinitely — for
  approval.
- Budgets: hard caps on tokens, dollars, and steps per run — *enforced*, not advisory.
- Multi-agent: a supervisor fans out to specialist sub-agents and aggregates their results.

Non-functional:

- The headline: no run loses progress on any crash. A run that has paid for thirty LLM calls must
  *resume*, not restart — "retry the whole loop" is a disqualifying answer here.
- LLM calls take seconds to minutes, are rate-limited, and occasionally hang — the flakiest
  dependency you will ever orchestrate. And each call costs real money, so at-most-once *payment*
  pressure coexists with at-least-once *delivery* reality.
- Runs last from seconds to weeks, with human waits dominating wall-clock time.

```
StartAgent(goal, budget, tools) -> run_id        Approve(run_id, decision)   # signal/update
GetState(run_id) -> transcript/status            Cancel(run_id)
```

---

## The Design: Mapping Agent Concepts onto Durable Execution

Don't rebuild the engine in this interview. State that the substrate is the
[durable workflow engine](design-a-workflow-engine.md) — event log with replay, transactional
outbox, sharded single-writer orchestrator — and spend your time on the mapping:

| Agent concept | Durable-execution primitive | Why it fits |
|---|---|---|
| Plan → act → observe loop | Workflow code | Loop counter, transcript refs, budget are durable local state; a crash means replay, not restart |
| LLM call | Activity with a retry policy | Flaky, slow, expensive — backoff on 429s, per-attempt timeouts |
| Tool call | Activity with an idempotency key | Side effects are at-least-once, so dedup at the target |
| Human approval | Signal / update + unbounded wait | A durably blocked workflow costs nothing while it waits |
| Token/cost budget | Workflow state, checked each iteration | Crash-proof, replay-exact, and can't be bypassed by a retrying activity |
| Sub-agents | Child workflows | Independent histories, parallel fan-out, failure isolation |
| Cross-team agents | Nexus operations | Contract-first calls across namespace boundaries |
| Long transcript | Blob storage, references in history | History carries pointers, not megabytes |

Then walk the agent-specific decisions, each one defensible on its own:

**LLM calls are activities tuned for their particular failure mode.** Rate-limit errors (429s)
want exponential backoff with jitter and a low per-attempt timeout. Hung streaming calls want
**heartbeats**, so a dead worker is detected in seconds rather than at the end of a generous
timeout ([activity timeouts](temporal-programming-model.md#activity-timeouts)). And because
retrying an LLM call re-*pays* for it, keep attempt counts bounded and classify errors carefully —
a content-policy rejection or malformed request is non-retryable and should fail fast instead of
burning budget on retries that cannot succeed.

**Budgets are workflow state with hard stops.** After each LLM activity completes, workflow code
adds the recorded token and dollar usage to a durable counter; when the cap is hit, the loop
exits to a "needs human decision" state — a signal wait, not an exception swallowed by a retry
policy. The placement is the point: because the counter lives in orchestration state, it survives
crashes and replay reconstructs it exactly. A budget tracked inside an activity would reset on
every retry — which is precisely the bug this placement avoids.

**Human-in-the-loop is signals and updates.** Before an irreversible tool call, the workflow
blocks on an approval signal — for minutes or weeks — consuming no worker resources while
blocked. Pair the wait with a durable timer for escalation: no answer in 48 hours, ping the
manager; still nothing, auto-reject. When the approver needs a validated, synchronous response,
use an [update](temporal-programming-model.md#interacting-with-running-workflows) rather than a
bare signal.

**Non-determinism discipline, agent flavor.** Workflow code may freely *branch* on LLM output —
it's a recorded result in history. What it must never do is *produce* it: no model calls, no
sampling, no `random()` or `now()` outside the SDK's deterministic wrappers
([the constraints](temporal-programming-model.md#determinism-constraints-and-replay)). The same
rule covers tool selection: if choosing the next tool involves any randomness, push the choice
into an activity.

**Payloads are references, not transcripts.** Event histories have per-payload and total size
limits, and a 200KB context window passed into every LLM activity blows through them fast. Store
transcript turns and artifacts — files, images, tool outputs — in blob storage; activities accept
and return references plus small summaries. The history stays what it should be: a compact
decision log.

**History growth forces continue-as-new.** Every loop iteration appends several events, and a
200-turn agent approaches the history limits while its replays get slower. Check a
`should_continue_as_new` condition at the top of each iteration and roll over when it trips,
carrying forward only compact state — the goal, budget spent, loop counter, and blob references
to the transcript
([continue-as-new](temporal-programming-model.md#continue-as-new-and-the-history-limit)).

**Multi-agent fan-out uses child workflows.** A supervisor spawns specialist children — research,
code, review — each with its own history, its own budget slice, and its own continue-as-new
schedule; the supervisor aggregates results and enforces the global budget. For agents owned by
*other teams*, call them as [Nexus operations](multi-cluster-nexus-advanced.md#nexus) across
namespace boundaries rather than reaching into their workflows.

---

## Deep-Dive Prompts Interviewers Pull

**"The agent crashed after paying for 30 LLM calls — what re-executes?"**
Nothing re-executes, and this is the single best answer in the interview. The thirty completed
calls exist in history as recorded activity results. A new worker replays the workflow code, and
each `execute_activity` call is satisfied from history — no network call, no tokens, no money.
The only thing that runs again is an activity that was *in flight* at the moment of the crash,
under its own retry policy — which is exactly why tool calls carry idempotency keys and LLM calls
bound their attempts.

**"How do you stop a retry storm from bankrupting me during an LLM outage?"**
In layers. On the activity: a per-attempt timeout, capped exponential backoff with jitter, and a
maximum attempt count so the activity eventually *fails* rather than retrying forever. In the
workflow: the budget counter as the backstop — even retries that succeed consume budget. On the
worker: concurrency limits, so a thousand agents can't synchronize their retries into the
provider. And note *why* the budget lives in workflow code: activity-local state resets on every
retry; orchestration state doesn't.

**"Human approval takes two weeks. What does that cost?"**
Almost nothing. A blocked workflow is rows in a database, not a running process — no worker slot,
no container, no open connection. This is the durable timer and signal machinery from the
[engine design](design-a-workflow-engine.md); the agent adds only the escalation pattern (a timer
racing the approval signal). The contrast to draw explicitly: an agent framework that holds the
loop in process memory turns two weeks of waiting into two weeks of process babysitting — and
loses the run on the first deploy.

**"Histories are exploding — a chatty agent does 500 turns."**
Two independent fixes, and the strong answer names both. Keep per-event payloads small — blob
references, not transcripts — so the history is a decision log rather than a data store. And
continue-as-new on a turn or size threshold so no single execution's history is unbounded. Then
be precise about the rollover boundary: what crosses is the input to the next execution — goal,
counters, references — while pending signals and in-flight activities must drain first, which is
why the check lives at the top of the loop, not mid-turn.

**"Why not just LangChain or LangGraph with a database checkpoint?"**
Because checkpointing state is the easy half of the problem. The hard half is everything around
it: exactly-once state transitions, at-least-once dispatch with lease expiry, durable timers that
survive restarts, signal delivery racing completions — in other words, the
[workflow engine](design-a-workflow-engine.md). A hand-rolled checkpoint loop is that article's
v1, with the same four failure modes — crash mid-step double-fires the tool, the database becomes
the queue, orchestration and execution are fused, and the checkpoint blob is opaque. The senior
framing: the agent framework is the *programming model*, durable execution is the *substrate* —
they compose rather than compete.

**"The model returns different outputs for identical requests. Doesn't that break replay?"**
No — and explaining why not proves you understand the mechanism. Determinism is required of the
*workflow code*, not of the world. The activity ran once; its result was recorded; replay feeds
the recording back. The model could be discontinued tomorrow and old runs would still replay
perfectly. The only way to break replay is to call the model *from workflow code* — which is the
number-one code-review rule on this platform.

## Interview Angle

- Open with the mapping, not with architecture: loop = workflow, LLM and tool calls =
  activities, approval = signals, budgets = workflow state, fan-out = child workflows. Then state
  that the substrate is the [workflow engine](design-a-workflow-engine.md) and go deep only where
  the agent workload stresses it — cost, payloads, history growth.
- The recorded-result rule is the load-bearing insight. Volunteer the "crashed after 30 paid
  calls" story before it's asked.
- Treat cost-consciousness as a first-class requirement: budgets in workflow state, bounded
  retries, non-retryable error classification. This is what distinguishes a 2026 agent-runtime
  answer from a generic workflow answer.
- Keep the framing vendor-neutral with Temporal as the reference implementation. The
  at-least-once and idempotency vocabulary comes from
  [foundations](distributed-systems-foundations.md#at-least-once-at-most-once-and-the-myth-of-exactly-once);
  the primitives come from the [programming model](temporal-programming-model.md).
