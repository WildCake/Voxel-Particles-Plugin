# Changelog

## v17 — 2026-09-05

### Fixed

- Removed geometry raycasts from camera admission and explicit bursts. A sign or nearby object can no longer cancel a burst whose anchor passes viewport and distance checks. Nearest-emitter selection already runs each rendered frame over the persistent registry; no multi-second selection timer is involved.
- Retuned the two duplicated fire presets for bounded acceleration and compact point emission. `Fire_1` is a broad amber campfire; `SimpleFire` is a smaller blue flame.
- Separated `Portal` and `tp2` into a cyan circular gate and golden square gateway. Corrected the bundled Portal's internal preset name, which was incorrectly `tp2`.
- Aligned existing `Firethrower`, `Landing_1`–`Landing_4`, and `Teleport` contents with the showcase. Several old bundled names pointed to different authored effects.

### Added

- All 32 showcase presets are bundled, up from nine. The 23 additions are complete preset tables with no dependency on demo helpers or game scripts.
- README recipes for the three combination pedestals. Orbital Rift now combines `GravityWell` and `AnnulusOrbit`, and Volcanic Furnace combines `Fire_1` and `EmberSmoke`.
- Explicit instructions for refreshing changed built-in presets without overwriting project-authored customizations.

Plugin, runtime, and installer version: **17**. Shared emitter, particle, spawn, and prewarm budgets are unchanged. Obsolete LOS bypass attributes/configuration are no longer consumed.

Release artifact: `dist/VoxelParticlesPlugin-v17.rbxmx`

SHA-256: `70545534768b7b041ae3cdd954d715fe284f8d496dbb83e9034698723ff5a724`

Validation: manifest build, XML membership, and static Luau source analysis. The unchanged weak-table type annotation in the native binder still produces its existing analyzer diagnostic. No Play tests, runtime measurements, or visual acceptance were performed for this release, as requested.

## v16 — 2026-09-05

### Fixed

- Bursts now obey camera visibility, distance LOD, and the same quality and capacity budgets as continuous emitters.
- A shared nearest-visible admission pass limits simulated emitters to 15/10/5/0 on High/Medium/Low/Minimum. Rejected emitters release living particles and queued demand.
- Quality reductions reclaim excess particles and emitter slots when the budget changes.
- Explicit bursts no longer bypass the pool creation budget. The default pool prewarms all 512 Parts at up to 8 per rendered frame before emission; quality changes retain the reserve.
- A new local-space particle population uses the current anchor transform after prewarming or camera culling.
- RuntimeInstaller checks the source of native-synced modules before reporting readiness and identifies stale owners without writing over them.

### Changed

- Plugin, runtime, and installer use one release number: 16. Builds reject mixed versions.
- Quality scales the global particle ceiling, per-emitter capacity, rate, burst demand, and total spawns per frame. High defaults to 512 living particles and 128 spawns per frame across the entire system.
- Camera admission is mandatory; the editor no longer exposes a per-preset FOV bypass.
- Studio follows the shared adaptive quality policy instead of silently forcing Medium.
- Runtime diagnostics report version, allocation, warmup, emitter admission, and frame budgets.

Release artifact: `dist/VoxelParticlesPlugin-v16.rbxmx`

SHA-256: `5ede188c300d917cd05084fc69bfbb7b0669288c59023acdfd72100493eb62ec`

## v15 — 2026-09-05

### Fixed

- Fresh preset-evaluation clones are excluded from the live `ChildAdded` and `ChildRemoved` registry while retaining their authored parent, preventing recursive self-registration, maximum event re-entrancy, and C stack overflow when a preset changes.

### Changed

- Plugin version is 15; the bundled runtime remains 13 and RuntimeInstaller remains 5.

Release artifact: `dist/VoxelParticlesPlugin-v15.rbxmx`

SHA-256: `1e179d373cc9685671d0947c4753c8e00fb8cf32d89981c914f37afbebcef4b8`

## v14 — 2026-09-04

### Added

- Uniform-distance `cubicBezier` emission across four anchor-local control points.
- `curveNormal` velocity for particles that disperse around the curve tangent.
- Allocation-free `Emitter:SetCubicBezier(p0, p1, p2, p3)` updates for animated curves.
- Complete editor controls and validation for cubic Bézier emitters.

### Changed

- Plugin version is 14, bundled runtime is 13, and RuntimeInstaller is 5.
- Runtime installation now includes the required `VoxelCubicBezier` sibling module.
- The 64-segment arc-length lookup bounds sampling cost while avoiding visible particle clumps and gaps along curved emitters.

Release artifact: `dist/VoxelParticlesPlugin-v14.rbxmx`

SHA-256: `3beb0200543c707e0a6bd80aba178931882a8f500cd39a741571895119a56206`

## v13 — 2026-09-02

### Fixed

- Fresh editor preview clones now retain the preset's authored parent while bypassing the `require()` cache, so presets can resolve sibling modules through `script.Parent`.

### Changed

- Plugin version is 13; the bundled runtime remains 12 and RuntimeInstaller remains 4.
- The repository skill and release validation now enforce parent-preserving fresh preset evaluation.

Release artifact: `dist/VoxelParticlesPlugin-v13.rbxmx`

SHA-256: `3ef608739c2b010c907c1a2decdd2a54f52934a91b8a873b2c37c89df953bc23`

## v12 — 2026-09-02

### Added

- Shared `ClientVfxQuality` tiers driven by the Roblox saved graphics-quality ceiling and measured client frame pressure.
- `radialOutward` and `radialTangent` particle direction modes.
- Uniform-area `annulus` emission with `spawnInnerRadius`.
- Editor controls and pre-preview validation for the new spawn contracts.
- Complete source manifest, analyzer sourcemap, deterministic package builder, and public repository engineering skill.

### Changed

- Voxel runtime version is 12; RuntimeInstaller version is 4.
- Minimum VFX quality now stops continuous voxel emission without treating it as burst configuration.
- Runtime installation includes the shared quality owner and preserves native Script Sync ownership.

### Fixed

- The required bundled `Default` preset is now present, making clean project installation complete.
- Package validation now rejects missing runtime siblings, missing presets, stale versions, and source mismatches.

Release artifact: `dist/VoxelParticlesPlugin-v12.rbxmx`

SHA-256: `e5703849b2d1df54a674b62d5dfb30f1be987536ea5aff61b7941332c082cf2d`
