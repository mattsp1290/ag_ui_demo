# 01 — Shared Infrastructure

Everything in this file is consumed by `02`, `03`, and `04`. Build it first.

## Current state (what exists today)

`lib/services/ag_ui_service.dart` exposes two methods, both of which hard-code away
exactly what the dojo features need:

```dart
final input = SimpleRunAgentInput(
  threadId: 'thread_${…}',
  runId:    'run_${…}',
  messages: [ UserMessage(id: …, content: message) ], // single message, no history
  tools:    [],            // ← never any tools
  context:  [],
  state:    <String, dynamic>{},  // ← never any seed state
  forwardedProps: <String, dynamic>{},
);
await for (final event in _client.runAgent(endpoint, input)) { yield event; }
```

- **No tools** → the client-tool routes (`02`/`03`) can never trigger a tool call.
- **No state seed** → `shared_state`/`predictive` start from the server default recipe
  and the client can never push edits back.
- **One message, fresh thread per call** → no multi-turn history, so the tool-result
  re-run (Run B) of Mechanism A has nowhere to live.

`ChatPageState` (`chat_page.dart:154`) already has the disposal guard (`_disposed`),
the streaming-text handling, and a crude `StateSnapshotEvent`/`StateDeltaEvent` branch
that prints `📊`-prefixed text. We keep `ChatPageState` for `agentic_chat` and the
existing tabs; the new mechanism pages are separate classes.

## 1. `EndpointConfig` — add a feature-kind flag

`lib/models/endpoint_config.dart` already has `isMultimodal`. Add a `featureKind` enum
so `main.dart` can dispatch each endpoint to the correct page family.

```dart
enum FeatureKind {
  chat,        // generic ChatPage (agentic_chat, reasoning, image-gen)
  clientTools, // tool_based_generative_ui  (Mechanism A, card rendering)
  approval,    // human_in_the_loop         (Mechanism A, approval gate)
  liveState,   // agentic_generative_ui, shared_state, predictive_state_updates
  multimodal,  // vision, audio, document   (existing)
}
```

Add `final FeatureKind featureKind;` to `EndpointConfig` (default `FeatureKind.chat`,
keep `isMultimodal` for backward-compat or derive it from `featureKind == multimodal`).
Tag the six dojo entries:

| Endpoint `path` | `featureKind` | Notes |
|-----------------|---------------|-------|
| `agentic_chat` | `chat` | keep generic page; tools added via `02` (see note) |
| `tool_based_generative_ui` | `clientTools` | renders tool calls as cards |
| `human_in_the_loop` | `approval` | approval gate over the round-trip |
| `agentic_generative_ui` | `liveState` | checklist |
| `shared_state` | `liveState` | recipe card |
| `predictive_state_updates` | `liveState` | recipe + ghost text |
| `image-gen`, `vision`, `audio`, `document`, `reasoning` | unchanged | |

> **`agentic_chat` placement.** The simplest correct demo of `agentic_chat` is to give
> the *generic* `ChatPage` a tool set and the round-trip, since its job is "chat that
> *can* call a tool." Two options — pick one in `02`:
> (a) leave `agentic_chat` as `FeatureKind.chat` and teach `ChatPageState` the
> round-trip (smaller blast radius, recommended); or
> (b) promote it to `clientTools` and share the new page. The plan assumes (a).

Also add a per-endpoint **tool set** to `EndpointConfig` so the page is data-driven:

```dart
final List<Tool> tools; // client tool definitions for this endpoint
```

`tools` is `const`-safe: `Tool` has a `const` constructor (`tool.dart`) and the
parameter maps in `02`/`03` are pure string/map/list literals, so `const
EndpointConfig(... tools: [Tool(...)] ...)` keeps `availableEndpoints` `const`.

> **Do NOT add a `seedState` closure field to `EndpointConfig`.** A non-`const`
> function/closure cannot be stored in a field of a `const`-constructed object, and
> `availableEndpoints` is a `const` list of `const EndpointConfig(...)`. Adding
> `final Map<String,dynamic> Function()? seedState;` would force `const` off the entire
> list (cascading to every entry) and the "existing tabs byte-for-byte equivalent"
> acceptance gate would fail to compile. Instead, keep seed state in a **small non-const
> side registry** keyed by path, leaving the model `const`:
>
> ```dart
> // lib/models/seed_state.dart
> Map<String, dynamic> _defaultRecipe() => {
>   'recipe': {
>     'title': 'Tomato Pasta', 'servings': 2,
>     'ingredients': [ {'name': 'pasta', 'amount': '200g'} ],
>     'steps': ['Boil water'],
>   },
> };
> const seedStateFns = <String, Map<String, dynamic> Function()>{
>   'shared_state': _defaultRecipe,
>   'predictive_state_updates': _defaultRecipe,
> };
> // A map literal of top-level tear-offs IS const — top-level function references
> // are compile-time constants, unlike closures.
> ```
>
> The page looks up `seedStateFns[endpoint.path]?.call()`. Concrete seed states live in
> `04`; concrete tool definitions live in `02`/`03`.

