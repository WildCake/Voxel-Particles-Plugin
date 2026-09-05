---
name: voxel-particles-plugin
description: Maintain, audit, package, and release the standalone Roblox Voxel Particles Plugin, including its editor UI, bundled runtime, ClientVfxQuality, presets, RuntimeInstaller, manifest, and native Script Sync-safe installation. Use for work in the Voxel Particles Plugin repository; exclude game-specific VFX content except at an explicit integration boundary.
---

# Voxel Particles Plugin Engineering

Use this skill for changes to the standalone plugin, its bundled runtime, or its release artifact.

## Load the contract

Read root `LESSONS.md`, `AGENTS.md`, `plugin-package.json`, and the directly affected owner. Read `README.md` and `CHANGELOG.md` when changing public behavior, installation, or a release.

Treat these as one package contract:

- editor and preview: `PLUGIN_EXPORT_CORE/VoxelParticlesPlugin/init.legacy.luau`;
- particle lifecycle, sampling, and motion: `Internal/VoxelParticleSystem.luau`;
- shared client quality ceiling: `Internal/ClientVfxQuality.luau`;
- project inspection and installation: `Internal/RuntimeInstaller.luau`;
- default authored data: `Internal/BundledPresets`;
- package membership: `plugin-package.json`;
- analyzer hierarchy: `plugin-sourcemap.json`;
- release assembly and validation: `tools/build_plugin.py`.

## Owner rules

Fix the smallest complete owner and update every direct contract consumer. Do not repair missing package dependencies at runtime, publish a loose module without its siblings, or add compatibility lookup layers.

Keep shared code game-agnostic. Game renderers may consume the installed runtime, but Grow a Planet, Relic Maze, mutation, weather, donation, and other game-specific code do not become plugin dependencies.

Native Script Sync owns mapped project source. RuntimeInstaller may inspect it but must not overwrite it; surface the exact disk owner that must be updated.

## Runtime invariants

- `ClientVfxQuality` is client-only and owns the saved-quality cap, frame-pressure tier, diagnostics, and tier-change event.
- Minimum quality may stop continuous emission without reclassifying that emitter as a burst emitter.
- Annulus sampling stays uniform by area and accepts only equal positive X/Z outer radii with `0 <= inner < outer`.
- Radial direction modes use the actual sampled offset. A zero offset retains emission-axis behavior.
- Invalid editor state is rejected before configuring a live preview emitter.
- Fresh editor evaluation may clone a preset to bypass `require()` caching, but the clone must keep the authored parent during `require()` and be destroyed immediately afterward. Never detach it: presets may legitimately resolve sibling defaults or helpers through `script.Parent`.
- Required modules and the `Default` preset must exist in both the manifest and final `.rbxmx` hierarchy.

## Release workflow

When public behavior or package membership changes:

1. Update the canonical source owner and relevant editor/installer consumers.
2. Use one release number for plugin, runtime, and installer. Ship the complete runtime bundle with every plugin release; the builder rejects mixed versions.
3. Update `plugin-package.json` and `plugin-sourcemap.json` together for source membership changes.
4. Build to a separate artifact; never overwrite the installed/template plugin:

   ```powershell
   python -B tools/build_plugin.py `
     --template "$env:LOCALAPPDATA\Roblox\Plugins\VoxelParticlesPlugin.rbxmx" `
     --output "dist\VoxelParticlesPlugin-v<version>.rbxmx"
   ```

5. Run Luau analysis with `plugin-sourcemap.json` when `luau-lsp` is available. Rebuild twice from the same template when packaging code changed and compare SHA-256.
6. Inspect the final XML hierarchy, manifest membership, version markers, artifact hash, and focused diff.
7. Update `CHANGELOG.md` and README download/install details.

Studio runtime or visual testing requires explicit authorization and an installed candidate. Use only official Roblox Studio MCP, keep native-synced source disk-owned, and return Studio to Edit after an authorized test.

## Handoff

Report the version, exact artifact and hash, source owners changed, manifest/module/preset counts, checks run, installed-plugin/project mutations, and any unrun Studio visual or runtime coverage.
