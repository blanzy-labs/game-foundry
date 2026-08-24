# TB-R04B implementation guidelines

- Inspect the accepted scene, trusted TB-R04B gate, and the rejected TB-R04 screenshot before editing.
- Work only in the provided execution worktree and prefer modifying only `scenes/player.tscn`; touch `scripts/player.gd` only for a minimal hierarchy compatibility need.
- Remove `Body/Shirt`, `Body/Shirt/Base`, every `Body/Shirt/Stripe*` node, and obsolete shirt/cylinder resources. Do not retain or rename them.
- Prefer a `ShaderMaterial` directly on the existing `Thorax` mesh. Its shader must use local `VERTEX.z`, write `ALBEDO`, and expose `stripe_light`, `stripe_dark`, and `stripe_count` parameters with 3–5 broad bands.
- Keep the shader deterministic, static, matte, and simple. Preserve low-poly lighting response; do not add animation, glow, texture dependencies, procedural noise, or high-tech polish.
- If using geometry instead, replace the Thorax mesh with 3–5 closely joined non-cylinder `ShellStripe*` pieces under the stable `Thorax` node. Do not place segments over an intact underlying shell or create protruding rings.
- Confine coloration to the front shell behind the head. Keep the rear `Abdomen` on its existing separate dark material.
- Preserve `Head`, `Mask`, integrated eyes, antennae, six leg roots with Upper/Lower segments, authored neutral transforms, gait constants, Body/Thorax/Abdomen animation paths, and local negative Z as visual forward.
- Preserve controller, collision, camera, interaction, gameplay, and all levels exactly.
- Do not modify tests or reintroduce a compatibility Shirt node. TB-R04B intentionally replaces that obsolete topology and owns its new acceptance.
- Game Foundry owns validation, critic review, repair, acceptance, and commit creation.
