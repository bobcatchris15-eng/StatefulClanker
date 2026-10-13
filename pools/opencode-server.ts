/**
 * StatefulClanker's OpenCode server transport.
 * Uses the installed OpenCode client (and its own provider credentials/models), NOT Pi's inference API.
 * Sessions are scoped with x-opencode-directory and may be steered while retained by the server.
 */
import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import { existsSync } from 'node:fs';
import { createServer } from 'node:net';
import { randomBytes } from 'node:crypto';
import { resolve, join, dirname } from 'node:path';

type Json = Record<string, any>;
type JsonFetch = typeof fetch;

function reservePort(): Promise<number> {
  return new Promise((ok, fail) => {
    const s = createServer();
    s.once('error', fail);
    s.listen(0, '127.0.0.1', () => {
      const a = s.address();
      const p = a && typeof a === 'object' ? a.port : 0;
      s.close(() => p ? ok(p) : fail(new Error('No OpenCode port')));
    });
  });
}
/** Resolve the native OpenCode binary on Windows, not the npm .cmd/.ps1 wrapper.
 * Shell-launched shims orphan their child executable on cancellation and can lock the checkout.
 * Resolve the installed opencode-ai package's executable before falling back to PATH.
 */
export function openCodeBinary(): string {
  const explicit = process.env.SC_OPENCODE_COMMAND?.trim();
  if (explicit) {
    if (process.platform === 'win32' && !/\.exe$/i.test(explicit))
      throw new Error('SC_OPENCODE_COMMAND must point to a native OpenCode .exe on Windows');
    return explicit;
  }
  if (process.platform === 'win32') {
    const candidates: string[] = [];
    const roots = new Set<string>();
    if (process.env.APPDATA) roots.add(join(process.env.APPDATA, 'npm'));
    const discovered = spawnSync('where.exe', ['opencode'], { encoding: 'utf8', windowsHide: true });
    for (const path of String(discovered.stdout ?? '').split(/\r?\n/).filter(Boolean)) roots.add(dirname(path.trim()));
    for (const root of roots) {
      candidates.push(join(root, 'node_modules', '@opencode', 'cli', 'bin', 'opencode.exe'));
      candidates.push(join(root, 'node_modules', 'opencode-ai', 'bin', 'opencode.exe'));
    }
    for (const candidate of candidates) if (existsSync(candidate)) return candidate;
    throw new Error('Unable to find native opencode.exe (V2 @opencode/cli or V1 opencode-ai); set SC_OPENCODE_COMMAND');
  }
  return 'opencode';
}

export interface OpenCodeResult {
  status: 'running' | 'waiting_input' | 'succeeded' | 'failed';
  text?: string;
  changedPaths?: string[];
  error?: string;
  completed?: boolean;
}
export class OpenCodeServer {
  private url = '';
  private password = '';
  private child: ChildProcess | null = null;
  private starting: Promise<void> | null = null;
  private readonly send: JsonFetch;
  private readonly root: string;
  constructor(root: string, send: JsonFetch = fetch) {
    this.root = root;
    this.send = send;
  }
  async start(): Promise<void> {
    if (this.starting) return this.starting;
    if (this.url) return;
    this.starting = this.boot();
    try { await this.starting; } finally { this.starting = null; }
  }
  private async boot(): Promise<void> {
    const existing = process.env.OPENCODE_SERVER_URL;
    if (existing) {
      const parsed = new URL(existing);
      if (!['127.0.0.1', 'localhost', '[::1]'].includes(parsed.hostname) || parsed.protocol !== 'http:')
        throw new Error('OPENCODE_SERVER_URL must be an HTTP loopback address');
      this.url = parsed.origin;
      this.password = process.env.OPENCODE_SERVER_PASSWORD ?? '';
      try { await this.health(); }
      catch (error) { this.url = ''; throw error; }
      return;
    }
    const port = await reservePort();
    this.url = `http://127.0.0.1:${port}`;
    this.password = randomBytes(30).toString('hex');
    const command = openCodeBinary();
    const child = spawn(command, ['serve', '--hostname', '127.0.0.1', '--port', String(port)], {
      cwd: resolve(this.root),
      windowsHide: true, stdio: 'ignore',
      env: { ...process.env, OPENCODE_SERVER_USERNAME: 'opencode', OPENCODE_SERVER_PASSWORD: this.password },
      // Windows npm shims may be .cmd; the launched arguments here contain NO model-generated strings.
      shell: process.platform === 'win32' && !/\.exe$/i.test(command),
    });
    this.child = child;
    let error = '';
    child.on('error', e => { error = e.message; });
    child.on('exit', () => { if (this.child === child) this.url = ''; });
    for (let i = 0; i < 60; i++) {
      if (error || child.exitCode !== null) break;
      try {
        await this.health(650);
        return;
      } catch { /* still starting */ }
      await new Promise(r => setTimeout(r, 150));
    }
    this.dispose();
    throw new Error('OpenCode server could not start: ' + (error || 'health check timed out / exited'));
  }

  /** V2 serves /global/health as a web-app fallback, NOT as JSON.
   * Its authenticated /api/session endpoint is a reliable backend readiness probe.
   */
  private async health(timeout = 3000): Promise<void> {
    const result = await this.request<{data?: Json[]}>('/api/session?limit=1', 'GET', undefined, timeout);
    if (!Array.isArray(result?.data)) throw new Error('OpenCode server has no usable V2 session API');
  }

