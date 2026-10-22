"""Claude provider: the Claude Agent SDK on the machine's own /login (subscription).

Never an API key. The child process gets a scrubbed environment and a session whose
init message reports apiKeySource other than "none" is refused. Tested against
claude-agent-sdk==0.2.172.

Why a worker task per session: ClaudeSDKClient owns an anyio task group, which must be
entered and left from the same task. The brain calls turn() and close() from different
HTTP handler tasks, so each session runs its client inside one task of its own and the
callers talk to it through queues.

Events are the dicts of base.py. Tool events carry an extra "id" (Claude's tool_use id):
one event when the call starts ({"name", "input"}) and one when it finishes with
"result" or "error", so a frontend can merge them."""

import asyncio
import os
import time

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    ClaudeSDKError,
    CLIConnectionError,
    CLINotFoundError,
    PermissionResultDeny,
    ProcessError,
    RateLimitEvent,
    ResultMessage,
    StreamEvent,
    SystemMessage,
    TextBlock,
    ToolResultBlock,
    ToolUseBlock,
    UserMessage,
)

from .base import AgentSession, ChatProvider, ProviderError

_SCRUB_EXACT = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDECODE")
_SCRUB_PREFIX = ("CLAUDE_CODE_",)
_env_lock = asyncio.Lock()
_END = object()
_RESULT_CAP = 50_000

_ASSISTANT_ERROR_KIND = {
    "rate_limit": "rate_limit",
    "authentication_failed": "auth",
    "billing_error": "auth",
    "invalid_request": "invalid",
    "model_not_found": "invalid",
    "server_error": "server",
}


def _kind_from_status(status):
    if status == 429:
        return "rate_limit"
    if status in (401, 403):
        return "auth"
    if status in (400, 404, 413, 422):
        return "invalid"
    if isinstance(status, int) and status >= 500:
        return "server"
    return None


def _kind_from_text(text):
    t = (text or "").lower()
    if "rate limit" in t or "usage limit" in t or "limit reached" in t:
        return "rate_limit"
    if "log in" in t or "login" in t or "authenticat" in t or "api key" in t:
        return "auth"
    if "no conversation found" in t:
        return "invalid"
    if "overloaded" in t or "internal server" in t:
        return "server"
    return None


def _provider_error(exc):
    """Map an SDK exception to ProviderError."""
    if isinstance(exc, ProviderError):
        return exc
    text = str(exc)
    if isinstance(exc, (CLINotFoundError, CLIConnectionError)):
        return ProviderError(text, kind=None)
    return ProviderError(text, kind=_kind_from_text(text))


class _scrubbed_env:
    """Remove the dangerous variables from os.environ while the child is spawned.
    ClaudeAgentOptions.env can only add or override, never unset, and the SDK merges
    it over os.environ; so the spawn happens under this lock with them popped."""

    async def __aenter__(self):
        await _env_lock.acquire()
        self._saved = {
            k: v
            for k, v in os.environ.items()
            if k in _SCRUB_EXACT or k.startswith(_SCRUB_PREFIX)
        }
        for k in self._saved:
            del os.environ[k]

    async def __aexit__(self, *exc):
        os.environ.update(self._saved)
        _env_lock.release()


def _flatten_result(content):
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        text = "\n".join(
            b.get("text", "") if isinstance(b, dict) else str(b) for b in content
        )
    else:
        text = "" if content is None else str(content)
    if len(text) > _RESULT_CAP:
        text = text[:_RESULT_CAP] + "\n[truncated]"
    return text


