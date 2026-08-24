# TB-R03 implementation guidelines

- Inspect `scripts/player.gd`, `scenes/player.tscn`, and the trusted TB-R03 gate before editing.
- Work only in the provided execution worktree and stay within `scripts/player.gd`, `scenes/player.tscn`, and an optional single `scripts/beetle_locomotion.gd` component.
- Prefer a focused implementation in `player.gd`; use the optional component only if it materially improves clarity.
- Capture every animated node's existing neutral transform at `_ready()` and apply procedural offsets relative to those poses.
- Drive gait from actual horizontal velocity, use a small idle threshold, scale frequency by clamped `horizontal_speed / MOVE_SPEED`, and blend a locomotion weight smoothly toward moving/idle targets.
- Use opposing tripods: left-front + left-rear + right-middle versus right-front + right-rear + left-middle.
- Ensure all six legs visibly move, with restrained variation allowed by front/middle/rear role. Keep legs attached and close to the floor.
- Add only a small visual-root bob and optional tiny sway; animate both antennae subtly.
- On stop, smoothly restore legs and Body to their captured neutral transforms. Do not accumulate offsets frame over frame.
- Keep CharacterBody velocity/move_and_slide as the sole root movement authority. Preserve TB-R01 camera-forward facing, strafe, backpedal, diagonal normalization, camera, gravity, collision, and interaction.
- Preserve the TB-R02 anatomy, materials, low-poly identity, descriptive nodes, and external-asset-free construction.
- Do not add Skeleton3D, AnimationPlayer, AnimationTree, rigging, external assets, audio, random animation, or gameplay features.
- Do not modify tests or weaken acceptance. Game Foundry owns validation, critic review, repair, acceptance, and commit creation.
