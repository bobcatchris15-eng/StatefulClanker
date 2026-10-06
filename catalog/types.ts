export type Rating = "unknown" | "poor" | "fair" | "good" | "excellent";
export const RATINGS: readonly Rating[] = ["unknown", "poor", "fair", "good", "excellent"];
export type Capability =
  | "coding" | "research" | "reasoning" | "repository_navigation" | "tool_use"
  | "long_context" | "vision" | "structured_output" | "speed";
export const CAPABILITIES: readonly Capability[] = [
  "coding", "research", "reasoning", "repository_navigation", "tool_use",
  "long_context", "vision", "structured_output", "speed",
];

export interface CandidateModel {
  key: string; // provider/id
  provider: string;
  id: string;
  name: string;
  reasoning: boolean;
  input: string[];
  contextWindow: number;
  maxTokens: number;
  cost: { input: number; output: number; cacheRead: number; cacheWrite: number };
  family?: string;
}

export interface Quirks {
  known_issues?: string[];
  [k: string]: unknown;
}

export interface Profile {
  pattern: string;
  capabilities?: Partial<Record<Capability, Rating>>;
  quirks?: Quirks;
  family?: string;
  lease_capacity?: number;
}

export interface AbilityRequest {
  profile?: string;
  min?: Partial<Record<Capability, Rating>>;
  weights?: Partial<Record<Capability, number>>;
  min_context?: number;
  free_only?: boolean;
  prefer_provider?: string[];
  avoid_provider?: string[];
  diversity_from?: string[];
  independent_of?: string;
}
