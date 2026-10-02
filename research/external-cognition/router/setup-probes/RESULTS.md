# Separate readiness results

Eight recorded setup sends: seven Kilo, one OpenRouter. First64-token probes for Liquid/North/Laguna returned HTTP200, length finish, reasoning fields and empty assistant content; dispatcher correctly recorded parse failures. New separately retained512-token checks returned exact {"ready":true} for all three, with stop finishes. Gemma/OpenRouter returned429 provider error; retained and excluded before experimental freeze. NVIDIA Nemotron/Kilo replacement passed512-token readiness with exact ready JSON. All four selected reported model IDs match requested IDs. No experimental requests have been sent.

These are transport/interface setup outcomes, excluded from controlled accuracy. No provider retries occurred within any dispatcher invocation, no paid fallback occurred, and the runtime hashes are saved separately. Synthetic research directories are direct paths outside the resident router root.
