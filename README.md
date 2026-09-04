# Voxel Particles Plugin

A Roblox Studio plugin for authoring, previewing, packaging, and installing client-rendered voxel particle emitters. The repository contains the complete editor, runtime, presets, native Script Sync-safe installer, and deterministic `.rbxmx` release builder.

## Download v14

[Download `VoxelParticlesPlugin-v14.rbxmx`](dist/VoxelParticlesPlugin-v14.rbxmx)

SHA-256: `3beb0200543c707e0a6bd80aba178931882a8f500cd39a741571895119a56206`

Install or publish the `.rbxmx` through Roblox Studio's local plugin workflow. Open **Voxel Particles v14**, then use **Initialize/Update project** to install the reviewed runtime and bundled presets.

If a target project uses native Script Sync, its mapped disk files remain authoritative. The plugin reports the conflict and intentionally does not overwrite those sources.

## What's new in v14

- `spawnShape = "cubicBezier"` emits across the full length of a four-point cubic Bézier curve instead of clustering in high-parameter-speed sections.
- `spawnDirectionMode = "curveNormal"` sends particles away from the curve in a uniformly random direction around its local tangent.
- `Emitter:SetCubicBezier(p0, p1, p2, p3)` updates a moving curve through one reusable 64-segment arc-length table without recreating the emitter or allocating new tables each frame.
- The editor exposes all four anchor-local control points, validates curve configuration, and previews the new shape and direction mode.
- The bundled runtime is v13 and RuntimeInstaller is v5 so project updates install the required `VoxelCubicBezier` runtime sibling atomically.

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
  --output "dist\VoxelParticlesPlugin-v14.rbxmx"
```

See [CHANGELOG.md](CHANGELOG.md) for release details and [AGENTS.md](AGENTS.md) for repository engineering rules.
