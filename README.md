# Voxel Particles Plugin

A Roblox Studio plugin for authoring, previewing, packaging, and installing client-rendered voxel particle emitters. The repository contains the complete editor, runtime, presets, native Script Sync-safe installer, and deterministic `.rbxmx` release builder.

## Download v15

[Download `VoxelParticlesPlugin-v15.rbxmx`](dist/VoxelParticlesPlugin-v15.rbxmx)

SHA-256: `1e179d373cc9685671d0947c4753c8e00fb8cf32d89981c914f37afbebcef4b8`

Install or publish the `.rbxmx` through Roblox Studio's local plugin workflow. Open **Voxel Particles v15**, then use **Initialize/Update project** to install the reviewed runtime and bundled presets.

If a target project uses native Script Sync, its mapped disk files remain authoritative. The plugin reports the conflict and intentionally does not overwrite those sources.

## What's new in v15

- Fresh preset-evaluation clones stay parented beside their authored module for valid `script.Parent` lookups, but the live preset registry now ignores those transient clones.
- Editing or saving a preset no longer recursively handles its evaluation clone through `ChildAdded`/`ChildRemoved`, preventing event re-entrancy and C stack overflow.
- This is an editor-only fix; the bundled runtime remains v13 and RuntimeInstaller remains v5.

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
