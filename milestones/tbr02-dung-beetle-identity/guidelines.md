# TB-R02 implementation guidelines

- Inspect the current player scene, TB-R01 controller, and trusted TB-R02 acceptance before editing.
- Work only in the provided execution worktree and modify only `scenes/player.tscn` and, if genuinely necessary, `scripts/player.gd`.
- Prefer no controller change: retain the stable `Body` node as a rotating `Node3D` visual root with all beetle parts beneath it.
- Build the character entirely from `SphereMesh`, `CapsuleMesh`, `BoxMesh`, and/or `CylinderMesh` subresources using deliberately low segment counts.
- Use descriptive deterministic node names required by the trusted test.
- Make the abdomen largest, then thorax, then a separate head; add exactly three visibly projecting legs per side and two chunky antennae.
- Make -Z the clear front, consistent with the existing controller and camera. Place the head, mask, and antennae toward -Z.
- Preserve the crude bargain-bin 1999–2002 aesthetic with a dark shell, subtle facet/highlight variation, readable near-black burglar mask, and limited materials.
- Keep the visual roughly 0.9–1.3 units tall and modestly adjust the single capsule collision and camera-pivot height only if required.
- Preserve `MOVE_SPEED`, movement/facing behavior, mouse controls, gravity, interaction range, progression, restart, and every level.
- Do not add external assets, animation, a rig, procedural movement, audio, stealth, abilities, inventory visuals, or any gameplay feature.
- Do not modify tests or weaken acceptance. Game Foundry owns validation, critic review, repair, acceptance, and commit creation.
