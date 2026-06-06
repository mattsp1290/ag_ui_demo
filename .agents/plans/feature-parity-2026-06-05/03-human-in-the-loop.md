# 03 — Human in the Loop (`human_in_the_loop`)

Mechanism A with an approval gate. Depends on `02` (the round-trip) and `01`.

## Why this is NOT the interrupt/resume protocol

`/human_in_the_loop` is `HumanInTheLoopConfig(approval)` =
`AgenticChatConfig()` + an approval-flavored system prompt (`runconfig.go:84-91`).
`AgenticChatConfig()` sets `NeverInterrupt: true` and `StreamToolCalls: true`, so the
server takes the streaming client-tool path (`loop.go:229-249`) and **never** reaches
the interrupt branch (`loop.go:261`). The route's comment is explicit
(`runconfig.go:79-80`): the user's decision is *"carried back as a role:tool result on
the follow-up run."*

So HITL is **exactly** `02`'s round-trip. The only differences:

1. The server's system prompt makes the model call the approval/action tool **before
   doing the consequential thing**, and wait for the result.
2. The client, instead of silently executing the tool, **shows an approve/deny UI** and
   turns the user's choice into the `ToolMessage` result.

No `resume[]`, no `RUN_FINISHED`-interrupt, no `responseSchema` parsing. (See `00` →
"Resume gap": the Dart SDK can't send `resume` anyway, and this route doesn't need it.)

## Delta from current behavior

Today `human_in_the_loop` hits the generic `ChatPageState` with `tools: []`. The model
has no tool to gate, so it just chats — the "human in the loop" never happens. The
upgrade gives it gated tools and an approval UI that decides the tool result.

## The approval tool(s)

Define one or more **consequential-action** tools so the system prompt has something to
gate. Put on `EndpointConfig.tools`:

```dart
Tool(
  name: 'send_email',
  description: 'Sends an email. Consequential — must be approved before sending.',
  parameters: {
    'type': 'object',
    'properties': {
      'to': {'type': 'string'},
      'subject': {'type': 'string'},
      'body': {'type': 'string'},
    },
    'required': ['to', 'subject', 'body'],
  },
),
Tool(
  name: 'delete_file',
  description: 'Deletes a file. Consequential — must be approved before deleting.',
  parameters: {
    'type': 'object',
    'properties': {'path': {'type': 'string'}},
    'required': ['path'],
  },
),
```

The approval prompt ("Send an email to X?") is derived **client-side** from the tool
name + arguments — exactly the human-readable summary the server's *interrupt* path
would have built, but we build it ourselves from the proposed call.

