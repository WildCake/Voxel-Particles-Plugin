# Voxel Particles Plugin

A Roblox Studio plugin for authoring, previewing, packaging, and installing client-rendered voxel particle emitters. The repository contains the complete editor, runtime, presets, native Script Sync-safe installer, and deterministic `.rbxmx` release builder.

## Download v12

[Download `VoxelParticlesPlugin-v12.rbxmx`](dist/VoxelParticlesPlugin-v12.rbxmx)

SHA-256: `e5703849b2d1df54a674b62d5dfb30f1be987536ea5aff61b7941332c082cf2d`

Install or publish the `.rbxmx` through Roblox Studio's local plugin workflow. Open **Voxel Particles v12**, then use **Initialize/Update project** to install the reviewed runtime and bundled presets.

If a target project uses native Script Sync, its mapped disk files remain authoritative. The plugin reports the conflict and intentionally does not overwrite those sources.

## What's new in v12

- `ClientVfxQuality` provides one shared `Minimum`/`Low`/`Medium`/`High` client VFX tier. Roblox saved graphics quality sets the ceiling; sustained frame pressure can lower it, and stable performance recovers it gradually.
- `spawnDirectionMode` supports `emission`, `radialOutward`, and `radialTangent` velocity.
- `spawnShape = "annulus"` samples a circular ring area uniformly through `spawnInnerRadius`.
- The editor exposes and validates the new fields before changing a live preview emitter.
- Minimum quality can stop continuous voxel emission without accidentally converting it into burst behavior.
- Clean installations now include the required bundled `Default` preset.

The older v11 quality path lived inside `VoxelParticleSystem`, observed only the selected Roblox graphics setting, and scaled only each voxel emitter's rate. v12 moves the decision into a reusable shared owner with frame-pressure adaptation, diagnostics, and tier-change notifications for other client VFX consumers.

## Configuration example

```luau
local config = {
	spawnShape = "annulus",
	spawnSize = Vector3.new(8, 0, 8),
	spawnInnerRadius = 5,
	spawnDirectionMode = "radialTangent",
}
```

Annulus X/Z values are equal positive outer radii and must satisfy `0 <= spawnInnerRadius < outerRadius`. Radial direction modes use the actual sampled spawn offset; a point emitter keeps its configured emission axis.

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
  --output "dist\VoxelParticlesPlugin-v12.rbxmx"
```

See [CHANGELOG.md](CHANGELOG.md) for release details and [AGENTS.md](AGENTS.md) for repository engineering rules.
