# Dojo Feature Parity — Overview

## What this plan is for

The Go server's `feat/dojo-feature-parity` branch (in
`/Users/punk1290/git/ag-ui-go-server-example`) turned six previously-stub endpoints
into the six **canonical AG-UI "dojo" demos**, each exercising a distinct AG-UI
protocol pattern. The Dart SDK (`/Users/punk1290/git/ag-ui/sdks/community/dart`)
already ships the typed events and per-feature convenience methods for all six.

The Flutter demo (`ag_ui_demo`) **already lists all six endpoints** in its nav rail,
but routes every one of them through a single generic `ChatPageState`
(`lib/pages/chat_page.dart`) that flattens *all* events into a flat
`List<ChatMessage>` and renders them as chat bubbles. That generic handler "works"
in the sense that it doesn't crash, but it does not *demonstrate* any of the six
patterns — a state-driven checklist renders as a wall of `📊` text, a collaborative
recipe never appears as a recipe, and client tools are never defined so the
tool-calling routes can never actually call a tool.

**This plan upgrades each of the six endpoints from "generic event dump" to a
purpose-built UI that exercises the real protocol contract**, and adds the small
amount of client-side SDK plumbing (tool definitions, the tool-result round-trip,
RFC-6902 patch application) that the dojo patterns require.

## Repositories involved

| Repo | Role | Local path |
|------|------|------------|
| `ag_ui_demo` | Flutter frontend (this repo) | `/Users/punk1290/git/ag_ui_demo` |
| `ag-ui-go-server-example` | Go backend, branch `feat/dojo-feature-parity` | `/Users/punk1290/git/ag-ui-go-server-example` |
| `ag-ui` (dart SDK) | Path dependency (`ag_ui`) | `/Users/punk1290/git/ag-ui/sdks/community/dart` |

> All server behavior cited below was read directly from the `feat/dojo-feature-parity`
> branch and is current as of this plan. The server changes are **already shipped**;
> nothing in the Go repo needs to change for this plan.

## The two mechanisms behind the six features

The six dojo routes collapse into exactly **two client-side mechanisms**. Organizing
the plan around the mechanism (not one-file-per-feature) keeps the shared
infrastructure in one place and avoids re-deriving it three times.

### Mechanism A — Client-tool round-trip (`02`, `03`)

The client **defines tools** in `RunAgentInput.tools`. The model decides to call one;
the server streams `TOOL_CALL_START / ARGS / END` live and then finishes with a plain
`RUN_FINISHED` (success) — it **cannot execute client tools**. The client executes the
tool locally (or asks the user), appends a `role:tool` `ToolMessage` carrying the
result to the conversation, and **re-runs** (Run B) with the full history. The model
sees the result and continues until it produces a final text answer.

| Route | System-prompt posture | Client-side rendering |
|-------|----------------------|----------------------|
| `agentic_chat` | "call a tool if one fits, else answer" | execute tool, show result inline |
| `tool_based_generative_ui` | "you MUST prefer a rendering tool over prose" | render the tool call **as a UI card** |
| `human_in_the_loop` | "call the approval tool before consequential actions, wait for the result" | render the proposed call as an **approve / deny** gate; the user's decision is the tool result |

**Critical correction to earlier analysis:** `/human_in_the_loop` is built from
`AgenticChatConfig()` (`runconfig.go:84-91`), which sets `NeverInterrupt: true` and
`StreamToolCalls: true`. The server's interrupt/resume branch (`loop.go:261`) is
therefore **never reached** on this route. The route's own comment
(`runconfig.go:79-80`) states the decision is *"carried back as a role:tool result on
the follow-up run."* The elaborate `RUN_FINISHED`-with-interrupt + `resume[]` +
`responseSchema` contract that the protocol *also* supports belongs to the
`/agentic` default route (`DefaultRunConfig`, non-streaming, `NeverInterrupt: false`)
— **a route the Dart client cannot drive anyway** (see "Resume gap" below). So HITL in
Flutter is the *same* round-trip as `02`, plus an approval UI. No resume support is
required for this plan.

### Mechanism B — Live state projection (`04`)

The server owns a document and emits a `STATE_SNAPSHOT` (the initial document) followed
by a stream of `STATE_DELTA` events carrying **RFC-6902 (JSON Patch) operations**. The
client keeps a local copy of the document, applies each patch as it arrives, and
renders the document **reactively** — the deltas animate the UI.

| Route | Document shape | What the deltas drive |
|-------|----------------|----------------------|
| `agentic_generative_ui` | `{steps:[{description,status}]}` | a checklist whose rows flip `pending → in_progress → completed` |
| `shared_state` | `{recipe:{title,servings,ingredients[],steps[]}}` | a recipe card edited collaboratively by agent + user |
| `predictive_state_updates` | `{recipe:{…}}` + ephemeral `/_predictive` | optimistic "ghosted" draft text that commits to `/recipe/steps` |