> **Design tension to resolve (and verify at runtime).** The server prompt
> (`humanInTheLoopSystemPrompt`, `runconfig.go`) says: *"you MUST first call **the
> provided approval tool** with a clear, human-readable **summary** … and wait for the
> result."* Read literally, that wants a dedicated `request_approval(summary, action)`
> tool whose argument is a summary string — which bare `send_email{to,subject,body}` /
> `delete_file{path}` do not provide. The evidence is genuinely two-sided:
> - *For action tools (this plan's choice):* the server's own interrupt path frames
>   approval as gating the raw action call —
>   `"Agent wants to call %s with %s — approve?"` over `tc.Function.Name`/`Arguments`
>   (`loop.go`). The designers clearly also model the consequential tool as the
>   approvable unit.
> - *For a dedicated approval tool:* the prompt's wording and its "summary" argument.
>
> Whether the model *reliably gates a bare action tool* under this prompt is an
> **empirical runtime question** that can't be settled from source. **Decision:** keep
> the action-tool design (simpler, and the interrupt path supports it), but **add the
> acceptance test in `05`** that confirms the model actually calls the action tool and
> waits for the result (rather than describing the action in prose and stopping). If
> that test proves flaky, fall back to a dedicated `request_approval(summary, action)`
> tool and gate on *that* — the round-trip machinery is identical either way.

## The gate: `_execute` becomes a user decision

Reuse `ClientToolsPageState` from `02`. Override `_execute` for `FeatureKind.approval`
so it **awaits a user decision** instead of running logic:

```dart
Future<String> _execute(ToolCall call) async {
  final args = call.function.arguments.isEmpty
      ? <String, dynamic>{}
      : jsonDecode(call.function.arguments) as Map<String, dynamic>;

  // Surface an approval card and suspend until the user taps Approve/Deny.
  final decision = await _askUser(
    summary: _summarize(call.function.name, args), // "Send email to a@b.com: 'Hi'…"
  );

  if (!decision.approved) {
    // Denied: tell the model so it can acknowledge and not retry the same action.
    return jsonEncode({
      'approved': false,
      'reason': decision.reason ?? 'The user declined this action.',
    });
  }
  // Approved: perform the (demo) action and return its result.
  return jsonEncode({'approved': true, 'result': _performDemoAction(call.function.name, args)});
}
```

`_askUser` returns a `Completer<_Decision>` future that the approve/deny buttons
complete:

```dart
class _Decision { final bool approved; final String? reason; const _Decision(this.approved, [this.reason]); }

Completer<_Decision>? _pendingDecision;

Future<_Decision> _askUser({required String summary}) {
  _pendingApprovalSummary = summary;          // drives the approval card UI
  _pendingDecision = Completer<_Decision>();
  notifyListeners();
  return _pendingDecision!.future;
}

void approve()        { _resolveDecision(const _Decision(true)); }
void deny([String? r]) { _resolveDecision(_Decision(false, r ?? 'User denied.')); }

void _resolveDecision(_Decision d) {
  _pendingApprovalSummary = null;
  _pendingDecision?.complete(d);
  _pendingDecision = null;
  notifyListeners();
}
```

Because the round-trip loop from `02` `await`s `_execute`, suspending on the
`Completer` cleanly pauses Run B's construction until the user acts — then the
`ToolMessage` (approved result or denial) goes back and the model continues.

> **Disposal:** if the page is disposed while a decision is pending, complete the
> completer with a denial in `dispose()` (before `super.dispose()`) so the awaiting
> loop unwinds instead of leaking. Guard with `if (_pendingDecision != null &&
> !_pendingDecision!.isCompleted)`.

## Rendering: the approval card

When `_pendingApprovalSummary != null`, show an inline card in the message list (or a
bottom sheet) with the proposed action and two buttons:

```
┌──────────────────────────────────────┐
│ ⚠  Approval required                  │
│ Agent wants to: send_email            │
│   to:      alice@example.com          │
│   subject: Quarterly report           │
│   body:    Please find attached…      │
│                                       │
│        [ Deny ]      [ Approve ]      │
└──────────────────────────────────────┘
```

After the decision, replace the card with a resolved bubble ("✅ Approved — email
sent" / "🚫 Denied"), and let the model's follow-up text render normally.

## Optional: the `?approval=off` toggle

Demonstrate the server's per-request toggle (`main.go:214-222`) with a switch in the
app bar. When **off**, call `_service.run(..., extraQuery: {'approval': 'off'})`: the
server drops the approval system prompt and behaves like `agentic_chat` (tools still
round-trip, but the model isn't told to gate). This visibly contrasts the gated vs
ungated posture from the same UI. Default the switch to **on**.

## File-change summary for `03`

| File | Change |
|------|--------|
| `lib/models/endpoint_config.dart` | tool set for `human_in_the_loop` |
| `lib/pages/client_tools_page.dart` | approval branch in `_execute`; `_askUser`/`approve`/`deny`; disposal completion |
| `lib/widgets/approval_card_widget.dart` | **new** — approval card with Approve/Deny |
| `lib/pages/client_tools_page.dart` (app bar) | optional `approval=off` toggle |

## Acceptance for `03`

- Prompt "email alice@example.com that the report is ready" → model calls `send_email`
  → **approval card** appears with the parsed args → **Approve** → tool result
  `{approved:true,…}` returns → model confirms "I've sent the email."
- Same prompt → **Deny** → tool result `{approved:false,…}` returns → model
  acknowledges and does not resend.
- Toggle **off** → the action proceeds without an approval card (ungated parity check).
- Disposing mid-decision unwinds cleanly (no pending-completer leak, no throw).
