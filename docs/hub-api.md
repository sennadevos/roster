# roster-hub and the phone app: the contract

Three parts, built against this document:

- **roster CLI** (`bin/roster`): new commands `transcript`, `screen`, `prompt`, `keys`, each also reachable on peers over `roster rpc`.
- **roster-hub** (`bin/roster-hub`): an HTTPS-facing JSON API and event stream for phones. It runs on one always-on machine (srv-agents-01), uses only the roster CLI on that machine, and so reaches every agent on every linked machine. Python 3.11+ stdlib only.
- **The app** (`app/`): Flutter, Android, package id `nl.sennadevos.roster`.

An agent is always named `name@machine` across the hub and the app (`rator-firmware/ui@hp-probook`).

## 1. roster CLI additions

All take `<agent>` as `name` or `name@machine`, print JSON with `--json`, and exit 1 with `roster: <reason>` on stderr on failure. Each has an rpc verb of the same name, so they work on peers.

### `roster transcript <agent> [--after I] [--limit N] --json`

The agent's Claude conversation, from its transcript JSONL (`~/.claude/projects/<dir>/<session_id>.jsonl` on its own machine).

```json
{"agent": "infra@hp-probook", "session_id": "…", "messages": [
  {"i": 412, "at": "2026-10-18T16:32:11+0200", "role": "user", "text": "…"},
  {"i": 413, "at": "…", "role": "assistant", "text": "…"},
  {"i": 414, "at": "…", "role": "tool", "tool": "Bash", "text": "git status", "result": "…(≤2000 chars)…", "error": false}
 ], "next": 415}
```

- `i` is the JSONL line number (from 1). `--after I` returns the first `--limit` messages with a larger `i`, plus earlier tool calls whose result arrived after `I` (same `i`, to merge); `next` is what to pass next time. `--before I` returns the last `--limit` messages with a smaller `i`, for scrolling back. With neither, the last `--limit` (default 200).
- `role`: `user` (what the user, a wake or a hook-injected prompt typed), `assistant` (text Claude wrote), `tool` (a tool call, with its result folded in once it exists; `text` is a one-line summary: the command, the file path, the query).
- Skipped: meta lines, thinking blocks, system/summary lines, empty texts.

### `roster screen <agent> --json`

What is on the agent's terminal now, and the dialog if one is open.

```json
{"agent": "…", "status": "blocked", "text": "…plain screen text…",
 "dialog": {"title": "Do you want to make this edit to viewer.js?",
            "options": [{"key": "1", "label": "Yes"}, {"key": "2", "label": "Yes, and don't ask again …"}, {"key": "3", "label": "No, and tell Claude what to do differently"}]}}
```

`dialog` is `null` unless a Claude choice dialog is on screen (numbered options above an `Esc to cancel` footer). `key` is the key that picks the option, `detail` its description. A question that takes several answers has `"multi": true` and a `checked` flag per option (the key toggles it). A form of several questions has `tabs` (`[{"label", "done"}]`) and `actions` (`[{"label": "Back", "keys": ["Left"]}, {"label": "Next", "keys": ["Right"]}]`) to move between them; its last tab offers Submit and Cancel as options.

### `roster prompt <agent> [text | -]`

Type a prompt into the agent as the user and press Enter. Refused when the agent is gone, when a dialog is open (status `blocked`: answer it with `keys`), or when its input line already holds typed text. Allowed while it is working: Claude Code queues it.

### `roster keys <agent> KEY…`

Send keys, to answer a dialog. Allowed: `Up Down Left Right Enter Escape Tab BSpace` and single characters `0-9 y n`.

## 2. roster-hub

Runs as the user unit `roster-hub.service` (written by `roster install --hub`), listening on plain HTTP on a private address (`listen` in `~/.config/roster/hub.toml`, e.g. `10.137.42.3:8790`). TLS is done by the reverse proxy in front of it (`https://roster.sennadevos.com`). It must never be bound to a public address itself.

### Auth

- Every request except `POST /v1/pair` and `GET /v1/version` carries `Authorization: Bearer <device token>`.
- Device tokens: 32 random bytes, urlsafe base64. The hub stores only their SHA-256, in `~/.local/state/roster/hub/devices.json` (mode 600), with the device id, name, created and last-seen times, and its push endpoint. Compare in constant time.
- Pairing: `roster-hub pair [--name NAME]` (run on the hub machine, or `ssh` there) prints a one-time code (8 characters, unambiguous alphabet, valid 10 minutes) and the public URL. The app posts it to `/v1/pair` and gets its token. Failed pair attempts are rate limited per client address (`X-Forwarded-For` from the proxy, else the socket): 5 per 10 minutes.
- `roster-hub devices` lists devices, `roster-hub revoke <id>` removes one.
- Request bodies over 256 KiB are refused. Unknown paths: 404 JSON.

