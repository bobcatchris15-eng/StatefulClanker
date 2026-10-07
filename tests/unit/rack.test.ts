import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BlinkenState, LAMPS, renderRack } from '../../ui/worker-rack.ts';

const ws = [
  { id: 'W03', status: 'RUNNING', provider: 'openrouter', model: 'glm-flash', role: 'implement', current_action: 'editing x.ts' },
  { id: 'W04', status: 'BLOCKED', model: 'm2' },
  { id: 'W05', status: 'COMPLETE', model: 'm3' },
];

test('Pi events pulse real lamps and expire', () => {
  const b = new BlinkenState(100);
  b.ingest('W03', { type: 'message_update' }, 1000);
  let s = b.snapshot('W03', 1050);
  assert.equal(s.ACT, true);
  assert.equal(s.GEN, true);
  assert.equal(s.TOL, false);
  s = b.snapshot('W03', 1101);
  assert.ok(LAMPS.every((l) => s[l] === false));
});

test('tool events classify tool, test and git/file activity', () => {
  const b = new BlinkenState(100);
  b.ingest('W03', { type: 'tool_execution_start', toolName: 'bash', args: { command: 'npm test && git status' } }, 1000);
  const s = b.snapshot('W03', 1050);
  assert.equal(s.ACT, true);
  assert.equal(s.TOL, true);
  assert.equal(s.TST, true);
  assert.equal(s.GIT, true);

  b.ingest('W04', { type: 'tool_execution_start', toolName: 'edit', args: {} }, 1000);
  assert.equal(b.snapshot('W04', 1050).GIT, true);
});

test('explicit transfers light TX and RX', () => {
  const b = new BlinkenState(100);
  b.transfer('CLANKER', 'W03', 1000);
  assert.equal(b.snapshot('CLANKER', 1050).TX, true);
  assert.equal(b.snapshot('W03', 1050).RX, true);
});

test('narrow rack keeps one live strip per participant', () => {
  const b = new BlinkenState(100);
  b.pulse('W03', 'ACT', 1000);
  const l = renderRack(ws, 60, b, undefined, 1050);
  assert.equal(l.length, ws.length);
  assert.ok(l[0]!.startsWith('W03'));
  assert.match(l[0]!, /■/);
  assert.match(l[0]!, /● RUN/);
  assert.match(l[1]!, /! BLOCK/);
  assert.ok(l.every((x) => x.length <= 60));
});

test('wide rack renders parent worker-zero and boxed blinken panels', () => {
  const b = new BlinkenState(100);
  b.transfer('CLANKER', 'W03', 1000);
  const parent = { id: 'CLANKER', status: 'RUNNING', provider: 'openai', model: 'parent-model', role: 'operator' };
  const l = renderRack([ws[0]!], 80, b, parent, 1050);
  assert.ok(l[0]!.includes('CLANKER'));
  assert.ok(l.some((x) => x.includes('ACT GEN TOL TX RX TST GIT ERR')));
  assert.ok(l.some((x) => x.includes('W03')));
  assert.ok(l.some((x) => x.includes('■')));
});

test('name shown in panel title', () => {
  const l = renderRack([{ id: 'W03', display_name: 'Rivet', status: 'RUNNING', model: 'm', current_action: 'x' }], 80);
  assert.ok(l[0]!.includes('W03 Rivet'));
});

test('empty without parent', () => assert.deepEqual(renderRack([], 80), []));
