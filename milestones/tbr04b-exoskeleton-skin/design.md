# TB-R04B — Striped Exoskeleton Skin Correction

Human QA rejected the accepted TB-R04 costume because `Body/Shirt` plus its base and five Y-stacked cylinders reads as a tiny human shirt, belt, or ring stack. Fundamentally replace that construction: the beetle is not wearing a garment; the front shell itself has burglar stripes.

## Required deletion and replacement

Delete the entire `Body/Shirt` hierarchy and its obsolete shirt/base/ring resources. Do not rotate, reposition, rename, or disguise those cylinders. No separate tubular costume, concentric band meshes, garment thickness, floating stripes, air gap, or outer shell may remain.

Apply the striped treatment to the stable mesh-bearing `Thorax`/front shell itself. The preferred implementation is a deterministic spatial `ShaderMaterial` directly on the thorax primitive. Use local `VERTEX.z` to select 3–5 broad bands progressing from front to rear, with individual bands crossing left-to-right over the shell. Expose `stripe_light`, `stripe_dark`, and `stripe_count` shader parameters. Use dirty cream and near-black/charcoal with simple diffuse low-poly lighting; avoid polish, glow, animation, and high-tech effects.

An alternative is allowed only if `Thorax` becomes the actual container for 3–5 closely joined, non-cylinder primitive shell pieces named `ShellStripe*`. Those pieces must replace—not cover—an underlying thorax mesh, distribute along local Z at a common height, and form the front shell surface without gaps or garment thickness.

## Anatomy and coverage

Preserve the sequence dark Head/Mask → striped Thorax/front shell → dark rear Abdomen. The striped surface should cover approximately the forward 35–55% of the main body behind the head. Do not stripe the entire abdomen. Preserve strong dark rear contrast and the visible separation between front and rear shell segments.

## Style and preservation

Keep the scrappy low-poly bargain-bin character style. Preserve the TB-R04 integrated emissive eyes and dark mask, both antennae, all six articulated two-segment legs, squat dung-beetle silhouette, TB-R03A gait/body motion, camera-relative movement, collision, interaction, collection, HUD, exit progression, completion, restart, and every level.

Use only Godot-native deterministic scene/material resources. Do not add external models or textures, skeletal/animation infrastructure, locomotion changes, level edits, audio, stealth, doors, traps, power-ups, or gameplay.

## Absolute implementation boundary

```text
scenes/player.tscn
scripts/player.gd
```

Prefer `scenes/player.tscn` alone. Tests and all other files remain locked.

## Acceptance and supersession note

TB-R04B intentionally supersedes only TB-R04's old structural assertion that a `Shirt` node exists; that immutable historical test is not applicable to a correction whose hard requirement is deleting the node. The new trusted gate directly preserves TB-R04's face, mask, eyes, low-poly character identity, and all earlier regressions while requiring the opposite costume topology. No historical test is edited or weakened.

The gate requires no `Body/Shirt`; a Z-driven striped material directly on `Thorax` or actual joined replacement shell segments; a separately dark Abdomen; integrated eyes/mask; antennae; six Upper/Lower leg hierarchies; TB-001 through TB-R03A regressions using authoritative TB-H01 spawn stabilization; top/high-three-quarter, side-three-quarter, and gameplay evidence; Linux export; and every exported level.

The independent critic must use the mandatory rendered evidence to answer: does this look like striped exoskeleton/carapace coloration rather than a separate human-style shirt, belt, or stack of rings? Block visible outer rings/tubes, Y-stacked stripes, garment edges or gaps, lack of head-to-abdomen progression, stripes that do not cross left-to-right, loss of the dark rear abdomen, unreadability, locomotion/gameplay changes, or scope expansion. The critic must not claim final human aesthetic approval.
