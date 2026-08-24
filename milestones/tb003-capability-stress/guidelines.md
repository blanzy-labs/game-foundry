# TB-003 implementation guidelines

- Inspect the current loader, runtime, existing levels, capability inventory, and trusted TB-003 acceptance before designing.
- Work only in the provided execution worktree and create only `levels/restroom_003.json`.
- Use valid existing JSON fields exactly as the loader defines them.
- Do not add runtime code, scenes, schema fields, assets, tests, configuration, or generated artifacts.
- Keep all required traversal flat, reachable, and understandable.
- Make empty toilets, signs, lighting, and geometry express deliberate route design rather than random quantity.
- Preserve both existing level files exactly.
- Do not commit or alter Game Foundry state. Game Foundry owns validation, critic review, acceptance, and commit creation.
