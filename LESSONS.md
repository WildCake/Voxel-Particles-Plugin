# LESSONS

- 2026-09-18: authoring preview belongs to the bundled runtime, independently of the project's installation status. Custom or synced runtime source must not disable selection, preset editing, or preview; disk-owned presets can be exported without writing their Studio source. Installation status still describes the project, not preview readiness.
- 2026-09-18: plugin ownership metadata alone does not authorize replacing edited source. Updates require current bundle content, an exact released fingerprint, or the unchanged fingerprint recorded at installation. Preserve customized runtime and authored presets.
- 2026-09-18: Minimum quality remains at 15%, never zero. Preserve positive fractional rates and small bursts; visible emitters share particle/frame quotas without a quality-dependent emitter cutoff. No emergency all-off policy is implemented.

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
- VoxelParticleSystem ranks its persistent emitter registry at 15 Hz using camera distance and viewport projection, never geometry raycasts; startup and quality changes refresh immediately. Spawn counters reset each rendered frame, and pending bursts keep the loop awake between polls. Bursts share all system budgets; local-space populations start at the anchor's current transform.
- Grow a Planet may provide proven generic changes, but its game-specific renderers, presets, catalogs, and state are not plugin dependencies.
