import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { appendEvent, readEvents } from '../../protocol/events.ts';
import { listActiveIntent, recordIntent } from '../../project/intent.ts';
import { createTask, getTask, updateTask } from '../../project/tasks.ts';
import { scDir } from '../../project/paths.ts';
import { allocateWorkerId } from '../../workers/registry.ts';

const tmp = () => mkdtempSync(join(tmpdir(), 'sc-'));

test('intent supersede', () => {
  const r = tmp();
  const a = recordIntent(r, { statement: 'a', source: 'u', scope: 'p' });
  const b = recordIntent(r, { statement: 'b', source: 'u', scope: 'p', supersedes: [a.id] });
  assert.deepEqual(listActiveIntent(r).map((i) => i.id), [b.id]);
});

test('task status move', () => {
  const r = tmp();
  const t = createTask(r, { title: 't', objective: 'o' });
  assert.equal(t.id, 't-0001');
  updateTask(r, t.id, { status: 'complete' });
  assert.ok(existsSync(join(scDir(r), 'tasks', 'complete', 't-0001.json')));
  assert.ok(!existsSync(join(scDir(r), 'tasks', 'active', 't-0001.json')));
  updateTask(r, t.id, { status: 'cancelled' });
  assert.ok(existsSync(join(scDir(r), 'tasks', 'cancelled', 't-0001.json')));
  assert.equal(getTask(r, t.id)?.status, 'cancelled');
  assert.equal(createTask(r, { title: 'x', objective: 'y' }).id, 't-0002');
});

test('worker id allocation', () => {
  const r = tmp();
  assert.equal(allocateWorkerId(r), 'W01');
  assert.equal(allocateWorkerId(r), 'W02');
});

test('event append/read', () => {
  const r = tmp();
  appendEvent(r, 'a', { x: 1 });
  appendEvent(r, 'b', { x: 2 });
  assert.equal(readEvents(r).length, 2);
  assert.equal(readEvents(r, { types: ['b'] }).length, 1);
});
