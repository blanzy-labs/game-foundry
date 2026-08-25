# TB-R08 — Timed / Special Turds

TB-R08 builds on human-approved TB-R07 commit `448ec03` and its accepted doors, pickups, hazards, movement, objectives, Linux runtime, and critique evidence. The test-bearing source base adds only the immutable TB-R08 gate.

## Collectible data and authority

Individual toilets gain optional `turd_type`, supporting exactly `normal`, `turbo`, and `ghost`; missing values normalize to `normal`. All turds remain one-shot ordinary objective collectibles. Turbo requires finite positive `effect_duration` and finite `effect_value > 1.0`; Ghost requires finite positive duration; normal requires neither. Unknown types and malformed/non-positive properties fail closed.

Collection remains synchronous and authoritative: `has_turd=false`, emit `collected` exactly once, increment objective, evaluate collect-count triggers, evaluate final exit, activate the special effect, while the existing pickup presentation continues independently. Duplicate collection never increments, fires, refreshes, or restarts feedback.

## Two explicit effects

`BurglarPlayer` owns only two independent temporary states through a small explicit API. Turbo (`HOT SHIT`) multiplies effective movement speed by its configured value without changing the baseline constant, acceleration/direction, camera, collision, or gait. Ghost (`GHOST TURD`) suppresses only the TB-R07 reset consequence while a reset zone still detects a legitimate entry. Same-type collection refreshes duration without stacking magnitude; different effects coexist. Timers decrease and expire deterministically, returning speed and immunity exactly to baseline. Restart naturally creates a clean player.

Ghost expiry while standing in a hazard does not force a reset; leaving and re-entering restores normal reset behavior. A normal hazard reset does not clear or refresh Turbo. No hazard is removed or disabled. Emit deterministic start, refresh, expiry, and Ghost-block markers.

Special turds retain the existing low-poly geometry and TB-R05 targeting/pickup presentation but have clearly different materials: normal brown, Turbo warm/emissive, Ghost pale spectral/emissive. Add a small existing-style HUD area listing only active effects with readable decreasing time. No inventory, activation input, generalized notification/effect framework, audio, health, damage, lives, scoring, weapons, stealth, NPCs, or permanent upgrades.

## restroom_006

Create a compact level, preferably `Hot Load`, with 8–10 collectibles including at least five normal, two Turbo, and two Ghost turds, 2–3 empty toilets, exactly two existing-style doors/triggers, at least two reset hazards, and three or more traversal areas. Turbo is noticeable but never required. Ghost offers a hazard shortcut while a reasonable safe route remains. Expiration cannot create a soft lock and the final exit remains completable.

## Proof and boundaries

The immutable validator proves legacy normalization, schema failures, distinct materials plus targeting, exact objective/door order, duplicates, controlled boosted movement, refresh without stacking, simultaneous independent timers, HUD countdown cleanup, Ghost crossing and post-expiry reset, Turbo through reset, final completion, nine evidence states, every current regression, Godot validation, Linux export, and exported runtime for restroom_001–006.

Do not modify prior levels, tests, character model, baseline movement/camera/collision/gait, door authority, hazard data, audio, assets, or unrelated gameplay. Do not begin detection/stealth or audio work. Human special-turd QA remains pending.
