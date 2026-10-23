# SDK agents: roster's own harness on the Claude Agent SDK

A roster tmux agent runs one of two harnesses, recorded per entry as `harness`:

- `claude`: Claude Code's own TUI, as before. roster reads its status from Claude Code's hooks and drives it by typing into the tmux session.
- `sdk`: roster's runner (`roster-brain agent <session id>`, `brain/roster_brain/runner.py`) on the Claude Agent SDK. It is the default for new agents. An agent keeps the harness it started with, through park, resume and `move --to`, so the two kinds live side by side.

`roster new --harness claude` (or `harness = "claude"` in `~/.config/roster/config.toml`) still starts a Claude Code agent.

## What stays the same

An SDK agent is a tmux agent like any other: its session runs the runner instead of `claude`. Everything roster does with the session works unchanged: `list`, `attach` (its window shows the runner's UI), `kill`, `park` and resume on demand, `move --to`, `cleanup`, and the hub and app. Inside, it is the same Claude Code engine (the SDK runs the CLI headless) with the user's settings, CLAUDE.md, skills, MCP servers and hooks, so mail arrives through the same roster hooks and the agent uses the same `roster` commands. Its conversation is a normal Claude session in `~/.claude/projects`, so `roster transcript` and `claude --resume <id>` work on it too.

It always runs on the machine's own subscription login: the runner drops `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` from its environment and refuses a session that reports any other `apiKeySource` than `none`.

## What is native

The runner drives the session through the SDK instead of a screen:

| | Claude Code agent | SDK agent |
|---|---|---|
| Status | from hooks | written by the runner as it happens (`working`, `idle`, `blocked`) |
| Prompt | typed into the session; refused while text sits in its input | sent at once; during a turn Claude takes it in at its next step, as Claude Code does with a message typed mid-turn |
| Interrupt | (Esc in its window) | `roster interrupt`, Esc or ^C in its window, `POST /v1/interrupt` |
| Model | at start (`--model`, `resume --model`) | live: `roster model`, `/model` in its window, `POST /v1/model` |
| Effort | at start | live: `roster effort`, `/effort` in its window, `POST /v1/effort` |
| Permission prompts and questions | parsed from the screen | structured: the runner's `can_use_tool` turns each into a dialog (`roster screen` shows it, `roster keys <n>` or the app picks an option, Esc declines) |
| API errors | StopFailure hook, then `roster revive` types "carry on" | the runner retries by itself, five times at most, after 5 minutes for a rate limit |
| Mail while idle | a wake prompt typed in | the runner wakes itself when it goes idle with mail waiting, and `roster send` queues a wake prompt |

The model and effort it runs with are kept in its entry, so a park or resume starts it the same way. Live effort switching uses the CLI's flag-settings control request (`apply_flag_settings` with `effortLevel`), as Claude Code's own `/effort` does; the SDK has no public call for it yet.

## Its window

The output scrolls above a status line (name, status, model, effort) and an input line. Enter sends, also while it works. Esc or ^C interrupts a turn (^C first clears typed text). `/model <name>`, `/effort <level>` and `/interrupt` are handled by the runner; other `/commands` go to Claude. While a dialog is open, type an option's number, or text for its free-text option, or Esc to decline.

## The control socket

`$XDG_RUNTIME_DIR/roster/<session id>.sock` (mode 600). One JSON request per connection, one JSON line back; `{"error": …}` on failure.

| Request | Answer |
|---|---|
| `{"op": "status"}` | `{"name", "status", "model", "effort", "dialog", "queued", "input", "session_id"}` |
| `{"op": "screen"}` | `{"text", "dialog", "status"}`: the last 60 lines shown |
| `{"op": "prompt", "text", "source"?}` | `{"ok", "queued"}`; refused while a dialog is open |
| `{"op": "interrupt"}` | `{"ok": interrupted}` |
| `{"op": "model", "model"}` / `{"op": "effort", "effort"}` | `{"ok", "model"}` / `{"ok", "effort"}` |
| `{"op": "answer", "key", "text"?}` | picks option `key` of the open dialog (`escape` declines); a multi-select option toggles |
| `{"op": "keys", "keys": [...]}` | the same in `roster keys` terms: a digit picks, `Escape` declines, `Enter` submits a multi-select, `y`/`n` |

A dialog is `{"title", "options": [{"key", "label", "detail"?, "input"?, "checked"?}], "multi", "cursor"}`, the shape `roster screen` gives for a Claude Code dialog.

## Requirements

The runner runs in the brain's venv (`~/.local/share/roster/brain-venv`, from `brain/requirements.txt`), which `roster install` sets up on every machine. A machine where that fails still runs Claude Code agents; `roster new` then says to use `--harness claude`.
