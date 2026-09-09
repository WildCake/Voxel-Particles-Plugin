# Voxel22 verification — 2026-09-09

Public behavior belongs to [README](../README.md#stopping-emission-in-v22); the artifact and its hash belong to [CHANGELOG](../CHANGELOG.md#v22--2026-09-09).

## Changed owners

Canonical `Internal/VoxelParticleSystem` adds StopEmission. The entry, installer and manifest carry the same new release number; their behavior is otherwise unchanged. Package membership and `plugin-sourcemap.json` remain unchanged. The builder wrote a separate v22 artifact using the installed plugin as its preserved template.

## Executed checks

- `python -B tools/build_plugin.py --template <installed VoxelParticlesPlugin.rbxmx> --output dist/VoxelParticlesPlugin-v22.rbxmx`: PASS, exact manifest/sourcemap/XML/source hierarchy with one entry, eight internal modules and 32 presets. Builder code is unchanged; one build was performed.
- `lune run tools/test_simulation_pause.luau`: PASS for controlled-step pause/resume, idempotency, no catch-up, preserved pending demand, explicit emitter operations, cleanup and compilation of all41 packaged sources. These are functional simulations, not performance measurements.
- `lune run tools/test_runtime_installer.luau`: PASS using the actual v22 artifact for clean install, managed v21 update, preserved/custom and missing presets, idempotency, synced-owner refusal and duplicate ownership.
- LSP1.69.0 with the existing `plugin-sourcemap.json` and pinned Roblox definitions: exit0 for the three changed canonical Luau sources. `git diff --check`: PASS.
- StopEmission's real particle and queue regression is maintained at the consuming integration boundary: [MIF area lifetime](../../Medieval%20in%20Fire/tests/equipment-client/AREA_LIFETIME_HANDOFF.md). The initial native queue failure changed from eight to24 births after ordinary disable; explicit StopEmission preserved the original eight while allowing their full lifetime, with pause/idempotency/explicit subsequent Emit covered.

## Installation scope

MIF's two mapped runtime sources receive the new method on disk. The installed local plugin file and open Studio plugin sessions were not replaced or reloaded. No plugin/storefront publication, place publication, desktop control, Studio rendering test or performance measurement was performed. The built candidate is available for operator installation and publication.

Review again if the emission-demand accounting, public emitter contract or package membership changes.