class _Session:
    """One Claude CLI process driven from one worker task; any number of turns."""

    def __init__(self, options):
        self._options = options
        self._inbox = asyncio.Queue()
        self._task = None
        self._client = None
        self._lock = asyncio.Lock()
        self._turn_active = False
        self._interrupted = False
        self.session_id = options.resume
        self.model = None

    # -- worker ------------------------------------------------------------

    async def _worker(self):
        client = ClaudeSDKClient(self._options)
        self._client = client
        out = None
        try:
            async with _scrubbed_env():
                await client.connect()
            while True:
                cmd = await self._inbox.get()
                if cmd is None:
                    break
                text, out = cmd
                await client.query(text)
                await self._pump(client, out)
                out.put_nowait(_END)
                out = None
        except BaseException as exc:  # noqa: BLE001 - reported to the caller, then re-raised if cancel
            err = _provider_error(exc) if isinstance(exc, Exception) else None
            if out is not None:
                out.put_nowait(err or ProviderError("session cancelled"))
            # fail turns that were queued behind this one
            while not self._inbox.empty():
                cmd = self._inbox.get_nowait()
                if cmd is not None:
                    cmd[1].put_nowait(err or ProviderError("session cancelled"))
            if not isinstance(exc, Exception):
                raise
        finally:
            self._client = None
            self._task = None
            try:
                await client.disconnect()
            except Exception:  # noqa: BLE001
                pass

    async def _pump(self, client, out):
        t0 = time.monotonic()
        got_delta = False
        sep = False
        tools = {}  # tool_use_id -> (name, input)
        async for m in client.receive_response():
            if isinstance(m, SystemMessage):
                if m.subtype == "init":
                    src = m.data.get("apiKeySource")
                    if src != "none":
                        try:
                            await client.interrupt()
                        except Exception:  # noqa: BLE001
                            pass
                        raise ProviderError(
                            f"refusing session: apiKeySource is {src!r}, expected 'none' "
                            "(subscription login)",
                            kind="auth",
                        )
                    self.session_id = m.data.get("session_id") or self.session_id
                    self.model = m.data.get("model") or self.model
            elif isinstance(m, StreamEvent):
                if getattr(m, "parent_tool_use_id", None):
                    continue
                ev = m.event
                if ev.get("type") == "content_block_start":
                    # A new text block after earlier text (e.g. around a tool call)
                    # starts a new paragraph instead of running on.
                    sep = got_delta
                elif ev.get("type") == "content_block_delta":
                    d = ev.get("delta", {})
                    if d.get("type") == "text_delta" and d.get("text"):
                        got_delta = True
                        out.put_nowait({"type": "delta", "text": ("\n\n" if sep else "") + d["text"]})
                        sep = False
            elif isinstance(m, AssistantMessage):
                self.model = m.model or self.model
                if m.error:
                    msg = "".join(b.text for b in m.content if isinstance(b, TextBlock)) or m.error
                    raise ProviderError(
                        msg, kind=_ASSISTANT_ERROR_KIND.get(m.error) or _kind_from_text(msg)
                    )
                if m.parent_tool_use_id:
                    continue
                for b in m.content:
                    if isinstance(b, TextBlock) and not got_delta and b.text:
                        out.put_nowait({"type": "delta", "text": b.text})
                    elif isinstance(b, ToolUseBlock):
                        tools[b.id] = (b.name, b.input)
                        out.put_nowait(
                            {"type": "tool", "id": b.id, "name": b.name, "input": b.input}
                        )
            elif isinstance(m, UserMessage):
                if m.parent_tool_use_id or not isinstance(m.content, list):
                    continue
                for b in m.content:
                    if isinstance(b, ToolResultBlock):
                        name, inp = tools.get(b.tool_use_id, (None, None))
                        ev = {"type": "tool", "id": b.tool_use_id, "name": name, "input": inp}
                        if b.is_error:
                            ev["error"] = _flatten_result(b.content)
                        else:
                            ev["result"] = _flatten_result(b.content)
                        out.put_nowait(ev)
            elif isinstance(m, RateLimitEvent):
                if m.rate_limit_info.status == "rejected":
                    raise ProviderError(
                        "subscription rate limit reached "
                        f"({m.rate_limit_info.rate_limit_type}, resets at "
                        f"{m.rate_limit_info.resets_at})",
                        kind="rate_limit",
                    )
            elif isinstance(m, ResultMessage):
                if m.session_id:
                    self.session_id = m.session_id
                aborted = (m.terminal_reason or "").startswith("aborted")
                if m.is_error and not (self._interrupted and aborted):
                    msg = m.result or "; ".join(m.errors or []) or m.subtype
                    kind = _kind_from_status(m.api_error_status) or _kind_from_text(msg)
                    if m.subtype.startswith("error_") and kind is None:
                        kind = "invalid"
                    raise ProviderError(msg, kind=kind)
                u = m.usage or {}
                usage = {
                    "input_tokens": u.get("input_tokens", 0),
                    "output_tokens": u.get("output_tokens", 0),
                    "cache_read_input_tokens": u.get("cache_read_input_tokens", 0),
                    "cache_creation_input_tokens": u.get("cache_creation_input_tokens", 0),
                    "cost_usd": m.total_cost_usd,  # list-price figure, not a charge
                }
                done = {
                    "type": "done",
                    "model": self.model,
                    "ms": int((time.monotonic() - t0) * 1000),
                    "usage": usage,
                }
                if self._interrupted:
                    done["interrupted"] = True
                out.put_nowait(done)

    # -- caller side ---------------------------------------------------------

    async def turn(self, text):
        async with self._lock:
            if self._task is None:
                self._task = asyncio.create_task(self._worker())
            self._interrupted = False
            out = asyncio.Queue()
            self._inbox.put_nowait((text, out))
            self._turn_active = True
            finished = False
            try:
                while True:
                    item = await out.get()
                    if item is _END:
                        finished = True
                        break
                    if isinstance(item, Exception):
                        finished = True
                        raise item
                    yield item
            finally:
                if not finished:
                    # consumer went away mid-turn: stop it so the next turn starts clean
                    await self.interrupt()
                    while True:
                        item = await out.get()
                        if item is _END or isinstance(item, Exception):
                            break
                self._turn_active = False

    async def interrupt(self):
        client = self._client
        if client is None or not self._turn_active:
            return
        self._interrupted = True
        await client.interrupt()

    async def close(self):
        task = self._task
        if task is None:
            return
        self._inbox.put_nowait(None)
        try:
            await asyncio.wait_for(asyncio.shield(task), timeout=10)
        except (asyncio.TimeoutError, Exception):  # noqa: BLE001
            task.cancel()
            try:
                await task
            except BaseException:  # noqa: BLE001
                pass