### Endpoints (JSON in and out; errors are `{"error": "…"}` with 4xx/5xx)

| Method and path | Body / query | Answer |
|---|---|---|
| `GET /v1/version` | | `{"hub": "0.3.0", "api": 1}` |
| `POST /v1/pair` | `{"code", "device_name"}` | `{"token", "device_id"}` |
| `GET /v1/agents` | `?all=1` for gone ones too | `{"agents": [row…], "machines": [{"name", "local": bool, "reachable": bool, "error"}]}`; a row is a `roster list --json` row plus `"agent": "name@machine"`; a live row has `subagents`: `[{"id", "type", "label", "status": "running"|"done", "started_at", "ended_at"}]`, the subagents it runs (shown under it, never as agents; finished ones stay two minutes) |
| `GET /v1/transcript` | `?agent=&after=&before=&limit=` | as `roster transcript --json` |
| `GET /v1/screen` | `?agent=` | as `roster screen --json` |
| `POST /v1/prompt` | `{"agent", "text"}` | `{"ok": true}` |
| `POST /v1/answer` | `{"agent", "key", "text"}`: type your own answer into the dialog's free-text option (`input: true`) and submit it | `{"ok": true}` |
| `POST /v1/keys` | `{"agent", "keys": [...]}` | `{"ok": true}` |
| `POST /v1/new` | `{"machine", "cwd", "name", "role", "prompt", "model", "effort"}` (all but `machine` optional; `effort` is `low`, `medium`, `high`, `xhigh` or `max`; `model` an alias such as `opus` or a full model name) | `{"agent"}` |
| `POST /v1/resume` | `{"agent"}` | `{"ok": true}` |
| `POST /v1/kill` | `{"agent"}` | `{"ok": true}` |
| `POST /v1/push` | `{"endpoint"}` (UnifiedPush endpoint URL), or `{"endpoint": null}` to stop | `{"ok": true}` |
| `GET /v1/devices` | | `{"devices": [{"id", "name", "created", "last_seen", "push": bool, "current": bool}]}` |
| `DELETE /v1/devices/{id}` | | `{"ok": true}` |
| `GET /v1/events` | | Server-Sent Events, see below |

The hub runs the CLI as `roster <command> … --json` (path from `ROSTER_BIN`, default `~/.local/bin/roster`) with a timeout, and passes its errors on as 4xx (`roster: …` text as `error`).

### Events: `GET /v1/events` (text/event-stream)

- `event: agents` with `data: <same JSON as GET /v1/agents>`, sent on connect and after every change (the hub follows `roster events --all`, debounced 300 ms, and only sends when the list differs).
- `event: ping`, `data: {}` every 25 s.
- Each event has an `id:`; the app reconnects with `Last-Event-ID` after a drop and just takes the next snapshot.

### Push (UnifiedPush through ntfy.sennadevos.com)

The app registers with the UnifiedPush distributor on the phone (the ntfy app) and gives the hub its endpoint. The hub posts to it with `Authorization: Bearer <token>` from `~/.config/secrets/ntfy-roster-hub-token` (an ntfy token allowed to write `up*` topics). Body: JSON

```json
{"type": "blocked|asking|finished|error", "agent": "name@machine", "title": "…", "body": "…"}
```

Sent when an agent's status becomes `blocked`; when a turn ends (`working` → `idle`/`done`) after running at least 60 s; when it gets an API error that needs the user (`stalled` with a non-transient error, or `gave_up`). The hub derives these from consecutive agent lists. Not sent for the agent the device is viewing right now? It cannot know; the app drops a push for the agent on screen.

## 3. The app

- **Pair**: hub URL (default `https://roster.sennadevos.com`) and the code; stores URL and token with `flutter_secure_storage`.
- **Agents**: grouped by machine (this hub's machines, reachable or not), each row: status glyph and colour, name, role, unread count, ⚠ when stalled. Live from `/v1/events`, reconnecting with backoff; pull to refresh.
- **Agent**: the conversation from `/v1/transcript` as a chat (user right, assistant left, tool calls as compact collapsible rows), loading older on scroll, new ones on each `agents` event that changes this agent. A composer sends `/v1/prompt`. When the agent is `blocked`, a card shows the dialog from `/v1/screen` with one button per option (→ `/v1/keys`). Menu: resume (gone), kill.
- **New agent**: machine, directory, name, role, first prompt.
- **Settings**: hub, devices (revoke), notifications on/off.
- **Push**: `unifiedpush` + `flutter_local_notifications`; tapping a notification opens that agent.
- Material 3, dark and light, works on a phone in one hand.
