# GF-000 — prerequisites and bootstrap

GF-000 establishes the reusable workstation validator and a minimal Godot smoke fixture. It does not implement a game.

## Validation

Run the human-readable and machine-readable checks:

```bash
./scripts/doctor.sh
./scripts/doctor.sh --json | jq .
```

Prove that the validator rejects invalid GDScript without changing the tracked fixture:

```bash
./scripts/self-test.sh
```

The self-test first requires the valid fixture to print `GAME_FOUNDRY_GODOT_SMOKE_OK`, then creates a temporary broken copy and requires Godot to reject it.

## User-local Godot layout

When `/opt` cannot be written without interactive elevation, the official Standard binary may be installed at:

```text
~/.local/lib/game-foundry/godot/4.7.2/godot
```

with `~/.local/bin/godot` pointing to it. Matching Standard export templates belong in:

```text
~/.local/share/godot/export_templates/4.7.2.stable
```

