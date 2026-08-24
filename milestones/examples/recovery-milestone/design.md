# Recovery fixture design

Each task creates exactly its required marker in `fixtures/recovery-project/src/`. Marker files must remain within the declared task scope and must not contain `FORBIDDEN_DESIGN_MARKER` or `SECOND_FORBIDDEN_MARKER`.

Task 2 depends on task 1 so recovery can prove that reconciliation unblocks, but does not execute, descendant work.
