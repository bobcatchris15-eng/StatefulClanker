import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

/** Deterministic provider "scmock": first call -> worker_finish tool call; after a tool result -> text. */
function stream(model: any, context: any) {
  const s = createAssistantMessageEventStream();
  (async () => {
    const out: any = {
      role: 'assistant', content: [], api: model.api, provider: model.provider, model: model.id,
      usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      stopReason: 'pending', timestamp: Date.now(),
    };
    s.push({ type: 'start', partial: out });
    const nResults = (context.messages ?? []).filter((m: any) => m.role === 'toolResult').length;
    const probe = process.env.SC_SHARED_PROBE === '1';
    if (nResults < (probe ? 4 : 2)) {
      const tn = nResults === 0 ? 'worker_name' : probe && nResults < 3 ? 'read' : 'worker_finish';
      const reads = (context.messages ?? []).filter((m: any) => m.role === 'toolResult' && m.toolName === 'read');
      if (probe && nResults === 3 && process.env.SC_SHARED_WRITE === '1') {
        writeFileSync(join(process.cwd(), 'a.txt'), 'edited by child\n');
      }
      const args: any = nResults === 0 ? { name: 'Rivet' }
        : probe && nResults < 3 ? { path: nResults === 1 ? 'a.txt' : 'untracked.txt' }
        : probe ? { status: 'complete', summary: JSON.stringify({ cwd: process.cwd(), root: process.env.SC_PROJECT_ROOT, reads }), changed_files: [] }
        : { status: 'complete', summary: 'mock work done', changed_files: ['a.txt'], tests_run: ['mock'], confidence: 'high' };
      const cid = `call_${nResults + 1}`;
      out.content.push({ type: 'toolCall', id: cid, name: tn, arguments: {} });
      s.push({ type: 'toolcall_start', contentIndex: 0, partial: out });
      out.content[0].arguments = args;
      s.push({ type: 'toolcall_delta', contentIndex: 0, delta: JSON.stringify(args), partial: out });
      s.push({ type: 'toolcall_end', contentIndex: 0, toolCall: { type: 'toolCall', id: cid, name: tn, arguments: args }, partial: out });
      out.stopReason = 'toolUse';
    } else {
      out.content.push({ type: 'text', text: '' });
      s.push({ type: 'text_start', contentIndex: 0, partial: out });
      out.content[0].text = 'all done';
      s.push({ type: 'text_delta', contentIndex: 0, delta: 'all done', partial: out });
      s.push({ type: 'text_end', contentIndex: 0, content: 'all done', partial: out });
      out.stopReason = 'stop';
    }
    s.push({ type: 'done', reason: out.stopReason, message: out });
    s.end();
  })();
  return s;
}

export default function (pi: ExtensionAPI): void {
  (pi as any).registerProvider('scmock', {
    name: 'SC Mock', baseUrl: 'http://127.0.0.1:1', apiKey: 'x', api: 'scmock-api', streamSimple: stream,
    models: [{ id: 'scmock-1', name: 'SC Mock', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 8000, maxTokens: 1000 }],
  });
}
