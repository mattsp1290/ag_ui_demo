# 02 — Client Tools (`agentic_chat` + `tool_based_generative_ui`)

Mechanism A. Depends on `01` (service `run`, `EndpointConfig.tools`).

## The contract (verified against `loop.go`)

1. Client sends `messages` + **`tools`** (client-defined).
2. Server runs the model with `StreamToolCalls: true`. If the model calls a tool:
   - `TOOL_CALL_START` → `TOOL_CALL_ARGS` (streamed JSON fragments) → `TOOL_CALL_END`
     arrive live during the `llm` step.
   - The server **classifies the call as client-defined**, does **not** execute it, and
     finishes with `MESSAGES_SNAPSHOT` + `RUN_FINISHED` (success)
     (`loop.go:229-249`). The assistant message in the snapshot carries the
     `toolCalls`.
3. Client reads the tool call(s), **executes locally**, appends one `ToolMessage` per
   call (`role:tool`, matching `toolCallId`) to the conversation, and **re-runs**
   (Run B) with the full history.
4. The model sees the tool result and either calls another tool (loop to 2) or returns
   a final text answer (`TEXT_MESSAGE_*` then `MESSAGES_SNAPSHOT` + `RUN_FINISHED`).

`tool_based_generative_ui` is identical on the wire; only the **server system prompt**
differs ("you MUST prefer a rendering tool"), and the **client renders the tool call as
a UI card** instead of executing real logic.

## Delta from current behavior

Today both endpoints hit the generic `ChatPageState`, which:
- sends `tools: []` → **the model never has a tool to call**, so these routes currently
  degrade to plain chat;
- *does* already render `TOOL_CALL_START/ARGS/END` and `MESSAGES_SNAPSHOT` tool calls as
  text bubbles (`chat_page.dart:306-374`) — but never produces a tool *result*, so the
  round-trip never closes and the model can't continue.

The upgrade: **define tools, close the round-trip, and (for `tool_based`) render the
tool call as a card.**

## Tool definitions

Put these on the `EndpointConfig` (`01`). `Tool` comes from `ag_ui`
(`name`, `description`, `parameters` = JSON Schema).

**`agentic_chat`** — a couple of small, genuinely client-executable tools so the demo
shows a real round-trip:

```dart
Tool(
  name: 'get_current_time',
  description: 'Returns the current local time.',
  parameters: {'type': 'object', 'properties': {}, 'required': []},
),
Tool(
  name: 'calculate',
  description: 'Evaluates a simple arithmetic expression and returns the number.',
  parameters: {
    'type': 'object',
    'properties': {'expression': {'type': 'string', 'description': 'e.g. "12 * 7 + 3"'}},
    'required': ['expression'],
  },
),
```

**`tool_based_generative_ui`** — a *rendering* tool whose arguments are the card's data:

```dart
Tool(
  name: 'render_card',
  description: 'Render a titled card with key/value facts and an optional image URL.',
  parameters: {
    'type': 'object',
    'properties': {
      'title': {'type': 'string'},
      'subtitle': {'type': 'string'},
      'facts': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {'label': {'type': 'string'}, 'value': {'type': 'string'}},
          'required': ['label', 'value'],
        },
      },
      'imageUrl': {'type': 'string'},
    },
    'required': ['title'],
  },
),
```

## Collecting a tool call from the stream

