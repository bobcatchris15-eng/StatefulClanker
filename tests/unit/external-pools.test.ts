import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { OpenCodeServer } from '../../pools/opencode-server.ts';
import { JulesRest, julesStatus } from '../../pools/jules-rest.ts';
import { PoolStore } from '../../pools/store.ts';
import { ExternalPoolManager } from '../../pools/manager.ts';

test('OpenCode V2 admits prompts durably, selects native client model and inspects completed turns', async () => {
  const prev = process.env.OPENCODE_SERVER_URL;
  const prevPass = process.env.OPENCODE_SERVER_PASSWORD;
  process.env.OPENCODE_SERVER_URL = 'http://127.0.0.1:8098';
  process.env.OPENCODE_SERVER_PASSWORD = 'fixture-password';
  const calls: Array<{ path: string; method: string; body: any; auth: string | null }> = [];
  let phase = 0;
  const send = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(String(input));
    const method = init?.method ?? 'GET';
    const body = init?.body ? JSON.parse(String(init.body)) : null;
    const headers = new Headers(init?.headers);
    calls.push({ path: url.pathname, method, body, auth: headers.get('authorization') });
    if (url.pathname === '/api/session' && method === 'GET') return Response.json({ data: [] });
    if (url.pathname === '/api/session' && method === 'POST') {
      assert.equal(body.agent, 'build');
      assert.ok(body.location.directory);
      return Response.json({ data: { id: 'ses-test' } });
    }
    if (url.pathname === '/api/session/ses-test/model') return Response.json({});
    if (url.pathname === '/api/session/ses-test/message') {
      return Response.json({ data: phase > 0 ? [
        ...(phase > 1 ? [{ id: 'msg-finished', type: 'assistant', finish: 'stop',
          time: { created: 5, completed: 6 },
          content: [{ type: 'text', text: 'I edited the files' }],
          snapshot: { files: ['src/example.ts'] } }] : []),
        { id: 'msg-intermediate', type: 'assistant', finish: 'tool-calls',
          time: { created: 2, completed: 3 },
          content: [{ type: 'text', text: "I'll read the file first" }] },
        { id: 'msg-user', type: 'user', text: 'do work', time: { created: 1 } },
      ] : [] });
    }
    if (url.pathname === '/api/session/ses-test/prompt') {
      phase = 1;
      return Response.json({ data: { id: 'msg-prompt', sessionID: 'ses-test', admittedSeq: 1 } });
    }
    if (url.pathname === '/api/session/ses-test/permission') return Response.json({ data: [] });
    if (url.pathname === '/api/session/ses-test/interrupt') return new Response(null, { status: 204 });
    return new Response('missing ' + url.pathname, { status: 404 });
  }) as typeof fetch;
  const server = new OpenCodeServer(process.cwd(), send);
  try {
    const session = await server.create('fix files');
    assert.equal(session, 'ses-test');
    assert.equal(await server.submit(session, 'implement change', 'opencode-go/qwen3.8-flash'), 0);
    const partial = await server.inspect(session, 0);
    assert.equal(partial.status, 'running', 'assistant tool-call step must not complete the job');
    assert.equal(partial.completed, undefined);
    phase = 2;
    const result = await server.inspect(session, 0);
    assert.equal(result.status, 'succeeded');
    assert.match(result.text ?? '', /edited/);
    assert.deepEqual(await server.diff(session), ['src/example.ts']);
    assert.equal(await server.steer(session, 'add tests'), 3);
    await server.abort(session);
    assert.ok(calls.some(c => c.path.endsWith('/prompt') && c.body.text === 'add tests' && c.body.delivery === 'queue'));
    assert.ok(calls.some(c => c.path.endsWith('/model') && c.body.model.id === 'qwen3.8-flash'));
    assert.ok(calls.every(c => c.auth?.startsWith('Basic ')));
    assert.ok(!calls.some(c => c.path.endsWith('/prompt_async')));
  } finally {
    server.dispose();
    if (prev === undefined) delete process.env.OPENCODE_SERVER_URL;
    else process.env.OPENCODE_SERVER_URL = prev;
    if (prevPass === undefined) delete process.env.OPENCODE_SERVER_PASSWORD;
    else process.env.OPENCODE_SERVER_PASSWORD = prevPass;
  }
});

