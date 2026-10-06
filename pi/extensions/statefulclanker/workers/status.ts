import type { WorkerStatus } from '../protocol/types.ts';

export interface StatusState { status: WorkerStatus; current_tool: string; finished: boolean }

export const initialStatus: StatusState = { status: 'STARTING', current_tool: '', finished: false };

/** Pure reducer: pi RPC events, {type:'sc',payload}, {type:'exit',code} -> StatusState. */
export function deriveStatus(prev: StatusState, event: any): StatusState {
  const t = event?.type;
  const terminal = prev.status === 'CANCELLED' || prev.status === 'FAILED';
  switch (t) {
    case 'agent_start':
    case 'turn_start':
      if (terminal) return prev;
      return { ...prev, status: prev.finished ? 'COMPLETE' : 'RUNNING' };
    case 'tool_execution_start':
      if (terminal) return prev;
      return { ...prev, status: prev.finished ? 'COMPLETE' : 'RUNNING', current_tool: String(event.toolName ?? '') };
    case 'tool_execution_end':
      return { ...prev, current_tool: '' };
    case 'agent_end':
    case 'agent_settled':
      if (terminal) return prev;
      return { ...prev, status: prev.finished ? 'COMPLETE' : 'IDLE', current_tool: '' };
    case 'sc': {
      const p = event.payload ?? {};
      if (p.kind === 'finish') return { ...prev, status: 'COMPLETE', finished: true, current_tool: '' };
      if (p.kind === 'progress' && typeof p.status === 'string' && !prev.finished && !terminal) {
        return { ...prev, status: p.status as WorkerStatus };
      }
      return prev;
    }
    case 'exit': {
      if (prev.finished || terminal) return prev;
      return { ...prev, status: 'LOST', current_tool: '' };
    }
    default:
      return prev;
  }
}
