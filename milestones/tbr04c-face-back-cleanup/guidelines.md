# TB-R04C implementation guidelines

- Inspect `ShellSeam`, the mask/eye transforms and mesh dimensions, the accepted TB-R04B shader, and the trusted TB-R04C test before editing.
- Work only in the provided execution worktree and prefer changing only `scenes/player.tscn`; `scripts/player.gd` is allowed only for a strictly necessary hierarchy compatibility fix.
- Delete `Body/ShellSeam` and its now-unused `BoxMesh_seam` resource. Do not rename or replace it with another bar, ridge, or handle.
- Preserve `Mask`, `EyeLeft`, and `EyeRight`. Keep eyes as separate left/right descendants of Mask so orientation and testability remain stable.
- Reduce each eye BoxMesh to a thin horizontal slit: width about 0.06–0.13, height no more than 0.045, depth no more than 0.014.
- Place each eye at the mask front plane so it intersects the mask surface and projects by no more than approximately 0.008. Avoid z-fighting while retaining the embedded-opening illusion.
- Preserve amber emissive readability, but subtle reduction of emission intensity is allowed if the eyes still read clearly and become less robotic.
- Do not add eye sockets, frames, brows, extra face panels, or detail unless absolutely necessary; the narrowest coherent solution is preferred.
- Preserve the entire TB-R04B Thorax ShaderMaterial, no-Shirt topology, dark Abdomen, all leg/antenna hierarchies, gait code, collision, controller, camera, gameplay, and levels.
- Do not modify tests, TB-H01, shader direction, locomotion, gameplay, or unrelated resources. Game Foundry owns validation, critic review, repair, acceptance, and commit creation.