test('Jules REST locates connected GitHub source, starts task, steers session and collects patch', async () => {
  const paths: string[] = [];
  const send = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(String(input));
    paths.push((init?.method ?? 'GET') + ' ' + url.pathname);
    assert.equal(new Headers(init?.headers).get('x-goog-api-key'), 'test-key');
    if (url.pathname === '/v1alpha/sources') return Response.json({
      sources: [{ name: 'sources/github-owner-repo', githubRepo: { owner: 'owner', repo: 'repo' } }],
    });
    if (url.pathname === '/v1alpha/sessions' && init?.method === 'POST') {
      const body = JSON.parse(String(init.body));
      assert.equal(body.sourceContext.source, 'sources/github-owner-repo');
      assert.equal(body.sourceContext.githubRepoContext.startingBranch, 'develop');
      // Real Jules API may omit state on creation; the supervisor must persist name first.
      return Response.json({ name: 'sessions/12345', url: 'https://jules.google.com/session/12345' });
    }
    if (url.pathname === '/v1alpha/sessions/12345' && (init?.method ?? 'GET') === 'GET') return Response.json({
      name: 'sessions/12345', state: 'COMPLETED', outputs: [],
    });
    if (url.pathname === '/v1alpha/sessions/12345/activities') return Response.json({
      activities: [{ agentMessaged: { agentMessage: 'Change ready' }, artifacts: [
        { changeSet: { gitPatch: { baseCommitId: 'abc', unidiffPatch: 'diff --git a/a b/a\\n' } } },
      ] }],
    });
    if (url.pathname.endsWith(':sendMessage')) return Response.json({});
    return new Response('missing', { status: 404 });
  }) as typeof fetch;
  const api = new JulesRest('test-key', send);
  const job: any = { id: 'j-test', pool: 'jules', status: 'starting', assignment: 'implement this',
    repo: 'owner/repo', metadata: { branch: 'develop' } };
  const session = await api.create(job);
  assert.equal(session.name, 'sessions/12345');
  assert.equal(session.state, undefined);
  assert.equal(julesStatus(session.state), 'queued');
  assert.equal(julesStatus('AWAITING_PLAN_APPROVAL'), 'waiting_input');
  assert.equal(julesStatus('IN_PROGRESS'), 'running');
  await api.sendMessage(session.name, 'Please add tests');
  const result = await api.collect(session.name);
  assert.equal(result.patches[0]?.baseCommitId, 'abc');
  assert.deepEqual(result.notes, ['Change ready']);
  assert.ok(paths.includes('POST /v1alpha/sessions/12345:sendMessage'));
});

test('PoolStore persists snapshots and reads in-progress jobs for restart recovery', async () => {
  const root = mkdtempSync(join(tmpdir(), 'sc-external-'));
  try {
    const store = new PoolStore({ cwd: root });
    await store.save({ id: 'x-opencode-1', pool: 'opencode', status: 'running',
      assignment: 'fix test', externalSessionId: 'ses123' });
    assert.equal((await store.list()).length, 1);
    assert.equal((await store.readStale())[0]?.externalSessionId, 'ses123');
    await store.save({ id: 'x-opencode-1', pool: 'opencode', status: 'succeeded',
      assignment: 'fix test', externalSessionId: 'ses123' });
    assert.equal((await store.readStale()).length, 0);
  } finally { rmSync(root, { recursive: true, force: true }); }
});


test('Jules manager persists remote ID before state interpretation and restores the same job after reboot', async () => {
  const root = mkdtempSync(join(tmpdir(), 'sc-jules-create-'));
  const store = new PoolStore({ cwd: root });
  let creates = 0;
  const fakeJules: any = {
    configured: true,
    create: async () => { creates++; return { name: 'sessions/987654' }; },
    get: async () => ({ name: 'sessions/987654', state: 'IN_PROGRESS' }),
    collect: async () => ({ session: { name: 'sessions/987654', state: 'COMPLETED' }, patches: [], notes: ['done'] }),
  };
  const m = new ExternalPoolManager(root, { jules: fakeJules, store });
  try {
    await m.start();
    const job = await m.launch({ pool: 'jules', assignment: 'Read a test', source: 'sources/github/example/repo' });
    assert.equal(job.externalSessionId, 'sessions/987654');
    assert.equal(job.status, 'running');
    await m.stop();
    const restarted = new ExternalPoolManager(root, { jules: fakeJules, store });
    try {
      await restarted.start();
      assert.equal(restarted.get(job.id).externalSessionId, 'sessions/987654');
      assert.equal(creates, 1, 'restart cannot duplicate the remote task');
    } finally { await restarted.stop(); }
  } finally {
    await m.stop();
    rmSync(root, { recursive: true, force: true });
  }
});
