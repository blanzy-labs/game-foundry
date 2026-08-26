# TB-R08 implementation guidelines

- Read the immutable TB-R08 validator and current loader, toilet, player, restroom, hazard, door, and TB-R05–R07 acceptance code before editing.
- Work only in the isolated execution worktree and declared source scope. Game Foundry owns validation, critic review, repair, acceptance, and the commit.
- Normalize toilet special data in the loader and configure each runtime toilet before it enters the tree. Keep low-poly construction and targeting/pickup Tweens intact; change only base material identity.
- Keep `_on_toilet_collected` authoritative: objective, doors, and exit update immediately before or independently of applying the effect; never await presentation or timers.
- Put only Turbo and Ghost timed state on `BurglarPlayer`. Refresh expiry, never multiply existing magnitude. Derive effective speed from the immutable baseline constant.
- Suppress Ghost resets at the runtime consequence boundary while leaving hazard detection, state, cooldown, and activation counting intact. A reset must preserve Turbo.
- Add a small active-effect HUD tied to player effect state; hide it when empty. Do not redesign existing counter, prompt, pickup, exit, or completion UI.
- Make restroom_006 compact, readable, safe without effects, and demonstrative with two of each special type for refresh proof.
- Do not edit tests, prior levels, scenes, `.gitignore`, Game Foundry files, character art, normal movement, camera, collision, audio, generated builds, or unrelated systems. GF-H02 remains authoritative for normal `.uid` metadata.
