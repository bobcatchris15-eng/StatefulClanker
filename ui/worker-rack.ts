export interface RackWorker {
  id: string; display_name?: string; status: string; model: string; provider?: string;
  current_action?: string; current_tool?: string; role?: string; task_id?: string;
}

export const LAMPS = ['ACT', 'GEN', 'TOL', 'TX', 'RX', 'TST', 'GIT', 'ERR'] as const;
export type Lamp = (typeof LAMPS)[number];

type LampExpiry = Partial<Record<Lamp, number>>;

/**
 * Ephemeral, UI-only telemetry. Durable worker state remains authoritative; these expiries only
 * make real Pi/Clanker events visible as short lamp pulses in the rack.
 */
export class BlinkenState {
  private until = new Map<string, LampExpiry>();
  readonly pulseMs: number;

  constructor(pulseMs = 650) { this.pulseMs = pulseMs; }

  pulse(id: string, lamp: Lamp, now = Date.now(), ttl = this.pulseMs): void {
    const row = this.until.get(id) ?? {};
    row[lamp] = Math.max(row[lamp] ?? 0, now + ttl);
    this.until.set(id, row);
  }

  /** Map a raw Pi event to physical-looking activity lamps. No random blinking. */
  ingest(id: string, ev: any, now = Date.now()): void {
    const t = String(ev?.type ?? '');
    if (!t) return;

    // Any meaningful runtime event is activity.
    if (
      t === 'agent_start' || t === 'agent_end' || t === 'agent_settled' ||
      t === 'turn_start' || t === 'turn_end' || t === 'message_start' ||
      t === 'message_update' || t === 'message_end' ||
      t.startsWith('tool_execution_') || t.startsWith('auto_retry_') ||
      t === 'extension_ui_request'
    ) this.pulse(id, 'ACT', now);

    if (t === 'agent_start' || t === 'turn_start' || t === 'message_start' || t === 'message_update') {
      this.pulse(id, 'GEN', now);
    }

    if (t.startsWith('tool_execution_')) {
      this.pulse(id, 'TOL', now);
      const name = String(ev?.toolName ?? '').toLowerCase();
      const args = ev?.args ?? {};
      const command = String(args?.command ?? args?.cmd ?? '').toLowerCase();

      if (
        /(^|[-_])(edit|write|patch|apply|replace)([-_]|$)/.test(name) ||
        /\bgit\b/.test(name) ||
        /\bgit\b/.test(command)
      ) this.pulse(id, 'GIT', now);

      if (
        /(^|[-_])(test|lint|typecheck|check|build)([-_]|$)/.test(name) ||
        /\b(npm|pnpm|yarn|bun)\b[^\n]*(test|lint|check|build)|\b(pytest|cargo test|go test|dotnet test|ctest|mvn test|gradle test)\b/.test(command)
      ) this.pulse(id, 'TST', now);
    }

    if (
      (t === 'auto_retry_end' && ev?.success === false) ||
      (t === 'agent_end' && Array.isArray(ev?.messages) && ev.messages.some((m: any) => m?.stopReason === 'error')) ||
      t === 'error'
    ) this.pulse(id, 'ERR', now, Math.max(this.pulseMs, 1200));

    if (t === 'extension_ui_request') {
      const text = String((ev?.method === 'notify' ? ev?.message : ev?.statusText) ?? '');
      if (text.startsWith('SC1 ')) this.pulse(id, 'TX', now);
    }
  }

  /** Explicit communication hook for parent/peer traffic that is not a Pi runtime event. */
  transfer(from: string, to: string, now = Date.now()): void {
    this.pulse(from, 'TX', now);
    this.pulse(to, 'RX', now);
    this.pulse(from, 'ACT', now);
    this.pulse(to, 'ACT', now);
  }

  snapshot(id: string, now = Date.now()): Record<Lamp, boolean> {
    const row = this.until.get(id) ?? {};
    const out = {} as Record<Lamp, boolean>;
    let live = false;
    for (const lamp of LAMPS) {
      out[lamp] = (row[lamp] ?? 0) > now;
      live ||= out[lamp];
    }
    if (!live && this.until.has(id)) this.until.delete(id);
    return out;
  }

