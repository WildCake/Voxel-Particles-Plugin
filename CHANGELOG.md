# Changelog

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
