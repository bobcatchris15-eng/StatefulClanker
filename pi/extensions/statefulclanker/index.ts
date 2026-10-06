import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { operatorMode } from './operator.ts';
import { workerMode } from './worker.ts';

export default function (pi: ExtensionAPI): void {
  if (process.env.SC_WORKER_ID) workerMode(pi);
  else operatorMode(pi);
}
