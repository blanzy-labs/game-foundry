# TB-R03A — Grounded Gait and Body Articulation

Refine the accepted TB-R03 procedural locomotion in response to authoritative human QA: the gait exists, but leg motion is too restrained, the body is rigid, and the beetle still appears suspended. The goal is to make six legs visibly support and propel the body across flat restroom floors without adding a mechanic or replacing the locomotion system.

## Measured starting point

The trusted diagnostic measures the lowest TB-R03 single-leg geometry at approximately local Y `0.0891` relative to a local floor plane near zero. The capsule already navigates all levels and its bottom aligns near local zero. The likely visual-grounding problem is therefore the single rigid, mostly lateral leg bars and their slightly elevated endpoints—not a physics failure.

Prefer fixes in this order: leg geometry, attachment pose, visual Body offset if necessary, minor articulation tuning, and collision only if objective evidence requires it. Do not blindly lower the entire player or resize the capsule.

## Two-segment leg architecture

Preserve the six stable direct children of `Body`:

```text
LegLeftFront     LegRightFront
LegLeftMiddle    LegRightMiddle
LegLeftRear      LegRightRear
```

Convert each into a `Node3D` articulation root with mesh-bearing descriptive `Upper` and `Lower` descendants (Lower may be nested through Upper). The authored neutral pose must visibly angle the Upper outward from the shell and the Lower down toward a contact endpoint. All six Lower endpoints should rest close to local floor Y, within the trusted tolerance and without deep penetration. A separate foot mesh is optional and must remain primitive and simple.

At runtime capture neutral transforms from the scene for every leg root, Upper, Lower, Body, Thorax, Abdomen, and antenna. Never assume zero authored rotation and never accumulate animation offsets.

## Refined gait

Preserve the TB-R03 speed-driven phase, threshold, blend, and tripods:

```text
Tripod A: left-front, left-rear, right-middle
Tripod B: right-front, right-rear, left-middle
```

Strengthen visible sweep approximately 20–40 percent over the original restrained result. Upper performs the main forward/back swing with modest role variation. Lower performs complementary bend/extension: lifted and bent during forward swing, extended down during the slower support/push portion. A clamped or asymmetric curve is preferable to a fully symmetric floating sine. Each leg must demonstrate a lower endpoint height difference between support and swing while returning close to the floor in support.

Keep the existing smooth locomotion weight for start/stop. When idle, roots, Upper, Lower, Body, Thorax, and Abdomen converge to the authored grounded neutral pose. Forward, strafe, backpedal, and diagonal inputs use the same simple gait; do not add a state machine or separate locomotion modes.

## Body weight and articulation

Tie subtle presentation-only weight transfer to tripod support:

- Body vertical compression/bob remains roughly 0.02–0.04 units.
- Body roll alternates toward the supporting tripod at roughly 1–3 degrees and stays below safe automated limits.
- Thorax receives approximately 1–2 degrees of pitch/roll.
- Abdomen receives smaller opposing roll/counter-motion so the insect feels articulated but coherent.
- Optional head lag must be extremely small and may be omitted.
- Existing antenna motion remains subtle and may be reduced if combined motion becomes distracting.

All motion is local to the visual hierarchy. CharacterBody velocity and `move_and_slide()` remain the only world-motion authority.

## Preservation and exclusions

Preserve TB-R01 movement/facing/camera behavior, TB-R02 character identity, and TB-R03 velocity-driven gait architecture. Preserve the single capsule, interaction range, gravity, speed, camera, turd collection, empty toilets, HUD, exit progression, heist completion, restart, and every level unless a narrowly evidenced visual adjustment is required.

Do not add Skeleton3D, AnimationPlayer, AnimationTree, IK, raycast feet, terrain placement, external model/animation assets, audio, sprint, jump, stealth, detection, doors, traps, power-ups, health, combat, or any new gameplay.

## Absolute implementation boundary

```text
scenes/player.tscn
scripts/player.gd
```

Tests, levels, other runtime files, configuration, schemas, and generated artifacts remain locked.

## Acceptance and critic

The trusted gate measures authored Lower endpoint height, all-six Upper/Lower influence, support-versus-swing endpoint separation, tripod opposition, Body amplitude, Thorax articulation, smaller opposing Abdomen motion, full idle recovery, every previous regression, low-angle idle/moving screenshots, Linux export, and every exported level. Human perception of contact and weight remains the primary final gate.

The independent critic must focus on grounded authored geometry, meaningful two-segment participation, alternating support, restrained coherent body articulation, neutral-relative simplicity, and preservation of root gameplay movement. Suspended legs, decorative but unused Lower segments, synchronous bends, deep floor clipping, excessive bounce/wobble, root-motion changes, movement regression, or unnecessary rig/IK infrastructure are blockers. It must not claim human visual approval.
