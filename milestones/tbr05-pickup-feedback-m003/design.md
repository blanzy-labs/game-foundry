# TB-R05 — Turd Pickup and Interaction Feedback

Refine the existing turd collection interaction without changing its gameplay rules. The accepted TB-R06 stateful-door and `collect_count` trigger architecture is the current base and remains authoritative.

## Authoritative collection order

A successful `TurdToilet.collect()` must set `has_turd = false` synchronously, accept collection exactly once, and emit `collected` exactly once. `RestroomRuntime` must then synchronously increment `collected_turds`, evaluate TB-R06 triggers, begin any threshold door opening, and unlock the final exit when appropriate. Pickup animation, targeting effects, `+1 TURD`, counter punch, and exit pulse are presentation only. No Tween completion may award collection credit, fire a trigger, open a door, update the objective, or unlock the exit.

At the `restroom_004` threshold of two, the first collection leaves Door A closed. The second immediately makes the count two, fires its trigger exactly once, and starts the door opening while the second pickup feedback remains active. Repeated collection of either robbed toilet changes no gameplay, trigger, door, or HUD-feedback count. Remaining collections preserve Door B, final-exit unlock, and heist completion.

## Toilet-owned feedback

`TurdToilet` exposes `set_targeted(targeted: bool)` and owns the collectible presentation. A valid targeted turd receives a restrained visible lift/scale/pulse. Clearing or changing the target returns the prior collectible toward neutral. Empty and collected toilets refuse targeted state.

Collection starts a 0.15–0.35 second Godot Tween: a quick upward pop/enlargement followed by shrink/fade or hide. During it `has_turd` is already false, the visual may remain visible, and duplicate `collect()` returns false without restarting feedback. Expose deterministic `targeted`, `pickup_feedback_active`, and `pickup_duration` state for trusted acceptance. Tweens must be killed/replaced safely during target changes, collection, free, and scene restart.

## Player interaction

Preserve the existing nearest-in-range search in `BurglarPlayer`. The player selects at most one valid nearest toilet, clears the old target, applies the new target, and asks the runtime to show the prompt. The exact prompt is `E — STEAL TURD`. Empty, collected, out-of-range, and completed-heist states show neither prompt nor target feedback.

## HUD feedback

Every successful collection updates the objective counter immediately, displays `+1 TURD` for roughly 0.5–1.0 seconds with a small drift/fade, and gives the counter a restrained 0.15–0.30 second scale/color punch. Expose `plus_one_label`, `collection_feedback_count`, and `counter_punch_count` so acceptance can prove one presentation event per authoritative collection. Duplicate/empty interactions produce none.

Preserve `EXIT UNLOCKED`; a modest entrance pulse is allowed and should occur once when the final required collectible is accepted. Expose `exit_unlock_feedback_count` for deterministic proof.

## Preservation and exclusions

Preserve TB-R06 door registry, trigger evaluation, one-shot state, door collision, `restroom_004`, final exit, restroom_001 through restroom_003, interaction range, movement, camera, locomotion, character model, toilet model, HUD meaning, completion, and restart. Do not change level data or schema.

Do not add audio, particles requiring new assets, AnimationTree, a generic animation framework, character/model work, movement tuning, hazards, traps, enemies, combat, inventory, scoring, timers, special turds, NPCs, Blender assets, TB-R07, or any unrelated gameplay system.

## Acceptance and critic

The immutable TB-R05 gate proves collection-once semantics, empty rejection, nearest-target handoff, exact prompt behavior, pickup lifecycle, immediate HUD feedback, threshold-two TB-R06 overlap, duplicate protection, all restroom_004 triggers, final exit/completion, inherited regression suites, rendered evidence, Linux export, and exported execution of all four levels.

The independent critic must inspect the patch and rendered evidence. Block if authoritative state waits for presentation, the second threshold door waits for animation, a toilet can collect twice, empty/collected toilets target or prompt, feedback is absent or obstructive, TB-R06/final progression changes, character/movement changes, tests or levels change, audio/unrelated features appear, or evidence does not substantiate the intended visual states. Human pickup/interaction judgment remains the completion gate.
