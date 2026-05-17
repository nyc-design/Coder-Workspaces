# Headroom stream prelude patch

`anyllm.py` is a patched copy of upstream
`headroom/backends/anyllm.py` from `chopratejas/headroom` commit
`6d62985b73b4a9e50d13ee9fc3df4b62bcba1c14`.

The only runtime change is in `AnyLLMBackend.stream_openai_message()`:
OpenAI-format streaming responses emit one immediate empty
`chat.completion.chunk` before opening the upstream request.

This prevents Coder chatd's hard-coded 60s stream-startup guard from canceling
and retrying long Claude Code / Meridian / OmniRoute requests while preserving
the real provider stream unchanged.
