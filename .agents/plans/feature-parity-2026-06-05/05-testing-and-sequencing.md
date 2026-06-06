# 05 — Testing & Sequencing

## Prerequisites

- Go server (`feat/dojo-feature-parity`) running at `http://localhost:8000` (or set
  `AG_UI_BASE_URL`). `OPENAI_API_KEY` set in the server env (all six routes drive the
  model). `scripts/dev.sh` starts server + app together.
- The Dart SDK path dependency at `/Users/punk1290/git/ag-ui/sdks/community/dart` is on
  a commit that includes the six `run*` convenience methods and `SimpleRunAgentInput`
  with `tools`/`state`/`config`/`metadata` (current `dart-sdk`/`main` both have these —
  verified). **No SDK change is required by this plan.**
- Optional server env for the checklist pace: `AGENTIC_UI_PACE_MS` (default ~600).

## Build order

The dependency graph is linear at the infra layer, then fan-out:

```
01 (infra) ─┬─ 02 (client tools) ── 03 (HITL, reuses 02's round-trip)
            └─ 04 (live state: checklist → shared_state → predictive)
```

1. **`01` first, in full.** Nothing else compiles meaningfully without `run(...)`,
   `applyJsonPatch`, the shared event mixin, the `FeatureKind` routing, and per-endpoint
   `tools` + the `seedStateFns` registry.
   Land it behind no behavior change: existing tabs must be byte-for-byte equivalent.
2. **`02` agentic_chat path** (the round-trip on the generic page) — smallest end-to-end
   proof that tools + re-run work. Then the `tool_based_generative_ui` card.
3. **`03`** — pure delta over `02` (`_execute` becomes a user decision + approval card).
4. **`04`** in the order checklist → shared_state → predictive. The checklist is the
   simplest delta consumer; shared_state adds the editable card + state echo; predictive
   adds only the ghost/commit visual on top of the same machinery.

Each step is independently shippable and testable against the live server.

## Per-feature manual test checklist

**Infra (`01`)**
- [ ] `flutter build macos` (and/or `flutter run`) passes; no analyzer errors.
- [ ] Existing tabs unchanged: agentic_chat (plain), vision/audio/document, reasoning,
      image-gen all behave as before.
- [ ] `applyJsonPatch` unit tests: `replace` scalar, `add` to `Map` key, `add` array
      `-` append, `add` array index insert, `remove` array index, `remove` map key,
      `/_predictive` add-then-remove round-trip leaves the doc clean, plus the exact
      per-route delta sequences (`01` §3 table).
- [ ] `availableEndpoints` is still `const` (seed state lives in the non-const
      `seedStateFns` registry, not on `EndpointConfig`). `flutter analyze` clean — no
      stray `?.`/`.cast<>()` infos on the acceptance gate.
- [ ] Shared mixin: a `RunErrorEvent` injected into the stream surfaces a visible error
      and clears the loading flag (no hang).

**agentic_chat (`02`)**
- [ ] "what is 12*7+3?" → `calculate` call visible → result `87` → final answer text.
- [ ] "what time is it?" → `get_current_time` → result → answer.
- [ ] A no-tool prompt ("tell me a joke") still answers as plain chat.
- [ ] Two-tool prompt completes via sequential round-trips without user action.

**tool_based_generative_ui (`02`)**
- [ ] "show a card about the Eiffel Tower" → `render_card` → **card widget** (title,
      facts), not prose → model closing line.
- [ ] A prompt with no fitting tool falls back to plain text.

**human_in_the_loop (`03`)**
- [ ] "email alice@example.com that the report is ready" → **approval card** with parsed
      `to/subject/body` → Approve → `{approved:true}` result → confirmation text.
- [ ] Same prompt → Deny → `{approved:false}` result → model acknowledges, no resend.
- [ ] App-bar toggle → `?approval=off` → action proceeds without an approval card.
- [ ] Dispose page mid-decision → pending completer resolved as denial; no throw.
- [ ] **Gating actually fires** (resolves the `03` I4 tension): with approval **on**,
      the model *calls the action tool and waits* for the result — it does not just
      describe the action in prose and stop. If this proves flaky, switch to a dedicated
      `request_approval(summary, action)` tool (`03` §"design tension").

