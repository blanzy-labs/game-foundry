# GF-001 negative-test evidence

A negative-test **PASS** means the injected defect was correctly rejected.

| Test | Detection | Critical pipeline exit | Key evidence |
|---|---:|---:|---|
| A — Broken GDScript | TRUE | 1 | Godot exit 1; Parse Error present |
| B — Wrong token | TRUE | 1 | Application exit 0; actual `GF001_WRONG`; expected `GF001_EXPECTED` |
| C — Unauthorized change | TRUE | 1 | Allowed target plus unexpected `README.md` detected |
| D — Missing screenshot | TRUE | 1 | Nonexistent PNG rejected |

Overall negative-test evidence: **PASS**
