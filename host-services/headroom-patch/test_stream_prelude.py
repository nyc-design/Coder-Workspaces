from __future__ import annotations

import asyncio
import importlib.util
import json
import sys
import types
from pathlib import Path
from types import SimpleNamespace


class FakeAsyncStream:
    def __init__(self, items):
        self._items = list(items)

    def __aiter__(self):
        self._iter = iter(self._items)
        return self

    async def __anext__(self):
        try:
            return next(self._iter)
        except StopIteration as exc:
            raise StopAsyncIteration from exc


class FakeAnyLLMInstance:
    def __init__(self):
        self.response = None
        self.calls = []

    async def acompletion(self, **kwargs):
        self.calls.append(kwargs)
        return self.response


def load_patched_module():
    # anyllm.py uses relative imports from headroom.backends. Provide minimal
    # stand-ins so this smoke test stays dependency-free.
    package = types.ModuleType("headroom")
    backends = types.ModuleType("headroom.backends")
    base = types.ModuleType("headroom.backends.base")

    class Backend:
        pass

    class BackendResponse:
        def __init__(self, body, status_code=200, headers=None, error=None):
            self.body = body
            self.status_code = status_code
            self.headers = headers or {}
            self.error = error

    class StreamEvent:
        def __init__(self, event_type, data, raw_sse=None):
            self.event_type = event_type
            self.data = data
            self.raw_sse = raw_sse

    base.Backend = Backend
    base.BackendResponse = BackendResponse
    base.StreamEvent = StreamEvent
    sys.modules.update({
        "headroom": package,
        "headroom.backends": backends,
        "headroom.backends.base": base,
    })

    path = Path(__file__).with_name("anyllm.py")
    spec = importlib.util.spec_from_file_location("headroom.backends.anyllm", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


async def main() -> None:
    module = load_patched_module()
    fake = FakeAnyLLMInstance()

    class FakeAnyLLM:
        @staticmethod
        def create(provider: str):
            assert provider == "openai"
            return fake

    module.ANYLLM_AVAILABLE = True
    module.AnyLLM = FakeAnyLLM
    backend = module.AnyLLMBackend(provider="openai")
    fake.response = FakeAsyncStream(
        [
            SimpleNamespace(
                model_dump=lambda **_: {
                    "id": "chunk1",
                    "choices": [{"delta": {"content": "hi"}}],
                }
            )
        ]
    )

    chunks = [chunk async for chunk in backend.stream_openai_message({"model": "gpt-4o"}, {})]
    assert len(chunks) == 3
    prelude = json.loads(chunks[0][len("data: "):])
    assert prelude["object"] == "chat.completion.chunk"
    assert prelude["choices"] == [{"index": 0, "delta": {}, "finish_reason": None}]
    assert json.loads(chunks[1][len("data: "):])["choices"][0]["delta"]["content"] == "hi"
    assert chunks[-1] == "data: [DONE]\n\n"


if __name__ == "__main__":
    asyncio.run(main())
