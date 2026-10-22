"""~/.config/roster/brain.toml, with defaults that work with no file at all."""

import os
import tomllib

CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "roster")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "roster", "brain")
SECRETS = os.path.expanduser("~/.config/secrets")

DEFAULTS = {
    "listen": "127.0.0.1:8791",
    "default_model": "claude:sonnet",
    "agent_model": "claude:sonnet",
    "strategy": "first",
    "token_file": None,
    "openrouter_key_file": os.path.join(SECRETS, "openrouter-token"),
    "deciders": [],
    "models": {
        "claude:sonnet": "Claude Sonnet (subscription)",
        "claude:opus": "Claude Opus (subscription)",
        "claude:haiku": "Claude Haiku (subscription)",
    },
    "tools": {},
}


class ConfigError(Exception):
    pass


def load(path=None):
    path = path or os.environ.get("ROSTER_BRAIN_CONFIG") or os.path.join(CONFIG_DIR, "brain.toml")
    cfg = {k: (v.copy() if isinstance(v, (dict, list)) else v) for k, v in DEFAULTS.items()}
    if os.path.exists(path):
        with open(path, "rb") as f:
            try:
                got = tomllib.load(f)
            except tomllib.TOMLDecodeError as exc:
                raise ConfigError("%s: %s" % (path, exc))
        for k, v in got.items():
            if k == "models":
                cfg["models"].update(v)
            else:
                cfg[k] = v
    cfg["path"] = path
    check(cfg)
    return cfg


def check(cfg):
    if cfg["strategy"] not in ("first", "race"):
        raise ConfigError("strategy must be first or race, not %r" % cfg["strategy"])
    names = set()
    for d in cfg["deciders"]:
        if not d.get("name") or d.get("kind") not in ("openrouter", "jev", "http"):
            raise ConfigError("every [[deciders]] needs a name and kind = openrouter, jev or http: %r" % d)
        if d["name"] in names:
            raise ConfigError("two deciders named %s" % d["name"])
        names.add(d["name"])
        if d["kind"] == "openrouter" and not d.get("model"):
            raise ConfigError("decider %s needs a model" % d["name"])
        if d["kind"] == "http" and not d.get("url"):
            raise ConfigError("decider %s needs a url" % d["name"])
    for name, t in cfg["tools"].items():
        cmd = t.get("command")
        if not isinstance(cmd, list) or not cmd or not all(isinstance(c, str) for c in cmd):
            raise ConfigError("tool %s: command must be a list of strings" % name)
    for m in [cfg["default_model"], cfg["agent_model"]]:
        split_model(m)
    if not cfg["agent_model"].startswith("claude:"):
        raise ConfigError("agent_model must be a claude: model")


def split_model(model_id):
    provider, sep, name = model_id.partition(":")
    if not sep or provider not in ("claude", "openrouter") or not name:
        raise ConfigError("model %r is not claude:<model> or openrouter:<id>" % model_id)
    return provider, name


def read_secret(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None
