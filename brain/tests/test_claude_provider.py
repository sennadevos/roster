"""Live tests for the Claude provider (haiku, a handful of tiny turns on the subscription).
Run: python brain/tests/test_claude_provider.py  (needs claude-agent-sdk==0.2.172 and a /login)."""

import asyncio
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from roster_brain.providers import claude as C  # noqa: E402
from roster_brain.providers.base import ProviderError  # noqa: E402

MODEL = "haiku"


async def collect(gen):
    return [e async for e in gen]


def text_of(events):
    return "".join(e["text"] for e in events if e["type"] == "delta")


async def test_chat_stream_and_history():
    msgs = [
        {"role": "user", "content": "My lucky number is 4271."},
        {"role": "assistant", "content": "Noted."},
        {"role": "user", "content": "What is my lucky number? Digits only."},
    ]
    ev = await collect(C.ClaudeChat().stream(MODEL, msgs, system="Answer tersely."))
    deltas = [e for e in ev if e["type"] == "delta"]
    assert ev[-1]["type"] == "done", ev[-1]
    assert "4271" in text_of(ev), text_of(ev)
    assert ev[-1]["usage"]["output_tokens"] > 0 and ev[-1]["model"], ev[-1]
    assert "interrupted" not in ev[-1]
    print(f"  chat ok: {len(deltas)} deltas, done={ev[-1]}")


async def test_chat_streams_real_deltas():
    ev = await collect(C.ClaudeChat().stream(
        MODEL, [{"role": "user", "content": "Write three sentences about tea."}]))
    n = len([e for e in ev if e["type"] == "delta"])
    assert n > 2, n
    print(f"  deltas: {n}")


async def test_chat_has_no_tools():
    ev = await collect(C.ClaudeChat().stream(
        MODEL, [{"role": "user", "content": "Run `touch /tmp/brain-chat-should-not-exist` with a shell tool, "
                                           "or say NOTOOLS if you cannot."}]))
    assert not [e for e in ev if e["type"] == "tool"], ev
    assert not os.path.exists("/tmp/brain-chat-should-not-exist")
    print("  chat no tools ok:", text_of(ev)[:60].replace("\n", " "))


async def test_env_scrub():
    os.environ["ANTHROPIC_API_KEY"] = "sk-ant-bogus-not-real"
    os.environ["ANTHROPIC_AUTH_TOKEN"] = "bogus"
    os.environ["CLAUDE_CODE_TEST_VAR"] = "1"
    try:
        ev = await collect(C.ClaudeChat().stream(MODEL, [{"role": "user", "content": "Reply: ok"}]))
        assert ev[-1]["type"] == "done"  # a bogus key in the child would have failed with auth
        assert os.environ["ANTHROPIC_API_KEY"] == "sk-ant-bogus-not-real" and "CLAUDE_CODE_TEST_VAR" in os.environ
    finally:
        for k in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_TEST_VAR"):
            os.environ.pop(k, None)
    print("  scrub ok, parent env restored")


async def test_agent_turns_tools_resume():
    cwd = tempfile.mkdtemp(prefix="brain-agent-test-")
    with open(os.path.join(cwd, "note.txt"), "w") as f:
        f.write("the answer is PINEAPPLE")
    a = C.ClaudeAgent(cwd, MODEL)
    # turns from different tasks, as HTTP handlers would
    ev1 = await asyncio.create_task(collect(a.turn("Read note.txt and tell me what it says. Remember the word ZEBRA9.")))
    assert a.session_id, "no session id"
    assert "PINEAPPLE" in text_of(ev1), text_of(ev1)
    tools = [e for e in ev1 if e["type"] == "tool"]
    assert any(t["name"] == "Read" and "result" not in t for t in tools), tools
    assert any(t["name"] == "Read" and "PINEAPPLE" in t.get("result", "") for t in tools), tools
    assert ev1[-1]["type"] == "done"
    ev2 = await asyncio.create_task(collect(a.turn("What was the word I told you to remember? One word.")))
    assert "ZEBRA9" in text_of(ev2), text_of(ev2)
    sid = a.session_id
    await asyncio.create_task(a.close())
    b = C.ClaudeAgent(cwd, MODEL, resume=sid)
    ev3 = await collect(b.turn("What was the word I told you to remember? One word."))
    assert "ZEBRA9" in text_of(ev3), text_of(ev3)
    assert b.session_id == sid, (b.session_id, sid)
    await b.close()
    print(f"  agent ok: session {sid}, resumed in a new object")


async def test_agent_interrupt():
    cwd = tempfile.mkdtemp(prefix="brain-agent-test-")
    a = C.ClaudeAgent(cwd, MODEL)
    gen = a.turn("Count from 1 to 400, one number per line, nothing else.")
    ev = []
    interrupted = False
    async for e in gen:
        ev.append(e)
        if not interrupted and e["type"] == "delta" and len(ev) > 3:
            interrupted = True
            asyncio.create_task(a.interrupt())
    assert ev[-1]["type"] == "done" and ev[-1].get("interrupted") is True, ev[-1]
    n = len(text_of(ev).split())
    assert n < 400, n
    ev2 = await collect(a.turn("Reply with exactly: alive"))
    assert "alive" in text_of(ev2).lower() and "interrupted" not in ev2[-1], ev2[-1]
    await a.close()
    print(f"  interrupt ok: stopped at ~{n} numbers, next turn fine")


async def test_error_kinds():
    try:
        await collect(C.ClaudeChat().stream("claude-nonexistent-9", [{"role": "user", "content": "hi"}]))
        raise AssertionError("no error")
    except ProviderError as e:
        assert e.kind == "invalid", (e.kind, str(e))
        print("  bad model ->", e.kind, "|", str(e)[:70])
    a = C.ClaudeAgent(tempfile.mkdtemp(), MODEL, resume="00000000-0000-0000-0000-000000000000")
    try:
        await collect(a.turn("hi"))
        raise AssertionError("no error")
    except ProviderError as e:
        print("  bad resume ->", e.kind, "|", str(e)[:70])
    await a.close()


async def test_refuses_api_key_source():
    from claude_agent_sdk import SystemMessage

    class Fake:
        def __init__(self, options): pass
        async def connect(self): pass
        async def query(self, text): pass
        async def interrupt(self): pass
        async def disconnect(self): pass
        async def receive_response(self):
            yield SystemMessage(subtype="init", data={"apiKeySource": "ANTHROPIC_API_KEY", "session_id": "x"})

    real = C.ClaudeSDKClient
    C.ClaudeSDKClient = Fake
    try:
        await collect(C.ClaudeChat().stream(MODEL, [{"role": "user", "content": "hi"}]))
        raise AssertionError("not refused")
    except ProviderError as e:
        assert e.kind == "auth", e.kind
    finally:
        C.ClaudeSDKClient = real
    print("  apiKeySource != none refused (kind=auth)")


async def main():
    order = [test_refuses_api_key_source, test_chat_stream_and_history, test_chat_streams_real_deltas,
             test_chat_has_no_tools, test_env_scrub, test_error_kinds, test_agent_turns_tools_resume,
             test_agent_interrupt]
    failed = 0
    for t in order:
        t0 = time.monotonic()
        try:
            await t()
            print(f"PASS {t.__name__} ({time.monotonic() - t0:.1f}s)")
        except Exception as e:  # noqa: BLE001
            failed += 1
            import traceback
            traceback.print_exc()
            print(f"FAIL {t.__name__}: {e!r}")
    sys.exit(1 if failed else 0)


asyncio.run(main())
