# Flutter Changes — ag_ui_demo

Branch: `matt.spurlin/1043/implement-multimodal-example`

## Files to change

### 1. `lib/models/chat_message.dart` — add `image` type

Add a new variant to `ChatMessageType`:

```dart
enum ChatMessageType {
  user,
  assistant,
  system,
  tool,
  thinking,
  image,   // ← new: carries a data-URL PNG from image_generated custom event
}
```

The `content` field on an image `ChatMessage` holds the full `data:image/png;base64,…`
string. No other fields are needed.

### 2. `lib/widgets/chat_message_widget.dart` — render image messages

`ChatMessageWidget` does **not** use a switch on `message.type`. It uses boolean
flags (`isUser`, `isAssistant`, `isTool`, `isThinking`) and renders all message
content as `Text(message.content)` inside a shared bubble+avatar Row. Images need
a different layout (no bubble), so add an **early return** at the top of `build()`,
before the existing `Padding` widget:

```dart
@override
Widget build(BuildContext context) {
  final theme = Theme.of(context);

  // Image messages bypass the bubble layout entirely.
  if (message.type == ChatMessageType.image) {
    final base64Str = message.content.split(',').last;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: theme.colorScheme.primary,
            child: Icon(Icons.image, size: 20, color: theme.colorScheme.onPrimary),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                base64Decode(base64Str),
                fit: BoxFit.contain,
                width: 300,
                errorBuilder: (_, __, ___) => const Text('(image failed to load)'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Existing boolean-flag layout continues here (no changes below this point).
  final isUser = message.type == ChatMessageType.user;
  // … rest of existing build() unchanged
```

Add `import 'dart:convert';` at the top of this file.

### 3. `lib/pages/chat_page.dart` — two changes

**3a. Handle the `image_generated` custom event.**

Add a branch before the final `else` in `_handleEvent`:

```dart
} else if (event is CustomEvent && event.name == 'image_generated') {
  final value = event.value as Map<String, dynamic>?;
  final url = value?['url'] as String?;
  if (url != null && url.isNotEmpty) {
    _messages.add(ChatMessage(
      id: 'image_${DateTime.now().millisecondsSinceEpoch}',
      type: ChatMessageType.image,
      content: url,
      timestamp: DateTime.now(),
    ));
  }
}
```

`package:ag_ui/ag_ui.dart` is already imported — `CustomEvent` needs no new import.

**3b. Suppress the spurious `StateSnapshotEvent` system message.**

The backend emits `STATE_SNAPSHOT { status: "generating", prompt: "..." }` before
generating the image. The existing `StateSnapshotEvent` handler in `_handleEvent`
(around line 336) falls through to a raw `snapshot.toString()` else-branch for any
snapshot that has neither `steps` nor `content` keys. This produces an unwanted
`"📊 UI State Generated: {status: generating, prompt: ...}"` system bubble.

Fix: only display the state message for snapshot shapes the UI knows how to render.
Replace the whole `StateSnapshotEvent` block with:

```dart
} else if (event is StateSnapshotEvent) {
  final snapshot = event.snapshot;
  if (snapshot != null && snapshot is Map) {
    // Only show a bubble for shapes with renderable content.
    if (snapshot.containsKey('steps') || snapshot.containsKey('content')) {
      String stateContent = '📊 UI State Generated:\n';
      if (snapshot.containsKey('steps') && snapshot['steps'] is List) {
        final steps = snapshot['steps'] as List;
        stateContent += 'Progress Steps:\n';
        for (int i = 0; i < steps.length; i++) {
          final step = steps[i];
          if (step is Map) {
            final description = step['description'] ?? 'Step ${i + 1}';
            final status = step['status'] ?? 'pending';
            final statusIcon = status == 'completed' ? '✅' :
                               status == 'in_progress' ? '🔄' :
                               status == 'enabled' ? '⚡' : '⏳';
            stateContent += '  $statusIcon $description\n';
          }
        }
      } else {
        stateContent += snapshot['content'].toString();
      }
      _messages.add(ChatMessage(
        id: 'state_${DateTime.now().millisecondsSinceEpoch}',
        type: ChatMessageType.system,
        content: stateContent,
        timestamp: DateTime.now(),
      ));
    }
    // Unknown snapshot shapes (e.g. image-gen {status, prompt}) are silently ignored.
  }
}
```

This is backward-compatible: existing agentic endpoints that emit `steps` or
`content` continue to display normally.

### 4. `lib/models/endpoint_config.dart` — add Image Gen endpoint

Add to `availableEndpoints`:

```dart
EndpointConfig(
  name: 'Image Gen',
  path: 'image-gen',
  description: 'Generate images from a text prompt using GPT-4o',
  icon: Icons.image_outlined,
),
```

The `path` is `image-gen` — `AgUiService.sendMessage` posts to
`$baseUrl/$path`, resolving to `http://localhost:8000/image-gen` by default
(override with `AG_UI_BASE_URL` env var).

### 5. `lib/services/ag_ui_service.dart` — no changes required

The service already creates a fresh `threadId`/`runId` per call, which is correct
for stateless image generation requests. The SSE decoding pipeline already handles
`CustomEvent` via the Dart SDK's decoder.

## Testing checklist

- [ ] App builds (`flutter build macos` or `flutter run -d macos`)
- [ ] New "Image Gen" tab appears in the navigation rail
- [ ] Typing a prompt and sending shows a loading indicator
- [ ] An inline image appears in the chat list after the SSE stream closes
- [ ] **No** "📊 UI State Generated" system bubble appears during image gen
- [ ] A second prompt generates a new image below the first
- [ ] Error case: stop the Go server → chat shows "Error: ..." (Flutter catch path)
- [ ] Existing tabs still display step-based state messages normally
- [ ] Existing tabs are otherwise unaffected

## Build notes

`dart:convert` is part of the Dart core SDK — no pubspec change needed.
Add `import 'dart:convert';` only in `chat_message_widget.dart` (where `base64Decode` is called).
`package:ag_ui` is already a path dependency pointing at the local checkout.
