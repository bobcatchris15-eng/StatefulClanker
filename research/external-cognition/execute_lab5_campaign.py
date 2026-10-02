#!/usr/bin/env python3
"""Driver for Lab 5 finite CSP campaign execution."""
import json
import os
import sys
import time
from pathlib import Path

# Add lab5 to path
ROOT = Path(__file__).resolve().parent / "lab5"
sys.path.insert(0, str(ROOT))

import pilot


def run_campaign(run_dir: str | Path) -> None:
    run_dir = Path(run_dir).resolve()
    manifest = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
    seeds = manifest["seeds"]
    families = manifest["families"]
    fam_a, fam_b = families[0], families[1]

    print(f"=== Starting Lab 5 Campaign at {run_dir} ===")
    print(f"Seeds: {seeds}")
    print(f"Families: {families}")
    print("=" * 60)

    total_pairs = len(seeds) * len(families) * 3
    pair_idx = 0

    for seed_i, seed in enumerate(seeds):
        fams = (fam_a, fam_b) if seed_i % 2 == 0 else (fam_b, fam_a)
        for fam in fams:
            for phase_name, roles in [
                ("propose", pilot.PROPOSERS),
                ("review", pilot.REVIEWERS),
                ("final", pilot.FINALS),
            ]:
                pair_idx += 1
                prefix = f"[{pair_idx}/{total_pairs}] Seed {seed} | {fam} | {phase_name} ({roles[0]}, {roles[1]})"

                # Check if already completed
                d = run_dir / "responses" / str(seed) / fam
                already_done = all(
                    (d / f"{r}.raw").is_file() or (d / f"{r}.failure.json").is_file()
                    for r in roles
                )
                if already_done:
                    print(f"{prefix} -> ALREADY RECORDED")
                    continue

                t0 = time.time()
                print(f"{prefix} -> DISPATCHING...", flush=True)
                try:
                    results = pilot.dispatch_pair(run_dir, seed, fam, roles)
                    dt = time.time() - t0
                    status_strs = []
                    for r, res in zip(roles, results):
                        code = res.get("failure_code") or (
                            "ACCEPTED" if res.get("protocol_receipt", {}).get("accepted") else "REJECTED"
                        )
                        status_strs.append(f"{r}:{code}")
                    print(f"{prefix} -> DONE in {dt:.1f}s ({', '.join(status_strs)})", flush=True)
                except Exception as exc:
                    print(f"{prefix} -> ERROR: {exc}", flush=True)
                    raise

    print("\n" + "=" * 60)
    print("All 72 call slots completed! Running offline evaluator...")
    eval_result = pilot.evaluate(run_dir)
    eval_path = run_dir / "evaluation.json"
    eval_path.write_text(json.dumps(eval_result, indent=2), encoding="utf-8")
    print(f"Evaluation saved to {eval_path}")

    # Summary
    print("\n=== FINAL RESULTS SUMMARY ===")
    for fam, stats in eval_result["families"].items():
        print(f"\nFamily: {fam.upper()}")
        print(f"  Total slots: {stats['total_slots']} (responses: {stats['responses']}, failures: {stats['failures']})")
        print(f"  Proposals accepted: {stats['proposals_accepted']}")
        print(f"  Proposals sound & complete: {stats['proposals_sound_and_complete']}")
        print(f"  Shared Integrator correct: {stats['shared_success_rate']}")
        print(f"  Raw Integrator correct:    {stats['raw_success_rate']}")


if __name__ == "__main__":
    campaign_dir = sys.argv[1] if len(sys.argv) > 1 else "research/external-cognition/lab5/runs/campaign"
    run_campaign(campaign_dir)
