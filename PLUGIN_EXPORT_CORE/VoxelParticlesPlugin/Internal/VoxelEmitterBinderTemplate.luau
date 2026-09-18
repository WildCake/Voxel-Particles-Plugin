-- VoxelEmitterBinder source: inert ModuleScript template in plugin, enabled LocalScript after installation.
-- Биндер только:
--  • следит за тегом CollectionService "VoxelEmitter"
--  • читает Attribute "VoxelPreset"
--  • триггерит бёрсты по Attribute "VoxelBurst"
-- Направление эмиссии полностью считается внутри VoxelParticleSystem
-- из локального emissionDirection и CFrame эмиттера.

-- Luau-safe

if script.Name == "VoxelEmitterBinderTemplate" then
	warn(("[VoxelParticles] Binder source template was required and has stopped itself: %s")
		:format(script:GetFullName()))
	return {}
end

local RunService        = game:GetService("RunService")
if not RunService:IsRunning() then
	return
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")

-- ==== Константы/атрибуты ======================================================
local TAG                       = "VoxelEmitter"
local PRESET_ATTRIBUTE          = "VoxelPreset"
local BURST_ATTRIBUTE           = "VoxelBurst"
local BURST_ON_ENABLE_ATTRIBUTE = "VoxelBurstOnEnable"
local BINDER_OWNER_NAME         = "__VoxelParticlesBinderOwner"

local function describeBinder(instance: Instance): string
	local ordinal = 0
	local parent = instance.Parent
	if parent then
		for _, sibling in ipairs(parent:GetChildren()) do
			if sibling:IsA("LocalScript") and sibling.Name == instance.Name then
				ordinal += 1
				if sibling == instance then
					break
				end
			end
		end
	end
	return ("%s [#%d]"):format(instance:GetFullName(), math.max(ordinal, 1))
end

local function claimBinderOwnership(): ObjectValue?
	local player = Players.LocalPlayer
	local playerScripts = player and player:FindFirstChildOfClass("PlayerScripts")
	if not playerScripts then
		warn(("[VoxelParticles] VoxelEmitterBinder cannot find LocalPlayer.PlayerScripts; binder=%s")
			:format(script:GetFullName()))
		return nil
	end

	local existing = playerScripts:FindFirstChild(BINDER_OWNER_NAME)
	if existing then
		if existing:IsA("ObjectValue") then
			local owner = existing.Value
			if owner == script then
				return existing
			end
			if owner == nil then
				existing:Destroy()
			else
				warn(("[VoxelParticles] Duplicate VoxelEmitterBinder ignored; duplicate=%s owner=%s")
					:format(describeBinder(script), describeBinder(owner)))
				return nil
			end
		else
			warn(("[VoxelParticles] VoxelEmitterBinder ownership marker has unexpected class %s at %s; binder=%s")
				:format(existing.ClassName, existing:GetFullName(), script:GetFullName()))
			return nil
		end
	end

	local claim = Instance.new("ObjectValue")
	claim.Name = BINDER_OWNER_NAME
	claim.Archivable = false
	claim.Value = script
	claim.Parent = playerScripts
	return claim
end

local binderClaim = claimBinderOwnership()
if not binderClaim then
	return
end

-- ==== Доступ к Shared =========================================================
local Shared        = ReplicatedStorage:WaitForChild("Shared")
local PresetsFolder = Shared:WaitForChild("VoxelEmitterPresets")
local VPS           = require(Shared:WaitForChild("VoxelParticleSystem"))

-- ==== Состояние биндера =======================================================
type BindingRecord = {
	Emitter: any?,
	Revision: number,
	Connections: {RBXScriptConnection},
}

local bindings = setmetatable({} :: {[BasePart]: BindingRecord}, { __mode = "k" })
local shuttingDown = false

-- ==== Утилиты =================================================================
local function deepCopy(v)
	if typeof(v) == "table" then
		local t = {}
		for k, val in pairs(v) do
			t[k] = deepCopy(val)
		end
		return t
	end
	return v
end

local function loadPresetState(name: string): any?
	if typeof(name) ~= "string" or name == "" then return nil end
	local mod = PresetsFolder:FindFirstChild(name)
	if not (mod and mod:IsA("ModuleScript")) then
		warn(("[VoxelParticles] Missing preset ModuleScript: %s.%s"):format(PresetsFolder:GetFullName(), name))
		return nil
	end
	local ok, result = pcall(function()
		local data = require(mod)
		if typeof(data) == "function" then data = data() end
		assert(typeof(data) == "table", "Preset must return a table or a factory returning a table")
		local state = deepCopy(data.state or data)
		assert(typeof(state) == "table", "Preset state must be a table")
		if data.enabled ~= nil then state.enabled = data.enabled end
		if data.seed ~= nil then state.seed = data.seed end
		return state
	end)
	if not ok then
		warn(("[VoxelParticles] Preset failed: %s — %s"):format(mod:GetFullName(), tostring(result)))
		return nil
	end
	return result
end

