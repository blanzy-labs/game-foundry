# TB-R07 — Data-Driven Environmental Hazards

TB-R07 extends the human-approved TB-R05/TB-R06 baseline at `f7ee30f` with exactly one environmental hazard type: `reset_zone`. The accepted test-bearing source base is the same gameplay plus the immutable TB-R07 acceptance gate.

## Functional contract

Level JSON accepts optional `hazards`, normalized to an empty array for existing levels. A reset zone requires `id`, `type`, `position`, `size`, and `reset_position`; `color` and positive `cooldown` are optional, with a 0.75-second default. Validation fails closed for duplicate IDs, unknown types, malformed vectors, non-positive dimensions, missing/malformed reset positions, and non-positive cooldowns.

Each hazard is a reusable scene/component with an aligned visible low-poly danger surface and Area3D/CollisionShape3D. It supports only `reset_zone`, explicitly accepts the player and ignores other physics bodies. Its minimal READY → TRIGGERED → COOLDOWN state permits one activation per entry, blocks event storms, increments a deterministic activation count, and permits later re-entry after cooldown. Emit deterministic registration, trigger, and player-reset markers.

RestroomRuntime instantiates all hazards from normalized level data without hard-coded level IDs and remains authoritative for the consequence. A valid activation moves the current CharacterBody3D player to that hazard's configured safe reset position and clears all velocity. It may show restrained, non-blocking visual/HUD feedback such as `OH CRAP!`, but adds no audio, damage, health, lives, death, checkpoint, reload, knockback, or arbitrary action language.

The reset occurs in the current scene instance. It must preserve collected count, collected toilets, fired triggers and their counts, open doors and their counts, unlocked exit state, TB-R05 pickup feedback, final completion, normal movement, camera, beetle model, and collision behavior. No scene reload is permitted.

## restroom_005 demonstration

Add a compact ridiculous restroom level, preferably named `Hazardous Materials`, with 7–10 collectible turds, 2–4 empty toilets, exactly two existing-style stateful doors, exactly two existing collect-count/open-door triggers, 2–3 reset zones, and 3–4 traversal areas. Hazards must be visible, avoidable without precision movement, and at least one must matter to the primary route. Every reset position must be safe: outside every hazard, blocking geometry, and closed door, with no reset loop or soft lock. Progression is early collection/hazard, Door A, middle hazard, Door B, final collection, exit unlock, and heist completion.

## Proof and boundaries

The immutable TB-R07 validator proves schema negatives, legacy compatibility, runtime data fidelity, actual spatial player entry, velocity clearing, one activation per entry, cooldown re-entry, non-player rejection, before/after objective/toilet/trigger/door/exit state, final completion, restroom_005 layout, visual evidence, all current regressions, Godot validation, Linux export, and exported runtime for restroom_001–005.

Do not modify prior levels, existing tests, doors/triggers, pickup authority, character art, gait, movement constants, camera behavior, collision behavior, audio, or unrelated systems. Do not begin the next slice or audio work. Human hazard QA remains pending after automated acceptance.
