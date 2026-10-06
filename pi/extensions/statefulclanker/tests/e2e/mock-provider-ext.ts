import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';

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
    const hasResult = (context.messages ?? []).some((m: any) => m.role === 'toolResult');
    if (!hasResult) {
      const args = { status: 'complete', summary: 'mock work done', changed_files: ['a.txt'], tests_run: ['mock'], confidence: 'high' };
      out.content.push({ type: 'toolCall', id: 'call_1', name: 'worker_finish', arguments: {} });
      s.push({ type: 'toolcall_start', contentIndex: 0, partial: out });
      out.content[0].arguments = args;
      s.push({ type: 'toolcall_delta', contentIndex: 0, delta: JSON.stringify(args), partial: out });
      s.push({ type: 'toolcall_end', contentIndex: 0, toolCall: { type: 'toolCall', id: 'call_1', name: 'worker_finish', arguments: args }, partial: out });
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
