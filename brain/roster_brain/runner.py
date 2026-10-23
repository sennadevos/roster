"""roster-agent: one roster agent on the Claude Agent SDK.

It runs as the command of the agent's roster tmux session, so everything roster
does with tmux agents (list, attach, park, kill, move, resume) works unchanged;
only what happens inside the session differs. Instead of Claude Code's TUI the
session shows this runner's own small terminal UI, and roster drives it through
a Unix socket instead of typing keys into it. See docs/sdk-agents.md.

The socket takes one JSON request per connection and answers with one JSON line:
  {"op": "status"}                       status, model, effort, dialog, queued, input
  {"op": "screen"}                       the last lines shown, and the open dialog
  {"op": "prompt", "text": ...}          a prompt as the user; mid-turn, Claude takes it in at its next step
  {"op": "interrupt"}                    stop the turn in progress
  {"op": "model", "model": ...}          switch model, live
  {"op": "effort", "effort": ...}        switch effort, live
  {"op": "answer", "key": ..., "text"?}  pick an option of the open dialog
  {"op": "keys", "keys": [...]}          the same, in `roster keys` terms

The agent finds its roster entry through its Claude session id
(sessions/<id> holds the roster name), so a rename never loses it.
"""

import asyncio
import collections
import glob
import json
import os
import re
import signal
import sys
import tempfile
import termios
import time

# Subscription only: an API key in the environment would move billing to the
# API. The runner is the agent's own process, so its environment can just lose them.
for _k in list(os.environ):
    if _k in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDECODE") or _k.startswith("CLAUDE_CODE_"):
        del os.environ[_k]

from claude_agent_sdk import (  # noqa: E402
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    PermissionResultAllow,
    PermissionResultDeny,
    RateLimitEvent,
    ResultMessage,
    StreamEvent,
    SystemMessage,
    TextBlock,
    ToolResultBlock,
    ToolUseBlock,
    UserMessage,
)

STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "roster")
AGENTS = os.path.join(STATE, "agents")
SESSIONS = os.path.join(STATE, "sessions")
EFFORTS = ("low", "medium", "high", "xhigh", "max")
REVIVE_MAX = 5
SCREEN_LINES = 60


def socket_path(session_id):
    """Where an agent's control socket lives; roster computes the same path."""
    base = os.environ.get("XDG_RUNTIME_DIR") or os.path.join(tempfile.gettempdir(), "roster-%d" % os.getuid())
    return os.path.join(base, "roster", session_id + ".sock")


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


# --- the roster entry -------------------------------------------------------


def roster_name(session_id):
    try:
        with open(os.path.join(SESSIONS, session_id)) as f:
            return f.read().strip() or None
    except OSError:
        return None


def entry_path(name):
    return os.path.join(AGENTS, name.replace("/", "%"), "agent.json")


