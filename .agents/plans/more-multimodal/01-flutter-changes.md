# Flutter Changes — more-multimodal

Branch: `matt.spurlin/1043/implement-multimodal-example`

## File change list

### 0. `lib/pages/chat_page.dart` — cancellation guard + `MultimodalChatPageState`

Two changes to the existing file (same library, so the subclass can access privates).

**0a. Add `_disposed` flag to `ChatPageState`**

Add a `bool _disposed = false` field. Override `dispose()` to set it before calling
`super.dispose()`. Guard `sendMessage`'s event loop and its `finally` block:

```dart
// field
bool _disposed = false;

@override
void dispose() {
  _disposed = true;
  _service.dispose();
  super.dispose();
}

void sendMessage(String text) async {
  // ... (existing setup unchanged) ...
  try {
    await for (final event in _service.sendMessage(endpoint.path, text)) {
      if (_disposed) break;   // ← add this guard
      _handleEvent(event);
    }
  } catch (e) {
    if (!_disposed) {         // ← wrap error bubble
      _messages.add(ChatMessage(
        id: 'error_${DateTime.now().millisecondsSinceEpoch}',
        type: ChatMessageType.system,
        content: 'Error: ${e.toString()}',
        timestamp: DateTime.now(),
      ));
    }
  } finally {
    if (!_disposed) {         // ← guard final state mutation
      _isLoading = false;
      _currentStreamingMessage = null;
      notifyListeners();
    }
  }
}
```

This fixes a pre-existing bug where switching tabs mid-stream calls `notifyListeners()`
on a disposed `ChangeNotifier` and throws. Multimodal responses (Whisper, vision) are
slower and widen the window.

**0b. Add `MultimodalChatPageState` to the same file**

Append after `ChatPageState`. Dart library privacy (`_` prefix) is file-scoped, not
class-scoped: a subclass in a *different* `.dart` file cannot access `_messages`,
`_service`, `_isLoading`, `_currentStreamingMessage`, or `_handleEvent`. Defining the
subclass in the same file gives it full access.

