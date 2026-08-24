# TB-R04A implementation guidelines

- Inspect the accepted TB-R04 scene, trusted TB-R04A orientation gate, and side/three-quarter evidence before editing.
- Work only in the provided execution worktree and prefer modifying only `scenes/player.tscn`; touch `scripts/player.gd` only for a minimal hierarchy compatibility requirement.
- Replace the current five-stripe top-to-bottom Y stack with stripe centers spread along local Z at a nearly common Y.
- Start the shell treatment behind the head, center it on the thorax/front body, and end it before the darker rear abdomen.
- Preserve a mesh-bearing `Shirt` hierarchy for TB-R04 compatibility, but make its visual interpretation a striped carapace panel or exoskeleton wrap rather than clothing.
- Use broad, alternating dirty-cream and charcoal/black primitive bands that conform around the segment and remain visible from a side or three-quarter view.
- Rotating or resizing the existing primitive cylinders is acceptable; simplifying the base geometry is preferable to retaining a garment-like construction.
- Preserve `Head`, `Mask`, integrated `EyeLeft`/`EyeRight`, `Thorax`, dark `Abdomen`, six leg roots and their Upper/Lower descendants, antennae, and the stable visual-forward direction.
- Preserve every neutral-relative gait transform, controller constant, collision dimension, camera property, interaction, progression behavior, and level.
- Do not add sleeves, stitching, cloth, textures, external assets, skeletons, animation systems, audio, or gameplay mechanics.
- Do not modify tests or weaken acceptance. Game Foundry owns validation, critic review, repair, acceptance, and commit creation.
