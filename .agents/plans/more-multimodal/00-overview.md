# More Multimodal — Overview

## What this plan is for

The ag-ui Dart SDK's last commit completed full round-trip support for all six input
modalities: `text`, `image`, `binary`, `audio`, `video`, `document`. This plan extends
the Flutter demo to send multimodal `UserMessage.multimodal(parts: [...])` messages to
the server, demonstrating that the Dart SDK can construct and serialize every
`InputContent` variant correctly.

The existing "Image Gen" tab demonstrates multimodal **output** (text → image via a
`CUSTOM` event). This plan demonstrates multimodal **input** (media → text analysis /
transcription / Q&A).

## Repositories involved

| Repo | Role | Local path |
|------|------|------------|
| `ag_ui_demo` | Flutter frontend | `/Users/punk1290/git/ag_ui_demo` |
| `ag-ui-go-server-example` | Go backend | `/Users/punk1290/git/ag-ui-go-server-example` |
| `ag-ui` (dart SDK) | Path dependency | `/Users/punk1290/git/ag-ui/sdks/community/dart` |

## New tabs

| Tab | Endpoint | Modalities sent | Server cost |
|-----|----------|-----------------|-------------|
| **Vision** | `POST /vision` | `ImageInputContent` (DataSource, base64) + optional `TextInputContent` | Low — reuses existing eino multimodal image path (`openai` provider) |
| **Audio** | `POST /audio` | `AudioInputContent` (DataSource, base64, `audio/wav` or `audio/mp3`) | Medium — new dedicated handler (Whisper API) |
| **Document Q&A** | `POST /document` | `DocumentInputContent` (DataSource, base64, `application/pdf`) + `TextInputContent` (question) | High — new handler, PDF ingestion strategy TBD by Go team |

## Architecture decision: same-library extension

The existing `ChatPageState` (451 lines, `chat_page.dart`) contains a ~150-line
`_handleEvent` method covering text streaming, tool calls, state snapshots, and the
`image_generated` custom event. A parallel multimodal page that re-implements this
would duplicate the code and create a future divergence bug.

**Solution:** `MultimodalChatPageState extends ChatPageState`, defined in the **same
file** (`chat_page.dart`).

This is a hard constraint of Dart's library-privacy model: `_`-prefixed members
(`_messages`, `_service`, `_isLoading`, `_currentStreamingMessage`, `_handleEvent`)
are private to the `.dart` file, not the class. A subclass in a *different* file
cannot access them at all. Co-locating the subclass in `chat_page.dart` gives it full
access to these members at compile time.

`MultimodalChatPage` (the widget) and `MultimodalChatPageView` live in the new file
`multimodal_chat_page.dart`. They import `chat_page.dart` and reference
`MultimodalChatPageState` as a public type. `MultimodalChatPageView` is a new
`StatelessWidget` that watches `MultimodalChatPageState` (not the base
`ChatPageState`) so that `context.watch<T>()` resolves the correct Provider type.

## Stream cancellation pre-fix

`ChatPageState.sendMessage` has no cancellation guard. When the user switches tabs,
Flutter disposes the `ChangeNotifierProvider` and calls `dispose()` on the state — but
the in-flight `await for` keeps running and calls `notifyListeners()` on a disposed
`ChangeNotifier`, which throws. This is a pre-existing bug that the multimodal path
(slower Whisper / vision responses) amplifies.

**Fix (applied to `chat_page.dart` as part of this plan):** Add a `bool _disposed =
false` flag. Set it to `true` in `dispose()` before calling `super.dispose()`. Guard
every `_handleEvent` call and every `notifyListeners()` after `await for` with `if
(_disposed) break` / `if (!_disposed)`.

## Go server dependencies

A separate request file is at:
`/Users/punk1290/git/ag-ui-go-server-example/.agents/requests/multimodal-input-endpoints.md`

**Critical context for implementation planning:**
- Vision: the existing `/agentic` endpoint already converts `ImageInputContent` →
  eino `UserInputMultiContent` when `MODEL_PROVIDER=openai`, including `DataSource`
  (base64) images. A dedicated `/vision` route can reuse this path with a
  vision-optimized system prompt; it is not net-new vision plumbing.
- Audio/Document: `convert.go` explicitly drops these (`slog.Warn("unsupported
  multimodal content type, dropping")`). These need new dedicated handlers in the
  style of `internal/imagegen/handler.go`.

## Go server BodyLimit — resolved

The Go server raised `BodyLimit` to **20 MB** in commit `4e8298b`, explicitly to
accommodate a 5 MB Flutter file cap (5 MB × ~1.33 base64 inflation ≈ 6.7 MB encoded,
well under 20 MB). The Flutter client-side guard is set at **5 MB raw** to match.

## Out of scope

- **Video**: `VideoInputContent` uses `UrlSource` (remote URL), not a local file pick.
  Excluded from this plan to keep all three tabs consistent (file picker → base64 →
  DataSource). A URL-input demo could be added later to cover `UrlSource`.
- **Live camera/mic capture**: The demo uses file picker only. Platform-native capture
  requires additional permissions and is out of scope.
- **Conversation history**: Each multimodal request is a single-turn, stateless call
  (fresh `threadId`/`runId` per send), matching the image-gen pattern.

## Server status (as of Go commit `4e8298b`)

| Endpoint | Status | Notes |
|----------|--------|-------|
| `POST /vision` | ✅ Shipped | GPT-4o Chat Completions; returns full text in one `TEXT_MESSAGE_CONTENT` event |
| `POST /audio` | ✅ Shipped | Whisper-1 via multipart; returns full transcription in one event |
| `POST /document` | ✅ Shipped | OpenAI Responses API (`/v1/responses`) with inline base64 PDF; returns full answer in one `TEXT_MESSAGE_CONTENT` event |
| `BodyLimit` | ✅ 20 MB | Matches Flutter's 5 MB raw cap + base64 inflation |

## Prerequisites

- `OPENAI_API_KEY` set in Go server environment (all three endpoints require it).
- Go server running at `http://localhost:8000` (or `AG_UI_BASE_URL` env var).
- `MODEL_PROVIDER` is not required — all three handlers call OpenAI directly, not via eino.
- Optional env vars: `VISION_MODEL` (default `gpt-4o`), `AUDIO_MODEL` (default `whisper-1`), `DOCUMENT_MODEL` (default `gpt-4o`).