```dart
/// Extends ChatPageState to support multimodal file-attachment input.
/// Defined in the same library (chat_page.dart) so it can access private members.
class MultimodalChatPageState extends ChatPageState {
  Uint8List? _pickedBytes;
  String?    _pickedFileName;
  String?    _pickedMimeType;

  MultimodalChatPageState({required super.endpoint});

  Uint8List? get pickedBytes    => _pickedBytes;
  String?    get pickedFileName => _pickedFileName;
  String?    get pickedMimeType => _pickedMimeType;
  bool       get hasFile        => _pickedBytes != null;

  /// Launches the file picker. Rejects files > 5 MB raw (base64 ~6.7 MB; server BodyLimit is 20 MB).
  Future<void> pickFile(
    List<String> allowedExtensions,
    BuildContext context,
  ) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      withData: true,  // required on macOS to get bytes via the sandbox
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) return;

    const maxBytes = 5 * 1024 * 1024; // 5 MB raw → ~6.7 MB base64 (server BodyLimit is 20 MB)
    if (bytes.length > maxBytes) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File too large — pick a file under 5 MB')),
        );
      }
      return;
    }

    _pickedBytes    = bytes;
    _pickedFileName = file.name;
    _pickedMimeType = _mimeTypeFor(file.extension ?? '');
    notifyListeners();
  }

  void clearPicked() {
    _pickedBytes    = null;
    _pickedFileName = null;
    _pickedMimeType = null;
    notifyListeners();
  }

  /// Builds InputContent parts, adds an attachment bubble, and streams the response.
  void sendMultimodal(String questionText) async {
    if (_pickedBytes == null) return;   // guard: do nothing if no file picked
    if (_isLoading)           return;   // guard: do nothing while already loading

    final bytes    = _pickedBytes!;
    final mime     = _pickedMimeType ?? 'application/octet-stream';
    final fileName = _pickedFileName ?? 'file';
    final base64   = base64Encode(bytes);   // from dart:convert
    final source   = DataSource(value: base64, mimeType: mime);

    // Build parts list by endpoint type.
    final List<InputContent> parts;
    switch (endpoint.path) {
      case 'vision':
        parts = [
          ImageInputContent(source: source),
          if (questionText.trim().isNotEmpty) TextInputContent(questionText.trim()),
        ];
      case 'audio':
        parts = [AudioInputContent(source: source)];
      case 'document':
        parts = [
          DocumentInputContent(source: source),
          if (questionText.trim().isNotEmpty) TextInputContent(questionText.trim()),
        ];
      default:
        parts = [ImageInputContent(source: source)]; // fallback
    }

    // Add the user-side attachment bubble before the response arrives.
    switch (endpoint.path) {
      case 'vision':
        _messages.add(ChatMessage(
          id: 'attachment_${DateTime.now().millisecondsSinceEpoch}',
          type: ChatMessageType.imageAttachment,
          content: fileName,
          imageBytes: bytes,   // decoded once here; never re-decoded in the widget
          timestamp: DateTime.now(),
        ));
      case 'audio':
        _messages.add(ChatMessage(
          id: 'attachment_${DateTime.now().millisecondsSinceEpoch}',
          type: ChatMessageType.audioAttachment,
          content: fileName,
          fileName: fileName,
          timestamp: DateTime.now(),
        ));
      case 'document':
        _messages.add(ChatMessage(
          id: 'attachment_${DateTime.now().millisecondsSinceEpoch}',
          type: ChatMessageType.documentAttachment,
          content: fileName,
          fileName: fileName,
          timestamp: DateTime.now(),
        ));
    }

    _isLoading = true;
    clearPicked();     // clear selection immediately so the UI resets
    notifyListeners();

    try {
      await for (final event in _service.sendMultimodalMessage(endpoint.path, parts)) {
        if (_disposed) break;
        _handleEvent(event);
      }
    } catch (e) {
      if (!_disposed) {
        _messages.add(ChatMessage(
          id: 'error_${DateTime.now().millisecondsSinceEpoch}',
          type: ChatMessageType.system,
          content: 'Error: ${e.toString()}',
          timestamp: DateTime.now(),
        ));
      }
    } finally {
      if (!_disposed) {
        _isLoading = false;
        _currentStreamingMessage = null;
        notifyListeners();
      }
    }
  }

  /// Returns a MIME type string for the given file extension.
  /// Falls back to 'application/octet-stream' for unknown extensions.
  static String _mimeTypeFor(String ext) => const {
    'jpg':  'image/jpeg',
    'jpeg': 'image/jpeg',
    'png':  'image/png',
    'gif':  'image/gif',
    'webp': 'image/webp',
    'mp3':  'audio/mpeg',
    'wav':  'audio/wav',
    'm4a':  'audio/mp4',
    'ogg':  'audio/ogg',
    'webm': 'audio/webm',
    'pdf':  'application/pdf',
  }[ext.toLowerCase()] ?? 'application/octet-stream';
}
```

Add the following imports at the top of `chat_page.dart` (alongside existing ones):

```dart
import 'dart:convert';           // base64Encode
import 'dart:typed_data';        // Uint8List
import 'package:file_picker/file_picker.dart';
import 'package:ag_ui/ag_ui.dart';  // already present, covers InputContent types
```

---

### 1. `pubspec.yaml` — add `file_picker` dependency

```yaml
dependencies:
  flutter:
    sdk: flutter
  provider: ^6.1.2
  ag_ui:
    path: /Users/punk1290/git/ag-ui/sdks/community/dart
  file_picker: ^8.1.7   # ← add this
```

Run `flutter pub get` after adding. The existing `dependency_overrides: meta` is
compatible with file_picker ^8.x.

---

### 2. `macos/Runner/DebugProfile.entitlements` — file picker entitlement

Add `com.apple.security.files.user-selected.read-only`. The `file_picker` package on
macOS only populates `PlatformFile.bytes` (used with `withData: true`) after the
sandbox grants read access to the user-selected file. Without this entitlement the
bytes field is null even though the file path is returned.

```xml
<key>com.apple.security.files.user-selected.read-only</key>
<true/>
```

---

### 3. `macos/Runner/Release.entitlements` — same entitlement

The Release entitlements currently only have `app-sandbox` and `network.client`. Add:

```xml
<key>com.apple.security.files.user-selected.read-only</key>
<true/>
```

---

