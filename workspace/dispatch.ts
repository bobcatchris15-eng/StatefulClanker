import {
  beginSolicitationSpawn, markNoticeDelivered, pendingNotices, readProposal, readSolicitation,
  resolveSolicitation, type Solicitation,
} from './checkouts.ts';

export interface CollaborationDispatch {
  sendWorker(workerId: string, message: string): Promise<void>;
  notifyOperator(message: string): void;
  canSpawn(): boolean;
  spawn(request: Solicitation): Promise<{ worker_id?: string; error?: string }>;
}
const summary = (q: Solicitation) =>
  'Solicitation ' + q.id + ' by ' + q.owner + '\nOwned paths: ' + q.paths.join(', ') + '\nRequest: ' + q.objective;

export function proposalAssignment(q: Solicitation): string {
  return 'You have been asked to collaborate on a shared checkout. ' + summary(q) + '\n' +
    'READ these files and relevant context. The requester retains exclusive checkout/commit right-of-way. ' +
    'Do not claim, directly edit, or commit these paths. Prepare improvements by checkout_hash followed by ' +
    'checkout_propose for each file you propose changing. The owner will accept/reject, validate, and publish. ' +
    'Use worker_progress to report blockers and worker_finish when your proposals are submitted. ' +
    'Do not expand scope or generate unrelated filesystem writes.';
}

/**
 * Durable inbox: duplicate text delivery can occur after a crash and packets include IDs.
 * New-worker spawns are reserved before starting the process; interrupted dispatch
 * requires explicit operator recovery rather than accidentally spawning twice.
 */
export async function dispatchNotices(root: string, d: CollaborationDispatch): Promise<number> {
  let handled = 0;
  for (const n of pendingNotices(root).slice(0, 30)) {
    if (n.kind === 'proposal') {
      const p = readProposal(root, 'operator', n.ref_id);
      if (p.status !== 'pending') { markNoticeDelivered(root, n.id); continue; }
      const msg = 'Checkout proposal ' + p.id + ' from ' + p.from + ' for ' + p.path +
        '. You hold commit responsibility. Call checkout_proposal_read, then checkout_accept or checkout_reject; ' +
        'validate and checkout_publish accepted changes. Check the current hash before applying.';
      if (n.to === 'operator') d.notifyOperator(msg);
      else {
        try { await d.sendWorker(n.to, msg); }
        catch { d.notifyOperator('Undeliverable proposal for ' + n.to + ': ' + msg + ' Use checkout_transfer if owner is inactive.'); }
      }
      markNoticeDelivered(root, n.id); handled++;
    } else if (n.kind === 'proposal_result') {
      const p = readProposal(root, 'operator', n.ref_id);
      const msg = 'Your proposal ' + p.id + ' for ' + p.path + ' was ' + p.status + ' by ' + p.to + '.';
      if (n.to === 'operator') d.notifyOperator(msg);
      else {
        try { await d.sendWorker(n.to, msg); }
        catch { d.notifyOperator('Could not deliver contributor outcome to ' + n.to + ': ' + msg); }
      }
      markNoticeDelivered(root, n.id); handled++;
    } else if (n.kind === 'solicit') {
      const q = readSolicitation(root, n.ref_id);
      if (q.status !== 'pending') { markNoticeDelivered(root, n.id); continue; }
      if (n.to === 'operator' && q.spawn_new) {
        if (!d.canSpawn()) continue;
        if (!beginSolicitationSpawn(root, q.id)) continue;
        markNoticeDelivered(root, n.id); // Reserve before creating the subprocess.
        try {
          const result = await d.spawn(q);
          if (!result.worker_id) throw Error(result.error || 'spawn returned no worker');
          resolveSolicitation(root, q.id, 'assigned', result.worker_id);
          d.notifyOperator('Solicitation ' + q.id + ': spawned proposal-only specialist ' + result.worker_id +
            ' for ' + q.owner + ' (' + q.paths.join(', ') + ').');
        } catch (err) {
          resolveSolicitation(root, q.id, 'failed', undefined, String((err as Error).message));
          d.notifyOperator('Solicitation ' + q.id + ' could not spawn: ' + String((err as Error).message) +
            '. Use checkout_dispatch to retry.');
        }
        handled++;
      } else if (n.to === 'operator') {
        resolveSolicitation(root, q.id, 'routing');
        d.notifyOperator('Assistance requested: ' + summary(q) +
          '\nUse checkout_dispatch with target worker or spawn_new to assign help.');
        markNoticeDelivered(root, n.id); handled++;
      } else {
        try {
          await d.sendWorker(n.to, proposalAssignment(q));
          resolveSolicitation(root, q.id, 'assigned', n.to);
        } catch {
          resolveSolicitation(root, q.id, 'routing');
          d.notifyOperator('Solicitation ' + q.id + ' could not reach ' + n.to +
            '. Use checkout_dispatch to select an active worker or spawn_new.');
        }
        markNoticeDelivered(root, n.id); handled++;
      }
    }
  }
  return handled;
}
