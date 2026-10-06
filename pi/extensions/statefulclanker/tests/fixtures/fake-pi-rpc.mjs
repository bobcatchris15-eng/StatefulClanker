// Minimal fake pi RPC process. Env FAKE_NO_FINISH=1 skips the SC1 finish notify.
import { StringDecoder } from 'node:string_decoder';
const out = (o) => process.stdout.write(JSON.stringify(o) + '\n');
const dec = new StringDecoder('utf8');
let buf = '';
process.stdin.on('data', (c) => {
  buf += dec.write(c);
  let i;
  while ((i = buf.indexOf('\n')) !== -1) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    if (line.trim()) handle(JSON.parse(line));
  }
});
process.stdin.on('end', () => process.exit(0));
function handle(m) {
  if (m.type === 'extension_ui_response') return;
  out({ id: m.id, type: 'response', command: m.type, success: true });
  if (m.type === 'prompt') {
    out({ type: 'agent_start' });
    out({ type: 'tool_execution_start', toolName: 'bash', toolCallId: 'c1', args: {} });
    out({ type: 'extension_ui_request', id: 'u1', method: 'confirm', title: 't', message: 'm' });
    if (!process.env.FAKE_NO_FINISH) {
      const p = { kind: 'finish', summary: 'done: ' + m.message, changed_files: ['a.txt'], confidence: 'high' };
      out({ type: 'extension_ui_request', id: 'u2', method: 'notify', message: 'SC1 ' + JSON.stringify(p) });
    }
    out({ type: 'agent_end', messages: [] });
    out({ type: 'agent_settled' });
  }
}
