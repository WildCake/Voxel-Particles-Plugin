--!strict
-- Run from the repository root: lune run tools/test_runtime_installer.luau
-- Executes the packaged installer against an in-memory DataModel and editor/sync mocks.
-- Never opens Studio, writes a place, installs a plugin, or contacts Roblox.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local Instance = roblox.Instance
local manifest = serde.decode("json", fs.readFile("plugin-package.json"))
local artifact = "dist/VoxelParticlesPlugin-v" .. manifest.pluginVersion .. ".rbxmx"
local package = roblox.deserializeModel(fs.readFile(artifact))[1]
local internal = package:FindFirstChild("Internal")
local bundledPresets = internal:FindFirstChild("BundledPresets")
local runtimeVersion = "VoxelParticlesRuntimeVersion"
local installerVersion = "VoxelParticlesInstallerVersion"

roblox.implementMethod("Instance", "WaitForChild", function(instance: any, name: string): any
	return assert(instance:FindFirstChild(name), name)
end)

local sharedService = Instance.new("ReplicatedStorage")
local starterPlayer = Instance.new("StarterPlayer")
local starterScripts = Instance.new("StarterPlayerScripts")
starterScripts.Parent = starterPlayer
local synced: {[any]: boolean} = {}
local writes = 0
local recordings = 0
local finishes = 0
local running = false
local services: any = {
	ReplicatedStorage = sharedService,
	StarterPlayer = starterPlayer,
	RunService = { IsRunning = function(): boolean return running end },
	InstanceFileSyncService = {
		GetStatus = function(_self: any, instance: any): string
			return synced[instance] and "Synced" or "NotSynced"
		end,
	},
	ScriptEditorService = {
		GetEditorSource = function(_self: any, instance: any): string return instance.Source end,
		UpdateSourceAsync = function(_self: any, instance: any, callback: (string) -> string)
			assert(not synced[instance], "Installer wrote a synced owner")
			instance.Source = callback(instance.Source)
			writes += 1
		end,
	},
	ChangeHistoryService = {
		TryBeginRecording = function(): string recordings += 1; return "test-recording" end,
		FinishRecording = function(_self: any, id: string, operation: string)
			assert(id == "test-recording" and operation == "Commit")
			finishes += 1
		end,
	},
}
local env: any = table.clone(roblox)
env.Enum = {
	InstanceFileSyncStatus = { NotSynced = "NotSynced" },
	FinishRecordingOperation = { Commit = "Commit", Cancel = "Cancel" },
}
env.script = internal:FindFirstChild("RuntimeInstaller")
env.game = { GetService = function(_self: any, name: string): any return assert(services[name], name) end }
env.require = function(module: any): any
	assert(module == internal:FindFirstChild("VoxelParticleSystem"))
	return {} -- Runtime itself is covered by test_simulation_pause.luau.
end
local installer = luau.load(env.script.Source, { environment = env, debugName = "PackagedRuntimeInstaller" })()
assert(writes == 0 and recordings == 0, "Loading the plugin must not install project source")

