export interface RackWorker {
  id: string; display_name?: string; status: string; model: string; current_action?: string; current_tool?: string; role?: string; task_id?: string;
}

export const SYMBOLS: Record<string, { sym: string; label: string }> = {
  STARTING: { sym: '◐', label: 'WAIT' }, RUNNING: { sym: '●', label: 'RUN' }, WAITING: { sym: '◐', label: 'WAIT' },
  BLOCKED: { sym: '!', label: 'BLOCK' }, COMPLETE: { sym: '✓', label: 'DONE' }, FAILED: { sym: '×', label: 'FAIL' },
  CANCELLED: { sym: '×', label: 'FAIL' }, LOST: { sym: '×', label: 'FAIL' }, IDLE: { sym: '○', label: 'IDLE' },
};

function fit(s: string, w: number): string {
  if (w <= 0) return '';
  return s.length <= w ? s : w <= 1 ? s.slice(0, w) : s.slice(0, w - 1) + '…';
}

function strip(w: RackWorker): string {
  const st = SYMBOLS[w.status] ?? { sym: '?', label: w.status };
  const act = w.current_action || w.current_tool || '';
  return `${w.id}${w.display_name ? ` ${w.display_name}` : ''} ${st.sym} ${st.label} ${w.model}  ${act}`.trimEnd();
}

/** Pure: workers -> display lines. Strips for narrow widths, boxed panel for width >= 100. */
export function renderRack(workers: RackWorker[], width: number): string[] {
  if (workers.length === 0) return [];
  if (width < 100) return workers.map((w) => fit(strip(w), Math.max(10, width)));
  const inner = width - 4;
  const bar = '─'.repeat(width - 2);
  const out = [`┌${bar}┐`];
  for (const w of workers) out.push(`│ ${fit(strip(w), inner).padEnd(inner)} │`);
  out.push(`└${bar}┘`);
  return out;
}
