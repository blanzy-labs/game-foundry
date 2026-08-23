# Bounded repair fixture design

Every repair marker file must contain the marker required by its locked task contract.

Repair marker files must never contain the exact text `FORBIDDEN_DESIGN_MARKER` or `SECOND_FORBIDDEN_MARKER`. Either marker is a locked design violation and must block acceptance even when deterministic validation passes.
