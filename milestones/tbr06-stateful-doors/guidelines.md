# TB-R06 implementation guidelines

- Read the trusted TB-R06 acceptance test and current loader/runtime before editing; tests are immutable and define the executable contract.
- Work only in the provided execution worktree and only within the task's allowed source scope.
- Extend the loader with small normalization helpers consistent with its existing result/error pattern. Normalize absent `doors` and `triggers` to typed empty arrays.
- Validate all door IDs before resolving trigger references. Preserve specific field paths in validation failures so malformed data is diagnosable.
- Use a reusable Door scene and script. Configure a BoxMesh and BoxShape3D from the same normalized size and move their shared root with one Tween.
- Keep `open()` idempotent and deterministic: exactly one accepted transition and one increment, with OPEN assigned only when movement completes.
- Make RestroomRuntime the single owner of door lookup and trigger state. Evaluate triggers synchronously from the successful collection signal path; never poll per frame.
- Do not award collection credit anywhere new. Empty and already-collected toilets must continue to emit no successful collection signal.
- Design `restroom_004` as a simple, readable three-area route with full-width wall/gate assemblies. Door A threshold is 2; Door B threshold is 4 or 5. Put sufficient collectibles on the near side of each closed gate and at least one beyond Door B.
- Use contrasting area floors/walls, door colors, labels, and lighting to make progression screenshots legible, while retaining the repository's low-poly procedural style.
- Preserve the existing player scene/script, all prior level files, final-exit rules, controls, collision behavior, HUD, and tests exactly.
- Do not implement the absent TB-R05 pickup-feedback work, audio, TB-R07, unrelated polish, or speculative schema/action types.
- Game Foundry owns validation, critic review, bounded repair, acceptance, and commit creation.
