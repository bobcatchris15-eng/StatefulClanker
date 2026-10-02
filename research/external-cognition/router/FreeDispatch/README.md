# FreeDispatch research harness

`FreeDispatch` is an isolated, one-request dispatcher for the Lab 4 router experiment. It references the existing `StatefulClanker.Router` assembly and directly uses `RouterStore.LoadConnections`, `ConnectionCredentialResolver.ResolveKey`, and the registered provider adapter's `BuildRequest`/`ParseSuccess` methods. It does not start the router daemon, read or write endpoint/routing state, modify production configuration, or add a provider framework.

The live path explicitly reads connections from `%LOCALAPPDATA%\StatefulClanker`, regardless of `SC_ROUTER_ROOT`. It refuses to instantiate the store unless the existing `routing` directory is already present, because `RouterStore` creates that directory in its constructor. The output directory must be outside this root and empty. API credentials remain in memory and are supplied only to the existing adapter; no header values or exception messages are written to disk or printed.

## Build and fake-network tests

Run the focused tests without a live provider:

```powershell
dotnet run --project research\external-cognition\router\FreeDispatch\tests\FreeDispatch.Tests.csproj
```

The test console uses a fake `HttpMessageHandler` and temporary router profiles. It exercises catalog gating, origin-before-credential ordering, redirect and transport failures, one-send behavior, request/response preservation, and bounded body-read cancellation. No test sends an external request.

## Inputs and allowlist

The CLI accepts a router `NormalizedInferenceRequest` JSON file and a single-target allowlist JSON file. The request uses the router's normal camelCase fields, for example:

```json
{
  "messages": [{"role": "user", "content": "one bounded prompt"}],
  "tools": [],
  "toolMode": "text",
  "maxOutputTokens": 512,
  "temperature": 0,
  "timeoutSeconds": 120
}
```

The allowlist v1 schema is:

```json
{
  "schema_version": 1,
  "provider": "kilo-free",
  "connection_id": "Kilo Free",
  "endpoint_id": "research-example",
  "model": "provider/model:free",
  "base_url": "https://api.kilo.ai/api/gateway",
  "catalog_path": "..\\kilo-free-catalog.json",
  "catalog_sha256": "<sha256 of the exact frozen catalog bytes>"
}
```

Supported provider/origin pairs are exactly `openrouter` / `https://openrouter.ai/api/v1` and `kilo-free` / `https://api.kilo.ai/api/gateway`. The connection's configured base URL must match the selected origin. The model must end in `:free`, match a row in the pinned catalog whose prompt and completion prices both parse to zero, and Kilo rows must also have `isFree: true`. The catalog's discovery URL and its SHA-256 are checked. A selected model or origin that fails these checks is rejected before credential resolution and before any request is sent.

## Invocation and slot behavior

```powershell
dotnet run --project research\external-cognition\router\FreeDispatch\FreeDispatch.csproj -- `
  dispatch --request request.json --allowlist allowlist.json --out-dir runs\free\slot-01 --timeout-seconds 120
```

The timeout must be from 90 through 300 seconds. Each invocation sends at most one HTTP request. Redirects are disabled, there are no retries or fallback routes, and any attempted send—including timeout, non-success status, invalid response or provider error—consumes the caller's slot. The same output directory cannot be reused. A request or catalog rejected before send also returns a failure receipt; do not silently swap a model or repeat the slot with a different target.

Before sending, the harness saves exact input bytes and the adapter-built request body. Request metadata stores header names only. It saves the complete HTTP response body and a small safe-header allowlist before calling the registered adapter parser. Successful text content is written byte-for-byte as UTF-8 to `content.raw`; reasoning fields are never separately forwarded or substituted. Missing usage remains unreported rather than being recorded as zero. Receipt and failure records omit exception details to prevent secret leakage.

Each output slot directory uses these artifacts:

```text
input.request.json
input.allowlist.json
input.catalog.json
request.body.raw
request.metadata.json
response.body.raw                 # after an HTTP response, including HTTP errors
response.metadata.json            # status and allowlisted safe headers
content.raw                        # only when the adapter yields text successfully
receipt.json
```

All artifacts are write-once. The receipt distinguishes `sent` from pre-send validation failure and reports provider/connection/endpoint/model IDs, request/response/content hashes, HTTP status, usage, returned model, finish reason, provider-error status, adapter success, and elapsed time. It does not evaluate answer correctness.
