"""OpenRouter chat completions, streamed."""

import json

import aiohttp

from .base import ChatProvider, ProviderError

URL = "https://openrouter.ai/api/v1/chat/completions"
HEADERS = {"HTTP-Referer": "https://github.com/sennadevos/roster", "X-Title": "roster-brain"}


def error_kind(status):
    if status in (401, 403):
        return "auth"
    if status == 402 or status == 429:
        return "rate_limit"
    if status >= 500:
        return "server"
    return "invalid"


class OpenRouter(ChatProvider):
    def __init__(self, session, key):
        self.session = session
        self.key = key

    def headers(self):
        if not self.key:
            raise ProviderError("no OpenRouter key (openrouter_key_file)", "auth")
        return dict(HEADERS, Authorization="Bearer " + self.key)

    async def complete(self, model, messages, timeout, **extra):
        """One non-streamed completion; returns the message text."""
        body = dict(extra, model=model, messages=messages)
        try:
            async with self.session.post(URL, json=body, headers=self.headers(),
                                         timeout=aiohttp.ClientTimeout(total=timeout)) as r:
                data = await r.json(content_type=None)
                if r.status != 200 or "error" in data:
                    err = data.get("error") or {}
                    raise ProviderError("openrouter %s: %s" % (r.status, err.get("message", data)),
                                        error_kind(err.get("code") or r.status))
        except aiohttp.ClientError as exc:
            raise ProviderError("openrouter: %s" % exc, "server")
        return data["choices"][0]["message"].get("content") or ""

    async def stream(self, model, messages, system=None):
        msgs = ([{"role": "system", "content": system}] if system else []) + messages
        body = {"model": model, "messages": msgs, "stream": True}
        usage = None
        served = model
        try:
            async with self.session.post(URL, json=body, headers=self.headers(),
                                         timeout=aiohttp.ClientTimeout(total=600, sock_read=120)) as r:
                if r.status != 200:
                    text = await r.text()
                    try:
                        msg = json.loads(text)["error"]["message"]
                    except (ValueError, KeyError, TypeError):
                        msg = text[:300]
                    raise ProviderError("openrouter %s: %s" % (r.status, msg), error_kind(r.status))
                async for raw in r.content:
                    line = raw.decode("utf-8", "replace").strip()
                    # Blank lines separate events; ": OPENROUTER PROCESSING" keeps the line alive.
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                    except ValueError:
                        continue
                    if "error" in chunk:
                        err = chunk["error"]
                        raise ProviderError("openrouter: %s" % err.get("message", err),
                                            error_kind(err.get("code") or 500))
                    served = chunk.get("model") or served
                    if chunk.get("usage"):
                        usage = chunk["usage"]
                    for choice in chunk.get("choices") or []:
                        text = (choice.get("delta") or {}).get("content")
                        if text:
                            yield {"type": "delta", "text": text}
        except aiohttp.ClientError as exc:
            raise ProviderError("openrouter: %s" % exc, "server")
        yield {"type": "done", "model": "openrouter:" + served, "usage": usage}
