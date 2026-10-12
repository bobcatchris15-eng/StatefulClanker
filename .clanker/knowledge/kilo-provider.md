---
status: provisional
tags: [providers, models, free-tier]
---

# kilo.ai as a Pi provider (free tier)

Added at human request: `kilo` custom provider in `~/.pi/agent/models.json`,
key stored in `~/.pi/agent/auth.json` under `kilo.key` (note: the field is `key`, **not** `apiKey`;
a probe that read `apiKey` sent `Bearer None` and got a misleading `401 INVALID_TOKEN`).

- Base URL `https://api.kilo.ai/api/openrouter`, `api: "openai-completions"`.
- `/models` does **not** authenticate (returns 200 with a garbage bearer) — never treat a 200 from
  `/models` as proof the key works. Probe `chat/completions` instead.
- Responses are OpenRouter-shaped: reasoning arrives as `message.reasoning` +
  `message.reasoning_details`, not `reasoning_content`. A low `max_tokens` yields
  `content: null` because reasoning eats the budget.
- Verified working (live 200, real content): `kilo-auto/free`, `nvidia/nemotron-3-ultra-550b-a55b:free`,
  `poolside/laguna-s-2.1:free`. Free tier ids otherwise present but thin: `openrouter/free`,
  `lfm-2.5-2.6b`, `laguna-xs`, `north-mini-code`, `nemotron-3{,.5-lightning}-super/omni`.
- `thinkingmachines/inkling-small:free` is **daily rate limited** (`429 limit_rpd`) — treat as
  occasional-only, do not select it as a default.
- `models.json` is loaded at Pi startup; new models only enter the Clanker candidate pool after a
  session restart. Ability profiles were recorded in `.statefulclanker/profiles.json` meanwhile.

Related: [[external-agent-pools]], [[evidence-discipline]].