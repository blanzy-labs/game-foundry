# TB-R02 — Dung Beetle Player Identity

Replace Turd Burglar's temporary capsule/head humanoid with a crude, distinctive low-poly dung beetle burglar. This is a visual identity slice, not a gameplay expansion.

## Character direction

The protagonist must immediately read as both **dung beetle** and **burglar**: small, determined, suspicious, ridiculous, and slightly criminal rather than realistic or frightening. Target a deliberately cheap late-1990s/early-2000s PC-game look. Avoid a polished mascot, smooth modern toy, realistic insect, detailed PBR asset, or high-poly character.

Build everything in `scenes/player.tscn` from source-controlled Godot primitive mesh subresources. No Blender, GLB, FBX, downloaded asset, asset-store dependency, external model, AI-generated 3D model, or animation system is allowed.

## Required anatomy

Keep `Body` as the stable rotating visual root and place all visible parts beneath it. Required direct named children are:

```text
Abdomen
Thorax
Head
Mask
AntennaLeft
AntennaRight
LegLeftFront
LegLeftMiddle
LegLeftRear
LegRightFront
LegRightMiddle
LegRightRear
```

Each required part must contain visible primitive geometry. Additional child segments may be used sparingly. The abdomen is the largest rounded/faceted rear shell, the thorax is a smaller distinct middle segment, and the head is smaller again. Six legs must visibly angle outward/downward. Antennae must be chunky enough to remain readable. A near-black mask must remain visible at normal gameplay distance. One small additional criminal cue is optional, but visual clutter is not.

Use only `SphereMesh`, `CapsuleMesh`, `BoxMesh`, and `CylinderMesh`, with low radial/ring counts where applicable. Prefer a limited dark-brown, blackened-purple, charcoal, muted-violet palette with small contrasting details. Visible facets and simple silhouettes are desirable.

## Orientation, scale, collision, and camera

The visual forward direction is -Z, matching TB-R01 at yaw zero. From rear to front the abdomen, thorax, and head must advance toward -Z; the mask sits in front of the head and antennae project toward the front. All visual parts rotate together when `Body.rotation.y` follows camera yaw.

Target approximately 0.9–1.3 world units of visual height, with a chunky but corridor-safe width and length. Use one simple capsule collision, modestly resized and repositioned to approximate the shorter beetle without enabling wall clipping or blocking existing passages. Adjust `CameraPivot` height only if helpful for framing; do not materially change spring-arm length, FOV, mouse sensitivity, movement speed, or interaction range.

## Gameplay preservation

TB-R01 remains authoritative: W is camera-forward, A/D strafe without sideways facing, S backpedals without a 180-degree turn, diagonal input remains normalized, moving yaw aligns smoothly to camera-forward, and idle camera rotation remains free. Preserve gravity, ground behavior, collision navigation, toilet prompts and collection, empty toilets, HUD, exit lock/unlock, heist completion, and restart across all three levels.

Do not add animation, IK, walking legs, antenna physics, a turd bag, carried inventory, rolling, sprint, jump, burrowing, flight, stealth, detection, health, power-ups, traps, audio, or any other mechanic.

## Absolute implementation boundary

The implementation may modify only:

```text
scenes/player.tscn
scripts/player.gd
```

The controller should change only if necessary to rotate the complete visual hierarchy. Tests, levels, other scripts/scenes, configuration, and generated artifacts are locked outside scope.

## Acceptance and critic

The trusted TB-R02 gate owns deterministic anatomy, primitive/low-poly, orientation, visual-scale, collision/camera, TB-R01 and earlier regression, rendered-evidence, Linux-export, and exported-runtime acceptance. It captures one normal third-person screenshot and one close three-quarter character screenshot. Human visual and movement judgment remains pending.

The independent critic must assess whether the patch unmistakably constructs a dung beetle with a burglar cue, fits the crude low-poly aesthetic, has an obvious correct front, is appropriately scaled, avoids unnecessary complexity and external dependencies, preserves TB-R01, and adds no gameplay. Clear failures such as fewer than six legs, no mask, humanoid retention, backward orientation, external model usage, or movement regression are blockers. Subjective polish observations may be warnings and must not be represented as human approval.
