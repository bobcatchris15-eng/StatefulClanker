# Per-pool supervisor pane rendering

`ui/pool-pane.ts` renders the three external worker pools (`opencode`, `agy`, `jules`) as static boxed panes; native Pi workers keep the animated lamp rack in `ui/worker-rack.ts`. Single operator entry point: `renderSplitPanes(native, pools, width, opts)`.

Verified by `npx tsx --test tests/unit/pool-pane.test.ts` (15 pass) and `npm run typecheck` (clean) at commit 87ea412.

## Contract worth reusing

- Glyph map is exported: `POOL_GLYPHS` (`queued ·`, `starting ◌`, `running ▶`, `waiting_input ?`, `succeeded ✓`, `failed ✗`, `cancelled —`, `unknown ~`) plus `POOL_TOKENS` theme tokens.
- `externalPoolIds()` = `["opencode","agy","jules"]` — stable order; do not duplicate the list in `operator.ts`.
- `allocateColumnWidths(naturals, width, min)` is deterministic: proportional, clamped to `[24, floor(width/n)]`, remainder to widest column, separators counted. No `Math.random`/`Date.now`.
- Degradation rule: if `width < 24*n + (n-1)` the split **stacks vertically** in order native, opencode, agy, jules at full width.
- `native` may be `null`; external columns then start at column 0.

## Gotcha: width helpers

`ui/worker-rack.ts` keeps its `clip`/`pad` helpers **private** (not exported) and reuses `truncateToWidth`/`visibleWidth` from `@earendil-works/pi-tui`. `pool-pane.ts` therefore exports its own ANSI/wide-char-aware `clipToWidth`. If worker-rack ever exports one, import it instead of keeping two copies. See [[external-agent-pools]].
