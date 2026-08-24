# TB-R04 implementation guidelines

- Inspect the accepted player scene, controller, TB-R03A gait gate, and trusted TB-R04 acceptance before editing.
- Work only in the provided execution worktree and modify only `scenes/player.tscn` and, if hierarchy compatibility truly requires it, `scripts/player.gd`.
- Integrate the stable `EyeLeft` and `EyeRight` nodes beneath `Head` or `Mask`; use inset, slit-like primitive geometry with a bright or emissive material.
- Preserve mesh-bearing discoverable `Head` and `Mask` nodes and local negative Z as visual forward.
- Add a mesh-bearing `Shirt` hierarchy centered on the thorax with at least three broad, clearly named `Stripe*` mesh nodes and strong light/dark material contrast.
- Keep the costume sleeveless and insect-shaped. Do not cover the six leg attachments or turn the beetle into a humanoid.
- Preserve the dark shell and use costume/eye contrast to improve readability against magenta and purple environments.
- Use only low-segment Godot primitive meshes and deterministic `.tscn` resources. Do not add external assets, textures, rigging, or animation infrastructure.
- Preserve all six articulated leg hierarchies, antennae, gait constants, captured neutral transforms, Body/Thorax/Abdomen motion, collision, controller, camera, interaction, progression, and level behavior.
- If moving Head or Mask from MeshInstance3D to Node3D, preserve its neutral transform and put the original primitive mesh beneath it; update runtime paths only if needed.
- Favor a small coherent construction over decorative detail. An additional burglar cue is optional and limited to one simple primitive-built element.
- Do not modify tests or weaken acceptance. Game Foundry owns validation, critic review, repair, acceptance, and commit creation.