### 4. `lib/models/endpoint_config.dart` — new endpoints + type flag

Add `isMultimodal` and `allowedExtensions` fields to `EndpointConfig` (both `const`-
compatible), and append three new entries after the existing seven:

```dart
class EndpointConfig {
  // ... existing fields (name, path, description, icon) unchanged ...
  final bool isMultimodal;
  final List<String> allowedExtensions;

  const EndpointConfig({
    required this.name,
    required this.path,
    required this.description,
    required this.icon,
    this.isMultimodal = false,
    this.allowedExtensions = const [],
  });

  static const List<EndpointConfig> availableEndpoints = [
    // ... existing 7 entries unchanged (isMultimodal defaults to false) ...
    EndpointConfig(
      name: 'Vision',
      path: 'vision',
      description: 'Analyze images with GPT-4o vision',
      icon: Icons.image_search,
      isMultimodal: true,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'gif', 'webp'],
    ),
    EndpointConfig(
      name: 'Audio',
      path: 'audio',
      description: 'Transcribe audio with Whisper',
      icon: Icons.mic,
      isMultimodal: true,
      allowedExtensions: ['mp3', 'wav', 'm4a', 'ogg', 'webm'],
    ),
    EndpointConfig(
      name: 'Document Q&A',
      path: 'document',
      description: 'Ask questions about a PDF',
      icon: Icons.description,
      isMultimodal: true,
      allowedExtensions: ['pdf'],
    ),
  ];
}
```

---

### 5. `lib/models/chat_message.dart` — new attachment types + `imageBytes` field

**5a. New `ChatMessageType` variants:**

```dart
enum ChatMessageType {
  user,
  assistant,
  system,
  tool,
  thinking,
  image,              // existing: received image (image_generated custom event)
  imageAttachment,    // ← new: image the user uploaded (thumbnail)
  audioAttachment,    // ← new: audio file the user uploaded (icon + filename)
  documentAttachment, // ← new: PDF the user uploaded (icon + filename)
}
```

**5b. Add `imageBytes` and `fileName` fields to `ChatMessage`:**

```dart
class ChatMessage {
  final String id;
  final ChatMessageType type;
  final String content;
  final DateTime timestamp;
  final bool isStreaming;
  final String? toolName;
  final String? toolArgs;
  final String? fileName;       // ← new: display name for audio/document attachments
  final Uint8List? imageBytes;  // ← new: decoded image bytes for imageAttachment
                                //    stored once at send time; never re-decoded in build()

  const ChatMessage({
    required this.id,
    required this.type,
    required this.content,
    required this.timestamp,
    this.isStreaming = false,
    this.toolName,
    this.toolArgs,
    this.fileName,
    this.imageBytes,
  });

  ChatMessage copyWith({
    String? id,
    ChatMessageType? type,
    String? content,
    DateTime? timestamp,
    bool? isStreaming,
    String? toolName,
    String? toolArgs,
    String? fileName,
    Uint8List? imageBytes,
  }) {
    return ChatMessage(
      id:          id          ?? this.id,
      type:        type        ?? this.type,
      content:     content     ?? this.content,
      timestamp:   timestamp   ?? this.timestamp,
      isStreaming:  isStreaming  ?? this.isStreaming,
      toolName:    toolName    ?? this.toolName,
      toolArgs:    toolArgs    ?? this.toolArgs,
      fileName:    fileName    ?? this.fileName,
      imageBytes:  imageBytes  ?? this.imageBytes,
    );
  }
}
```

Add `import 'dart:typed_data';` at the top of `chat_message.dart`.

Note: `imageBytes` holds the raw decoded bytes, not base64. Storing base64 in a
`String` and calling `base64Decode` inside `ChatMessageWidget.build` would re-decode
on every streaming delta (dozens per second during a live text response), causing
jank and unnecessary allocation. Decode once at send time; store the result.

---

### 6. `lib/services/ag_ui_service.dart` — `sendMultimodalMessage` method

Add alongside the existing `sendMessage` method:

```dart
Stream<BaseEvent> sendMultimodalMessage(
  String endpoint,
  List<InputContent> parts,
) async* {
  try {
    _connectionController.add(ConnectionStatus.connecting);

    final input = SimpleRunAgentInput(
      threadId: 'thread_${DateTime.now().millisecondsSinceEpoch}',
      runId: 'run_${DateTime.now().millisecondsSinceEpoch}',
      messages: [
        UserMessage.multimodal(
          id: 'user_${DateTime.now().millisecondsSinceEpoch}',
          parts: parts,
        ),
      ],
      tools: [],
      context: [],
      state: <String, dynamic>{},
      forwardedProps: <String, dynamic>{},
    );

    _connectionController.add(ConnectionStatus.connected);

    await for (final event in _client.runAgent(endpoint, input)) {
      yield event;
    }

    _connectionController.add(ConnectionStatus.disconnected);
  } catch (e) {
    _connectionController.add(ConnectionStatus.error);
    debugPrint('Error sending multimodal message: $e');
    rethrow;
  }
}
```

`UserMessage.multimodal` serializes `content` as a JSON array; the Go server's
`aguitypes` already parses this form.

---

### 7. New `lib/pages/multimodal_chat_page.dart`

`MultimodalChatPageState` lives in `chat_page.dart` (see item 0). This new file
contains only the `MultimodalChatPage` widget and `MultimodalChatPageView`.

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/endpoint_config.dart';
import '../services/ag_ui_service.dart';
import '../widgets/chat_message_widget.dart';
import '../widgets/multimodal_input_widget.dart';
import 'chat_page.dart';   // exports MultimodalChatPageState as a public type

class MultimodalChatPage extends StatelessWidget {
  final EndpointConfig endpoint;
  const MultimodalChatPage({Key? key, required this.endpoint}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Register as MultimodalChatPageState so the view's watch<MultimodalChatPageState>()
    // resolves correctly. Provider's lookup is by exact static type.
    return ChangeNotifierProvider<MultimodalChatPageState>(
      create: (_) => MultimodalChatPageState(endpoint: endpoint),
      child: const MultimodalChatPageView(),
    );
  }
}

class MultimodalChatPageView extends StatelessWidget {
  const MultimodalChatPageView({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Watch the subtype — not ChatPageState — so Provider resolves the right instance.
    final state = context.watch<MultimodalChatPageState>();
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.background,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(state.endpoint.name, style: theme.textTheme.titleMedium),
            Text(
              state.endpoint.description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          if (state.connectionStatus != ConnectionStatus.disconnected)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Icon(
                _connectionIcon(state.connectionStatus),
                color: _connectionColor(state.connectionStatus, theme),
                size: 20,
              ),
            ),
        ],
        bottom: state.isLoading
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                ),
              )
            : null,
      ),
      body: Column(
        children: [
          Expanded(
            child: state.messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(state.endpoint.icon, size: 64,
                             color: theme.colorScheme.outline),
                        const SizedBox(height: 16),
                        Text('Attach a file to begin',
                             style: theme.textTheme.titleLarge?.copyWith(
                               color: theme.colorScheme.outline)),
                      ],
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    itemCount: state.messages.length,
                    itemBuilder: (context, index) {
                      final reversedIndex = state.messages.length - 1 - index;
                      return ChatMessageWidget(message: state.messages[reversedIndex]);
                    },
                  ),
          ),
          MultimodalInputWidget(
            endpoint: state.endpoint,
            isEnabled: !state.isLoading,
            onPickFile: () => state.pickFile(state.endpoint.allowedExtensions, context),
            onSend: state.sendMultimodal,
            onClear: state.clearPicked,
          ),
        ],
      ),
    );
  }

  IconData _connectionIcon(ConnectionStatus s) => switch (s) {
        ConnectionStatus.connected    => Icons.check_circle,
        ConnectionStatus.connecting   => Icons.sync,
        ConnectionStatus.error        => Icons.error,
        ConnectionStatus.disconnected => Icons.circle_outlined,
      };

  Color _connectionColor(ConnectionStatus s, ThemeData theme) => switch (s) {
        ConnectionStatus.connected    => Colors.green,
        ConnectionStatus.connecting   => theme.colorScheme.primary,
        ConnectionStatus.error        => theme.colorScheme.error,
        ConnectionStatus.disconnected => theme.colorScheme.outline,
      };
}
```

---

### 8. New `lib/widgets/multimodal_input_widget.dart`

Bottom input area for the multimodal tabs. Reads picked-file state from
`context.watch<MultimodalChatPageState>()`.

```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/endpoint_config.dart';
import '../pages/chat_page.dart';   // for MultimodalChatPageState

