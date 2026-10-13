/**
 * Jules cloud execution through the official REST API.
 * Credentials stay in JULES_API_KEY (never in receipts or logs).
 * https://jules.google/docs/api/reference/sessions
 */
import { execFileSync, spawnSync } from 'node:child_process';
import type { ExternalWorkerSpec } from './types.ts';

export interface JulesSession {
  name: string;
  id?: string;
  state?: string;
  url?: string;
  outputs?: unknown[];
  title?: string;
}
type Json = Record<string, any>;
export type JsonFetch = typeof fetch;
const BASE = 'https://jules.googleapis.com/v1alpha';
const terminal = new Set(['COMPLETED', 'FAILED']);

export function julesStatus(state?: string): ExternalWorkerSpec['status'] {
  if (!state) return 'queued'; // Create may return only a resource name.
  switch (state.toUpperCase()) {
    case 'COMPLETED': return 'succeeded';
    case 'FAILED': return 'failed';
    case 'AWAITING_PLAN_APPROVAL':
    case 'AWAITING_USER_FEEDBACK':
    case 'PAUSED': return 'waiting_input';
    case 'QUEUED': return 'queued';
    default: return 'running';
  }
}
export function isJulesTerminal(state?: string): boolean {
  return !!state && terminal.has(state.toUpperCase());
}
function origin(repo: string): string {
  if (/^[^\s/]+\/[^\s/]+$/.test(repo)) return repo.replace(/\.git$/, '');
  try {
    const remote = execFileSync('git', ['remote', 'get-url', 'origin'], { cwd: repo, encoding: 'utf8', timeout: 4000 }).trim();
    const found = /(?:github\.com[:/])([^/]+)\/([^/\s]+?)(?:\.git)?$/.exec(remote);
    return found ? `${found[1]}/${found[2]}` : '';
  } catch { return ''; }
}
export function githubOrigin(repo: string): string { return origin(repo); }

/** A Windows Pi process may predate user environment changes. Read the persisted
 * current-user variable without logging credentials or expanding shell command text.
 */
export function configuredJulesKey(): string {
  if (process.env.JULES_API_KEY?.trim()) return process.env.JULES_API_KEY.trim();
  if (process.platform !== 'win32') return '';
  try {
    const result = spawnSync('reg.exe',
      ['query', 'HKCU\\Environment', '/v', 'JULES_API_KEY'],
      { encoding: 'utf8', windowsHide: true, timeout: 3000 });
    if (result.status !== 0) return '';
    const match = /JULES_API_KEY\s+REG_(?:SZ|EXPAND_SZ)\s+([^\r\n]+)/i.exec(String(result.stdout ?? ''));
    return match?.[1]?.trim() ?? '';
  } catch { return ''; }
}

export class JulesRest {
  private readonly key: string;
  private readonly send: JsonFetch;
  constructor(key = configuredJulesKey(), send: JsonFetch = fetch) {
    this.key = key.trim();
    this.send = send;
  }
  get configured(): boolean { return this.key.length > 0; }

  private async call<T>(path: string, method = 'GET', body?: unknown): Promise<T> {
    if (!this.configured) throw new Error('JULES_API_KEY is not configured; generate an API key in Jules settings');
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 20000);
    try {
      const res = await this.send(BASE + path, {
        method,
        headers: {
          'x-goog-api-key': this.key,
          'content-type': 'application/json',
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: controller.signal,
      });
      if (!res.ok) {
        const message = (await res.text()).slice(0, 500);
        throw new Error(`Jules API HTTP ${res.status}: ${message}`);
      }
      if (res.status === 204) return {} as T;
      const raw = await res.text();
      return (raw ? JSON.parse(raw) : {}) as T;
    } finally { clearTimeout(timer); }
  }

  async sources(): Promise<Json[]> {
    const all: Json[] = [];
    let page = '';
    do {
      const r = await this.call<{sources?: Json[]; nextPageToken?: string}>(
        '/sources?pageSize=100' + (page ? '&pageToken=' + encodeURIComponent(page) : ''));
      all.push(...(r.sources ?? []));
      page = r.nextPageToken ?? '';
    } while (page && all.length < 1000);
    return all;
  }

