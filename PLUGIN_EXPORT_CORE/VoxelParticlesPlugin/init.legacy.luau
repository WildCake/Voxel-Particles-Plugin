-- Roblox Studio plugin for authoring voxel particle emitters.
-- Based on the runtime particlesUI and VoxelParticleSystem modules.

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Selection = game:GetService("Selection")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local function recordChange(identifier, displayName, callback)
	local recording = ChangeHistoryService:TryBeginRecording(identifier, displayName)
	if not recording then
		error("Studio is already recording another change; finish it and retry")
	end
	local ok, result = pcall(callback)
	ChangeHistoryService:FinishRecording(
		recording,
		ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
	)
	if not ok then
		error(result, 0)
	end
	return result
end

-- FIX: forward-declare so closures capture locals (Luau scoping)
local DEFAULT_PRESET_NAME
local DEFAULT_DISPLAY_NAME
-- forward-declared shared state для использования в startBurstLoop и других верхних функций
local currentEmitter
local previewEmitter
local currentState
local previewPlaying
local lastPreviewAnchorCFrame
local destroyPreview
local applyPreview
local bindPresetFolder

-- These references remain nil until a read-only inspection finds an existing
-- installation or the operator explicitly initializes the project.
local presetsFolder = nil

local Internal = script:WaitForChild("Internal")
local VoxelCubicBezier = require(Internal:WaitForChild("VoxelCubicBezier"))
local RuntimeInstaller = require(Internal:WaitForChild("RuntimeInstaller"))
local VPS = RuntimeInstaller.VPS


local PLUGIN_VERSION = 14
local EMITTER_NAME = "VoxelEmitter"
local PRESET_ATTRIBUTE = "VoxelPreset"
local DISPLAY_ATTRIBUTE = "VoxelPresetDisplay"

local MATERIALS = {
	Enum.Material.Neon,
	Enum.Material.SmoothPlastic,
	Enum.Material.Plastic,
	Enum.Material.Glass,
	Enum.Material.Sand,
	Enum.Material.Fabric,
}

local SHAPES = {
	"point",
	"cube",
	"sphere",
	"hemisphere",
	"disc",
	"ring",
	"annulus",
	"triangle",
	"square",
	"star5",
	"star7",
	"cubicBezier",
}

local SHAPE_DISPLAY_NAMES: {[string]: string} = {
	point = "Point",
	cube = "Cube",
	sphere = "Sphere",
	hemisphere = "Hemisphere",
	disc = "Disc",
	ring = "Ring",
	annulus = "Annulus",
	triangle = "Triangle",
	square = "Square",
	star5 = "Star (5-point)",
	star7 = "Star (7-point)",
	cubicBezier = "Cubic Bezier curve",
}

local DIRECTION_MODES = {
	"emission",
	"radialOutward",
	"radialTangent",
	"curveNormal",
}

local DIRECTION_MODE_DISPLAY_NAMES: {[string]: string} = {
	emission = "Emission axis",
	radialOutward = "Radial outward",
	radialTangent = "Radial tangent",
	curveNormal = "Curve normal",
}

local SAVE_COLOR = Color3.fromRGB(80, 170, 110)
local DISABLED_COLOR = Color3.fromRGB(60, 60, 70)
local STOP_COLOR = Color3.fromRGB(200, 90, 90)

-- Edit = превью работает, Play = отключаем превью (рантайм-биндер сам всё запустит)
local function isPlayMode()
	return RunService:IsRunning()
end


local function isEditMode()
	return not isPlayMode()
end

local refreshRunModeControls -- forward declaration

-- simple button factory used across the plugin
local function createButton(parent, text, onClick)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, 120, 1, 0)
	b.BackgroundColor3 = Color3.fromRGB(70, 120, 200)
	b.AutoButtonColor = true
	b.Font = Enum.Font.GothamBold
	b.TextSize = 14
	b.TextColor3 = Color3.fromRGB(255,255,255)
	b.Text = text
	b.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = b
	if onClick then b.MouseButton1Click:Connect(onClick) end
	return b
end

