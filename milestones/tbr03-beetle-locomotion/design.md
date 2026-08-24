# TB-R03 — Beetle Locomotion and Movement Feel

Turn the TB-R02 beetle from a sliding prototype into a grounded, visibly scuttling character using small deterministic procedural transforms. This is presentation only: gameplay movement remains entirely controlled by `CharacterBody3D.velocity` and `move_and_slide()`.

## Gait model

Use an alternating tripod gait built from the existing six named leg nodes:

```text
Tripod A: LegLeftFront, LegLeftRear, LegRightMiddle
Tripod B: LegRightFront, LegRightRear, LegLeftMiddle
```

The two groups must be approximately 180 degrees out of phase; all six legs may not swing together. Give each leg visible rotation and, if useful, a small lift/position offset. Modest front/middle/rear variation is encouraged, but biological simulation is not required.

At `_ready()`, capture the neutral transforms for all legs, Body, abdomen if animated, and both antennae. Every procedural pose must be calculated relative to those immutable neutral transforms rather than assuming zero rotation or accumulating offsets.

Maintain a deterministic walk phase driven by delta and actual horizontal velocity (`Vector2(velocity.x, velocity.z).length()`). Below a small threshold, phase stops. Above it, frequency scales with a safely clamped speed factor based on `horizontal_speed / MOVE_SPEED`. Diagonal input must not overdrive the gait. Reversing phase while backpedaling is preferred if it remains simple and stable, but normal phase is acceptable.

Use a lightweight locomotion weight that approaches one while moving and zero while idle. Scale all gait offsets by it. Starting must not snap immediately to a full pose; stopping must smoothly return all legs, Body bob/sway, and moving-only antenna offsets to rest rather than freezing mid-stride.

## Secondary motion and grounding

Apply a small Body-local vertical bob while moving, approximately 0.02–0.05 units at peak. Optional roll/sway must remain much smaller than leg motion. Both antennae should receive subtle phase-derived response; a tiny deterministic idle sway is allowed. Secondary abdomen motion is optional and must not look detached.

The existing TB-R02 leg geometry already approaches the floor. Preserve or minimally tune Body/leg/collision height only if required to improve apparent contact. The body must remain supported above the floor, legs must not clip deeply, and the simple single capsule must remain compatible with narrow corridors and toilet approaches.

## Preservation and exclusions

Preserve TB-R01 exactly: W camera-forward movement, camera-yaw facing, A/D strafe, S backpedal, normalized diagonals, smooth yaw, and idle camera freedom. Preserve TB-R02's abdomen, thorax, head, mask, six legs, two antennae, scale, primitive-only construction, and criminal beetle identity. Preserve toilet prompts/collection, empty toilets, HUD, exit progression, heist completion, restart, and all three levels.

Do not introduce root motion, Skeleton3D, bone rigging, skin weights, AnimationPlayer, AnimationTree, external animation/model files, Blender, GLB, procedural IK, audio, sprint, jump, stealth, detection, NPCs, traps, power-ups, doors, health, or any other gameplay mechanic.

## Allowed implementation boundary

```text
scripts/player.gd
scenes/player.tscn
scripts/beetle_locomotion.gd   # optional, only if warranted
```

Tests, levels, other gameplay scripts/scenes, schemas, project configuration, and generated artifacts remain locked.

## Acceptance and critic

The trusted gate black-box exercises the actual controller and observes idle stability, moving phase progression, all-six-leg influence, tripod opposition across transform axes, speed-scaled gait path, constrained Body bob/sway, two-antenna response, smooth return to neutral, stopped-phase stability, grounding, collision, every prior slice regression, distinct idle/moving rendered captures, Linux export, and all exported levels.

The critic must block synchronous legs, omitted legs, excessive bouncing, visual-root animation that changes CharacterBody movement, controller regression, external animation infrastructure, or unnecessary complexity. It should judge from source and deterministic evidence whether the implementation is a restrained, maintainable, movement-speed-driven insect gait. Human movement and groundedness judgment remains pending and must not be represented as approved.
