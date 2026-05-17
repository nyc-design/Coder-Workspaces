---
name: signoz
description: Investigate traces, logs, and metrics from OpenTelemetry-instrumented services via the SigNoz MCP. Invoke when the user reports a perf regression, a backend error, or a flaky request flow in a project that emits OTel telemetry to SigNoz.
---

# SigNoz observability (MCP-only)

SigNoz is the OpenTelemetry backend for projects that emit traces,
logs, and metrics. It is the one observability tool we expose only via
MCP (no CLI equivalent).

## When to invoke

- The user reports a slow endpoint, a 5xx burst, or an error they saw
  in production / staging.
- You need to confirm whether a recent deploy changed latency or error
  rate for a specific service.
- You're tracing a multi-service request flow and need the actual span
  graph instead of guessing from code.

Don't invoke for projects that don't emit to SigNoz — check
`CLAUDE.md` / the repo's OTel config first.

## Recommended call order

1. `list_services` — confirm the service name matches what you expect
   (services often have a deploy-env suffix, e.g. `api-prod`).
2. `search_traces_by_service` — narrow by service + time window +
   optional operation / status filters.
3. `get_error_logs` — when traces point at a failed span, fetch the
   matching error logs for stack traces and exception messages.

Drill from service → trace → span → log, not the other way around;
log-first searches are usually too noisy to be useful.

## Pair with

- `agentmemory-remember` — save non-obvious findings (e.g. "this 5xx
  spike was caused by X, not Y as initially suspected") so the next
  agent doesn't redo the investigation.