local function addCorner(parent, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius
	corner.Parent = parent
end

local function addListLayout(parent, fillDirection)
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = fillDirection
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = parent
end


local function deepCopy(value)
	if typeof(value) == "table" then
		local copy = {}
		for k, v in pairs(value) do
			copy[k] = deepCopy(v)
		end
		return copy
	end
	return value
end

local function mergeMissing(target, defaults)
	for key, defaultValue in pairs(defaults) do
		local current = target[key]
		if current == nil then
			target[key] = deepCopy(defaultValue)
		elseif typeof(current) == "table" and typeof(defaultValue) == "table" then
			mergeMissing(current, defaultValue)
		end
	end
end

local function mergeInto(target, overrides)
	for key, value in pairs(overrides) do
		if typeof(value) == "table" and typeof(target[key]) == "table" then
			mergeInto(target[key], value)
		else
			target[key] = deepCopy(value)
		end
	end
end

local function worldEmissionDirection(anchor: Instance?, localDir: Vector3): Vector3
	-- Теперь emissionDirection трактуется как ЛОКАЛЬНЫЙ вектор,
	-- а перевод в мир делает сама VoxelParticleSystem.
	if typeof(localDir) ~= "Vector3" then
		return Vector3.new(0, 1, 0)
	end
	return localDir
end


local function defaultState()
	return {
		enabled = true,
		seed = nil,
		_seedValue = 1,

		rate = 24,
		burstCount = 0,
		maxParticles = 128,
		emissionDirection = Vector3.new(0, 1, 0),
		spawnDirectionMode = "emission",

		spawnShape = "point",
		spawnSize = Vector3.new(0, 0, 0),
		spawnInnerRadius = 0,
		spawnSurfaceOnly = false,
		distanceSpeedFactor = 0,
		cubicBezierPoints = {
			Vector3.new(0, 0, 0),
			Vector3.new(0, 2, 0),
			Vector3.new(2, 4, 0),
			Vector3.new(2, 6, 0),
		},

		perParticle = {
			speed = {min = 6, max = 10},
			life = {min = 1.0, max = 1.8},
			angle = {min = 0, max = 25},
			size = {min = 0.4, max = 0.8},
			rotationX = {min = -45, max = 45},
			rotationY = {min = -120, max = 120},
			rotationZ = {min = -45, max = 45},
			turbulence = {min = 0, max = 0},
			returnForce = {min = 0, max = 0},
			steerYaw = {min = 0, max = 0},
			steerPitch = {min = 0, max = 0},
			steerRoll = {min = 0, max = 0},
			opacity = {min = 1, max = 1},
			color = {min = Color3.new(1, 1, 1), max = Color3.new(1, 1, 1)},
		},

		globalSpeedCurve = {1, 1, 1},
		perParticleCurves = {
			speed = {1, 1, 1},
			size = {1, 1, 1},
			rotationX = {1, 1, 1},
			rotationY = {1, 1, 1},
			rotationZ = {1, 1, 1},
			turbulence = {1, 1, 1},
			returnForce = {1, 1, 1},
			steerYaw = {1, 1, 1},
			steerPitch = {1, 1, 1},
			steerRoll = {1, 1, 1},
		},

		rateNoiseAmplitude = 0,
		rateNoiseFrequency = 0,
		rateNoiseSeed = nil,
		_rateNoiseSeedValue = 0,

		lifeNoiseAmplitude = 0,
		lifeNoiseFrequency = 0,
		lifeNoiseSeed = nil,
		_lifeNoiseSeedValue = 0,

		sizeNoiseAmplitude = 0,
		sizeNoiseFrequency = 0,
		sizeNoiseSeed = nil,
		_sizeNoiseSeedValue = 0,

		steerNoiseAmplitude = 0,
		steerNoiseFrequency = 0,
		steerNoiseSeed = nil,
		_steerNoiseSeedValue = 0,

		wind = Vector3.zero,
		acceleration = Vector3.new(0, 0, 0),
		accelerationDrag = 20,
		accelerationCurve = {start = 1, mid = 1, finish = 1},

		color = Color3.fromRGB(255, 255, 255),
		material = Enum.Material.Neon,
		colorCurve = {start = Color3.new(1,1,1), mid = Color3.new(1,1,1), finish = Color3.new(1,1,1)},
		opacityCurve = {start = 1, mid = 1, finish = 1},
		targetFps = 60,
		visualUpdateStep = 1,
		sizeUpdateStep = 1,

		cullOutsideFov = false,
		lodNear = 0,
		lodFar = 0,

		turbulenceAntiJitter = false,
		localSpace = false,
		faceMovement = false,
	}
end

local function ensureStateIntegrity(state)
	mergeMissing(state, defaultState())
	state.distanceSpeedFactor = math.clamp(tonumber(state.distanceSpeedFactor) or 0, -10, 10)
	state.spawnInnerRadius = math.max(0, tonumber(state.spawnInnerRadius) or 0)
	state.accelerationDrag = math.clamp(tonumber(state.accelerationDrag) or 20, 0, 100)
	if state.seed ~= nil then
		state._seedValue = state.seed
	end
	if state.rateNoiseSeed ~= nil then
		state._rateNoiseSeedValue = state.rateNoiseSeed
	end
	if state.lifeNoiseSeed ~= nil then
		state._lifeNoiseSeedValue = state.lifeNoiseSeed
	end
	if state.sizeNoiseSeed ~= nil then
		state._sizeNoiseSeedValue = state.sizeNoiseSeed
	end
	if state.steerNoiseSeed ~= nil then
		state._steerNoiseSeedValue = state.steerNoiseSeed
	end
	state.burstCount = math.max(0, math.floor(tonumber(state.burstCount) or 0))
	-- NEW: 30 или 60, любые другие значения приводим к 60
	state.targetFps = (tonumber(state.targetFps) == 30) and 30 or 60

end

local function validateSpawnState(state)
	local directionMode = state.spawnDirectionMode
	assert(
		directionMode == "emission"
			or directionMode == "radialOutward"
			or directionMode == "radialTangent"
			or directionMode == "curveNormal",
		"Spawn direction mode must be Emission axis, Radial outward, Radial tangent, or Curve normal"
	)
	assert(typeof(state.spawnSize) == "Vector3", "Spawn size must be a Vector3")
	local innerRadius = tonumber(state.spawnInnerRadius)
	assert(
		innerRadius and innerRadius == innerRadius and innerRadius >= 0 and innerRadius < math.huge,
		"Annulus inner radius must be finite and non-negative"
	)
	if state.spawnShape == "annulus" then
		local outerX = math.abs(state.spawnSize.X)
		local outerZ = math.abs(state.spawnSize.Z)
		assert(
			outerX > 0 and outerX < math.huge and math.abs(outerX - outerZ) <= 1e-4 and innerRadius < outerX,
			"Annulus requires equal positive Spawn size X/Z and an inner radius smaller than them"
		)
	elseif state.spawnShape == "cubicBezier" then
		local points = state.cubicBezierPoints
		assert(typeof(points) == "table" and #points == 4, "Cubic Bezier requires exactly four control points")
		for index = 1, 4 do
			assert(typeof(points[index]) == "Vector3", ("Cubic Bezier point %d must be a Vector3"):format(index - 1))
		end
		VoxelCubicBezier.Build(points[1], points[2], points[3], points[4])
	elseif state.spawnShape == "cylinderStream" then
		assert(directionMode == "emission", "Cylinder stream requires Emission axis direction mode")
	end
	if directionMode == "curveNormal" then
		assert(state.spawnShape == "cubicBezier", "Curve normal direction mode requires Cubic Bezier spawn shape")
	end
end

local function buildConfig(state)
	validateSpawnState(state)
	local cfg = {
		rate = state.rate,
		burstCount = state.burstCount,
		maxParticles = state.maxParticles,
		emissionDirection = state.emissionDirection,
		spawnDirectionMode = state.spawnDirectionMode,

		spawnShape = state.spawnShape,
		spawnSize = state.spawnSize,
		spawnInnerRadius = state.spawnInnerRadius,
		spawnSurfaceOnly = state.spawnSurfaceOnly,
		distanceSpeedFactor = state.distanceSpeedFactor,
		cubicBezierPoints = deepCopy(state.cubicBezierPoints),

		perParticle = deepCopy(state.perParticle),
		perParticleCurves = deepCopy(state.perParticleCurves),
		globalSpeedCurve = deepCopy(state.globalSpeedCurve),

		rateNoiseAmplitude = state.rateNoiseAmplitude,
		rateNoiseFrequency = state.rateNoiseFrequency,
		rateNoiseSeed = state.rateNoiseSeed,

		lifeNoiseAmplitude = state.lifeNoiseAmplitude,
		lifeNoiseFrequency = state.lifeNoiseFrequency,
		lifeNoiseSeed = state.lifeNoiseSeed,

		sizeNoiseAmplitude = state.sizeNoiseAmplitude,
		sizeNoiseFrequency = state.sizeNoiseFrequency,
		sizeNoiseSeed = state.sizeNoiseSeed,

		steerNoiseAmplitude = state.steerNoiseAmplitude,
		steerNoiseFrequency = state.steerNoiseFrequency,
		steerNoiseSeed = state.steerNoiseSeed,

		wind = state.wind,
		acceleration = state.acceleration,
		accelerationDrag = state.accelerationDrag,
		accelerationCurve = deepCopy(state.accelerationCurve),

		color = state.color,
		material = state.material,
		colorCurve = deepCopy(state.colorCurve),
		opacityCurve = deepCopy(state.opacityCurve),

		targetFps = state.targetFps,
		visualUpdateStep = state.visualUpdateStep,
		sizeUpdateStep = state.sizeUpdateStep,


		cullOutsideFov = state.cullOutsideFov,
		lodNear = state.lodNear,
		lodFar = state.lodFar,

		turbulenceAntiJitter = state.turbulenceAntiJitter,
		localSpace = state.localSpace,
		faceMovement = state.faceMovement,
	}

	if state.seed ~= nil then
		cfg.seed = state.seed
	end

	if state.perParticle.color then
		cfg.perParticle.color = {
			min = state.perParticle.color.min,
			max = state.perParticle.color.max,
		}
	end

	if state.rate ~= 0 then
		cfg.burstCount = nil
	end

	return cfg
end


local toggleButton = plugin:CreateToolbar("Voxel Particles"):CreateButton(
	"VoxelParticlesToggle",
	("Open the voxel particle editor v%d"):format(PLUGIN_VERSION),
	"",
	("Voxel Particles v%d"):format(PLUGIN_VERSION)
)
toggleButton.ClickableWhenViewportHidden = true


local widget = plugin:CreateDockWidgetPluginGuiAsync(
	"VoxelParticleEditor",
	DockWidgetPluginGuiInfo.new(
		Enum.InitialDockState.Float,
		false,
		false,
		520,
		780,
		380,
		520
	)
)
local BASE_TITLE = ("Voxel Particles v%d"):format(PLUGIN_VERSION)
widget.Title = BASE_TITLE
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local savedWidgetEnabled = plugin:GetSetting("VoxelParticles_WidgetEnabled")
if typeof(savedWidgetEnabled) ~= "boolean" then
	savedWidgetEnabled = false
end

widget.Enabled = savedWidgetEnabled


local root = Instance.new("Frame")
root.Name = "Root"
root.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
root.BorderSizePixel = 0
root.Size = UDim2.fromScale(1, 1)
root.Parent = widget

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 8)
padding.PaddingBottom = UDim.new(0, 8)
padding.PaddingLeft = UDim.new(0, 12)
padding.PaddingRight = UDim.new(0, 12)
padding.Parent = root

local header = Instance.new("Frame")
header.Name = "Header"
header.BackgroundTransparency = 1
header.AutomaticSize = Enum.AutomaticSize.Y
header.Size = UDim2.new(1, 0, 0, 120)
header.Parent = root

addListLayout(header, Enum.FillDirection.Vertical)

local playbackRow = Instance.new("Frame")
playbackRow.Name = "PlaybackRow"
playbackRow.Size = UDim2.new(1, 0, 0, 28)
playbackRow.BackgroundTransparency = 1
playbackRow.Parent = header
-- [BurstUI] горизонтальный лэйаут для кнопок Play/Stop и Burst
addListLayout(playbackRow, Enum.FillDirection.Horizontal)

local playbackButton = Instance.new("TextButton")
playbackButton.Name = "PlaybackButton"
playbackButton.Size = UDim2.new(0, 120, 1, 0)
playbackButton.BackgroundColor3 = STOP_COLOR
playbackButton.TextColor3 = Color3.fromRGB(255, 255, 255)
playbackButton.Font = Enum.Font.GothamBold
playbackButton.TextSize = 14
playbackButton.Text = "Stop"
playbackButton.AutoButtonColor = true
playbackButton.Parent = playbackRow
-- [BurstUI] параметры и состояние burst-цикла
local burstLoopActive = false
local burstButton = Instance.new("TextButton")
burstButton.Name = "BurstButton"
burstButton.Size = UDim2.new(0, 120, 1, 0)
burstButton.BackgroundColor3 = Color3.fromRGB(90, 140, 255)
burstButton.TextColor3 = Color3.fromRGB(255, 255, 255)
burstButton.Font = Enum.Font.GothamBold
burstButton.TextSize = 14
burstButton.Text = "Burst 1.0s: OFF"
burstButton.AutoButtonColor = true
burstButton.Parent = playbackRow
addCorner(burstButton, UDim.new(0, 6))
local statusLabel = Instance.new("TextLabel")
local function updateBurstButton()
	burstButton.Text = burstLoopActive and "Burst 1.0s: ON" or "Burst 1.0s: OFF"
	burstButton.BackgroundColor3 = burstLoopActive and SAVE_COLOR or Color3.fromRGB(90, 140, 255)
end

local function stopBurstLoop()
	burstLoopActive = false
	updateBurstButton()
end

local function startBurstLoop()
	if burstLoopActive then return end
	burstLoopActive = true
	updateBurstButton()
	task.spawn(function()
		while burstLoopActive do
			-- работаем ТОЛЬКО в редакторе, при активном превью и валидном превью-эмиттере
			if not isPlayMode() and previewPlaying and previewEmitter and currentEmitter and currentEmitter.Parent then
				local count = math.max(1, currentState.burstCount or 0)
				-- чисто UI-спавн: никакой логики в системе не меняем
				pcall(function() previewEmitter:Emit(count) end)
			end
			task.wait(1.0)
		end
	end)
end


addCorner(playbackButton, UDim.new(0, 6))

previewPlaying = true


local function updatePlaybackButton()
	if not playbackButton then
		return
	end
	playbackButton.Text = previewPlaying and "Stop" or "Play"
	if playbackButton.Active then
		playbackButton.BackgroundColor3 = previewPlaying and STOP_COLOR or SAVE_COLOR
	else
		playbackButton.BackgroundColor3 = DISABLED_COLOR
	end
end
burstButton.MouseButton1Click:Connect(function()
	if isPlayMode() then
		statusLabel.Text = "Play mode: preview controls are disabled."
		return
	end
	if not previewPlaying then
		-- если превью выключено — сначала включим его
		previewPlaying = true
		destroyPreview()
		applyPreview()
		updatePlaybackButton()
	end
	if burstLoopActive then
		stopBurstLoop()
	else
		startBurstLoop()
	end
end)

local emitterInfoLabel = Instance.new("TextLabel")
emitterInfoLabel.Name = "EmitterInfo"
emitterInfoLabel.Size = UDim2.new(1, 0, 0, 20)
emitterInfoLabel.BackgroundTransparency = 1
emitterInfoLabel.Font = Enum.Font.Gotham
emitterInfoLabel.TextSize = 14
emitterInfoLabel.TextColor3 = Color3.fromRGB(220, 220, 230)
emitterInfoLabel.TextXAlignment = Enum.TextXAlignment.Left
emitterInfoLabel.Text = "Emitter: <none>"
emitterInfoLabel.Parent = header

local positionLabel = Instance.new("TextLabel")
positionLabel.Size = UDim2.new(1, 0, 0, 20)
positionLabel.BackgroundTransparency = 1
positionLabel.Font = Enum.Font.Gotham
positionLabel.TextSize = 14
positionLabel.TextColor3 = Color3.fromRGB(180, 180, 190)
positionLabel.TextXAlignment = Enum.TextXAlignment.Left
positionLabel.Text = "World CFrame: n/a"
positionLabel.Parent = header

local displayRow = Instance.new("Frame")
displayRow.Size = UDim2.new(1, 0, 0, 28)
displayRow.BackgroundTransparency = 1
displayRow.Parent = header
displayRow.Visible = false

local displayLabel = Instance.new("TextLabel")
displayLabel.Size = UDim2.new(0, 120, 1, 0)
displayLabel.BackgroundTransparency = 1
displayLabel.Font = Enum.Font.Gotham
displayLabel.TextSize = 14
displayLabel.TextXAlignment = Enum.TextXAlignment.Left
displayLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
displayLabel.Text = "Display name"
displayLabel.Parent = displayRow

local displayNameBox = Instance.new("TextBox")
displayNameBox.Size = UDim2.new(1, -124, 1, 0)
displayNameBox.Position = UDim2.new(0, 124, 0, 0)
displayNameBox.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
displayNameBox.BorderSizePixel = 0
displayNameBox.ClearTextOnFocus = false
displayNameBox.Font = Enum.Font.Gotham
displayNameBox.PlaceholderText = "Shown in runtime UI"
displayNameBox.Text = ""
displayNameBox.TextSize = 14
displayNameBox.TextColor3 = Color3.fromRGB(235, 235, 240)
displayNameBox.TextXAlignment = Enum.TextXAlignment.Left
displayNameBox.Parent = displayRow

addCorner(displayNameBox, UDim.new(0, 6))

local presetRow = Instance.new("Frame")
presetRow.Size = UDim2.new(1, 0, 0, 28)
presetRow.BackgroundTransparency = 1
presetRow.Parent = header
presetRow.Visible = false


local presetLabel = Instance.new("TextLabel")
presetLabel.Size = UDim2.new(0, 120, 1, 0)
presetLabel.BackgroundTransparency = 1
presetLabel.Font = Enum.Font.Gotham
presetLabel.TextSize = 14
presetLabel.TextXAlignment = Enum.TextXAlignment.Left
presetLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
presetLabel.Text = "Preset name"
presetLabel.Parent = presetRow

local presetNameBox = Instance.new("TextBox")
presetNameBox.Size = UDim2.new(1, -124, 1, 0)
presetNameBox.Position = UDim2.new(0, 124, 0, 0)
presetNameBox.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
presetNameBox.BorderSizePixel = 0
presetNameBox.ClearTextOnFocus = false
presetNameBox.Font = Enum.Font.Gotham
presetNameBox.PlaceholderText = "ModuleScript name"
presetNameBox.Text = ""
presetNameBox.TextSize = 14
presetNameBox.TextColor3 = Color3.fromRGB(235, 235, 240)
presetNameBox.TextXAlignment = Enum.TextXAlignment.Left
presetNameBox.Parent = presetRow

addCorner(presetNameBox, UDim.new(0, 6))

local presetSelector = Instance.new("Frame")
presetSelector.Name = "PresetSelector"
presetSelector.Size = UDim2.new(1, 0, 0, 32)
presetSelector.BackgroundTransparency = 1
presetSelector.ClipsDescendants = false
presetSelector.ZIndex = 200
presetSelector.Parent = header

addListLayout(presetSelector, Enum.FillDirection.Horizontal)

local presetDropdown = Instance.new("TextButton")
presetDropdown.Name = "PresetDropdown"
presetDropdown.Size = UDim2.new(1, -200, 1, 0)
presetDropdown.BackgroundColor3 = Color3.fromRGB(40, 40, 46)
presetDropdown.BorderSizePixel = 0
presetDropdown.Text = "Select existing preset"
presetDropdown.TextColor3 = Color3.fromRGB(230, 230, 235)
presetDropdown.TextSize = 14
presetDropdown.Font = Enum.Font.Gotham
presetDropdown.TextXAlignment = Enum.TextXAlignment.Left
presetDropdown.AutoButtonColor = false
presetDropdown.ZIndex = presetSelector.ZIndex + 1
presetDropdown.Parent = presetSelector

addCorner(presetDropdown, UDim.new(0, 6))

local dropdownIcon = Instance.new("TextLabel")
dropdownIcon.AnchorPoint = Vector2.new(1, 0.5)
dropdownIcon.Position = UDim2.new(1, -8, 0.5, 0)
dropdownIcon.Size = UDim2.new(0, 18, 0, 18)
dropdownIcon.BackgroundTransparency = 1
dropdownIcon.Font = Enum.Font.GothamBold
dropdownIcon.TextSize = 18
dropdownIcon.TextColor3 = Color3.fromRGB(200, 200, 210)
dropdownIcon.Text = "v"
dropdownIcon.ZIndex = presetDropdown.ZIndex + 1
dropdownIcon.Parent = presetDropdown




statusLabel.Size = UDim2.new(1, 0, 0, 20)
statusLabel.AutomaticSize = Enum.AutomaticSize.Y
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 13
statusLabel.TextColor3 = Color3.fromRGB(170, 170, 180)
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextWrapped = true
statusLabel.Text = "Select a part named VoxelEmitter to begin."
statusLabel.Parent = header

local runtimeRoleLabel = Instance.new("TextLabel")
runtimeRoleLabel.Name = "RuntimeRoles"
runtimeRoleLabel.Size = UDim2.new(1, 0, 0, 34)
runtimeRoleLabel.AutomaticSize = Enum.AutomaticSize.Y
runtimeRoleLabel.BackgroundTransparency = 1
runtimeRoleLabel.Font = Enum.Font.Gotham
runtimeRoleLabel.TextSize = 11
runtimeRoleLabel.TextColor3 = Color3.fromRGB(145, 150, 165)
runtimeRoleLabel.TextWrapped = true
runtimeRoleLabel.TextXAlignment = Enum.TextXAlignment.Left
runtimeRoleLabel.TextYAlignment = Enum.TextYAlignment.Top
runtimeRoleLabel.Text = "Source template (inert ModuleScript): Plugin/Internal/VoxelEmitterBinderTemplate\nInstalled runtime (enabled LocalScript): StarterPlayerScripts/VoxelEmitterBinder"
runtimeRoleLabel.LayoutOrder = 80
runtimeRoleLabel.Parent = header

local initializeProjectBtn = Instance.new("TextButton")
initializeProjectBtn.Name = "InitializeProjectButton"
initializeProjectBtn.Size = UDim2.new(1, 0, 0, 32)
initializeProjectBtn.BackgroundColor3 = Color3.fromRGB(90, 140, 255)
initializeProjectBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
initializeProjectBtn.Font = Enum.Font.GothamBold
initializeProjectBtn.TextSize = 14
initializeProjectBtn.Text = "Inspecting runtime..."
initializeProjectBtn.AutoButtonColor = false
initializeProjectBtn.LayoutOrder = 90
initializeProjectBtn.Parent = header

addCorner(initializeProjectBtn, UDim.new(0, 6))

-- Actions row inside header
local actionsRow = Instance.new("Frame")
actionsRow.Size = UDim2.new(1, 0, 0, 32)
actionsRow.BackgroundTransparency = 1
actionsRow.LayoutOrder = 100
actionsRow.Parent = header

addListLayout(actionsRow, Enum.FillDirection.Horizontal)

local createEmitterBtn = Instance.new("TextButton")
createEmitterBtn.Size = UDim2.new(0, 140, 1, 0)
createEmitterBtn.BackgroundColor3 = Color3.fromRGB(90, 140, 255)
createEmitterBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
createEmitterBtn.Font = Enum.Font.GothamBold
createEmitterBtn.TextSize = 14
createEmitterBtn.Text = "Create emitter"
createEmitterBtn.AutoButtonColor = true
createEmitterBtn.Parent = actionsRow

addCorner(createEmitterBtn, UDim.new(0, 6))

local createEmitterAtCenter
local runtimePrepared = false
local currentRuntimeStatus = nil

local function applyRuntimeInspection(status)
	currentRuntimeStatus = status
	runtimePrepared = status.ready == true
	presetsFolder = status.presetsFolder
	local roleText = "Source template (inert ModuleScript): Plugin/Internal/VoxelEmitterBinderTemplate\nInstalled runtime (enabled LocalScript): StarterPlayerScripts/VoxelEmitterBinder"
	if #status.duplicatePaths > 0 then
		roleText ..= "\nDuplicates: " .. table.concat(status.duplicatePaths, ", ")
	elseif status.blocked and #status.conflicts > 0 then
		roleText ..= "\nConflict: " .. status.conflicts[1]
	end
	runtimeRoleLabel.Text = roleText
	initializeProjectBtn.Text = status.action
	initializeProjectBtn.Active = not runtimePrepared
	initializeProjectBtn.Selectable = not runtimePrepared
	initializeProjectBtn.AutoButtonColor = not runtimePrepared
	if status.blocked then
		initializeProjectBtn.BackgroundColor3 = Color3.fromRGB(190, 75, 75)
	elseif runtimePrepared then
		initializeProjectBtn.BackgroundColor3 = SAVE_COLOR
	else
		initializeProjectBtn.BackgroundColor3 = Color3.fromRGB(90, 140, 255)
	end
	if bindPresetFolder then
		bindPresetFolder(presetsFolder)
	end
	return runtimePrepared
end

local function refreshRuntimeInspection()
	local ok, statusOrError = pcall(RuntimeInstaller.inspectRuntime)
	if not ok then
		runtimePrepared = false
		currentRuntimeStatus = nil
		presetsFolder = nil
		initializeProjectBtn.Text = "Inspection failed"
		initializeProjectBtn.Active = true
		initializeProjectBtn.Selectable = true
		initializeProjectBtn.BackgroundColor3 = Color3.fromRGB(190, 75, 75)
		statusLabel.Text = "Runtime inspection failed: " .. tostring(statusOrError)
		return false
	end
	applyRuntimeInspection(statusOrError)
	statusLabel.Text = statusOrError.message
	return runtimePrepared
end

initializeProjectBtn.MouseButton1Click:Connect(function()
	if isPlayMode() then
		statusLabel.Text = "Stop Play mode before initializing the project runtime."
		return
	end
	if runtimePrepared then
		return
	end
	if currentRuntimeStatus and currentRuntimeStatus.blocked then
		refreshRuntimeInspection()
		if currentRuntimeStatus and currentRuntimeStatus.blocked then
			statusLabel.Text = currentRuntimeStatus.message
			return
		end
	end
	initializeProjectBtn.Text = "Initializing..."
	initializeProjectBtn.Active = false
	local ok, statusOrError = pcall(RuntimeInstaller.initializeRuntime)
	if not ok then
		warn("[VoxelParticlesPlugin] Runtime initialization failed: ", statusOrError)
		statusLabel.Text = "Initialization failed: " .. tostring(statusOrError)
		refreshRuntimeInspection()
		return
	end
	applyRuntimeInspection(statusOrError)
	statusLabel.Text = "Runtime ready at StarterPlayerScripts.VoxelEmitterBinder"
end)

createEmitterBtn.MouseButton1Click:Connect(function()
	if not runtimePrepared then
		statusLabel.Text = "Initialize or update the project runtime first."
		return
	end
	createEmitterAtCenter()
end)

playbackButton.MouseButton1Click:Connect(function()
	if isPlayMode() then
		statusLabel.Text = "Play mode: preview controls are disabled."
		return
	end
	if previewPlaying then
		previewPlaying = false
		-- Отключая превью — гасим и burst-цикл
		if burstLoopActive then
			burstLoopActive = false
			updateBurstButton()
		end
		destroyPreview()
	else
		previewPlaying = true
		destroyPreview()
		applyPreview()
	end
	updatePlaybackButton()
end)



local dropdownOverlay = Instance.new("Frame")
dropdownOverlay.Name = "PresetDropdownOverlay"
dropdownOverlay.Visible = false
dropdownOverlay.BackgroundColor3 = Color3.fromRGB(26, 26, 32)
dropdownOverlay.BorderSizePixel = 0
dropdownOverlay.AnchorPoint = Vector2.new(0, 0)
dropdownOverlay.ZIndex = 500
dropdownOverlay.Active = true
dropdownOverlay.ClipsDescendants = true
dropdownOverlay.Size = UDim2.fromOffset(0, 0)
dropdownOverlay.Position = UDim2.fromOffset(0, 0)
dropdownOverlay.Parent = root

addCorner(dropdownOverlay, UDim.new(0, 6))

local dropdownScroll = Instance.new("ScrollingFrame")
dropdownScroll.Name = "DropdownScroll"
dropdownScroll.Size = UDim2.new(1, 0, 1, 0)
dropdownScroll.BackgroundTransparency = 1
dropdownScroll.BorderSizePixel = 0
dropdownScroll.CanvasSize = UDim2.new()
dropdownScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
dropdownScroll.ScrollBarThickness = 6
dropdownScroll.ScrollingDirection = Enum.ScrollingDirection.Y
dropdownScroll.ZIndex = dropdownOverlay.ZIndex + 1
dropdownScroll.Active = true
dropdownScroll.Parent = dropdownOverlay

local dropdownPadding = Instance.new("UIPadding")
dropdownPadding.PaddingTop = UDim.new(0, 6)
dropdownPadding.PaddingBottom = UDim.new(0, 6)
dropdownPadding.PaddingLeft = UDim.new(0, 6)
dropdownPadding.PaddingRight = UDim.new(0, 6)
dropdownPadding.Parent = dropdownScroll

local dropdownList = Instance.new("UIListLayout")
dropdownList.FillDirection = Enum.FillDirection.Vertical
dropdownList.Padding = UDim.new(0, 2)
dropdownList.Parent = dropdownScroll

local dropdownOverlayHeight = 0

local function applyDropdownTransform()
	local buttonPos = presetDropdown.AbsolutePosition
	local buttonSize = presetDropdown.AbsoluteSize
	local rootPos = root.AbsolutePosition
	local offsetX = buttonPos.X - rootPos.X
	local offsetY = buttonPos.Y - rootPos.Y + buttonSize.Y + 4
	dropdownOverlay.Position = UDim2.fromOffset(offsetX, offsetY)
	dropdownOverlay.Size = UDim2.fromOffset(buttonSize.X, dropdownOverlayHeight)
end

local function updateDropdownOverlaySize()
	local paddingHeight = dropdownPadding.PaddingTop.Offset + dropdownPadding.PaddingBottom.Offset
	local contentHeight = dropdownList.AbsoluteContentSize.Y + paddingHeight
	local clampedHeight = math.clamp(contentHeight, 0, 220)
	dropdownOverlayHeight = clampedHeight
	dropdownScroll.CanvasSize = UDim2.new(0, 0, 0, contentHeight)
	applyDropdownTransform()
end

dropdownList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateDropdownOverlaySize)
task.defer(updateDropdownOverlaySize)

