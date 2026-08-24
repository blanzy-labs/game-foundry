# TB-R04A — Shell Stripe Placement Refinement

Correct the accepted TB-R04 costume in response to authoritative human QA. Its five stripe centers currently span local Y `0.3800` and local Z `0.0000`, creating a top-to-bottom human-shirt reading. Replace that vertical stack with a bold front-to-rear shell wrap whose stripes read as markings or bands on the beetle's carapace.

## Orientation and placement

Distribute the stripe elements along the beetle's local length axis (Z), beginning behind the dark head and continuing across the thorax/first body segment. Stripe-center Z span must be meaningfully larger than Y span and meet the trusted minimum. Keep the stripe centers at a substantially common height rather than rebuilding a vertical torso stack.

The treatment should visually wrap around the front segment as painted exoskeleton, a shell skin, or carapace banding. Rotated low-segment cylinders, shell-conforming primitive bands, or a simpler replacement hierarchy are acceptable. Preserve the stable mesh-bearing `Shirt` node required by TB-R04, though visually it should no longer resemble fabric or a tunic.

Confine the bands to the front body. Do not project beyond the head or spread so far back that the whole beetle becomes striped. The large rear `Abdomen` stays visibly dark and separate, establishing a clear head → striped thorax/front segment → dark rear shell sequence.

## Readability and style

Preserve broad alternating dirty-cream and charcoal/black contrast so the shell banding survives normal gameplay distance. Keep the scrappy, funny, low-poly bargain-bin character style. Favor a simple strong silhouette over small detailing. Do not add stitching, sleeves, fabric simulation, a humanoid garment shape, or realism.

## Preservation and exclusions

Preserve the TB-R04 integrated emissive mask eyes, dark mask/head, six articulated legs, two antennae, squat dung-beetle proportions, and primitive-only construction. Preserve TB-R01 movement, TB-R03 locomotion, TB-R03A grounded gait and body articulation, the capsule, camera, interaction, collection, HUD, exit progression, heist completion, restart, and every level.

Do not add external assets, textures, rigging, animation infrastructure, audio, stealth, doors, traps, power-ups, or gameplay systems.

## Absolute implementation boundary

```text
scenes/player.tscn
scripts/player.gd
```

Prefer `scenes/player.tscn` alone. Tests, levels, other runtime files, configuration, schemas, and generated artifacts remain locked.

## Acceptance and critic

The trusted gate requires at least three stripe meshes distributed front-to-rear with Z-center span at least `0.26`, Y-center span no more than `0.14`, and Z dominance at least `1.8×` Y. It requires front-shell placement, a contrasting dark rear abdomen, the integrated face, all legs and antennae, the entire TB-001 through TB-R04 regression chain, side/three-quarter and gameplay screenshots, Linux export, and all three exported runtimes.

The independent critic must inspect the source and rendered evidence for a horizontal shell/carapace reading. Block a remaining vertical human-shirt impression, poor front/rear segmentation, bands covering the rear abdomen, loss of mask/beetle identity, tiny unreadable stripes, locomotion/gameplay changes, external assets, or scope expansion. Human judgment remains authoritative for the final shell-versus-shirt impression and humor; the critic must not claim final human aesthetic approval.
