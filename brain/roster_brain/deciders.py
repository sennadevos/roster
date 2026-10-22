"""Decision models: asked before any LLM, they answer, run a fast tool, pick a
model, or pass. The contract is in docs/brain.md, "Decisions"."""

import asyncio
import json
import time

import aiohttp

from .providers.base import ProviderError

PROMPT = """You are the router in front of a personal assistant. Decide how the user's latest message is handled. Reply with ONE JSON object and nothing else.

Options:
- {"decision": "answer", "text": "<short answer>", "confidence": <0..1>}: only when the message is a question you can answer correctly in a few words (yes/no or one fact) from the message and the recent conversation alone.
- {"decision": "tool", "tool": "<name>", "args": {}, "confidence": <0..1>}: only when the message plainly asks for exactly one of the tools below and nothing more.
- {"decision": "route", "model": "<model id>", "confidence": <0..1>}: pick the best model below for anything else.
- {"decision": "pass"}: when unsure.

Confidence is how sure you are that the user would accept this without a second thought. Never guess facts about the user's machines, files or projects you cannot see. If the message refers to earlier messages, to "this conversation", to what was said or done before, or to anything not shown to you here, do not answer it: route it or pass.

Tools:
%(tools)s

Models:
%(models)s

%(mode)s

Recent conversation:
%(history)s"""

CHAT_MODE = "This is a chat; any of the options above may be used."
AGENT_MODE = ("This conversation is with a coding agent working in a folder on the user's machine. Do not route. "
              "Answer yourself only general questions whose answer does not depend on the agent's files, its work, "
              "or the state of anything you cannot see; run a tool only when plainly asked. Otherwise pass.")


def catalog_text(items):
    return "\n".join("- %s: %s" % kv for kv in items) or "(none)"


def history_text(messages):
    lines = ["%s: %s" % (m["role"], m["content"][:500]) for m in messages]
    return "\n".join(lines) or "(none)"


def parse(text):
    text = (text or "").strip()
    if text.startswith("```"):
        text = text.strip("`")
        text = text[text.find("{"):]
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end < start:
        return None
    try:
        got = json.loads(text[start:end + 1])
    except ValueError:
        return None
    return got if isinstance(got, dict) else None


class Decider:
    def __init__(self, spec):
        self.name = spec["name"]
        self.timeout = spec.get("timeout_ms", 1500) / 1000
        self.min_confidence = spec.get("min_confidence", 0.9)
        self.spec = spec

    async def ask(self, text, history, tools, models, agent=False):
        raise NotImplementedError


class OpenRouterDecider(Decider):
    def __init__(self, spec, openrouter):
        super().__init__(spec)
        self.openrouter = openrouter

    async def ask(self, text, history, tools, models, agent=False):
        system = PROMPT % {"tools": catalog_text(tools), "models": catalog_text([] if agent else models),
                           "history": history_text(history), "mode": AGENT_MODE if agent else CHAT_MODE}
        out = await self.openrouter.complete(
            self.spec["model"], [{"role": "system", "content": system}, {"role": "user", "content": text}],
            self.timeout, temperature=0, max_tokens=200, response_format={"type": "json_object"})
        return parse(out)


class HttpDecider(Decider):
    """POSTs {"text", "history", "tools", "models"} and takes a decision back.
    A stand-in contract until Jev's own interface is known."""

    def __init__(self, spec, session):
        super().__init__(spec)
        self.session = session

    async def ask(self, text, history, tools, models, agent=False):
        body = {"text": text, "kind": "agent" if agent else "chat",
                "history": [{"role": m["role"], "content": m["content"]} for m in history],
                "tools": [{"name": n, "description": d} for n, d in tools],
                "models": [{"id": i, "description": d} for i, d in models]}
        headers = {}
        if self.spec.get("token_file"):
            from .config import read_secret
            headers["Authorization"] = "Bearer %s" % read_secret(self.spec["token_file"])
        try:
            async with self.session.post(self.spec["url"], json=body, headers=headers,
                                         timeout=aiohttp.ClientTimeout(total=self.timeout)) as r:
                if r.status != 200:
                    raise ProviderError("%s: HTTP %s" % (self.name, r.status), "server")
                return await r.json(content_type=None)
        except aiohttp.ClientError as exc:
            raise ProviderError("%s: %s" % (self.name, exc), "server")


def build(cfg, session, openrouter):
    out = []
    for spec in cfg["deciders"]:
        if spec.get("enabled", True) is False:
            continue
        out.append(OpenRouterDecider(spec, openrouter) if spec["kind"] == "openrouter"
                   else HttpDecider(spec, session))
    return out


def valid(decider, got, tools, models, allow_route):
    """The decision if it is usable, else None (a pass)."""
    if not got or got.get("decision") not in ("answer", "tool", "route"):
        return None
    try:
        conf = float(got.get("confidence", 0))
    except (TypeError, ValueError):
        conf = 0.0
    kind = got["decision"]
    if kind == "answer":
        if conf < decider.min_confidence or not str(got.get("text", "")).strip():
            return None
    elif kind == "tool":
        if conf < decider.min_confidence or got.get("tool") not in tools:
            return None
        if not isinstance(got.get("args", {}), dict):
            return None
    elif kind == "route":
        if not allow_route or got.get("model") not in models:
            return None
    got["confidence"] = conf
    return got


async def decide(deciders, strategy, text, history, tools, models, allow_route=True, log=None):
    """Returns (decision, decider name, ms) or (None, None, ms)."""
    start = time.monotonic()
    tool_items = [(n, t.get("description", n)) for n, t in tools.items()]
    model_items = list(models.items())

    async def one(d):
        try:
            got = await asyncio.wait_for(d.ask(text, history, tool_items, model_items, not allow_route),
                                         d.timeout)
        except asyncio.TimeoutError:
            log and log("decider %s: timeout" % d.name)
            return None
        except ProviderError as exc:
            log and log("decider %s: %s" % (d.name, exc))
            return None
        return valid(d, got, tools, models, allow_route)

    if strategy == "race" and len(deciders) > 1:
        tasks = {asyncio.ensure_future(one(d)): d for d in deciders}
        try:
            for fut in asyncio.as_completed(list(tasks)):
                got = await fut
                if got:
                    # as_completed yields new futures; find which decider by result identity.
                    for t, d in tasks.items():
                        if t.done() and not t.cancelled() and t.result() is got:
                            return got, d.name, ms(start)
        finally:
            for t in tasks:
                t.cancel()
        return None, None, ms(start)
    for d in deciders:
        got = await one(d)
        if got:
            return got, d.name, ms(start)
    return None, None, ms(start)


def ms(start):
    return int((time.monotonic() - start) * 1000)
