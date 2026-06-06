# 04 — Live State (`agentic_generative_ui` + `shared_state` + `predictive_state_updates`)

Mechanism B. Depends on `01` (service `run`, `applyJsonPatch`, the `seedStateFns`
registry, and the shared event mixin).

## The shared contract (verified)

All three routes emit:
1. `STATE_SNAPSHOT` — the initial document (`StateSnapshotEvent.snapshot`, a `Map`).
2. a stream of `STATE_DELTA` — each `StateDeltaEvent.delta` is a `List<Map>` of RFC-6902
   ops to apply, in order, to the local document.
3. usually a closing `TEXT_MESSAGE_*` + `MESSAGES_SNAPSHOT` + `RUN_FINISHED`.

The client keeps one mutable document, applies each patch as it arrives, and rebuilds
the widget. **The delta application is identical for all three**; only the document
shape and the widget differ. This is the whole reason to share one page family.

## Shared page / state

`lib/pages/live_state_page.dart` + `LiveStatePageState` (copy the `_disposed` guard).
Core handler:

```dart
dynamic _doc;            // the live document (deep-mutable); null until first snapshot
final List<ChatMessage> _chat = []; // optional: the closing assistant text
bool _loading = false;

void _handleEvent(BaseEvent event) {
  if (event is StateSnapshotEvent) {
    _doc = jsonDecode(jsonEncode(event.snapshot)); // clone → mutable, unaliased
  } else if (event is StateDeltaEvent) {
    _doc = applyJsonPatch(_doc, event.delta);      // .delta is already List<Map<..>>
  } else if (event is RunErrorEvent) {             // arrives via the stream, not a throw
    _loading = false;
    _chat.add(ChatMessage(
      id: 'error_${DateTime.now().millisecondsSinceEpoch}',
      type: ChatMessageType.system,
      content: '⚠️ Run error: ${event.message ?? 'the agent failed'}',
      timestamp: DateTime.now(),
    ));
  } else if (event is RunFinishedEvent) {
    _loading = false;
  } else if (event is CustomEvent && event.name == 'agent_complete') {
    // shared_state-style summary; optional badge. Success path only.
  }
  // TEXT_MESSAGE_* and Reasoning*/Thinking* are handled by the shared mixin (01 §4b/4c):
  // the "what I changed" summary on shared/predictive, and a reasoning affordance (or a
  // documented decision not to surface it) on these pages.
  if (!_disposed) notifyListeners();
}
```

`event.delta` is already `List<Map<String,dynamic>>` in the SDK — no `.cast<>()` needed.
`event.snapshot` is statically `dynamic` (`typedef State = dynamic`); the dojo routes
always send a `Map`, and the `jsonDecode(jsonEncode(...))` clone works regardless.