def _history_prompt(messages):
    if len(messages) == 1:
        return messages[0]["content"]
    parts = ["<conversation>"]
    for m in messages:
        parts.append(f"[{m['role']}]\n{m['content']}")
    parts.append("</conversation>")
    parts.append("Reply as the assistant to the last user message above. Answer directly; "
                 "do not mention this transcript format.")
    return "\n\n".join(parts)


async def _deny_all(tool, inp, ctx):
    return PermissionResultDeny(message="No tools are available in this chat.")


class ClaudeChat(ChatProvider):
    """One-shot answers from the brain's history; no tools, no settings, no hooks."""

    async def stream(self, model, messages, system=None):
        options = ClaudeAgentOptions(
            model=model or None,
            system_prompt=system or "",
            tools=[],
            allowed_tools=[],
            can_use_tool=_deny_all,
            permission_mode="dontAsk",
            setting_sources=[],
            include_partial_messages=True,
            max_turns=1,
            effort="low" if model and "haiku" in model else None,
        )
        session = _Session(options)
        try:
            async for ev in session.turn(_history_prompt(messages)):
                yield ev
        finally:
            await session.close()


class ClaudeAgent(AgentSession):
    """A live agent session in a working folder, kept across turns."""

    def __init__(self, cwd, model, system=None, resume=None, permission_mode="auto"):
        self.session_id = resume
        options = ClaudeAgentOptions(
            cwd=cwd,
            model=model or None,
            system_prompt=(
                {"type": "preset", "preset": "claude_code", "append": system}
                if system
                else {"type": "preset", "preset": "claude_code"}
            ),
            permission_mode=permission_mode,
            setting_sources=["user", "project", "local"],
            include_partial_messages=True,
            resume=resume,
        )
        self._session = _Session(options)

    async def turn(self, text):
        try:
            async for ev in self._session.turn(text):
                self.session_id = self._session.session_id or self.session_id
                yield ev
        finally:
            self.session_id = self._session.session_id or self.session_id
            # a dead process must resume from the id next time, not from the old one
            self._session._options.resume = self.session_id

    async def interrupt(self):
        await self._session.interrupt()

    async def close(self):
        await self._session.close()
