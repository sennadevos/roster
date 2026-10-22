# roster

An opt-in roster of Claude Code agents: each agent has a name, a status and a maildir inbox, so agents can see each other and send messages without blocking. Agents live in detached tmux sessions (one per agent, on a private tmux server) and are shown in a terminal window each. Several machines can be linked, so agents on one see and message agents on another.

## Install

On any Linux host, as the user that runs the agents. Nothing is installed outside `~/.local`, so this works on Fedora Atomic or CoreOS as they come:

```sh
curl -fsSL https://raw.githubusercontent.com/sennadevos/roster/main/install.sh | sh
```

`install.sh` fetches a standalone Python and the static tmux build when the host has none. It then runs `roster install`, which writes `~/.config/roster/tmux.conf` and the `roster-tmux` user unit, adds roster's hooks to `~/.claude/settings.json` (leaving everything else there alone), and installs the roster skill for Claude Code. Use `--from <checkout>` to install from a local copy, and pass `--tray` to also install the system tray menu, `--no-hooks` or `--no-skill` to skip those parts.

## Use

```sh
roster new [dir] [--name N] [--role R] [--prompt P]   # start an agent; opens in this terminal
roster list                                            # every agent, here and on peers
roster attach <name>                                   # focus its window, or open one
roster send <name> "message"                           # from inside an agent
roster kill | resume | rename | cleanup                # see roster -h
```

Agents use the `roster` skill to join, rename themselves, and message each other. `roster-tray` (a StatusNotifierItem menu) and `roster-pick` (a fuzzel menu for a keybinding) are front ends on the CLI.

## Folder trust

Starting an agent in a folder counts as trusting it: `roster new` and `roster resume` record Claude Code's folder trust for it (in `~/.claude.json`, keyed like Claude does: the repository root, or the folder itself), so a new agent does not stop at "Do you trust this folder?". Set `trust = false` in `~/.config/roster/config.toml` to keep Claude's question instead.

## API errors

When a turn ends on a transient API error (connection lost, DNS, overloaded, server error, rate limit), roster marks the agent in `roster list` and leaves a small reviver behind. Once the API host answers again (and at least five minutes after a rate limit), it types a prompt to carry on into the agent, but only when it is idle, nobody is in its window and its input line is empty. Five failed revives in a row and it gives up; login and billing errors are only shown. `roster revive <name>` does the same by hand.

## Other machines

```sh
roster peer add user@host
```

installs roster on that host over your SSH and links the two machines both ways. Each side gets a roster key of its own that is pinned in the other's `authorized_keys` to `roster rpc`, so a peer can list, deliver mail, attach, and start or end agents, but never gets a shell. After that:

- `roster list`, the tray and the picker show the other machine's agents under its name.
- `roster send name@host-machine` delivers there; while it is unreachable, mail waits in an outbox.
- `roster attach` opens a remote agent in a local window over SSH.
- `roster new --on <machine>` starts one there.

Every row and message says which machine it is from, so agents know that paths on another machine are not theirs.

## Phone app and roster-hub

`roster-hub` is a small HTTP API and event stream over the roster CLI, for the Android app. It runs on one always-on machine and does everything through `roster` there, so the phone sees and drives every agent on every linked machine: the list, each agent's conversation and screen, prompts, dialog answers, new, resume and kill, and push notifications (through UnifiedPush and ntfy) when an agent blocks, finishes a long turn or hits an API error that needs you. The API is in [docs/hub-api.md](docs/hub-api.md).

```sh
roster install --hub          # writes and starts the roster-hub user unit
roster-hub pair --name pixel  # a one-time code for the app, valid 10 minutes
roster-hub devices            # paired phones; roster-hub revoke <id> removes one
```

Config is `~/.config/roster/hub.toml`: `listen` (a private `host:port`; the hub refuses public and wildcard addresses), `public_url` (what the app connects to), `push_token_file` (default `~/.config/secrets/ntfy-roster-hub-token`) and `push_allowed` (URL prefixes a phone's push endpoint must start with, default `https://ntfy.sennadevos.com/`). It speaks plain HTTP: put a TLS reverse proxy in front of it, which must set `X-Forwarded-For`. Paired devices are in `~/.local/state/roster/hub/devices.json`, which holds only hashes of their tokens.

## Chats and agents: roster-brain

`roster-brain` holds chats and Claude agent sessions behind one router. Decision models (Jev on OpenRouter's Decisions API, a fast chat model, or your own endpoint) see each message first and answer a yes/no themselves, run a declared fast tool, or pick the model that answers: an OpenRouter model or Claude on the machine's own subscription login (Agent SDK, never an API key). Frontends such as a launcher bar talk to its HTTP API on `127.0.0.1:8791`. The design and API are in [docs/brain.md](docs/brain.md).

```sh
roster install --brain        # its venv, plus the roster-brain user unit
roster-brain check            # what the config resolves to
roster-brain ask "is 17 prime?"
```

Config is `~/.config/roster/brain.toml`; the OpenRouter key is read from `~/.config/secrets/openrouter-token`.

## State

`~/.local/state/roster/`: `agents/<name>/agent.json` and `inbox/{tmp,new,cur}` per agent, `sessions/<claude session id>`, `peers/`, `outbox/`. Every write is a temp file renamed into place.
