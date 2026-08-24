# TB-R03A implementation guidelines

- Inspect the accepted TB-R02 scene, TB-R03 controller, and trusted TB-R03A acceptance before editing.
- Refine rather than replace the existing speed-driven alternating-tripod system.
- Work only in the provided execution worktree and modify only `scenes/player.tscn` and `scripts/player.gd`.
- Preserve each stable leg name as a `Node3D` root and add deterministic mesh-bearing `Upper` and `Lower` descendants for all six legs.
- Author neutral leg geometry so each Lower endpoint sits within the trusted near-floor tolerance while the abdomen stays above ground.
- Prefer visual geometry, attachment, and Body-pose changes over collision changes. Preserve the existing capsule unless objective navigation evidence requires otherwise.
- Capture neutral transforms for every animated root/Upper/Lower segment plus Body, Thorax, Abdomen, and antennae; apply non-accumulating offsets relative to those poses.
- Strengthen the main sweep moderately over TB-R03. Give Upper the primary swing and Lower complementary bend/extension plus an asymmetric lifted swing and low support phase.
- Preserve the exact tripod membership and movement-speed-driven phase/blend behavior.
- Add only restrained Body weight transfer, Thorax articulation, and smaller opposing Abdomen counter-motion. Preserve or reduce antenna response if needed.
- Do not animate CharacterBody root position, collision, gameplay velocity, speed, gravity, camera, interaction, or progression.
- Preserve shell colors, mask, proportions, primitive-only construction, camera-facing behavior, strafe, backpedal, diagonal normalization, and idle camera freedom.
- Do not add skeletons, AnimationPlayer/Tree, IK, raycast feet, terrain solving, external assets, audio, or gameplay mechanics.
- Do not modify tests or weaken acceptance. Game Foundry owns validation, critic review, repair, acceptance, and commit creation.
