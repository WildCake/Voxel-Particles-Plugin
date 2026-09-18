# Changelog

## v26 — 2026-09-18

- Added a persistent saving panel beside the preset selector: Save preset, Save a copy, Auto-save ON/OFF, Export preset and an explicit save status. Runtime diagnostics are expandable, and the selector uses the available width.
- Kept automatic saving enabled by default; added a remembered manual mode. Auto-save is debounced and tied to the edited preset/state. Switching selection flushes writable changes or asks before discarding; closing the editor uses the same protection. Failed writes and edits made during a yielding save remain unsaved.
- Saving a copy suggests an unused name, preserves the original and selects the new preset. Project initialization preserves edits to a bundled example. Matching settings received from an external file clear the dirty indicator.
- Synced files remain protected. Their primary action opens guided export with the preset's location and a select-all control; exporting does not claim the original is saved. Ordinary project presets require no code editing. UI distinguishes saving the preset in the place from saving/publishing the place itself.
- Package: one entry, ten internal modules and 32 presets. Plugin, runtime and installer use version 26. The runtime behavior is unchanged; the exact v25 source remains eligible for installation updates.

Release artifact: `dist/VoxelParticlesPlugin-v26.rbxmx`

SHA-256: `246c028cef2c5d6e156aa7e1a4f07bd1729d626598f0eab0a58ac9230aa9302e`

Validation: 21 focused in-memory checks of the actual save owner and saving UI, complete entry compilation, scoped Luau analysis, installer scenarios including v25 updates and synced/custom source protection, and manifest/XML/source validation. Studio visual testing, plugin installation/reload, particle execution, Play and publication were not performed.

## v25 — 2026-09-18

- Fixed oversized particle births: the initial size now includes the lifetime curve and seeded size noise before the Part becomes visible. Previously spawn used the raw base size until the first `sizeUpdateStep` write.
- Shared the size calculation between birth and updates. Preserved authored update intervals, base size, curve interpolation and the existing minimum multiplier of 0.01; skipped writes no longer calculate unused size noise.
- Plugin, runtime and installer share version 25. Exact v24 runtime remains eligible for updates; customized and synced sources remain protected. Package membership is unchanged: one entry, nine internal modules, 32 presets.

Release artifact: `dist/VoxelParticlesPlugin-v25.rbxmx`

SHA-256: `d151a68a2c8fb777a84007ceb310bd44a1fd352812381c8d4473720ab572c3c1`

Validation: reproduced the wrong birth size with one in-memory particle, then passed zero/small/default start values, skipped writes, curve progression at 30/60 simulation steps per second, and noise continuity. Scoped Luau analysis, manifest/XML/source checks and the existing installer scenarios including v24 updates passed. No Studio particle execution, Play, performance measurement, installation, reload or publication was performed; the operator's unsaved preset remains untouched.

## v24 — 2026-09-18

- Gameplay distance fading now starts no earlier than 70 studs and preserves the authored fade width. Continuous emission and bursts share this rule; quality, global budgets, local limits and viewport culling still apply.
- Made Studio Edit preview use authored density without quality, camera/LOD, soft-budget, global particle-cap, frame-spawn or pool-warmup reductions. Authored rate noise, lifetime, enabled state and maximum particle count remain in effect.
- Kept preview allocation bounded by authored emitter limits, with pool reuse and cleanup on configuration changes and destruction. Gameplay keeps its existing budget policy. Preview mode belongs to the bundled renderer and is never saved into presets.
- Added a preview-policy label and excluded paused Play from editor preview using `RunService:IsEdit()`.
- Plugin, runtime and installer share version 24. Package: one entry, nine internal modules and 32 presets. Exact v23 runtime remains eligible for update; edited and synced sources remain protected.

Release artifact: `dist/VoxelParticlesPlugin-v24.rbxmx`

SHA-256: `66bfd5b634763743cb87129008d624b9c3eecf8abc16ac07b214bd359b4ddbeb`

Validation: manifest/XML/source checks, compilation of all 42 sources, scoped Luau analysis, pure distance-arithmetic checks (70-stud boundary, preserved fade width, later/disabled LOD), and in-memory installer checks including v23-to-v24 updates, earlier releases, and edited/synced source protection. No particle execution, Studio preview, Play, performance measurement, installation or publication was performed.

## v23 — 2026-09-18

- Separated editor authoring/preview from project runtime installation. Customized and synced runtime no longer disables the editor. Added source export for disk-owned presets and an explicit read-only bundled preset library before installation.
- Preserved user modifications even when a runtime still carries plugin ownership metadata. Updates check released source or the unchanged installation fingerprint. Exact v12–v22 bundles remain updatable.
- Kept Minimum density at 15%, positive fractional rates and small bursts. Removed the quality-dependent visible-emitter cutoff; particle/frame quotas and camera culling remain.
- Added the game-independent `ClientVfxQuality.SetQualityCap` API. No game-specific settings or dependencies are bundled.
- Aligned preset factory/raw-table handling between editor and binder. Invalid presets produce named diagnostics without preventing other emitters from binding; yielding loads cannot attach a superseded selection.
- Plugin, runtime and installer share version 23. Package: one entry, nine internal modules and 32 presets.

Release artifact: `dist/VoxelParticlesPlugin-v23.rbxmx`

