# GF-002 fault-injection evidence

A negative-test **PASS** means the shared production acceptance gate returned a real non-zero process exit for the injected fault.

| Test | Result | Gate exit | Command exit |
|---|---:|---:|---:|
| A — Broken GDScript | PASS | 1 | 1 |
| B — Wrong mutation token | PASS | 1 | 0 |
| C — Unauthorized source change | PASS | 1 | 0 |
| D — Missing screenshot | PASS | 1 | 0 |
| E — Agent success / Godot failure | PASS | 1 | 1 |

Overall: **PASS**
