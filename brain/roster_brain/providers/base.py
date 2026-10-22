"""What every provider implements. Events are plain dicts, the same shapes the
turn event stream sends (docs/brain.md): {"type": "delta", "text"},
{"type": "tool", "name", "input", "result"?, "error"?},
{"type": "done", "model", "usage"?}, {"type": "error", "error", "kind"?}."""


class ProviderError(Exception):
    """A failed turn. kind: rate_limit, auth, server, invalid or None."""

    def __init__(self, message, kind=None):
        super().__init__(message)
        self.kind = kind


class ChatProvider:
    """Answers a chat turn from the full history the brain keeps."""

    async def stream(self, model, messages, system=None):
        """model: the part after "<provider>:". messages: [{"role": "user" |
        "assistant", "content": str}], oldest first, ending with the new user
        message. Yields events, the last one "done"; raises ProviderError."""
        raise NotImplementedError
        yield


class AgentSession:
    """One live agent conversation. The brain keeps one per agent conversation
    and calls close() when it is deleted or the service stops."""

    session_id = None  # Claude's session id once known; stored for resume

    async def turn(self, text):
        """Run one turn; yields events like ChatProvider.stream."""
        raise NotImplementedError
        yield

    async def interrupt(self):
        raise NotImplementedError

    async def close(self):
        pass
