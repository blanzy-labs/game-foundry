# TB-R01 — Player Movement and Camera Refinement

Refine the existing third-person controller so the camera defines the visible character's forward orientation during movement.

## Control model

Movement remains camera-relative:

- W moves camera-forward.
- A and D move sideways relative to the camera.
- S moves backward relative to the camera.
- Diagonal input remains normalized and cannot exceed `MOVE_SPEED`.

While any movement input is active, the character's target yaw is camera yaw. The visible body must smoothly approach that yaw with responsive, non-twitchy interpolation. It must not derive target yaw from the movement vector: strafing must look like strafing instead of a 90-degree turn, and backward movement must look like backpedaling instead of a 180-degree pivot.

When there is no movement input, camera yaw may change without forcing the character to rotate. On the next movement input, the character smoothly aligns to camera-forward.

## Preservation requirements

Preserve the existing mouse yaw, mouse pitch, pitch clamp, mouse capture and Escape behavior. Preserve approximately the current speed, with `MOVE_SPEED` preferably unchanged. Preserve gravity, ground behavior, collision, toilet interaction and prompt distance, collection, dynamic objective/HUD, exit lock/unlock, heist completion, and restart.

Do not add jump, sprint, crouch, slide, climb, stealth, traps, doors, triggers, power-ups, audio, animation, or a new player character. The placeholder burglar remains until TB-R02. Do not change any level data; `restroom_001`, `restroom_002`, and `restroom_003` must all remain playable.

## Absolute implementation boundary

The implementation may modify only:

```text
scripts/player.gd
```

The trusted `tests/run_tbr01_acceptance.sh` and all existing acceptance files are locked outside the task scope. Do not change scripts other than `player.gd`, scenes, levels, project configuration, schemas, tests, assets, or generated artifacts.

## Deterministic acceptance

The trusted gate executes the real player controller and proves camera-forward movement at zero and rotated yaw, camera-forward facing during left/right strafe and backpedal, normalized diagonal speed, smooth non-snapping alignment, idle camera freedom, preserved mouse/pitch behavior, TB-001/TB-002/TB-003 gameplay regressions, Linux export, and exported runtime loading for all three levels.

## Independent critic focus

The critic must block explicit control-model violations or inappropriate scope growth. It should verify that movement remains camera-relative; moving facing follows camera-forward; strafe does not rotate the body sideways; backpedal does not force a 180-degree turn; idle camera freedom remains; interaction and gameplay are preserved by the trusted regression evidence; and the implementation is small and appropriate. Warnings may pass. The critic must not claim subjective movement quality has passed; human movement QA remains authoritative.
