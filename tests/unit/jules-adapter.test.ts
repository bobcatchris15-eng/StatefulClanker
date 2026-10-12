/**
 * Jules cloud adapter unit tests.
 *
 * Scope: argv construction per phase, session-id extraction, and the "cloud run finished" predicate.
 * No network, no CLI: the adapter is pure argv + pure parsing by design.
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  formatJulesSessionRow,
  julesAdapter,
  julesPhase,
  julesSessionFinished,
  julesVersionArgs,
  sessionIdFromJulesText,
} from '../../pools/jules.ts';
import type { ExternalWorkerSpec } from '../../pools/types.ts';

function spec(over: Partial<ExternalWorkerSpec> = {}): ExternalWorkerSpec {
  return {
    id: 'j1',
    pool: 'jules',
    status: 'queued',
    assignment: 'Fix the flaky test',
    ...over,
  };
}

test('jules is a cloud pool with no caller-supplied session switch', () => {
  assert.equal(julesAdapter.kind, 'cloud');
  assert.equal(julesAdapter.allocatesSession, false);
  assert.equal(julesAdapter.command, 'jules');
});

test('version probe uses --help because jules has no --version flag', () => {
  assert.deepEqual(julesVersionArgs, ['--help']);
});

test('dispatch: jules new <prompt>, repo inferred, no session flag', () => {
  const args = julesAdapter.buildArgs(spec());
  assert.deepEqual(args, ['new', 'Fix the flaky test']);
  assert.equal(args.includes('--session'), false);
});

test('dispatch: explicit repo wins over cwd inference', () => {
  const args = julesAdapter.buildArgs(spec({ repo: 'bobcatchris15-eng/StatefulClanker' }));
  assert.deepEqual(args, ['new', '--repo', 'bobcatchris15-eng/StatefulClanker', 'Fix the flaky test']);
});

test('dispatch: a bare repo path is not passed to --repo (needs owner/name)', () => {
  const args = julesAdapter.buildArgs(spec({ repo: 'E:/StatefulClanker' }));
  assert.equal(args.includes('--repo'), false);
});

test('dispatch: --parallel is clamped to 1..5 and omitted at 1', () => {
  assert.equal(julesAdapter.buildArgs(spec({ metadata: { parallel: 1 } })).includes('--parallel'), false);
  assert.deepEqual(julesAdapter.buildArgs(spec({ metadata: { parallel: 3 } })).slice(0, 3), [
    'new',
    '--parallel',
    '3',
  ]);
  assert.equal(julesAdapter.buildArgs(spec({ metadata: { parallel: 99 } })).includes('5'), true);
});

test('status phase lists sessions', () => {
  const s = spec({ metadata: { phase: 'status' }, externalSessionId: '123456' });
  assert.deepEqual(julesAdapter.buildArgs(s), ['remote', 'list', '--session']);
  assert.equal(julesPhase(s), 'status');
});

test('pull applies the patch by default; apply:false previews without writing', () => {
  const s = spec({ metadata: { phase: 'pull' }, externalSessionId: '123456' });
  assert.deepEqual(julesAdapter.buildArgs(s), ['remote', 'pull', '--session', '123456', '--apply']);
  const preview = spec({ metadata: { phase: 'pull', apply: false }, externalSessionId: '123456' });
  assert.deepEqual(julesAdapter.buildArgs(preview), ['remote', 'pull', '--session', '123456']);
});

test('non-dispatch phases without a session id throw instead of emitting broken argv', () => {
  assert.throws(() => julesAdapter.buildArgs(spec({ metadata: { phase: 'pull' } })), /session id/);
});

test('session id extraction covers the shapes the CLI actually prints', () => {
  assert.equal(sessionIdFromJulesText('{"sessionId":"abc-123"}'), 'abc-123');
  assert.equal(sessionIdFromJulesText('Session 12345678 — in progress'), '12345678');
  assert.equal(sessionIdFromJulesText('id: 987654321'), '987654321');
  assert.equal(sessionIdFromJulesText('nothing here'), undefined);
});

test('session row rendering is compact and parseable', () => {
  assert.equal(formatJulesSessionRow('Session 12345678 — in_progress'), '12345678 · in_progress');
});

test('parseLine surfaces a session event so the registry can record the id', () => {
  const parsed = julesAdapter.parseLine('{"sessionId":"zz-9"}');
  assert.equal(parsed.sessionId, 'zz-9');
  assert.equal(parsed.kind, 'progress');
  assert.deepEqual(julesAdapter.parseLine('   '), { text: '' });
});

test('finished predicate recognizes terminal and non-terminal states', () => {
  assert.equal(julesSessionFinished('session completed'), true);
  assert.equal(julesSessionFinished('state: FAILED'), true);
  assert.equal(julesSessionFinished('in_progress'), false);
  assert.equal(julesSessionFinished('queued'), false);
});

test('unknown phase degrades to dispatch rather than throwing', () => {
  const s = spec({ metadata: { phase: 'weird' } });
  assert.equal(julesPhase(s), 'dispatch');
  assert.deepEqual(julesAdapter.buildArgs(s), ['new', 'Fix the flaky test']);
});