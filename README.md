# Voxel Particles Plugin

A Roblox Studio plugin for authoring, previewing, packaging, and installing client-rendered voxel particle emitters. The repository contains the complete editor, runtime, presets, native Script Sync-safe installer, and deterministic `.rbxmx` release builder.

## Download v19

[Download `VoxelParticlesPlugin-v19.rbxmx`](dist/VoxelParticlesPlugin-v19.rbxmx)

SHA-256: `93e4de3632e6500a2965274c0b7e88b6537c398921979d5ea2577eec566710b0`

Install or publish the `.rbxmx` through Roblox Studio's local plugin workflow. Open **Voxel Particles v19**, then use **Initialize/Update project** to install the complete runtime and all 32 bundled presets.

Plugin, runtime, and installer share release number **19**. The builder rejects mixed release numbers.

## Updating an existing project

Updating the installed plugin does not replace runtime scripts already saved in a place. The plugin contains a versioned bundle; each project needs that complete bundle.

1. Stop Play and update the plugin.
2. For a project without native Script Sync, click **Update project** (or **Initialize project** for a new installation). Wait for **Voxel Particles runtime v19 is ready**.
3. For a synced project, update the mapped disk owners together using the files from [this release's Internal folder](PLUGIN_EXPORT_CORE/VoxelParticlesPlugin/Internal):
   - `ReplicatedStorage.Shared`: `VoxelParticleSystem`, `ClientVfxQuality`, `VoxelFairShareAllocator`, `VoxelMotionIntegrator`, `VoxelCubicBezier`, and `VoxelCylinderStream`.
   - `StarterPlayer.StarterPlayerScripts.VoxelEmitterBinder`: use the contents of `VoxelEmitterBinderTemplate.luau` in the existing mapped `VoxelEmitterBinder.local.luau` file.
   - Add missing modules from `Internal/BundledPresets` to the mapped `ReplicatedStorage.Shared.VoxelEmitterPresets` folder.
4. Let Script Sync propagate, then rescan in the plugin. An outdated synced module now blocks readiness and names the mismatching instance. Keep project-authored presets; the updater does not replace existing preset contents.
5. Start a fresh Play session to load the updated modules, verify the project, then publish the place.

Use **Script Sync → Reveal in Explorer/Finder** to locate a mapped owner. If Studio presents a conflict after you have updated those files, select the reviewed disk version. See Roblox's [Script Sync guide](https://create.roblox.com/docs/scripting/sync).

**Refreshing built-in effects:** the updater adds missing presets and preserves existing preset contents, including your edits. To adopt the v19 fire adjustments, replace `Fire_1` and `SimpleFire` with the matching files in [BundledPresets](PLUGIN_EXPORT_CORE/VoxelParticlesPlugin/Internal/BundledPresets). The bundle also includes v17's golden `tp2` gateway and corrected `Firethrower` and `Landing_1`–`Landing_4` mappings. Copy all bundled preset contents to reproduce the complete showcase. Keep any customized versions under separate preset names first. For Script Sync, edit the mapped disk files. Restart Play afterward because already-required presets remain cached for that session.

## What's new in v19

- Both fire presets reduce size-noise amplitude from 0.74 to 0.185 and frequency from 5.6 to 1.4: four times gentler and slower per-particle size variation.
- `SimpleFire` uses a green-to-turquoise-to-blue color curve. Its movement, acceleration, lifetime, initial size, and other settings are unchanged from v18; `Fire_1` retains its warm colors.

## What's new in v18

- Camera distance and viewport selection refresh at 15 Hz over the persistent emitter registry, with an immediate refresh when the renderer starts or quality changes. CollectionService tag events maintain the registry; no geometry raycasts are used. Between polls, the renderer uses the cached selection.
- Particle simulation and spawn counters remain tied to rendered frames. Queued bursts keep an otherwise idle renderer awake until the next admission poll. Shared emitter, particle, spawn, and prewarm limits are unchanged.
- `Fire_1` and `SimpleFire` restore their original upward flame settings. Only upward acceleration changes from 39.5 to 10, and the initial size-curve multiplier increases from 0.8 to 1.6.
- `Portal` restores the original pink effect. The golden square `tp2` gateway is unchanged.
- Confetti keeps SmoothPlastic and now fixes the blue color channel at 255, giving every randomized color maximum HSV value without adding Neon or lights. The brighter palette spans blue, lavender, and pink.
- All 32 demo presets remain bundled as independent modules, including both layers of the Relic explosion, with no demo helper or game-script dependencies.

The demo's combination pedestals use two ordinary presets on colocated anchors:

| Stand | Presets | Trigger |
| --- | --- | --- |
| Volcanic Furnace | `Fire_1` + `EmberSmoke` | Continuous |
| Relic Maze Explosion | `RelicExplosionCore` + `RelicExplosionShell` | Emit both bursts together |
| Orbital Rift | `GravityWell` + `AnnulusOrbit` | Continuous spherical core and orbital halo |

Place anchors at the same position and assign their `VoxelPreset` attributes to reproduce these combinations. Each layer remains subject to the shared system limits.

## What's new in v16

- One system-wide budget covers all attached emitters, including continuous streams and explicit bursts. The nearest visible anchors receive simulation slots.
- Camera and distance admission applies to bursts. Rejected emitters release their particles and queued demand immediately, preventing hidden simulation and catch-up bursts.
- Quality scales particle capacity, emission, burst requests, and frame spawn limits. The old per-preset **Cull outside FOV** switch is removed: camera admission is always enforced by the system.
- The default 512-Part pool warms at up to 8 new Parts per rendered frame. Emission begins only when the pool is ready; bursts cannot allocate extra Parts. The reserve survives quality changes.
- Local-space effects resume from their current anchor transform after warmup or culling.
- Studio no longer forces Medium quality. Use `ClientVfxQuality.SetStudioForcedTier()` only for explicit Studio tests.

Default shared limits per client:

| Quality | Simulated emitters | Living particles | New particles per frame |
| --- | ---: | ---: | ---: |
| High | 15 | 512 | 128 |
| Medium | 10 | 333 | 83 |
| Low | 5 | 154 | 38 |
| Minimum | 0 | 0 | 0 |

These are upper bounds across the system, not per-preset allowances. The reusable reserve contains 512 Parts; dormant Parts are unparented. Prewarming takes 64 rendered frames (about 1.07 seconds at 60 FPS). Calling `SetMaxTotalParticles()` changes the single system capacity; individual demo scripts should not compete to configure it.

`VoxelParticleSystem.GetDiagnostics()` reports the release version, readiness, pool allocation, active limits, and frame counters. Pass `true` to include emitter admission details. `FrameSpawnLimit` belongs to the recorded spawn frame; `MaxSpawnsPerFrame` reflects the current quality setting.

## Runtime highlights

- `ClientVfxQuality` provides one shared `Minimum`/`Low`/`Medium`/`High` client VFX tier. Roblox saved graphics quality sets the ceiling; sustained frame pressure can lower it, and stable performance recovers it gradually.
- `spawnDirectionMode` supports `emission`, `radialOutward`, and `radialTangent` velocity.
- Cubic Bézier emitters add the curve-only `curveNormal` velocity mode.
- `spawnShape = "annulus"` samples a circular ring area uniformly through `spawnInnerRadius`.
- The editor exposes and validates the new fields before changing a live preview emitter.
- Minimum quality stops both continuous and burst voxel emission without reclassifying an emitter.
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
  --output "dist\VoxelParticlesPlugin-v19.rbxmx"
```

See [CHANGELOG.md](CHANGELOG.md) for release details and [AGENTS.md](AGENTS.md) for repository engineering rules.
