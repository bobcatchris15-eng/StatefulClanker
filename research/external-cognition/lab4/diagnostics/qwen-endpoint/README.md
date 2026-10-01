# Direct endpoint diagnostics

On user instruction, the coordinator stopped the first local campaign and tested the exact registered Qwen9B through Lemonade. No coordinator changes to Lemonade settings were needed.

| Request | Output | Observed wall time |
|---|---|---|
| 01, max_tokens=16 | READY | See 01.meta.json (about 2 seconds) |
| 02, max_tokens=32 | {"ok":true} | 2.67 seconds |
| 03, concurrent pair | ALPHA | 2.43 seconds |
| 04, concurrent pair | BETA | 4.55 seconds |

Exact requests, full returned JSON and timing/usage metadata are retained. The pair took 4.55 seconds overall; timings are consistent with serialized backend execution despite concurrent client requests. This is an operational observation, not proof of scheduler architecture. All requests returned HTTP 200 and finish_reason stop. Model response alias qwen3.5:9b matches the registered qwen3.5-9b-FLM checkpoint.

The experiment's longer returned reviews reported about 8.3 tokens/second for decoding, making a 4096-token ceiling incompatible with a reliable 300-second bound if used fully. Actual time also includes prefill, queuing and server overhead. Context 70728 remained loaded. These diagnostics test transport/output handling, not cooperative reasoning or mathematical accuracy.

Lemonade's [OpenAI-compatible API](https://lemonade-server.ai/docs/api/openai/) documents chat completions; the [management API](https://lemonade-server.ai/docs/api/lemonade/) documents per-model context/load settings. The installed version is 11.9.0 and uses /api/v1 locally.
