export type IntentStatus = 'active' | 'superseded' | 'withdrawn' | 'satisfied';
export interface Intent {
  id: string;
  timestamp: string;
  source: string;
  statement: string;
  supersedes: string[];
  scope: string;
  status: IntentStatus;
}

export type TaskStatus = 'pending' | 'active' | 'blocked' | 'complete' | 'failed' | 'cancelled';
export interface Task {
  id: string;
  title: string;
  objective: string;
  status: TaskStatus;
  created_by: string;
  assigned_worker: string | null;
  scope: { files: string[]; subsystem: string; worktree: string };
  dependencies: string[];
  related_tasks: string[];
  context_hints: string[];
  constraints: string[];
  expected_outputs: string[];
  verification_expectations: string[];
  results: unknown[];
  evidence: unknown[];
  unresolved: string[];
  created_at: string;
  updated_at: string;
}

export type WorkerStatus =
  | 'STARTING' | 'RUNNING' | 'WAITING' | 'BLOCKED' | 'IDLE'
  | 'COMPLETE' | 'FAILED' | 'CANCELLED' | 'LOST';

export interface WorkerResult {
  worker_id: string;
  task_id: string;
  status: string;
  summary: string;
  changed_files: string[];
  artifacts: string[];
  tests_added: string[];
  tests_run: string[];
  test_results: unknown[];
  important_discoveries: string[];
  lessons_written: string[];
  unresolved_questions: string[];
  known_risks: string[];
  collaboration_packets: PeerPacket[];
  confidence: number | string;
}

export interface Worker {
  id: string;
  task_id: string;
  role: string;
  ability_profile: string;
  provider: string;
  model: string;
  endpoint_lease: EndpointLease | null;
  session_id: string | null;
  generation: number;
  pid: number | null;
  status: WorkerStatus;
  project_root: string;
  worktree: { path: string; branch: string; base_commit: string } | null;
  started_at: string;
  last_activity: string;
  current_action: string;
  current_tool: string;
  context_usage: { tokens_used: number; context_window: number; percentage: number; compactions: number };
  collaboration: { team_ids: string[]; inbox_cursor: number; unread_count: number };
  results: WorkerResult[];
}

export interface PeerPacket {
  id: string;
  from: string;
  to: string;
  kind: string;
  body: string;
  ts: string;
}

export interface ContextReceipt {
  id: string;
  task_id: string;
  worker_id: string;
  ts: string;
  sources: string[];
  token_estimate: number;
}

export interface Endpoint {
  id: string;
  provider: string;
  url: string;
  model: string;
  max_concurrent: number;
}

export interface EndpointLease {
  endpoint_id: string;
  worker_id: string;
  acquired_at: string;
  expires_at: string | null;
}

export interface ScEvent {
  ts: string;
  type: string;
  data: unknown;
}
