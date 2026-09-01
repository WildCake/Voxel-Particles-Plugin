# AGENTS.md

This repository owns the standalone Roblox Voxel Particles Plugin. Read `LESSONS.md` before every task and use `.agents/skills/voxel-particles-plugin/SKILL.md` for audits, implementation, packaging, installation-contract work, and releases.

## Ownership

- `PLUGIN_EXPORT_CORE/VoxelParticlesPlugin` is the canonical package source.
- `plugin-package.json` is the complete package manifest; `plugin-sourcemap.json` must describe the same source hierarchy.
- `tools/build_plugin.py` is the only release builder. It must preserve its input template and write a separate validated `.rbxmx` artifact.
- `dist/` contains reviewed release artifacts, not editable source.

## Engineering rules

- Change the smallest complete owner: editor UI in `init.legacy.luau`, particle behavior in `VoxelParticleSystem`, shared quality policy in `ClientVfxQuality`, installation behavior in `RuntimeInstaller`, and authored defaults in `BundledPresets`.
- Keep the plugin game-agnostic. Do not import Grow a Planet, Relic Maze, donation, combat, weather, mutation, or other game-specific state and content.
- A release is incomplete when a required sibling module or bundled preset is absent from the package, even if loose disk sources compile.
- Keep plugin, runtime, and installer versions explicit and validated. Do not change a release number without a complete artifact build.
- Native Script Sync is authoritative for mapped project scripts. The installer must fail closed rather than overwrite synced owners.
- Use official Roblox Studio MCP for authorized Studio inspection or mutation. Do not start Play or Run without explicit authorization.

## Verification

Run the manifest builder, Luau analysis with `plugin-sourcemap.json` when the analyzer is available, XML/package inspection, and a focused diff review. Report runtime or visual coverage only when it was actually run after installation in Studio.
