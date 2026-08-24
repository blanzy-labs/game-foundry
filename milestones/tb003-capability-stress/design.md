# TB-003 — Existing-Capability Level Stress Design

Create the strongest, most interesting new playable Turd Burglar level possible using only gameplay and level capabilities already present in the locked target repository.

## Absolute implementation boundary

The implementation may create only:

```text
levels/restroom_003.json
```

No runtime gameplay feature may be added. Do not modify scripts, scenes, schemas, tests, `project.godot`, `game.yaml`, or `export_presets.cfg`. Do not extend the level loader or JSON schema. A limitation in the current capability set must be worked around creatively or left unimplemented; never add a feature to make the level easier to build.

Use only the fields and semantics proven by `scripts/level_loader.gd`, the existing runtime, `levels/restroom_001.json`, `levels/restroom_002.json`, and `docs/tb003-current-capability-inventory.md`.

## Creative brief

Create a sprawling, ridiculous neon restroom labyrinth that feels materially larger, stranger, and more intentional than First Flush or Second Flush. It must feel like a genuinely new level, not a longer row of stalls. Choose the level name, precise layout, palette, routes, toilet arrangement, lighting, signage, jokes, and landmarks.

The layout must provide:

- at least four visually distinct areas or zones;
- at least one central or transitional space connecting multiple routes;
- at least one meaningful branch;
- at least two intentional dead-end or decoy concepts;
- at least one return through a previously seen area;
- spawn and exit in meaningfully separated map regions;
- ground-based required traversal with no jumping or climbing;
- enough visual structure to remain understandable without a minimap.

Use box geometry as more than a floor, perimeter, and stall dividers. Compose corridors, alcoves, islands, partitions, false rooms, columns, overhead/non-colliding decoration, colored sectors, transitions, and visual landmarks where useful. Geometry remains axis-aligned.

Use lighting colors to give zones recognizable identity and navigation value. Use short, readable 3D signs for directions, misdirection, zone names, fake warnings, exit hints, or crude jokes. Empty toilets must be deliberate false rewards or decoys, including at least one tempting empty toilet.

Include at least two small surprises using only existing capabilities, such as a misleading sign, hidden-looking empty-toilet alcove, unexpected lighting reveal, false route, sudden large chamber, strange toilet arrangement, or box-geometry visual gag.

## Quantitative bounds

The accepted level must contain:

- 10–16 total toilets;
- at least 6 collectible toilets;
- at least 3 empty toilets;
- 30–70 box geometry primitives;
- 6–14 labels;
- 6–12 lights;
- at least 3 distinct light colors;
- multiple floor/wall colors;
- four spatial toilet zones;
- empty-toilet decoys in at least two spatial zones;
- a practical footprint at least 24 by 24 units and no larger than 80 by 80 units.

`id` must be `restroom_003`. `objective.turds_required` must exactly equal the number of `has_turd: true` toilets. All IDs/names required to be unique by the loader or trusted test must be unique.

Keep player spawn, exit, and all toilets effectively at ground level. Do not place required content behind impassable walls or in elevated locations. Prefer 10–16 toilets, 6–10 collectibles, 35–70 boxes, 6–14 labels, and 6–12 lights; purposeful composition matters more than inflated counts.

## Existing levels and acceptance

`levels/restroom_001.json` and `levels/restroom_002.json` must remain byte-for-byte unchanged. The trusted `tests/run_tb003_acceptance.sh` gate owns structural, loader, runtime, gameplay, regression, rendering, Linux export, and exported-level-selection acceptance. Do not modify or weaken it.

The independent critic must judge existing-capability compliance, material difference from the first two levels, structural requirements, intentional composition, visual zoning, deliberate empty-toilet use, signage, and any attempted schema or gameplay expansion. It must not claim that the level is fun; human gameplay QA remains authoritative.
