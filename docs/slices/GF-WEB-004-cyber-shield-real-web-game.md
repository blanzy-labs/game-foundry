# GF-WEB-004 — Cyber Shield real Web game POC

GF-WEB-004 adds `games/cyber-shield`, the first small playable game workload
carried through the complete Game Foundry Web pipeline. It is a Godot 4 2D
game with a horizontal paddle, data-driven labeled threats, one shared fall
speed, score, three-breach game over, and clean restart.

The normal game supports Left/Right, A/D, mouse position, and touch position.
The Web acceptance URL alone enables three deterministic input commands:
`S` creates a normal top-of-field threat, `B` creates a threat intersecting
the paddle, and `M` creates a threat beyond the miss boundary. These inputs
enter through Godot's real input and gameplay code. They do not set score,
breaches, or game state directly, and they are unavailable in the manual
preview URL.

Run the complete slice acceptance with:

```text
./scripts/gf-web-004-acceptance.sh
```

The acceptance validates the Godot project, runs game-specific deterministic
logic, exports and smokes Linux x86_64, exports and verifies the real Web
bundle through GF-WEB-001, executes baseline GF-WEB-002 Chromium acceptance,
classifies and packages the bundle through GF-WEB-003, runs both generic and
game-specific production-like Chromium acceptance, smokes the manual preview,
and reruns the existing GF-WEB-001/002/003 suites.

The final hosting release is locally playable with:

```text
./scripts/gf-web-local-preview.sh <gf-web-004-artifact>/release
```

GF-WEB-004 does not modify either production site, upload an R2 object,
configure Cloudflare, deploy a game, create a remote repository, or begin site
integration. A future repository split may move `games/cyber-shield` to its
own repository while preserving the game ID and release contract.
