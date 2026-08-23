# Independent critic fixture design

Every critic marker file must contain the marker required by its task contract.

Critic marker files must never contain the exact text `FORBIDDEN_DESIGN_MARKER`. This is an explicit locked design requirement and any candidate containing that text must be blocked from acceptance even if deterministic validation passes.
