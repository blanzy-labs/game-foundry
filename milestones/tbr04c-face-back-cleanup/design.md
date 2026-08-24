# TB-R04C — Face and Back Cleanup Refinement

Perform a narrow visual cleanup after the accepted TB-R04B striped exoskeleton. Human QA identified two remaining issues: `Body/ShellSeam` appears as an unexplained thin bar or handle on the abdomen, and the two emissive rectangular eye blocks still project from the mask like pasted-on robot parts.

## Back cleanup

Remove `Body/ShellSeam` and its obsolete mesh resource. The default and required result is a clean dark rear abdomen with no bar, handle, floating ridge, or replacement artifact. Do not spend scope inventing a new back accessory.

## Face cleanup

Preserve the stable `Mask`, `EyeLeft`, and `EyeRight` identities and the amber emissive readability, but refine each eye into a restrained horizontal slit embedded in the mask surface. Keep each eye as a low-poly `BoxMesh` descendant of `Mask`, with width approximately `0.06–0.13`, height at most `0.045`, and depth at most `0.014`. Place it so the thin mesh intersects the mask's front plane: visible enough to glow, but projecting no more than the trusted shallow tolerance.

The result should read as eye openings in a dark burglar face, not bright cubes pasted onto a robot bug. Preserve clear left/right separation and forward direction. Do not add realistic eyeballs, oversized cartoon eyes, detailed facial anatomy, extra face machinery, or new external assets.

## Preservation

Preserve the TB-R04B implementation exactly in concept: no `Shirt`; the stable `Thorax` carries the static, matte, local-Z striped ShaderMaterial; the rear `Abdomen` stays separately dark. Preserve the dark head/mask, antennae, six articulated Upper/Lower legs, squat beetle silhouette, grounded gait, Body/Thorax/Abdomen articulation, controller, collision, camera, interaction, collection, HUD, exit progression, completion, restart, and every level.

Do not change locomotion, gameplay, levels, TB-H01 stabilization, shader stripe direction, or body segmentation. Only tiny face geometry/material placement changes and bar removal belong in this slice.

## Absolute implementation boundary

```text
scenes/player.tscn
scripts/player.gd
```

Prefer `scenes/player.tscn` alone. Tests and all other files remain locked.

## Acceptance and critic

The trusted gate requires `ShellSeam` and back-bar/handle replacements to be absent; thin emissive BoxMesh eyes beneath Mask that intersect rather than protrude significantly from its front plane; preserved eye separation; the exact TB-R04B no-shirt Z-striped thorax contract; a separately dark rear abdomen; antennae; six articulated legs; TB-001 through TB-R04B regression behavior with TB-H01 stabilization; front-three-quarter, rear/side, and gameplay screenshots; Linux export; and all exported levels.

The independent critic must inspect all rendered views and block if any accidental back bar remains, the eyes still read as pasted-on glowing blocks, face direction/cohesion regresses, striped shell or rear segmentation regresses, movement/gameplay changes, or scope expands. Human QA remains authoritative for the final face/back aesthetic judgment.
