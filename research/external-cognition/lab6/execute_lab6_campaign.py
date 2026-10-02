"""Campaign executor for Lab 6 16-variable Ring CSP.

Dispatches all 6 seeds across Phase 1 (Proposers), Phase 2 (Reviewers), Phase 3 (Integrators),
using cohere/north-mini-code:free via Kilo Free.
Runs offline evaluation and writes evaluation.json upon completion.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

LAB6_DIR = Path(__file__).resolve().parent
if str(LAB6_DIR) not in sys.path:
    sys.path.insert(0, str(LAB6_DIR))

import offline_evaluate
import pilot

CAMPAIGN_DIR = LAB6_DIR / "runs" / "campaign"
FAMILY = "north"


def is_phase_done(run_dir: Path, seed: int, family: str, roles: tuple[str, ...]) -> bool:
    slot_dir = run_dir / "responses" / str(seed) / family
    return all(
        (slot_dir / f"{r}.raw").is_file() or (slot_dir / f"{r}.failure.json").is_file()
        for r in roles
    )


def execute_campaign():
    print(f"=== Starting Lab 6 Execution on {FAMILY} ===")
    print(f"Campaign Dir: {CAMPAIGN_DIR}")
    print(f"Seeds: {pilot.SEEDS}")

    total_start = time.time()

    for seed in pilot.SEEDS:
        print(f"\n--- Seed {seed} ---")

        # Phase 1: Proposers (4 concurrent)
        if not is_phase_done(CAMPAIGN_DIR, seed, FAMILY, pilot.PROPOSERS):
            print(f"[{seed}] Phase 1 (Proposers: {pilot.PROPOSERS}) dispatching...")
            p1_start = time.time()
            res1 = pilot.dispatch_phase(CAMPAIGN_DIR, seed, FAMILY, pilot.PROPOSERS)
            p1_elapsed = time.time() - p1_start
            print(f"[{seed}] Phase 1 completed in {p1_elapsed:.1f}s. Results: {[r.get('protocol_receipt', {}).get('accepted', r.get('failure_code')) for r in res1]}")
        else:
            print(f"[{seed}] Phase 1 (Proposers) already completed.")

        # Phase 2: Reviewers (4 concurrent)
        if not is_phase_done(CAMPAIGN_DIR, seed, FAMILY, pilot.REVIEWERS):
            print(f"[{seed}] Phase 2 (Reviewers: {pilot.REVIEWERS}) dispatching...")
            p2_start = time.time()
            res2 = pilot.dispatch_phase(CAMPAIGN_DIR, seed, FAMILY, pilot.REVIEWERS)
            p2_elapsed = time.time() - p2_start
            print(f"[{seed}] Phase 2 completed in {p2_elapsed:.1f}s. Results: {[r.get('protocol_receipt', {}).get('accepted', r.get('failure_code')) for r in res2]}")
        else:
            print(f"[{seed}] Phase 2 (Reviewers) already completed.")

        # Phase 3: Integrators (2 parallel)
        if not is_phase_done(CAMPAIGN_DIR, seed, FAMILY, pilot.FINALS):
            print(f"[{seed}] Phase 3 (Integrators: {pilot.FINALS}) dispatching...")
            p3_start = time.time()
            res3 = pilot.dispatch_phase(CAMPAIGN_DIR, seed, FAMILY, pilot.FINALS)
            p3_elapsed = time.time() - p3_start
            print(f"[{seed}] Phase 3 completed in {p3_elapsed:.1f}s. Results: {[r.get('protocol_receipt', {}).get('accepted', r.get('failure_code')) for r in res3]}")
        else:
            print(f"[{seed}] Phase 3 (Integrators) already completed.")

    total_elapsed = time.time() - total_start
    print(f"\nAll 6 seeds dispatched in {total_elapsed:.1f}s!")

    # Run offline evaluation
    print("\n=== Running Offline Evaluation ===")
    summary = offline_evaluate.evaluate_frozen_run(CAMPAIGN_DIR)
    eval_file = CAMPAIGN_DIR / "evaluation.json"
    eval_file.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    print(f"Saved evaluation to {eval_file}")

    fam_data = summary["families"][FAMILY]
    print(f"\n=== Lab 6 Summary for {FAMILY} ===")
    print(f"Total Slots: {fam_data['total_slots']}")
    print(f"Responses: {fam_data['responses']} / Failures: {fam_data['failures']}")
    print(f"Proposals Accepted: {fam_data['proposals_accepted']}")
    print(f"Proposals Sound & Complete: {fam_data['proposals_sound_and_complete']}")
    print(f"Shared Integrator Correct: {fam_data['shared_success_rate']}")
    print(f"Raw Integrator Correct: {fam_data['raw_success_rate']}")

    # Print breakdown per seed
    print("\nPer-Seed Breakdown:")
    for seed in pilot.SEEDS:
        records = [r for r in fam_data["records"] if r["seed"] == seed]
        shared = next((r for r in records if r["role"] == "shared-integrator"), {})
        raw = next((r for r in records if r["role"] == "raw-integrator"), {})
        props = [r for r in records if r["role"] in pilot.PROPOSERS]
        prop_ok = sum(1 for r in props if r.get("sound") and r.get("complete"))
        print(f"  Seed {seed}: Proposers S&C={prop_ok}/4 | Shared Solved={shared.get('correct')} | Raw Solved={raw.get('correct')}")


if __name__ == "__main__":
    execute_campaign()
