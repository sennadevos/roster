"""roster-brain serve | check | ask TEXT"""

import argparse
import json
import os
import sys
import urllib.request

from . import VERSION
from . import config as config_mod


def scrub_env():
    # Subscription only: an API key in the environment would silently move
    # Claude's billing to the API (docs/brain.md, Providers).
    for k in list(os.environ):
        if k in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN") or k.startswith("CLAUDE_CODE_") or k == "CLAUDECODE":
            del os.environ[k]


def cmd_serve(cfg, args):
    scrub_env()
    from .server import serve
    print("roster-brain %s on http://%s (%s)" % (VERSION, cfg["listen"], cfg["path"]), flush=True)
    serve(cfg)


def cmd_check(cfg, args):
    print("config  %s%s" % (cfg["path"], "" if os.path.exists(cfg["path"]) else " (absent: defaults)"))
    print("listen  %s" % cfg["listen"])
    print("models  default %s, agents %s" % (cfg["default_model"], cfg["agent_model"]))
    print("deciders %s (%s)" % (", ".join(d["name"] for d in cfg["deciders"]) or "none", cfg["strategy"]))
    print("tools   %s" % (", ".join(cfg["tools"]) or "none"))
    key = config_mod.read_secret(cfg["openrouter_key_file"])
    print("openrouter key %s" % ("present" if key else "MISSING (%s)" % cfg["openrouter_key_file"]))


def cmd_ask(cfg, args):
    """A terminal frontend: one question, the answer streamed."""
    req = urllib.request.Request("http://%s/v1/ask" % cfg["listen"], method="POST",
                                 data=json.dumps({"text": " ".join(args.text), "route": args.route}).encode(),
                                 headers={"Content-Type": "application/json"})
    if cfg.get("token_file"):
        req.add_header("Authorization", "Bearer " + config_mod.read_secret(cfg["token_file"]))
    event = None
    with urllib.request.urlopen(req) as r:
        for raw in r:
            line = raw.decode().rstrip("\n")
            if line.startswith("event: "):
                event = line[7:]
            elif line.startswith("data: "):
                data = json.loads(line[6:])
                if event == "delta":
                    sys.stdout.write(data["text"])
                    sys.stdout.flush()
                elif event == "route" and args.verbose:
                    print("[%s]" % json.dumps(data), file=sys.stderr)
                elif event == "done":
                    print()
                    if args.verbose:
                        print("[%s]" % json.dumps(data), file=sys.stderr)
                elif event == "error":
                    print("\nroster-brain: %s" % data["error"], file=sys.stderr)
                    return 1
    return 0


def main():
    p = argparse.ArgumentParser(prog="roster-brain")
    p.add_argument("--config")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve")
    sub.add_parser("check")
    a = sub.add_parser("ask")
    a.add_argument("--route")
    a.add_argument("-v", "--verbose", action="store_true")
    a.add_argument("text", nargs="+")
    r = sub.add_parser("agent", help="run one SDK agent (roster starts this in its tmux session)")
    r.add_argument("session_id")
    args = p.parse_args()
    if args.cmd == "agent":
        from .runner import main as run_agent
        return run_agent(args.session_id) or 0
    try:
        cfg = config_mod.load(args.config)
    except config_mod.ConfigError as exc:
        print("roster-brain: %s" % exc, file=sys.stderr)
        return 1
    return {"serve": cmd_serve, "check": cmd_check, "ask": cmd_ask}[args.cmd](cfg, args) or 0


if __name__ == "__main__":
    sys.exit(main())
