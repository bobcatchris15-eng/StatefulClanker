import { spawn, type ChildProcess } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { attachJsonlReader } from './jsonl.ts';

/**
 * Worker->parent channel ("SC1"): a worker (t3's worker.ts) sends an extension notify/setStatus
 * whose text starts with "SC1 " followed by JSON: {kind:"progress", status?, action?, ...} or
 * {kind:"finish", summary, changed_files, ...}. The runtime emits these as 'sc' events (payload = parsed JSON).
 * Other emitted events: 'event' (every raw pi event), 'notify', 'status', 'exit' ({code,signal}), 'stderr'.
 */
export interface StartOpts {
  piCommand: string; args?: string[]; cwd: string; env?: Record<string, string>;
  provider: string; model: string; thinking?: string; extensionPath: string;
  workerId?: string; projectRoot?: string; taskId?: string;
  /** Absolute paths of the parent's `-e` extensions, forwarded to the worker. */
  extraExtensions?: string[];
}

/**
 * Extension paths the parent was launched with (`-e <p>`, `--extension <p>`, `--extension=<p>`), absolute
 * (relative to cwd), deduped, excluding `self` (the statefulclanker index.ts, already passed separately).
 * Global (~/.pi/agent/extensions) and settings-listed extensions load automatically in child pi processes,
 * so only CLI-supplied ones need forwarding.
 */
export function parentExtensionArgs(argv: string[], self?: string, cwd: string = process.cwd()): string[] {
  const norm = (p: string) => (process.platform === 'win32' ? p.toLowerCase() : p);
  const selfAbs = self ? norm(resolve(cwd, self)) : undefined;
  const out: string[] = [];
  const seen = new Set<string>();
  const add = (p: string | undefined) => {
    if (!p) return;
    const abs = resolve(cwd, p);
    const k = norm(abs);
    if (k === selfAbs || seen.has(k)) return;
    seen.add(k); out.push(abs);
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-e' || a === '--extension') add(argv[++i]);
    else if (a.startsWith('--extension=')) add(a.slice('--extension='.length));
  }
  return out;
}

const SC_PREFIX = 'SC1 ';

export type ProviderSignal = 'rate_limit' | 'auth_error' | 'timeout' | 'malformed_tool_call';

/** Classify error text into a health outcome. Only the category is ever returned, never the text. */
export function classifyErrorText(text: string): ProviderSignal {
  const t = text.toLowerCase();
  if (/malformed|invalid tool|tool call.*(invalid|parse)|failed to parse.*(tool|argument)/.test(t)) return 'malformed_tool_call';
  if (/\b(401|403)\b|unauthori[sz]ed|forbidden|\bauth/.test(t)) return 'auth_error';
  if (/\b429\b|rate.?limit|overloaded|quota|too many requests|\b5\d\d\b/.test(t)) return 'rate_limit';
  return 'timeout';
}

/**
 * Provider-error signal from a raw pi RPC event, or null. Shapes (from rpc.md; agent_end message shape inferred):
 * auto_retry_end {success:false, finalError}; agent_end {willRetry:false, messages:[{role:'assistant', stopReason:'error', errorMessage}]}.
 */
export function providerSignal(ev: any): { outcome: ProviderSignal; source: 'retry' | 'agent_end' } | null {
  if (ev?.type === 'auto_retry_end' && ev.success === false) {
    return { outcome: classifyErrorText(String(ev.finalError ?? '')), source: 'retry' };
  }
  if (ev?.type === 'agent_end' && !ev.willRetry && Array.isArray(ev.messages)) {
    for (let i = ev.messages.length - 1; i >= 0; i--) {
      const m = ev.messages[i];
      if (m?.role !== 'assistant') continue;
      const txt = String(m.errorMessage ?? '');
      if (m.stopReason === 'error' || (m.stopReason === 'aborted' && txt)) return { outcome: classifyErrorText(txt), source: 'agent_end' };
      break;
    }
  }
  return null;
}

