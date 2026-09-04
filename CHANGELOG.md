# Changelog

## v15 — 2026-09-05

### Changed

- Project runtime controls now state explicitly that they install or update code in the open project, not the Studio plugin.
- Creator Store publishing, Studio-managed updates, local `.rbxmx` replacement, and duplicate-copy prevention are documented as separate workflows.
- Plugin version is 15; the bundled runtime remains 13 and RuntimeInstaller remains 5.

### Security

- Plugin updates remain owned by Roblox Studio. Voxel Particles does not request HTTP access or execute a custom self-updater.

Release artifact: `dist/VoxelParticlesPlugin-v15.rbxmx`

SHA-256: `c406e567327d23c4ada15ddb09f51e1d1300c07ae4a9e1e53378792618ac8237`

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