The args stream as fragments; accumulate per `toolCallId`. The simplest reliable source
is the **`MESSAGES_SNAPSHOT`** at the end of Run A — its `AssistantMessage.toolCalls`
carry the fully-assembled `FunctionCall(name, arguments)` (`arguments` is a JSON
string). Use the live `TOOL_CALL_*` events only for progressive UI ("calling
render_card…"); use the snapshot as the authoritative call list.

```dart
// inside the page's event handler
if (event is MessagesSnapshotEvent) {
  // .messages is non-nullable (events.dart) — no `?.` needed.
  final assistant = event.messages.whereType<AssistantMessage>().lastOrNull;
  final calls = assistant?.toolCalls ?? const [];
  if (calls.isNotEmpty) {
    _pendingAssistant = assistant;          // keep to append before the tool results
    _pendingCalls = calls;                  // drive UI / execution
  }
}
if (event is RunFinishedEvent && _pendingCalls.isNotEmpty && !_busy) {
  // Launch the round-trip ONCE. While it runs, _busy stays true, so this branch
  // can't fire again — the while-loop inside _resolveToolCalls drives subsequent
  // rounds (Run C, D, …). _busy is cleared only by whichever loop owns it (the
  // initial-send loop's finally, or _resolveToolCalls's finally), never here.
  _busy = true;
  _resolveToolCalls();                      // execute (02) or gate (03), then re-run
}
// A prose-only answer (no tool call) streams via the shared TEXT_MESSAGE_* path
// (01 §4c) — nothing special here; _pendingCalls stays empty and the initiating loop's
// finally clears _busy. That is the expected `tool_based_generative_ui` "no fitting
// tool" outcome (see "No-tool-call path" below).
```

## The round-trip (Run B)

`_busy` is set by the caller (the `RunFinishedEvent` branch above) **before** calling
this, so it doubles as the re-entrancy guard and the round-trip-wide loading flag. The
whole body is wrapped in `try/catch/finally` because this method is fired **unawaited**
— an uncaught throw here would otherwise be an unobserved async error that never reaches
the UI and never clears `_busy`.

A **`while` loop** (not recursion) drives multi-round exchanges: each re-run's stream
sets `_pendingCalls` again via `MESSAGES_SNAPSHOT` if the model calls another tool, and
the loop keeps going until a run finishes with no pending calls. Because `_busy` is true
throughout, the `_handleEvent` launch branch never re-enters this method.

```dart
// _busy is already true (set in the RUN_FINISHED launch branch). Never re-entered
// while busy: the launch branch's `&& !_busy` guard blocks it, so this runs once and
// the loop below owns every subsequent round.
Future<void> _resolveToolCalls() async {
  try {
    while (_pendingCalls.isNotEmpty) {
      // 1. Put the assistant message that *requested* the calls into history first,
      //    so the re-run's conversation has the tool_calls the results answer to.
      //    (The model provider — e.g. OpenAI — rejects a tool result that doesn't
      //    follow an assistant message carrying that tool_call_id. The Go server does
      //    NO such ordering check; the constraint is upstream at the model API.)
      _history.add(_pendingAssistant!);       // AssistantMessage with toolCalls
      final calls = _pendingCalls;
      _pendingCalls = const [];               // consume before the re-run repopulates
      _pendingAssistant = null;

      // 2. One ToolMessage per call. _execute may throw (malformed args) → caught below.
      for (final call in calls) {
        final result = await _execute(call);  // 02: real exec; 03: user decision
        _history.add(ToolMessage(
          id: 'tool_${DateTime.now().millisecondsSinceEpoch}_${call.id}',
          toolCallId: call.id,
          content: result,                     // JSON string the model can read
        ));
      }

      // 3. Re-run with the full history (same threadId, tools). A RUN_ERROR here
      //    arrives as a RunErrorEvent in the stream (handled in _handleEvent, 01 §4a),
      //    not as a throw. _handleEvent may repopulate _pendingCalls → another loop.
      await for (final event in _service.run(
        endpoint.path,
        threadId: _threadId,
        messages: _history,
        tools: endpoint.tools,
      )) {
        if (_disposed) return;
        _handleEvent(event);
      }
    }
  } catch (e) {
    if (!_disposed) {
      _messages.add(ChatMessage(
        id: 'error_${DateTime.now().millisecondsSinceEpoch}',
        type: ChatMessageType.system,
        content: 'Error resolving tool call: $e',
        timestamp: DateTime.now(),
      ));
    }
  } finally {
    // This loop owns _busy once launched; on exit the exchange is converged or errored.
    if (!_disposed) { _busy = false; notifyListeners(); }
  }
}
```

The **initial send** (the first user message, before any tool call) runs its own
`await for` loop and must clear `_busy` in its `finally` **only if no round-trip was
queued** — otherwise it would clear the flag out from under an in-flight
`_resolveToolCalls`:

```dart
} finally {
  // If _handleEvent launched a round-trip, _pendingCalls is non-empty here (the
  // launch consumes it only after its first await), so leave _busy to that loop.
  if (!_disposed && _pendingCalls.isEmpty) { _busy = false; notifyListeners(); }
}
```

> **Connection-status blink:** the shared `run(...)` emits
> `connecting → connected → disconnected` per run, so a two-run round-trip flickers the
> indicator. While `_busy` spans the round-trip, suppress the inter-run `disconnected`
> (or just bind the indicator to `_busy` instead of the raw connection stream).

> **Ordering / re-entrancy contract.** `_handleEvent` is synchronous but
> `_resolveToolCalls()` is `async` and fired **unawaited** on `RunFinishedEvent`.
> `RUN_FINISHED` is terminal, so Run A's stream is genuinely done before Run B opens —
> there is never an overlapping `runAgent` on one socket. The rules that make this safe:
> - **Resolve once per terminal event.** The `RunFinishedEvent` branch launches a
>   round-trip *only* when `_pendingCalls.isNotEmpty && !_busy`, and sets `_busy = true`
>   first. A second terminal event arriving while a round-trip is in flight cannot
>   launch a duplicate (which would double-append `ToolMessage`s).
> - **`_busy` is the guard AND the round-trip-wide loading flag** — one flag spanning
>   the first send through the last Run B, not per-run `_isLoading` toggling (avoids the
>   loading-bar flicker between runs).
> - **The body is `try/catch/finally`** (above) because it's unawaited: a throw from
>   `_service.run` or a malformed-args `jsonDecode` inside `_execute` must surface to the
>   UI and reset `_busy`, not vanish as an unobserved async error.

`_execute` for `agentic_chat`:

```dart
Future<String> _execute(ToolCall call) async {
  final args = call.function.arguments.isEmpty
      ? <String, dynamic>{}
      : jsonDecode(call.function.arguments) as Map<String, dynamic>;
  switch (call.function.name) {
    case 'get_current_time':
      return jsonEncode({'time': DateTime.now().toIso8601String()});
    case 'calculate':
      return jsonEncode({'result': _evalSimple(args['expression'] as String? ?? '')});
    default:
      return jsonEncode({'error': 'unknown tool ${call.function.name}'});
  }
}
```

(`_evalSimple` can be a tiny shunting-yard or a hard-coded "echo the expression"; the
point is the round-trip, not a calculator. Keep it ~20 lines or stub it. On a parse
failure or divide-by-zero, **return** `jsonEncode({'error': '...'})` so the model can
recover — do not throw, even though `_resolveToolCalls`'s `try/catch` would catch it.)

For `tool_based_generative_ui`, `_execute` does **not** compute anything — the card
*is* the result. Render the card from `call.function.arguments`, then return a trivial
acknowledgement so the model can produce a closing sentence:

```dart
// render path: parse args → append a ChatMessage of a new `card` type (see below)
return jsonEncode({'rendered': true});
```

## No-tool-call path (explicit handler requirement)

`tool_based_generative_ui`'s server prompt only *prefers* a rendering tool — the model
may still answer in prose, and `agentic_chat` answers directly whenever no tool fits.
In that case the final `MESSAGES_SNAPSHOT` carries an assistant message with **no
`toolCalls`**, `_pendingCalls` stays empty, and the `RunFinishedEvent` branch correctly
no-ops. **This is not just a test expectation — the handler must render the closing
text.** Wire the shared `TEXT_MESSAGE_START/CONTENT/END` path (`01` §4c) on
`ClientToolsPageState`; it is not inherited from `ChatPageState`. Without it, a
prose-only answer renders nothing.

## Rendering

### `agentic_chat`
Reuse the generic chat bubbles. Show the tool call ("🔧 calculate(...)"), then the
tool result, then the model's final answer. The existing `_handleEvent` tool branches
(`chat_page.dart:306-374`) already render the call; you only add the result bubble from
the `ToolMessage` you created, and the final `TEXT_MESSAGE_*` already works.

### `tool_based_generative_ui`
Add a `card` `ChatMessageType` (or a dedicated message model) and a `CardWidget` that
renders `{title, subtitle, facts[], imageUrl}`. Insert it when a `render_card` call is
resolved. This is the one genuinely new widget for `02`:

```
┌────────────────────────────┐
│ Eiffel Tower               │  ← title
│ Paris, France              │  ← subtitle
│ Height      330 m          │  ← facts[]
│ Built       1889           │
│ [image if imageUrl set]    │
└────────────────────────────┘
```

**Demo tip:** a single static card is a thin demo. Define 2–3 card shapes (e.g. a facts
card, a list/gallery card, a stat card) — either as separate tools or variants of
`render_card` — so the "the model *chose* to render UI instead of prose" point lands
harder when different prompts yield visibly different UI.

## Page / state classes

`lib/pages/client_tools_page.dart` + a `ClientToolsPageState` (own `ChangeNotifier`,
copy the `_disposed` guard from `ChatPageState`, **and mix in the shared event handler
from `01` §4** for `RUN_ERROR` + reasoning/thinking + text-streaming). It holds:
`_history` (`List<Message>`), `_threadId`, `_pendingCalls`, `_pendingAssistant`, the
display `List<ChatMessage>`, and `_busy` (the round-trip-wide guard/loading flag — there
is no separate `_isLoading`). The first send seeds `_history` with the `UserMessage`,
sets `_busy = true`, and calls `_service.run(...)`; the round-trip is the loop above.

> **Avoid the split-brain.** Option (a) puts the same round-trip logic in
> `ChatPageState` (for `agentic_chat`) *and* `ClientToolsPageState` (for `tool_based`/
> HITL). Factor `_resolveToolCalls` + the collect-from-snapshot logic into the shared
> mixin/helper alongside the `01` §4 handlers, so both consumers share one
> implementation rather than two that can diverge.

The same page class serves `03` (approval) — the only difference is `_execute` (see
`03`). Branch on `endpoint.featureKind`.

## File-change summary for `02`

| File | Change |
|------|--------|
| `lib/models/endpoint_config.dart` | tool sets for `agentic_chat`, `tool_based_generative_ui` |
| `lib/pages/client_tools_page.dart` | **new** — page + `ClientToolsPageState` with the round-trip |
| `lib/widgets/card_widget.dart` | **new** — generative-UI card renderer |
| `lib/models/chat_message.dart` | add a `card` type + a field to carry parsed card data (or a small `CardData` model) |
| `lib/main.dart` | already routes `clientTools` → `ClientToolsPage` (from `01`) |

If you choose option (a) for `agentic_chat` (keep it on the generic `ChatPage`), instead
teach `ChatPageState.sendMessage` to pass `endpoint.tools` and add the same
`_resolveToolCalls` round-trip there. Recommended, smaller diff.

## Acceptance for `02`

- `agentic_chat`: "what's 12*7+3?" → model calls `calculate` → client returns `87` →
  model answers "12 × 7 + 3 = 87." Tool call, result, and final answer all visible.
- `tool_based_generative_ui`: "show me a card about the Eiffel Tower" → model calls
  `render_card` → a **card widget** appears (not prose) → model adds a one-line closer.
- Multi-round: a prompt that needs two tools in sequence completes without manual
  intervention (the loop re-runs until a text-only final answer).
- Switching away mid-round-trip does not throw (`_disposed` guard).