**Empty / first-paint state.** `_doc` is null until the first `STATE_SNAPSHOT`. For
`shared_state`/`predictive` the page can paint the **seed document** immediately
(`seedStateFns[endpoint.path]?.call()`, `01` §1) so the card isn't blank. The
**checklist has no seed** (by design), so it renders an empty-state prompt
("Send a message to generate a plan…", mirroring `chat_page.dart`'s empty state) until
the first snapshot returns. Show `_loading` as a spinner/progress bar in all three.

The widget reads `_doc` and renders per `endpoint.featureKind` sub-type. Use a small
discriminator (e.g. `endpoint.path`) to pick the renderer, or three thin subclasses.

`build` for the page: a header (endpoint name/description), the **document renderer**
filling the body, and a text input at the bottom that calls
`state.send(text)` → `_service.run(endpoint.path, threadId:_threadId,
messages:_history, state: _docForRequest())`.

---

## A. `agentic_generative_ui` — animated checklist

**Document:** `{ "steps": [ {description, status}, … ] }`. Status flows
`pending → in_progress → completed`. The server paces the deltas (env
`AGENTIC_UI_PACE_MS`, default ~600 ms) so the checklist animates row by row
(`agenticui.go`). Deltas are `replace /steps/{i}/status`.

**Delta from current behavior:** the generic `ChatPageState` already *parses* these
exact deltas but renders them as appended `📊`-prefixed text lines
(`chat_page.dart:398-470`). The upgrade replaces that text dump with a real checklist.

**Renderer:** a `ListView` of rows, each:
```
[✓] Understand the request: …      (completed → green check)
[◐] Draft the response             (in_progress → spinner)
[ ] Review                         (pending → empty box)
```
Map status → icon: `completed → Icons.check_circle (green)`, `in_progress →
CircularProgressIndicator (small)`, `pending → Icons.radio_button_unchecked (grey)`.
Because the doc mutates in place and `notifyListeners` fires per delta, the rows flip
live as the paced deltas arrive — that *is* the demo.

No tools, no state seed required; any user message kicks off a fresh plan.

---

## B. `shared_state` — collaborative recipe card

**Document:** `{ "recipe": {title, servings, ingredients:[{name,amount}], steps:[…]} }`.
The server seeds from `RunAgentInput.state.recipe` if present, else a small default —
**verified** in `seedRecipe` (`sharedstate.go:97-106`): *"It adopts state.recipe
verbatim (so a user-edited document round-trips), or starts from a small default recipe
when none is provided."* (`shared_state` uses the dedicated `SharedState.Run` entry
point, not the generic `agent.Run`, so this is its own seeding path.) The model edits via an internal `apply_recipe_changes` tool whose
calls are **suppressed on the wire** — the edits surface only as granular `STATE_DELTA`
ops on `/recipe/*` (`replace /recipe/title`, `replace /recipe/servings`,
`add /recipe/ingredients/-`, `remove /recipe/ingredients/{i}`, `add /recipe/steps/-`).
Then a short `TEXT_MESSAGE` summary ("I doubled the servings and added basil.").

**Delta from current behavior:** generic handler shows `STATE_SNAPSHOT` as `📊` text
and ignores `/recipe/*` deltas (its delta branch only matches `/steps/*/status`). So the
recipe is currently invisible. The upgrade renders it as a card and applies the patches.

**The collaboration loop (the point of this feature):**
1. Server seeds + streams edits → card updates live.
2. The user can **edit the card directly** in the Flutter UI (change title, +/- a
   serving, add/remove an ingredient). Those edits mutate `_doc` locally.
3. On the next send, pass the **edited recipe back as `state`**:
   `_service.run('shared_state', state: {'recipe': _doc['recipe']}, messages: _history)`.
   The server adopts it verbatim (`seedRecipe`, `sharedstate.go:97-106`,
   last-writer-wins) and edits from there. → genuine two-way shared state.
   **Typing constraint:** `SimpleRunAgentInput.toJson` asserts `state is
   Map<String,dynamic>`, so the value passed as `state` must be a
   `Map<String,dynamic>` — which `_doc['recipe']` is, because it came through the
   `jsonDecode(jsonEncode(...))` clone. Do **not** pass a typed model object here.

**Renderer:** a card with an editable title (`TextField`), a servings stepper
(`- N +`), an ingredients list (each row removable, plus an "add ingredient" field),
and a numbered steps list.

> **Read `servings` as `num`, not `int`.** The seed/snapshot encodes it as `float64`
> server-side while an *edit* delta sends an `int` (`sharedstate.go`), so over the wire
> it can arrive as either `2` or `2.0`. Read it defensively:
> `((_doc['recipe']['servings'] as num?) ?? 0).toInt()`. A hard `as int` throws a
> `TypeError` on a `2.0` payload. Below the card, the assistant's summary line + the input box
("ask the assistant to change the recipe…").