class MultimodalInputWidget extends StatefulWidget {
  final EndpointConfig endpoint;
  final bool isEnabled;
  final VoidCallback onPickFile;
  final void Function(String question) onSend;
  final VoidCallback onClear;

  const MultimodalInputWidget({
    Key? key,
    required this.endpoint,
    required this.isEnabled,
    required this.onPickFile,
    required this.onSend,
    required this.onClear,
  }) : super(key: key);

  @override
  State<MultimodalInputWidget> createState() => _MultimodalInputWidgetState();
}

class _MultimodalInputWidgetState extends State<MultimodalInputWidget> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MultimodalChatPageState>();
    final theme = Theme.of(context);
    final isAudio = widget.endpoint.path == 'audio';

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Preview strip — shown only when a file is picked.
          if (state.hasFile)
            _FilePreview(
              endpoint: widget.endpoint,
              bytes: state.pickedBytes,
              fileName: state.pickedFileName ?? '',
              onClear: widget.isEnabled ? widget.onClear : null,
            ),

          // Input row.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Row(
              children: [
                // Attach button.
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: widget.isEnabled ? widget.onPickFile : null,
                  tooltip: 'Attach file',
                ),

                // Question text field (hidden for audio — no text input needed).
                if (!isAudio)
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: InputDecoration(
                        hintText: widget.endpoint.path == 'document'
                            ? 'Ask a question about the document...'
                            : 'Describe what you want to know...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                      ),
                      enabled: widget.isEnabled,
                      onSubmitted: state.hasFile && widget.isEnabled
                          ? (_) {
                              widget.onSend(_controller.text);
                              _controller.clear();
                            }
                          : null,
                    ),
                  )
                else
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('Pick an audio file and tap Send to transcribe.',
                                  style: TextStyle(color: Colors.grey)),
                    ),
                  ),

                // Send button.
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: state.hasFile && widget.isEnabled
                      ? () {
                          widget.onSend(_controller.text);
                          _controller.clear();
                        }
                      : null,
                  tooltip: 'Send',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Thumbnail / icon preview strip shown above the input row when a file is picked.
class _FilePreview extends StatelessWidget {
  final EndpointConfig endpoint;
  final Uint8List? bytes;
  final String fileName;
  final VoidCallback? onClear;

  const _FilePreview({
    required this.endpoint,
    required this.bytes,
    required this.fileName,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          if (endpoint.path == 'vision' && bytes != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.memory(bytes!, height: 60, fit: BoxFit.cover),
            )
          else
            Icon(
              endpoint.path == 'audio'
                  ? Icons.audio_file
                  : Icons.picture_as_pdf,
              size: 36,
              color: theme.colorScheme.primary,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              fileName,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: onClear,
            tooltip: 'Remove',
          ),
        ],
      ),
    );
  }
}
```

---

### 9. `lib/widgets/chat_message_widget.dart` — render attachment types

Add three new early-return branches **after** the existing `ChatMessageType.image`
branch and **before** the regular bubble layout:

```dart
// Image the user uploaded — thumbnail on the right (user side).
if (message.type == ChatMessageType.imageAttachment) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,  // right-aligned
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: message.imageBytes != null
                ? Image.memory(
                    message.imageBytes!,   // ← already decoded; no base64Decode call
                    fit: BoxFit.contain,
                    width: 200,
                    errorBuilder: (_, __, ___) =>
                        const Text('(image failed to load)'),
                  )
                : const Text('(no image data)'),
          ),
        ),
        const SizedBox(width: 8),
        CircleAvatar(
          radius: 16,
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(Icons.person, size: 20,
                      color: theme.colorScheme.onPrimaryContainer),
        ),
      ],
    ),
  );
}