local function verifyInstalled(): any
	local status = installer.inspectRuntime()
	assert(status.ready and not status.blocked and not status.needsUpdate)
	local targetCount = 0
	for _, plan in status.targetPlans do
		targetCount += 1
		assert(plan.owner.Source == plan.bundled.Source, "Installed source differs from its package sibling")
		assert(plan.owner:GetAttribute(runtimeVersion) == manifest.runtimeVersion)
		assert(plan.owner:GetAttribute(installerVersion) == manifest.installerVersion)
		assert(plan.owner.ClassName == plan.className and plan.owner.Parent == plan.parent)
		if plan.className == "LocalScript" then assert(plan.owner.Enabled) end
	end
	assert(targetCount == 7, "Six shared runtime modules and one binder must ship together")
	assert(#status.presetsFolder:GetChildren() == #manifest.bundledPresets)
	for _, bundled in bundledPresets:GetChildren() do
		assert(status.presetsFolder:FindFirstChild(bundled.Name), "Missing bundled preset")
	end
	return status
end

local initial = installer.inspectRuntime()
assert(not initial.ready and not initial.blocked and initial.needsUpdate)
assert(writes == 0)
installer.initializeRuntime()
local installed = verifyInstalled()
assert(writes == 7 and recordings == 1 and finishes == 1)
installer.initializeRuntime()
assert(writes == 7 and recordings == 1, "Already-current initialization must be idempotent")
print("PASS clean installation: complete runtime, enabled binder, all presets; idempotent rescan")

local previousVersion = manifest.runtimeVersion - 1
local previousPackage = roblox.deserializeModel(fs.readFile("dist/VoxelParticlesPlugin-v" .. previousVersion .. ".rbxmx"))[1]
local previousInternal = previousPackage:FindFirstChild("Internal")
for key, plan in installed.targetPlans do
	local oldName = key == "ClientBinder" and "VoxelEmitterBinderTemplate" or plan.name
	plan.owner.Source = previousInternal:FindFirstChild(oldName).Source
	plan.owner:SetAttribute(runtimeVersion, previousVersion)
	plan.owner:SetAttribute(installerVersion, previousVersion)
end
local customPreset = installed.presetsFolder:FindFirstChild("Default")
customPreset.Source = "return { projectCustomization = true }"
installed.presetsFolder:FindFirstChild("WindRibbon"):Destroy()
local oldRuntime = installed.targetPlans.VoxelParticleSystem.owner
local beforeUpdate = installer.inspectRuntime()
assert(beforeUpdate.needsUpdate and not beforeUpdate.blocked)
installer.initializeRuntime()
installed = verifyInstalled()
assert(installed.targetPlans.VoxelParticleSystem.owner ~= oldRuntime)
assert(customPreset.Source == "return { projectCustomization = true }", "Preserve authored presets")
assert(installed.presetsFolder:FindFirstChild("WindRibbon").Source == bundledPresets:FindFirstChild("WindRibbon").Source)
print("PASS managed v" .. previousVersion .. " to v" .. manifest.runtimeVersion .. " update: all target versions, replacement runtime, preserved/custom and missing presets")

local owner = installed.targetPlans.VoxelParticleSystem.owner
local latestSource = owner.Source
owner.Source = previousInternal:FindFirstChild("VoxelParticleSystem").Source
synced[owner] = true
local writesBefore, recordingsBefore = writes, recordings
local conflict = installer.inspectRuntime()
assert(conflict.blocked and not conflict.ready and conflict.needsUpdate)
assert(not pcall(installer.initializeRuntime))
assert(writes == writesBefore and recordings == recordingsBefore)
assert(owner.Source == previousInternal:FindFirstChild("VoxelParticleSystem").Source)
owner.Source = latestSource -- Simulated disk owner update, outside the installer.
assert(installer.inspectRuntime().ready)
synced[owner] = nil
print("PASS stale synced owner blocks before writes; complete reviewed disk update restores readiness")

local duplicate = owner:Clone()
duplicate.Parent = owner.Parent
assert(installer.inspectRuntime().needsUpdate)
installer.initializeRuntime()
installed = verifyInstalled()
owner = installed.targetPlans.VoxelParticleSystem.owner
local unknown = Instance.new("ModuleScript")
unknown.Name = owner.Name
unknown.Source = "return { userOwned = true }"
unknown.Parent = owner.Parent
writesBefore, recordingsBefore = writes, recordings
assert(installer.inspectRuntime().blocked)
assert(not pcall(installer.initializeRuntime))
assert(writes == writesBefore and recordings == recordingsBefore)
unknown:Destroy()
running = true
assert(not pcall(installer.initializeRuntime), "Runtime installation requires Edit")
assert(writes == writesBefore and recordings == recordingsBefore)
print("PASS proven duplicate cleanup; unmanaged duplicate and Play installation fail closed")