```
┌─ Tomato Pasta ───────────  servings: [-] 2 [+] ┐
│ Ingredients                                     │
│  • 200g  pasta                              [x] │
│  • 3     tomatoes                           [x] │
│  + add ingredient …                             │
│ Steps                                           │
│  1. Boil water                                  │
│  2. Cook pasta 9 min                            │
└─────────────────────────────────────────────────┘
"I added tomatoes and a boiling step."   ← assistant summary
```

`seedStateFns['shared_state']` (the side registry from `01` §1, **not** a field on the
`const` `EndpointConfig`) returns the initial recipe so the card has content before the
first message.

---

## C. `predictive_state_updates` — optimistic ghost text

**Document:** `{ "recipe": {…} }` plus an **ephemeral** `/_predictive` namespace.
As the model streams new steps, the server re-`add`s the **whole `/_predictive` object**
each tick with value `{"draft": "<accumulated text>"}` (it does **not** emit a nested
`/_predictive/draft` path — verified in `predictive.go`); on completion it **commits**
the parsed steps at `/recipe/steps` and **removes** `/_predictive`. So the real op
sequence is: `add /_predictive {draft:…}` (repeated) → `add /recipe/steps [..]` →
`remove /_predictive`. A client that drops every `/_predictive` delta still reaches the
correct final state — the committed steps are recomputed from the full generation, not
promoted from the last prediction, so predictions are pure enhancement.

**Delta from current behavior:** invisible today (generic handler ignores
`/recipe/*` and `/_predictive`). New feature end to end.

**Renderer:** the recipe steps list, plus a **ghosted draft overlay** driven by
`_doc['_predictive']?['draft']`:
- While `_doc['_predictive']?['draft']` is non-null → render that text **faded /
  italic** below the committed steps, labeled "drafting…".
- When `/_predictive` is removed and `/recipe/steps` is added → the ghost clears and
  the committed steps render at full opacity.

The applier from `01` handles `add /_predictive` (whole object), `add /recipe/steps`,
and `remove /_predictive` with no special-casing — and because the whole `/_predictive`
object is re-added each tick, its parent (the root) always exists, so the applier's
"no intermediate-parent creation" limitation (`01` §3) is never hit. The renderer just
keys off whether `_doc['_predictive']` is present. This "ghost → commit" transition is
the demo.

`seedStateFns['predictive_state_updates']` (the `01` §1 registry): a recipe with a
couple of existing steps so the prompt "rewrite the steps" has something to revise.

---

## File-change summary for `04`

| File | Change |
|------|--------|
| `lib/models/seed_state.dart` | recipe seed for `shared_state` + `predictive_state_updates` in the `seedStateFns` registry (`01` §1); checklist needs none |
| `lib/pages/live_state_page.dart` | **new** — page + `LiveStatePageState` (snapshot+delta projection, send loop) |
| `lib/widgets/checklist_widget.dart` | **new** — `agentic_generative_ui` renderer |
| `lib/widgets/recipe_card_widget.dart` | **new** — `shared_state` editable card (also reused, read-only steps, by predictive) |
| `lib/widgets/predictive_steps_widget.dart` | **new** — committed steps + ghosted draft |
| `lib/main.dart` | already routes `liveState` → `LiveStatePage` (from `01`) |

## Acceptance for `04`

- **Checklist:** any prompt → snapshot renders N pending rows → rows flip
  `pending→in_progress→completed` one at a time (paced) → closing "All steps complete."
- **Shared state:** recipe card visible from seed → "double the servings and add
  basil" → servings field and ingredients update **live** via deltas → assistant
  summary appears. Then edit the card by hand, send "make it vegetarian" → server
  starts from the hand-edited recipe (last-writer-wins).
- **Predictive:** "rewrite the steps to be more detailed" → ghosted draft text streams
  in faded → on completion the ghost clears and the steps list shows the committed
  steps at full opacity. Dropping the `/_predictive` deltas (verify by ignoring them)
  still yields the same final steps.
- Switching tabs mid-stream does not throw.
