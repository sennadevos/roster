"""The router and conversation engine. A turn runs as its own task and feeds a
queue, so a frontend that drops the stream does not stop it."""

import asyncio
import os
import time

import aiohttp

from . import config as config_mod
from . import deciders as deciders_mod
from .providers.base import ProviderError
from .providers.openrouter import OpenRouter
from .store import Store

HISTORY_FOR_DECIDERS = 6
END = object()


class Busy(Exception):
    pass


class Brain:
    def __init__(self, cfg, log=print):
        self.cfg = cfg
        self.log = log
        self.store = Store(os.path.join(config_mod.STATE_DIR, "brain.db"))
        self.agents = {}
        self.turns = {}
        self.subscribers = set()
        self.session = None
        self._partial = {}

    async def start(self):
        self.session = aiohttp.ClientSession()
        key = config_mod.read_secret(self.cfg["openrouter_key_file"])
        self.openrouter = OpenRouter(self.session, key)
        self.deciders = deciders_mod.build(self.cfg, self.session, self.openrouter)
        self._claude_chat = None

    async def stop(self):
        for t in list(self.turns.values()):
            t.cancel()
        for a in list(self.agents.values()):
            try:
                await a.close()
            except Exception as exc:  # closing must never keep the service up
                self.log("closing agent: %s" % exc)
        await self.session.close()

    # -- catalog -------------------------------------------------------------

    def catalog(self):
        return {"models": [{"id": i, "description": d} for i, d in self.cfg["models"].items()],
                "default_model": self.cfg["default_model"],
                "agent_model": self.cfg["agent_model"],
                "deciders": [{"name": d.name, "kind": d.spec["kind"], "timeout_ms": int(d.timeout * 1000),
                              "min_confidence": d.min_confidence} for d in self.deciders],
                "strategy": self.cfg["strategy"],
                "tools": [{"name": n, "description": t.get("description", n)}
                          for n, t in self.cfg["tools"].items()]}

    # -- events --------------------------------------------------------------

    def publish(self, event, data):
        for q in list(self.subscribers):
            q.put_nowait((event, data))

    # -- conversations -------------------------------------------------------

    def create(self, kind, title=None, model=None, system=None, cwd=None):
        if kind not in ("chat", "agent"):
            raise ValueError("kind must be chat or agent")
        if kind == "agent":
            model = model or self.cfg["agent_model"]
            if not model.startswith("claude:"):
                raise ValueError("an agent runs on a claude: model")
            cwd = os.path.expanduser(cwd or "~")
            if not os.path.isdir(cwd):
                raise ValueError("no such folder: %s" % cwd)
        else:
            model = model or self.cfg["default_model"]
            cwd = None
        config_mod.split_model(model)
        conv = self.store.create_conversation(kind, model, title, system, cwd)
        self.publish("conversation", conv)
        return conv

    async def delete(self, cid):
        t = self.turns.pop(cid, None)
        if t:
            t.cancel()
        agent = self.agents.pop(cid, None)
        if agent:
            await agent.close()
        self.store.delete_conversation(cid)
        self.publish("conversation", {"id": cid, "deleted": True})

    async def interrupt(self, cid):
        conv = self.store.conversation(cid)
        if not conv:
            raise KeyError(cid)
        if cid not in self.turns:
            return False
        agent = self.agents.get(cid)
        if agent:
            await agent.interrupt()
        else:
            self.turns[cid].cancel()
        return True

    # -- turns ---------------------------------------------------------------

    def turn(self, cid, text, route=None):
        """Starts a turn; returns an async iterator of (event, data)."""
        conv = self.store.conversation(cid)
        if not conv:
            raise KeyError(cid)
        if cid in self.turns:
            raise Busy("a turn is already running in this conversation")
        q = asyncio.Queue()

        def emit(event, data):
            q.put_nowait((event, data))
            if event in ("start", "done", "error"):
                self.publish("message", dict(data, conversation=cid, event=event))

        task = asyncio.ensure_future(self._turn(conv, text, route, emit))
        self.turns[cid] = task
        task.add_done_callback(lambda _t: (self.turns.pop(cid, None), q.put_nowait(END)))

        async def events():
            while True:
                item = await q.get()
                if item is END:
                    return
                yield item
        return events()

    async def _turn(self, conv, text, route, emit):
        cid = conv["id"]
        start = time.monotonic()
        history = self.store.messages(cid)
        mid = self.store.add_message(cid, "user", text)
        emit("start", {"conversation": cid, "message": mid})
        answer_id = None
        try:
            decision, by, dms = await self._route(conv, text, route, history)
            if decision["decision"] == "answer":
                emit("route", {"by": by, "decision": "answer", "ms": dms})
                answer_id = self.store.add_message(cid, "assistant", decision["text"], model=None,
                                                   route="decider:" + by)
                emit("delta", {"text": decision["text"]})
                emit("done", {"message": answer_id, "model": "decider:" + by, "ms": ms(start)})
            elif decision["decision"] == "tool":
                emit("route", {"by": by, "decision": "tool", "tool": decision["tool"], "ms": dms})
                answer_id = await self._fast_tool(cid, decision, by, emit, start)
            else:
                model = decision["model"]
                emit("route", {"by": by, "decision": "route", "model": model, "ms": dms})
                answer_id = self.store.add_message(cid, "assistant", "", state="streaming",
                                                   model=model, route=by)
                await self._generate(conv, text, model, history, answer_id, emit, start)
        except asyncio.CancelledError:
            if answer_id:
                self.store.finish_message(answer_id, self._partial.get(answer_id, ""), state="interrupted")
            emit("error", {"error": "interrupted", "kind": "interrupted"})
            raise
        except ProviderError as exc:
            if answer_id:
                self.store.finish_message(answer_id, self._partial.get(answer_id, ""), state="error",
                                          meta={"error": str(exc), "kind": exc.kind})
            emit("error", {"error": str(exc), "kind": exc.kind})
        except Exception as exc:
            self.log("turn in %s failed: %r" % (cid, exc))
            if answer_id:
                self.store.finish_message(answer_id, self._partial.get(answer_id, ""), state="error",
                                          meta={"error": repr(exc)})
            emit("error", {"error": "internal: %s" % exc})
        finally:
            self._partial.pop(answer_id, None)

    async def _route(self, conv, text, route, history):
        """Returns (decision, by, ms); always a decision, falling back to the default."""
        if route and route.startswith("model:"):
            model = route[6:]
            config_mod.split_model(model)
            if conv["kind"] == "agent":
                raise ProviderError("an agent conversation stays on its own model", "invalid")
            return {"decision": "route", "model": model}, "forced", 0
        if route != "direct" and self.deciders:
            got, by, dms = await deciders_mod.decide(
                # In an agent conversation the history is the agent's world, which a
                # decider cannot see; without it, it has to pass on anything about it.
                self.deciders, self.cfg["strategy"], text,
                history[-HISTORY_FOR_DECIDERS:] if conv["kind"] == "chat" else [],
                self.cfg["tools"], self.cfg["models"], allow_route=conv["kind"] == "chat", log=self.log)
            if got:
                return got, by, dms
            return {"decision": "route", "model": conv["model"]}, "default", dms
        return {"decision": "route", "model": conv["model"]}, "default" if route != "direct" else "forced", 0

    async def _fast_tool(self, cid, decision, by, emit, start):
        name = decision["tool"]
        spec = self.cfg["tools"][name]
        args = decision.get("args") or {}
        try:
            cmd = [c.format(**args) for c in spec["command"]]
        except (KeyError, IndexError, ValueError) as exc:
            raise ProviderError("tool %s: missing argument %s" % (name, exc), "invalid")
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT)
            out, _ = await asyncio.wait_for(proc.communicate(), spec.get("timeout_s", 10))
            ok, output = proc.returncode == 0, out.decode("utf-8", "replace").strip()[-2000:]
        except asyncio.TimeoutError:
            proc.kill()
            ok, output = False, "timed out"
        except OSError as exc:
            ok, output = False, str(exc)
        emit("tool", {"name": name, "input": args, "result": output, "error": not ok})
        text = ("Done: %s" % spec.get("description", name)) if ok else ("%s failed: %s" % (name, output))
        if ok and output and spec.get("show_output", True):
            text += "\n" + output
        mid = self.store.add_message(cid, "assistant", text, route="decider:" + by,
                                     meta={"tool": name, "args": args, "ok": ok})
        emit("delta", {"text": text})
        emit("done", {"message": mid, "model": "tool:" + name, "ms": ms(start)})
        return mid

    async def _generate(self, conv, text, model, history, answer_id, emit, start):
        provider, name = config_mod.split_model(model)
        parts = []
        self._partial[answer_id] = ""
        if conv["kind"] == "agent":
            agent = await self._agent(conv)
            events = agent.turn(self._with_missed(conv, text, history))
        else:
            msgs = [{"role": m["role"], "content": m["content"]} for m in history
                    if m["role"] in ("user", "assistant") and m["content"]]
            msgs.append({"role": "user", "content": text})
            chat = self.openrouter if provider == "openrouter" else self._claude()
            events = chat.stream(name, msgs, conv["system"])
        done = {}
        async for ev in events:
            kind = ev.get("type")
            if kind == "delta":
                parts.append(ev["text"])
                self._partial[answer_id] = "".join(parts)
                emit("delta", {"text": ev["text"]})
            elif kind == "tool":
                emit("tool", {k: v for k, v in ev.items() if k != "type"})
            elif kind == "done":
                done = ev
            elif kind == "error":
                raise ProviderError(ev.get("error", "error"), ev.get("kind"))
        if conv["kind"] == "agent":
            sid = self.agents[conv["id"]].session_id
            if sid and sid != conv["claude_session"]:
                self.store.update_conversation(conv["id"], claude_session=sid)
        meta = {k: done[k] for k in ("usage", "interrupted") if done.get(k)}
        state = "interrupted" if done.get("interrupted") else "done"
        self.store.finish_message(answer_id, "".join(parts), state=state, model=done.get("model") or model,
                                  meta=meta or None)
        emit("done", dict({"message": answer_id, "model": done.get("model") or model, "ms": ms(start)}, **meta))

    def _claude(self):
        if not self._claude_chat:
            from .providers.claude import ClaudeChat
            self._claude_chat = ClaudeChat()
        return self._claude_chat

    async def _agent(self, conv):
        agent = self.agents.get(conv["id"])
        if not agent:
            from .providers.claude import ClaudeAgent
            agent = ClaudeAgent(conv["cwd"], config_mod.split_model(conv["model"])[1], system=conv["system"],
                                resume=conv["claude_session"])
            self.agents[conv["id"]] = agent
        return agent

    def _with_missed(self, conv, text, history):
        """Turns the router answered since Claude last spoke, put in front of the prompt."""
        missed = []
        for m in reversed(history):
            if m["role"] == "assistant" and not (m["route"] or "").startswith("decider:"):
                break
            missed.append(m)
        missed.reverse()
        pairs = [m for m in missed if m["content"]]
        if not any(m["role"] == "assistant" for m in pairs):
            return text
        lines = ["%s: %s" % ("User" if m["role"] == "user" else "Answered without you", m["content"])
                 for m in pairs]
        return ("[From roster-brain, the service that runs this conversation: since your last answer the user "
                "also sent the messages below, which its fast router answered instead of you. They are real and "
                "part of this conversation; they are only missing from your own transcript.]\n"
                + "\n".join(lines) + "\n[End of the router's turns. The user's new message follows.]\n\n" + text)


def ms(start):
    return int((time.monotonic() - start) * 1000)
