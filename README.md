# Game Foundry

An AI-operated, human-directed automation platform for building and operating small Godot games.

Current implementation slice: **GF-WEB-001 — Godot Web export target**.

## Validate workstation

```bash
./scripts/doctor.sh
```

## Machine-readable validation

```bash
./scripts/doctor.sh --json
```

See [the pipeline architecture](docs/architecture/pipeline.md).

## Local project dashboard

Start the dependency-free local dashboard with:

```bash
./scripts/gf-dashboard.sh
```

Then open [http://127.0.0.1:8787](http://127.0.0.1:8787). Set
`GF_DASHBOARD_PORT` to use a different local port.

The dashboard is read-only. Project names and platforms come from
`config/projects.json`; task progress and next actions come from the
authoritative Game Foundry milestone status command. The dashboard cannot
execute, transition, approve, or publish work.

## Run one unattended bounded window

```bash
./scripts/gf-unattended-run.sh --json --max-tasks 1 --max-minutes 45 GF-MILESTONE-ID
```

The command performs recovery before fresh work, delegates execution to the
existing bounded runner, and writes a machine-readable receipt. See the
[GF-009 operating contract](docs/slices/GF-009-scheduled-unattended-execution.md).

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

The reusable static Web release target is documented in
[GF-WEB-001](docs/slices/GF-WEB-001-godot-web-export-target.md). It produces and
integrity-verifies a Godot Web bundle; browser execution and site deployment
remain separate later slices.

The first real game workload is recorded in the [TB-001 evidence summary](reports/tb-001/evidence-summary.md).

The data-driven level factory is recorded in the [TB-002 evidence summary](reports/tb-002/evidence-summary.md).

The deterministic milestone control plane is documented in [GF-003](docs/slices/GF-003-milestone-contract.md).
Review the source-controlled [GF-003 evidence summary](reports/gf-003/evidence-summary.md).