  clear(id?: string): void {
    if (id) this.until.delete(id);
    else this.until.clear();
  }
}

export const SYMBOLS: Record<string, { sym: string; label: string }> = {
  STARTING: { sym: '◐', label: 'START' }, RUNNING: { sym: '●', label: 'RUN' }, WAITING: { sym: '◐', label: 'WAIT' },
  BLOCKED: { sym: '!', label: 'BLOCK' }, COMPLETE: { sym: '✓', label: 'DONE' }, FAILED: { sym: '×', label: 'FAIL' },
  CANCELLED: { sym: '×', label: 'CANCEL' }, LOST: { sym: '×', label: 'LOST' }, IDLE: { sym: '○', label: 'IDLE' },
};

function fit(s: string, w: number): string {
  if (w <= 0) return '';
  return s.length <= w ? s : w <= 1 ? s.slice(0, w) : s.slice(0, w - 1) + '…';
}

function modelLabel(w: RackWorker): string {
  if (w.provider && !w.model.includes('/')) return `${w.provider}/${w.model}`;
  return w.model;
}

function lights(id: string, blink?: BlinkenState, now = Date.now()): string {
  const snap = blink?.snapshot(id, now);
  return LAMPS.map((l) => snap?.[l] ? '■' : '□').join(' ');
}

const LABEL_LINE = LAMPS.join(' ');

function title(w: RackWorker): string {
  const nm = w.display_name ? ` ${w.display_name}` : '';
  const role = w.role ? ` · ${w.role.toUpperCase()}` : '';
  return `${w.id}${nm}${role} · ${modelLabel(w)}`;
}

function strip(w: RackWorker, blink?: BlinkenState, now = Date.now()): string {
  const st = SYMBOLS[w.status] ?? { sym: '?', label: w.status };
  const act = w.current_action || w.current_tool || '';
  return `${w.id}${w.display_name ? ` ${w.display_name}` : ''}  ${lights(w.id, blink, now)}  ${st.sym} ${st.label}  ${modelLabel(w)}${act ? `  ${act}` : ''}`;
}

function panel(w: RackWorker, width: number, blink?: BlinkenState, now = Date.now()): string[] {
  const st = SYMBOLS[w.status] ?? { sym: '?', label: w.status };
  const outer = Math.max(54, Math.min(width, 96));
  const inner = outer - 4;
  const ttl = fit(title(w), inner - 2);
  const topFill = Math.max(0, inner - ttl.length - 1);
  const top = `┌─ ${ttl} ${'─'.repeat(topFill)}┐`;
  const activity = `${lights(w.id, blink, now)}   ${st.sym} ${st.label}`;
  const action = w.current_action || (w.current_tool ? `tool: ${w.current_tool}` : '');
  const body = [
    `│ ${fit(activity, inner).padEnd(inner)} │`,
    `│ ${fit(LABEL_LINE, inner).padEnd(inner)} │`,
  ];
  if (action) body.push(`│ ${fit(action, inner).padEnd(inner)} │`);
  return [top, ...body, `└${'─'.repeat(outer - 2)}┘`];
}

/**
 * Parent (when supplied) is rendered first as worker zero. At >= 64 columns each participant gets
 * a real BlinkenRack panel; narrower terminals collapse to one live strip per participant.
 */
export function renderRack(
  workers: RackWorker[],
  width: number,
  blink?: BlinkenState,
  parent?: RackWorker,
  now = Date.now(),
): string[] {
  const rows = parent ? [parent, ...workers] : workers;
  if (rows.length === 0) return [];
  if (width < 64) return rows.map((w) => fit(strip(w, blink, now), Math.max(10, width)));
  const out: string[] = [];
  for (let i = 0; i < rows.length; i++) {
    if (i) out.push('');
    out.push(...panel(rows[i]!, width, blink, now));
  }
  return out;
}
