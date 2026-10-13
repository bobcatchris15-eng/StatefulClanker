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
  if (explicit && (!process.platform.startsWith('win') || /\\.exe$/i.test(explicit))) return explicit;
  if (process.platform === 'win32') {
    const candidates: string[] = [];
    if (process.env.APPDATA) candidates.push(join(process.env.APPDATA, 'npm', 'node_modules', 'opencode-ai', 'bin', 'opencode.exe'));
    const shim = spawnSync('where.exe', ['opencode'], { encoding: 'utf8', windowsHide: true });
    for (const entry of String(shim.stdout ?? '').split(/\\r?\\n/).filter(Boolean)) {
      const d = dirname(entry.trim());
      candidates.push(join(d, 'node_modules', 'opencode-ai', 'bin', 'opencode.exe'));
    }
    for (const c of candidates) if (existsSync(c)) return c;
    if (explicit) throw new Error('SC_OPENCODE_COMMAND must be a native .exe on Windows: ' + explicit);
    throw new Error('Unable to locate native opencode.exe; set SC_OPENCODE_COMMAND to the installed executable');
  }
  return explicit || 'opencode';
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
      try { await this.request('/global/health'); }
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
        const health = await this.request<Json>('/global/health', 'GET', undefined, 500);
        if (health.healthy === true) return;
      } catch { /* still starting */ }
      await new Promise(r => setTimeout(r, 150));
    }
    this.dispose();
    throw new Error('OpenCode server could not start: ' + (error || 'health check timed out / exited'));
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

  async create(title: string): Promise<string> {
    await this.start();
    const s = await this.request<Json>('/session', 'POST', { title });
    if (typeof s.id !== 'string') throw new Error('OpenCode session create returned no ID');
    return s.id;
  }
  private sid(id: string): string { return encodeURIComponent(id); }
  async messages(id: string): Promise<Json[]> {
    await this.start();
    return this.request<Json[]>('/session/' + this.sid(id) + '/message');
  }
  async submit(id: string, prompt: string, model?: string): Promise<number> {
    const previous = await this.messages(id);
    let selected: Json | undefined;
    if (model) {
      const slash = model.indexOf('/');
      if (slash < 1 || slash === model.length - 1) throw new Error('OpenCode model must be provider/model');
      selected = { providerID: model.slice(0, slash), modelID: model.slice(slash + 1) };
    }
    await this.request('/session/' + this.sid(id) + '/prompt_async', 'POST', {
      ...(selected ? { model: selected } : {}),
      parts: [{ type: 'text', text: prompt }],
    });
    return previous.length;
  }
  async steer(id: string, text: string, model?: string): Promise<number> {
    // Same session; caller serializes turns unless the installed API specifically supports steering busy turns.
    return this.submit(id, text, model);
  }

  async inspect(id: string, baseline: number): Promise<OpenCodeResult> {
    await this.start();
    const [states, messages] = await Promise.all([
      this.request<Json>('/session/status'),
      this.messages(id),
    ]);
    const state = states?.[id];
    const typ = typeof state?.type === 'string' ? state.type : 'idle';
    const newer = messages.slice(baseline).filter(m => m?.info?.role === 'assistant');
    const last = newer.at(-1);
    const info = last?.info ?? {};
    const rawError = info.error;
    const error = rawError ? JSON.stringify(rawError).slice(0, 700) : undefined;
    const text = (last?.parts ?? []).filter((p: Json) => p.type === 'text')
      .map((p: Json) => String(p.text ?? '')).join('').slice(-2500);
    if (error) return { status: 'failed', error, text, completed: true };
    // A completed assistant message plus no busy session is a real turn completion.
    if (last && typ !== 'busy' && (info.time?.completed || info.finish)) {
      return { status: 'succeeded', text, completed: true };
    }
    if (typ === 'retry') return { status: 'waiting_input', text };
    return { status: 'running', text };
  }

  async diff(id: string): Promise<string[]> {
    const diffs = await this.request<Json[]>('/session/' + this.sid(id) + '/diff');
    return (Array.isArray(diffs) ? diffs : []).map(d => d.file ?? d.path ?? d.after ?? '')
      .filter((v): v is string => typeof v === 'string' && v.length > 0);
  }
  async abort(id: string): Promise<void> {
    await this.start();
    await this.request('/session/' + this.sid(id) + '/abort', 'POST', {});
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
