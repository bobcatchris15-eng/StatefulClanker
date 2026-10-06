import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderRack } from '../../ui/worker-rack.ts';

const ws = [
  { id: 'W03', status: 'RUNNING', model: 'glm-flash', current_action: 'editing x.ts' },
  { id: 'W04', status: 'BLOCKED', model: 'm2' },
  { id: 'W05', status: 'COMPLETE', model: 'm3' },
  { id: 'W06', status: 'FAILED', model: 'm4' },
  { id: 'W07', status: 'IDLE', model: 'm5' },
  { id: 'W08', status: 'WAITING', model: 'm6' },
];

test('narrow strips', () => {
  const l = renderRack(ws, 60);
  assert.equal(l[0], 'W03 ● RUN glm-flash  editing x.ts');
  assert.match(l[1]!, /! BLOCK/); assert.match(l[2]!, /✓ DONE/); assert.match(l[3]!, /× FAIL/);
  assert.match(l[4]!, /○ IDLE/); assert.match(l[5]!, /◐ WAIT/);
  assert.ok(l.every((x) => x.length <= 60));
});

test('name shown after id', () => {
  const l = renderRack([{ id: 'W03', display_name: 'Rivet', status: 'RUNNING', model: 'm', current_action: 'x' }], 60);
  assert.equal(l[0], 'W03 Rivet ● RUN m  x');
});

test('wide boxed', () => {
  const l = renderRack(ws, 110);
  assert.equal(l.length, ws.length + 2);
  assert.ok(l.every((x) => x.length === 110));
  assert.ok(l[0]!.startsWith('┌'));
});

test('empty', () => assert.deepEqual(renderRack([], 80), []));
