# TB-R06 — Stateful Doors and Objective Triggers

Add the first reusable, data-driven progression mechanism to Turd Burglar: doors that open once when collection-count triggers fire. Prove it in `restroom_004`, a linear three-area level with two sequential gates, while preserving all accepted gameplay and the frozen TB-R04C character.

## Level-data contract

`doors` and `triggers` are optional top-level arrays. Every normalized level must expose both arrays, empty when omitted, so `restroom_001` through `restroom_003` remain unchanged and valid.

A door has required `id`, `position`, `size`, `color`, and `open_offset`, plus optional `open_duration` defaulting to `0.5`. IDs are non-empty and unique. Vector and color normalization follows existing loader conventions. Every size component and the duration must be greater than zero.

A trigger has a unique `id`, exact `type: "collect_count"`, integer `threshold`, and action with exact `type: "open_door"` plus `door_id`. Threshold must be from 1 through `objective.turds_required`, and the referenced door must exist. Reject duplicate IDs, unknown door references, invalid thresholds, invalid dimensions/duration, and unsupported trigger/action values with field-specific errors.

## Door runtime contract

Create reusable `scenes/door.tscn` backed by `scripts/door.gd`. Keep stable child paths `Visual` and `StaticBody3D/CollisionShape3D`. `configure(definition)` applies normalized data before normal use. The door owns `CLOSED`, `OPENING`, and `OPEN` states (numeric 0, 1, 2), `closed_position`, `open_offset`, `open_duration`, and `open_count` for deterministic trusted inspection.

`open() -> bool` returns true exactly once, changes CLOSED to OPENING, increments `open_count` once, and starts a Tween from `closed_position` to `closed_position + open_offset`. Further calls during or after opening return false and do nothing. Tween the door root so visual and static collision move together. On completion set OPEN; do not delete or separately disable collision.

## Runtime ownership and trigger semantics

`RestroomRuntime` owns `doors_by_id`, `trigger_fired`, and `trigger_fire_count`. During gameplay construction it instantiates every configured door and initializes every trigger as unfired with count zero. After—and only after—a successful toilet collection increments `collected_turds`, evaluate unfired triggers. A `collect_count` trigger fires once when `collected_turds >= threshold`, marks itself fired, increments its fire count once, and calls the referenced door's `open()`.

Empty toilets and duplicate collection attempts must not advance the objective or triggers. Existing final-exit unlock and completion logic remains independent and unchanged in behavior.

## Demonstration level

Add `levels/restroom_004.json` with 6–8 collectible toilets, 2–3 empty toilets, two doors, two triggers, and exactly three clearly differentiated sequential areas. Door A opens at two collected turds. Door B opens at four or five. The spawn-to-exit route must be meaningfully long; gates must be ordered along it and span their corridor with ordinary collision geometry preventing side bypasses.

Place enough collectible toilets before each gate to reach its threshold without entering the locked area. Leave at least one collectible beyond Door B, and make every required collectible reachable in the intended sequence. Door movement must be visually obvious and clear the passage without creating a new blocker. The final exit remains locked until all required turds are collected.

## Preservation and scope

Preserve `restroom_001` through `restroom_003`, movement, collision, camera, interaction, collection, HUD, final exit, completion, restart, TB-H01 stabilization, and the accepted TB-R04C character. Do not add pickup feedback, audio, enemies, combat, keys, switches, alternate trigger/action types, schema variants, or TB-R07 work. TB-R05 has no implementation or acceptance suite in the repository and must be reported unavailable, not synthesized in this slice.

## Acceptance and critic

The trusted gate covers legacy normalization, positive and negative schema cases, runtime registries, initially blocking doors, idempotent animated opening with collision moving alongside the visual, one-shot threshold firing, empty/duplicate protection, soft-lock-resistant level ordering, final exit preservation, inherited regressions, six rendered views, Linux build, and exported execution of all four levels.

The independent critic must inspect the implementation and rendered evidence. It must block on a bypassable or unclear gate, inaccessible required collectible, timing-dependent trigger behavior, visual/collision divergence, non-idempotent transitions, character or prior-gameplay changes, tests changed by the coding agent, or scope expansion. Human play QA remains the completion gate.
