"""Router, store and API tests that need no network and no Claude: deciders are
a local HTTP stub, models a stub provider. Run from brain/:
    PYTHONPATH=. .venv/bin/python -m unittest tests.test_brain"""

import asyncio
import json
import os
import tempfile
import unittest

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

STATE = tempfile.mkdtemp()
os.environ["XDG_STATE_HOME"] = STATE

from roster_brain import config as config_mod  # noqa: E402
from roster_brain import deciders  # noqa: E402
from roster_brain.server import BRAIN, make_app  # noqa: E402


class StubChat:
    """Echoes the last message, in two deltas."""

    def __init__(self):
        self.calls = []

    async def stream(self, model, messages, system=None):
        self.calls.append((model, messages, system))
        yield {"type": "delta", "text": "echo: "}
        await asyncio.sleep(0)
        yield {"type": "delta", "text": messages[-1]["content"]}
        yield {"type": "done", "model": "openrouter:" + model}


def sse(text):
    out, event = [], None
    for line in text.splitlines():
        if line.startswith("event: "):
            event = line[7:]
        elif line.startswith("data: "):
            out.append((event, json.loads(line[6:])))
    return out


class ParseTest(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(deciders.parse('```json\n{"decision": "pass"}\n```'), {"decision": "pass"})
        self.assertEqual(deciders.parse('sure: {"decision": "answer", "text": "Yes"}'),
                         {"decision": "answer", "text": "Yes"})
        self.assertIsNone(deciders.parse("no json here"))

    def test_valid(self):
        d = deciders.Decider({"name": "x"})
        tools, models = {"lock": {}}, {"openrouter:a": "A"}
        self.assertIsNone(deciders.valid(d, {"decision": "answer", "text": "Yes", "confidence": 0.5}, tools, models, True))
        self.assertTrue(deciders.valid(d, {"decision": "answer", "text": "Yes", "confidence": 0.95}, tools, models, True))
        self.assertIsNone(deciders.valid(d, {"decision": "tool", "tool": "nope", "confidence": 1}, tools, models, True))
        self.assertIsNone(deciders.valid(d, {"decision": "route", "model": "openrouter:a"}, tools, models, False))
        self.assertIsNone(deciders.valid(d, {"decision": "route", "model": "openrouter:b"}, tools, models, True))


class JevReadTest(unittest.TestCase):
    def setUp(self):
        self.jev = deciders.JevDecider({"name": "jev", "kind": "jev"}, None)

    def test_tool_wins_on_its_own_question(self):
        got = self.jev.read({"kind": {"choice": "task", "confidence": 0.5},
                             "tool": {"choice": "date", "confidence": 0.83}})
        self.assertEqual((got["decision"], got["tool"]), ("tool", "date"))

    def test_yes_no(self):
        a = {"kind": {"choice": "yes_no", "confidence": 1}, "hidden": {"noul": 0.1}, "tool": {"choice": "none"}}
        self.assertEqual(self.jev.read(dict(a, yes={"noul": 0.97}))["text"], "Yes.")
        self.assertEqual(self.jev.read(dict(a, yes={"noul": 0.02}))["text"], "No.")
        self.assertIsNone(self.jev.read(dict(a, yes={"noul": 0.6})))
        self.assertIsNone(self.jev.read(dict(a, yes={"noul": 0.99}, hidden={"noul": 0.8})))

    def test_route(self):
        got = self.jev.read({"kind": {"choice": "task"}, "model": {"choice": "claude:sonnet", "confidence": 0.7}})
        self.assertEqual(got["model"], "claude:sonnet")


class ApiTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.decision = {"decision": "pass"}

        async def decide(request):
            self.seen = await request.json()
            return web.json_response(self.decision)

        stub = web.Application()
        stub.router.add_post("/decide", decide)
        self.stub = TestServer(stub)
        await self.stub.start_server()
        cfg = dict(config_mod.DEFAULTS, path="test",
                   default_model="openrouter:stub", models={"openrouter:stub": "stub", "openrouter:other": "other"},
                   deciders=[{"name": "jev", "kind": "http", "url": str(self.stub.make_url("/decide")),
                              "timeout_ms": 2000}],
                   tools={"hello": {"description": "Say hello", "command": ["echo", "hello {who}"]}})
        config_mod.check(cfg)
        self.app = make_app(cfg, log=lambda m: None)
        self.client = TestClient(TestServer(self.app))
        await self.client.start_server()
        self.chat = StubChat()
        self.app[BRAIN].openrouter = self.chat

    async def asyncTearDown(self):
        await self.client.close()
        await self.stub.close()

    async def turn(self, cid, text, **extra):
        r = await self.client.post("/v1/conversations/%s/messages" % cid, json=dict(extra, text=text))
        self.assertEqual(r.status, 200, await r.text())
        return sse(await r.text())

    async def new_chat(self):
        r = await self.client.post("/v1/conversations", json={"kind": "chat"})
        self.assertEqual(r.status, 201)
        return (await r.json())["id"]

    async def test_answer_by_decider(self):
        cid = await self.new_chat()
        self.decision = {"decision": "answer", "text": "Yes.", "confidence": 0.99}
        ev = await self.turn(cid, "is it on?")
        kinds = [e for e, _ in ev]
        self.assertEqual(kinds, ["start", "route", "delta", "done"])
        self.assertEqual(ev[1][1]["by"], "jev")
        self.assertEqual(self.chat.calls, [])
        conv = await (await self.client.get("/v1/conversations/" + cid)).json()
        self.assertEqual([m["content"] for m in conv["messages"]], ["is it on?", "Yes."])
        self.assertEqual(conv["messages"][1]["route"], "decider:jev")

    async def test_tool_by_decider(self):
        cid = await self.new_chat()
        self.decision = {"decision": "tool", "tool": "hello", "args": {"who": "Senna"}, "confidence": 1}
        ev = await self.turn(cid, "say hello")
        tool = [d for e, d in ev if e == "tool"][0]
        self.assertEqual(tool["result"], "hello Senna")
        self.assertFalse(tool["error"])

    async def test_pass_falls_back_and_history(self):
        cid = await self.new_chat()
        await self.turn(cid, "one")
        self.decision = {"decision": "route", "model": "openrouter:other", "confidence": 0.8}
        ev = await self.turn(cid, "two")
        self.assertEqual("".join(d["text"] for e, d in ev if e == "delta"), "echo: two")
        self.assertEqual(self.chat.calls[0][0], "stub")
        model, msgs, _ = self.chat.calls[1]
        self.assertEqual(model, "other")
        self.assertEqual([m["content"] for m in msgs], ["one", "echo: one", "two"])
        self.assertEqual(self.seen["history"][-1]["content"], "echo: one")

    async def test_forced_route_skips_deciders(self):
        cid = await self.new_chat()
        self.decision = {"decision": "answer", "text": "nope", "confidence": 1}
        ev = await self.turn(cid, "hi", route="model:openrouter:other")
        self.assertEqual(ev[1][1]["by"], "forced")
        self.assertEqual(self.chat.calls[-1][0], "other")

    async def test_low_confidence_is_pass(self):
        cid = await self.new_chat()
        self.decision = {"decision": "answer", "text": "maybe", "confidence": 0.3}
        ev = await self.turn(cid, "hm")
        self.assertEqual(ev[1][1]["by"], "default")

    async def test_ask_and_list(self):
        r = await self.client.post("/v1/ask", json={"text": "quick one"})
        ev = sse(await r.text())
        self.assertEqual(ev[-1][0], "done")
        got = await (await self.client.get("/v1/conversations")).json()
        self.assertIn("quick one", [c["title"] for c in got["conversations"]])

    async def test_errors(self):
        r = await self.client.post("/v1/conversations/nope/messages", json={"text": "x"})
        self.assertEqual(r.status, 404)
        r = await self.client.post("/v1/conversations", json={"kind": "agent", "cwd": "/no/such/dir"})
        self.assertEqual(r.status, 400)
        r = await self.client.post("/v1/conversations", json={"kind": "chat", "model": "gpt"})
        self.assertEqual(r.status, 400)


if __name__ == "__main__":
    unittest.main()