presetDropdown:GetPropertyChangedSignal("AbsolutePosition"):Connect(applyDropdownTransform)
presetDropdown:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyDropdownTransform)
widget:GetPropertyChangedSignal("AbsolutePosition"):Connect(applyDropdownTransform)
widget:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyDropdownTransform)

local scroll = Instance.new("ScrollingFrame")
scroll.Name = "Scroll"
scroll.Position = UDim2.new(0, 0, 0, 0)
scroll.Size = UDim2.new(1, 0, 1, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.new()
scroll.ScrollBarThickness = 6
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.Parent = root

local scrollLayout = Instance.new("UIListLayout")
scrollLayout.Padding = UDim.new(0, 10)
scrollLayout.FillDirection = Enum.FillDirection.Vertical
scrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
scrollLayout.Parent = scroll

local function updateScrollLayout()
	local headerHeight = header.AbsoluteSize.Y
	local offset = headerHeight + 8
	scroll.Position = UDim2.new(0, 0, 0, offset)
	scroll.Size = UDim2.new(1, 0, 1, -offset)
end

header:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateScrollLayout)
widget:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateScrollLayout)
task.defer(updateScrollLayout)

local colorPickerOverlay = Instance.new("Frame")
colorPickerOverlay.Visible = false
colorPickerOverlay.Size = UDim2.new(1, 0, 1, 0)
colorPickerOverlay.BackgroundTransparency = 1
colorPickerOverlay.InputSink = Enum.InputSink.All
colorPickerOverlay.ZIndex = 100
colorPickerOverlay.Parent = widget
-- Modal overlay to block clicks behind name prompt / future dialogs
local modalOverlay = Instance.new("TextButton")
modalOverlay.Visible = false
modalOverlay.AutoButtonColor = false
modalOverlay.Text = ""
modalOverlay.BackgroundColor3 = Color3.fromRGB(0,0,0)
modalOverlay.BackgroundTransparency = 0.35
modalOverlay.BorderSizePixel = 0
modalOverlay.Size = UDim2.fromScale(1,1)
modalOverlay.ZIndex = 199
modalOverlay.Parent = widget


-- === Name prompt overlay for creating a new preset ===
local namePrompt = Instance.new("Frame")
namePrompt.Visible = false
namePrompt.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
namePrompt.BorderSizePixel = 0
namePrompt.Position = UDim2.fromScale(0.5, 0.5)
namePrompt.AnchorPoint = Vector2.new(0.5, 0.5)
namePrompt.Size = UDim2.new(1, -40, 0, 120)
namePrompt.ZIndex = 200
namePrompt.Parent = widget


local namePromptTitle = Instance.new("TextLabel")
namePromptTitle.BackgroundTransparency = 1
namePromptTitle.Font = Enum.Font.Gotham
namePromptTitle.TextSize = 16
namePromptTitle.Text = "New preset name"
namePromptTitle.TextColor3 = Color3.fromRGB(230,230,235)
namePromptTitle.Size = UDim2.new(1, -16, 0, 24)
namePromptTitle.Position = UDim2.new(0, 8, 0, 8)
namePromptTitle.Parent = namePrompt

local nameInput = Instance.new("TextBox")
nameInput.Size = UDim2.new(1, -16, 0, 28)
nameInput.Position = UDim2.new(0, 8, 0, 44)
nameInput.BackgroundColor3 = Color3.fromRGB(30,30,36)
nameInput.BorderSizePixel = 0
nameInput.ClearTextOnFocus = false
nameInput.Font = Enum.Font.Gotham
nameInput.TextSize = 14
nameInput.TextColor3 = Color3.fromRGB(235,235,240)
nameInput.PlaceholderText = "MyPreset"
nameInput.Parent = namePrompt
addCorner(nameInput, UDim.new(0, 6))

local btnRow = Instance.new("Frame")
btnRow.BackgroundTransparency = 1
btnRow.Size = UDim2.new(1, -16, 0, 28)
btnRow.Position = UDim2.new(0, 8, 0, 80)
btnRow.Parent = namePrompt

local createBtn = createButton(btnRow, "Create", function() end)
createBtn.Position = UDim2.new(1, -160, 0, 0)
createBtn.Size = UDim2.new(0, 72, 1, 0)
createBtn.Parent = btnRow

local cancelBtn = createButton(btnRow, "Cancel", function() end)
cancelBtn.Position = UDim2.new(1, -80, 0, 0)
cancelBtn.Size = UDim2.new(0, 72, 1, 0)
cancelBtn.Parent = btnRow

local _namePromptCallback
local function namePromptOpen(onConfirm)
	_namePromptCallback = onConfirm
	nameInput.Text = ""
	namePrompt.Visible = true
	modalOverlay.Visible = true

	nameInput:CaptureFocus()
end
local function namePromptClose()
	namePrompt.Visible = false
	modalOverlay.Visible = false

	_namePromptCallback = nil
end
createBtn.MouseButton1Click:Connect(function()
	local cb = _namePromptCallback
	namePromptClose()
	if cb then cb((nameInput.Text or ""):gsub("^%s*(.-)%s*$", "%1")) end
end)
cancelBtn.MouseButton1Click:Connect(namePromptClose)
nameInput.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		local cb = _namePromptCallback
		namePromptClose()
		if cb then cb((nameInput.Text or ""):gsub("^%s*(.-)%s*$", "%1")) end
	end
end)


local colorPickerBackground = Instance.new("Frame")
colorPickerBackground.AnchorPoint = Vector2.new(0.5, 0.5)
colorPickerBackground.Position = UDim2.new(0.5, 0, 0.5, 0)
colorPickerBackground.Size = UDim2.new(0, 280, 0, 300)
colorPickerBackground.BackgroundColor3 = Color3.fromRGB(26, 26, 32)
colorPickerBackground.BorderSizePixel = 0
colorPickerBackground.ZIndex = 101
colorPickerBackground.Parent = colorPickerOverlay

addCorner(colorPickerBackground, UDim.new(0, 8))

local colorPickerTitle = Instance.new("TextLabel")
colorPickerTitle.Size = UDim2.new(1, -40, 0, 30)
colorPickerTitle.Position = UDim2.new(0, 16, 0, 8)
colorPickerTitle.BackgroundTransparency = 1
colorPickerTitle.Font = Enum.Font.GothamBold
colorPickerTitle.TextSize = 16
colorPickerTitle.TextXAlignment = Enum.TextXAlignment.Left
colorPickerTitle.TextColor3 = Color3.fromRGB(235, 235, 240)
colorPickerTitle.Text = "Pick color"
colorPickerTitle.ZIndex = 101
colorPickerTitle.Parent = colorPickerBackground

local colorPickerClose = Instance.new("TextButton")
colorPickerClose.AnchorPoint = Vector2.new(1, 0)
colorPickerClose.Position = UDim2.new(1, -10, 0, 6)
colorPickerClose.Size = UDim2.new(0, 24, 0, 24)
colorPickerClose.BackgroundTransparency = 1
colorPickerClose.BorderSizePixel = 0
colorPickerClose.Text = "✕"
colorPickerClose.Font = Enum.Font.GothamBold
colorPickerClose.TextSize = 16
colorPickerClose.TextColor3 = Color3.fromRGB(200, 200, 210)
colorPickerClose.ZIndex = 101
colorPickerClose.Parent = colorPickerBackground

local paletteFrame = Instance.new("Frame")
paletteFrame.Position = UDim2.new(0, 16, 0, 48)
paletteFrame.Size = UDim2.new(0, 210, 0, 160)
paletteFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
paletteFrame.BorderSizePixel = 0
paletteFrame.ZIndex = 101
paletteFrame.Parent = colorPickerBackground

addCorner(paletteFrame, UDim.new(0, 6))

local paletteGradient = Instance.new("UIGradient")
paletteGradient.Rotation = 90
paletteGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
	ColorSequenceKeypoint.new(1, Color3.new(0, 0, 0)),
})

paletteGradient.Parent = paletteFrame

local hueOverlay = Instance.new("Frame")
hueOverlay.Size = UDim2.new(0, 210, 0, 160)
hueOverlay.Position = UDim2.new(0, 0, 0, 0)
hueOverlay.BackgroundTransparency = 1
hueOverlay.ZIndex = 102
hueOverlay.Parent = paletteFrame

local hueGradient = Instance.new("UIGradient")
hueGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0.0, Color3.fromHSV(0, 1, 1)),
	ColorSequenceKeypoint.new(0.17, Color3.fromHSV(0.17, 1, 1)),
	ColorSequenceKeypoint.new(0.33, Color3.fromHSV(0.33, 1, 1)),
	ColorSequenceKeypoint.new(0.5, Color3.fromHSV(0.5, 1, 1)),
	ColorSequenceKeypoint.new(0.67, Color3.fromHSV(0.67, 1, 1)),
	ColorSequenceKeypoint.new(0.83, Color3.fromHSV(0.83, 1, 1)),
	ColorSequenceKeypoint.new(1.0, Color3.fromHSV(1.0, 1, 1)),
})

hueGradient.Rotation = 0
hueGradient.Parent = hueOverlay

local paletteIndicator = Instance.new("Frame")
paletteIndicator.Size = UDim2.new(0, 12, 0, 12)
paletteIndicator.AnchorPoint = Vector2.new(0.5, 0.5)
paletteIndicator.Position = UDim2.new(0.5, 0, 0.5, 0)
paletteIndicator.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
paletteIndicator.BorderSizePixel = 0
paletteIndicator.ZIndex = 103
paletteIndicator.Parent = paletteFrame

addCorner(paletteIndicator, UDim.new(1, 0))

local paletteIndicatorStroke = Instance.new("UIStroke")
paletteIndicatorStroke.Color = Color3.fromRGB(0, 0, 0)
paletteIndicatorStroke.Thickness = 2
paletteIndicatorStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
paletteIndicatorStroke.Parent = paletteIndicator

local hueSlider = Instance.new("Frame")
hueSlider.Position = UDim2.new(0, 236, 0, 48)
hueSlider.Size = UDim2.new(0, 20, 0, 160)
hueSlider.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
hueSlider.BorderSizePixel = 0
hueSlider.ZIndex = 101
hueSlider.Parent = colorPickerBackground

addCorner(hueSlider, UDim.new(0, 6))

local hueGradient2 = Instance.new("UIGradient")
hueGradient2.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0.0, Color3.fromHSV(0, 1, 1)),
	ColorSequenceKeypoint.new(0.17, Color3.fromHSV(0.17, 1, 1)),
	ColorSequenceKeypoint.new(0.33, Color3.fromHSV(0.33, 1, 1)),
	ColorSequenceKeypoint.new(0.5, Color3.fromHSV(0.5, 1, 1)),
	ColorSequenceKeypoint.new(0.67, Color3.fromHSV(0.67, 1, 1)),
	ColorSequenceKeypoint.new(0.83, Color3.fromHSV(0.83, 1, 1)),
	ColorSequenceKeypoint.new(1.0, Color3.fromHSV(1.0, 1, 1)),
})

hueGradient2.Rotation = 90
hueGradient2.Parent = hueSlider

local hueIndicator = Instance.new("Frame")
hueIndicator.Size = UDim2.new(1, 0, 0, 4)
hueIndicator.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
hueIndicator.AnchorPoint = Vector2.new(0, 0.5)
hueIndicator.BorderSizePixel = 0
hueIndicator.ZIndex = 102
hueIndicator.Parent = hueSlider

local hueIndicatorStroke = Instance.new("UIStroke")
hueIndicatorStroke.Color = Color3.fromRGB(30, 30, 35)
hueIndicatorStroke.Thickness = 2
hueIndicatorStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
hueIndicatorStroke.Parent = hueIndicator

local previewFrame = Instance.new("Frame")
previewFrame.Position = UDim2.new(0, 16, 0, 220)
previewFrame.Size = UDim2.new(0, 48, 0, 48)
previewFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
previewFrame.BorderSizePixel = 0
previewFrame.ZIndex = 101
previewFrame.Parent = colorPickerBackground

addCorner(previewFrame, UDim.new(0, 6))

local hexLabel = Instance.new("TextLabel")
hexLabel.Position = UDim2.new(0, 72, 0, 228)
hexLabel.Size = UDim2.new(1, -88, 0, 30)
hexLabel.BackgroundTransparency = 1
hexLabel.Font = Enum.Font.Gotham
hexLabel.TextSize = 14
hexLabel.TextColor3 = Color3.fromRGB(220, 220, 230)
hexLabel.TextXAlignment = Enum.TextXAlignment.Left
hexLabel.Text = "#FFFFFF"
hexLabel.ZIndex = 101
hexLabel.Parent = colorPickerBackground


local colorPickerState = {
	activeButton = nil,
	onChanged = nil,
	hue = 0,
	saturation = 1,
	value = 1,
	paletteDragging = false,
	hueDragging = false,
}

local function updateHexLabel(color)
	local r = math.clamp(math.floor(color.R * 255 + 0.5), 0, 255)
	local g = math.clamp(math.floor(color.G * 255 + 0.5), 0, 255)
	local b = math.clamp(math.floor(color.B * 255 + 0.5), 0, 255)
	hexLabel.Text = string.format("#%02X%02X%02X", r, g, b)
end

