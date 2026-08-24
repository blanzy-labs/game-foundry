# TB-R04 — Beetle Aesthetic and Costume Refinement

Refine the accepted primitive-built protagonist so the face, costume, and silhouette read as one intentional low-poly criminal dung beetle. Preserve the established squat insect anatomy, grounded articulated gait, movement, camera, interaction, progression, and three-level compatibility.

## Face and eye integration

Preserve a dark burglar mask but make it and the eyes a single face design. Move `EyeLeft` and `EyeRight` beneath either the `Head` or `Mask` hierarchy so they are genuinely integrated rather than floating sibling blocks. Inset slit-like or small rectangular eye openings are preferred. Keep them separated and bright or emissive enough to read from the ordinary camera without becoming cute, round, realistic, or oversized.

The stable mesh-bearing `Head` and `Mask` identities must remain discoverable. A Node3D wrapper with primitive mesh descendants is acceptable when required for hierarchy. The visual front remains local negative Z.

## Striped thorax costume

Add a mesh-bearing `Shirt` hierarchy around the thorax/upper body. It should suggest a crude sleeveless burglar tunic on an insect, not human clothing. Give it at least three clearly named `Stripe*` mesh descendants with strong light/dark contrast—dirty cream against charcoal or black is preferred. Make stripe bands broad enough to survive gameplay distance and conform through simple primitive pieces around the thorax. Do not add sleeves, cloth simulation, or hide the thorax segmentation and six leg attachments.

The costume may overlap the very front of the abdomen only when it improves coherence. At most one optional simple burglar cue is allowed, but it is not required and must not clutter the silhouette.

## Style and construction

Preserve the dark brown, black, and purple-black shell palette against the neon environment while using the bright eyes and shirt stripes to clarify front and identity. Keep the result scrappy, angular, funny, slightly ugly, and reminiscent of a late-1990s bargain-bin 3D game—not polished, realistic, or mascot-like.

Use only Godot-native primitive meshes and source-controlled scene construction. No external models, textures, skeletal rig, animation system, Blender dependency, or generated bitmap asset is permitted.

## Preservation and exclusions

Preserve the six stable two-segment leg roots and two antennae. Preserve the complete TB-R03A neutral-relative grounded gait and all `player.gd` movement, facing, body articulation, and idle recovery unless a minimal hierarchy-path adjustment is strictly necessary. Preserve the capsule, speed, gravity, camera, interaction range, turd collection, empty toilets, HUD, exit progression, heist completion, restart, and all three restroom levels.

Do not add audio, stealth, doors, traps, power-ups, health, combat, new mechanics, rigging, IK, terrain solving, or animation overhaul.

## Absolute implementation boundary

```text
scenes/player.tscn
scripts/player.gd
```

Tests, levels, other runtime files, configuration, schemas, and generated artifacts remain locked.

## Acceptance and critic

The trusted gate requires a loadable player scene; mesh-bearing Body, Head, Mask, Shirt, six legs, and two antennae; `EyeLeft` and `EyeRight` integrated beneath Head or Mask with readable materials; three or more high-contrast named shirt stripe meshes; primitive-only construction; the entire TB-001 through TB-R03A regression chain; normal gameplay and close three-quarter screenshots; Linux export; and runtime checks for all three levels.

The independent critic must inspect source, deterministic evidence, and rendered screenshots. Block floating or unreadable eyes, a mask/eye design that no longer reads as a face, missing or illegible stripes, a humanoid costume, obscured insect segmentation or legs, lost beetle identity, non-primitive/external assets, locomotion or gameplay changes, weak ordinary-distance readability, or scope expansion. Human judgment remains authoritative for whether the character is funny, coherent, memorable, and protagonist-ready; the critic must not claim final human aesthetic approval.
