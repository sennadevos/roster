"""The HTTP API from docs/brain.md."""

import asyncio
import hmac
import json

from aiohttp import web

from . import VERSION
from . import config as config_mod
from .brain import Brain, Busy

BRAIN = web.AppKey("brain", Brain)
TOKEN = web.AppKey("token", object)


def j(data, status=200):
    return web.json_response(data, status=status, dumps=lambda d: json.dumps(d, ensure_ascii=False))


def fail(msg, status=400):
    return j({"error": msg}, status)


def conv_out(brain, c, messages=False):
    out = {k: c[k] for k in ("id", "kind", "title", "model", "system", "cwd", "created", "updated")}
    out["running"] = c["id"] in brain.turns
    if messages:
        out["messages"] = [{k: m[k] for k in ("id", "role", "content", "state", "model", "route", "meta",
                                              "created")} for m in brain.store.messages(c["id"])]
    return out


@web.middleware
async def auth(request, handler):
    token = request.app[TOKEN]
    if token:
        got = request.headers.get("Authorization", "")
        if not hmac.compare_digest(got.encode(), ("Bearer " + token).encode()):
            return fail("unauthorized", 401)
    try:
        return await handler(request)
    except web.HTTPException:
        raise
    except (ValueError, config_mod.ConfigError) as exc:
        return fail(str(exc))


async def body(request):
    try:
        got = await request.json()
    except ValueError:
        raise ValueError("body must be JSON")
    if not isinstance(got, dict):
        raise ValueError("body must be a JSON object")
    return got


async def health(request):
    return j({"ok": True, "version": VERSION})


async def catalog(request):
    return j(request.app[BRAIN].catalog())


async def list_convs(request):
    brain = request.app[BRAIN]
    limit = int(request.query.get("limit", 50))
    return j({"conversations": [conv_out(brain, c) for c in
                                brain.store.conversations(request.query.get("kind"), limit)]})


async def create_conv(request):
    brain = request.app[BRAIN]
    b = await body(request)
    c = brain.create(b.get("kind", "chat"), b.get("title"), b.get("model"), b.get("system"), b.get("cwd"))
    return j(conv_out(brain, c), 201)


async def get_conv(request):
    brain = request.app[BRAIN]
    c = brain.store.conversation(request.match_info["id"])
    if not c:
        return fail("no such conversation", 404)
    return j(conv_out(brain, c, messages=True))


async def delete_conv(request):
    brain = request.app[BRAIN]
    cid = request.match_info["id"]
    if not brain.store.conversation(cid):
        return fail("no such conversation", 404)
    await brain.delete(cid)
    return j({"deleted": cid})


async def interrupt(request):
    try:
        stopped = await request.app[BRAIN].interrupt(request.match_info["id"])
    except KeyError:
        return fail("no such conversation", 404)
    return j({"interrupted": stopped})


async def stream_turn(request, cid, text, route):
    brain = request.app[BRAIN]
    if not isinstance(text, str) or not text.strip():
        return fail("text is required")
    try:
        events = brain.turn(cid, text, route)
    except KeyError:
        return fail("no such conversation", 404)
    except Busy as exc:
        return fail(str(exc), 409)
    resp = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache",
                                       "X-Accel-Buffering": "no"})
    await resp.prepare(request)
    try:
        async for event, data in events:
            await resp.write(("event: %s\ndata: %s\n\n" % (event, json.dumps(data, ensure_ascii=False))).encode())
    except (ConnectionResetError, asyncio.CancelledError):
        # The client left; the turn carries on and lands in the store.
        pass
    return resp


async def post_message(request):
    b = await body(request)
    return await stream_turn(request, request.match_info["id"], b.get("text"), b.get("route"))


async def ask(request):
    b = await body(request)
    brain = request.app[BRAIN]
    text = b.get("text")
    if not isinstance(text, str) or not text.strip():
        return fail("text is required")
    c = brain.create("chat", title=text.strip()[:60], model=b.get("model"), system=b.get("system"))
    return await stream_turn(request, c["id"], text, b.get("route"))


async def events(request):
    brain = request.app[BRAIN]
    q = asyncio.Queue()
    brain.subscribers.add(q)
    resp = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache"})
    await resp.prepare(request)
    try:
        while True:
            try:
                event, data = await asyncio.wait_for(q.get(), 25)
                await resp.write(("event: %s\ndata: %s\n\n" % (event, json.dumps(data, ensure_ascii=False))).encode())
            except asyncio.TimeoutError:
                await resp.write(b": keepalive\n\n")
    except (ConnectionResetError, asyncio.CancelledError):
        pass
    finally:
        brain.subscribers.discard(q)
    return resp


def make_app(cfg, log=print):
    brain = Brain(cfg, log)
    app = web.Application(middlewares=[auth])
    app[BRAIN] = brain
    app[TOKEN] = config_mod.read_secret(cfg["token_file"]) if cfg.get("token_file") else None

    async def on_start(app):
        await brain.start()

    async def on_stop(app):
        await brain.stop()

    app.on_startup.append(on_start)
    app.on_cleanup.append(on_stop)
    app.router.add_get("/v1/health", health)
    app.router.add_get("/v1/catalog", catalog)
    app.router.add_get("/v1/conversations", list_convs)
    app.router.add_post("/v1/conversations", create_conv)
    app.router.add_get("/v1/conversations/{id}", get_conv)
    app.router.add_delete("/v1/conversations/{id}", delete_conv)
    app.router.add_post("/v1/conversations/{id}/messages", post_message)
    app.router.add_post("/v1/conversations/{id}/interrupt", interrupt)
    app.router.add_post("/v1/ask", ask)
    app.router.add_get("/v1/events", events)
    return app


def serve(cfg):
    host, _, port = cfg["listen"].rpartition(":")
    web.run_app(make_app(cfg), host=host or "127.0.0.1", port=int(port), print=None,
                shutdown_timeout=5)