local function applyHSV(h, s, v, triggerCallback)
	colorPickerState.hue = math.clamp(h, 0, 1)
	colorPickerState.saturation = math.clamp(s, 0, 1)
	colorPickerState.value = math.clamp(v, 0, 1)

	paletteFrame.BackgroundColor3 = Color3.fromHSV(colorPickerState.hue, 1, 1)
	paletteIndicator.Position = UDim2.new(colorPickerState.saturation, 0, 1 - colorPickerState.value, 0)
	hueIndicator.Position = UDim2.new(0, 0, colorPickerState.hue, 0)

	local color = Color3.fromHSV(colorPickerState.hue, colorPickerState.saturation, colorPickerState.value)
	previewFrame.BackgroundColor3 = color
	updateHexLabel(color)
	if colorPickerState.activeButton then
		colorPickerState.activeButton.BackgroundColor3 = color
	end
	if triggerCallback and colorPickerState.onChanged then
		colorPickerState.onChanged(color)
	end
end

local function closeColorPicker()
	colorPickerState.activeButton = nil
	colorPickerState.onChanged = nil
	colorPickerState.paletteDragging = false
	colorPickerState.hueDragging = false
	colorPickerOverlay.Visible = false
end

colorPickerClose.MouseButton1Click:Connect(closeColorPicker)

local function updatePaletteFromInput(input)
	local absPos = paletteFrame.AbsolutePosition
	local absSize = paletteFrame.AbsoluteSize
	if absSize.X <= 0 or absSize.Y <= 0 then
		return
	end
	local relX = math.clamp((input.Position.X - absPos.X) / absSize.X, 0, 1)
	local relY = math.clamp((input.Position.Y - absPos.Y) / absSize.Y, 0, 1)
	applyHSV(colorPickerState.hue, relX, 1 - relY, true)
end

local function updateHueFromInput(input)
	local absPos = hueSlider.AbsolutePosition
	local absSize = hueSlider.AbsoluteSize
	if absSize.Y <= 0 then
		return
	end
	local relY = math.clamp((input.Position.Y - absPos.Y) / absSize.Y, 0, 1)
	applyHSV(relY, colorPickerState.saturation, colorPickerState.value, true)
end

paletteFrame.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		colorPickerState.paletteDragging = true
		updatePaletteFromInput(input)
	end
end)

paletteFrame.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		colorPickerState.paletteDragging = false
	end
end)

paletteFrame.InputChanged:Connect(function(input)
	if colorPickerState.paletteDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		updatePaletteFromInput(input)
	end
end)

hueSlider.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		colorPickerState.hueDragging = true
		updateHueFromInput(input)
	end
end)

hueSlider.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		colorPickerState.hueDragging = false
	end
end)

hueSlider.InputChanged:Connect(function(input)
	if colorPickerState.hueDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		updateHueFromInput(input)
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if not colorPickerOverlay.Visible then
		return
	end
	if colorPickerState.paletteDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		updatePaletteFromInput(input)
	elseif colorPickerState.hueDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		updateHueFromInput(input)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		colorPickerState.paletteDragging = false
		colorPickerState.hueDragging = false
	end
end)

local function openColorPicker(button, onChanged)
	colorPickerState.activeButton = button
	colorPickerState.onChanged = onChanged
	local color = button.BackgroundColor3
	local h, s, v = color:ToHSV()
	applyHSV(h, s, v, false)
	colorPickerOverlay.Visible = true
end

-- REPLACE from the line: local function createSection(title, defaultOpen)
local function createSection(title, defaultOpen)
	local container = Instance.new("Frame")
	container.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
	container.BackgroundTransparency = 0.15
	container.Size = UDim2.new(1, 0, 0, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.Parent = scroll

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = container

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 0)
	layout.Parent = container

	local headerButton = Instance.new("TextButton")
	headerButton.Name = "Header"
	headerButton.Size = UDim2.new(1, 0, 0, 40) -- was 36
	headerButton.BackgroundTransparency = 1
	headerButton.BorderSizePixel = 0
	headerButton.Text = ""
	headerButton.AutoButtonColor = false
	headerButton.Parent = container

	local headerLabel = Instance.new("TextLabel")
	headerLabel.BackgroundTransparency = 1
	headerLabel.Size = UDim2.new(1, -28, 1, 0)
	headerLabel.Position = UDim2.new(0, 12, 0, 0)
	headerLabel.Font = Enum.Font.GothamBold
	headerLabel.TextSize = 18 -- was 16
	headerLabel.TextXAlignment = Enum.TextXAlignment.Left
	headerLabel.TextColor3 = Color3.fromRGB(210, 210, 220)
	headerLabel.Text = title
	headerLabel.Parent = headerButton

	local indicator = Instance.new("TextLabel")
	indicator.Name = "Indicator"
	indicator.BackgroundTransparency = 1
	indicator.Font = Enum.Font.GothamBold
	indicator.TextSize = 20 -- was 18
	indicator.TextColor3 = Color3.fromRGB(210, 210, 220)
	indicator.Size = UDim2.new(0, 18, 1, 0)
	indicator.Position = UDim2.new(1, -24, 0, 0)
	indicator.Text = ""
	indicator.Parent = headerButton

	local contentHolder = Instance.new("Frame")
	contentHolder.Name = "Content"
	contentHolder.Size = UDim2.new(1, 0, 0, 0)
	contentHolder.BackgroundTransparency = 1
	contentHolder.AutomaticSize = Enum.AutomaticSize.Y
	contentHolder.Parent = container

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.PaddingBottom = UDim.new(0, 12)
	padding.Parent = contentHolder

	local contentLayout = Instance.new("UIListLayout")
	contentLayout.FillDirection = Enum.FillDirection.Vertical
	contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
	contentLayout.Padding = UDim.new(0, 6)
	contentLayout.Parent = contentHolder

	local open = defaultOpen and true or false

	local function setOpen(value)
		open = value and true or false
		contentHolder.Visible = open
		indicator.Text = open and "v" or ">"
		padding.PaddingTop = open and UDim.new(0, 6) or UDim.new(0, 0)
	end

	headerButton.MouseButton1Click:Connect(function()
		setOpen(not open)
	end)

	setOpen(open)

	local api = {}
	function api:GetContent()
		return contentHolder
	end
	function api:SetOpen(value)
		setOpen(value)
	end
	function api:IsOpen()
		return open
	end
	return api
end
-- REPLACE until here


local function createSubLabel(parent, text, isHelpText)
	local label = Instance.new("TextLabel")
	label.Name = isHelpText and "HelpText" or "SubLabel"
	label.Size = UDim2.new(1, 0, 0, isHelpText and 42 or 28)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	label.TextSize = isHelpText and 12 or 18
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = isHelpText and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center
	label.TextWrapped = isHelpText and true or false
	label.TextColor3 = isHelpText and Color3.fromRGB(155, 165, 185) or Color3.fromRGB(185, 185, 195)
	label.Text = text
	label.Parent = parent
	return label
end


local function formatInteger(value)
	return string.format("%d", math.floor(value + 0.5))
end

local function formatFloat(value)
	return string.format("%.2f", value)
end

local function createCheckbox(parent, labelText, initialValue, onChanged)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 32)
	row.BackgroundTransparency = 1
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -36, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	label.TextSize = 14
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(220, 220, 225)
	label.Text = labelText
	label.Parent = row

	local button = Instance.new("TextButton")
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, 0, 0.5, 0)
	button.Size = UDim2.new(0, 24, 0, 24)
	button.AutoButtonColor = false
	button.Text = ""
	button.BackgroundColor3 = initialValue and Color3.fromRGB(70, 170, 110) or Color3.fromRGB(70, 70, 80)
	button.Parent = row

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = button

	local check = Instance.new("Frame")
	check.Size = UDim2.new(0.6, 0, 0.6, 0)
	check.AnchorPoint = Vector2.new(0.5, 0.5)
	check.Position = UDim2.new(0.5, 0, 0.5, 0)
	check.BackgroundTransparency = initialValue and 0 or 1
	check.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	check.Parent = button

	local checkCorner = Instance.new("UICorner")
	checkCorner.CornerRadius = UDim.new(0, 4)
	checkCorner.Parent = check

	local value = initialValue
	local enabled = true

	local function setVisual()
		button.BackgroundColor3 = value and Color3.fromRGB(70, 170, 110) or Color3.fromRGB(70, 70, 80)
		check.BackgroundTransparency = value and 0 or 1
		button.Active = enabled
		button.AutoButtonColor = false
		button.BackgroundTransparency = enabled and 0 or 0.4
	end

	button.MouseButton1Click:Connect(function()
		if not enabled then
			return
		end
		value = not value
		setVisual()
		if onChanged then
			onChanged(value)
		end
	end)

	setVisual()

	local api = {}
	function api:SetValue(newValue)
		value = newValue and true or false
		setVisual()
	end
	function api:SetEnabled(isEnabled)
		enabled = isEnabled
		setVisual()
	end
	return api
end

local CURVE_SLIDER_COLOR = Color3.fromRGB(232, 189, 211)

-- [SliderFix] полная замена: поддержка drag от трека и от «шайбы», плюс глобальный отпуск мыши
local function createSlider(parent, labelText, minValue, maxValue, initialValue, step, onChanged, formatValue, fillColor)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 54)
	row.BackgroundTransparency = 1
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(0.7, 0, 0, 22)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	label.TextSize = 14
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(220, 220, 225)
	label.Text = labelText
	label.Parent = row

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Size = UDim2.new(0.3, 0, 0, 22)
	valueLabel.Position = UDim2.new(0.7, 0, 0, 0)
	valueLabel.BackgroundTransparency = 1
	valueLabel.Font = Enum.Font.Gotham
	valueLabel.TextSize = 14
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.TextColor3 = Color3.fromRGB(180, 180, 190)
	valueLabel.Parent = row

	local sliderTrack = Instance.new("Frame")
	sliderTrack.AnchorPoint = Vector2.new(0, 1)
	sliderTrack.Position = UDim2.new(0, 0, 1, -4)
	sliderTrack.Size = UDim2.new(1, 0, 0, 18)
	sliderTrack.BackgroundColor3 = Color3.fromRGB(52, 52, 60)
	sliderTrack.Active = true
	sliderTrack.Parent = row
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 8)
	trackCorner.Parent = sliderTrack

	local accentColor = fillColor or Color3.fromRGB(90, 140, 255)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = accentColor
	fill.BackgroundTransparency = 0.1
	fill.Parent = sliderTrack
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 8)
	fillCorner.Parent = fill

	local thumb = Instance.new("Frame")
	thumb.AnchorPoint = Vector2.new(0.5, 0.5)
	thumb.Size = UDim2.new(0, 14, 0, 14)
	thumb.Position = UDim2.new(0, 0, 0.5, 0)
	thumb.BackgroundColor3 = Color3.fromRGB(240, 240, 245)
	thumb.Active = true
	thumb.Parent = sliderTrack
	local thumbCorner = Instance.new("UICorner")
	thumbCorner.CornerRadius = UDim.new(0, 7)
	thumbCorner.Parent = thumb

	local stepValue = step or (maxValue - minValue) / 200
	if stepValue <= 0 then
		stepValue = 0.01
	end

	local formatter = formatValue or (stepValue >= 1 and formatInteger or formatFloat)
	local dragging = false
	local enabled = true
	local currentValue = initialValue
	local connections = {}
	local activeInput
	local guiRoot = sliderTrack:FindFirstAncestorWhichIsA("PluginGui")
		or sliderTrack:FindFirstAncestorWhichIsA("ScreenGui")

	local function clampValue(value)
		if maxValue == minValue then
			return minValue
		end
		local scaled = (value - minValue) / stepValue
		local snapped = minValue + math.round(scaled) * stepValue
		return math.clamp(snapped, math.min(minValue, maxValue), math.max(minValue, maxValue))
	end

	local function updateVisual()
		local range = maxValue - minValue
		local alpha = (range ~= 0) and ((currentValue - minValue) / range) or 0
		alpha = math.clamp(alpha, 0, 1)
		fill.Size = UDim2.new(alpha, 0, 1, 0)
		thumb.Position = UDim2.new(alpha, 0, 0.5, 0)
		valueLabel.Text = formatter(currentValue)
		sliderTrack.BackgroundTransparency = enabled and 0 or 0.4
		fill.BackgroundColor3 = accentColor
		fill.BackgroundTransparency = enabled and 0.1 or 0.5
		thumb.BackgroundTransparency = enabled and 0 or 0.4
		sliderTrack.Active = enabled
		thumb.Active = enabled
	end

	local function setValue(newValue, fireCallback)
		currentValue = clampValue(newValue)
		updateVisual()
		if fireCallback and onChanged then
			onChanged(currentValue)
		end
	end

	local function resolveTrackOrigin()
		local absolute = sliderTrack.AbsolutePosition
		if guiRoot then
			local rootAbs = guiRoot.AbsolutePosition
			return Vector2.new(absolute.X - rootAbs.X, absolute.Y - rootAbs.Y)
		end
		return Vector2.new(absolute.X, absolute.Y)
	end

	local function getPointerVector(input)
		local userInputType = input and input.UserInputType
		if userInputType == Enum.UserInputType.MouseMovement or userInputType == Enum.UserInputType.MouseButton1 then
			if guiRoot and guiRoot:IsA("PluginGui") then
				local relative = guiRoot:GetRelativeMousePosition()
				return Vector2.new(relative.X, relative.Y)
			end
			local loc = UserInputService:GetMouseLocation()
			return Vector2.new(loc.X, loc.Y)
		end
		if userInputType == Enum.UserInputType.Touch then
			local position = input.Position
			if typeof(position) == "Vector3" then
				return Vector2.new(position.X, position.Y)
			elseif typeof(position) == "Vector2" then
				return position
			end
			return nil
		end
		local position = input and input.Position
		if typeof(position) == "Vector3" then
			return Vector2.new(position.X, position.Y)
		elseif typeof(position) == "Vector2" then
			return position
		end
		if guiRoot and guiRoot:IsA("PluginGui") then
			local relative = guiRoot:GetRelativeMousePosition()
			return Vector2.new(relative.X, relative.Y)
		end
		local loc = UserInputService:GetMouseLocation()
		return Vector2.new(loc.X, loc.Y)
	end

	local function handlePointerPosition(pointer)
		if not pointer then
			return
		end
		local origin = resolveTrackOrigin()
		local absSize = sliderTrack.AbsoluteSize.X
		if absSize <= 0 then
			return
		end
		local relative = (pointer.X - origin.X) / absSize
		local newValue = minValue + (maxValue - minValue) * relative
		setValue(newValue, true)
	end

	local function handleInput(input)
		if not enabled then
			return
		end
		local pointer = getPointerVector(input)
		handlePointerPosition(pointer)
	end

	local function beginDrag(input)
		if not enabled then
			return
		end
		dragging = true
		activeInput = input
		handleInput(input)
	end

	local function endDrag(input)
		if not dragging then
			return
		end
		if input == activeInput then
			dragging = false
			activeInput = nil
			return
		end
		if activeInput and activeInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
			activeInput = nil
			return
		end
		if activeInput and activeInput.UserInputType == Enum.UserInputType.Touch and input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
			activeInput = nil
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
			activeInput = nil
		end
	end

	local function shouldTrackInput(input)
		if not dragging then
			return false
		end
		if input == activeInput then
			return true
		end
		if activeInput and activeInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement then
			return true
		end
		if activeInput and activeInput.UserInputType == Enum.UserInputType.Touch and input.UserInputType == Enum.UserInputType.Touch then
			return true
		end
		return false
	end

	table.insert(connections, sliderTrack.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			beginDrag(input)
		end
	end))
	table.insert(connections, sliderTrack.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			endDrag(input)
		end
	end))
	table.insert(connections, sliderTrack.InputChanged:Connect(function(input)
		if shouldTrackInput(input) then
			handleInput(input)
		end
	end))

	-- ВАЖНО: поддержка перетаскивания за «шайбу»
	table.insert(connections, thumb.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			beginDrag(input)
		end
	end))
	table.insert(connections, thumb.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			endDrag(input)
		end
	end))
	table.insert(connections, thumb.InputChanged:Connect(function(input)
		if shouldTrackInput(input) then
			handleInput(input)
		end
	end))

	-- Глобальный move/ended, чтобы тянуть за пределы трека и отпускать где угодно
	table.insert(connections, UserInputService.InputChanged:Connect(function(input)
		if shouldTrackInput(input) then
			handleInput(input)
		end
	end))
	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			endDrag(input)
		end
	end))

	row.Destroying:Connect(function()
		dragging = false
		activeInput = nil
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
	end)

	setValue(initialValue, false)

	local api = {}
	function api:SetValue(newValue)
		setValue(newValue, false)
	end
	function api:SetRange(newMin, newMax)
		minValue = newMin
		maxValue = newMax
		setValue(currentValue, false)
	end
	function api:SetEnabled(isEnabled)
		enabled = isEnabled
		updateVisual()
	end
	function api:GetValue()
		return currentValue
	end
	return api