SHA-256: `84683be4e15345da5259d1b25a7591d45f40e315ea910b1ecc30a7b506a6c6a1`

Validation: manifest/XML/source checks, compilation of all 42 sources, scoped Luau analysis and in-memory installer checks for clean install, v12–v22 updates, edited/synced source protection and duplicates. Particle execution, Studio preview, Play, performance measurements, installation and publication were not performed. The reported third-party incident cannot be reproduced from a screenshot alone; the fixes address independently confirmed code paths.

## v22 — 2026-09-09

- Added explicit emission retirement through [StopEmission](README.md#stopping-emission-in-v22). Existing particle motion, presets, SetEnabled, Emit and simulation pause semantics are unchanged.
- Plugin, runtime and installer share version **22**. Package membership remains eight internal modules and 32 presets; installer logic is unchanged.

Release artifact: `dist/VoxelParticlesPlugin-v22.rbxmx`

SHA-256: `4165ed5b587bb8bf7ead73de909e23a25645e7f85ac0658173fe54aa464ae300`

Validation and installation scope: [v22 verification](tools/V22_VERIFICATION.md).

## v21 — 2026-09-08

- Added native planar launch spread and its editor controls. The configuration contract and example are in [README](README.md#flat-fan-spread-in-v21).
- Kept the existing cone path and all 32 authored presets unchanged. Preset loading, saving and runtime configuration accept the new optional fields without migrating old presets.
- Plugin, runtime and installer share version **21**; the complete artifact contains eight internal modules and 32 presets. Installation ownership behavior is unchanged.

Release artifact: `dist/VoxelParticlesPlugin-v21.rbxmx`

SHA-256: `13a3f34a9d5b16fc21564eff6ff197a64ee022d3a2b349f67b0e8a8aa7365344`

Validation and installation record: [v21 verification](tools/V21_VERIFICATION.md).

## v20 — 2026-09-05

- Added the client-wide dot API `VoxelParticleSystem.SetSimulationPaused(paused: boolean)`. Idempotent pause/resume freezes emission, existing particle motion/lifetime/noise, interpolation, unmasking, admission, and pool warmup without changing emitter enabled states.
- Paused `Emit()` requests return zero without building a backlog. Existing queued demand is preserved; real time and local-space anchor movement during pause are not replayed on resume. Quality reclamation waits for the first resumed frame.
- Added `GetDiagnostics().SimulationPaused`. Existing emitter APIs, preview controls, installer ownership rules and presets retain their behavior.
- Plugin, runtime, and installer share version **20**. The complete package contains eight internal modules and 32 presets.

Release artifact: `dist/VoxelParticlesPlugin-v20.rbxmx`

SHA-256: `3fe340f1fd4c446aac9586c7e5933a0df3548475a9e71735d5cc6ff3318b0e8e`

Validation: manifest build and exact XML/source hierarchy validation; all 41 package sources compile. Lune functional tests execute the runtime at 30/60 FPS and the packaged installer for clean initialization, v19 update, preserved/custom and missing presets, idempotency, duplicate ownership, stale synced source and Edit-only installation. Luau analysis with `plugin-sourcemap.json` reports no diagnostics in changed sources; the unchanged binder template reports its game-runtime require path and weak-table annotation diagnostics. No Studio installation, Play, visual, load test or publication was performed.

## v19 — 2026-09-05

- Reduced `sizeNoiseAmplitude` from 0.74 to 0.185 and `sizeNoiseFrequency` from 5.6 to 1.4 in both `Fire_1` and `SimpleFire`.
- Changed only `SimpleFire`'s color curve to green, turquoise, and blue. Flame motion, acceleration, lifetime, initial size, opacity, and emission remain as in v18.
- The complete package still contains 32 presets and eight internal modules. Plugin, runtime, and installer share version **19**; the 15 Hz camera admission and shared budgets are unchanged.

Release artifact: `dist/VoxelParticlesPlugin-v19.rbxmx`

SHA-256: `93e4de3632e6500a2965274c0b7e88b6537c398921979d5ea2577eec566710b0`

Validation: release build, focused static Luau analysis, and source/package inspection. No Play tests or visual acceptance were run.

## v18 — 2026-09-05

### Changed

- Camera distance and viewport selection now refresh at 15 Hz over the cached emitter registry. Renderer startup and quality changes still refresh immediately. No raycasts or repeated scene discovery are introduced.
- Spawn counters still reset each rendered frame. Pending burst demand prevents idle shutdown while waiting for the next admission poll; slow frames skip missed polls instead of running catch-up scans.
- Restored the original `Fire_1` and `SimpleFire` settings, changing only upward acceleration (39.5 to 10) and the initial size-curve multiplier (0.8 to 1.6).
- Restored the original pink Portal state. The golden `tp2` gateway and other presets are unchanged.
- Confetti retains SmoothPlastic and uses a full blue channel throughout its random color range, keeping HSV value at 1 without Neon or lights. Its palette is blue/lavender/pink.

Plugin, runtime, and installer version: **18**. All 32 presets and the existing shared budgets remain bundled.

Release artifact: `dist/VoxelParticlesPlugin-v18.rbxmx`

SHA-256: `e846ff17da2ca9bde78765c020e711bd78b8b0058c940091f01fc2853042baf2`

Validation: release build, static Luau analysis, and focused source review; no Play tests or performance measurements were run.

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
