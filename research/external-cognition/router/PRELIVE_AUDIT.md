# FreeDispatch prelive audit

## Finding

The research-only dispatcher is ready for bounded setup probes under the frozen allowlists. This approval is limited to the transport dispatcher; it does not approve the separate experimental harness or a broader campaign. I made no provider inference request and changed no production or live router configuration.

## What I checked

- The four allowlist entries select only the exact OpenRouter or Kilo Free base origin; all four model IDs end in `:free`. The allowlist-pinned SHA-256 values match the current catalog bytes: OpenRouter `3bfb0f214a25f4aff6e696440f60ddce6211d0217995549e439776c008e2a0ff`, Kilo `91b0f8dd6199ab37f6a27642ca7e70ae453dd704001c2f7eaf8a04f7da0f9167`.
- Source checks allowlist provider/origin/model suffix, catalog hash, exact catalog model row and zero prompt/completion pricing (plus Kilo's explicit `isFree=true`) before loading the credential. The loaded connection origin must also match the provider origin. The dispatcher resolves the installed router connection through `RouterStore.LoadConnections` and `ConnectionCredentialResolver.ResolveKey`, then uses `ProviderAdapterRegistry` and the registered OpenAI Chat adapter. It does not change the router source or machine connection file.
- The built URI is constrained to the expected HTTPS host, port, and `/chat/completions` path. The live handler disables automatic redirects; the dispatch method contains one `SendAsync` call and no retry/failover loop.
- The exact outgoing adapter body is create-new persisted before send. The complete response body bytes (or received partial bytes on body-read failure) are persisted unchanged with a hash and completeness flag; extracted assistant content is separately stored byte-for-byte. Metadata saves header names and a safe response-header allowlist, not request header values. Generic exception text is not written to artifacts.
- The linked request deadline is passed to both `SendAsync` and response-body acquisition/read. Timeout, transport, HTTP, provider, and parse outcomes become failure receipts without retries. The body-acquisition cancellation regression and unsafe-output-path checks are included.
- Output under the router root and a nonempty output directory now fail in memory without writing there. Other artifact writes use `FileMode.CreateNew`, preserving existing files. The output-path containment check is lexical (`Path.GetFullPath`); it does not resolve Windows junction/symlink targets. The approved probe runner should use a direct, non-linked research output directory outside the router root.

## Verification

Offline fake-network dispatcher tests passed 9/9 with:

```powershell
dotnet run --project research/external-cognition/router/FreeDispatch/tests/FreeDispatch.Tests.csproj
```

The CLI help and invalid-command paths also returned the documented usage and a redacted `sent:false` failure receipt. No provider endpoint was contacted.

## Boundary

The fake-network suite supports the one-send, no-redirect, raw-body, credential-redaction, free-catalog/origin, timeout, and no-write failure properties. It does not validate provider account access, live free quota, endpoint-specific response behavior, or the in-progress campaign harness. Setup probes remain separate evidence and should be stopped on any price/origin discrepancy or paid fallback.
