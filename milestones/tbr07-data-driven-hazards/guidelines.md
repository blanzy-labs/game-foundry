# TB-R07 implementation guidelines

- Read the trusted TB-R07 acceptance gate and current loader, restroom, player, door, toilet, and prior acceptance code before editing. Tests are immutable and executable proof.
- Work only in the isolated execution worktree and declared scope. Game Foundry owns validation, critic review, repairs, acceptance, and the feature commit.
- Add only `reset_zone`; use a reusable hazard node with a visible surface and aligned Area3D BoxShape3D, explicit player filtering, deterministic state/counts, and a positive cooldown.
- Keep RestroomRuntime authoritative for reset consequences and player progression authoritative in its existing collection/trigger path. Teleport and clear velocity in-place; never reload the scene.
- Preserve TB-R05 synchronous collection, prompt, pickup Tween, HUD feedback and duplicate protection. Preserve TB-R06 registries, one-shot triggers, door collision/open state, and exit behavior.
- Keep player changes to a narrow safe-reset API only. Do not change normal input, speed, gravity, gait, camera, model, or collision.
- Make restroom_005 compact, readable, avoidable, completable, and safe after every reset; reuse existing JSON geometry, doors, triggers, toilets, labels, lights, and environment vocabulary.
- Use restrained procedural hazard visuals and a brief non-blocking reaction. Add no audio/assets, health/lives/death, scene reload, checkpoint, generic action framework, or unrelated gameplay.
- Do not edit tests, prior levels, `.gitignore`, Game Foundry files, generated builds, or unrelated sources. Normal generated Godot `.uid` handling remains governed by GF-H02.