// Audio or document attachment bubble on the right.
if (message.type == ChatMessageType.audioAttachment ||
    message.type == ChatMessageType.documentAttachment) {
  final isAudio = message.type == ChatMessageType.audioAttachment;
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isAudio ? Icons.audio_file : Icons.picture_as_pdf,
                size: 20,
                color: theme.colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 8),
              Text(
                message.fileName ?? message.content,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        CircleAvatar(
          radius: 16,
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(Icons.person, size: 20,
                      color: theme.colorScheme.onPrimaryContainer),
        ),
      ],
    ),
  );
}
```

Note: `message.imageBytes` is used directly — no call to `base64Decode`. The existing
`ChatMessageType.image` branch (for the image-gen output) still uses
`message.content.split(',').last` because that branch receives a `data:`-prefixed URL
from the Go server, not bare bytes. These two branches handle fundamentally different
data: one is an AI-generated image URL, the other is user-uploaded bytes.

---

### 10. `lib/main.dart` — route multimodal endpoints to `MultimodalChatPage`

Replace the single `page = ChatPage(...)` assignment:

```dart
import 'pages/multimodal_chat_page.dart';   // ← add import

// In _MyHomePageState.build:
Widget page = endpoint.isMultimodal
    ? MultimodalChatPage(
        key: ValueKey(endpoint.path),
        endpoint: endpoint,
      )
    : ChatPage(
        key: ValueKey(endpoint.path),
        endpoint: endpoint,
      );
```

---

## Testing checklist

All three server endpoints are fully implemented (Go commits `4e8298b`, `985860d`).
Each returns the full response in a single `TEXT_MESSAGE_CONTENT` event (not streamed
in deltas) — the existing `_handleEvent` text-streaming path handles this correctly.

- [ ] `flutter build macos` passes with no errors
- [ ] Three new tabs appear in the nav rail (Vision, Audio, Document Q&A)
- [ ] File picker opens on "Attach" tap; correct extensions are filtered
- [ ] Picked image shows thumbnail preview; picked audio/PDF shows icon + filename
- [ ] File > 5 MB shows snackbar and is rejected; state is not updated
- [ ] Dismiss ✕ button clears the preview and resets state
- [ ] Send is disabled when no file is picked
- [ ] Send is disabled while a response is loading
- [ ] Switching tabs mid-stream does not throw (disposed-state guard)
- [ ] Attachment bubble appears on the right before the response
- [ ] Vision tab: pick a PNG, type "What's in this image?", send → GPT-4o description appears
- [ ] Vision tab: pick a PNG with no question → send still works; server defaults to "Describe this image in detail."
- [ ] Audio tab: pick a WAV, send → Whisper transcription appears
- [ ] Document tab: pick a PDF, type a question, send → GPT-4o answer appears (Responses API, inline PDF)
- [ ] Document tab: pick a PDF with no question → send still works; server defaults to "Summarize this document."
- [ ] Document tab: send with no document part → RUN_ERROR bubble appears in chat
- [ ] Existing 7 tabs are unaffected by all changes
- [ ] "Image Gen" tab still generates images correctly

## Build notes

- `dart:typed_data` is needed wherever `Uint8List` is referenced (`chat_message.dart`,
  `chat_page.dart`, `multimodal_input_widget.dart`). It is a Dart core library — no
  pubspec change needed.
- `dart:convert` is needed in `chat_page.dart` for `base64Encode`. No pubspec change.
- `file_picker` requires macOS entitlement `com.apple.security.files.user-selected
  .read-only` in both entitlement files (see items 2 and 3). `withData: true` tells
  the plugin to populate `PlatformFile.bytes` in addition to the path; on macOS the
  sandbox grants access to the selected path via the entitlement, and using in-memory
  bytes avoids a second sandbox round-trip.
- The MIME map in `MultimodalChatPageState._mimeTypeFor` covers every extension listed
  in `EndpointConfig.allowedExtensions` and falls back to `application/octet-stream`
  for anything not in the map. `DataSource` requires a non-null, non-empty `mimeType`;
  the fallback satisfies this invariant for unknown extensions rather than throwing.
- The `_disposed` flag in `ChatPageState` is `false`-initialized and set `true` in
  `dispose()` before `super.dispose()`. Subclasses that override `dispose()` must call
  `super.dispose()` last (standard Flutter convention) — the flag is already set when
  the superclass `dispose()` runs, so `ChangeNotifier.dispose()` finding zero listeners
  is correct.
