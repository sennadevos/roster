"""Scores a decision model on routing cases, live over OpenRouter (costs a few
cents). From brain/: PYTHONPATH=. .venv/bin/python tests/decider_eval.py <openrouter model id, or jev>"""
import asyncio, sys, time, aiohttp
from roster_brain import config, deciders
from roster_brain.providers.openrouter import OpenRouter
CASES = [  # (text, agent, wanted kinds)
    ("Is 17 a prime number?", False, {"answer"}),
    ("what's the date", False, {"tool"}),
    ("Write a 300-word essay on tmux", False, {"route", "pass"}),
    ("List every question I asked you in this conversation", True, {"pass"}),
    ("What is in notes.txt?", True, {"pass"}),
    ("Is the sky blue on a clear day?", True, {"answer"}),
    ("Did the build pass?", True, {"pass"}),
    ("Is Python's list.sort stable?", False, {"answer"}),
    ("refactor the parser to use a state machine", True, {"pass"}),
    ("show me the roster agents", False, {"tool"}),
    ("Is the Eiffel Tower in Berlin?", False, {"answer"}),
    ("Did I already push the fix?", True, {"pass"}),
    ("Is water wet? Explain in detail with three arguments.", False, {"route", "pass"}),
]
async def main(model):
    async with aiohttp.ClientSession() as s:
        orr = OpenRouter(s, config.read_secret(config.DEFAULTS["openrouter_key_file"]))
        if model == "jev" or "typesafe/jev" in model:
            d = deciders.JevDecider({"name": "x", "kind": "jev", "timeout_ms": 8000,
                                     **({} if model == "jev" else {"model": model})}, orr)
        else:
            d = deciders.OpenRouterDecider({"name": "x", "kind": "openrouter", "model": model, "timeout_ms": 8000}, orr)
        tools = {"date": {"description": "Show the current date and time"},
                 "agents": {"description": "List the agents on the roster and what they are doing"}}
        models = {"openrouter:google/gemini-3.8-flash": "fast general", "claude:sonnet": "Claude, writing and code"}
        ok = 0
        for text, agent, want in CASES:
            t = time.monotonic()
            got, by, ms = await deciders.decide([d], "first", text, [], tools, models, allow_route=not agent)
            kind = got["decision"] if got else "pass"
            ok += kind in want
            print("%-5s %5dms %-6s %s" % ("ok" if kind in want else "BAD", ms, kind, text))
        print(model, "%d/%d" % (ok, len(CASES)))
asyncio.run(main(sys.argv[1]))
