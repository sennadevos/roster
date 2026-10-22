# roster-brain: chats and agents behind one router

roster-brain is a local service that holds chats and agent sessions, and decides per message who answers: a decision model (Jev or another fast model) itself, a simple tool call, an OpenRouter model, or Claude. Frontends (the launchbar, the roster app, a terminal) only talk to its HTTP API.

## Parts

- **Store**: SQLite in `~/.local/state/roster/brain/brain.db` (WAL). Conversations and every message, including which route answered it. A message is written before its answer streams and finished after, so a crash leaves a visible `"state": "partial"` message, never a silent gap.
- **Providers**: what generates an answer.
  - `claude`: the Claude Agent SDK on the machine's own `/login` (subscription). Never an API key: the service clears `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` from its environment and refuses a session whose `apiKeySource` is not `none`.
  - `openrouter`: OpenRouter's chat completions API, key in `~/.config/secrets/openrouter-token`.
- **Deciders**: decision models, asked first. Each gets the message, a short tail of the conversation and the catalog (models and fast tools), and returns one decision or passes. Kinds:
  - `openrouter`: any OpenRouter model asked for a JSON decision.
  - `jev`: Jev, TypeSafe's System One model on OpenRouter (`~typesafe/jev-latest`), through OpenRouter's Decisions API (`POST /api/alpha/decisions`). Jev writes no text; it answers typed questions, so one request asks them all (what kind of message this is, the probability the answer is yes, whether the answer depends on something it cannot see, which tool, which model) and the decision is read off the answers. About 0.25 s.
  - `http`: any model behind a JSON endpoint that speaks the contract below.
- **Fast tools**: commands declared in the config that a decider may run directly, without an LLM.
- **Router**: runs the deciders, applies the decision, falls back to the conversation's default model.

## Conversations

Two kinds:

- `chat`: the brain owns the history. Every turn may go to a different model; the model gets the history as messages. No tools beyond fast tools.
- `agent`: a Claude agent session (Agent SDK, tools, a working folder) that stays alive between turns and resumes by its Claude session id after a restart. A turn the router answers without Claude (a yes/no, a fast tool) is stored and handed to Claude as context at the start of its next turn, so Claude never misses what happened.

## Decisions

A decider returns JSON, one of:

```json
{"decision": "answer", "text": "Yes.", "confidence": 0.97}
{"decision": "tool", "tool": "lock-screen", "args": {}, "confidence": 0.95}
{"decision": "route", "model": "openrouter:google/gemini-3.8-flash", "confidence": 0.8}
{"decision": "pass"}
```

- `answer` and `tool` are taken only at or above the decider's `min_confidence` (default 0.9, for `jev` 0.8); below it they count as `pass`. A `jev` decider answers yes or no only when Jev puts the probability at or beyond `answer_at` (default 0.9) and judges the answer not to depend on anything it was not shown. It only runs tools without arguments, since Jev cannot fill them in.
- `route` names a model from the catalog; unknown models count as `pass`.
- Deciders run in config order (`strategy = "first"`, the first non-pass wins) or all at once (`strategy = "race"`, the first non-pass to arrive wins). Each has its own `timeout_ms`; a timeout is a pass. When every decider passes, the conversation's default model answers.
- An agent conversation only takes `answer` and `tool` from deciders, and they see only the new message, not the history (that is the agent's world, which they cannot see); anything else goes to its Claude session.
- An `http` decider gets `POST <url>` with `{"text", "kind": "chat"|"agent", "history": [{"role", "content"}], "tools": [{"name", "description"}], "models": [{"id", "description"}]}` (and `Authorization: Bearer` from `token_file` when set) and answers with one decision object. For a decision model of your own.
- A fast tool's `command` may hold `{name}` placeholders, filled from the decision's `args`; a missing argument fails the turn rather than running a half-filled command. `timeout_s` (default 10) bounds it.
- A message can skip the router: `"route": "model:<id>"` forces a model, `"route": "direct"` forces the conversation's default.

## Config: `~/.config/roster/brain.toml`

```toml
listen = "127.0.0.1:8791"
default_model = "claude:sonnet"

[[deciders]]
name = "jev"
kind = "jev"
timeout_ms = 1500

[[deciders]]
name = "flash"
kind = "openrouter"
model = "google/gemini-3.5-flash-lite"
timeout_ms = 2000
min_confidence = 0.9
enabled = false

[models]
# Shown in the catalog; any other openrouter:<id> is still accepted when asked for by name.
"claude:sonnet" = "Claude Sonnet (subscription)"
"claude:opus" = "Claude Opus (subscription)"
"openrouter:google/gemini-3.8-flash" = "Gemini Flash, fast general answers"

[tools.lock-screen]
description = "Lock the screen"
command = ["loginctl", "lock-session"]
```

Model ids are `<provider>:<model>`. `claude:<alias or full name>` and `openrouter:<OpenRouter model id>`.

## HTTP API

Plain HTTP on `listen` (loopback by default). With `token_file` set, every request needs `Authorization: Bearer <token>`. JSON in and out; errors are `{"error": "…"}` with a 4xx/5xx status.

| Method and path | Does |
| --- | --- |
| `GET /v1/health` | `{"ok": true, "version": …}` |
| `GET /v1/catalog` | models, deciders, fast tools |
| `GET /v1/conversations?kind=&limit=` | newest first |
| `POST /v1/conversations` | `{"kind": "chat"\|"agent", "title"?, "model"?, "cwd"? (agent), "system"?}` → the conversation |
| `GET /v1/conversations/{id}` | the conversation with its messages |
| `DELETE /v1/conversations/{id}` | ends an agent session, deletes the conversation |
| `POST /v1/conversations/{id}/messages` | `{"text", "route"?}` → an event stream (below) |
| `POST /v1/conversations/{id}/interrupt` | stops the turn in progress |
| `POST /v1/ask` | `{"text", "model"?, "route"?}`: a one-shot in a new chat, same event stream; the launchbar's quick path |
| `GET /v1/events` | server-sent events for every conversation (`message`, `conversation`), for frontends that keep a list open |

### The turn event stream

`POST …/messages` and `/v1/ask` answer with `text/event-stream`; each event is `event: <type>` plus one `data:` JSON line:

- `start`: `{"conversation": id, "message": id}` (the user message is stored)
- `route`: `{"by": "flash"|"default"|"forced", "decision": "answer"|"tool"|"route", "model"?, "tool"?, "ms": 212}`
- `delta`: `{"text": "…"}` (append)
- `tool`: `{"name", "input", "result"?, "error"?, "id"?}` (fast tools and Claude's own tool calls; a Claude call comes twice with the same `id`, once when it starts and once with its result)
- `done`: `{"message": id, "model", "ms", "usage"?}`
- `error`: `{"error": "…", "kind"?: "rate_limit"|"auth"|"server"|"invalid"}`, the stream then ends

A client that drops the stream does not stop the turn; the answer still lands in the conversation.

## Running

`roster-brain serve` runs it in the foreground; `roster install --brain` writes `roster-brain.service`. It runs on the machine whose frontends use it (the laptop for the launchbar). Its Python dependencies live in a venv under `~/.local/share/roster/brain-venv`, made by the installer.