The Dart SDK decodes `StateDeltaEvent.delta` (a `List<Map<String,dynamic>>` of patch
ops) but **does not apply patches** — the app must apply them. See `01` for the applier.

## The Resume gap (why we don't use the interrupt/resume protocol)

The Go server can pause a run and finish with an interrupt outcome, persisting the
paused run keyed by `threadID/runID`, and resume it when the client sends a top-level
`RunAgentInput.Resume` array (`loop.go:109-167`). **The Dart SDK has no way to send
this.** Neither `SimpleRunAgentInput` (`client.dart:673`) nor `RunAgentInput`
(`context.dart:51`) has a `resume` field, and `SimpleRunAgentInput.toJson()` emits no
`resume` key. The Go code even calls this out:
`runconfig.go:35` — *"feature routes can't resume — the Dart client has no resume path."*

This is **not a blocker** for any of the six dojo routes, because none of the routes the
Flutter app drives use the interrupt path (they all set `NeverInterrupt: true`). It is
recorded here only so a future implementer does not try to build an approval flow on
the interrupt/resume protocol. If the protocol-level interrupt/resume demo is ever
wanted, it would require an SDK enhancement (add a `ResumeEntry` type + `resume` field +
serialization) and is **out of scope** for this plan.

## Architecture strategy

1. **Keep the generic `ChatPageState` for `agentic_chat`** (Mechanism A's simplest
   case) and for the existing multimodal/reasoning tabs. Extend it minimally.
2. **Add a small shared service/state layer** for the things every dojo feature needs
   that the current service hard-codes away: passing `tools`, passing/seeding `state`,
   carrying conversation history across turns, and the tool-result re-run (`01`).
3. **Build a dedicated page + state class per *mechanism*** — not per feature — and
   parameterize by `EndpointConfig`. Mechanism A's three routes share one page family;
   Mechanism B's three routes share another. Per-feature differences are: which tools
   are defined, which system prompt the server uses (server-side, nothing to do), and
   which widget renders the document.
4. **Route in `main.dart` by a feature-kind flag on `EndpointConfig`** (extend the
   existing `isMultimodal` pattern), so the nav rail dispatches each endpoint to the
   right page type.

## File / section map

| File | Covers |
|------|--------|
| `01-shared-infrastructure.md` | `EndpointConfig` feature-kind flag; service-layer extensions (tools, state, history, re-run); the RFC-6902 patch applier; `main.dart` routing |
| `02-client-tools.md` | `agentic_chat` + `tool_based_generative_ui`: tool definitions, collecting tool calls from the stream, the `ToolMessage` round-trip, generative-UI card rendering |
| `03-human-in-the-loop.md` | `human_in_the_loop`: the approval-gate UI built on `02`'s round-trip (approve → execute & return result; deny → return refusal) |
| `04-live-state.md` | `agentic_generative_ui` + `shared_state` + `predictive_state_updates`: snapshot + delta projection, the checklist widget, the recipe-card widget, the predictive ghost-text widget |
| `05-testing-and-sequencing.md` | build order, per-feature manual test checklist, prerequisites, out-of-scope |

## Verified facts this plan relies on

These were confirmed by reading the source on the named branches (not inferred). **Go
line numbers throughout this plan are approximate** (the branch moves) and several omit
the `internal/agent/` path prefix — trust the symbol/function names and re-grep for the
exact line rather than trusting the number.

- All six convenience methods exist on `AgUiClient`: `runAgenticChat`,
  `runHumanInTheLoop`, `runAgenticGenerativeUi`, `runToolBasedGenerativeUi`,
  `runSharedState`, `runPredictiveStateUpdates` (`client.dart:102-156`). All take a
  `SimpleRunAgentInput`. (We will mostly keep using the generic `runAgent(path, input)`
  the service already calls, which is what the convenience methods delegate to.)
- `SimpleRunAgentInput` carries `tools`, `state`, `messages`, `context`,
  `forwardedProps`, `config`, `metadata` and serializes all of them
  (`client.dart:673`, `toJson` at `client.dart:715`). So client tools and state seeding
  work today with no SDK change.
- `StateDeltaEvent.delta` is `List<Map<String,dynamic>>` of raw RFC-6902 ops; the SDK
  applies nothing.
- `predictive_state_updates` emits prediction deltas under `/_predictive` and commits
  the final value at `/recipe/steps`, then removes `/_predictive`
  (`predictive.go:22-35,63`).
- `agent_complete` is a `CustomEvent` emitted only on the converged success path
  (`loop.go:313-315`).
- `human_in_the_loop` reads a per-request approval toggle from the `X-AG-Approval`
  header or `?approval=` query param; empty keeps the gate on, `off` makes it behave
  like `agentic_chat` (`main.go:214-222`, `runconfig.go:84-91`). The toggle changes only
  the **system prompt** — the mechanism is the client-tool round-trip either way.
