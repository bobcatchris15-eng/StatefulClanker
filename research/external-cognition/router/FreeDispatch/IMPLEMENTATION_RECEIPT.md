# FreeDispatch implementation receipt

Date: 2026-10-01. This is a research-only dispatcher referencing the existing `src/StatefulClanker.Router` project. No production router files were changed. No daemon was started, no live inference request was made by this implementation task, and no package or provider framework was added.

## Verification

Command:

```powershell
dotnet run --project research\external-cognition\router\FreeDispatch\tests\FreeDispatch.Tests.csproj --no-restore
```

Result: 11 fake-handler self-tests passed. Coverage includes exact request/response persistence, content preservation, API-key non-disclosure, catalog price and Kilo free-flag checks, free-model suffix enforcement, origin checks before credential resolution, redirects disabled, no retry after redirect or transport failure, 90–300 second timeout validation, response-body acquisition cancellation, and no writes into the router root or an existing output directory.

The existing connection IDs `Kilo Free` and `OpenRouter` were checked against the configured dictionary keys without displaying credential values. The current research allowlist files for `gemma`, `laguna`, `liquid`, `nemotron`, and `north` were checked offline against their pinned catalogs; each selected row has the `:free` suffix and zero prompt/completion prices, and the Kilo rows also carry `isFree: true`.

## Source dependency hashes

SHA-256 hashes at receipt time:

| File | SHA-256 |
|---|---|
| `FreeDispatch.csproj` | `22a3fb7b46514ca08ce6526f4e4ad2bcd33c978dd798a720d0b3350702e1e9d9` |
| `Program.cs` | `a1eee8ce9748d7477f98be6611aed231d3c64f67ba0677dd0281ac124b5cffcb` |
| `tests/FreeDispatch.Tests.csproj` | `3e2fe346573bd0cc6efa6617f62392e6c2800a7fcadd11cf361d8a46268c43c3` |
| `tests/Program.cs` | `8088640eb2b938a50b7fff88c1eb741673a1c067d0df06d8d42677982e8c1ddb` |
| `README.md` | `87b59ee575ed0e6ae3427d96bb78968f8f4bfb1974b53fe5ecafe6c904f8a67a` |
| `src/StatefulClanker.Router/StatefulClanker.Router.csproj` | `a431c64b2ba91fe8b9772a5505fc8b2cbe1ad13a8161889bceb8a3a079b0f3c0` |
| `src/StatefulClanker.Router/RouterStore.cs` | `ed5bd6d8506e17670245568807c8d7b9aab1e9a571e80ca1cdea4a460e7e6cf4` |
| `src/StatefulClanker.Router/Models.cs` | `9d08c2931b4fb7c8ee386fa3990fc098a2b2367d913e6ae6bf91c54c6d8c135e` |
| `src/StatefulClanker.Router/Inference/InferenceModels.cs` | `86cea2ce5e623892f9b94bde3428581d93120e7bcaf33e02a7f7af453135f00d` |
| `src/StatefulClanker.Router/Inference/ConnectionCredentialResolver.cs` | `d6d6f977bca25d9a263f43ffe674dccc940ec53385a68b6086ef393304f6d51b` |
| `src/StatefulClanker.Router/Inference/ProviderAdapterRegistry.cs` | `47d4ae2721d148552ab75707c6bc9631c27fe3229b95db501496f788bc5f0cf9` |
| `src/StatefulClanker.Router/Inference/Adapters/OpenAiChatAdapter.cs` | `4884dd2b24aebe821318eea38112b46728780d4ecce13f576f484ed6e8afa3b4` |

The live CLI uses one selected allowlist, a single `NormalizedInferenceRequest`, the matching registered adapter, and exactly one `HttpClient.SendAsync`. The resolved credential exists only in process memory. Request header values are never persisted; response bodies are captured before adapter parsing. Every invocation returns a small receipt and does not select another model or assess semantic correctness.
