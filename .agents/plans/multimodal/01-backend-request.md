# Backend Work — ag-ui-go-server-example

The full request for the Go server agent is in:

```
/Users/punk1290/git/ag-ui-go-server-example/MULTIMODAL_REQUEST.md
```

That request has been implemented. This document summarizes the actual contract
the Flutter frontend depends on (updated to match the implementation).

## Contract: `/image-gen` endpoint

**Method:** POST  
**Content-Type:** application/json  
**Request body:** standard AG-UI `RunAgentInput` (same shape as `/agentic`)  
**Response:** `text/event-stream` SSE, same AG-UI encoding as existing endpoints

### Required SSE event sequence

```
event: RUN_STARTED
data: { "type":"RUN_STARTED", "threadId":"...", "runId":"..." }

event: STATE_SNAPSHOT
data: { "type":"STATE_SNAPSHOT", "snapshot":{ "status":"generating", "prompt":"<user text>" } }

event: CUSTOM
data: { "type":"CUSTOM", "name":"image_generated", "value":{ "prompt":"<user text>", "url":"data:image/png;base64,<...>" } }

event: STATE_DELTA
data: { "type":"STATE_DELTA", "delta":[{ "op":"replace", "path":"/status", "value":"done" }] }

event: MESSAGES_SNAPSHOT
data: { "type":"MESSAGES_SNAPSHOT", "messages":[] }

event: RUN_FINISHED
data: { "type":"RUN_FINISHED", "threadId":"...", "runId":"..." }
```

### Prompt extraction

The server takes the last message with `role == "user"`. It handles both plain
string content and multimodal messages: when the content is an array of content
parts, all `text` parts are joined with newlines.

### Error paths

**Before the SSE stream opens** (HTTP 400 JSON, not an SSE event):
- Invalid JSON body → `{"error": "invalid request body"}`
- No user message / empty prompt → `{"error": "no user prompt provided"}`

The Flutter `catch` in `ChatPageState.sendMessage` will surface these as a
generic `"Error: ..."` system message. The `ChatInputWidget` trims and guards
empty sends, so the no-prompt 400 is unreachable in normal use.

**Inside the SSE stream** (RUN_ERROR event):
- OpenAI API failure → `RUN_ERROR` with `"image generation failed: <reason>"`

### Environment variables used

| Var | Required | Default | Notes |
|-----|----------|---------|-------|
| `OPENAI_API_KEY` | yes | — | Standard OpenAI key |
| `IMAGE_MODEL` | no | `gpt-image-1` | Override if needed |
| `IMAGE_SIZE` | no | `1024x1024` | Must be a valid size for the model |

The route does NOT use `MODEL_PROVIDER`, `MODEL`, or eino — it calls the OpenAI
Images API directly via `net/http`.

## Handler signature note

```go
func Handler(shutdownCtx context.Context, logger *slog.Logger) fiber.Handler
```

The first param is the **server-level shutdown context** (the `sigCtx` from
`main`), not a config struct. The stream-writer goroutine runs after the Fiber
handler returns (fasthttp recycles `RequestCtx` at that point), so the run context
must be derived from `shutdownCtx`. This mirrors the `agenticHandler` pattern and
ensures SIGTERM cancels in-flight image generation requests.

## No changes needed to existing `/agentic` route

The `/image-gen` route is additive. The existing agent loop, tools, model setup,
and runstore are not touched.
