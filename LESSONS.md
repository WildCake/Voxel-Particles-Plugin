# LESSONS

- `PLUGIN_EXPORT_CORE/VoxelParticlesPlugin` is the only editable plugin package source. Historical top-level game scripts, `Shared`, `StarterPlayerScripts`, media, and donation files are not plugin owners and are excluded from the public repository.
- The installed `%LOCALAPPDATA%\Roblox\Plugins\VoxelParticlesPlugin.rbxmx` is a release/template input, never the source of truth and never an in-place build target.
- Every packaged source is declared in `plugin-package.json`; `plugin-sourcemap.json` and the `.rbxmx` hierarchy must match it exactly.
- Runtime v12 requires `ClientVfxQuality`, `VoxelFairShareAllocator`, `VoxelMotionIntegrator`, and `VoxelCylinderStream` as bundled siblings. Never publish `VoxelParticleSystem` alone.
- The editor requires a bundled `Default` preset. A clean installation without it is invalid even when upgrades of older projects appear to work.
- Mark fresh evaluation clones as transient before parenting them and ignore them in preset-folder `ChildAdded`/`ChildRemoved` observers; otherwise the parent-preserving cache bypass recursively registers its own clones and overflows Studio's event stack.
- `ClientVfxQuality` is the shared client VFX ceiling. Roblox saved quality sets its cap; sustained frame pressure may lower the effective tier and stable performance recovers it slowly.
- Annulus emission is circular and uniform by area: equal positive X/Z outer radii and `0 <= spawnInnerRadius < outer`. Invalid geometry fails before preview mutation.
- `radialOutward` and `radialTangent` derive velocity from a non-zero sampled spawn offset. Point emission naturally retains the configured emission axis.
- RuntimeInstaller must preserve native Script Sync ownership and block conflicting or synced writes instead of adding fallback copies or compatibility lookup paths.
- Grow a Planet may provide proven generic changes, but its game-specific renderers, presets, catalogs, and state are not plugin dependencies.
