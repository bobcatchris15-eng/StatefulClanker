import { test } from 'node:test';
import assert from 'node:assert/strict';
import { claimLoad, LOADED_KEY } from '../../index.ts';

test('double-load guard: first claim wins, second is refused', () => {
  const g: Record<symbol, unknown> = {};
  assert.equal(claimLoad(g), true);
  assert.equal(g[LOADED_KEY], true);
  assert.equal(claimLoad(g), false);
});
