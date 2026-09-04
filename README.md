# Voxel Particles Plugin

A Roblox Studio plugin for authoring, previewing, packaging, and installing client-rendered voxel particle emitters. The repository contains the complete editor, runtime, presets, native Script Sync-safe installer, and deterministic `.rbxmx` release builder.

## Download v15

[Download `VoxelParticlesPlugin-v15.rbxmx`](dist/VoxelParticlesPlugin-v15.rbxmx)

SHA-256: `c406e567327d23c4ada15ddb09f51e1d1300c07ae4a9e1e53378792618ac8237`

## Install and update

The button inside Voxel Particles installs or updates the runtime in the open project. It never updates the Studio plugin itself.

### Creator Store installation

Create one plugin asset for the first Store release. For every later release, use Studio's **Publish as Plugin** flow to overwrite that same Voxel Particles asset instead of creating another one. Users then receive the release through Studio's **Plugins > Manage Plugins > Update**, **Update All**, or **Auto Update** controls. See Roblox's [Studio plugin documentation](https://create.roblox.com/docs/studio/plugins) and [official Manage Plugins update instructions](https://devforum.roblox.com/t/introducing-the-studioselectable-collision-group/2872878).

Before publishing, load the reviewed artifact in Studio and confirm the editor reports the expected version. Publish the selected root plugin script through Studio; do not send the generated `.rbxmx` directly through Open Cloud, whose [asset upload documentation](https://create.roblox.com/docs/cloud/guides/usage-assets) warns that externally edited `.rbxm`/`.rbxmx` files might not upload or function.

Do not add an HTTP downloader or a self-update button to the plugin. Roblox owns installed Creator Store plugin updates, and the public `Plugin` API does not expose a self-update operation.

### Local development installation

This repository's release `.rbxmx` is a local build with no Creator Store asset link and does not receive Manage Plugins updates. Close every Roblox Studio process, then replace the single canonical file at `%LOCALAPPDATA%\Roblox\Plugins\VoxelParticlesPlugin.rbxmx` with the reviewed release artifact. Reopen Studio and confirm the toolbar title reports the expected version.

Never keep a version-suffixed `.rbxmx` beside the canonical local file, and never enable a local copy alongside the Creator Store copy; either case can run two plugin instances. Files ending in `.bak` are inert backups. The deterministic builder must continue writing to `dist`, never directly to the installed path.

If a target project uses native Script Sync, its mapped disk files remain authoritative. The plugin reports the conflict and intentionally does not overwrite those sources.

After installing **Voxel Particles v15**, use **Install project runtime** or **Update project runtime** to install the reviewed runtime and bundled presets into the open project.

## What's new in v15

- Project runtime controls now say exactly what they change and explicitly distinguish themselves from Studio plugin updates.
- The release workflow now separates Creator Store updates from local `.rbxmx` replacement and documents duplicate-copy prevention.
- Plugin version is 15; the bundled runtime remains 13 and RuntimeInstaller remains 5.

## Runtime highlights

- `ClientVfxQuality` provides one shared `Minimum`/`Low`/`Medium`/`High` client VFX tier. Roblox saved graphics quality sets the ceiling; sustained frame pressure can lower it, and stable performance recovers it gradually.
- `spawnDirectionMode` supports `emission`, `radialOutward`, and `radialTangent` velocity.
- Cubic Bézier emitters add the curve-only `curveNormal` velocity mode.
- `spawnShape = "annulus"` samples a circular ring area uniformly through `spawnInnerRadius`.
- The editor exposes and validates the new fields before changing a live preview emitter.
- Minimum quality can stop continuous voxel emission without accidentally converting it into burst behavior.
- Clean installations now include the required bundled `Default` preset.

The older v11 quality path lived inside `VoxelParticleSystem`, observed only the selected Roblox graphics setting, and scaled only each voxel emitter's rate. v12 moves the decision into a reusable shared owner with frame-pressure adaptation, diagnostics, and tier-change notifications for other client VFX consumers.

## Configuration example

```luau
local config = {
	spawnShape = "cubicBezier",
	spawnDirectionMode = "curveNormal",
	cubicBezierPoints = {
		Vector3.new(0, 0, 0),
		Vector3.new(0, 8, 0),
		Vector3.new(12, 12, 0),
		Vector3.new(18, 4, 0),
	},
}
```

Curve points are local to the emitter anchor. P0/P3 are endpoints and P1/P2 are handles. Update an animated curve with `emitter:SetCubicBezier(p0, p1, p2, p3)`; existing particles continue their own world-space motion. Annulus X/Z values remain equal positive outer radii and must satisfy `0 <= spawnInnerRadius < outerRadius`.

## Source ownership

- `PLUGIN_EXPORT_CORE/VoxelParticlesPlugin/init.legacy.luau` — Studio editor and preview.
- `PLUGIN_EXPORT_CORE/VoxelParticlesPlugin/Internal` — bundled runtime, installer, and helpers.
- `PLUGIN_EXPORT_CORE/VoxelParticlesPlugin/Internal/BundledPresets` — shipped presets.
- `plugin-package.json` — complete package membership and versions.
- `plugin-sourcemap.json` — matching Luau analyzer hierarchy.
- `tools/build_plugin.py` — deterministic package assembly and validation.
- `.agents/skills/voxel-particles-plugin` — repository-specific Codex workflow.

Historical game experiments and raw media that share the original local folder are intentionally not part of this repository.

## Build from source

Python 3 is required. The builder preserves non-source Roblox metadata from an existing plugin template, replaces every manifest-owned source, validates the exact hierarchy and dependencies, and refuses to overwrite its template.

```powershell
python -B tools/build_plugin.py `
  --template "$env:LOCALAPPDATA\Roblox\Plugins\VoxelParticlesPlugin.rbxmx" `
  --output "dist\VoxelParticlesPlugin-v15.rbxmx"
```

See [CHANGELOG.md](CHANGELOG.md) for release details and [AGENTS.md](AGENTS.md) for repository engineering rules.
