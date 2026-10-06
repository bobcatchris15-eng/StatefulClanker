import type { AbilityRequest, Capability, Rating } from "./types.ts";

export interface Ability {
  min: Partial<Record<Capability, Rating>>;
  weights: Partial<Record<Capability, number>>;
  independent?: boolean; // review: diversity penalty vs. the worker under review
}

export const ABILITIES: Record<string, Ability> = {
  implementation: { min: { coding: "fair", tool_use: "fair" }, weights: { coding: 3, tool_use: 2, repository_navigation: 1, structured_output: 1 } },
  research: { min: { research: "fair" }, weights: { research: 3, reasoning: 1, long_context: 2, tool_use: 1 } },
  architecture: { min: { reasoning: "good" }, weights: { reasoning: 3, coding: 2, research: 1, long_context: 1 } },
  review: { min: { coding: "fair", reasoning: "fair" }, weights: { coding: 2, reasoning: 3, repository_navigation: 1 }, independent: true },
  fast: { min: {}, weights: { speed: 3, tool_use: 1, coding: 1 } },
};

export function resolveAbility(req: AbilityRequest): Ability {
  const base = (req.profile && ABILITIES[req.profile]) || { min: {}, weights: {} };
  const weights = { ...base.weights, ...(req.weights ?? {}) };
  if (Object.keys(weights).length === 0) weights.coding = 1;
  return { min: { ...base.min, ...(req.min ?? {}) }, weights, independent: base.independent };
}
