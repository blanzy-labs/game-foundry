# TB-R05 implementation guidelines

- Read the trusted TB-R05 acceptance gate and current toilet, player, restroom, door, and TB-R06 tests before editing. The tests are immutable and define executable proof.
- Work only in the execution worktree and task scope. Game Foundry owns validation, critic review, bounded repair, acceptance, and the feature commit.
- Keep `collect()` synchronous: flip `has_turd`, clear target presentation, start presentation safely, emit `collected` once, and return true. A second call returns false immediately.
- Keep RestroomRuntime's existing `_on_toilet_collected` path authoritative. Increment count and evaluate triggers before or independently of HUD Tweens; never await presentation.
- Implement `set_targeted()` on the toilet and have the player's existing nearest-target update explicitly clear the old target before selecting a new one. Never make toilets search for the player.
- Use small Godot-native Tweens and explicit deterministic state. Keep `pickup_duration` within 0.15–0.35 seconds. Kill conflicting target/pickup Tweens safely and restore neutral presentation only when the collectible still exists.
- Add a simple `+1 TURD` HUD label and restrained counter punch. Count feedback starts only from successful collection signals. Preserve the exact counter meaning and exact `E — STEAL TURD` prompt.
- Keep TB-R06 door and trigger code structurally unchanged unless a minimal compatibility correction is unavoidable. Do not delay `_evaluate_triggers()` or move it into UI/toilet animation code.
- Preserve every level, schema, scene, character hierarchy, locomotion pose, movement constant, camera behavior, toilet geometry, and collision behavior.
- Do not edit tests, levels, `.gitignore`, Game Foundry files, generated builds, or unrelated sources. Do not add audio, assets, frameworks, or new gameplay.
- Ensure visual evidence clearly distinguishes normal, targeted, pickup, HUD, final-exit, and threshold-door states in the existing procedural style.
