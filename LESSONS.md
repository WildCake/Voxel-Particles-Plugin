# LESSONS

- `PLUGIN_EXPORT_CORE/VoxelParticlesPlugin` is the only editable plugin package source. Historical top-level game scripts, `Shared`, `StarterPlayerScripts`, media, and donation files are not plugin owners and are excluded from the public repository.
- The installed `%LOCALAPPDATA%\Roblox\Plugins\VoxelParticlesPlugin.rbxmx` is a release/template input, never the source of truth and never an in-place build target.
- Every packaged source is declared in `plugin-package.json`; `plugin-sourcemap.json` and the `.rbxmx` hierarchy must match it exactly.
- Every release uses one version for the plugin, runtime, and installer. Ship `VoxelParticleSystem`, `ClientVfxQuality`, `VoxelFairShareAllocator`, `VoxelMotionIntegrator`, `VoxelCubicBezier`, `VoxelCylinderStream`, and the client binder together; never publish the particle module alone.
- The editor requires a bundled `Default` preset. A clean installation without it is invalid even when upgrades of older projects appear to work.
- Mark fresh evaluation clones as transient before parenting them and ignore them in preset-folder `ChildAdded`/`ChildRemoved` observers; otherwise the parent-preserving cache bypass recursively registers its own clones and overflows Studio's event stack.
- `ClientVfxQuality` is the shared client VFX ceiling. Roblox saved quality sets its cap; sustained frame pressure may lower the effective tier and stable performance recovers it slowly.
- Annulus emission is circular and uniform by area: equal positive X/Z outer radii and `0 <= spawnInnerRadius < outer`. Invalid geometry fails before preview mutation.
- `radialOutward` and `radialTangent` derive velocity from a non-zero sampled spawn offset. Point emission naturally retains the configured emission axis.
- RuntimeInstaller must preserve native Script Sync ownership and block conflicting or synced writes instead of adding fallback copies or compatibility lookup paths.
- Native Script Sync ownership does not prove freshness: compare every installed runtime source with the release bundle before reporting ready.
- VoxelParticleSystem ranks its persistent emitter registry every rendered frame using camera distance and viewport projection, never geometry raycasts. Bursts share quality, admission, particle, and prewarm budgets; a new local-space population starts at the anchor's current transform.
- Grow a Planet may provide proven generic changes, but its game-specific renderers, presets, catalogs, and state are not plugin dependencies.