## 2. Service layer — tools, state, history, and the re-run

Replace the two single-shot methods with a session-oriented surface. The key new
capability is **carrying a growing `List<Message>` across runs** and **re-running with
an appended `ToolMessage`**.

```dart
class AgUiService {
  // … existing baseUrl, _client, _connectionController …

  /// One run. The caller owns the message list and passes the full history each time,
  /// so the same method serves the first turn and every tool-result re-run.
  Stream<BaseEvent> run(
    String endpoint, {
    required String threadId,        // stable across a multi-turn exchange
    required List<Message> messages, // full conversation so far
    List<Tool> tools = const [],
    dynamic state,                   // seed/echoed document for liveState routes
    Map<String, String> extraQuery = const {}, // e.g. {'approval': 'off'}
  }) async* {
    _connectionController.add(ConnectionStatus.connecting);
    final input = SimpleRunAgentInput(
      threadId: threadId,
      runId: 'run_${DateTime.now().millisecondsSinceEpoch}',
      messages: messages,
      tools: tools,
      context: const [],
      state: state ?? const <String, dynamic>{},
      forwardedProps: const <String, dynamic>{},
    );
    // Per-request query params (e.g. the HITL approval toggle) ride on the endpoint
    // string: runAgent builds `${baseUrl}/$endpoint`, so a query suffix passes through.
    final path = extraQuery.isEmpty
        ? endpoint
        : '$endpoint?${extraQuery.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}';
    _connectionController.add(ConnectionStatus.connected);
    try {
      await for (final event in _client.runAgent(path, input)) {
        yield event;
      }
      _connectionController.add(ConnectionStatus.disconnected);
    } catch (e) {
      _connectionController.add(ConnectionStatus.error);
      debugPrint('run error: $e');
      rethrow;
    }
  }
}
```

Notes:
- Keep the existing `sendMessage` / `sendMultimodalMessage` as thin wrappers over
  `run` (or leave them untouched and have the new pages call `run` directly). Do not
  break the multimodal/reasoning tabs.
