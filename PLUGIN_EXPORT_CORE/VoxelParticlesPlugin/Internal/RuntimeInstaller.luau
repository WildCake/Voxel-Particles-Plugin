local ChangeHistoryService = game:GetService("ChangeHistoryService")
local InstanceFileSyncService = game:GetService("InstanceFileSyncService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local StarterPlayer = game:GetService("StarterPlayer")

local RuntimeInstaller = {}
local Internal = script.Parent
local BundledVPS = Internal:WaitForChild("VoxelParticleSystem")
local BundledBinder = Internal:WaitForChild("VoxelEmitterBinderTemplate")
if not BundledBinder:IsA("ModuleScript") then
	error("Internal.VoxelEmitterBinderTemplate must be an inert ModuleScript source template")
end
local BundledSharedRuntime = {
	ClientVfxQuality = Internal:WaitForChild("ClientVfxQuality"),
	VoxelFairShareAllocator = Internal:WaitForChild("VoxelFairShareAllocator"),
	VoxelMotionIntegrator = Internal:WaitForChild("VoxelMotionIntegrator"),
	VoxelCubicBezier = Internal:WaitForChild("VoxelCubicBezier"),
	VoxelCylinderStream = Internal:WaitForChild("VoxelCylinderStream"),
}
local BundledPresets = Internal:WaitForChild("BundledPresets")

local RUNTIME_VERSION = 13
local INSTALLER_VERSION = 5
local MANAGED_ATTRIBUTE = "VoxelParticlesPluginManaged"
local VERSION_ATTRIBUTE = "VoxelParticlesRuntimeVersion"
local INSTALLER_ATTRIBUTE = "VoxelParticlesInstallerVersion"
local ROLE_ATTRIBUTE = "VoxelParticlesRuntimeRole"
local LEGACY_FINGERPRINTS = {
	VoxelParticleSystem = { length = 84642, djb2 = 2280397555, sdbm = 4125035962 },
	VoxelEmitterBinder = { length = 5374, djb2 = 1141971026, sdbm = 2214730513 },
}

local function readScriptSource(instance)
	return ScriptEditorService:GetEditorSource(instance)
end

local function writeScriptSource(instance, source)
	ScriptEditorService:UpdateSourceAsync(instance, function()
		return source
	end)
end

local function isFileSynced(instance)
	return InstanceFileSyncService:GetStatus(instance) ~= Enum.InstanceFileSyncStatus.NotSynced
end

local function fullName(instance)
	local ok, result = pcall(function()
		return instance:GetFullName()
	end)
	return ok and result or instance.Name
end

local function describeInstance(instance)
	local duplicateIndex = 0
	local parent = instance.Parent
	if parent then
		for _, sibling in ipairs(parent:GetChildren()) do
			if sibling.Name == instance.Name then
				duplicateIndex += 1
				if sibling == instance then
					break
				end
			end
		end
	end
	return ("%s [%s #%d]"):format(fullName(instance), instance.ClassName, math.max(duplicateIndex, 1))
end

local function namedChildren(parent, name)
	local matches = {}
	for _, child in ipairs(parent:GetChildren()) do
		if child.Name == name then
			table.insert(matches, child)
		end
	end
	return matches
end

local function sourceFingerprint(source)
	local djb2 = 5381
	local sdbm = 0
	for index = 1, #source do
		local byte = string.byte(source, index)
		djb2 = (djb2 * 33 + byte) % 4294967296
		sdbm = (sdbm * 65599 + byte) % 4294967296
	end
	return #source, djb2, sdbm
end

local function isKnownLegacyRuntime(instance, name)
	local expected = LEGACY_FINGERPRINTS[name]
	if not expected then
		return false
	end
	local length, djb2, sdbm = sourceFingerprint(readScriptSource(instance))
	return length == expected.length and djb2 == expected.djb2 and sdbm == expected.sdbm
end

local function hasCurrentSource(instance, bundled)
	return readScriptSource(instance) == readScriptSource(bundled)
end

local function isManaged(instance)
	return instance:GetAttribute(MANAGED_ATTRIBUTE) == true
end

local function isSafePluginRuntime(instance, name, bundled)
	return isManaged(instance)
		or hasCurrentSource(instance, bundled)
		or isKnownLegacyRuntime(instance, name)
end

local function markManaged(instance, role)
	instance:SetAttribute(MANAGED_ATTRIBUTE, true)
	instance:SetAttribute(VERSION_ATTRIBUTE, RUNTIME_VERSION)
	instance:SetAttribute(INSTALLER_ATTRIBUTE, INSTALLER_VERSION)
	instance:SetAttribute(ROLE_ATTRIBUTE, role)
end

local lastDuplicateWarningSignature = nil

local function addConflict(status, message)
	status.blocked = true
	table.insert(status.conflicts, message)
end

local function addDuplicate(status, instances)
	local paths = {}
	for _, instance in ipairs(instances) do
		local path = describeInstance(instance)
		table.insert(paths, path)
		table.insert(status.duplicatePaths, path)
	end
	table.sort(paths)
	status.needsUpdate = true
	return table.concat(paths, ", ")
end

local function emitDuplicateWarning(status)
	if #status.duplicatePaths == 0 then
		lastDuplicateWarningSignature = nil
		return
	end
	local paths = table.clone(status.duplicatePaths)
	table.sort(paths)
	local signature = table.concat(paths, "\n")
	if signature == lastDuplicateWarningSignature then
		return
	end
	lastDuplicateWarningSignature = signature
	warn("[VoxelParticlesPlugin] Duplicate runtime instances detected; initialization will keep one proven owner and will never overwrite an unknown copy:\n - "
		.. table.concat(paths, "\n - "))
end

local function analyzeUniqueFolder(status, parent, name)
	local matches = namedChildren(parent, name)
	if #matches > 1 then
		local paths = addDuplicate(status, matches)
		addConflict(status, ("Multiple folders named %s exist: %s"):format(name, paths))
		return nil
	end
	local existing = matches[1]
	if existing and not existing:IsA("Folder") then
		addConflict(status, ("Expected %s.%s to be a Folder, got %s")
			:format(fullName(parent), name, existing.ClassName))
		return nil
	end
	return existing
end

local function analyzeTarget(status, key, parent, name, className, bundled, candidates)
	local plan = {
		key = key,
		parent = parent,
		name = name,
		className = className,
		bundled = bundled,
		owner = nil,
		remove = {},
		replace = false,
		create = false,
	}
	status.targetPlans[key] = plan

	if #candidates == 0 then
		if isFileSynced(parent) then
			addConflict(status, ("Native Script Sync owns %s; add missing %s from its disk source")
				:format(fullName(parent), name))
		else
			status.needsUpdate = true
			plan.create = true
		end
		return
	end

	if #candidates > 1 then
		addDuplicate(status, candidates)
	end

	local synced = {}
	local current = {}
	local safe = {}
	for _, candidate in ipairs(candidates) do
		if candidate.ClassName ~= className then
			addConflict(status, ("Expected %s to be a %s, got %s")
				:format(fullName(candidate), className, candidate.ClassName))
			continue
		end
		if isFileSynced(candidate) then
			table.insert(synced, candidate)
			if candidate:IsA("LocalScript") and not candidate.Enabled then
				addConflict(status, ("Native Script Sync binder is disabled: %s")
					:format(fullName(candidate)))
			end
		elseif isSafePluginRuntime(candidate, name, bundled) then
			table.insert(safe, candidate)
			if hasCurrentSource(candidate, bundled) then
				table.insert(current, candidate)
			end
		else
			addConflict(status, ("Unmanaged runtime source will not be overwritten: %s")
				:format(fullName(candidate)))
		end
	end

	if #synced > 1 then
		addConflict(status, ("Multiple native Script Sync owners exist for %s")
			:format(name))
		return
	end

	local owner = synced[1]
	if not owner then
		for _, candidate in ipairs(current) do
			if candidate.Parent == parent then
				owner = candidate
				break
			end
		end
	end
	owner = owner or current[1]
	if not owner then
		for _, candidate in ipairs(safe) do
			if candidate.Parent == parent then
				owner = candidate
				break
			end
		end
	end
	owner = owner or safe[1]
	if not owner then
		return
	end
	plan.owner = owner

	if owner.Parent ~= parent then
		addConflict(status, ("Runtime %s must be a direct child of %s, found %s")
			:format(name, fullName(parent), fullName(owner)))
		return
	end

	for _, candidate in ipairs(candidates) do
		if candidate ~= owner and not isFileSynced(candidate) and isSafePluginRuntime(candidate, name, bundled) then
			table.insert(plan.remove, candidate)
		end
	end

	if not isFileSynced(owner) then
		local currentSource = hasCurrentSource(owner, bundled)
		local currentMetadata = owner:GetAttribute(VERSION_ATTRIBUTE) == RUNTIME_VERSION
			and owner:GetAttribute(INSTALLER_ATTRIBUTE) == INSTALLER_VERSION
			and owner:GetAttribute(ROLE_ATTRIBUTE) == key
		local enabled = not owner:IsA("LocalScript") or owner.Enabled
		if not currentSource then
			plan.replace = true
			status.needsUpdate = true
		elseif not currentMetadata or not enabled then
			status.needsUpdate = true
		end
	end
	if #plan.remove > 0 then
		status.needsUpdate = true
	end
end

local function binderCandidates(starterPlayerScripts)
	local candidates = {}
	for _, descendant in ipairs(starterPlayerScripts:GetDescendants()) do
		if descendant.Name == "VoxelEmitterBinder" then
			table.insert(candidates, descendant)
		end
	end
	return candidates
end

local function analyzePresetFolder(status, folder)
	local byName = {}
	for _, child in ipairs(folder:GetChildren()) do
		local group = byName[child.Name]
		if not group then
			group = {}
			byName[child.Name] = group
		end
		table.insert(group, child)
	end
	for name, group in pairs(byName) do
		if #group > 1 then
			local paths = addDuplicate(status, group)
			addConflict(status, ("Duplicate presets named %s exist: %s"):format(name, paths))
		end
	end

	for _, bundled in ipairs(BundledPresets:GetChildren()) do
		if bundled:IsA("ModuleScript") then
			local matches = namedChildren(folder, bundled.Name)
			local existing = matches[1]
			if not existing then
				if isFileSynced(folder) then
					addConflict(status, ("Native Script Sync owns %s; add missing bundled preset %s from disk")
						:format(fullName(folder), bundled.Name))
				else
					status.needsUpdate = true
					table.insert(status.missingPresets, bundled)
				end
			elseif not existing:IsA("ModuleScript") then
				addConflict(status, ("Expected preset %s to be a ModuleScript, got %s")
					:format(fullName(existing), existing.ClassName))
			end
		end
	end
end

function RuntimeInstaller.inspectRuntime()
	local status = {
		ready = false,
		blocked = false,
		needsUpdate = false,
		sharedFolder = nil,
		presetsFolder = nil,
		conflicts = {},
		duplicatePaths = {},
		targetPlans = {},
		missingPresets = {},
		action = "Initialize project",
		message = "Project runtime is not initialized.",
	}

	local foundShared = analyzeUniqueFolder(status, ReplicatedStorage, "Shared")
	status.sharedFolder = foundShared
	if not foundShared then
		if #namedChildren(ReplicatedStorage, "Shared") == 0 then
			status.needsUpdate = true
		end
	else
		local foundPresets = analyzeUniqueFolder(status, foundShared, "VoxelEmitterPresets")
		status.presetsFolder = foundPresets
		if not foundPresets then
			if #namedChildren(foundShared, "VoxelEmitterPresets") == 0 then
				if isFileSynced(foundShared) then
					addConflict(status, ("Native Script Sync owns %s; create VoxelEmitterPresets from disk")
						:format(fullName(foundShared)))
				else
					status.needsUpdate = true
				end
			end
		else
			analyzePresetFolder(status, foundPresets)
		end

		for name, bundled in pairs(BundledSharedRuntime) do
			analyzeTarget(status, name, foundShared, name, "ModuleScript", bundled, namedChildren(foundShared, name))
		end
		analyzeTarget(status, "VoxelParticleSystem", foundShared, "VoxelParticleSystem", "ModuleScript", BundledVPS,
			namedChildren(foundShared, "VoxelParticleSystem"))
	end

	local starterPlayerScripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
	analyzeTarget(status, "ClientBinder", starterPlayerScripts, "VoxelEmitterBinder", "LocalScript", BundledBinder,
		binderCandidates(starterPlayerScripts))

	emitDuplicateWarning(status)
	if status.blocked then
		status.action = "Rescan conflicts"
		status.message = status.conflicts[1] or "Runtime conflicts must be resolved."
	elseif status.needsUpdate then
		status.action = foundShared and "Update project" or "Initialize project"
		status.message = foundShared and "Runtime update is required." or "Project runtime is not initialized."
	else
		status.ready = true
		status.action = "Runtime ready"
		status.message = "Voxel Particles runtime is ready."
	end
	return status
end

local function ensureFolder(parent, name, role)
	local matches = namedChildren(parent, name)
	if #matches > 1 then
		error(("Cannot initialize while duplicate %s folders exist under %s")
			:format(name, fullName(parent)))
	end
	local existing = matches[1]
	if existing then
		if not existing:IsA("Folder") then
			error(("Expected %s.%s to be a Folder"):format(fullName(parent), name))
		end
		return existing
	end
	if isFileSynced(parent) then
		error(("Native Script Sync owns %s; create %s from disk"):format(fullName(parent), name))
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	markManaged(folder, role)
	folder.Parent = parent
	return folder
end

local function prepareRuntime(bundled, name, role, className)
	local runtime
	if className == "ModuleScript" then
		runtime = Instance.new("ModuleScript")
	elseif className == "LocalScript" then
		runtime = Instance.new("LocalScript")
		runtime.Enabled = false
	else
		error(("Unsupported runtime class %s for %s"):format(tostring(className), name))
	end

	local ok, prepareError = pcall(function()
		runtime.Name = name
		writeScriptSource(runtime, readScriptSource(bundled))
		markManaged(runtime, role)
		if runtime:IsA("LocalScript") then
			runtime.Enabled = true
		end
	end)
	if not ok then
		runtime:Destroy()
		error(prepareError, 0)
	end
	return runtime
end

local function applyTargetPlan(plan)
	for _, duplicate in ipairs(plan.remove) do
		warn(("[VoxelParticlesPlugin] Removing proven duplicate runtime: %s")
			:format(fullName(duplicate)))
		duplicate:Destroy()
	end
	if plan.create then
		local created = prepareRuntime(plan.bundled, plan.name, plan.key, plan.className)
		created.Parent = plan.parent
		return created
	end
	local owner = plan.owner
	if not owner then
		error(("No safe owner was selected for %s"):format(plan.name))
	end
	if isFileSynced(owner) then
		return owner
	end
	if plan.replace then
		local parent = owner.Parent
		local replacement = prepareRuntime(plan.bundled, plan.name, plan.key, plan.className)
		owner:Destroy()
		replacement.Parent = parent
		return replacement
	end
	markManaged(owner, plan.key)
	if owner:IsA("LocalScript") then
		owner.Enabled = true
	end
	return owner
end

function RuntimeInstaller.initializeRuntime()
	if RunService:IsRunning() then
		error("Voxel Particles runtime can only be initialized from Edit mode")
	end
	local before = RuntimeInstaller.inspectRuntime()
	if before.blocked then
		error("Voxel Particles initialization blocked:\n - " .. table.concat(before.conflicts, "\n - "))
	end
	if before.ready then
		return before
	end

	local recording = ChangeHistoryService:TryBeginRecording(
		"VoxelParticles.InitializeRuntime",
		"Initialize Voxel Particles runtime"
	)
	if not recording then
		error("Voxel Particles could not start an undo recording; finish the active Studio operation and retry")
	end

	local ok, result = pcall(function()
		local installedShared = ensureFolder(ReplicatedStorage, "Shared", "SharedFolder")
		local installedPresets = ensureFolder(installedShared, "VoxelEmitterPresets", "PresetFolder")

		local prepared = RuntimeInstaller.inspectRuntime()
		if prepared.blocked then
			error(table.concat(prepared.conflicts, "\n"))
		end
		for _, plan in pairs(prepared.targetPlans) do
			applyTargetPlan(plan)
		end
		for _, bundled in ipairs(prepared.missingPresets) do
			local clone = bundled:Clone()
			clone.Parent = installedPresets
		end

		local final = RuntimeInstaller.inspectRuntime()
		if not final.ready then
			error(final.message)
		end
		return final
	end)

	ChangeHistoryService:FinishRecording(
		recording,
		ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
	)
	if not ok then
		error(result, 0)
	end
	print("[VoxelParticlesPlugin] Runtime initialization complete; duplicate-safe owner set installed")
	return result
end

-- Plugin startup and Edit preview are read-only. Installation happens only after
-- the operator presses the initialization/update button in the widget.
RuntimeInstaller.VPS = require(BundledVPS)
RuntimeInstaller.isFileSynced = isFileSynced
RuntimeInstaller.readScriptSource = readScriptSource
RuntimeInstaller.writeScriptSource = writeScriptSource

return RuntimeInstaller