**agentic_generative_ui (`04`)**
- [ ] Any prompt → checklist of pending rows → rows animate
      pending→in_progress→completed → "All steps complete."

**shared_state (`04`)**
- [ ] Recipe card visible from seed.
- [ ] "double the servings and add basil" → servings + ingredients update live;
      assistant summary appears.
- [ ] Hand-edit the card (title/servings/ingredient), then send another instruction →
      server continues from the edited recipe (last-writer-wins).

**predictive_state_updates (`04`)**
- [ ] "rewrite the steps in more detail" → ghosted draft streams in faded → on commit
      the ghost clears and steps show at full opacity.
- [ ] Ignoring `/_predictive` deltas still yields identical final `/recipe/steps`
      (correctness-of-commit check).

**Cross-cutting**
- [ ] Switching tabs mid-stream never throws (`_disposed` guard in every state class).
- [ ] Connection status indicator reflects connecting/connected/disconnected/error
      (and does not blink `disconnected` between Run A and Run B of a tool round-trip).
- [ ] No `notifyListeners()` after dispose.
- [ ] **`RUN_ERROR` surfacing** on every new page: force it via a deliberately malformed
      client tool schema (server rejects → `RUN_ERROR`) or non-convergence — the page
      shows the error, stops the spinner, and (client-tools) abandons the round-trip.
- [ ] **Reasoning/thinking** on the client-tools pages renders like the generic page
      (no regression); on live-state pages it behaves per the documented decision
      (`01` §4b).
- [ ] **No-tool-call fallback**: a prose-only answer on `tool_based_generative_ui`
      renders the streamed text (not a blank screen).
- [ ] **Re-entrancy**: a tool round-trip never double-appends `ToolMessage`s; a second
      terminal event mid-flight does not launch a duplicate `_resolveToolCalls`
      (`_busy` guard). Disposing mid-round-trip unwinds cleanly.

## Notes & gotchas

- **Tool `arguments` is a JSON string**, not a map — `jsonDecode` it before use, and
  guard the empty-string case (no-arg tools).
- **`ToolMessage.toolCallId` must match** the `ToolCall.id` from the assistant message,
  and the assistant message that requested the call must precede it in the history of
  Run B. This ordering is enforced by the **upstream model provider** (e.g. OpenAI
  rejects a `tool` message that doesn't follow an assistant message carrying that
  `tool_call_id`), **not** by the Go server — `toEinoMessages` does no ordering/pairing
  check. So a 400 here points at the model API, not the handler.
- **`RUN_ERROR` is an event, not an exception** (`RunErrorEvent` in the stream) — the
  `try/catch` around `_service.run` never catches it. Every page needs an explicit
  branch (`01` §4a).
- **Clone snapshots before mutating** (`jsonDecode(jsonEncode(...))`); event objects may
  hand back unmodifiable collections and are shared with the SDK.
- **Stable `threadId` per page session** (generated once), not per send.
- **`extraQuery` on the endpoint string** is how the HITL approval toggle travels;
  `runAgent` concatenates `baseUrl/endpoint`, so `human_in_the_loop?approval=off`
  resolves correctly.

## Out of scope

- **Protocol-level interrupt/resume** (`RUN_FINISHED` interrupt + `resume[]`). The Dart
  SDK has no `resume` field and none of the six dojo routes use the interrupt path, so
  it's neither needed nor reachable here. Adding it would be an SDK enhancement
  (`ResumeEntry` type + `resume` field + serialization) plus the `/agentic` default
  route — a separate effort.
- **`agent_complete` analytics surface** beyond an optional "done" badge.
- **Persistence** of threads/recipes across app restarts.
- **Server changes** — none. The `feat/dojo-feature-parity` branch already ships every
  endpoint this plan targets.