function resolveSpawn(cmd: string, args: string[]): { file: string; args: string[]; shell: boolean } {
  if (process.platform === 'win32' && /\.(cmd|bat)$/i.test(cmd)) {
    const cli = join(dirname(cmd), 'node_modules', '@earendil-works', 'pi-coding-agent', 'dist', 'cli.js');
    if (existsSync(cli)) return { file: process.execPath, args: [cli, ...args], shell: false };
    const q = (s: string) => (/[\s"&|<>^]/.test(s) ? `"${s.replace(/"/g, '\\"')}"` : s);
    return { file: q(cmd), args: args.map(q), shell: true };
  }
  return { file: cmd, args, shell: false };
}

export class PiRpcRuntime {
  private em = new EventEmitter();
  private child: ChildProcess | null = null;
  private pending = new Map<string, { resolve: (r: any) => void; reject: (e: Error) => void }>();
  private seq = 0;
  streaming = false;
  exited = false;
  stopping = false;

  get pid(): number | null { return this.child?.pid ?? null; }

  on(event: string, cb: (...a: any[]) => void): this { this.em.on(event, cb); return this; }

  start(o: StartOpts): void {
    const args = [...(o.args ?? []), '--mode', 'rpc', '--provider', o.provider, '--model', o.model, ...(o.thinking ? ['--thinking', o.thinking] : []), '-e', o.extensionPath, ...(o.extraExtensions ?? []).flatMap((p) => ['-e', p])];
    const sp = resolveSpawn(o.piCommand, args);
    const env: Record<string, string | undefined> = { ...process.env, ...(o.env ?? {}) };
    if (o.workerId) env.SC_WORKER_ID = o.workerId;
    if (o.projectRoot) env.SC_PROJECT_ROOT = o.projectRoot;
    if (o.taskId) env.SC_TASK_ID = o.taskId;
    const child = spawn(sp.file, sp.args, { cwd: o.cwd, env, shell: sp.shell, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    this.child = child;
    child.stdin!.on('error', () => {});
    attachJsonlReader(child.stdout!, (l) => this.onLine(l));
    child.stderr!.on('data', (d) => this.em.emit('stderr', String(d)));
    child.on('error', (e) => this.onExit(null, null, e));
    child.on('exit', (code, sig) => this.onExit(code, sig));
  }

  private onExit(code: number | null, signal: NodeJS.Signals | null, err?: Error): void {
    if (this.exited) return;
    this.exited = true;
    this.streaming = false;
    for (const p of this.pending.values()) p.reject(new Error('pi process exited'));
    this.pending.clear();
    this.em.emit('exit', { code: err ? 1 : code, signal, error: err?.message, expected: this.stopping });
  }

  private write(obj: unknown): void {
    if (!this.child || this.exited || !this.child.stdin!.writable) throw new Error('pi process not running');
    this.child.stdin!.write(JSON.stringify(obj) + '\n');
  }

  private onLine(line: string): void {
    if (!line.trim()) return;
    let ev: any;
    try { ev = JSON.parse(line); } catch { this.em.emit('stderr', `unparsable: ${line}`); return; }
    if (ev.type === 'response') {
      const p = ev.id !== undefined ? this.pending.get(String(ev.id)) : undefined;
      if (p) { this.pending.delete(String(ev.id)); p.resolve(ev); }
      this.em.emit('response', ev);
      return;
    }
    if (ev.type === 'agent_start') this.streaming = true;
    if (ev.type === 'agent_settled') this.streaming = false;
    if (ev.type === 'extension_ui_request') this.onUi(ev);
    const sig = providerSignal(ev);
    if (sig) this.em.emit('signal', sig);
    this.em.emit('event', ev);
  }

  private onUi(ev: any): void {
    const m = ev.method;
    try {
      if (m === 'confirm') this.write({ type: 'extension_ui_response', id: ev.id, confirmed: false, cancelled: true });
      else if (m === 'select' || m === 'input' || m === 'editor') this.write({ type: 'extension_ui_response', id: ev.id, cancelled: true });
    } catch { /* process gone */ }
    if (m === 'notify' || m === 'setStatus') {
      const text: string = String((m === 'notify' ? ev.message : ev.statusText) ?? '');
      this.em.emit(m === 'notify' ? 'notify' : 'status', text, ev);
      if (text.startsWith(SC_PREFIX)) {
        try { this.em.emit('sc', JSON.parse(text.slice(SC_PREFIX.length))); } catch { /* malformed */ }
      }
    }
  }

  send(cmd: Record<string, unknown>, timeoutMs = 30000): Promise<any> {
    const id = String(cmd.id ?? `r${++this.seq}`);
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => { this.pending.delete(id); reject(new Error(`timeout: ${cmd.type}`)); }, timeoutMs);
      t.unref();
      this.pending.set(id, { resolve: (r) => { clearTimeout(t); resolve(r); }, reject: (e) => { clearTimeout(t); reject(e); } });
      try { this.write({ ...cmd, id }); } catch (e) { clearTimeout(t); this.pending.delete(id); reject(e as Error); }
    });
  }

  prompt(text: string): Promise<any> {
    const c: Record<string, unknown> = { type: 'prompt', message: text };
    if (this.streaming) c.streamingBehavior = 'steer';
    return this.send(c);
  }
  steer(text: string): Promise<any> { return this.send({ type: 'steer', message: text }); }
  followUp(text: string): Promise<any> { return this.send({ type: 'follow_up', message: text }); }
  abort(): Promise<any> { return this.send({ type: 'abort' }); }
  getState(): Promise<any> { return this.send({ type: 'get_state' }); }

  async stop(): Promise<void> {
    this.stopping = true;
    const c = this.child;
    if (!c || this.exited) return;
    await new Promise<void>((res) => {
      const t = setTimeout(() => { try { c.kill(); } catch { /* */ } }, 2000);
      t.unref();
      this.em.once('exit', () => { clearTimeout(t); res(); });
      try { c.stdin!.end(); } catch { /* */ }
      setTimeout(() => { try { c.kill(); } catch { /* */ } }, 500).unref();
    });
  }
}
