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

## State

`~/.local/state/roster/`: `agents/<name>/agent.json` and `inbox/{tmp,new,cur}` per agent, `sessions/<claude session id>`, `peers/`, `outbox/`. Every write is a temp file renamed into place.
