// No model calls. Isolated config/data/cache/state; leaves fixture and OpenAPI evidence in temp.
// Usage: node docs/research/opencode-headless-probe.mjs <native-opencode.exe> [receipt.json]
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { randomBytes } from 'node:crypto';
import assert from 'node:assert/strict';

const executable = resolve(process.argv[2]);
const root = realpathSync(mkdtempSync(join(tmpdir(), 'sc-opencode-headless-')));
const git = (...args) => execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', windowsHide: true }).trim();
git('init', '-q'); git('config', 'user.name', 'Headless Probe'); git('config', 'user.email', 'probe@example.invalid');
writeFileSync(join(root, 'tracked.txt'), 'committed baseline\n');
git('add', 'tracked.txt'); git('commit', '-qm', 'probe baseline');
writeFileSync(join(root, 'tracked.txt'), 'parent dirty file\n');
writeFileSync(join(root, 'untracked.txt'), 'parent untracked file\n');
const password = randomBytes(24).toString('hex');
const config = { autoupdate: false, share: 'disabled', snapshot: false, enabled_providers: ['opencode'],
  permission: { '*': 'deny', read: 'allow' } };
const env = { ...process.env, OPENCODE_SERVER_PASSWORD: password,
  OPENCODE_CONFIG_CONTENT: JSON.stringify(config),
  XDG_DATA_HOME: join(root, 'data'), XDG_CONFIG_HOME: join(root, 'config'),
  XDG_CACHE_HOME: join(root, 'cache'), XDG_STATE_HOME: join(root, 'state') };
// Do not inherit custom configuration directories from the operator.
delete env.OPENCODE_CONFIG; delete env.OPENCODE_CONFIG_DIR;
const headers = { Authorization: 'Basic ' + Buffer.from('opencode:' + password).toString('base64') };
let child, base;
async function stop() {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise(resolveExit => child.once('exit', resolveExit));
  child.kill();
  await exited;
}
async function start() {
  let logs = ''; base = undefined;
  child = spawn(executable, ['serve', '--pure', '--hostname', '127.0.0.1', '--port', '0'],
    { cwd: root, env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  let error;
  child.on('error', e => { error = e; });
  child.stdout.on('data', data => {
    logs += data;
    base = logs.match(/https?:\/\/127\.0\.0\.1:\d+/)?.[0];
  });
  // Always drain stderr; never publish raw logs or credentials in the receipt.
  child.stderr.on('data', () => {});
  const deadline = Date.now() + 25000;
  while (!base && !error && child.exitCode === null && Date.now() < deadline)
    await new Promise(r => setTimeout(r, 100));
  if (error) throw error;
  assert.ok(base, 'server must report listening address before startup deadline');
  await request('/global/health');
}
async function request(path, method = 'GET', body) {
  const response = await fetch(base + path, { method, headers: { ...headers, 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(10000) });
  assert.ok(response.ok, `${method} ${path}: HTTP ${response.status}`);
  return response.status === 204 ? null : response.json();
}
const receipt = { date: new Date().toISOString(), executable, fixture: root, model_calls: 0, checks: {} };
try {
  await start();
  receipt.health = await request('/global/health');
  const paths = await request('/path');
  assert.equal(realpathSync(paths.directory), root);
  assert.equal(realpathSync(paths.worktree), root);
  receipt.checks.git_root_matches_cwd = true;
  assert.equal((await request('/file/content?path=tracked.txt')).content.trim(), 'parent dirty file');
  assert.equal((await request('/file/content?path=untracked.txt')).content.trim(), 'parent untracked file');
  receipt.checks.dirty_and_untracked_files_visible = true;
  writeFileSync(join(root, 'tracked.txt'), 'parent edit after startup\n');
  assert.equal((await request('/file/content?path=tracked.txt')).content.trim(), 'parent edit after startup');
  receipt.checks.live_parent_edit_visible = true;
  const a = await request('/session', 'POST', { title: 'headless probe A' });
  const b = await request('/session', 'POST', { title: 'headless probe B' });
  assert.notEqual(a.id, b.id);
  assert.equal(realpathSync(a.directory), root); assert.equal(realpathSync(b.directory), root);
  receipt.sessions = [a.id, b.id];
  receipt.checks.two_sessions_share_directory = true;
  const providers = await request('/provider');
  const provider = providers.all.find(p => p.id === 'opencode');
  const modelID = Object.keys(provider.models)[0];
  // noReply still requires model identity; this stores context without executing inference.
  await request(`/session/${a.id}/message`, 'POST', { noReply: true,
    model: { providerID: provider.id, modelID }, parts: [{ type: 'text', text: 'Probe context only; do not run.' }] });
  assert.equal((await request(`/session/${a.id}/message`)).length, 1);
  assert.equal((await request(`/session/${b.id}/message`)).length, 0);
  receipt.checks.session_histories_separate = true;
  assert.equal((await fetch(base + '/global/health')).status, 401);
  receipt.checks.unauthenticated_request_rejected = true;
  const spec = await request('/doc');
  writeFileSync(join(root, 'openapi.json'), JSON.stringify(spec, null, 2));
  receipt.api = {
    prompt_fields: Object.keys(spec.paths['/session/{sessionID}/message'].post.requestBody.content['application/json'].schema.properties),
    native_delivery: spec.paths['/api/session/{sessionID}/prompt']?.post?.requestBody?.content?.['application/json']?.schema?.properties?.delivery,
    permission_reply: Boolean(spec.paths['/permission/{requestID}/reply']),
    question_reject: Boolean(spec.paths['/question/{requestID}/reject']),
  };
  assert.equal(git('worktree', 'list', '--porcelain').match(/^worktree /gm)?.length, 1);
  receipt.checks.one_physical_git_worktree = true;
  await stop(); await start();
  assert.equal((await request(`/session/${a.id}/message`)).length, 1);
  assert.equal((await request(`/session/${b.id}`)).id, b.id);
  receipt.checks.sessions_survive_server_restart = true;
} finally { await stop(); }
if (process.argv[3]) writeFileSync(resolve(process.argv[3]), JSON.stringify(receipt, null, 2) + '\n');
console.log(JSON.stringify(receipt, null, 2));
