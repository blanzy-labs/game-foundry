# Game Foundry

An AI-operated, human-directed automation platform for building and operating small Godot games.

Current status: **GF-001 — end-to-end acceptance**.

## Validate workstation

```bash
./scripts/doctor.sh
```

## Machine-readable validation

```bash
./scripts/doctor.sh --json
```

See [the pipeline architecture](docs/architecture/pipeline.md).

## Run end-to-end acceptance

```bash
./scripts/gf-001-acceptance.sh
```

Run controlled fail-closed checks with:

```bash
./scripts/gf-001-failure-tests.sh
```

Review the source-controlled [GF-001 evidence summary](reports/gf-001/evidence-summary.md).

Production-gate hardening and fault-injection guidance are documented in [GF-002](docs/slices/GF-002-production-gate-hardening.md).
Review the source-controlled [GF-002 evidence summary](reports/gf-002/evidence-summary.md).

The first real game workload is recorded in the [TB-001 evidence summary](reports/tb-001/evidence-summary.md).
