--!strict
-- Shared client-side graphics ceiling and frame-pressure state for all world VFX.

local RunService = game:GetService("RunService")

if not RunService:IsClient() then
	error("ClientVfxQuality can only be required by client code")
end

local ClientVfxQuality = {}

ClientVfxQuality.Tier = table.freeze({
	Minimum = 0,
	Low = 1,
	Medium = 2,
	High = 3,
})

local tierChanged = Instance.new("BindableEvent")
local userGameSettings: any = nil
local manualCap = ClientVfxQuality.Tier.Medium
local effectiveTier = ClientVfxQuality.Tier.Medium
local automatic = true
local studioForcedTier: number? = nil
local rollingFrameTime = 1 / 60
local emergencySeconds = 0
local pressureSeconds = 0
local recoverySeconds = 0
local lastReason = "Initial"

local EMERGENCY_FRAME_TIME = 1 / 30
local PRESSURE_FRAME_TIME = 0.022
local RECOVERY_FRAME_TIME = 0.018
local EMERGENCY_HOLD = 0.75
local PRESSURE_HOLD = 2
local RECOVERY_HOLD = 8
local FRAME_EMA_ALPHA = 0.08

local okSettings, settings = pcall(function()
	return UserSettings():GetService("UserGameSettings")
end)
if okSettings then
	userGameSettings = settings
end

local function tierForSavedQuality(savedQuality: any): (number, boolean)
	if typeof(savedQuality) ~= "EnumItem" or savedQuality.EnumType ~= Enum.SavedQualitySetting then
		return ClientVfxQuality.Tier.Medium, true
	end
	if savedQuality.Name == "Automatic" then
		return ClientVfxQuality.Tier.High, true
	end
	local level = savedQuality.Value
	if level <= 2 then
		return ClientVfxQuality.Tier.Minimum, false
	elseif level <= 4 then
		return ClientVfxQuality.Tier.Low, false
	elseif level <= 7 then
		return ClientVfxQuality.Tier.Medium, false
	end
	return ClientVfxQuality.Tier.High, false
end

local function setEffectiveTier(nextTier: number, reason: string)
	nextTier = math.clamp(math.floor(nextTier), ClientVfxQuality.Tier.Minimum, manualCap)
	if studioForcedTier ~= nil then
		nextTier = studioForcedTier
	end
	if nextTier == effectiveTier then
		return
	end
	effectiveTier = nextTier
	lastReason = reason
	tierChanged:Fire(effectiveTier, lastReason)
end

local function refreshManualCap()
	local savedQuality = nil
	if userGameSettings ~= nil then
		local ok, value = pcall(function()
			return userGameSettings.SavedQualityLevel
		end)
		if ok then
			savedQuality = value
		end
	end
	local nextCap, isAutomatic = tierForSavedQuality(savedQuality)
	manualCap = nextCap
	automatic = isAutomatic
	if studioForcedTier ~= nil then
		manualCap = ClientVfxQuality.Tier.High
	end
	if effectiveTier > manualCap then
		setEffectiveTier(manualCap, "RobloxQualityCap")
	elseif effectiveTier < ClientVfxQuality.Tier.Minimum then
		setEffectiveTier(ClientVfxQuality.Tier.Minimum, "RobloxQualityCap")
	end
end

local function updateFramePressure(deltaTime: number)
	local safeDelta = math.clamp(deltaTime, 1 / 240, 0.25)
	rollingFrameTime += (safeDelta - rollingFrameTime) * FRAME_EMA_ALPHA

	if rollingFrameTime > EMERGENCY_FRAME_TIME then
		emergencySeconds += safeDelta
	else
		emergencySeconds = 0
	end
	if rollingFrameTime > PRESSURE_FRAME_TIME then
		pressureSeconds += safeDelta
	else
		pressureSeconds = 0
	end
	if rollingFrameTime < RECOVERY_FRAME_TIME then
		recoverySeconds += safeDelta
	else
		recoverySeconds = 0
	end

	if emergencySeconds >= EMERGENCY_HOLD and effectiveTier > ClientVfxQuality.Tier.Minimum then
		emergencySeconds = 0
		pressureSeconds = 0
		recoverySeconds = 0
		setEffectiveTier(effectiveTier - 1, "EmergencyFramePressure")
	elseif pressureSeconds >= PRESSURE_HOLD and effectiveTier > ClientVfxQuality.Tier.Minimum then
		pressureSeconds = 0
		recoverySeconds = 0
		setEffectiveTier(effectiveTier - 1, "SustainedFramePressure")
	elseif recoverySeconds >= RECOVERY_HOLD and effectiveTier < manualCap then
		recoverySeconds = 0
		setEffectiveTier(effectiveTier + 1, if automatic then "AutomaticRecovery" else "ManualCapRecovery")
	end
end

function ClientVfxQuality.GetTier(): number
	return effectiveTier
end

function ClientVfxQuality.GetParticleMultiplier(): number
	if effectiveTier <= ClientVfxQuality.Tier.Minimum then
		return 0
	elseif effectiveTier == ClientVfxQuality.Tier.Low then
		return 0.3
	elseif effectiveTier == ClientVfxQuality.Tier.Medium then
		return 0.65
	end
	return 1
end

function ClientVfxQuality.OnTierChanged(callback: (number, string) -> ()): RBXScriptConnection
	return tierChanged.Event:Connect(callback)
end

function ClientVfxQuality.SetStudioForcedTier(tier: number?)
	if not RunService:IsStudio() then
		error("SetStudioForcedTier is Studio-only")
	end
	if tier ~= nil then
		tier = math.clamp(math.floor(tier), ClientVfxQuality.Tier.Minimum, ClientVfxQuality.Tier.High)
	end
	studioForcedTier = tier
	refreshManualCap()
	setEffectiveTier(if tier ~= nil then tier else math.min(effectiveTier, manualCap), "StudioForcedTier")
end

function ClientVfxQuality.GetDiagnostics(): {[string]: any}
	return {
		Tier = effectiveTier,
		ManualCap = manualCap,
		Automatic = automatic,
		RollingFrameTimeMs = rollingFrameTime * 1000,
		Reason = lastReason,
		StudioForcedTier = studioForcedTier,
	}
end

refreshManualCap()
if automatic and studioForcedTier == nil then
	effectiveTier = ClientVfxQuality.Tier.Medium
else
	effectiveTier = math.min(manualCap, studioForcedTier or manualCap)
end

if userGameSettings ~= nil then
	local okSignal, signal = pcall(function()
		return userGameSettings:GetPropertyChangedSignal("SavedQualityLevel")
	end)
	if okSignal and signal then
		signal:Connect(refreshManualCap)
	end
end

pcall(function()
	game.GraphicsQualityChangeRequest:Connect(function()
		task.defer(refreshManualCap)
	end)
end)

RunService.RenderStepped:Connect(updateFramePressure)

return table.freeze(ClientVfxQuality)
