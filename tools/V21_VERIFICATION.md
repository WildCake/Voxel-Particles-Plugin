# Voxel21 verification — 2026-09-08

The artifact and public configuration contract belong to [CHANGELOG](../CHANGELOG.md#v21--2026-09-08) and [README](../README.md#flat-fan-spread-in-v21).

## Changed owners

- Canonical `Internal/VoxelParticleSystem`: validates and samples native fan launch directions; existing cone sampling remains unchanged.
- `init.legacy.luau`: default fields, preview validation, config transport, Movement controls; the existing generic save/load path carries both fields.
- `Internal/RuntimeInstaller` and `plugin-package.json`: aligned release numbers. Installer logic and package membership are unchanged; `plugin-sourcemap.json` therefore needs no membership edit.
- The previously prepared, uncommitted v20 pause implementation and its tests/artifact were present at task entry. v21 retains that required foundation; it does not remove the pause API already used by client projects.

## Executed checks

- `python -B tools/build_plugin.py --template <installed VoxelParticlesPlugin.rbxmx> --output dist/VoxelParticlesPlugin-v21.rbxmx`: PASS. Manifest, sourcemap and exact XML/source hierarchy agree: one plugin entry, eight internal modules, 32 presets. Builder code was unchanged; one build was required and performed.
- `lune run tools/test_fan_spread.luau`: **552 checks PASS**. All 41 packaged sources compile. Real packaged runtime samples rotated planes, positive/negative spread, non-zero minimum, zero width, invalid-plane rejection and return to cone. Each of all 32 v20 bundled presets emits the same seeded directions, positions, lifetime and size after a controlled simulation step on v20 and v21.
- `lune run tools/test_runtime_installer.luau`: PASS. Complete clean installation; idempotent rescan; managed v20→v21 update; preserved custom preset; restored missing preset; stale synced source blocks before writes; proven duplicate handling; unknown duplicate and running-place installation rejected.
- `lune run tools/test_simulation_pause.luau`: PASS. Controlled-step pause/resume, idempotency, no catch-up, emitter enabled state, quality changes, queued demand, Attach/Emit and cleanup; all 41 package sources compile. These are functional simulations, not FPS measurements or benchmarks.
- Luau LSP 1.69.0, pinned Roblox definitions and `plugin-sourcemap.json`: exit0 for the three changed canonical Luau owners. `git diff --check`: PASS.

## Installation and remaining coverage

The validated release artifact replaced `C:/Users/Maxim/AppData/Local/Roblox/Plugins/VoxelParticlesPlugin.rbxmx` under the owner's explicit authorization. Its SHA-256 after replacement equals the release artifact hash in CHANGELOG. The build wrote a separate artifact before this installation; it never used the installed file as an in-place build target.

Canonical plugin sources were edited on disk. Studio MCP only read the Voxel demo's mode (Edit); it did not start Play, edit Source, inspect sync propagation, move the camera or publish. No live plugin reload was attempted by the agent in the owner's open Studio sessions. Later in this pass the owner explicitly confirmed replacing the local plugin and publishing it; this is owner-reported publication, not an agent-side storefront verification.

**Operator pending:** live editor interaction/save-reload, Studio rendering, art comparison, target-device and performance acceptance. Automated checks cover the stated update paths, not every customized third-party place.

Official platform references checked 2026-09-08: [Script Sync](https://create.roblox.com/docs/scripting/sync), [Studio plugin reload and publication](https://create.roblox.com/docs/studio/plugins), [CFrame coordinate transforms](https://create.roblox.com/docs/reference/engine/datatypes/CFrame). Revisit on relevant Roblox API or installation-workflow changes.