- The `extraQuery` → endpoint-suffix trick is verified against the SDK: `runAgent`
  treats a non-absolute `endpoint` as a path and concatenates it onto `baseUrl`
  (`client.dart:77`), so `human_in_the_loop?approval=off` resolves correctly. (The
  alternative — `X-AG-Approval` via `AgUiClientConfig.defaultHeaders` — is client-global
  and can't vary per request, so prefer the query suffix.)
- `threadId` is generated **once per page/session**, not per send, so the server keys a
  coherent exchange. (Server feature routes mostly re-derive state from the request, but
  a stable thread id is the correct AG-UI contract and costs nothing.)

## 3. The RFC-6902 (JSON Patch) applier

The SDK decodes `StateDeltaEvent.delta` / `ActivityDeltaEvent.patch` but applies
nothing. The dojo routes only ever emit three op kinds, on simple paths:

| op | example path | meaning |
|----|--------------|---------|
| `replace` | `/recipe/title`, `/steps/0/status`, `/status` | overwrite a scalar |
| `add` | `/recipe/ingredients/-`, `/recipe/steps`, `/_predictive` | append to array (`-`) or set key |
| `remove` | `/recipe/ingredients/2`, `/_predictive` | drop an array element or key |

A compact, dependency-free applier covers every server delta. Put it in
`lib/services/json_patch.dart`:

```dart
/// Minimal in-place RFC-6902 applier for the op subset the AG-UI dojo routes emit
/// (add / replace / remove on object keys and arrays, including the "-" append token).
/// Returns the (possibly replaced) root so callers can reassign for a root-level op.
dynamic applyJsonPatch(dynamic root, List<Map<String, dynamic>> ops) {
  for (final op in ops) {
    final kind = op['op'] as String?;
    final path = op['path'] as String? ?? '';
    final segments = _parsePointer(path);
    if (segments.isEmpty) {
      // Whole-document replace (rare). Replace/return the new root.
      if (kind == 'replace' || kind == 'add') root = op['value'];
      continue;
    }
    final parent = _resolve(root, segments.sublist(0, segments.length - 1));
    final key = segments.last;
    switch (kind) {
      case 'add':
        if (parent is List) {
          if (key == '-') {
            parent.add(op['value']);
          } else {
            parent.insert(int.parse(key), op['value']);
          }
        } else if (parent is Map) {
          parent[key] = op['value']; // RFC: add to object == set
        }
        break;
      case 'replace':
        if (parent is List) {
          parent[int.parse(key)] = op['value'];
        } else if (parent is Map) {
          parent[key] = op['value'];
        }
        break;
      case 'remove':
        if (parent is List) {
          parent.removeAt(int.parse(key));
        } else if (parent is Map) {
          parent.remove(key);
        }
        break;
    }
  }
  return root;
}

List<String> _parsePointer(String pointer) {
  if (pointer.isEmpty || pointer == '/') return const [];
  return pointer
      .split('/')
      .skip(1) // leading ''
      .map((s) => s.replaceAll('~1', '/').replaceAll('~0', '~'))
      .toList();
}

dynamic _resolve(dynamic node, List<String> segments) {
  for (final seg in segments) {
    node = node is List ? node[int.parse(seg)] : (node as Map)[seg];
  }
  return node;
}
```

Apply against a **deep-mutable copy** of the document. Snapshots arrive as
`Map<String,dynamic>` with possibly `const`/unmodifiable nested collections, so clone
on `STATE_SNAPSHOT` before mutating: `state = jsonDecode(jsonEncode(snapshot))`. (The
demo documents are tiny; the round-trip clone is the simplest way to guarantee
mutability and break aliasing with the event object.)

**Exact delta sequences the applier must tolerate** (verified against the handlers;
these are the unit-test cases for `01` acceptance):

| Route | Ops emitted (each as its own single-op `STATE_DELTA`) |
|-------|------------------------------------------------------|
| `agentic_generative_ui` | `replace /steps/{i}/status` (value `in_progress` then `completed`) |
| `shared_state` | `replace /recipe/title`; `replace /recipe/servings`; `add /recipe/ingredients/-`; `remove /recipe/ingredients/{i}`; `add /recipe/steps/-` |
| `predictive_state_updates` | `add /_predictive` (value `{"draft": "<text>"}`, re-added each tick); `add /recipe/steps` (value `[...]`); `remove /_predictive` |

> **Index-shift is safe** — the server sorts ingredient removals **descending** and
> emits **one op per delta** (`sharedstate.go`), so the applier never sees an ascending
> multi-remove in a single delta. No re-sorting needed client-side.
>
> **Documented limitation: no intermediate-parent creation.** `_resolve` walks
> *existing* nodes and will throw if a pointer's parent doesn't exist. This never bites
> the current routes because the server always `add`s whole parent objects (e.g.
> predictive re-adds the entire `/_predictive` object rather than `/_predictive/draft`,
> so the parent always exists). If a future server change emits a deep `add` into a
> missing parent, the applier should fail loudly against this stated assumption rather
> than silently — that is intentional.

> Alternative: the pub package `json_patch` (`^3.0.1`) implements full RFC-6902. It's a
> fine substitute, but it returns a new document (non-mutating) and pulls a dependency
> into a pubspec that already pins a `meta` override. The ~40-line applier above is
> under our control and sufficient. Lead with it; swap to the package only if a future
> route emits `move`/`copy`/`test`.

## 4. Cross-cutting event handling (every new state class needs these)

The two new page families (`ClientToolsPageState` in `02`/`03`, `LiveStatePageState`
in `04`) are *new* `ChangeNotifier`s — they inherit **nothing** from `ChatPageState`.
Three behaviors that `ChatPageState` already has must be re-provided, or the new pages
regress versus the generic page they replace. **Factor these into a shared mixin or
helper** (`lib/pages/agui_event_handling.dart`) consumed by both new state classes (and
optionally retrofit onto `ChatPageState`) so they are written once, not three times.

### 4a. `RUN_ERROR` is an event, not an exception

The server emits `RUN_ERROR` on real paths — non-convergence within the iteration
budget (`loop.go`, the `if !converged` branch) and tool-schema rejection
(`clientToolInfos` → caller surfaces it). It decodes to a **`RunErrorEvent` delivered
*through the stream***, not a thrown error — so the `try/catch` around `_service.run(...)`
**never sees it**. Without a branch, the live-state page freezes on a half-built
document and the spinner can stick forever; the client-tools page hangs "loading" if a
`RUN_ERROR` arrives mid-round-trip.

Every state class must handle it:

```dart
if (event is RunErrorEvent) {
  _isLoading = false;              // stop spinner
  _busy = false;                   // abandon any pending tool round-trip (02/03)
  _pendingCalls = const [];        // (client-tools pages)
  _messages.add(ChatMessage(
    id: 'error_${DateTime.now().millisecondsSinceEpoch}',
    type: ChatMessageType.system,
    content: '⚠️ Run error: ${event.message ?? 'the agent failed'}',
    timestamp: DateTime.now(),
  ));
  if (!_disposed) notifyListeners();
  return;
}
```

### 4b. Reasoning / thinking passthrough

The model on these routes can stream `Reasoning*` (and legacy `Thinking*`) events — the
codebase added `Reasoning*` handling precisely because the server emits it. The
client-tools pages **must** handle them the same way `ChatPageState` does
(`chat_page.dart:242-305, 375-385`: start/content/end → a streaming reasoning bubble;
`ReasoningMessage` in `MESSAGES_SNAPSHOT` → a reasoning bubble). For the live-state
pages, make an explicit decision: either render a small "agent is reasoning…"
affordance, or document that reasoning is intentionally not surfaced there and why.
Either way it is a decision, not an omission. The shared mixin is the natural home for
the start/content/end handling.

### 4c. Plain-text answer path

Both new families must wire the normal `TEXT_MESSAGE_START/CONTENT/END` streaming path
(again, not inherited). On the tool routes this is the "model answered in prose instead
of calling a tool" outcome (`tool_based_generative_ui` only *prefers* a tool); on
shared/predictive it is the "what I changed" summary. See `02` §"no-tool-call path".

## 5. `main.dart` routing

Extend the existing `isMultimodal` dispatch to switch on `featureKind`:

```dart
Widget page;
switch (endpoint.featureKind) {
  case FeatureKind.multimodal:
    page = MultimodalChatPage(key: ValueKey(endpoint.path), endpoint: endpoint);
  case FeatureKind.clientTools:
  case FeatureKind.approval:
    page = ClientToolsPage(key: ValueKey(endpoint.path), endpoint: endpoint); // 02/03
  case FeatureKind.liveState:
    page = LiveStatePage(key: ValueKey(endpoint.path), endpoint: endpoint);   // 04
  case FeatureKind.chat:
    page = ChatPage(key: ValueKey(endpoint.path), endpoint: endpoint);
}
```

The `ValueKey(endpoint.path)` is essential (it already exists): switching tabs rebuilds
the page and its `ChangeNotifierProvider`, disposing the previous state and its
in-flight stream — relying on the `_disposed` guard pattern that every state class must
copy from `ChatPageState`.

## File-change summary for `01`

| File | Change |
|------|--------|
| `lib/models/endpoint_config.dart` | add `FeatureKind` enum, `featureKind` field, `const`-safe `tools` field; tag the six dojo endpoints (**no** `seedState` field — keep the model `const`) |
| `lib/models/seed_state.dart` | **new** — non-const `seedStateFns` registry of top-level tear-offs keyed by path |
| `lib/services/ag_ui_service.dart` | add session-oriented `run(...)` with `messages`/`tools`/`state`/`extraQuery`; keep existing methods working |
| `lib/services/json_patch.dart` | **new** — `applyJsonPatch` (op subset) |
| `lib/pages/agui_event_handling.dart` | **new** — shared mixin/helper: `RUN_ERROR`, reasoning/thinking, text-streaming (consumed by both new state classes) |
| `lib/main.dart` | dispatch on `featureKind` |

## Acceptance for `01`

- App still builds and all existing tabs (agentic_chat, multimodal trio, reasoning,
  image-gen) behave exactly as before.
- `run(...)` can be called with a non-empty `tools` list and a multi-message history
  and produces a valid request (verify by pointing it at `agentic_chat` with a trivial
  tool and observing `TOOL_CALL_*` events in the stream).
- `applyJsonPatch` unit-tested against the three op kinds, the `-` append token, the
  exact per-route delta sequences in the table above, and a `/_predictive`
  add-then-remove round-trip that leaves the doc clean.
- The shared event mixin handles `RunErrorEvent` (visible error + resets loading) and
  reasoning/thinking + text-streaming events, verified once so all consumers inherit it.
- The `RUN_ERROR` and reasoning policies (§4) are decided **before** the page work in
  `02`/`04` begins — both are cross-cutting and cheaper to bake into the shared layer
  than to retrofit per page.