def load_entry(session_id):
    name = roster_name(session_id)
    if not name:
        return None
    try:
        with open(entry_path(name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def update_entry(session_id, **fields):
    """Read, change and rewrite the entry in one go, as roster does (temp file, rename)."""
    e = load_entry(session_id)
    if not e or e.get("session_id") != session_id:
        return None
    e.update(fields)
    path = entry_path(e["name"])
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp.")
    with os.fdopen(fd, "w") as f:
        f.write(json.dumps(e, indent=2) + "\n")
    os.replace(tmp, path)
    return e


def unread_mail(name):
    try:
        return bool(os.listdir(os.path.join(AGENTS, name.replace("/", "%"), "inbox", "new")))
    except OSError:
        return False


def transcript_exists(session_id):
    return bool(glob.glob(os.path.expanduser("~/.claude/projects/*/%s.jsonl" % session_id)))


def tool_summary(name, inp):
    inp = inp or {}
    for key in ("command", "file_path", "path", "pattern", "url", "query", "description", "prompt"):
        if isinstance(inp.get(key), str) and inp[key].strip():
            return inp[key].strip().splitlines()[0][:200]
    return json.dumps(inp, ensure_ascii=False)[:200]


def block_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") if isinstance(b, dict) else str(b) for b in content)
    return "" if content is None else str(content)


# --- terminal ---------------------------------------------------------------

DIM, BOLD, RED, CYAN, YELLOW, RESET = "\x1b[2m", "\x1b[1m", "\x1b[31m", "\x1b[36m", "\x1b[33m", "\x1b[0m"


class Terminal:
    """Scrolling output above a status line and an input line, in a plain tty.

    The output area is a scroll region; writes to it go to the saved cursor
    (DECSC/DECRC), so streamed text continues where it left off while the input
    line keeps the real cursor. Without a tty (tests) it only keeps the lines.
    """

    def __init__(self, on_submit, on_key):
        self.on_submit = on_submit
        self.on_key = on_key
        self.lines = collections.deque(maxlen=2000)  # plain text, for `screen` and redraws
        self.styled = collections.deque(maxlen=400)  # what was drawn, for redraws
        self.partial = ""  # the open line, still being streamed
        self.partial_style = ""
        self.buf = ""
        self.status = ""
        self.tty = sys.stdin.isatty() and sys.stdout.isatty()
        self.fd = sys.stdin.fileno() if self.tty else None
        self.saved = None
        self.pending = ""
        self.in_paste = False

    def start(self, loop):
        if not self.tty:
            return
        self.saved = termios.tcgetattr(self.fd)
        mode = termios.tcgetattr(self.fd)
        mode[3] &= ~(termios.ICANON | termios.ECHO | termios.ISIG | termios.IEXTEN)
        mode[0] &= ~(termios.IXON | termios.ICRNL)
        mode[6][termios.VMIN], mode[6][termios.VTIME] = 1, 0
        termios.tcsetattr(self.fd, termios.TCSANOW, mode)
        sys.stdout.write("\x1b[?2004h")  # bracketed paste
        self.layout()
        loop.add_reader(self.fd, self.read)
        loop.add_signal_handler(signal.SIGWINCH, self.layout)

    def stop(self):
        if self.tty and self.saved:
            sys.stdout.write("\x1b[?2004l\x1b[r\x1b[%d;1H\r\n" % self.rows)
            sys.stdout.flush()
            termios.tcsetattr(self.fd, termios.TCSANOW, self.saved)

    def layout(self):
        """(Re)draw everything for the current size: region, recent output, status, input."""
        if not self.tty:
            return
        cols, rows = os.get_terminal_size()
        self.cols, self.rows = cols, max(rows, 5)
        out = ["\x1b[r\x1b[2J\x1b[1;%dr" % (self.rows - 2), "\x1b[%d;1H" % (self.rows - 2)]
        for line in list(self.styled)[-(self.rows - 2):]:
            out.append("\r\n" + line)
        if self.partial:
            out.append("\r\n" + self.partial_style + self.partial + RESET)
        out.append("\x1b7")
        sys.stdout.write("".join(out))
        self.draw_bottom()

    def draw_bottom(self):
        if not self.tty:
            return
        shown = self.buf.replace("\n", "⏎")
        room = self.cols - 3
        if len(shown) > room:
            shown = "…" + shown[-(room - 1):]
        status = self.status[:self.cols]
        sys.stdout.write("\x1b[%d;1H\x1b[2K%s%s%s\x1b[%d;1H\x1b[2K%s❯%s %s" % (
            self.rows - 1, DIM, status, RESET, self.rows, BOLD, RESET, shown))
        sys.stdout.flush()

    def set_status(self, text):
        self.status = text
        self.draw_bottom()

    def _emit(self, text):
        if self.tty:
            sys.stdout.write("\x1b8" + text + "\x1b7")
            self.draw_bottom()

    def print(self, text, style=""):
        """Whole lines of output."""
        self.close_line()
        for line in str(text).split("\n"):
            self.lines.append(line)
            self.styled.append(style + line + RESET if style else line)
            self._emit("\r\n" + (style + line + RESET if style else line))

    def stream(self, text, style=""):
        """Text that may end mid-line, continued by the next call."""
        if not self.partial:
            self.partial_style = style
            self._emit("\r\n")
        parts = text.split("\n")
        for i, part in enumerate(parts):
            if i:
                self.lines.append(self.partial)
                self.styled.append(self.partial_style + self.partial + RESET)
                self.partial = ""
                self._emit("\r\n")
            self.partial += part
            self._emit(style + part + (RESET if style else ""))

    def close_line(self):
        if self.partial:
            self.lines.append(self.partial)
            self.styled.append(self.partial_style + self.partial + RESET)
            self.partial = ""

    def screen(self):
        tail = list(self.lines)[-SCREEN_LINES:]
        if self.partial:
            tail.append(self.partial)
        return "\n".join(tail)

    # Keys. Enter submits, Esc interrupts (or declines a dialog), ^C clears the
    # input or interrupts, ^U clears, ^W deletes a word; a paste may hold newlines.
    def read(self):
        try:
            data = os.read(self.fd, 65536).decode("utf-8", "replace")
        except OSError:
            return
        data = self.pending + data
        self.pending = ""
        i = 0
        while i < len(data):
            if self.in_paste:
                end = data.find("\x1b[201~", i)
                if end < 0:
                    self.buf += data[i:].replace("\r\n", "\n").replace("\r", "\n")
                    break
                self.buf += data[i:end].replace("\r\n", "\n").replace("\r", "\n")
                self.in_paste = False
                i = end + 6
                continue
            ch = data[i]
            if ch == "\x1b":
                if data.startswith("\x1b[200~", i):
                    self.in_paste = True
                    i += 6
                    continue
                m = re.match(r"\x1b(\[[0-9;]*[A-Za-z~]|O[A-Za-z])", data[i:])
                if m:
                    i += len(m.group(0))  # arrows, function keys: not used
                    continue
                if i == len(data) - 1:
                    self.on_key("escape")
                    i += 1
                    continue
                if data[i + 1] in "[O":
                    self.pending = data[i:]  # a sequence cut in two reads
                    break
                self.on_key("escape")
                i += 1
                continue
            if ch in "\r\n":
                text, self.buf = self.buf, ""
                self.draw_bottom()
                self.on_submit(text)
            elif ch == "\x03":
                if self.buf:
                    self.buf = ""
                else:
                    self.on_key("interrupt")
            elif ch in "\x7f\x08":
                self.buf = self.buf[:-1]
            elif ch == "\x15":
                self.buf = ""
            elif ch == "\x17":
                self.buf = re.sub(r"\S*\s*$", "", self.buf)
            elif ch >= " " or ch == "\t":
                self.buf += ch
            i += 1
        self.draw_bottom()


# --- the agent --------------------------------------------------------------


class Runner:
    def __init__(self, session_id):
        self.sid = session_id
        e = load_entry(session_id)
        if not e:
            raise SystemExit("roster-agent: no roster entry for session %s" % session_id)
        self.cwd = e.get("cwd") or os.path.expanduser("~")
        self.model = e.get("model")
        self.effort = e.get("effort")
        self.status = None
        self.client = None
        self.queue = asyncio.Queue()
        self.dialog = None
        self.interrupting = False
        self.revives = 0
        self.revive_task = None
        self.turn_started = time.monotonic()
        self.started = transcript_exists(session_id)
        self.term = Terminal(self.submit, self.key)
        self.loop = None

    @property
    def name(self):
        return roster_name(self.sid) or "?"

    # -- status ----------------------------------------------------------------

    def set_status(self, status, **extra):
        changed = status != self.status
        self.status = status
        fields = dict(extra)
        if changed:
            fields.update(status=status, status_at=now())
        if fields:
            update_entry(self.sid, **fields)
        self.draw_status()
        if status == "idle" and changed:
            self.check_mail()

    def draw_status(self):
        parts = [self.name, self.status or "starting", self.model or "default model",
                 "effort %s" % (self.effort or "default")]
        if self.queue.qsize():
            parts.append("%d queued" % self.queue.qsize())
        hint = "esc: interrupt · /model /effort /help" if not self.dialog else "type an option number, or esc"
        self.term.set_status(" " + " · ".join(parts) + "   " + hint)

    def check_mail(self):
        """Mail that arrived while idle and no hook delivered: wake for it, as `roster send` would."""
        if self.status == "idle" and self.queue.empty() and unread_mail(self.name):
            self.queue.put_nowait(("[roster] You have mail waiting.", "roster"))

    # -- input -------------------------------------------------------------------

    def submit(self, text):
        """The terminal's Enter."""
        if not text.strip():
            return
        if self.dialog:
            self.answer_typed(text.strip())
            return
        if text.startswith("/"):
            cmd, _, arg = text[1:].partition(" ")
            arg = arg.strip()
            if cmd == "model" and arg:
                asyncio.ensure_future(self.safe(self.set_model(arg)))
                return
            if cmd == "effort" and arg:
                asyncio.ensure_future(self.safe(self.set_effort(arg)))
                return
            if cmd in ("interrupt", "stop"):
                asyncio.ensure_future(self.safe(self.interrupt()))
                return
            if cmd == "help":
                self.term.print("/model <alias or name> · /effort %s · /interrupt (or esc) · "
                                "other /commands go to Claude" % "|".join(EFFORTS), DIM)
                return
        self.prompt(text, "you")

    def key(self, what):
        if what == "escape" and self.dialog:
            self.resolve_dialog("escape", None)
        elif what in ("escape", "interrupt") and self.status == "working":
            asyncio.ensure_future(self.safe(self.interrupt()))

    async def safe(self, coro):
        try:
            return await coro
        except Exception as exc:  # shown, never fatal
            self.term.print("error: %s" % exc, RED)

    def prompt(self, text, source):
        self.queue.put_nowait((text, source))
        self.draw_status()

    # -- controls ----------------------------------------------------------------

    async def interrupt(self):
        if self.status not in ("working", "blocked") or not self.client:
            return False
        self.interrupting = True
        if self.dialog:
            self.resolve_dialog("escape", None)
        await self.client.interrupt()
        self.term.print("interrupted", YELLOW)
        return True

    async def set_model(self, model):
        if not re.match(r"^[A-Za-z0-9._\[\]-]+$", model):
            raise ValueError("bad model name %r" % model)
        if self.client:
            await self.client.set_model(model)
        self.model = model
        update_entry(self.sid, model=model)
        self.term.print("model: %s" % model, CYAN)
        self.draw_status()

    async def set_effort(self, effort):
        if effort not in EFFORTS:
            raise ValueError("effort is one of %s" % ", ".join(EFFORTS))
        if self.client:
            # The CLI's flag-settings layer, as its /effort command writes; no
            # public SDK call for it yet (claude-agent-sdk 0.2.172).
            await self.client._query._send_control_request(
                {"subtype": "apply_flag_settings", "settings": {"effortLevel": effort}})
        self.effort = effort
        update_entry(self.sid, effort=effort)
        self.term.print("effort: %s" % effort, CYAN)
        self.draw_status()

    # -- dialogs -----------------------------------------------------------------

    async def open_dialog(self, title, options, multi=False):
        """Show a choice and wait for it; returns (key, text). Keys are "1", "2", …"""
        fut = self.loop.create_future()
        self.dialog = {"title": title, "options": options, "multi": multi, "future": fut, "cursor": "1"}
        self.set_status("blocked")
        self.term.print(title, BOLD)
        for o in options:
            mark = ("[✔] " if o.get("checked") else "[ ] ") if "checked" in o else ""
            self.term.print("  %s. %s%s%s" % (o["key"], mark, o["label"], ("  " + o["detail"]) if o.get("detail") else ""))
        try:
            return await fut
        finally:
            self.dialog = None
            if self.status == "blocked":
                self.set_status("working")

    def dialog_out(self):
        if not self.dialog:
            return None
        return {k: v for k, v in self.dialog.items() if k != "future"}

    def resolve_dialog(self, key, text):
        d = self.dialog
        if d and not d["future"].done():
            d["future"].set_result((key, text))

    def answer(self, key, text=None):
        d = self.dialog
        if not d:
            raise ValueError("no dialog is open")
        key = str(key)
        if key == "escape":
            self.resolve_dialog("escape", None)
            return
        opt = next((o for o in d["options"] if o["key"] == key), None)
        if not opt:
            raise ValueError("no option %s" % key)
        if d["multi"] and "checked" in opt:
            opt["checked"] = not opt["checked"]
            self.term.print("  %s %s" % ("[✔]" if opt["checked"] else "[ ]", opt["label"]), DIM)
            return
        if opt.get("input") and not (text or "").strip():
            raise ValueError("option %s needs text" % key)
        self.resolve_dialog(key, text)

    def answer_typed(self, text):
        d = self.dialog
        try:
            if re.fullmatch(r"\d{1,2}", text):
                self.answer(text)
                return
            field = next((o for o in d["options"] if o.get("input")), None)
            if field:
                self.answer(field["key"], text)
                return
            self.term.print("type an option number (1-%d), or esc" % len(d["options"]), YELLOW)
        except ValueError as exc:
            self.term.print(str(exc), YELLOW)

    async def can_use_tool(self, tool, inp, ctx):
        if tool == "AskUserQuestion":
            return await self.ask_questions(inp)
        options = [{"key": "1", "label": "Yes"}]
        if ctx.suggestions:
            options.append({"key": "2", "label": "Yes, and don't ask again for this"})
        options.append({"key": str(len(options) + 1), "label": "No, and tell Claude what to do differently",
                        "input": True, "text": ""})
        reason = (" (%s)" % ctx.decision_reason) if getattr(ctx, "decision_reason", None) else ""
        key, text = await self.open_dialog("Allow %s: %s?%s" % (tool, tool_summary(tool, inp), reason), options)
        if key == "1":
            return PermissionResultAllow()
        if key == "2" and ctx.suggestions:
            return PermissionResultAllow(updated_permissions=ctx.suggestions)
        msg = (text or "").strip() or "The user declined this tool call."
        return PermissionResultDeny(message=msg, interrupt=key == "escape")

    async def ask_questions(self, inp):
        answers = {}
        for q in inp.get("questions") or []:
            opts = [{"key": str(i + 1), "label": o.get("label", ""), "detail": o.get("description", "")}
                    for i, o in enumerate(q.get("options") or [])]
            multi = bool(q.get("multiSelect"))
            if multi:
                for o in opts:
                    o["checked"] = False
            n = len(opts)
            opts.append({"key": str(n + 1), "label": "Type something", "input": True, "text": ""})
            if multi:
                opts.append({"key": str(n + 2), "label": "Submit"})
            key, text = await self.open_dialog(q.get("question") or q.get("header") or "Question", opts, multi)
            if key == "escape":
                return PermissionResultDeny(message="The user declined to answer.", interrupt=True)
            if text is not None and key == str(n + 1):
                answers[q.get("question")] = text.strip()
            elif multi:
                answers[q.get("question")] = ", ".join(o["label"] for o in opts if o.get("checked"))
            else:
                answers[q.get("question")] = opts[int(key) - 1]["label"]
        return PermissionResultAllow(updated_input=dict(inp, answers=answers))

    # -- the session -------------------------------------------------------------

    def options(self):
        kw = dict(
            cwd=self.cwd,
            model=self.model or None,
            effort=self.effort or None,
            setting_sources=["user", "project", "local"],
            system_prompt={"type": "preset", "preset": "claude_code"},
            include_partial_messages=True,
            can_use_tool=self.can_use_tool,
            stderr=lambda line: None,
        )
        if self.started:
            kw["resume"] = self.sid
        else:
            kw["session_id"] = self.sid
        return ClaudeAgentOptions(**kw)

    async def run(self):
        self.loop = asyncio.get_running_loop()
        self.term.start(self.loop)
        server = await self.serve_socket()
        first = os.path.join(os.path.dirname(entry_path(self.name)), "first-prompt")
        try:
            with open(first) as f:
                text = f.read()
            os.remove(first)
            if text.strip():
                self.queue.put_nowait((text, "you"))
        except OSError:
            pass
        failures = 0
        try:
            while True:
                try:
                    async with ClaudeSDKClient(self.options()) as client:
                        self.client = client
                        failures = 0
                        await self.serve(client)
                except asyncio.CancelledError:
                    raise
                except Exception as exc:
                    self.client = None
                    self.term.print("session error: %s" % exc, RED)
                    self.set_status("idle", stalled={"error": "unknown", "at": now(), "message": str(exc)[:200]})
                    failures += 1
                    await asyncio.sleep(min(5 * 2 ** failures, 300))
                    self.started = transcript_exists(self.sid)
        finally:
            server.close()
            try:
                os.remove(socket_path(self.sid))
            except OSError:
                pass

    async def serve(self, client):
        """Send prompts as they come and read the session's output all along.

        A prompt sent while a turn runs goes straight to Claude, which takes it
        in at its next step, as Claude Code does with a message typed mid-turn
        (and records it the same way), or starts a new turn with it after."""
        if self.status != "idle":
            self.set_status("idle")
        self.term.print("%s · %s · %s" % (self.name, self.cwd, "resumed" if self.started else "new session"), DIM)
        reader = asyncio.ensure_future(self.read(client))
        try:
            while True:
                getter = asyncio.ensure_future(self.queue.get())
                done, _ = await asyncio.wait({getter, reader}, return_when=asyncio.FIRST_COMPLETED)
                if reader in done:
                    getter.cancel()
                    reader.result()  # raises what ended it
                    raise RuntimeError("the session's output ended")
                text, _source = getter.result()
                self.term.print("❯ %s" % text, BOLD)
                if self.status != "working":
                    self.interrupting = False
                    self.turn_started = time.monotonic()
                    self.set_status("working")
                await client.query(text)
        finally:
            reader.cancel()

    async def read(self, client):
        """Every message of the session, shown as it comes; a result ends a turn."""
        streamed = ""  # text already shown from deltas this turn
        async for m in client.receive_messages():
            if not isinstance(m, (ResultMessage, SystemMessage, RateLimitEvent)) and self.status == "idle":
                # A turn the CLI started by itself, e.g. with a prompt queued at the end of the last.
                self.turn_started = time.monotonic()
                self.set_status("working")
            if isinstance(m, SystemMessage):
                if m.subtype == "init":
                    if m.data.get("apiKeySource") not in (None, "none"):
                        self.term.print("refusing to run on an API key (apiKeySource %s); the subscription "
                                        "login is required" % m.data.get("apiKeySource"), RED)
                        raise RuntimeError("not on the subscription login")
                    self.model = self.model or m.data.get("model")
            elif isinstance(m, StreamEvent):
                if m.parent_tool_use_id:
                    continue
                ev = m.event
                if ev.get("type") == "content_block_start" and (ev.get("content_block") or {}).get("type") == "text":
                    self.term.close_line()
                    self.term.stream("⏺ ")
                elif ev.get("type") == "content_block_delta":
                    d = ev.get("delta") or {}
                    if d.get("type") == "text_delta" and d.get("text"):
                        streamed += d["text"]
                        self.term.stream(d["text"])
            elif isinstance(m, AssistantMessage):
                if m.parent_tool_use_id:
                    continue
                if m.error:
                    msg = "".join(b.text for b in m.content if isinstance(b, TextBlock)) or m.error
                    self.term.print("API error (%s): %s" % (m.error, msg[:300]), RED)
                for b in m.content:
                    if isinstance(b, TextBlock) and b.text.strip() and b.text.strip() not in streamed:
                        self.term.print("⏺ " + b.text)
                    elif isinstance(b, ToolUseBlock):
                        self.term.print("  ⏺ %s(%s)" % (b.name, tool_summary(b.name, b.input)), CYAN)
            elif isinstance(m, UserMessage):
                if m.parent_tool_use_id or not isinstance(m.content, list):
                    continue
                for b in m.content:
                    if isinstance(b, ToolResultBlock):
                        text = block_text(b.content).strip()
                        first = text.splitlines()[0][:160] if text else ""
                        more = len(text.splitlines()) - 1
                        line = "    ⎿ %s%s" % (first, " (+%d lines)" % more if more > 0 else "")
                        self.term.print(line, RED if b.is_error else DIM)
            elif isinstance(m, RateLimitEvent):
                if m.rate_limit_info.status == "rejected":
                    self.term.print("subscription rate limit reached (%s)" % m.rate_limit_info.rate_limit_type, RED)
            elif isinstance(m, ResultMessage):
                self.term.close_line()
                streamed = ""
                self.started = True
                aborted = (m.terminal_reason or "").startswith("aborted") or self.interrupting
                if m.is_error and not aborted:
                    msg = (m.result or "; ".join(m.errors or []) or m.subtype or "")[:200]
                    kind = "rate_limit" if m.api_error_status == 429 else (
                        "server_error" if (m.api_error_status or 0) >= 500 else "unknown")
                    self.term.print("turn failed: %s" % msg, RED)
                    self.set_status("idle", stalled={"error": kind, "at": now(), "message": msg})
                    self.schedule_revive(kind)
                    continue
                self.term.print("  %.1fs" % (time.monotonic() - self.turn_started), DIM)
                self.revives = 0
                self.set_status("idle", stalled=None)

    def schedule_revive(self, kind):
        """After an API error, carry on by itself once it may work again."""
        if self.revives >= REVIVE_MAX:
            update_entry(self.sid, stalled={"error": kind, "at": now(), "message": "gave up", "gave_up": True})
            return
        delay = 300 if kind == "rate_limit" else min(30 * 2 ** self.revives, 900)
        self.revives += 1

        async def later():
            await asyncio.sleep(delay)
            if self.status == "idle" and self.queue.empty() and not self.term.buf:
                self.queue.put_nowait(("[roster] Your last turn ended on an API error. The API may answer "
                                       "again: carry on where you left off.", "roster"))
        if self.revive_task:
            self.revive_task.cancel()
        self.revive_task = asyncio.ensure_future(later())
        self.term.print("trying again in %ds" % delay, DIM)

    # -- the control socket ------------------------------------------------------

    async def serve_socket(self):
        path = socket_path(self.sid)
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        try:
            os.remove(path)
        except OSError:
            pass
        server = await asyncio.start_unix_server(self.handle, path=path)
        os.chmod(path, 0o600)
        return server

    async def handle(self, reader, writer):
        try:
            req = json.loads(await asyncio.wait_for(reader.readline(), 10))
            out = await self.request(req)
        except Exception as exc:
            out = {"error": str(exc)}
        writer.write((json.dumps(out) + "\n").encode())
        try:
            await writer.drain()
        finally:
            writer.close()

    async def request(self, req):
        op = req.get("op")
        if op == "status":
            return {"name": self.name, "status": self.status, "model": self.model, "effort": self.effort,
                    "dialog": self.dialog_out(), "queued": self.queue.qsize(), "input": bool(self.term.buf),
                    "session_id": self.sid}
        if op == "screen":
            return {"text": self.term.screen(), "dialog": self.dialog_out(), "status": self.status}
        if op == "prompt":
            text = req.get("text") or ""
            if not text.strip():
                raise ValueError("empty prompt")
            if self.dialog:
                raise ValueError("a dialog is open; answer it first")
            queued = self.status != "idle"
            self.prompt(text, req.get("source") or "roster")
            return {"ok": True, "queued": queued}
        if op == "interrupt":
            return {"ok": await self.interrupt()}
        if op == "model":
            await self.set_model(req.get("model") or "")
            return {"ok": True, "model": self.model}
        if op == "effort":
            await self.set_effort(req.get("effort") or "")
            return {"ok": True, "effort": self.effort}
        if op == "answer":
            self.answer(req.get("key"), req.get("text"))
            return {"ok": True}
        if op == "keys":
            for k in req.get("keys") or []:
                if k == "Escape":
                    self.answer("escape")
                elif re.fullmatch(r"\d", k) and self.dialog:
                    self.answer(k)
                elif k == "Enter" and self.dialog and self.dialog["multi"]:
                    submit = next((o for o in self.dialog["options"] if o["label"] == "Submit"), None)
                    if submit:
                        self.answer(submit["key"])
                elif k in ("y", "n") and self.dialog:
                    self.answer("1" if k == "y" else "escape")
                else:
                    raise ValueError("key %s means nothing to an SDK agent here" % k)
            return {"ok": True}
        raise ValueError("unknown op %r" % op)


def main(session_id):
    runner = Runner(session_id)
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    task = loop.create_task(runner.run())
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        loop.add_signal_handler(sig, task.cancel)
    try:
        loop.run_until_complete(task)
    except asyncio.CancelledError:
        pass
    finally:
        runner.term.stop()
        loop.close()