  private async request<T>(path: string, method = 'GET', body?: unknown, timeout = 15000): Promise<T> {
    if (!this.url) throw new Error('OpenCode server not started');
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), timeout);
    try {
      const res = await this.send(this.url + path, {
        method, signal: ac.signal,
        headers: {
          'content-type': 'application/json',
          'x-opencode-directory': encodeURIComponent(resolve(this.root)),
          ...(this.password ? { authorization: 'Basic ' + Buffer.from('opencode:' + this.password).toString('base64') } : {}),
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      });
      if (!res.ok) throw new Error(`OpenCode HTTP ${res.status}: ${(await res.text()).slice(0, 500)}`);
      if (res.status === 204) return {} as T;
      const txt = await res.text();
      return (txt ? JSON.parse(txt) : {}) as T;
    } finally { clearTimeout(timer); }
  }

  async create(_title: string): Promise<string> {
    await this.start();
    // Native V2 sessions have a selected agent and location. Compatibility /session
    // creates a record without an active agent, which can strand admitted prompts.
    const s = await this.request<{ data?: Json }>('/api/session', 'POST', {
      agent: 'build', location: { directory: resolve(this.root) },
    });
    if (typeof s.data?.id !== 'string') throw new Error('OpenCode V2 session create returned no ID');
    return s.data.id;
  }
  private sid(id: string): string { return encodeURIComponent(id); }
  /** OpenCode 1.18.35 V2 exposes durable message/turn state. The legacy
   * prompt_async compatibility route can return HTTP 204 without ever storing the input.
   * Use the V2 admission path and verify that a session turn actually finished.
   */
  async messages(id: string): Promise<Json[]> {
    await this.start();
    const response = await this.request<{data?: Json[]}>('/api/session/' + this.sid(id) + '/message?order=desc&limit=200');
    return Array.isArray(response.data) ? response.data : [];
  }
  async submit(id: string, prompt: string, model?: string): Promise<number> {
    await this.start();
    const previous = await this.messages(id);
    if (model) {
      const slash = model.indexOf('/');
      if (slash < 1 || slash === model.length - 1) throw new Error('OpenCode model must be provider/model');
      await this.request('/api/session/' + this.sid(id) + '/model', 'POST', {
        model: { providerID: model.slice(0, slash), id: model.slice(slash + 1) },
      });
    }
    const result = await this.request<{data?: Json}>('/api/session/' + this.sid(id) + '/prompt', 'POST', {
      text: prompt, delivery: 'queue', resume: true,
    });
    if (!result?.data?.id || !result.data.sessionID) throw new Error('OpenCode did not confirm durable prompt admission');
    // Number of projected messages BEFORE admission, used only for detecting a new assistant turn.
    return previous.length;
  }
  async steer(id: string, text: string, model?: string): Promise<number> {
    return this.submit(id, text, model);
  }
  async inspect(id: string, baseline: number): Promise<OpenCodeResult> {
    await this.start();
    const messages = await this.messages(id);
    // V2 returns newest messages first. Filter out old assistant turns using the
    // pre-submission projection length as an advisory guard.
    const newestFirst = messages.slice(0, Math.max(0, messages.length - baseline));
    const assistant = newestFirst.find(m => m?.type === 'assistant');
    const content = Array.isArray(assistant?.content) ? assistant.content : [];
    const responseText = content.filter((p: Json) => p.type === 'text')
      .map((p: Json) => String(p.text ?? '')).join('').slice(-2500);
    if (assistant?.error) return { status: 'failed', completed: true,
      error: JSON.stringify(assistant.error).slice(0, 1200), text: responseText };
    // Every tool invocation can end an assistant message with finish='tool-calls'.
    // A message timestamp or arbitrary finish code is NOT a completed task.
    // OpenCode V2 publishes a final assistant with finish='stop' (and then an idle
    // projection). Require that terminal result rather than an intermediate step.
    if (assistant?.finish === 'stop' && assistant?.time?.completed) {
      return { status: 'succeeded', completed: true, text: responseText };
    }
    if (assistant?.finish === 'length' && assistant?.time?.completed) {
      return { status: 'failed', completed: true, text: responseText,
        error: 'OpenCode assistant stopped at generation limit without completing its task' };
    }
    try {
      const pending = await this.request<{data?: Json[]}>('/api/session/' + this.sid(id) + '/permission');
      if (Array.isArray(pending.data) && pending.data.length) return {
        status: 'waiting_input', text: 'OpenCode requires permission for ' +
          pending.data.map(p => String(p.action ?? p.id ?? 'operation')).join(', '),
      };
    } catch { /* permissions query is optional for compatibility */ }
    return { status: 'running', text: responseText };
  }

  async diff(id: string): Promise<string[]> {
    await this.start();
    const messages = await this.messages(id);
    const files = new Set<string>();
    for (const msg of messages) {
      for (const file of msg?.snapshot?.files ?? []) if (typeof file === 'string') files.add(file);
    }
    if (files.size) return [...files];
    try {
      const diffs = await this.request<Json[]>('/session/' + this.sid(id) + '/diff');
      return (Array.isArray(diffs) ? diffs : []).map(d => d.file ?? d.path ?? d.after ?? '')
        .filter((v): v is string => typeof v === 'string' && v.length > 0);
    } catch { return []; }
  }
  async abort(id: string): Promise<void> {
    await this.start();
    await this.request('/api/session/' + this.sid(id) + '/interrupt', 'POST', {});
  }
  async exists(id: string): Promise<boolean> {
    try { await this.start(); await this.request('/session/' + this.sid(id)); return true; }
    catch { return false; }
  }
  dispose(): void {
    const child = this.child;
    this.child = null;
    if (child && child.exitCode === null && child.pid) {
      if (process.platform === 'win32') {
        // Kill only this supervisor-owned server and its descendants, not other user's OpenCode sessions.
        spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore', timeout: 5000 });
      } else {
        try { child.kill('SIGTERM'); } catch { /* gone */ }
      }
    }
    this.url = '';
  }
}