  async sourceFor(repo: string): Promise<string> {
    const github = origin(repo);
    if (!github) throw new Error('Jules requires a GitHub owner/repo or a local checkout with an origin remote');
    const [owner, name] = github.toLowerCase().split('/');
    const source = (await this.sources()).find((s) =>
      (s.githubRepo?.owner?.toLowerCase() === owner && s.githubRepo?.repo?.toLowerCase() === name)
      || (typeof s.id === 'string' && s.id.toLowerCase().endsWith(`/${owner}/${name}`)));
    if (!source?.name) throw new Error(`Jules source for ${github} not connected; connect the repository in Jules first`);
    return String(source.name);
  }

  async create(spec: ExternalWorkerSpec): Promise<JulesSession> {
    const meta = spec.metadata ?? {};
    const source = typeof meta.source === 'string' ? meta.source : await this.sourceFor(spec.repo ?? process.cwd());
    const branch = typeof meta.branch === 'string' && meta.branch ? meta.branch : 'main';
    const body = {
      prompt: spec.assignment,
      title: typeof meta.title === 'string' ? meta.title : `StatefulClanker ${spec.id}`,
      sourceContext: { source, githubRepoContext: { startingBranch: branch } },
      requirePlanApproval: meta.requirePlanApproval === true,
      ...(meta.autoCreatePr === true ? { automationMode: 'AUTO_CREATE_PR' } : {}),
    };
    const session = await this.call<JulesSession>('/sessions', 'POST', body);
    if (!/^sessions\/[^/]+$/.test(session.name ?? '')) throw new Error('Jules create returned no valid session resource name');
    return session;
  }

  private resource(id: string): string {
    const name = id.startsWith('sessions/') ? id : 'sessions/' + id;
    if (!/^sessions\/[a-zA-Z0-9_-]+$/.test(name)) throw new Error('Invalid Jules session resource name');
    return name;
  }

  get(id: string): Promise<JulesSession> {
    return this.call<JulesSession>('/' + this.resource(id));
  }
  sendMessage(id: string, prompt: string): Promise<Json> {
    return this.call<Json>('/' + this.resource(id) + ':sendMessage', 'POST', { prompt });
  }
  approvePlan(id: string): Promise<Json> {
    return this.call<Json>('/' + this.resource(id) + ':approvePlan', 'POST', {});
  }

  async activities(id: string): Promise<Json[]> {
    const items: Json[] = [];
    let page = '';
    do {
      const r = await this.call<{activities?: Json[]; nextPageToken?: string}>(
        '/' + this.resource(id) + '/activities?pageSize=100' + (page ? '&pageToken=' + encodeURIComponent(page) : ''));
      items.push(...(r.activities ?? []));
      page = r.nextPageToken ?? '';
    } while (page && items.length < 3000);
    return items;
  }

  async collect(id: string): Promise<{ session: JulesSession; patches: Array<{ patch: string; baseCommitId: string; suggestedCommitMessage?: string }>; notes: string[] }> {
    const [session, activities] = await Promise.all([this.get(id), this.activities(id)]);
    const patches: Array<{ patch: string; baseCommitId: string; suggestedCommitMessage?: string }> = [];
    const notes: string[] = [];
    for (const a of activities) {
      if (a.agentMessaged?.agentMessage) notes.push(String(a.agentMessaged.agentMessage));
      if (a.sessionFailed?.reason) notes.push(String(a.sessionFailed.reason));
      for (const artifact of a.artifacts ?? []) {
        const p = artifact.changeSet?.gitPatch;
        if (typeof p?.unidiffPatch === 'string' && p.unidiffPatch.length) {
          patches.push({ patch: p.unidiffPatch, baseCommitId: String(p.baseCommitId ?? ''), suggestedCommitMessage: p.suggestedCommitMessage });
        }
      }
    }
    return { session, patches, notes };
  }
}