local function destroyEmitter(record: BindingRecord)
	local emitter = record.Emitter
	record.Emitter = nil
	if emitter then
		pcall(function()
			emitter:Destroy()
		end)
	end
end

local function bind(part: BasePart)
	local record = bindings[part]
	if record == nil then
		return
	end

	record.Revision += 1
	local revision = record.Revision
	destroyEmitter(record)
	if not CollectionService:HasTag(part, TAG) or not part:IsDescendantOf(Workspace) then
		return
	end

	local presetName = part:GetAttribute(PRESET_ATTRIBUTE)
	if typeof(presetName) ~= "string" or presetName == "" then
		warn(("[VoxelParticles] Emitter has no VoxelPreset: %s"):format(part:GetFullName()))
		return
	end

	local cfg = loadPresetState(presetName)
	if not cfg then
		return
	end
	-- require/factory can yield; only the still-current selection owns this result.
	if bindings[part] ~= record or record.Revision ~= revision
		or not part:IsDescendantOf(Workspace) or not CollectionService:HasTag(part, TAG) then return end

	local burstOnEnable = (part:GetAttribute(BURST_ON_ENABLE_ATTRIBUTE) == true)
	if burstOnEnable then
		cfg.burstOnEnable = true
	end

	local attached, emitter = pcall(VPS.Attach, part, cfg)
	if not attached then
		warn(("[VoxelParticles] Emitter failed: %s; preset=%s — %s")
			:format(part:GetFullName(), presetName, tostring(emitter)))
		return
	end
	record.Emitter = emitter

	-- Первичный BURST, если атрибут уже выставлен
	local wantAttr = part:GetAttribute(BURST_ATTRIBUTE)
	local want = (typeof(wantAttr) == "number") and wantAttr or 0
	if want ~= 0 then
		if want == -1 then
			local count = tonumber(cfg.burstCount) or 0
			if count > 0 then
				emitter:Emit(count)
			end
		elseif want > 0 then
			emitter:Emit(math.floor(want))
		end
		part:SetAttribute(BURST_ATTRIBUTE, 0)
	end
end

local function unwatch(part: BasePart)
	local record = bindings[part]
	if record == nil then
		return
	end

	bindings[part] = nil
	destroyEmitter(record)
	for _, connection in ipairs(record.Connections) do
		connection:Disconnect()
	end
	table.clear(record.Connections)
end

local function watch(part: BasePart)
	if shuttingDown or bindings[part] ~= nil then
		return
	end

	local record: BindingRecord = {
		Emitter = nil,
		Revision = 0,
		Connections = {},
	}
	bindings[part] = record

	-- Смена пресета → ребинд
	record.Connections[#record.Connections + 1] = part:GetAttributeChangedSignal(PRESET_ATTRIBUTE):Connect(function()
		bind(part)
	end)

	-- Сигнал бёрста: просто вызываем Emit у уже привязанного эмиттера
	record.Connections[#record.Connections + 1] = part:GetAttributeChangedSignal(BURST_ATTRIBUTE):Connect(function()
		local emitter = record.Emitter
		if not emitter then
			return
		end

		local vAttr = part:GetAttribute(BURST_ATTRIBUTE)
		local v = (typeof(vAttr) == "number") and vAttr or 0
		if v == 0 then
			return
		end

		if v == -1 then
			local cfg = loadPresetState(tostring(part:GetAttribute(PRESET_ATTRIBUTE) or ""))
			local count = cfg and tonumber(cfg.burstCount) or 0
			if count and count > 0 then
				emitter:Emit(count)
			end
			part:SetAttribute(BURST_ATTRIBUTE, 0)
		elseif v >= 1 then
			emitter:Emit(math.floor(v))
			part:SetAttribute(BURST_ATTRIBUTE, 0)
		end
	end)

	-- Изменение родителя/удаление
	record.Connections[#record.Connections + 1] = part.AncestryChanged:Connect(function()
		if part:IsDescendantOf(Workspace) then
			bind(part)
		else
			destroyEmitter(record)
		end
	end)
	record.Connections[#record.Connections + 1] = part.Destroying:Connect(function()
		unwatch(part)
	end)

	bind(part)
end

local tagAddedConnection = CollectionService:GetInstanceAddedSignal(TAG):Connect(function(inst)
	if inst:IsA("BasePart") then
		watch(inst)
	end
end)

local tagRemovedConnection = CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(inst)
	if inst:IsA("BasePart") then
		unwatch(inst)
	end
end)

script.Destroying:Connect(function()
	if shuttingDown then
		return
	end
	shuttingDown = true

	tagAddedConnection:Disconnect()
	tagRemovedConnection:Disconnect()
	local watchedParts = {}
	for part in pairs(bindings) do
		watchedParts[#watchedParts + 1] = part
	end
	for _, part in ipairs(watchedParts) do
		unwatch(part)
	end

	if binderClaim.Parent and binderClaim.Value == script then
		binderClaim:Destroy()
	end
end)

-- Subscribe and own cleanup before a custom preset can yield during enumeration.
for _, inst in ipairs(CollectionService:GetTagged(TAG)) do
	if inst:IsA("BasePart") then watch(inst) end
end
