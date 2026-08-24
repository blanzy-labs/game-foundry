# TB-R01 implementation guidelines

- Inspect `scripts/player.gd`, `scenes/player.tscn`, and the trusted TB-R01 acceptance before editing.
- Work only in the provided execution worktree and modify only `scripts/player.gd`.
- Keep movement camera-relative and preserve `MOVE_SPEED`, gravity, collision, input mappings, mouse capture, pitch clamp, interaction range, and gameplay integration.
- Derive moving character facing from camera yaw, not from the current movement vector.
- Keep rotation responsive and smooth; do not snap or add a locomotion state machine.
- Do not rotate the character merely because the player strafes or backpedals.
- Do not force visual character rotation while idle.
- Small testable calculation helpers are welcome, but avoid unnecessary abstraction.
- Do not add jumping, sprinting, crouching, sliding, climbing, stealth, animation, audio, a new character, or level-data changes.
- Do not modify tests or weaken acceptance. Game Foundry owns validation, critic review, acceptance, and commit creation.