end


local function createMaterialDropdown(parent, labelText, initialMaterial, onChanged)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 32)
	row.BackgroundTransparency = 1
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(0.5, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	label.TextSize = 14
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(220, 220, 225)
	label.Text = labelText
	label.Parent = row

	local button = Instance.new("TextButton")
	button.Size = UDim2.new(0.5, -8, 1, 0)
	button.Position = UDim2.new(0.5, 8, 0, 0)
	button.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
	button.TextColor3 = Color3.fromRGB(235, 235, 240)
	button.Font = Enum.Font.Gotham
	button.TextSize = 14
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.AutoButtonColor = false
	button.Parent = row

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = button

	local listFrame = Instance.new("Frame")
	listFrame.Visible = false
	listFrame.Size = UDim2.new(0, 180, 0, 200)
	listFrame.Position = UDim2.new(0, 0, 1, 4)
	listFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 46)
	listFrame.BorderSizePixel = 0
	listFrame.Parent = button

	local listCorner = Instance.new("UICorner")
	listCorner.CornerRadius = UDim.new(0, 6)
	listCorner.Parent = listFrame

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 2)
	listLayout.Parent = listFrame

	local function setMaterial(material)
		button.Text = material.Name
		if onChanged then
			onChanged(material)
		end
	end

	for _, material in ipairs(MATERIALS) do
		local option = Instance.new("TextButton")
		option.Size = UDim2.new(1, 0, 0, 28)
		option.BackgroundColor3 = Color3.fromRGB(50, 50, 58)
		option.AutoButtonColor = false
		option.Font = Enum.Font.Gotham
		option.TextSize = 14
		option.TextColor3 = Color3.fromRGB(220, 220, 230)
		option.Text = material.Name
		option.Parent = listFrame
		option.MouseButton1Click:Connect(function()
			listFrame.Visible = false
			setMaterial(material)
		end)
	end

	button.MouseButton1Click:Connect(function()
		listFrame.Visible = not listFrame.Visible
	end)

	setMaterial(initialMaterial)

	return {
		SetMaterial = function(_, material)
			setMaterial(material)
		end,
		Close = function()
			listFrame.Visible = false
		end,
	}
end

local function createColorPicker(parent, labelText, initialValue, onChanged)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 44)
	row.BackgroundTransparency = 1
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -48, 0, 24)
	label.Position = UDim2.new(0, 0, 0, 10)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	label.TextSize = 14
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(220, 220, 225)
	label.Text = labelText
	label.Parent = row

	local button = Instance.new("TextButton")
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, 0, 0.5, 0)
	button.Size = UDim2.new(0, 36, 0, 36)
	button.BackgroundColor3 = initialValue
	button.AutoButtonColor = false
	button.Text = ""
	button.Parent = row

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Transparency = 0.45
	stroke.Parent = button

	button.MouseButton1Click:Connect(function()
		if isPlayMode() then
			return
		end

		openColorPicker(button, function(color)
			if onChanged then
				onChanged(color)
			end
		end)
	end)

	local api = {}
	function api:SetColor(newColor)
		button.BackgroundColor3 = newColor
		if colorPickerState.activeButton == button then
			local h, s, v = newColor:ToHSV()
			applyHSV(h, s, v, false)
		end
	end
	return api
end

local function setButtonEnabled(button, baseColor, enabled)
	button.Active = enabled
	button.AutoButtonColor = enabled
	if button:IsA("GuiButton") then
		button.Selectable = enabled
	end
	button.TextTransparency = enabled and 0 or 0.35
	button.BackgroundColor3 = enabled and baseColor or DISABLED_COLOR
end

local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

currentEmitter = nil
local emitterConnections = {}
currentState = defaultState()

ensureStateIntegrity(currentState)
local stateDirty = false
local currentDisplayName = ""
local selectedPresetItem = nil
local presetItems = {}
local presetConnections = {}
local dropdownVisible = false
previewEmitter = nil



local function clearEmitterConnections()
	for _, connection in ipairs(emitterConnections) do
		connection:Disconnect()
	end
	table.clear(emitterConnections)
end

local function setWidgetTitleDirty()
	widget.Title = stateDirty and (BASE_TITLE .. " *") or BASE_TITLE
end

local function updateEmitterInfo()
	if currentEmitter and currentEmitter.Parent then
		local fullName = currentEmitter:GetFullName()
		emitterInfoLabel.Text = string.format("Emitter: %s", fullName)
		local cf = currentEmitter.CFrame
		local pos = cf.Position
		local look = cf.LookVector
		positionLabel.Text = string.format(
			"World CFrame: (%.2f, %.2f, %.2f)  look (%.2f, %.2f, %.2f)",
			pos.X, pos.Y, pos.Z,
			look.X, look.Y, look.Z
		)
	else
		emitterInfoLabel.Text = "Emitter: <none>"
		positionLabel.Text = "World CFrame: n/a"
	end
end

-- FIX: assign to the forward-declared locals (do not redeclare)
DEFAULT_PRESET_NAME = "Default"
DEFAULT_DISPLAY_NAME = "Default"


local function updateStatus()
	local playMode = isPlayMode()
	if refreshRunModeControls then
		refreshRunModeControls(playMode)
	end
	if not runtimePrepared then
		local runtimeMessage = currentRuntimeStatus and currentRuntimeStatus.message
		statusLabel.Text = runtimeMessage or "Inspecting Voxel Particles runtime..."
		if scroll then
			scroll.Visible = false
			scroll.Active = false
		end
		setWidgetTitleDirty()
		return
	end

	if not currentEmitter then
		statusLabel.Text = playMode
			and "Play mode: select an emitter in Workspace. Editor controls are disabled."
			or "Select a part named VoxelEmitter to begin."
		if scroll then
			scroll.Visible = false
			scroll.Active = false
		end
	else
		local parts = {}
		table.insert(parts, stateDirty and "Unsaved changes" or "All changes saved")
		if selectedPresetItem and selectedPresetItem.module then
			table.insert(parts, string.format("Preset: %s", selectedPresetItem.module.Name))
			if RuntimeInstaller.isFileSynced(selectedPresetItem.module) then
				table.insert(parts, "Disk-synced preset: preview only")
			end
		else
			table.insert(parts, string.format("Preset: %s", DEFAULT_PRESET_NAME))
		end
		if playMode then
			table.insert(parts, "Play mode: controls disabled")
		end
		statusLabel.Text = table.concat(parts, " • ")
		if scroll then
			scroll.Visible = true
			scroll.Active = not playMode
		end
	end
	setWidgetTitleDirty()
end



local function markDirty()
	stateDirty = true
	updateStatus()
end

local saveCurrentPreset
local _autosavePending = false
local function _scheduleAutoSave()
	if isPlayMode() then return end
	if not currentEmitter then return end
	if not selectedPresetItem or not selectedPresetItem.module then return end
	if RuntimeInstaller.isFileSynced(selectedPresetItem.module) then
		updateStatus()
		return
	end
	if _autosavePending then return end
	_autosavePending = true
	task.delay(0.3, function()
		_autosavePending = false
		-- сохраняем выбранный пресет с текущим state
		saveCurrentPreset()
	end)
end


local function scheduleApply()
	if isPlayMode() then return end

	markDirty()
	applyPreview()
	_scheduleAutoSave()
end



