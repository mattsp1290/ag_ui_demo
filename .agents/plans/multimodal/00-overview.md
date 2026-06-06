# Multimodal Image Generation Demo — Overview

## Goal

Add an "Image Generation" tab to the Flutter AG-UI demo that lets the user type a
text prompt and receive a small AI-generated image powered by GPT-4o's image model
(`gpt-image-1`). The demo shows AG-UI's custom event mechanism carrying binary-safe
data (base64 PNG) from the server to the Flutter client.

## Repositories Involved

| Repo | Role | Local path |
|------|------|------------|
| `ag_ui_demo` | Flutter frontend | `/Users/punk1290/git/ag_ui_demo` |
| `ag-ui-go-server-example` | Go backend (AG-UI SSE server) | `/Users/punk1290/git/ag-ui-go-server-example` |
| `ag-ui` (dart SDK) | Used via path dep in pubspec.yaml | `/Users/punk1290/git/ag-ui/sdks/community/dart` |

## Architecture

```
Flutter app (ag_ui_demo)
  │
  │  POST /image-gen  (AG-UI RunAgentInput JSON body)
  ↓
Go server (ag-ui-go-server-example)
  │
  │  POST /v1/images/generations  (gpt-image-1, 1024x1024)
  │  Note: response_format NOT sent — gpt-image-1 returns b64_json by default
  ↓
OpenAI API
  │
  │  { data: [{ b64_json: "..." }] }
  ↑
Go server emits SSE stream of AG-UI events:
  1. RUN_STARTED
  2. STATE_SNAPSHOT  { status: "generating", prompt: "<user text>" }
  3. CUSTOM          name="image_generated"  value={ prompt, url: "data:image/png;base64,…" }
  4. STATE_DELTA     [{ op:"replace", path:"/status", value:"done" }]
  5. MESSAGES_SNAPSHOT
  6. RUN_FINISHED
  ↑
Flutter app handles CustomEvent → displays inline image in chat list
```

## Work Breakdown

### Backend — ag-ui-go-server-example
See `01-backend-request.md` and the request file dropped in that repo.

| Task | Notes |
|------|-------|
| New `internal/imagegen/client.go` | Thin OpenAI Images API wrapper (no eino needed — direct HTTP) |
| New `internal/imagegen/handler.go` | AG-UI handler: parse RunAgentInput, call client, emit events |
| Wire route in `cmd/server/main.go` | `app.Post("/image-gen", imagegen.Handler(sigCtx, logger))` — passes the server shutdown context, not `cfg` |

### Frontend — ag_ui_demo
See `02-flutter-changes.md`.

| Task | Notes |
|------|-------|
| New `EndpointConfig` | `/image-gen`, icon `Icons.image`, name "Image Gen" |
| New `ChatMessageType.image` | Carries a base64/data-URL string for the PNG |
| Update `ChatMessageWidget` | Render `Image.memory(base64Decode(dataUrl))` for image messages |
| Handle `CustomEvent` in `ChatPageState._handleEvent` | `event.name == 'image_generated'` → add image message |

## Prerequisites

- `OPENAI_API_KEY` must be set in the Go server's environment.
- `MODEL_PROVIDER` is **not used** by `/image-gen` — the route calls OpenAI directly via `net/http`, not through eino.
- Go server CORS is already enabled by default (`CORS_ENABLED=true`).
- The `gpt-image-1` model requires an OpenAI account with image generation access.

## Key Design Decisions

**Custom event for the image** — AG-UI's `CUSTOM` event carries an arbitrary JSON
value. The Go emitter already has `emit.Custom(name, value)`. The Dart SDK's
`CustomEvent` decodes this into `event.name` (string) and `event.value` (dynamic).
This avoids encoding the image in a text message and keeps the contract explicit.

**base64 by default, no `response_format` field sent** — `gpt-image-1` always
returns `b64_json` and rejects the `response_format` parameter (which is a DALL-E
2/3 field). The implementation intentionally omits it. The result avoids a second
round-trip to fetch a temporary URL and lets Flutter display the image offline.

**No conversation history for image-gen** — each request is independent (single
prompt → single image). The existing `AgUiService` already creates a fresh
`threadId` per call, which is correct here.

**Small image = 1024×1024** — `gpt-image-1` accepts `1024x1024`, `1536x1024`, or
`1024x1536`. We pick `1024x1024` (square, smallest area).