local function rebuildPanel(state)
	for _, child in ipairs(scroll:GetChildren()) do
		if child ~= scrollLayout then
			child:Destroy()
		end
	end

	ensureStateIntegrity(state)
	local per = state.perParticle

	local function rangeSlider(container, label, rangeTable, minimum, maximum, stepValue, formatter)
		local minSlider
		local maxSlider
		minSlider = createSlider(container, label .. " min", minimum, maximum, rangeTable.min, stepValue, function(v)
			rangeTable.min = v
			if rangeTable.max < rangeTable.min then
				rangeTable.max = rangeTable.min
				if maxSlider then
					maxSlider:SetValue(rangeTable.max)
				end
			end
			scheduleApply()
		end, formatter)
		maxSlider = createSlider(container, label .. " max", minimum, maximum, rangeTable.max, stepValue, function(v)
			rangeTable.max = v
			if rangeTable.min > rangeTable.max then
				rangeTable.min = rangeTable.max
				if minSlider then
					minSlider:SetValue(rangeTable.min)
				end
			end
			scheduleApply()
		end, formatter)
	end

	local function curveTriple(container, label, values)
		createSubLabel(container, label)
		createSlider(container, label .. " start", 0, 5, values[1], 0.05, function(v)
			values[1] = v
			scheduleApply()
		end, formatFloat, CURVE_SLIDER_COLOR)
		createSlider(container, label .. " mid", 0, 5, values[2], 0.05, function(v)
			values[2] = v
			scheduleApply()
		end, formatFloat, CURVE_SLIDER_COLOR)
		createSlider(container, label .. " finish", 0, 5, values[3], 0.05, function(v)
			values[3] = v
			scheduleApply()
		end, formatFloat, CURVE_SLIDER_COLOR)
	end

	local function noiseControls(container, prefix, amplitudeKey, frequencyKey, seedKey, seedStoreKey)
		createSlider(container, prefix .. " noise amplitude", 0, 1, state[amplitudeKey], 0.01, function(v)
			state[amplitudeKey] = math.clamp(v, 0, 1)
			scheduleApply()
		end, formatFloat)
		createSlider(container, prefix .. " noise frequency", 0, 20, state[frequencyKey], 0.05, function(v)
			state[frequencyKey] = math.max(0, v)
			scheduleApply()
		end, formatFloat)

		local seedSliderControl
		createCheckbox(container, prefix .. " inherit seed", state[seedKey] == nil, function(value)
			if value then
				state[seedKey] = nil
				if seedSliderControl then
					seedSliderControl:SetEnabled(false)
				end
			else
				state[seedKey] = state[seedStoreKey]
				if seedSliderControl then
					seedSliderControl:SetEnabled(true)
				end
			end
			scheduleApply()
		end)

		seedSliderControl = createSlider(container, prefix .. " manual seed", 0, 100000, state[seedKey] or state[seedStoreKey], 1, function(v)
			local iv = math.floor(v + 0.5)
			state[seedStoreKey] = iv
			if state[seedKey] ~= nil then
				state[seedKey] = iv
				scheduleApply()
			end
		end, formatInteger)
		if state[seedKey] == nil and seedSliderControl then
			seedSliderControl:SetEnabled(false)
		end
	end

	local emissionSection = createSection("Emission & Spawn", true)
	local emission = emissionSection:GetContent()

	createCheckbox(emission, "Emitter enabled", state.enabled, function(value)
		state.enabled = value
		scheduleApply()
	end)

	local seedSlider
	createCheckbox(emission, "Automatic seed", state.seed == nil, function(value)
		if value then
			state.seed = nil
			if seedSlider then
				seedSlider:SetEnabled(false)
			end
		else
			state.seed = state._seedValue
			if seedSlider then
				seedSlider:SetEnabled(true)
			end
		end
		scheduleApply()
	end)

	seedSlider = createSlider(emission, "Manual seed", 0, 100000, state.seed or state._seedValue, 1, function(v)
		local iv = math.floor(v + 0.5)
		state._seedValue = iv
		if state.seed ~= nil then
			state.seed = iv
			scheduleApply()
		end
	end, formatInteger)
	if state.seed == nil and seedSlider then
		seedSlider:SetEnabled(false)
	end

	local burstSlider
	createSlider(emission, "Emission rate", 0, 512, state.rate, 1, function(v)
		local newRate = math.floor(v + 0.5)
		state.rate = newRate
		if burstSlider then
			burstSlider:SetEnabled(newRate == 0)
		end
		scheduleApply()
	end, formatInteger)

	burstSlider = createSlider(emission, "Burst emission count", 0, 512, state.burstCount or 0, 1, function(v)
		state.burstCount = math.max(0, math.floor(v + 0.5))
		scheduleApply()
	end, formatInteger)
	if state.rate ~= 0 and burstSlider then
		burstSlider:SetEnabled(false)
	end

	createSlider(emission, "Max particles", 1, 2048, state.maxParticles, 1, function(v)
		state.maxParticles = math.max(1, math.floor(v + 0.5))
		scheduleApply()
	end, formatInteger)

	rangeSlider(emission, "Lifetime", per.life, 0.01, 10, 0.05, formatFloat)

	noiseControls(emission, "Rate", "rateNoiseAmplitude", "rateNoiseFrequency", "rateNoiseSeed", "_rateNoiseSeedValue")
	noiseControls(emission, "Lifetime", "lifeNoiseAmplitude", "lifeNoiseFrequency", "lifeNoiseSeed", "_lifeNoiseSeedValue")

	local spawnShapeIndex = 1
	for i, shape in ipairs(SHAPES) do
		if shape == state.spawnShape then
			spawnShapeIndex = i
			break
		end
	end

	createSlider(emission, "Spawn shape", 1, #SHAPES, spawnShapeIndex, 1, function(v)
		if #SHAPES == 0 then
			return
		end
		local idx = math.clamp(math.floor(v + 0.5), 1, #SHAPES)
		local nextShape = SHAPES[idx]
		state.spawnShape = nextShape
		if nextShape == "cubicBezier" then
			state.spawnDirectionMode = "curveNormal"
		elseif state.spawnDirectionMode == "curveNormal" then
			state.spawnDirectionMode = "emission"
		end
		scheduleApply()
		rebuildPanel(state)
	end, function(v)
		if #SHAPES == 0 then
			return "-"
		end
		local idx = math.clamp(math.floor(v + 0.5), 1, #SHAPES)
		local shapeId = SHAPES[idx]
		return SHAPE_DISPLAY_NAMES[shapeId] or shapeId
	end)

	createSlider(emission, "Spawn size X", 0, 10, state.spawnSize.X, 0.05, function(v)
		state.spawnSize = Vector3.new(math.max(0, v), state.spawnSize.Y, state.spawnSize.Z)
		scheduleApply()
	end, formatFloat)
	createSlider(emission, "Spawn size Y", 0, 10, state.spawnSize.Y, 0.05, function(v)
		state.spawnSize = Vector3.new(state.spawnSize.X, math.max(0, v), state.spawnSize.Z)
		scheduleApply()
	end, formatFloat)
	createSlider(emission, "Spawn size Z", 0, 10, state.spawnSize.Z, 0.05, function(v)
		state.spawnSize = Vector3.new(state.spawnSize.X, state.spawnSize.Y, math.max(0, v))
		scheduleApply()
	end, formatFloat)
	createSlider(emission, "Annulus inner radius", 0, 10, state.spawnInnerRadius, 0.05, function(v)
		state.spawnInnerRadius = math.max(0, v)
		scheduleApply()
	end, formatFloat)
	createSubLabel(
		emission,
		"Annulus uses equal positive Spawn size X/Z as its outer radius; inner radius must be smaller.",
		true
	)
	createCheckbox(emission, "Spawn surface only", state.spawnSurfaceOnly, function(value)
		state.spawnSurfaceOnly = value
		scheduleApply()
	end)
	if state.spawnShape == "cubicBezier" then
		createSubLabel(
			emission,
			"Cubic Bezier points are local to the emitter. P0/P3 are endpoints; P1/P2 shape the curve.",
			true
		)
		local function addCurvePointSlider(pointIndex, axis)
			local point = state.cubicBezierPoints[pointIndex]
			local value = if axis == "X" then point.X elseif axis == "Y" then point.Y else point.Z
			createSlider(emission, ("Curve P%d %s"):format(pointIndex - 1, axis), -50, 50, value, 0.1, function(v)
				local current = state.cubicBezierPoints[pointIndex]
				if axis == "X" then
					state.cubicBezierPoints[pointIndex] = Vector3.new(v, current.Y, current.Z)
				elseif axis == "Y" then
					state.cubicBezierPoints[pointIndex] = Vector3.new(current.X, v, current.Z)
				else
					state.cubicBezierPoints[pointIndex] = Vector3.new(current.X, current.Y, v)
				end
				scheduleApply()
			end, formatFloat)
		end
		for pointIndex = 1, 4 do
			addCurvePointSlider(pointIndex, "X")
			addCurvePointSlider(pointIndex, "Y")
			addCurvePointSlider(pointIndex, "Z")
		end
	end

	local speedSection = createSection("Speed & Size", false)
	local speedContent = speedSection:GetContent()
	rangeSlider(speedContent, "Speed", per.speed, 0, 50, 0.1, formatFloat)
	createSlider(speedContent, "Distance speed factor", -10, 10, state.distanceSpeedFactor, 0.1, function(v)
		state.distanceSpeedFactor = math.clamp(v, -10, 10)
		scheduleApply()
	end, formatFloat)
	createSubLabel(speedContent, "Global speed curve")
	createSlider(speedContent, "Global speed start", 0, 5, state.globalSpeedCurve[1], 0.05, function(v)
		state.globalSpeedCurve[1] = v
		scheduleApply()
	end, formatFloat, CURVE_SLIDER_COLOR)
	createSlider(speedContent, "Global speed mid", 0, 5, state.globalSpeedCurve[2], 0.05, function(v)
		state.globalSpeedCurve[2] = v
		scheduleApply()
	end, formatFloat, CURVE_SLIDER_COLOR)
	createSlider(speedContent, "Global speed finish", 0, 5, state.globalSpeedCurve[3], 0.05, function(v)
		state.globalSpeedCurve[3] = v
		scheduleApply()
	end, formatFloat, CURVE_SLIDER_COLOR)
	curveTriple(speedContent, "Per-particle speed curve", state.perParticleCurves.speed)
	rangeSlider(speedContent, "Size", per.size, 0, 10, 0.05, formatFloat)
	curveTriple(speedContent, "Per-particle size curve", state.perParticleCurves.size)
	noiseControls(speedContent, "Size", "sizeNoiseAmplitude", "sizeNoiseFrequency", "sizeNoiseSeed", "_sizeNoiseSeedValue")

	local movementSection = createSection("Movement & Forces", false)
	local movement = movementSection:GetContent()
	rangeSlider(movement, "Emission angle", per.angle, 0, 180, 1, formatInteger)
	local directionModeIndex = 1
	for i, directionMode in ipairs(DIRECTION_MODES) do
		if directionMode == state.spawnDirectionMode then
			directionModeIndex = i
			break
		end
	end
	createSlider(movement, "Spawn direction mode", 1, #DIRECTION_MODES, directionModeIndex, 1, function(v)
		local idx = math.clamp(math.floor(v + 0.5), 1, #DIRECTION_MODES)
		state.spawnDirectionMode = DIRECTION_MODES[idx]
		scheduleApply()
	end, function(v)
		local idx = math.clamp(math.floor(v + 0.5), 1, #DIRECTION_MODES)
		local modeId = DIRECTION_MODES[idx]
		return DIRECTION_MODE_DISPLAY_NAMES[modeId] or modeId
	end)
	createSubLabel(
		movement,
		"Radial modes use the sampled offset. Curve normal sends particles away around the curve tangent. Emission axis uses the direction below.",
		true
	)
	createSlider(movement, "Emission direction X", -10, 10, state.emissionDirection.X, 0.05, function(v)
		state.emissionDirection = Vector3.new(v, state.emissionDirection.Y, state.emissionDirection.Z)
		scheduleApply()
	end, formatFloat)
	createSlider(movement, "Emission direction Y", -10, 10, state.emissionDirection.Y, 0.05, function(v)
		state.emissionDirection = Vector3.new(state.emissionDirection.X, v, state.emissionDirection.Z)
		scheduleApply()
	end, formatFloat)
	createSlider(movement, "Emission direction Z", -10, 10, state.emissionDirection.Z, 0.05, function(v)
		state.emissionDirection = Vector3.new(state.emissionDirection.X, state.emissionDirection.Y, v)
		scheduleApply()
	end, formatFloat)
	createSlider(movement, "Wind X", -20, 20, state.wind.X, 0.5, function(v)
		state.wind = Vector3.new(v, state.wind.Y, state.wind.Z)
		scheduleApply()
	end, formatFloat)
	createSlider(movement, "Wind Y", -20, 20, state.wind.Y, 0.5, function(v)
		state.wind = Vector3.new(state.wind.X, v, state.wind.Z)
		scheduleApply()
	end, formatFloat)
	createSlider(movement, "Wind Z", -20, 20, state.wind.Z, 0.5, function(v)
		state.wind = Vector3.new(state.wind.X, state.wind.Y, v)
		scheduleApply()
	end, formatFloat)
	createSlider(movement, "Acceleration X", -200, 200, state.acceleration.X, 0.5, function(v)
		state.acceleration = Vector3.new(v, state.acceleration.Y, state.acceleration.Z)
		scheduleApply()
	end, formatFloat)
	createSlider(movement, "Acceleration Y", -200, 200, state.acceleration.Y, 0.5, function(v)
		state.acceleration = Vector3.new(state.acceleration.X, v, state.acceleration.Z)
		scheduleApply()
	end, formatFloat)
	createSlider(movement, "Acceleration Z", -200, 200, state.acceleration.Z, 0.5, function(v)
		state.acceleration = Vector3.new(state.acceleration.X, state.acceleration.Y, v)
		scheduleApply()
	end, formatFloat)
	createSubLabel(
		movement,
		"Acceleration accumulates velocity. Drag limits that velocity; 0 leaves it unlimited. Negative curve values reverse acceleration.",
		true
	)
	createSlider(movement, "Acceleration drag", 0, 100, state.accelerationDrag, 0.5, function(v)
		state.accelerationDrag = v
		scheduleApply()
	end, formatFloat)
	createSlider(movement, "Acceleration curve start", -5, 5, state.accelerationCurve.start, 0.05, function(v)
		state.accelerationCurve.start = v
		scheduleApply()
	end, formatFloat, CURVE_SLIDER_COLOR)
	createSlider(movement, "Acceleration curve mid", -5, 5, state.accelerationCurve.mid, 0.05, function(v)
		state.accelerationCurve.mid = v
		scheduleApply()
	end, formatFloat, CURVE_SLIDER_COLOR)
	createSlider(movement, "Acceleration curve finish", -5, 5, state.accelerationCurve.finish, 0.05, function(v)
		state.accelerationCurve.finish = v
		scheduleApply()
	end, formatFloat, CURVE_SLIDER_COLOR)
	rangeSlider(movement, "Return force", per.returnForce, -2, 2, 0.05, formatFloat)
	curveTriple(movement, "Return force curve", state.perParticleCurves.returnForce)
	createCheckbox(movement, "Simulate in local space", state.localSpace, function(value)
		state.localSpace = value
		scheduleApply()
	end)

	local rotationSection = createSection("Rotation & Orientation", false)
	local rotation = rotationSection:GetContent()
	rangeSlider(rotation, "Rotation X", per.rotationX, -360, 360, 1, formatInteger)
	rangeSlider(rotation, "Rotation Y", per.rotationY, -360, 360, 1, formatInteger)
	rangeSlider(rotation, "Rotation Z", per.rotationZ, -360, 360, 1, formatInteger)
	curveTriple(rotation, "Rotation X curve", state.perParticleCurves.rotationX)
	curveTriple(rotation, "Rotation Y curve", state.perParticleCurves.rotationY)
	curveTriple(rotation, "Rotation Z curve", state.perParticleCurves.rotationZ)
	createCheckbox(rotation, "Face movement direction", state.faceMovement, function(value)
		state.faceMovement = value
		scheduleApply()
	end)

	local steeringSection = createSection("Steering", false)
	local steering = steeringSection:GetContent()
	rangeSlider(steering, "Steer yaw", per.steerYaw, -360, 360, 1, formatInteger)
	rangeSlider(steering, "Steer pitch", per.steerPitch, -360, 360, 1, formatInteger)
	rangeSlider(steering, "Steer roll", per.steerRoll, -360, 360, 1, formatInteger)
	curveTriple(steering, "Steer yaw curve", state.perParticleCurves.steerYaw)
	curveTriple(steering, "Steer pitch curve", state.perParticleCurves.steerPitch)
	curveTriple(steering, "Steer roll curve", state.perParticleCurves.steerRoll)
	noiseControls(steering, "Steer", "steerNoiseAmplitude", "steerNoiseFrequency", "steerNoiseSeed", "_steerNoiseSeedValue")

	local turbulenceSection = createSection("Turbulence", false)
	local turbulence = turbulenceSection:GetContent()
	rangeSlider(turbulence, "Turbulence strength", per.turbulence, -10, 10, 0.5, formatFloat)
	curveTriple(turbulence, "Turbulence curve", state.perParticleCurves.turbulence)
	createCheckbox(turbulence, "Turbulence anti jitter", state.turbulenceAntiJitter, function(value)
		state.turbulenceAntiJitter = value
		scheduleApply()
	end)

	local appearanceSection = createSection("Appearance", false)
	local appearance = appearanceSection:GetContent()
	local baseColorPicker = createColorPicker(appearance, "Base color", state.color, function(color)
		state.color = color
		scheduleApply()
	end)

	local materialDropdown = createMaterialDropdown(appearance, "Material", state.material, function(material)
		state.material = material
		scheduleApply()
	end)
	materialDropdown:SetMaterial(state.material)

	createSubLabel(appearance, "Per-particle color range")
	local rangeMinPicker = createColorPicker(appearance, "Range minimum", per.color.min, function(color)
		per.color.min = color
		scheduleApply()
	end)
	local rangeMaxPicker = createColorPicker(appearance, "Range maximum", per.color.max, function(color)
		per.color.max = color
		scheduleApply()
	end)
	rangeSlider(appearance, "Per-particle opacity", per.opacity, 0, 1, 0.01, formatFloat)
	createSubLabel(appearance, "Color over lifetime")
	local startPicker = createColorPicker(appearance, "Start color", state.colorCurve.start, function(color)
		state.colorCurve.start = color
		scheduleApply()
	end)
	local midPicker = createColorPicker(appearance, "Mid color", state.colorCurve.mid, function(color)
		state.colorCurve.mid = color
		scheduleApply()
	end)
	local finishPicker = createColorPicker(appearance, "Finish color", state.colorCurve.finish, function(color)
		state.colorCurve.finish = color
		scheduleApply()
	end)
	createSlider(appearance, "Opacity curve start", 0, 3, state.opacityCurve.start, 0.01, function(v)
		state.opacityCurve.start = v
		scheduleApply()
	end, formatFloat, CURVE_SLIDER_COLOR)
	createSlider(appearance, "Opacity curve mid", 0, 3, state.opacityCurve.mid, 0.01, function(v)
		state.opacityCurve.mid = v
		scheduleApply()
	end, formatFloat, CURVE_SLIDER_COLOR)
	createSlider(appearance, "Opacity curve finish", 0, 3, state.opacityCurve.finish, 0.01, function(v)
		state.opacityCurve.finish = v
		scheduleApply()
	end, formatFloat, CURVE_SLIDER_COLOR)

	local updateSection = createSection("Update & LOD", false)
	local updateContent = updateSection:GetContent()
	createCheckbox(updateContent, "Simulate @ 30 FPS (interpolate)", state.targetFps == 30, function(value)
		state.targetFps = value and 30 or 60
		scheduleApply()
	end)



	createSlider(updateContent, "Visual update step", 1, 8, state.visualUpdateStep, 1, function(v)
		state.visualUpdateStep = math.clamp(math.floor(v + 0.5), 1, 8)
		scheduleApply()
	end, formatInteger)
	createSlider(updateContent, "Size update step", 1, 8, state.sizeUpdateStep, 1, function(v)
		state.sizeUpdateStep = math.clamp(math.floor(v + 0.5), 1, 8)
		scheduleApply()
	end, formatInteger)
	createCheckbox(updateContent, "Cull outside FOV", state.cullOutsideFov, function(value)
		state.cullOutsideFov = value
		scheduleApply()
	end)
	local lodFarSlider
	createSlider(updateContent, "LOD near", 0, 600, state.lodNear, 1, function(v)
		state.lodNear = math.max(0, math.floor(v + 0.5))
		if state.lodFar < state.lodNear then
			state.lodFar = state.lodNear
			if lodFarSlider then
				lodFarSlider:SetValue(state.lodFar)
			end
		end
		scheduleApply()
	end, formatInteger)
	lodFarSlider = createSlider(updateContent, "LOD far", 0, 1200, state.lodFar, 1, function(v)
		local desired = math.floor(v + 0.5)
		if desired < state.lodNear then
			desired = state.lodNear
		end
		state.lodFar = desired
		if lodFarSlider then
			lodFarSlider:SetValue(desired)
		end
		scheduleApply()
	end, formatInteger)

	-- Ensure color pickers reflect latest state when rebuilding
	baseColorPicker:SetColor(state.color)
	rangeMinPicker:SetColor(per.color.min)
	rangeMaxPicker:SetColor(per.color.max)
	startPicker:SetColor(state.colorCurve.start)
	midPicker:SetColor(state.colorCurve.mid)
	finishPicker:SetColor(state.colorCurve.finish)
end

-- Clone to bypass require() caching while preserving the authored module context.
local function requirePresetModuleFresh(module: ModuleScript)
	local clone = module:Clone()
	clone.Parent = module.Parent
	local ok, data = pcall(function()
		return require(clone)
	end)
	clone:Destroy()
	return ok, data
end

local function parsePresetModule(module)
	local source = RuntimeInstaller.readScriptSource(module)
	if typeof(source) ~= "string" or source:match("^%s*$") then
		return nil
	end
	local ok, data = requirePresetModuleFresh(module)
	if not ok then
		warn("[VoxelParticlesPlugin] Failed to load preset", module:GetFullName(), data)
		return nil
	end

	if typeof(data) == "function" then
		local success, result = pcall(data)
		if not success then
			warn("[VoxelParticlesPlugin] Preset factory failed", module:GetFullName(), result)
			return nil
		end
		data = result
	end

	if typeof(data) ~= "table" then
		warn("[VoxelParticlesPlugin] Preset module did not return a table", module:GetFullName())
		return nil
	end

	local state = defaultState()
	if typeof(data.state) == "table" then
		mergeInto(state, data.state)
	end
	if data.seed ~= nil then state.seed = data.seed end
	if data.enabled ~= nil then state.enabled = data.enabled and true or false end
	ensureStateIntegrity(state)

	return {
		module = module,
		displayName = data.displayName or data.name or module.Name,
		activationDistance = data.activationDistance,
		state = state,
	}
end


local function setSelectedPreset(item)
	selectedPresetItem = item
	if item and item.module then
		presetDropdown.Text = string.format("%s (%s)", item.displayName or item.module.Name, item.module.Name)
	else
		presetDropdown.Text = "Select existing preset"
	end
	updateStatus()
end

local function applyPresetItem(item, preserveDisplay)
	if not item then
		return
	end
	local newState = deepCopy(item.state)
	ensureStateIntegrity(newState)
	currentState = newState
	rebuildPanel(currentState)
	if not preserveDisplay then
		currentDisplayName = item.displayName or currentDisplayName or ""
	end
	displayNameBox.Text = currentDisplayName
	presetNameBox.Text = item.module.Name
	stateDirty = false
	updateEmitterInfo()
	updateStatus()
	applyPreview()

end

-- VoxelParticlesPlugin.lua
local function rebuildPresetDropdown()
	for _, child in ipairs(dropdownScroll:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	local items = {}
	for _, item in pairs(presetItems) do
		table.insert(items, item)
	end
	table.sort(items, function(a, b)
		local nameA = string.lower(a.displayName or a.module.Name)
		local nameB = string.lower(b.displayName or b.module.Name)
		if nameA == nameB then
			return a.module.Name < b.module.Name
		end
		return nameA < nameB
	end)

	for _, item in ipairs(items) do
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(1, 0, 0, 28)
		button.BackgroundColor3 = Color3.fromRGB(50, 50, 58)
		button.AutoButtonColor = true
		button.Font = Enum.Font.Gotham
		button.TextSize = 14
		button.TextColor3 = Color3.fromRGB(230, 230, 235)
		button.TextXAlignment = Enum.TextXAlignment.Left
		button.Text = string.format("%s (%s)", item.displayName or item.module.Name, item.module.Name)
		button.ZIndex = dropdownScroll.ZIndex + 1
		button.Parent = dropdownScroll
		button.MouseButton1Click:Connect(function()
			dropdownVisible = false
			dropdownOverlay.Visible = false
			-- выбираем...
			setSelectedPreset(item)
			-- ...и СРАЗУ ЖЕ применяем (авто-LOAD)
			applyPresetItem(item, false)
			-- закрепляем на эмиттере атрибуты пресета (для рантайм-биндера)
			if currentEmitter then
				local ok, err = pcall(function()
					recordChange("VoxelParticles.SelectPreset", "Select Voxel Preset", function()
						currentEmitter:SetAttribute(PRESET_ATTRIBUTE, item.module.Name)
						currentEmitter:SetAttribute(DISPLAY_ATTRIBUTE, currentDisplayName)
					end)
				end)
				if not ok then
					warn("[VoxelParticlesPlugin] Failed to record preset selection: ", err)
					statusLabel.Text = "Preset selection failed: " .. tostring(err)
				end
			end
		end)
	end

	dropdownOverlay.Visible = dropdownVisible and #items > 0
	if dropdownOverlay.Visible then
		updateDropdownOverlaySize()
	end
	if dropdownVisible and #items == 0 then
		dropdownVisible = false
	end
end


local function refreshPresetModule(module)
	local item = parsePresetModule(module)
	if item then
		presetItems[module] = item
	else
		presetItems[module] = nil
	end
	if selectedPresetItem and selectedPresetItem.module == module then
		setSelectedPreset(presetItems[module])
	end
	rebuildPresetDropdown()
	return presetItems[module]
end

local function unregisterPresetModule(module)
	local connections = presetConnections[module]
	if connections then
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
	end
	presetConnections[module] = nil
	if selectedPresetItem and selectedPresetItem.module == module then
		setSelectedPreset(nil)
	end
	presetItems[module] = nil
	rebuildPresetDropdown()
end

local function registerPresetModule(module)
	if not module:IsA("ModuleScript") then
		return
	end
	local connections = presetConnections[module]
	if connections then
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
	end
	presetConnections[module] = {}
	refreshPresetModule(module)
	local function connect(signal)
		local conn = signal:Connect(function()
			refreshPresetModule(module)
		end)
		table.insert(presetConnections[module], conn)
	end
	connect(module:GetPropertyChangedSignal("Name"))
	connect(module:GetPropertyChangedSignal("Source"))
	connect(module.AncestryChanged)
end


-- Санитайзер: приводит state к сериализуемому виду (EnumItem и т.п.)
local function sanitizeStateForSave(state)
	-- Прогоняем через ensureStateIntegrity, чтобы старые пресеты получили
	-- новые поля (например distanceSpeedFactor) ещё до сериализации.
	ensureStateIntegrity(state)

	-- Материал: только EnumItem
	if typeof(state.material) ~= "EnumItem" then
		state.material = Enum.Material.Neon
	end
	-- Перечисления формы спавна
	local okShape = false
	for _, s in ipairs(SHAPES) do
		if state.spawnShape == s then
			okShape = true
			break
		end
	end
	if not okShape then
		state.spawnShape = "point"
	end
	state.distanceSpeedFactor = math.clamp(tonumber(state.distanceSpeedFactor) or 0, -10, 10)
	-- Диапазоны: min<=max
	local function clampRange(r, lo, hi)
		if typeof(r) == "table" and typeof(r.min) == "number" and typeof(r.max) == "number" then
			if r.min > r.max then r.min, r.max = r.max, r.min end
			r.min = math.clamp(r.min, lo, hi)
			r.max = math.clamp(r.max, lo, hi)
		end
	end
	clampRange(state.perParticle.speed, 0, 1e6)
	clampRange(state.perParticle.life, 0.001, 1e3)
	clampRange(state.perParticle.angle, -360, 360)
	clampRange(state.perParticle.size, 0, 1e3)
	clampRange(state.perParticle.rotationX, -10000, 10000)
	clampRange(state.perParticle.rotationY, -10000, 10000)
	clampRange(state.perParticle.rotationZ, -10000, 10000)
	clampRange(state.perParticle.opacity, 0, 1)
	state.burstCount = math.max(0, math.floor(tonumber(state.burstCount) or 0))

	-- Цвета: только Color3
	local function coerceColor3(v)
		if typeof(v) == "Color3" then return v end
		return Color3.new(1,1,1)
	end
	if state.perParticle and state.perParticle.color then
		state.perParticle.color.min = coerceColor3(state.perParticle.color.min)
		state.perParticle.color.max = coerceColor3(state.perParticle.color.max)
	end
	state.color = coerceColor3(state.color)
	if state.colorCurve then
		state.colorCurve.start = coerceColor3(state.colorCurve.start)
		state.colorCurve.mid = coerceColor3(state.colorCurve.mid)
		state.colorCurve.finish = coerceColor3(state.colorCurve.finish)
	end
	-- Гарантировать числовые Seeds если не наследуем
	local function coerceSeed(field, storeField)
		if state[field] ~= nil then
			state[field] = tonumber(state[field]) or 0
		end
		state[storeField] = tonumber(state[storeField]) or 0
	end
	coerceSeed("seed", "_seedValue")
	coerceSeed("rateNoiseSeed", "_rateNoiseSeedValue")
	coerceSeed("lifeNoiseSeed", "_lifeNoiseSeedValue")
	coerceSeed("sizeNoiseSeed", "_sizeNoiseSeedValue")
	coerceSeed("steerNoiseSeed", "_steerNoiseSeedValue")
	-- NEW: FPS только 30 или 60
	local fps = tonumber(state.targetFps)
	state.targetFps = (fps == 30) and 30 or 60
	validateSpawnState(state)

	return state
end


local serializeValue

local function buildModuleSource(moduleName, displayName, state)
	-- сериализуемое состояние
	local safeState = sanitizeStateForSave(deepCopy(state))

	-- собираем исходник модуля так, чтобы был ровно ОДИН return
	local lines = {
		"-- Auto-generated by Voxel Particles Plugin",
		"return {",
	}
	local indentTable = "        "
	local function addField(key, value)
		if value == nil then return end
		table.insert(lines, indentTable .. key .. " = " .. serializeValue(value, 1) .. ",")
	end

	addField("name", moduleName)
	addField("displayName", displayName)

	addField("seed", safeState.seed)
	addField("enabled", safeState.enabled)
	addField("state", safeState)

	table.insert(lines, "}")

	return table.concat(lines, "\n") .. "\n"
end


-- VoxelParticlesPlugin.lua
local function ensureDefaultPreset()
	if not runtimePrepared or not presetsFolder then
		error("Voxel Particles runtime is not initialized")
	end
	local mod = presetsFolder:FindFirstChild(DEFAULT_PRESET_NAME)
	if not mod then
		error("Bundled Default preset is missing; use Update project")
	end
	if not mod:IsA("ModuleScript") then
		error(("Default preset must be a ModuleScript, got %s"):format(mod.ClassName))
	end
	return mod
end




local function setCurrentEmitter(emitter)
	if not runtimePrepared then
		emitter = nil
	end
	if emitter == currentEmitter then
		updateEmitterInfo()
		return
	end
	clearEmitterConnections()
	currentEmitter = emitter
	dropdownVisible = false
	dropdownOverlay.Visible = false
	closeColorPicker()

	if not emitter or not emitter.Parent then
		currentDisplayName = ""
		displayNameBox.Text = ""
		presetNameBox.Text = ""
		setSelectedPreset(nil)
		currentState = defaultState()
		ensureStateIntegrity(currentState)
		rebuildPanel(currentState)
		destroyPreview()

		stateDirty = false
		updateEmitterInfo()
		updateStatus()
		return

	end

	local attrDisplay = emitter:GetAttribute(DISPLAY_ATTRIBUTE)
	if typeof(attrDisplay) == "string" and attrDisplay ~= "" then
		currentDisplayName = attrDisplay
	else
		currentDisplayName = emitter.Name
	end
	displayNameBox.Text = currentDisplayName

	local attrPreset = emitter:GetAttribute(PRESET_ATTRIBUTE)
	local applied = false
	if typeof(attrPreset) == "string" and attrPreset ~= "" then
		presetNameBox.Text = attrPreset
		local module = presetsFolder:FindFirstChild(attrPreset)
		if module and module:IsA("ModuleScript") then
			local item = presetItems[module] or refreshPresetModule(module)
			if item then
				setSelectedPreset(item)
				applyPresetItem(item, true)
				applied = true
			end
		end
	end

	if not applied then
		-- Preview Default without mutating selection merely because it was inspected.
		local defMod = ensureDefaultPreset()
		local defItem = presetItems[defMod] or refreshPresetModule(defMod)
		setSelectedPreset(defItem)
		presetNameBox.Text = defMod.Name

		-- дефолтное состояние даже если defItem вдруг ещё не распарсился
		currentState = deepCopy(defItem and defItem.state or defaultState())
		ensureStateIntegrity(currentState)
		rebuildPanel(currentState)
		stateDirty = false
		applyPreview()
	end



	updateEmitterInfo()
	updateStatus()

	table.insert(emitterConnections, emitter:GetPropertyChangedSignal("CFrame"):Connect(function()
		updateEmitterInfo()
		applyPreview()
	end))

	table.insert(emitterConnections, emitter.AncestryChanged:Connect(function(_, parent)
		if not parent then
			setCurrentEmitter(nil)
		else
			updateEmitterInfo()

		end
	end))
	applyPreview()

end

local function formatNumberForSource(value)
	if math.abs(value) < 1e-7 then
		value = 0
	end
	local formatted = string.format("%.6f", value)
	formatted = formatted:gsub("0+$", ""):gsub("%.$", "")
	if formatted == "" then
		formatted = "0"
	end
	return formatted
end

serializeValue = function(value, indent)
	indent = indent or 0
	local t = typeof(value)

	if t == "number" then
		return formatNumberForSource(value)

	elseif t == "boolean" then
		return value and "true" or "false"

	elseif t == "string" then
		return string.format("%q", value)

	elseif t == "Vector3" then
		return string.format(
			"Vector3.new(%s, %s, %s)",
			formatNumberForSource(value.X),
			formatNumberForSource(value.Y),
			formatNumberForSource(value.Z)
		)

	elseif t == "Color3" then
		local r = math.clamp(math.floor(value.R * 255 + 0.5), 0, 255)
		local g = math.clamp(math.floor(value.G * 255 + 0.5), 0, 255)
		local b = math.clamp(math.floor(value.B * 255 + 0.5), 0, 255)
		return string.format("Color3.fromRGB(%d, %d, %d)", r, g, b)

	elseif t == "EnumItem" then
		-- Внимание: в новом Studio нет EnumType.Name
		local enumTypeStr = tostring(value.EnumType):match("Enum%.(.+)$") or "Material"
		return string.format("Enum.%s.%s", enumTypeStr, value.Name)

	elseif t == "CFrame" then
		local comps = { value:GetComponents() }
		for i, c in ipairs(comps) do
			comps[i] = formatNumberForSource(c)
		end
		return "CFrame.new(" .. table.concat(comps, ", ") .. ")"

	elseif t == "table" then
		-- массив?
		local isArray, maxIndex = true, 0
		for k in pairs(value) do
			if typeof(k) ~= "number" or k % 1 ~= 0 or k <= 0 then
				isArray = false
				break
			end
			if k > maxIndex then maxIndex = k end
		end
		if isArray then
			local entries = table.create(maxIndex)
			for i = 1, maxIndex do
				entries[i] = serializeValue(value[i], indent + 1)
			end
			return "{" .. table.concat(entries, ", ") .. "}"
		end

		-- словарь
		local keys = {}
		for k in pairs(value) do table.insert(keys, k) end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

		local indentStr   = string.rep("        ", indent)
		local childIndent = string.rep("        ", indent + 1)
		local lines = {}
		for _, k in ipairs(keys) do
			local keyText
			if typeof(k) == "string" and k:match("^[%a_][%w_]*$") then
				keyText = k
			else
				keyText = "[" .. serializeValue(k, indent + 1) .. "]"
			end
			local valueText = serializeValue(value[k], indent + 1)
			table.insert(lines, childIndent .. keyText .. " = " .. valueText .. ",")
		end
		return "{\n" .. table.concat(lines, "\n") .. "\n" .. indentStr .. "}"

	elseif value == nil then
		return "nil"
	else
		error(("Unsupported value type: %s"):format(t))
	end
end






saveCurrentPreset = function()
	if isPlayMode() then
		statusLabel.Text = "Play mode: presets are read-only."
		return
	end
	if not runtimePrepared or not presetsFolder then
		statusLabel.Text = "Initialize or update the project runtime first."
		return
	end

	if not currentEmitter then
		statusLabel.Text = "Select an emitter before saving."
		return
	end

	if not selectedPresetItem or not selectedPresetItem.module then
		statusLabel.Text = "Select or create a preset before saving."
		return
	end
	if RuntimeInstaller.isFileSynced(selectedPresetItem.module) then
		statusLabel.Text = "Preview only: native Script Sync owns this preset. Save through its disk file."
		return
	end
	local moduleName = selectedPresetItem.module.Name
	currentDisplayName = selectedPresetItem.displayName or moduleName


	local module = presetsFolder:FindFirstChild(moduleName)
	if module and not module:IsA("ModuleScript") then
		statusLabel.Text = ("Save blocked: %s already exists as %s."):format(moduleName, module.ClassName)
		return
	end

	-- Build source before opening an undo recording so validation is mutation-free.
	local ok, sourceOrErr = pcall(function()
		return buildModuleSource(moduleName, currentDisplayName, currentState)
	end)
	if not ok then
		warn("[VoxelParticlesPlugin] Failed to build preset source: ", sourceOrErr)
		statusLabel.Text = "Save failed: " .. tostring(sourceOrErr)
		return
	end

	local savedModule = module
	local saved, saveError = pcall(function()
		recordChange("VoxelParticles.SavePreset", "Save Voxel Preset", function()
			local createdModule = false
			if not savedModule then
				savedModule = Instance.new("ModuleScript")
				savedModule.Name = moduleName
				savedModule.Parent = presetsFolder
				createdModule = true
			end
			local sourceUpdated, sourceError = pcall(RuntimeInstaller.writeScriptSource, savedModule, sourceOrErr)
			if not sourceUpdated then
				if createdModule then
					savedModule:Destroy()
				end
				error(sourceError, 0)
			end
			currentEmitter:SetAttribute(PRESET_ATTRIBUTE, moduleName)
			currentEmitter:SetAttribute(DISPLAY_ATTRIBUTE, currentDisplayName)
		end)
	end)
	if not saved then
		warn("[VoxelParticlesPlugin] Failed to save preset: ", saveError)
		statusLabel.Text = "Save failed: " .. tostring(saveError)
		return
	end

	stateDirty = false
	local item = refreshPresetModule(savedModule)
	setSelectedPreset(item)
	updateStatus()
end

local function isEmitterPart(instance: Instance): boolean
	if not instance:IsA("BasePart") then
		return false
	end
	if instance.Name == EMITTER_NAME then
		return true
	end
	local hasPreset = instance:GetAttribute(PRESET_ATTRIBUTE)
	local hasDisplay = instance:GetAttribute(DISPLAY_ATTRIBUTE)
	return hasPreset ~= nil or hasDisplay ~= nil
end

local function resolveSelectionEmitter(): BasePart?
	local selection = Selection:Get()
	for _, instance in ipairs(selection) do
		if isEmitterPart(instance) then
			return instance
		elseif instance:IsA("Model") then
			for _, descendant in ipairs(instance:GetDescendants()) do
				if isEmitterPart(descendant) then
					return descendant
				end
			end
		end
	end
	return nil
end



-- === Create emitter helper ===
createEmitterAtCenter = function()
	if isPlayMode() then
		statusLabel.Text = "Play mode: emitters cannot be created."
		return
	end
	if not runtimePrepared then
		statusLabel.Text = "Initialize or update the project runtime first."
		return
	end

	local ok, partOrError = pcall(function()
		return recordChange("VoxelParticles.CreateEmitter", "Create Voxel Emitter", function()
			local part = Instance.new("Part")
			part.Name = EMITTER_NAME
			part.Size = Vector3.new(0.1, 0.1, 0.1)
			part.Material = Enum.Material.Neon
			part.Color = Color3.new(1, 1, 1)
			part.Anchored = true
			part.CanCollide = false
			part.CFrame = CFrame.new(0, 0, 0)
			part:SetAttribute(PRESET_ATTRIBUTE, DEFAULT_PRESET_NAME)
			part:SetAttribute(DISPLAY_ATTRIBUTE, DEFAULT_DISPLAY_NAME)
			CollectionService:AddTag(part, EMITTER_NAME)
			part.Parent = Workspace
			return part
		end)
	end)
	if not ok then
		warn("[VoxelParticlesPlugin] Failed to create emitter: ", partOrError)
		statusLabel.Text = "Create emitter failed: " .. tostring(partOrError)
		return
	end
	local part = partOrError

	Selection:Set({part})
	setCurrentEmitter(part)

	statusLabel.Text = string.format("Emitter created: %s", part:GetFullName())
end

-- === Live preview of VoxelParticleSystem in Studio ===
destroyPreview = function()
	if previewEmitter then
		pcall(function() previewEmitter:Destroy() end)
		previewEmitter = nil
	end

	lastPreviewAnchorCFrame = nil
end

applyPreview = function()
	-- Do not run editor preview during Play or outside client edit context; runtime binder handles effects.
	if isPlayMode() or not RunService:IsClient() then
		destroyPreview()
		return
	end

	if not previewPlaying then
		destroyPreview()
		return
	end

	-- Без валидного эмиттера превью не нужно
	if not currentEmitter or not currentEmitter.Parent then
		destroyPreview()
		return
	end

	-- Собираем и валидируем конфиг до изменения живого preview-emitter.
	local configOk, cfgOrError = pcall(buildConfig, currentState)
	if not configOk then
		statusLabel.Text = "Preview error: " .. tostring(cfgOrError)
		return
	end
	local cfg = cfgOrError
	-- emissionDirection остаётся ЛОКАЛЬНЫМ (в осях эмиттера),
	-- ядро само переведёт его в мир по CFrame якоря.
	pcall(function()
		VPS.SetTargetFps((currentState.targetFps == 30) and 30 or 60)
	end)


	-- Создание или обновление эмиттера
	if not previewEmitter then
		local ok, res = pcall(function()
			return VPS.Attach(currentEmitter, cfg)
		end)
		if ok then
			previewEmitter = res
		else
			statusLabel.Text = "Preview error: " .. tostring(res)
			return
		end
	else
		pcall(function() previewEmitter:SetAnchor(currentEmitter) end)
		local configured, configureError = pcall(function() previewEmitter:Configure(cfg) end)
		if not configured then
			statusLabel.Text = "Preview error: " .. tostring(configureError)
			return
		end
	end

	-- Синхронизация флага включения
	pcall(function() previewEmitter:SetEnabled(currentState.enabled) end)

	lastPreviewAnchorCFrame = currentEmitter.CFrame
end

local function updatePreviewDirection()
	if isPlayMode() then
		lastPreviewAnchorCFrame = nil
		return
	end

	if not (previewPlaying and previewEmitter) then
		return
	end

	local anchor = currentEmitter
	if not (anchor and anchor.Parent) then
		lastPreviewAnchorCFrame = nil
		return
	end

	local anchorCFrame = anchor.CFrame
	if lastPreviewAnchorCFrame and anchorCFrame == lastPreviewAnchorCFrame then
		return
	end

	lastPreviewAnchorCFrame = anchorCFrame
	local dir = worldEmissionDirection(anchor, (currentState and currentState.emissionDirection) or Vector3.new(0, 1, 0))
	pcall(function()
		previewEmitter.emissionDirection = dir
	end)
end

presetDropdown.MouseButton1Click:Connect(function()
	if isPlayMode() then
		statusLabel.Text = "Play mode: presets cannot be changed."
		return
	end

	dropdownVisible = not dropdownVisible
	rebuildPresetDropdown()
end)


UserInputService.InputBegan:Connect(function(input)
	if dropdownVisible and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
		local pointer
		if widget and widget:IsA("PluginGui") then
			local relative = widget:GetRelativeMousePosition()
			pointer = Vector2.new(relative.X + widget.AbsolutePosition.X, relative.Y + widget.AbsolutePosition.Y)
		else
			local pos = input.Position
			if typeof(pos) == "Vector3" then
				pointer = Vector2.new(pos.X, pos.Y)
			elseif typeof(pos) == "Vector2" then
				pointer = pos
			else
				local mouse = UserInputService:GetMouseLocation()
				pointer = Vector2.new(mouse.X, mouse.Y)
			end
		end

		local overlayPos = dropdownOverlay.AbsolutePosition
		local overlaySize = dropdownOverlay.AbsoluteSize
		local withinOverlay = pointer.X >= overlayPos.X and pointer.X <= overlayPos.X + overlaySize.X
			and pointer.Y >= overlayPos.Y and pointer.Y <= overlayPos.Y + overlaySize.Y
		local buttonPos = presetDropdown.AbsolutePosition
		local buttonSize = presetDropdown.AbsoluteSize
		local withinButton = pointer.X >= buttonPos.X and pointer.X <= buttonPos.X + buttonSize.X
			and pointer.Y >= buttonPos.Y and pointer.Y <= buttonPos.Y + buttonSize.Y
		if not withinOverlay and not withinButton then
			dropdownVisible = false
			dropdownOverlay.Visible = false
		end
	end
end)

displayNameBox.FocusLost:Connect(function()
	if isPlayMode() then
		displayNameBox.Text = currentDisplayName
		return
	end

	local text = trim(displayNameBox.Text)
	if text ~= currentDisplayName then
		currentDisplayName = text
		if currentEmitter then
			markDirty()
		end
	end
	displayNameBox.Text = currentDisplayName
end)

presetNameBox.FocusLost:Connect(function()
	if isPlayMode() then
		if selectedPresetItem and selectedPresetItem.module then
			presetNameBox.Text = selectedPresetItem.module.Name
		else
			presetNameBox.Text = ""
		end
		return
	end

	local previous = presetNameBox.Text
	local text = trim(previous)
	if text ~= previous then
		presetNameBox.Text = text
	end
	if currentEmitter and text ~= "" then
		local selectedName = selectedPresetItem and selectedPresetItem.module.Name or nil
		if selectedName ~= text then
			markDirty()
		end
	end
	updateStatus()
end)



-- New preset button
local newPresetBtn = createButton(actionsRow, "New preset", function()
	if isPlayMode() then
		statusLabel.Text = "Play mode: presets are read-only."
		return
	end
	if not runtimePrepared or not presetsFolder then
		statusLabel.Text = "Initialize or update the project runtime first."
		return
	end
	if RuntimeInstaller.isFileSynced(presetsFolder) then
		statusLabel.Text = "Native Script Sync owns this preset folder. Create presets through its disk source."
		return
	end

	namePromptOpen(function(name)
		if not name or name == "" then return end
		name = name:gsub("^%s*(.-)%s*$", "%1")
		if name == "" then return end

		if presetsFolder:FindFirstChild(name) then
			statusLabel.Text = ("Preset '%s' already exists."):format(name)
			return
		end

		local fromState = currentState and deepCopy(currentState) or defaultState()
		local ok, srcOrErr = pcall(function()
			return buildModuleSource(name, name, fromState)
		end)
		if not ok then
			statusLabel.Text = "Create failed: " .. tostring(srcOrErr)
			return
		end

		local mod = nil
		local created, createError = pcall(function()
			recordChange("VoxelParticles.CreatePreset", "Create Voxel Preset", function()
				mod = Instance.new("ModuleScript")
				mod.Name = name
				mod.Parent = presetsFolder
				local sourceUpdated, sourceError = pcall(RuntimeInstaller.writeScriptSource, mod, srcOrErr)
				if not sourceUpdated then
					mod:Destroy()
					error(sourceError, 0)
				end
				if currentEmitter then
					currentEmitter:SetAttribute(PRESET_ATTRIBUTE, name)
					currentEmitter:SetAttribute(DISPLAY_ATTRIBUTE, name)
				end
			end)
		end)
		if not created then
			warn("[VoxelParticlesPlugin] Failed to create preset: ", createError)
			statusLabel.Text = "Create failed: " .. tostring(createError)
			return
		end

		-- Parse only after ScriptEditorService has committed the new source.
		local item = refreshPresetModule(mod)
		setSelectedPreset(item)
		statusLabel.Text = ("Preset created: %s"):format(name)
	end)
end)

newPresetBtn.Parent = actionsRow

local textBoxBaseColor = displayNameBox.BackgroundColor3
local presetDropdownBaseColor = presetDropdown.BackgroundColor3
local createEmitterBaseColor = createEmitterBtn.BackgroundColor3
local newPresetBaseColor = newPresetBtn.BackgroundColor3

refreshRunModeControls = function(playMode)
	local editable = not playMode and runtimePrepared
	local presetFolderWritable = editable and presetsFolder ~= nil and not RuntimeInstaller.isFileSynced(presetsFolder)
	local selectedModule = selectedPresetItem and selectedPresetItem.module
	local presetSourceWritable = presetFolderWritable
		and not (selectedModule and RuntimeInstaller.isFileSynced(selectedModule))

	displayNameBox.TextEditable = presetSourceWritable
	displayNameBox.Active = presetSourceWritable
	displayNameBox.Selectable = presetSourceWritable
	displayNameBox.BackgroundColor3 = presetSourceWritable and textBoxBaseColor or DISABLED_COLOR

	presetNameBox.TextEditable = presetSourceWritable
	presetNameBox.Active = presetSourceWritable
	presetNameBox.Selectable = presetSourceWritable
	presetNameBox.BackgroundColor3 = presetSourceWritable and textBoxBaseColor or DISABLED_COLOR

	setButtonEnabled(presetDropdown, presetDropdownBaseColor, editable)
	setButtonEnabled(createEmitterBtn, createEmitterBaseColor, editable)
	newPresetBtn.Text = presetFolderWritable and "New preset" or "Disk-owned"
	setButtonEnabled(newPresetBtn, newPresetBaseColor, presetFolderWritable)
	setButtonEnabled(playbackButton, previewPlaying and STOP_COLOR or SAVE_COLOR, editable)
	if burstButton then setButtonEnabled(burstButton, Color3.fromRGB(90, 140, 255), editable) end
	if playMode then
		initializeProjectBtn.Active = false
		initializeProjectBtn.Selectable = false
		initializeProjectBtn.AutoButtonColor = false
		initializeProjectBtn.BackgroundColor3 = DISABLED_COLOR
	elseif currentRuntimeStatus then
		initializeProjectBtn.Active = not runtimePrepared
		initializeProjectBtn.Selectable = not runtimePrepared
		initializeProjectBtn.AutoButtonColor = not runtimePrepared
		if currentRuntimeStatus.blocked then
			initializeProjectBtn.BackgroundColor3 = Color3.fromRGB(190, 75, 75)
		elseif runtimePrepared then
			initializeProjectBtn.BackgroundColor3 = SAVE_COLOR
		else
			initializeProjectBtn.BackgroundColor3 = Color3.fromRGB(90, 140, 255)
		end
	end
	updatePlaybackButton()
	updateBurstButton()
	if scroll then
		scroll.Active = editable
	end

	if not editable then
		dropdownVisible = false
		dropdownOverlay.Visible = false
		closeColorPicker()
		-- Безопасно гасим burst-цикл при переходе в Play
		if burstLoopActive then
			burstLoopActive = false
			updateBurstButton()
		end
	end
end


toggleButton.Click:Connect(function()
	local enabling = not widget.Enabled
	widget.Enabled = enabling
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
	if not widget.Enabled then
		if burstLoopActive then burstLoopActive = false; updateBurstButton() end

		dropdownVisible = false
		dropdownOverlay.Visible = false
		closeColorPicker()
		destroyPreview()
	else
		if isEditMode() then
			applyPreview()
		end
	end

end)

-- Keep lifecycle-only state in its own function so the large editor chunk stays
-- comfortably below Luau's per-function local-variable limit.
;(function()
local activePresetFolder = nil
local presetFolderConnections = {}

bindPresetFolder = function(folder)
	if folder == activePresetFolder then
		return
	end
	for _, connection in ipairs(presetFolderConnections) do
		connection:Disconnect()
	end
	table.clear(presetFolderConnections)

	local registered = {}
	for module in pairs(presetConnections) do
		table.insert(registered, module)
	end
	for _, module in ipairs(registered) do
		unregisterPresetModule(module)
	end
	activePresetFolder = folder
	if not folder then
		setSelectedPreset(nil)
		return
	end

	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("ModuleScript") then
			registerPresetModule(child)
		end
	end
	table.insert(presetFolderConnections, folder.ChildAdded:Connect(function(child)
		if child:IsA("ModuleScript") then
			registerPresetModule(child)
		end
	end))
	table.insert(presetFolderConnections, folder.ChildRemoved:Connect(function(child)
		if child:IsA("ModuleScript") then
			unregisterPresetModule(child)
		end
	end))

	local defaultModule = folder:FindFirstChild(DEFAULT_PRESET_NAME)
	if defaultModule and defaultModule:IsA("ModuleScript") then
		setSelectedPreset(presetItems[defaultModule] or refreshPresetModule(defaultModule))
	end
end

local selectionConnection = Selection.SelectionChanged:Connect(function()
	setCurrentEmitter(resolveSelectionEmitter())
end)

toggleButton:SetActive(widget.Enabled)

local lastPlayModeState = nil
local function refreshPlayModeState(force)
	local playMode = isPlayMode()

	if not force and playMode == lastPlayModeState then
		return
	end

	lastPlayModeState = playMode
	dropdownVisible = false
	dropdownOverlay.Visible = false
	closeColorPicker()

	if playMode then
		if burstLoopActive then burstLoopActive = false; updateBurstButton() end

		destroyPreview()
	else
		if widget.Enabled then
			applyPreview()
		end
	end

	updateStatus()
end

local renderConnection = RunService.RenderStepped:Connect(function()
	updatePreviewDirection()
end)

local heartbeatConnection = RunService.Heartbeat:Connect(function()
	refreshPlayModeState(false)
end)

refreshRuntimeInspection()
refreshPlayModeState(true)
setCurrentEmitter(resolveSelectionEmitter())
updateStatus()
updatePlaybackButton()

plugin.Unloading:Connect(function()
	stopBurstLoop()
	destroyPreview()
	clearEmitterConnections()
	selectionConnection:Disconnect()
	renderConnection:Disconnect()
	heartbeatConnection:Disconnect()
	for _, connection in ipairs(presetFolderConnections) do
		connection:Disconnect()
	end
	table.clear(presetFolderConnections)
	local registered = {}
	for module in pairs(presetConnections) do
		table.insert(registered, module)
	end
	for _, module in ipairs(registered) do
		unregisterPresetModule(module)
	end
end)
end)()
