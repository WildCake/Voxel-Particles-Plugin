-- ReplicatedStorage/Shared/VoxelParticleSystem.lua
-- Гибкая система воксельных (кубических) партиклов для клиентской отрисовки.
-- version 16

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local VoxelCubicBezier = require(script.Parent:WaitForChild("VoxelCubicBezier"))
local VoxelCylinderStream = require(script.Parent:WaitForChild("VoxelCylinderStream"))
local VoxelFairShareAllocator = require(script.Parent:WaitForChild("VoxelFairShareAllocator"))
local VoxelMotionIntegrator = require(script.Parent:WaitForChild("VoxelMotionIntegrator"))
local ClientVfxQuality = if RunService:IsClient() then require(script.Parent:WaitForChild("ClientVfxQuality")) else nil

local VISIBILITY_POLL_INTERVAL = 0.14
local LOS_IGNORE_ATTRIBUTE = "VoxelIgnoreModel"
local LOS_IGNORE_TAG = "IgnoreLOS"

local _LOS_FILTER = table.create(16)

local function _buildLosFilter(anchor: BasePart): {Instance}
	local count = 1
	_LOS_FILTER[count] = anchor

	local parent = anchor.Parent
	if parent and parent.Parent then
		count += 1
		_LOS_FILTER[count] = parent
	end

	local ignoreValue = anchor:FindFirstChild(LOS_IGNORE_ATTRIBUTE)
	if ignoreValue and ignoreValue:IsA("ObjectValue") then
		local ignore = ignoreValue.Value
		if ignore and ignore.Parent then
			count += 1
			_LOS_FILTER[count] = ignore
		end
	end

	for _, plr in ipairs(Players:GetPlayers()) do
		local character = plr.Character
		if character and character.Parent then
			count += 1
			_LOS_FILTER[count] = character
		end
	end

	local tagged = CollectionService:GetTagged(LOS_IGNORE_TAG)
	for i = 1, #tagged do
		local instance = tagged[i]
		if instance and instance.Parent then
			count += 1
			_LOS_FILTER[count] = instance
		end
	end

	for i = count + 1, #_LOS_FILTER do
		_LOS_FILTER[i] = nil
	end

	return _LOS_FILTER
end

-- === Performance & Noise config =========================================
-- Пер-эмиттерный режим FPS (30 или 60). Глобальной частоты больше нет.
local SIM_STEP_30 = 1/30
local SIM_STEP_60 = 1/60
-- ограничители от «спирали смерти» и бёрстов

local MAX_SUBSTEPS_PER_FRAME = 2   -- не более 2 сим‑шагов за один кадр
local MAX_SPAWN_PER_FRAME    = 96  -- combined burst/rate ceiling per emitter at High
local MAX_POOLED_PART_CREATIONS_PER_FRAME = 8
local _frameSerial = 0
-- [ADD LINES] — маска первого появления
local UNMASK_FRAMES = 2
local _UNMASK_AT = setmetatable({} :: {[BasePart]: number}, {__mode = "k"}) -- part -> frameToUnmask




-- Приближение к лимиту частиц, после которого режем rate/burst
local ADAPTIVE_THRESHOLD = 0.50 -- 50%

-- Быстрый «волновой» шум вместо
local _WAVE_RES = 256
local _WAVE = table.create(_WAVE_RES)
do
	local twoPi = 2 * math.pi
	for i = 1, _WAVE_RES do
		_WAVE[i] = math.sin((i - 1)/_WAVE_RES * twoPi)
	end
end

local function waveNoise(t: number, seed: number?): number
	-- Псевдошум [-1..1], детерминированный, периодический; seed сдвигает фазу
	local phase = t + ((seed or 0) * 0.001)
	phase = phase - math.floor(phase)              -- frac
	local f = phase * _WAVE_RES
	local i = math.floor(f)
	local frac = f - i
	local i0 = (i % _WAVE_RES) + 1
	local i1 = ((i + 1) % _WAVE_RES) + 1
	local a = _WAVE[i0]
	local b = _WAVE[i1]
	return a + (b - a) * frac
end
-- ==== 32-slot cache for waveNoise =======================================
local _WN_SIZE = 32
local _WN_KEYS = table.create(_WN_SIZE)
local _WN_VALS = table.create(_WN_SIZE)

local function _u32(n:number): number
	return bit32.band(n, 0xFFFFFFFF)
end



-- лёгкий «без умножений» хеш для индексации слотов
local function _hash32_fast(x:number): number
	x = _u32(x + 0x9E3779B9)
	x = bit32.bxor(x, bit32.rshift(x, 16))
	x = _u32(x + bit32.lshift(x, 3))
	x = bit32.bxor(x, bit32.rshift(x, 11))
	return _u32(x)
end
local _hash32 -- forward declaration: реализация ниже в разделе PRNG
local function waveNoiseCached(t:number, seed:number?): number
	-- waveNoise периодичен по frac(t), квантуем её в 32 ведра
	local tb = bit32.band(math.floor(t * 32), 31)         -- 0..31
	local sb = _hash32(_u32(seed or 0))                   -- хешируем весь сид (нужен forward-declare)
	local key = _u32(bit32.lshift(bit32.band(sb, 0xFFFF), 5) + tb)
	local slot = bit32.band(_hash32_fast(key), (_WN_SIZE - 1)) + 1
	if _WN_KEYS[slot] ~= key then
		_WN_KEYS[slot] = key
		_WN_VALS[slot] = waveNoise(t, seed)
	end
	return _WN_VALS[slot]

end
-- ==== LUT-32 для равномерного угла phi ==================================
local _LUT_N = 32
local _SIN_LUT = table.create(_LUT_N)
local _COS_LUT = table.create(_LUT_N)
do
	for i = 1, _LUT_N do
		local phi = 2*math.pi * (i-1)/_LUT_N
		_SIN_LUT[i] = math.sin(phi)
		_COS_LUT[i] = math.cos(phi)
	end
end


export type Range = {min: number?, max: number?} | {number} | number

local function ensureFolder(parent: Instance, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local VoxelParticleSystem = {}
-- [DEPRECATED] Глобальный FPS убран. Оставляем API как установку дефолта
-- для новых эмиттеров (если в конфиге нет targetFps).
local DEFAULT_EMITTER_FPS = 60
function VoxelParticleSystem.SetTargetFps(fps: number)
	DEFAULT_EMITTER_FPS = (fps == 30) and 30 or 60
end

VoxelParticleSystem.__index = VoxelParticleSystem

local Emitter = {}
Emitter.__index = Emitter
type EmitterInstance = typeof(setmetatable({} :: {[string]: any}, Emitter))
-- Контейнеры системы
local ACTIVE_FOLDER = ensureFolder(Workspace, "VoxelParticles")
local LIVE_FOLDER   = ensureFolder(ACTIVE_FOLDER, "Live")

-- Режим хранения «спящих» частиц:
--   "workspace"  — Folder в Workspace (как сейчас)
--   "replicated" — Folder в ReplicatedStorage (вне мира, удобно наблюдать)
--   "nil"        — Parent=nil (самый «лёгкий» для движка)
local POOL_MODE: "workspace" | "replicated" | "nil" = "nil"

local POOL_FOLDER: Instance? = nil
do
	if POOL_MODE == "workspace" then
		POOL_FOLDER = ensureFolder(ACTIVE_FOLDER, "Pool")
	elseif POOL_MODE == "replicated" then
		local root = ensureFolder(ReplicatedStorage, "VoxelParticlesPool")
		POOL_FOLDER = ensureFolder(root, "Pool")
	else
		-- "nil" режим: храним ссылки в массиве, Parent у «спящих» = nil
		POOL_FOLDER = nil
	end
end


local _baseMaxTotalParticles = 512
local MAX_TOTAL_PARTICLES = _baseMaxTotalParticles
local MAX_ACTIVE_EMITTERS_HIGH = 15
local maxActiveEmitters = MAX_ACTIVE_EMITTERS_HIGH

local _qualityMultiplier = 1
local _qualityConnections = table.create(0)
local _qualitySignalsConnected = false




local pool: {BasePart} = {}
local liveCount = 0
local partCreationsThisFrame = 0
local spawnsThisFrame = 0
local frameSpawnLimit = 0

local function _budgetMul(): number
	local limit = MAX_TOTAL_PARTICLES
	if limit <= 0 then return 1 end
	local ratio = liveCount / limit
	if ratio <= ADAPTIVE_THRESHOLD then
		return 1
	end
	-- Плавно сжимаем rate/burst от 100% до 0% на интервале [threshold .. 1]
	local k = 1 - (ratio - ADAPTIVE_THRESHOLD) / (1 - ADAPTIVE_THRESHOLD)
	if k < 0 then k = 0 end
	return k
end

local particles = {} :: {any}
local emitters = {} :: {EmitterInstance}
local selectedEmitters = table.create(MAX_ACTIVE_EMITTERS_HIGH) :: {EmitterInstance}
local selectVisibleEmitters: (number) -> ()
-- Глобальные «часы» для rate-noise (одни на все эмиттеры)
local _rateNoiseClock = 0

--==================== 32-bit counter-based PRNG (per-particle) ====================


local function _mul32(a:number, b:number): number
	a = _u32(a); b = _u32(b)
	local a_lo = bit32.band(a, 0xFFFF); local a_hi = bit32.rshift(a,16)
	local b_lo = bit32.band(b, 0xFFFF); local b_hi = bit32.rshift(b,16)
	local lo  = a_lo * b_lo
	local mid = a_lo * b_hi + a_hi * b_lo
	local lower16 = bit32.band(lo, 0xFFFF)
	local upper16 = bit32.band(bit32.rshift(lo, 16) + bit32.band(mid, 0xFFFF), 0xFFFF)
	return _u32(bit32.lshift(upper16,16) + lower16)
end

-- реализация присваивается в уже объявленную выше переменную _hash32
_hash32 = function(x:number): number
	x = _u32(x + 0x9E3779B9)
	x = _u32(bit32.bxor(x, bit32.rshift(x,16)))
	x = _mul32(x, 0x85EBCA6B)
	x = _u32(bit32.bxor(x, bit32.rshift(x,13)))
	x = _mul32(x, 0xC2B2AE35)
	x = _u32(bit32.bxor(x, bit32.rshift(x,16)))
	return x
end


local function _u32_to_unit(x:number): number
	return (_u32(x)) / 4294967296.0
end

-- fast PRNG: xorshift32 на основе seed+counter (без умножений)
local function _p_next_u32(state): number
	state.prngCounter = _u32(state.prngCounter + 1)
	return _hash32(_u32(state.prngSeed + _mul32(state.prngCounter, 0x9E3779B9)))
end



local function _p_next01(state): number
	return _u32_to_unit(_p_next_u32(state))
end

local function _p_next_open01(state): number
	return (_p_next_u32(state) + 0.5) / 4294967296.0
end

local function _p_next_number(state, a:number?, b:number?): number
	local t = _p_next01(state)
	if a ~= nil and b ~= nil then return a + (b - a) * t end
	return t
end

--==================== Утилиты диапазонов/кривых ====================

type ParticleState = {
	index: number?,
	emitter: EmitterInstance,
	part: BasePart,
	age: number,
	life: number,
	origin: Vector3,
	position: Vector3,
	baseDirection: Vector3,
	baseSpeed: number,
	accelerationVelocity: Vector3,
	baseSize: Vector3,
	baseAngularVelocity: Vector3,
	angularAngles: Vector3,
	turbulenceStrength: number,
	turbulenceVelocity: Vector3,
	turbulenceTarget: Vector3,
	turbulenceTimer: number,
	returnStrength: number,
	-- Руление направления (самолётик): базовые скорости по осям (рад/с)
	steerYawRate: number,
	steerPitchRate: number,
	steerRollRate: number,
	-- Ортонормированный базис руления, влияющий на траекторию
	steerRight: Vector3,
	steerUp: Vector3,

	-- per-particle PRNG state:
	prngSeed: number,
	prngCounter: number,

	-- пер-частичный цвет/альфа:
	baseColor: Color3,
	baseOpacity: number,

	-- счётчики «через N шагов»
	_tickVisual: number,
	_tickSize: number,
	renderPrev: CFrame?,
	renderCurr: CFrame?,

}

local updateConnection: RBXScriptConnection? = nil
-- Буферы покадровой записи трансформов (для Workspace:BulkMoveTo)
local MOVE_PARTS   = table.create(1024)
local MOVE_CFRAMES = table.create(1024)
-- Переиспользуемые буферы для кадрового fair‑share аллокатора (убираем микро‑GC)
local _FAIR_NEEDERS = table.create(128)  -- список эмиттеров, которым есть что спавнить в этот кадр
local _FAIR_ALLOC   = table.create(128)  -- выделения по эмиттерам на текущий кадр



local DEFAULT_CONFIG = {
	rate = 24,
	burstCount = 0,
	maxParticles = 128,
	emissionDirection = Vector3.new(0, 1, 0),
	spawnDirectionMode = "emission", -- "emission", "radialOutward", "radialTangent", or "curveNormal"

	-- новая спавн-геометрия
	spawnShape = "point",                -- also supports "cylinderStream" and "cubicBezier"
	spawnSize  = Vector3.new(0,0,0),     -- полуразмеры для всех форм; для "ring"/"annulus" — радиусы по локальным X/Z
	spawnInnerRadius = 0,                -- абсолютный внутренний радиус только для плоского "annulus"
	spawnSurfaceOnly = false,            -- если true: для 3D форм спавним по поверхности, а не по объёму
	distanceSpeedFactor = 0,
	cubicBezierPoints = {
		Vector3.new(0, 0, 0),
		Vector3.new(0, 2, 0),
		Vector3.new(2, 4, 0),
		Vector3.new(2, 6, 0),
	},
	cylinderStreamAxis = Vector3.new(0, 1, 0),
	cylinderStreamRadius = 1,
	cylinderStreamHalfHeight = 1,


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
		-- Самолётик: угловые скорости изменения НАПРАВЛЕНИЯ (град/с)
		steerYaw  = {min = 0, max = 0},
		steerPitch= {min = 0, max = 0},
		steerRoll = {min = 0, max = 0},


		-- новые диапазоны
		opacity = {min = 1, max = 1},
		color   = {min = Color3.new(1,1,1), max = Color3.new(1,1,1)},
	},

	globalSpeedCurve = {1, 1, 1},

	-- Нойз для частоты эмиссии (мягкие пульсации rate)
	rateNoiseAmplitude = 0,   -- 0..1, амплитуда мультипликатора (±amp вокруг 1.0)
	rateNoiseFrequency = 0,   -- Гц, сколько «волн» в секунду
	rateNoiseSeed = nil, -- если nil, берём сид эмиттера; число => общий сид для синхронизации
	-- Нойз для длительности жизни (lifetime)
	lifeNoiseAmplitude = 0,   -- 0..1, амплитуда мультипликатора
	lifeNoiseFrequency = 0,   -- Гц
	lifeNoiseSeed      = nil, -- если nil, наследует rateNoiseSeed; если и он nil — берём сид эмиттера

	-- Нойз масштаба (по времени жизни частицы), с возможностью общих сидов
	sizeNoiseAmplitude = 0,   -- 0..1, глубина пульсаций вокруг 1
	sizeNoiseFrequency = 0,   -- Гц, сколько «волн» за секунду возраста частицы
	sizeNoiseSeed      = nil, -- nil => наследует lifeNoiseSeed => rateNoiseSeed; иначе используем это число

	-- Нойз руления (пер-частица, во времени её жизни)
	steerNoiseAmplitude = 0,   -- 0..1, множитель |ω| = ω * (1 + amp * noise)
	steerNoiseFrequency = 0,   -- Гц, частота нойза по времени жизни частицы (исп. state.age)
	steerNoiseSeed      = nil, -- nil => наследует sizeNoiseSeed => lifeNoiseSeed => rateNoiseSeed => prngSeed


	wind = Vector3.zero,
	-- Мировое ускорение (например, подъём пламени или псевдо-гравитация)
	acceleration = Vector3.new(0, 0, 0),
	accelerationDrag = 20,
	accelerationCurve = { start = 1, mid = 1, finish = 1 },

	perParticleCurves = {},

	-- базовые материал/цвет
	color = Color3.fromRGB(255, 255, 255),
	material = Enum.Material.Neon,

	-- кривые цвета/прозрачности (мультипликативные)
	colorCurve   = {start = Color3.new(1,1,1), mid = Color3.new(1,1,1), finish = Color3.new(1,1,1)},
	opacityCurve = {start = 1, mid = 1, finish = 1},

	-- Частота применения во внешний мир (шаги симуляции)
	visualUpdateStep = 1, -- цвет+прозрачность: применять каждые N шагов (1/2/3)
	sizeUpdateStep   = 1, -- скейл: применять каждые N шагов (1/2/3)

	-- LOD/отсечение
	lodNear = 0,
	lodFar  = 0,

	-- Игнорировать отсечение по видимости (камера/LOS/FOV)
	ignoreVisibilityCulling = false,

	-- Турбулентность: анти-джиттер
	turbulenceAntiJitter = false,

	-- Пространство симуляции
	localSpace = false,
	faceMovement = false, -- если true, кубики «самолётиком» смотрят по вектору движения



}

-- [REPLACE WHOLE FUNCTION] createCube
local function createCube(): BasePart
	local part = Instance.new("Part")
	part.Name = "VoxelParticle"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.EnableFluidForces = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = DEFAULT_CONFIG.color
	part.Size = Vector3.new(0.5, 0.5, 0.5)
	part.Transparency = 1
	-- Критично: локальная маска скрывает часть даже если Transparency временно 0
	part.LocalTransparencyModifier = 1
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	if POOL_MODE == "nil" then
		part.Parent = nil
	else
		part.Parent = POOL_FOLDER
	end
	return part
end

local function _readGraphicsQualityRatio(): number
	if ClientVfxQuality == nil then
		return 1
	end
	return ClientVfxQuality.GetParticleMultiplier()
end


local function _hasLineOfSightToCamera(anchor: BasePart?, originPosition: Vector3?): boolean
	if not anchor then
		return true
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return true
	end

	local camPos = cam.CFrame.Position
	local target = originPosition or anchor.Position
	local direction = camPos - target
	local distance = direction.Magnitude
	if distance <= 0 then
		return true
	end

	local dirUnit = direction / distance

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = _buildLosFilter(anchor)
	params.IgnoreWater = true

	local result = Workspace:Raycast(target, dirUnit * distance, params)
	return result == nil
end

local function _computeParticleMultiplier(qualityRatio: number): number
	return math.clamp(qualityRatio, 0, 1)
end

-- [REPLACE WHOLE FUNCTION] _applyQualityScaling
local function _applyQualityScaling()
	MAX_TOTAL_PARTICLES = math.max(0, math.floor(_baseMaxTotalParticles * _qualityMultiplier + 0.5))
	maxActiveEmitters = math.floor(MAX_ACTIVE_EMITTERS_HIGH * _qualityMultiplier + 0.5)
	for _, emitter in ipairs(emitters) do
		emitter.maxParticles = math.max(0, math.floor(emitter._baseMaxParticles * _qualityMultiplier + 0.5))
		if emitter._baseRate == nil then
			emitter._baseRate = math.max(0, tonumber(emitter.rate) or 0)
		end
		-- burst-эмиттеры (rate<=0) не трогаем
		if emitter._baseRate > 0 then
			local desired = math.max(0, math.floor(emitter._baseRate * _qualityMultiplier + 0.5))
			if desired ~= emitter.rate then
				emitter.rate = desired
			end
		end
	end
	selectVisibleEmitters(0)
end


local function _updateQualityMultiplier()
	local newRatio = _readGraphicsQualityRatio()
	local newMultiplier = _computeParticleMultiplier(newRatio)
	if math.abs(newMultiplier - _qualityMultiplier) < 1e-3 then
		return
	end
	_qualityMultiplier = newMultiplier
	_applyQualityScaling()
end

-- [REPLACE WHOLE FUNCTION] _connectQualitySignals
local function _connectQualitySignals()
	if _qualitySignalsConnected then return end
	_qualitySignalsConnected = true
	if not RunService:IsClient() or ClientVfxQuality == nil then return end

	local connection = ClientVfxQuality.OnTierChanged(function()
		_updateQualityMultiplier()
	end)
	if connection then
		table.insert(_qualityConnections, connection)
	end
end

-- [REPLACE WHOLE FUNCTION] acquireCube
-- [REPLACE WHOLE FUNCTION]
local function acquireCube(): BasePart?
	if liveCount >= MAX_TOTAL_PARTICLES then
		return nil
	end
	local part = table.remove(pool)
	if not part then
		return nil
	end
	liveCount += 1
	spawnsThisFrame += 1

	-- Насильная маска: деталь есть в мире, но локально невидима
	part.LocalTransparencyModifier = 1
	part.Transparency = 1
	part.Parent = LIVE_FOLDER -- всегда в Live при активации

	return part
end



-- [REPLACE WHOLE FUNCTION]
local function releaseCube(part: BasePart)
	_UNMASK_AT[part] = nil
	part.LocalTransparencyModifier = 1
	part.Transparency = 1
	part.Size = Vector3.new(0.5, 0.5, 0.5)
	part.CFrame = CFrame.new()
	liveCount = math.max(0, liveCount - 1)
	local reusableCapacity = math.max(0, _baseMaxTotalParticles - liveCount)
	if #pool >= reusableCapacity then
		part:Destroy()
		return
	end

	if POOL_MODE == "nil" then
		part.Parent = nil
	else
		part.Parent = POOL_FOLDER
	end
	table.insert(pool, part)
end

local function warmPoolWithinFrameBudget()
	local reusableCapacity = math.max(0, _baseMaxTotalParticles - liveCount)
	while #pool > reusableCapacity do
		local part = table.remove(pool)
		if part then part:Destroy() end
	end
	local missing = reusableCapacity - #pool
	local remainingBudget = MAX_POOLED_PART_CREATIONS_PER_FRAME - partCreationsThisFrame
	local createCount = math.max(0, math.min(missing, remainingBudget))

	for _ = 1, createCount do
		partCreationsThisFrame += 1
		table.insert(pool, createCube())
	end
end


local function parseRange(range: Range?, defaultMin: number, defaultMax: number): (number, number)
	if range == nil then
		return defaultMin, defaultMax
	end
	if typeof(range) == "number" then
		return range, range
	elseif typeof(range) == "table" then
		local rangeTable = range :: any
		local minValue = defaultMin
		local maxValue = defaultMax
		if rangeTable.min ~= nil then
			minValue = rangeTable.min
		elseif rangeTable[1] ~= nil then
			minValue = rangeTable[1]
		end
		if rangeTable.max ~= nil then
			maxValue = rangeTable.max
		elseif rangeTable[2] ~= nil then
			maxValue = rangeTable[2]
		end
		if minValue > maxValue then
			minValue, maxValue = maxValue, minValue
		end
		return minValue, maxValue
	end
	return defaultMin, defaultMax
end

local function parseCurve(curve: any, defaultValue: number?): (number, number, number)
	local startValue = defaultValue or 1
	local midValue = defaultValue or 1
	local endValue = defaultValue or 1
	if curve == nil then
		return startValue, midValue, endValue
	end
	if typeof(curve) == "table" then
		startValue = curve.start or curve[1] or startValue
		midValue = curve.mid or curve[2] or midValue
		endValue = curve.finish or curve.final or curve[3] or endValue
	elseif typeof(curve) == "number" then
		startValue = curve
		midValue = curve
		endValue = curve
	end
	return startValue, midValue, endValue
end

local function evaluateCurve(alpha: number, startValue: number, midValue: number, endValue: number): number
	alpha = math.clamp(alpha, 0, 1)
	if alpha <= 0.5 then
		local t = alpha / 0.5
		return startValue + (midValue - startValue) * t
	else
		local t = (alpha - 0.5) / 0.5
		return midValue + (endValue - midValue) * t
	end
end


-- ===== Новые вспомогательные для цвета/спавна/локального базиса =====

local function _parseColorRange(range:any, defMin:Color3, defMax:Color3): (Color3, Color3)
	if typeof(range) == "Color3" then return range, range end
	if typeof(range) == "table" then
		local a = range.min or range[1] or defMin
		local b = range.max or range[2] or defMax
		return a, b
	end
	return defMin, defMax
end

local function _evalColorCurve(alpha:number, c0:Color3, c1:Color3, c2:Color3): Color3
	alpha = math.clamp(alpha, 0, 1)
	if alpha <= 0.5 then
		local t = alpha / 0.5
		return c0:Lerp(c1, t)
	else
		local t = (alpha - 0.5)/0.5
		return c1:Lerp(c2, t)
	end
end

local function _isColorCurveTrivial(c0:Color3, c1:Color3, c2:Color3): boolean
	return c0.R==1 and c0.G==1 and c0.B==1 and c1.R==1 and c1.G==1 and c1.B==1 and c2.R==1 and c2.G==1 and c2.B==1
end

local function _basisFromDir(dir:Vector3)
	dir = (dir.Magnitude > 0) and dir.Unit or Vector3.new(0,1,0)
	local up = (math.abs(dir.Y) > 0.99) and Vector3.new(1,0,0) or Vector3.new(0,1,0)
	local right = dir:Cross(up).Unit
	local forward = right:Cross(dir).Unit
	return dir, right, forward
end

local function _sampleConeDirection(axis: Vector3, minAngle: number, maxAngle: number, pstate): Vector3
	local direction, right, forward = _basisFromDir(axis)
	local cosMin, cosMax = math.cos(minAngle), math.cos(maxAngle)
	if cosMin < cosMax then
		cosMin, cosMax = cosMax, cosMin
	end
	local cosTheta = _p_next_number(pstate, cosMax, cosMin)
	local sinTheta = math.sqrt(math.max(0, 1 - cosTheta * cosTheta))
	local phi = _p_next_number(pstate, 0, math.pi * 2)
	return (direction * cosTheta + right * (math.cos(phi) * sinTheta) + forward * (math.sin(phi) * sinTheta)).Unit
end

local function _copyVector2Array(points: {Vector2}): {Vector2}
	local copy = table.create(#points)
	for i = 1, #points do
		copy[i] = points[i]
	end
	return copy
end

local function _reverseArray<T>(arr: {T})
	local i, j = 1, #arr
	while i < j do
		arr[i], arr[j] = arr[j], arr[i]
		i += 1
		j -= 1
	end
end

local function _polygonSignedArea(points: {Vector2}): number
	local area = 0
	local count = #points
	if count < 3 then
		return 0
	end
	for i = 1, count do
		local current = points[i]
		local nextPoint = points[(i % count) + 1]
		area += current.X * nextPoint.Y - nextPoint.X * current.Y
	end
	return area * 0.5
end

local function _cross2D(a: Vector2, b: Vector2, c: Vector2): number
	return (b.X - a.X) * (c.Y - a.Y) - (b.Y - a.Y) * (c.X - a.X)
end

local function _pointInTriangle(pt: Vector2, a: Vector2, b: Vector2, c: Vector2): boolean
	local d1 = _cross2D(pt, a, b)
	local d2 = _cross2D(pt, b, c)
	local d3 = _cross2D(pt, c, a)
	local hasNeg = (d1 < 0) or (d2 < 0) or (d3 < 0)
	local hasPos = (d1 > 0) or (d2 > 0) or (d3 > 0)
	return not (hasNeg and hasPos)
end

type PolygonTriangle = {
	a: Vector2,
	b: Vector2,
	c: Vector2,
	area: number,
}

type PolygonEdge = {
	a: Vector2,
	b: Vector2,
	length: number,
}

type PolygonData = {
	vertices: {Vector2},
	triangles: {PolygonTriangle},
	edges: {PolygonEdge},
	totalArea: number,
	perimeter: number,
}

local function _triangulatePolygon(points: {Vector2}): {PolygonTriangle}
	local triangles = {}
	local count = #points
	if count < 3 then
		return triangles
	end

	local indices = table.create(count)
	for i = 1, count do
		indices[i] = i
	end

	local guard = 0
	while #indices >= 3 and guard < 512 do
		guard += 1
		local earFound = false
		for earIndex = 1, #indices do
			local prevIndex = indices[((earIndex - 2) % #indices) + 1]
			local currIndex = indices[earIndex]
			local nextIndex = indices[(earIndex % #indices) + 1]

			local a = points[prevIndex]
			local b = points[currIndex]
			local c = points[nextIndex]

			if _cross2D(a, b, c) <= 1e-8 then
				continue
			end

			local ear = true
			for j = 1, #indices do
				local idx = indices[j]
				if idx ~= prevIndex and idx ~= currIndex and idx ~= nextIndex then
					if _pointInTriangle(points[idx], a, b, c) then
						ear = false
						break
					end
				end
			end

			if ear then
				table.insert(triangles, {
					a = a,
					b = b,
					c = c,
					area = 0,
				})
				table.remove(indices, earIndex)
				earFound = true
				break
			end
		end

		if not earFound then
			break
		end
	end

	if #triangles == 0 and count >= 3 then
		-- fallback: фан-триангуляция вокруг первой вершины
		local pivot = points[1]
		for i = 2, count - 1 do
			local b = points[i]
			local c = points[i + 1]
			if math.abs(_cross2D(pivot, b, c)) > 1e-8 then
				table.insert(triangles, {
					a = pivot,
					b = b,
					c = c,
					area = 0,
				})
			end
		end
	end

	for _, tri in ipairs(triangles) do
		tri.area = math.abs(_cross2D(tri.a, tri.b, tri.c)) * 0.5
	end

	return triangles
end

local function _buildPolygonData(vertices: {Vector2}): PolygonData
	local pts = _copyVector2Array(vertices)
	if _polygonSignedArea(pts) < 0 then
		_reverseArray(pts)
	end

	local triangles = _triangulatePolygon(pts)
	local totalArea = 0
	for _, tri in ipairs(triangles) do
		totalArea += tri.area
	end

	local edges = table.create(#pts)
	local perimeter = 0
	for i = 1, #pts do
		local a = pts[i]
		local b = pts[(i % #pts) + 1]
		local length = (b - a).Magnitude
		perimeter += length
		edges[i] = {
			a = a,
			b = b,
			length = length,
		}
	end

	return {
		vertices = pts,
		triangles = triangles,
		edges = edges,
		totalArea = totalArea,
		perimeter = perimeter,
	}
end

local function _samplePolygonInterior(poly: PolygonData, pstate): Vector2
	if poly.totalArea <= 0 then
		return poly.vertices[1] or Vector2.zero
	end

	local t = _p_next01(pstate) * poly.totalArea
	for _, tri in ipairs(poly.triangles) do
		if tri.area <= 0 then
			continue
		end
		if t <= tri.area then
			local u = _p_next01(pstate)
			local v = _p_next01(pstate)
			if u + v > 1 then
				u = 1 - u
				v = 1 - v
			end
			local ab = tri.b - tri.a
			local ac = tri.c - tri.a
			return tri.a + ab * u + ac * v
		end
		t -= tri.area
	end

	local last = poly.triangles[#poly.triangles]
	if last then
		return last.a
	end
	return poly.vertices[1] or Vector2.zero
end

local function _samplePolygonPerimeter(poly: PolygonData, pstate): Vector2
	if poly.perimeter <= 0 then
		return poly.vertices[1] or Vector2.zero
	end

	local t = _p_next01(pstate) * poly.perimeter
	for _, edge in ipairs(poly.edges) do
		if edge.length <= 0 then
			continue
		end
		if t <= edge.length then
			local alpha = t / edge.length
			return edge.a + (edge.b - edge.a) * alpha
		end
		t -= edge.length
	end

	local last = poly.edges[#poly.edges]
	if last then
		return last.b
	end
	return poly.vertices[1] or Vector2.zero
end

local function _makeStarVertices(points: number): {Vector2}
	local vertices = table.create(points * 2)
	local outerRadius = 1
	local innerRadius = outerRadius * math.sin(math.pi / (2 * points)) / math.sin(3 * math.pi / (2 * points))
	local step = math.pi / points
	local startAngle = -math.pi / 2
	for i = 0, points * 2 - 1 do
		local radius = (i % 2 == 0) and outerRadius or innerRadius
		local angle = startAngle + step * i
		vertices[i + 1] = Vector2.new(math.cos(angle) * radius, math.sin(angle) * radius)
	end
	return vertices
end

local FLAT_POLYGONS = {
	triangle = _buildPolygonData({
		Vector2.new(0, 1),
		Vector2.new(-math.sqrt(3)/2, -0.5),
		Vector2.new(math.sqrt(3)/2, -0.5),
	}),
	square = _buildPolygonData({
		Vector2.new(-1, -1),
		Vector2.new(1, -1),
		Vector2.new(1, 1),
		Vector2.new(-1, 1),
	}),
	star5 = _buildPolygonData(_makeStarVertices(5)),
	star7 = _buildPolygonData(_makeStarVertices(7)),
}

local function _spawnOffset(
	shape: string,
	size: Vector3,
	dir: Vector3,
	surfaceOnly: boolean,
	annulusInnerRadius: number,
	pstate
): Vector3
	local D, R, F = _basisFromDir(dir)
	local sx, sy, sz = math.abs(size.X), math.abs(size.Y), math.abs(size.Z)
	if shape == "point" then
		return Vector3.zero
	elseif shape == "cube" then
		if surfaceOnly then
			-- равномерно по поверхности параллелепипеда (выбор грани ~ площади)
			local ax = sy * sz
			local ay = sx * sz
			local az = sx * sy
			local sum = ax + ay + az
			-- выбираем ось грани
			local t = _p_next01(pstate) * sum
			if t < ax then
				-- грань ±X
				local sign = (_p_next01(pstate) < 0.5) and -1 or 1
				return Vector3.new(sign*sx, _p_next_number(pstate, -sy, sy), _p_next_number(pstate, -sz, sz))
			elseif t < ax + ay then
				-- грань ±Y
				local sign = (_p_next01(pstate) < 0.5) and -1 or 1
				return Vector3.new(_p_next_number(pstate, -sx, sx), sign*sy, _p_next_number(pstate, -sz, sz))
			else
				-- грань ±Z
				local sign = (_p_next01(pstate) < 0.5) and -1 or 1
				return Vector3.new(_p_next_number(pstate, -sx, sx), _p_next_number(pstate, -sy, sy), sign*sz)
			end
		else
			-- объём как было
			return Vector3.new(
				_p_next_number(pstate, -sx, sx),
				_p_next_number(pstate, -sy, sy),
				_p_next_number(pstate, -sz, sz)
			)
		end

	elseif shape == "sphere" then
		if surfaceOnly then
			-- равномерно по поверхности сферы (анизотропный скейл даёт эллипсоид)
			local u = _p_next01(pstate)
			local v = _p_next01(pstate)
			local theta = 2*math.pi*u
			local z = 2*v - 1
			local r = math.sqrt(math.max(0, 1 - z*z))
			return Vector3.new(
				(r*math.cos(theta)) * sx,
				(z)                 * sy,
				(r*math.sin(theta)) * sz
			)
		else
			-- объём как было
			local u = _p_next01(pstate)
			local v = _p_next01(pstate)
			local theta = 2*math.pi*u
			local phi = math.acos(2*v - 1)
			local rr = (_p_next01(pstate))^(1/3)
			local sinPhi = math.sin(phi)
			return Vector3.new(
				(rr * sinPhi * math.cos(theta)) * sx,
				(rr * math.cos(phi))            * sy,
				(rr * sinPhi * math.sin(theta)) * sz
			)
		end

	elseif shape == "hemisphere" then
		-- полупространство +D
		if surfaceOnly then
			-- равномерно по поверхности полусферы
			local theta = 2*math.pi*_p_next01(pstate)
			local z = _p_next_number(pstate, 0, 1)
			local r = math.sqrt(math.max(0, 1 - z*z))
			local loc = Vector3.new(r*math.cos(theta), z, r*math.sin(theta))
			return R*(loc.X*sx) + D*(loc.Y*sy) + F*(loc.Z*sz)
		else
			-- объём как было
			local theta = 2*math.pi*_p_next01(pstate)
			local z = _p_next_number(pstate, 0, 1)
			local r = math.sqrt(math.max(0, 1 - z*z))
			local rad = (_p_next01(pstate))^(1/3)
			local loc = Vector3.new(r*math.cos(theta), z, r*math.sin(theta)) * rad
			return R*(loc.X*sx) + D*(loc.Y*sy) + F*(loc.Z*sz)
		end

	elseif shape == "disc" then
		local theta = 2*math.pi*_p_next01(pstate)
		if surfaceOnly then
			return R*(math.cos(theta)*sx) + F*(math.sin(theta)*sz)
		else
			local r = math.sqrt(_p_next01(pstate))
			return R*(r*math.cos(theta)*sx) + F*(r*math.sin(theta)*sz)
		end
	elseif shape == "ring" then
		local theta = 2*math.pi*_p_next01(pstate)
		return R*(math.cos(theta)*sx) + F*(math.sin(theta)*sz)
	elseif shape == "annulus" then
		local theta = 2 * math.pi * _p_next01(pstate)
		local radius = math.sqrt(
			annulusInnerRadius * annulusInnerRadius
				+ (sx * sx - annulusInnerRadius * annulusInnerRadius) * _p_next01(pstate)
		)
		return R * (math.cos(theta) * radius) + F * (math.sin(theta) * radius)
	elseif FLAT_POLYGONS[shape] then
		local poly = FLAT_POLYGONS[shape]
		local sample2d
		if surfaceOnly then
			sample2d = _samplePolygonPerimeter(poly, pstate)
		else
			sample2d = _samplePolygonInterior(poly, pstate)
		end
		return R*(sample2d.X * sx) + F*(sample2d.Y * sz)
	else
		return Vector3.zero
	end
end

-- Вращает вектор v вокруг оси axisUnit на угол angle (рад)
local function _rotateAroundAxis(v: Vector3, axisUnit: Vector3, angle: number): Vector3
	local c = math.cos(angle)
	local s = math.sin(angle)
	return v * c + axisUnit:Cross(v) * s + axisUnit * (axisUnit:Dot(v)) * (1 - c)
end

--============== Пул частиц/освобождение/рендер-луп ==============

local function releaseParticle(state: ParticleState)
	if not state.index then
		return
	end
	state.emitter._particles[state] = nil
	state.emitter._alive = math.max(0, state.emitter._alive - 1)
	local idx = state.index
	local lastIdx = #particles
	local last = particles[lastIdx]
	particles[idx] = last
	if last then
		last.index = idx
	end
	particles[lastIdx] = nil
	state.index = nil
	releaseCube(state.part)
end

selectVisibleEmitters = function(dt: number)
	table.clear(selectedEmitters)
	for _, emitter in emitters do
		emitter._admitted = false
		emitter._visibilityElapsed = (emitter._visibilityElapsed or 0) + dt
		if maxActiveEmitters == 0 or emitter._destroyed
			or not (emitter._enabled or emitter._alive > 0 or emitter._spawnDemand > 0) then
			continue
		end
		local cameraScale, distanceSquared = emitter:_getCameraScale()
		emitter._cameraScale = cameraScale
		emitter._cameraDistanceSquared = distanceSquared
		if cameraScale <= 0 then continue end
		local count = #selectedEmitters
		if count == maxActiveEmitters
			and distanceSquared >= selectedEmitters[count]._cameraDistanceSquared then
			continue
		end
		if not emitter:_updateLineOfSight(false) then continue end
		local insertion = count + 1
		while insertion > 1
			and distanceSquared < selectedEmitters[insertion - 1]._cameraDistanceSquared do
			insertion -= 1
		end
		table.insert(selectedEmitters, insertion, emitter)
		if #selectedEmitters > maxActiveEmitters then
			table.remove(selectedEmitters)
		end
	end
	for _, emitter in selectedEmitters do
		emitter._admitted = true
		emitter._spawnedThisFrame = 0
	end
	for _, emitter in emitters do
		if not emitter._admitted then
			emitter._spawnDemand = 0
			emitter._burstDemand = 0
			emitter._quotaDebt = 0
			emitter._accumulator = 0
			emitter._simAccumulator = 0
			emitter._pendingSubsteps = 0
		end
	end
	-- Reclaim before simulation: invisible emitters and quality reductions never
	-- retain a second, unbudgeted population of living particles.
	for index = #particles, 1, -1 do
		local state = particles[index]
		local emitter = state.emitter
		if not emitter._admitted or emitter._alive > emitter.maxParticles
			or liveCount > MAX_TOTAL_PARTICLES then
			releaseParticle(state)
		end
	end
end

local function spawnDemandPhase(quota: number, explicitBurst: boolean): number
	if quota <= 0 then
		return 0
	end

	local needers = _FAIR_NEEDERS
	table.clear(needers)
	local allocated = _FAIR_ALLOC
	local count = 0

	for index = 1, #selectedEmitters do
		local emitter = selectedEmitters[index]
		local totalDemand = math.max(0, emitter._spawnDemand or 0)
		local burstDemand = math.min(totalDemand, math.max(0, emitter._burstDemand or 0))
		local demand = explicitBurst and burstDemand or (totalDemand - burstDemand)
		local localCap = emitter.maxParticles - emitter._alive

		if demand > localCap then
			demand = localCap
		end
		demand = math.min(demand,
			math.max(0, math.floor(MAX_SPAWN_PER_FRAME * _qualityMultiplier) - emitter._spawnedThisFrame))

		if demand > 0 then
			count += 1
			needers[count] = emitter
			emitter._demandForFrame = demand
			emitter._quotaDebt = emitter._quotaDebt or 0
		else
			emitter._demandForFrame = 0
		end
	end

	if count == 0 then
		return 0
	end

	local granted = VoxelFairShareAllocator.Allocate(needers, allocated, quota, _frameSerial)
	if granted <= 0 then
		return 0
	end

	local totalSpawned = 0
	for index = 1, count do
		local emitter = needers[index]
		local allocation = allocated[index]
		if allocation and allocation > 0 then
			if allocation > emitter._demandForFrame then
				allocation = emitter._demandForFrame
			end

			local spawned = 0
			for _ = 1, allocation do
				if liveCount >= MAX_TOTAL_PARTICLES then
					break
				end
				if not emitter:_spawnOne() then
					break
				end
				spawned += 1
			end

			emitter._spawnDemand = math.max(0, emitter._spawnDemand - spawned)
			emitter._spawnedThisFrame += spawned
			if explicitBurst then
				emitter._burstDemand = math.max(0, emitter._burstDemand - spawned)
			end
			totalSpawned += spawned
		end
		emitter._demandForFrame = 0
	end

	return totalSpawned
end

-- ReplicatedStorage/Shared/VoxelParticleSystem.lua
-- [ПОЛНАЯ ЗАМЕНА ФУНКЦИИ] ensureUpdateLoop()

local function ensureUpdateLoop()
	if updateConnection then
		return
	end
	updateConnection = RunService.RenderStepped:Connect(function(dt)
		debug.profilebegin("VPS.Frame")
		_frameSerial += 1
		_rateNoiseClock += dt
		partCreationsThisFrame = 0
		spawnsThisFrame = 0
		debug.profilebegin("VPS.PoolWarmup")
		warmPoolWithinFrameBudget()
		debug.profileend()
		local poolReady = #pool + liveCount >= _baseMaxTotalParticles
		debug.profilebegin("VPS.Admission")
		selectVisibleEmitters(dt)
		debug.profileend()

		-- Continuous and burst requests share one quality-scaled frame budget.
		local GLOBAL_MAX_SPAWN_PER_FRAME = math.floor(128 * _qualityMultiplier)
		frameSpawnLimit = GLOBAL_MAX_SPAWN_PER_FRAME

		local function spawnDRR()
			if not poolReady then return end
			local available = MAX_TOTAL_PARTICLES - liveCount
			if available <= 0 then
				-- Ничего не спавним, но НЕ обнуляем _spawnDemand: долг перенесётся на следующие кадры.
				return
			end

			-- Emission only borrows prewarmed Parts, including explicit bursts.
			local burstSpawned = spawnDemandPhase(
				math.min(available, GLOBAL_MAX_SPAWN_PER_FRAME),
				true
			)

			available = MAX_TOTAL_PARTICLES - liveCount
			local frameQuota = GLOBAL_MAX_SPAWN_PER_FRAME - burstSpawned
			spawnDemandPhase(
				math.min(available, frameQuota, #pool),
				false
			)

			for index = 1, #selectedEmitters do
				local emitter = selectedEmitters[index]
				local backlogCap = math.min(emitter.maxParticles - emitter._alive, MAX_SPAWN_PER_FRAME * 4)
				if backlogCap < 0 then
					backlogCap = 0
				end
				if (emitter._spawnDemand or 0) > backlogCap then
					emitter._spawnDemand = backlogCap
				end
				emitter._burstDemand = math.min(emitter._burstDemand or 0, emitter._spawnDemand or 0)
			end
		end
		-- ============================================================================



		-- ====================================================================

		-- 1) Готовим саб‑шаги и альфу интерполяции для эмиттеров 30 FPS.
		--    ВАЖНО: считаем «время» не только для включённых, но и для тех, у кого ещё есть живые частицы.
		local emitterCount = #selectedEmitters
		for i = 1, emitterCount do
			local e = selectedEmitters[i]
			if e._isFixed30 then
				local hasActive = e._enabled or (e._alive and e._alive > 0)
				if hasActive then
					local step = SIM_STEP_30
					e._simAccumulator = (e._simAccumulator or 0) + dt
					local maxAccum = step * MAX_SUBSTEPS_PER_FRAME
					if e._simAccumulator > maxAccum then
						e._simAccumulator = maxAccum
					end
					e._pendingSubsteps = math.floor(e._simAccumulator / step)
					e._simAccumulator -= e._pendingSubsteps * step
					e._interpAlpha = (step > 0) and math.clamp(e._simAccumulator / step, 0, 1) or 0
				else
					e._pendingSubsteps = 0
					e._interpAlpha = 0
				end
			else
				e._pendingSubsteps = 0
				e._interpAlpha = 0
				if e._hasAccelerationDrag and (e._alive or 0) > 0 then
					VoxelMotionIntegrator.ConfigureAccelerationDragStep(
						e._accelerationDragStep,
						e.accelerationDrag,
						dt
					)
				end
			end
		end

		-- 2) Копим «спрос» на спавн: ТОЛЬКО для включённых эмиттеров
		for i = 1, emitterCount do
			local e = selectedEmitters[i]
			if e._enabled and poolReady then
				if e._isFixed30 then
					local steps = e._pendingSubsteps
					for _ = 1, steps do
						e:_updateEmission(SIM_STEP_30)
					end
				else
					e:_updateEmission(dt)
				end
			end
		end

		-- 3) Шаг симуляции частиц — НЕ зависит от enabled (живые частицы продолжают жить)
		debug.profilebegin("VPS.Simulation")
		local i = #particles
		while i >= 1 do
			local state = particles[i]
			if state then
				local e = state.emitter
				if e._isFixed30 then
					local steps = e._pendingSubsteps or 0
					if steps > 0 then
						local alive = true
						for _ = 1, steps do
							if not e:_stepParticle(state, SIM_STEP_30, true) then
								alive = false
								break
							end
						end
						if not alive then
							releaseParticle(state)
							if i > #particles then i = #particles end
						else
							i -= 1
						end
					else
						-- шага нет — интерполяция произойдёт на этапе (5)
						i -= 1
					end
				else
					if not e:_stepParticle(state, dt, false) then
						releaseParticle(state)
						if i > #particles then i = #particles end
					else
						i -= 1
					end
				end
			else
				i -= 1
			end
		end
		debug.profileend()
		debug.profilebegin("VPS.Spawn")
		spawnDRR()
		debug.profileend()
		-- 4.5) Насильная маска первых двух кадров (для всех частиц, 30 и 60 FPS)
		do
			local pcount = #particles
			for j = 1, pcount do
				local s = particles[j]
				if s then
					local part = s.part
					local unmaskAt = _UNMASK_AT[part]
					if unmaskAt then
						if _frameSerial >= unmaskAt then
							_UNMASK_AT[part] = nil
							if part.LocalTransparencyModifier ~= 0 then
								part.LocalTransparencyModifier = 0
							end
						else
							if part.LocalTransparencyModifier ~= 1 then
								part.LocalTransparencyModifier = 1
							end
						end
					end
				end
			end
		end

		-- 5) Интерполяция и буфер записи для всех 30 FPS‑частиц
		local pcount = #particles
		for j = 1, pcount do
			local s = particles[j]
			if s then
				local e = s.emitter
				if e._isFixed30 then
					local prev = s.renderPrev or s.part.CFrame
					local curr = s.renderCurr or prev
					local cf   = prev:Lerp(curr, e._interpAlpha or 0)
					local idx = #MOVE_PARTS + 1
					MOVE_PARTS[idx]   = s.part
					MOVE_CFRAMES[idx] = cf
				end
			end
		end

		-- 6) Одна запись всех трансформов
		if #MOVE_PARTS > 0 then
			Workspace:BulkMoveTo(MOVE_PARTS, MOVE_CFRAMES, Enum.BulkMoveMode.FireCFrameChanged)
			table.clear(MOVE_PARTS)
			table.clear(MOVE_CFRAMES)
		end

		-- 7) Авто‑стоп цикла после завершения ограниченного прогрева пула.
		if #particles == 0 then
			local anyEnabled = false
			for emitterIndex = 1, #emitters do
				if emitters[emitterIndex]._enabled then
					anyEnabled = true
					break
				end
			end
			if not anyEnabled and poolReady then
				local connection = updateConnection
				if connection then
					connection:Disconnect()
				end
				updateConnection = nil
			end
		end
		debug.profileend()
	end)
end



local function stopUpdateLoopIfIdle()
	local poolReady = #pool + liveCount >= _baseMaxTotalParticles
	if updateConnection and #emitters == 0 and #particles == 0 and poolReady then
		updateConnection:Disconnect()
		updateConnection = nil
	end
end

function Emitter:_updateLineOfSight(forceImmediate: boolean?): boolean
	local anchor = self.anchor

	if self.ignoreVisibilityCulling then
		self._hasLineOfSight = true
		self._visibilityElapsed = 0
		return true
	end

	-- Для непрерывных эффектов (rate > 0) без якоря считаем невидимым.
	if not anchor or not anchor.Parent then
		self._hasLineOfSight = false
		self._visibilityElapsed = 0
		return false
	end

	-- Троттлинг LOS-проверок для непрерывных эффектов.
	self._visibilityElapsed = self._visibilityElapsed or 0
	if forceImmediate then
		self._visibilityElapsed = VISIBILITY_POLL_INTERVAL
	end

	if self._visibilityElapsed >= VISIBILITY_POLL_INTERVAL then
		self._visibilityElapsed = 0

		local okPosition, originPosition = pcall(function()
			return anchor.Position
		end)
		if okPosition then
			self._hasLineOfSight = _hasLineOfSightToCamera(anchor, originPosition)
		else
			self._hasLineOfSight = false
		end
	end

	return self._hasLineOfSight ~= false
end


-- Camera visibility is shared by continuous emission, explicit bursts and admission.
function Emitter:_getCameraScale(): (number, number)
	local anchor = self.anchor
	local camera = Workspace.CurrentCamera
	if not anchor or not anchor.Parent or not camera then
		return 0, math.huge
	end
	local position = anchor.Position
	local projected, onScreen = camera:WorldToViewportPoint(position)
	if not onScreen or projected.Z <= 0 then
		return 0, math.huge
	end
	local offset = position - camera.CFrame.Position
	local distanceSquared = offset:Dot(offset)
	if self.lodFar > self.lodNear then
		local scale = 1 - math.clamp((math.sqrt(distanceSquared) - self.lodNear) / (self.lodFar - self.lodNear), 0, 1)
		return scale, distanceSquared
	end
	return 1, distanceSquared
end

--============== Конфиг/применение ==============

function Emitter:_applyConfig(config)
	config = config or {}
	local merged = table.clone(DEFAULT_CONFIG)
	for key, value in pairs(config) do
		merged[key] = value
	end

	self._baseRate = math.max(0, tonumber(merged.rate) or 0)
	if self._baseRate > 0 then
		self.rate = math.max(0, math.floor(self._baseRate * _qualityMultiplier + 0.5))
	else
		self.rate = 0
	end
	local burst = tonumber(merged.burstCount) or 0
	if self._baseRate <= 0 then
		self.burstCount = math.max(0, math.floor(burst))
	else
		self.burstCount = 0
	end
	self._burstOnEnable = (merged.burstOnEnable == true)
	self._burstConsumed = false
	self.rateNoiseAmplitude = math.max(0, tonumber(merged.rateNoiseAmplitude) or 0)
	self.rateNoiseFrequency = math.max(0, tonumber(merged.rateNoiseFrequency) or 0)
	self._useRateNoise = (self.rateNoiseAmplitude > 0) and (self.rateNoiseFrequency > 0)
	self._lastRateNoiseMul = 1.0 -- кэш актуального множителя нойза рэйта для внешнего доступа

	self.rateNoiseSeed = (merged.rateNoiseSeed ~= nil) and tonumber(merged.rateNoiseSeed) or nil

	self.lifeNoiseAmplitude = math.max(0, tonumber(merged.lifeNoiseAmplitude) or 0)
	self.lifeNoiseFrequency = math.max(0, tonumber(merged.lifeNoiseFrequency) or 0)
	self._useLifeNoise = (self.lifeNoiseAmplitude > 0) and (self.lifeNoiseFrequency > 0)
	-- наследуем сид по умолчанию от rateNoiseSeed
	if merged.lifeNoiseSeed ~= nil then
		self.lifeNoiseSeed = tonumber(merged.lifeNoiseSeed)
	else
		self.lifeNoiseSeed = self.rateNoiseSeed
	end

	self.sizeNoiseAmplitude = math.max(0, tonumber(merged.sizeNoiseAmplitude) or 0)
	self.sizeNoiseFrequency = math.max(0, tonumber(merged.sizeNoiseFrequency) or 0)
	self._useSizeNoise = (self.sizeNoiseAmplitude > 0) and (self.sizeNoiseFrequency > 0)
	if merged.sizeNoiseSeed ~= nil then
		self.sizeNoiseSeed = tonumber(merged.sizeNoiseSeed)
	else
		-- наследуем сид: сначала от life, затем от rate; если оба nil — зададим позже из per-particle prng
		self.sizeNoiseSeed = self.lifeNoiseSeed or self.rateNoiseSeed
	end
	local baseMaxParticles = math.max(1, math.floor(tonumber(merged.maxParticles) or DEFAULT_CONFIG.maxParticles))
	self._baseMaxParticles = baseMaxParticles
	self.maxParticles = math.max(0, math.floor(baseMaxParticles * _qualityMultiplier + 0.5))
	local emissionDirection = merged.emissionDirection or DEFAULT_CONFIG.emissionDirection
	if emissionDirection.Magnitude == 0 then
		emissionDirection = Vector3.new(0, 1, 0)
	end
	self.emissionDirection = emissionDirection.Unit
	self.spawnDirectionMode = tostring(merged.spawnDirectionMode or "emission")
	assert(
		self.spawnDirectionMode == "emission"
			or self.spawnDirectionMode == "radialOutward"
			or self.spawnDirectionMode == "radialTangent"
			or self.spawnDirectionMode == "curveNormal",
		"spawnDirectionMode must be emission, radialOutward, radialTangent, or curveNormal"
	)

	-- новая геометрия
	self.spawnShape = tostring(merged.spawnShape or "point")
	do
		local ss = merged.spawnSize or Vector3.new()
		self.spawnSize = Vector3.new(math.abs(ss.X), math.abs(ss.Y), math.abs(ss.Z))
		self.spawnInnerRadius = math.max(0, tonumber(merged.spawnInnerRadius) or 0)
		self.spawnSurfaceOnly = (merged.spawnSurfaceOnly == true)
		local sx, sy, sz = self.spawnSize.X, self.spawnSize.Y, self.spawnSize.Z
		if self.spawnShape == "annulus" then
			assert(
				sx > 0 and math.abs(sx - sz) <= 1e-4 and self.spawnInnerRadius < sx,
				"annulus spawn requires equal positive X/Z outer radii and 0 <= inner < outer"
			)
		end
		self._spawnMaxExtent = math.max(sx, math.max(sy, sz))
	end
	if self.spawnShape == "cubicBezier" then
		local points = merged.cubicBezierPoints
		assert(typeof(points) == "table" and #points == 4, "cubicBezierPoints must contain exactly four Vector3 values")
		for index = 1, 4 do
			assert(typeof(points[index]) == "Vector3", ("cubicBezierPoints[%d] must be a Vector3"):format(index))
		end
		local lut = VoxelCubicBezier.Build(points[1], points[2], points[3], points[4])
		self.cubicBezierPoints = table.clone(points)
		self._cubicBezierLut = lut
		self._spawnMaxExtent = VoxelCubicBezier.MaxControlExtent(lut)
	else
		self.cubicBezierPoints = nil
		self._cubicBezierLut = nil
	end
	self.distanceSpeedFactor = math.clamp(tonumber(merged.distanceSpeedFactor) or 0, -10, 10)
	do
		local streamAxis = merged.cylinderStreamAxis
		local streamRadius = tonumber(merged.cylinderStreamRadius)
		local streamHalfHeight = tonumber(merged.cylinderStreamHalfHeight)
		assert(typeof(streamAxis) == "Vector3", "cylinderStreamAxis must be a Vector3")
		assert(
			streamAxis.X == streamAxis.X and streamAxis.Y == streamAxis.Y and streamAxis.Z == streamAxis.Z
				and math.abs(streamAxis.X) < math.huge
				and math.abs(streamAxis.Y) < math.huge
				and math.abs(streamAxis.Z) < math.huge
				and streamAxis.Magnitude > 0,
			"cylinderStreamAxis must be finite and non-zero"
		)
		assert(
			streamRadius and streamRadius > 0 and streamRadius < math.huge,
			"cylinderStreamRadius must be finite and positive"
		)
		assert(
			streamHalfHeight and streamHalfHeight >= 0 and streamHalfHeight < math.huge,
			"cylinderStreamHalfHeight must be finite and non-negative"
		)
		self.cylinderStreamAxis = streamAxis.Unit
		self.cylinderStreamRadius = streamRadius
		self.cylinderStreamHalfHeight = streamHalfHeight
	end

	self.color = merged.color
	self.material = merged.material
	self.wind = merged.wind or Vector3.zero

	self.acceleration = merged.acceleration or Vector3.zero
	do
		local accelerationDrag = tonumber(merged.accelerationDrag)
		assert(
			accelerationDrag and accelerationDrag == accelerationDrag
				and accelerationDrag >= 0 and accelerationDrag < math.huge,
			"accelerationDrag must be finite and non-negative"
		)
		self.accelerationDrag = accelerationDrag
		self._hasAccelerationDrag = accelerationDrag > 0

		local a1, a2, a3 = parseCurve(merged.accelerationCurve, 1)
		self.accelCurve = { a1, a2, a3 }
		self._hasAccel = (self.acceleration.Magnitude ~= 0) and not (a1 == 0 and a2 == 0 and a3 == 0)
	end


	-- LOD/отсечение
	self.lodNear = math.max(0, tonumber(merged.lodNear) or 0)
	self.lodFar  = math.max(self.lodNear, tonumber(merged.lodFar)  or 0)

	-- цвет/альфа кривые
	do
		local cc = merged.colorCurve or {start = Color3.new(1,1,1), mid=Color3.new(1,1,1), finish=Color3.new(1,1,1)}
		self.colorCurveStart  = cc.start or cc[1] or Color3.new(1,1,1)
		self.colorCurveMid    = cc.mid   or cc[2] or Color3.new(1,1,1)
		self.colorCurveFinish = cc.finish or cc.final or cc[3] or Color3.new(1,1,1)
		self._hasColorCurve = not _isColorCurveTrivial(self.colorCurveStart, self.colorCurveMid, self.colorCurveFinish)

		local oc = merged.opacityCurve or {start=1, mid=1, finish=1}
		local o1, o2, o3 = parseCurve(oc, 1)
		self.opacityCurve = {o1, o2, o3}
		self._hasOpacityCurve = not (o1==1 and o2==1 and o3==1)

		self.visualUpdateStep = math.clamp(tonumber(merged.visualUpdateStep) or 1, 1, 8)
		self.sizeUpdateStep   = math.clamp(tonumber(merged.sizeUpdateStep)   or 1, 1, 8)

	end

	-- глобальная скорость
	self.globalSpeedCurve = {parseCurve(merged.globalSpeedCurve or DEFAULT_CONFIG.globalSpeedCurve, 1)}

	self.steerNoiseAmplitude = math.max(0, tonumber(merged.steerNoiseAmplitude) or 0)
	self.steerNoiseFrequency = math.max(0, tonumber(merged.steerNoiseFrequency) or 0)
	self._useSteerNoise = (self.steerNoiseAmplitude > 0) and (self.steerNoiseFrequency > 0)
	if merged.steerNoiseSeed ~= nil then
		self.steerNoiseSeed = tonumber(merged.steerNoiseSeed)
	else
		-- Наследуем по цепочке: size -> life -> rate -> (fallback позже из state.prngSeed)
		self.steerNoiseSeed = self.sizeNoiseSeed or self.lifeNoiseSeed or self.rateNoiseSeed
	end

	-- кривые per-particle
	local curves = {}
	local curveDefs = merged.perParticleCurves or {}
	curves.speed = {parseCurve(curveDefs.speed, 1)}
	curves.size = {parseCurve(curveDefs.size, 1)}
	curves.rotationX = {parseCurve(curveDefs.rotationX, 1)}
	curves.rotationY = {parseCurve(curveDefs.rotationY, 1)}
	curves.rotationZ = {parseCurve(curveDefs.rotationZ, 1)}
	curves.turbulence = {parseCurve(curveDefs.turbulence, 1)}
	curves.returnForce = {parseCurve(curveDefs.returnForce, 1)}
	curves.steerYaw   = {parseCurve(curveDefs.steerYaw,   1)}
	curves.steerPitch = {parseCurve(curveDefs.steerPitch, 1)}
	curves.steerRoll  = {parseCurve(curveDefs.steerRoll,  1)}

	self.curves = curves

	local perParticle = merged.perParticle or DEFAULT_CONFIG.perParticle
	local ranges = {}
	ranges.speedMin, ranges.speedMax = parseRange(perParticle.speed, DEFAULT_CONFIG.perParticle.speed.min, DEFAULT_CONFIG.perParticle.speed.max)
	ranges.lifeMin, ranges.lifeMax = parseRange(perParticle.life, DEFAULT_CONFIG.perParticle.life.min, DEFAULT_CONFIG.perParticle.life.max)
	ranges.angleMin, ranges.angleMax = parseRange(perParticle.angle, DEFAULT_CONFIG.perParticle.angle.min, DEFAULT_CONFIG.perParticle.angle.max)
	ranges.sizeMin, ranges.sizeMax = parseRange(perParticle.size, DEFAULT_CONFIG.perParticle.size.min, DEFAULT_CONFIG.perParticle.size.max)
	ranges.rotXMin, ranges.rotXMax = parseRange(perParticle.rotationX, DEFAULT_CONFIG.perParticle.rotationX.min, DEFAULT_CONFIG.perParticle.rotationX.max)
	ranges.rotYMin, ranges.rotYMax = parseRange(perParticle.rotationY, DEFAULT_CONFIG.perParticle.rotationY.min, DEFAULT_CONFIG.perParticle.rotationY.max)
	ranges.rotZMin, ranges.rotZMax = parseRange(perParticle.rotationZ, DEFAULT_CONFIG.perParticle.rotationZ.min, DEFAULT_CONFIG.perParticle.rotationZ.max)
	ranges.turbMin, ranges.turbMax = parseRange(perParticle.turbulence, 0, 0)
	ranges.returnMin, ranges.returnMax = parseRange(perParticle.returnForce, 0, 0)

	ranges.steerYawMin,   ranges.steerYawMax   = parseRange(perParticle.steerYaw,   0, 0)
	ranges.steerPitchMin, ranges.steerPitchMax = parseRange(perParticle.steerPitch, 0, 0)
	ranges.steerRollMin,  ranges.steerRollMax  = parseRange(perParticle.steerRoll,  0, 0)


	-- новые диапазоны цвета/альфы
	do
		local cmin, cmax = _parseColorRange(perParticle.color, Color3.new(1,1,1), Color3.new(1,1,1))
		ranges.colorMin, ranges.colorMax = cmin, cmax
		ranges.opacityMin, ranges.opacityMax = parseRange(perParticle.opacity, 1, 1)
	end

	self.ranges = ranges

	self.enableTurbulence = math.abs(ranges.turbMin) > 0 or math.abs(ranges.turbMax) > 0
	self.enableReturn = math.abs(ranges.returnMin) > 0 or math.abs(ranges.returnMax) > 0

	-- «быстрый выход» по ориентации
	self._needRotation =
		not (ranges.rotXMin == 0 and ranges.rotXMax == 0
			and  ranges.rotYMin == 0 and ranges.rotYMax == 0
			and  ranges.rotZMin == 0 and ranges.rotZMax == 0
			and (not self.curves.rotationX or (self.curves.rotationX[1]==1 and self.curves.rotationX[2]==1 and self.curves.rotationX[3]==1))
			and (not self.curves.rotationY or (self.curves.rotationY[1]==1 and self.curves.rotationY[2]==1 and self.curves.rotationY[3]==1))
			and (not self.curves.rotationZ or (self.curves.rotationZ[1]==1 and self.curves.rotationZ[2]==1 and self.curves.rotationZ[3]==1)))

	self.turbulenceAntiJitter = (merged.turbulenceAntiJitter == true)
	self.ignoreVisibilityCulling = (merged.ignoreVisibilityCulling == true)
	self.localSpace = (merged.localSpace == true)
	self.faceMovement = (merged.faceMovement == true)

	-- Пер-эмиттерный FPS
	do
		local tfps = tonumber(merged.targetFps)
		if tfps ~= 30 then tfps = 60 end
		self.targetFps = tfps
		self._simFps = tfps
		self._simStep = (tfps == 30) and SIM_STEP_30 or SIM_STEP_60
		self._isFixed30 = (tfps == 30)
		self._simAccumulator = self._simAccumulator or 0
		if self._hasAccelerationDrag then
			VoxelMotionIntegrator.ConfigureAccelerationDragStep(
				self._accelerationDragStep,
				self.accelerationDrag,
				self._simStep
			)
		end
	end

	self._needSteer =
		not (ranges.steerYawMin == 0 and ranges.steerYawMax == 0
			and  ranges.steerPitchMin == 0 and ranges.steerPitchMax == 0
			and  ranges.steerRollMin == 0 and ranges.steerRollMax == 0
			and (not self.curves.steerYaw   or (self.curves.steerYaw[1]==1 and self.curves.steerYaw[2]==1 and self.curves.steerYaw[3]==1))
			and (not self.curves.steerPitch or (self.curves.steerPitch[1]==1 and self.curves.steerPitch[2]==1 and self.curves.steerPitch[3]==1))
			and (not self.curves.steerRoll  or (self.curves.steerRoll[1]==1 and self.curves.steerRoll[2]==1 and self.curves.steerRoll[3]==1)))

	if self.spawnDirectionMode == "curveNormal" then
		assert(self.spawnShape == "cubicBezier", "curveNormal direction mode requires cubicBezier spawn shape")
	end

	if self.spawnShape == "cylinderStream" then
		assert(self.spawnDirectionMode == "emission", "cylinderStream requires emission direction mode")
		local globalSpeed = self.globalSpeedCurve
		local particleSpeed = self.curves.speed
		assert(
			math.abs(self.emissionDirection:Dot(self.cylinderStreamAxis)) <= 1e-5,
			"cylinderStreamAxis must be perpendicular to emissionDirection"
		)
		assert(ranges.speedMin > 0 and ranges.speedMax > 0, "cylinderStream speed must be positive")
		assert(ranges.angleMin == 0 and ranges.angleMax == 0, "cylinderStream angle must be zero")
		assert(self.distanceSpeedFactor == 0, "cylinderStream distanceSpeedFactor must be zero")
		assert(
			globalSpeed[1] == 1 and globalSpeed[2] == 1 and globalSpeed[3] == 1
				and particleSpeed[1] == 1 and particleSpeed[2] == 1 and particleSpeed[3] == 1,
			"cylinderStream speed curves must be constant"
		)
		assert(self.wind == Vector3.zero and not self._hasAccel, "cylinderStream forces must be zero")
		assert(not self.enableTurbulence and not self.enableReturn, "cylinderStream path modifiers must be zero")
		assert(not self._needSteer, "cylinderStream steering must be zero")
		assert(not self._useLifeNoise, "cylinderStream life noise must be disabled")
		assert(not self.localSpace, "cylinderStream must use world-space particles")
	end

	-- пер-эмиттерные служебные
	self._serial = self._serial or 0
	-- если указан seed, используем его; иначе берём быстрый таймер
	if config and config.seed then
		self._seed32 = _u32(tonumber(config.seed) or 1)
	else
		self._seed32 = _u32(math.floor((os.clock()*1000000) % 0xFFFFFFFF))
	end
	self._lastAnchorCF = self.anchor and self.anchor.CFrame or self._lastAnchorCF
end

--============== Спавн одной частицы ==============

function Emitter:_spawnOne(): boolean
	if self._alive >= self.maxParticles then
		return false
	end
	local anchor = self.anchor
	if not anchor or not anchor.Parent then
		return false
	end
	local part = acquireCube()
	if not part then
		return false
	end
	-- A new population starts at the current anchor transform, including after
	-- pool warmup or camera culling while a local-space anchor was moving.
	if self.localSpace and self._alive == 0 then
		self._lastAnchorCF = anchor.CFrame
		self._lastAnchorFrame = nil
		self._anchorDelta = nil
	end

	self._alive += 1

	part.Material = self.material

	-- локальный PRNG из сидов эмиттера
	self._serial += 1
	local pseed = _u32(_hash32(_u32(self._seed32 + self._serial)))
	self._spawnPRNG = self._spawnPRNG or { prngSeed = 0, prngCounter = 0 }
	local _tmpState = self._spawnPRNG
	_tmpState.prngSeed = pseed
	_tmpState.prngCounter = 0


	local ranges = self.ranges

	local life  = _p_next_number(_tmpState, ranges.lifeMin,  ranges.lifeMax)

	-- Плавающий lifetime: мультипликатор в [1-amp .. 1+amp], синхронизируемым сидом
	if self._useLifeNoise then
		local t = _rateNoiseClock * self.lifeNoiseFrequency
		local seed = (self.lifeNoiseSeed ~= nil) and self.lifeNoiseSeed
			or (self.rateNoiseSeed ~= nil) and self.rateNoiseSeed
			or self._seed32
		local n = waveNoiseCached(t, seed)
		local mul = 1 + self.lifeNoiseAmplitude * n
		if mul < 0 then mul = 0 end
		life = life * mul
	end


	local speed = _p_next_number(_tmpState, ranges.speedMin, ranges.speedMax)
	local sizeValue = _p_next_number(_tmpState, ranges.sizeMin, ranges.sizeMax)
	local sizeVector = Vector3.new(sizeValue, sizeValue, sizeValue)
	part.Size = sizeVector

	-- ЛОКАЛЬНОЕ направление из пресета (в осях эмиттера).
	-- Здесь self.emissionDirection трактуем как ЛОКАЛЬНЫЙ вектор.
	local localDir = self.emissionDirection
	if localDir.Magnitude == 0 then
		localDir = Vector3.new(0, 1, 0)
	end

	-- Переводим локальный вектор в мировые координаты относительно CFrame якоря.
	-- Именно это и даёт «угол эмиттера + смещение из пресета».
	local worldDir = anchor.CFrame:VectorToWorldSpace(localDir)
	if worldDir.Magnitude == 0 then
		worldDir = Vector3.new(0, 1, 0)
	end

	-- смещение спавна: используем копию состояния PRNG, затем синхронизируем основной счётчик
	local dirUnit = worldDir.Unit
	local offsetState = {
		prngSeed = _tmpState.prngSeed,
		prngCounter = _tmpState.prngCounter,
	}
	local offset
	local streamTravelDistance
	local curveTangent
	if self.spawnShape == "cylinderStream" then
		local worldAxis = anchor.CFrame:VectorToWorldSpace(self.cylinderStreamAxis)
		offset, streamTravelDistance = VoxelCylinderStream.Sample(
			worldDir,
			worldAxis,
			self.cylinderStreamRadius,
			self.cylinderStreamHalfHeight,
			_p_next01(offsetState),
			_p_next_open01(offsetState)
		)
	elseif self.spawnShape == "cubicBezier" then
		local localOffset, localTangent = VoxelCubicBezier.Sample(
			self._cubicBezierLut,
			_p_next01(offsetState)
		)
		offset = anchor.CFrame:VectorToWorldSpace(localOffset)
		curveTangent = anchor.CFrame:VectorToWorldSpace(localTangent).Unit
	else
		offset = _spawnOffset(
			self.spawnShape,
			self.spawnSize,
			worldDir,
			self.spawnSurfaceOnly,
			self.spawnInnerRadius,
			offsetState
		)
	end
	_tmpState.prngCounter = offsetState.prngCounter


	local radial = offset
	local planar = radial - dirUnit * radial:Dot(dirUnit)
	local planarMagnitudeSquared = planar:Dot(planar)
	local radialMagnitude = radial.Magnitude
	if self.distanceSpeedFactor ~= 0 then
		local maxExtent = self._spawnMaxExtent or 0
		if maxExtent > 1e-6 then
			local normalizedDistance = math.clamp(radialMagnitude / maxExtent, 0, 1)
			local multiplier = 1 + self.distanceSpeedFactor * (normalizedDistance - 0.5)
			if multiplier < 0 then
				multiplier = 0
			end
			speed *= multiplier
		end
	end
	if streamTravelDistance then
		life = streamTravelDistance / speed
	end

	-- направление в конусе (на базе PRNG)
	local baseDirection = (function()
		local minA = math.clamp(math.rad(ranges.angleMin), 0, math.pi)
		local maxA = math.clamp(math.rad(ranges.angleMax), 0, math.pi)
		if minA > maxA then minA, maxA = maxA, minA end
		if self.spawnDirectionMode == "curveNormal" then
			local _, normal, bitangent = _basisFromDir(curveTangent)
			local normalAngle = _p_next_number(_tmpState, 0, math.pi * 2)
			local normalDirection = (normal * math.cos(normalAngle) + bitangent * math.sin(normalAngle)).Unit
			return _sampleConeDirection(normalDirection, minA, maxA, _tmpState)
		elseif radialMagnitude > 1e-6 and self.spawnDirectionMode == "radialOutward" then
			return _sampleConeDirection(radial / radialMagnitude, minA, maxA, _tmpState)
		elseif radialMagnitude > 1e-6 and self.spawnDirectionMode == "radialTangent" then
			local radialDirection = radial / radialMagnitude
			local reference = if math.abs(radialDirection.Y) < 0.92 then Vector3.yAxis else Vector3.xAxis
			local tangent = radialDirection:Cross(reference).Unit
			local bitangent = radialDirection:Cross(tangent).Unit
			local tangentAngle = _p_next_number(_tmpState, 0, math.pi * 2)
			local tangentDirection = (tangent * math.cos(tangentAngle) + bitangent * math.sin(tangentAngle)).Unit
			return _sampleConeDirection(tangentDirection, minA, maxA, _tmpState)
		end
		local cosMin, cosMax = math.cos(minA), math.cos(maxA)
		if cosMin < cosMax then cosMin, cosMax = cosMax, cosMin end
		local cosTheta = _p_next_number(_tmpState, cosMax, cosMin)
		local sinTheta = math.sqrt(math.max(0, 1 - cosTheta*cosTheta))
		if planarMagnitudeSquared > 1e-12 and radialMagnitude > 1e-6 then
			local radialDir = radial / radialMagnitude
			local cosAlpha = math.clamp(dirUnit:Dot(radialDir), -1, 1)
			local sinAlphaSq = math.max(0, 1 - cosAlpha * cosAlpha)
			if sinAlphaSq > 1e-12 then
				local invSinAlpha = 1 / math.sqrt(sinAlphaSq)
				local R = (radialDir - dirUnit * cosAlpha) * invSinAlpha
				local candidate = R * sinTheta + dirUnit * cosTheta
				local candidateMagnitude = candidate.Magnitude
				if candidateMagnitude > 0 then
					return candidate / candidateMagnitude
				end
			end
		end
		local idx = 1 + math.floor(_p_next01(_tmpState) * _LUT_N)
		if idx > _LUT_N then idx = _LUT_N end
		local sinPhi = _SIN_LUT[idx]
		local cosPhi = _COS_LUT[idx]

		local x = sinTheta * cosPhi
		local y = cosTheta
		local z = sinTheta * sinPhi
		local D, Rb, Fb = _basisFromDir(worldDir)
		return (Rb * x + D * y + Fb * z).Unit

	end)()

	-- спавн-геометрия
	local origin   = anchor.Position
	local position = origin + offset
	part.CFrame = CFrame.new(position)
	-- Начальный базис руления: оси (Right, Up) перпендикулярны текущему направлению
	local steerUp = (math.abs(baseDirection.Y) > 0.99) and Vector3.new(1,0,0) or Vector3.new(0,1,0)
	local steerRight = baseDirection:Cross(steerUp)
	if steerRight.Magnitude < 1e-6 then steerUp = Vector3.new(0,0,1); steerRight = baseDirection:Cross(steerUp) end
	steerRight = steerRight.Unit
	steerUp = steerRight:Cross(baseDirection).Unit


	-- углы/вращения
	local rotX = math.rad(_p_next_number(_tmpState, ranges.rotXMin, ranges.rotXMax))
	local rotY = math.rad(_p_next_number(_tmpState, ranges.rotYMin, ranges.rotYMax))
	local rotZ = math.rad(_p_next_number(_tmpState, ranges.rotZMin, ranges.rotZMax))
	-- Самолётик: базовые скоростИ руления (рад/с)
	local steerYawRate   = math.rad(_p_next_number(_tmpState, ranges.steerYawMin,   ranges.steerYawMax))
	local steerPitchRate = math.rad(_p_next_number(_tmpState, ranges.steerPitchMin, ranges.steerPitchMax))
	local steerRollRate  = math.rad(_p_next_number(_tmpState, ranges.steerRollMin,  ranges.steerRollMax))


	-- спираль/турбулентность/возврат
	local turbulenceStrength = self.enableTurbulence and _p_next_number(_tmpState, ranges.turbMin, ranges.turbMax) or 0
	local returnStrength = self.enableReturn and _p_next_number(_tmpState, ranges.returnMin, ranges.returnMax) or 0

	-- per-particle цвет/альфа
	local colRand = Color3.new(
		_p_next_number(_tmpState, ranges.colorMin.R, ranges.colorMax.R),
		_p_next_number(_tmpState, ranges.colorMin.G, ranges.colorMax.G),
		_p_next_number(_tmpState, ranges.colorMin.B, ranges.colorMax.B)
	)
	local baseColor = Color3.new(
		math.clamp(self.color.R * colRand.R, 0, 1),
		math.clamp(self.color.G * colRand.G, 0, 1),
		math.clamp(self.color.B * colRand.B, 0, 1)
	)
	local baseOpacity = math.clamp(_p_next_number(_tmpState, ranges.opacityMin, ranges.opacityMax), 0, 1)

	-- Применяем кривые сразу на старте (progress = 0), чтобы не было «подрыва»
	local initColor = baseColor
	if self._hasColorCurve then
		local cmul0 = _evalColorCurve(0, self.colorCurveStart, self.colorCurveMid, self.colorCurveFinish)
		initColor = Color3.new(
			math.clamp(baseColor.R * cmul0.R, 0, 1),
			math.clamp(baseColor.G * cmul0.G, 0, 1),
			math.clamp(baseColor.B * cmul0.B, 0, 1)
		)
	end
	part.Color = initColor

	local initAlpha = baseOpacity
	if self._hasOpacityCurve or baseOpacity ~= 1 then
		local om0 = evaluateCurve(0, self.opacityCurve[1], self.opacityCurve[2], self.opacityCurve[3])
		initAlpha = math.clamp(baseOpacity * om0, 0, 1)
	end
	part.Transparency = 1 - initAlpha
	-- [ADD LINES] — маска на первые 2 кадра
	part.LocalTransparencyModifier = 1
	_UNMASK_AT[part] = _frameSerial + UNMASK_FRAMES

	-- Делаем видимым только теперь, когда всё выставлено  [ADD LINE]
	-- [ADD LINES] показать частицу после полной инициализации, без вспышки
	part.Parent = LIVE_FOLDER
	part.LocalTransparencyModifier = 0



	local state: ParticleState = {
		emitter = self,
		part = part,
		age = 0,
		life = life,
		origin = origin,
		position = position,
		baseDirection = baseDirection,
		baseSpeed = speed,
		accelerationVelocity = Vector3.zero,
		baseSize = sizeVector,
		baseAngularVelocity = Vector3.new(rotX, rotY, rotZ),
		angularAngles = Vector3.new(0, 0, 0),

		turbulenceStrength = turbulenceStrength,
		turbulenceVelocity = Vector3.zero,
		turbulenceTarget = Vector3.zero,
		turbulenceTimer = 0,

		returnStrength = returnStrength,

		prngSeed = pseed,
		prngCounter = 0,

		baseColor = baseColor,
		baseOpacity = baseOpacity,

		_tickVisual = self.visualUpdateStep - 1,
		_tickSize   = 0,


		steerYawRate = steerYawRate,
		steerPitchRate = steerPitchRate,
		steerRollRate = steerRollRate,
		steerRight = steerRight,
		steerUp = steerUp,
		renderPrev = part.CFrame,
		renderCurr = part.CFrame,

	}

	state.index = #particles + 1
	particles[state.index] = state
	self._particles[state] = true
	return true
end

--============== Эмиссия (с учётом LOD/отсечения) ==============

function Emitter:_updateEmission(dt: number)
	local anchor = self.anchor
	if not anchor or not anchor.Parent then
		return
	end

	local rateMul = self._cameraScale
	if rateMul <= 0 then
		return
	end

	-- Плавающий rate (мультипликатор [1-amp .. 1+amp])
	if self._useRateNoise then
		local t = _rateNoiseClock * self.rateNoiseFrequency
		local seed = (self.rateNoiseSeed ~= nil) and self.rateNoiseSeed or self._seed32
		local n = waveNoiseCached(t, seed)

		local noiseMul = 1 + self.rateNoiseAmplitude * n
		if noiseMul < 0 then noiseMul = 0 end
		self._lastRateNoiseMul = noiseMul
		rateMul *= noiseMul
	else
		self._lastRateNoiseMul = 1.0
	end

	-- Глобальный «мягкий» бюджет по тоталу
	rateMul *= _budgetMul()

	-- Копим спрос на спавн, но не спавним здесь
	self._accumulator += dt * self.rate * rateMul
	local toEmit = math.floor(self._accumulator)
	if toEmit <= 0 then
		return
	end
	self._accumulator -= toEmit

	-- Локальные ограничения на кадр и оставшуюся ёмкость эмиттера
	if toEmit > MAX_SPAWN_PER_FRAME then
		toEmit = MAX_SPAWN_PER_FRAME
	end
	local localCap = self.maxParticles - self._alive
	if localCap <= 0 then
		return
	end
	if toEmit > localCap then
		toEmit = localCap
	end

	-- Копим «спрос» этого эмиттера на текущий кадр
	self._spawnDemand = (self._spawnDemand or 0) + toEmit
	-- Мягкое ограничение бэклога, чтобы не копить бесконечно
	local backlogCap = math.min(self.maxParticles - self._alive, MAX_SPAWN_PER_FRAME * 4)
	if backlogCap < 0 then backlogCap = 0 end
	if self._spawnDemand > backlogCap then
		self._spawnDemand = backlogCap
	end

end



--============== Шаг частицы ==============

local RETURN_ACTIVATION = 0.3

function Emitter:_stepParticle(state: ParticleState, dt: number, drySimulate: boolean?): boolean        -- Fail-safe: частица продолжает жить даже если якорь исчез; новые просто не спавнятся.
	-- (см. _updateEmission)
	drySimulate = (drySimulate == true)
	-- Local Space: применяем один и тот же дельта‑трансформ на все частицы эмиттера в текущем кадре
	if self.localSpace and self.anchor and self.anchor.Parent and self._lastAnchorCF then
		local curr = self.anchor.CFrame
		-- вычисляем дельту ровно один раз на кадр
		if self._lastAnchorFrame ~= _frameSerial then
			self._anchorDelta = curr * self._lastAnchorCF:Inverse()
			self._lastAnchorCF = curr
			self._lastAnchorFrame = _frameSerial
		end
		local delta = self._anchorDelta
		if delta then
			state.position      = delta:PointToWorldSpace(state.position)
			state.origin        = delta:PointToWorldSpace(state.origin)
			state.baseDirection = delta:VectorToWorldSpace(state.baseDirection).Unit
			state.steerRight = delta:VectorToWorldSpace(state.steerRight).Unit
			state.steerUp    = delta:VectorToWorldSpace(state.steerUp).Unit


		end
	end


	state.age += dt
	if state.age >= state.life then
		return false
	end

	local progress = state.age / state.life

	local gs = self.globalSpeedCurve
	local speedScale = evaluateCurve(progress, gs[1], gs[2], gs[3])
	local curves = self.curves

	local perSpeed = curves.speed
	if perSpeed then
		speedScale *= evaluateCurve(progress, perSpeed[1], perSpeed[2], perSpeed[3])
	end

	local currentSpeed = state.baseSpeed * speedScale
	local velocity = state.baseDirection * currentSpeed

	if self.wind.Magnitude > 0 then
		velocity += self.wind
	end

	-- Турбулентность (анти-джиттер по флагу)
	if self.enableTurbulence and state.turbulenceStrength ~= 0 then
		local turbCurve = curves.turbulence
		local turbScale = 1
		if turbCurve then
			turbScale = evaluateCurve(progress, turbCurve[1], turbCurve[2], turbCurve[3])
		end
		if turbScale ~= 0 then
			state.turbulenceTimer -= dt
			if state.turbulenceTimer <= 0 then
				local theta = 2*math.pi*_p_next01(state)
				local z = _p_next_number(state, -1, 1)
				local r = math.sqrt(math.max(0, 1 - z*z))
				local rnd = Vector3.new(r*math.cos(theta), z, r*math.sin(theta))
				state.turbulenceTarget = rnd * state.turbulenceStrength * turbScale
				local nextT = self.turbulenceAntiJitter and 0.10 or (0.08 + _p_next01(state) * 0.12)
				state.turbulenceTimer = nextT
			end
			local lerpAlpha = self.turbulenceAntiJitter and 0.10 or math.clamp(dt * 4, 0, 1)
			state.turbulenceVelocity = state.turbulenceVelocity:Lerp(state.turbulenceTarget, lerpAlpha)
			velocity += state.turbulenceVelocity
		end
	end

	-- Возврат к origin на хвосте жизни
	if self.enableReturn and state.returnStrength ~= 0 then
		-- Отрицательное значение return force действует сразу, положительное ждёт активацию
		local shouldApply = state.returnStrength < 0 or progress >= RETURN_ACTIVATION
		if shouldApply then
			local returnCurve = curves.returnForce
			local returnScale = 1
			if returnCurve then
				returnScale = evaluateCurve(progress, returnCurve[1], returnCurve[2], returnCurve[3])
			end
			if returnScale ~= 0 then
				local toOrigin = state.origin - state.position
				local remaining = math.max(state.life - state.age, 1e-3)
				velocity += (toOrigin / remaining) * state.returnStrength * returnScale
			end
		end
	end

	-- Руление направления (самолётик): roll влияет на локальную рамку yaw/pitch
	if self._needSteer then
		local sc = self.curves
		local yawRate   = state.steerYawRate
		local pitchRate = state.steerPitchRate
		local rollRate  = state.steerRollRate

		if sc.steerYaw   then yawRate   *= evaluateCurve(progress, sc.steerYaw[1],   sc.steerYaw[2],   sc.steerYaw[3]) end
		if sc.steerPitch then pitchRate *= evaluateCurve(progress, sc.steerPitch[1], sc.steerPitch[2], sc.steerPitch[3]) end
		if sc.steerRoll  then rollRate  *= evaluateCurve(progress, sc.steerRoll[1],  sc.steerRoll[2],  sc.steerRoll[3]) end

		-- Пер-частичный нойз руления: множитель (1 + amp * noise(age * freq, seed_axis))
		if self._useSteerNoise then
			local t = state.age * self.steerNoiseFrequency
			local baseSeed = self.steerNoiseSeed or self.sizeNoiseSeed or self.lifeNoiseSeed or self.rateNoiseSeed or state.prngSeed
			local nYaw   = waveNoiseCached(t, baseSeed + 101)
			local nPitch = waveNoiseCached(t, baseSeed + 202)
			local nRoll  = waveNoiseCached(t, baseSeed + 303)

			local mul = self.steerNoiseAmplitude
			yawRate   = yawRate   * math.max(0, 1 + mul * nYaw)
			pitchRate = pitchRate * math.max(0, 1 + mul * nPitch)
			rollRate  = rollRate  * math.max(0, 1 + mul * nRoll)
		end

		-- Применяем малые повороты за шаг (в радианах)
		local dRoll  = rollRate  * dt
		local dYaw   = yawRate   * dt
		local dPitch = pitchRate * dt

		-- roll: вращаем локальные оси вокруг текущего направления
		if dRoll ~= 0 then
			state.steerRight = _rotateAroundAxis(state.steerRight, state.baseDirection, dRoll).Unit
			state.steerUp    = _rotateAroundAxis(state.steerUp,    state.baseDirection, dRoll).Unit
		end

		-- yaw: поворачиваем направление вокруг локальной Up
		if dYaw ~= 0 then
			state.baseDirection = _rotateAroundAxis(state.baseDirection, state.steerUp, dYaw).Unit
			-- переортонормируем локальные оси от нового направления
			state.steerRight = state.baseDirection:Cross(state.steerUp).Unit
			state.steerUp    = state.steerRight:Cross(state.baseDirection).Unit
		end

		-- pitch: поворачиваем направление вокруг локального Right
		if dPitch ~= 0 then
			state.baseDirection = _rotateAroundAxis(state.baseDirection, state.steerRight, dPitch).Unit
			-- переортонормируем
			state.steerUp    = state.steerRight:Cross(state.baseDirection).Unit
			state.steerRight = state.baseDirection:Cross(state.steerUp).Unit
		end

		-- Пересобрать скорость с учётом руления
		velocity = state.baseDirection * currentSpeed + (velocity - state.baseDirection * currentSpeed)
	end

	-- Acceleration is world-axis velocity change, matching Roblox particle semantics.
	-- The existing base/wind/turbulence/return velocity remains kinematic input.
	local accel = Vector3.zero
	if self._hasAccel then
		local aScale = evaluateCurve(progress, self.accelCurve[1], self.accelCurve[2], self.accelCurve[3])
		if aScale ~= 0 then
			accel = self.acceleration * aScale
		end
	end
	if self._hasAccel or state.accelerationVelocity ~= Vector3.zero then
		velocity = VoxelMotionIntegrator.Step(
			state,
			velocity,
			accel,
			dt,
			self._hasAccelerationDrag and self._accelerationDragStep or nil
		)
	else
		state.position += velocity * dt
	end


	-- углы/вращение
	do
		local angularVel = state.baseAngularVelocity
		local rotCurves = self.curves
		local rxCurve = rotCurves.rotationX
		local ryCurve = rotCurves.rotationY
		local rzCurve = rotCurves.rotationZ
		local rx = angularVel.X
		local ry = angularVel.Y
		local rz = angularVel.Z
		if rxCurve then
			rx *= evaluateCurve(progress, rxCurve[1], rxCurve[2], rxCurve[3])
		end
		if ryCurve then
			ry *= evaluateCurve(progress, ryCurve[1], ryCurve[2], ryCurve[3])
		end
		if rzCurve then
			rz *= evaluateCurve(progress, rzCurve[1], rzCurve[2], rzCurve[3])
		end
		state.angularAngles += Vector3.new(rx, ry, rz) * dt
	end

	-- кривые цвета/прозрачности (с квантованием записи)
	state._tickVisual += 1
	local doVisualWrite = (state._tickVisual % self.visualUpdateStep) == 0

	if doVisualWrite and self._hasColorCurve then
		local cmul = _evalColorCurve(progress, self.colorCurveStart, self.colorCurveMid, self.colorCurveFinish)
		local c = Color3.new(
			math.clamp(state.baseColor.R * cmul.R, 0, 1),
			math.clamp(state.baseColor.G * cmul.G, 0, 1),
			math.clamp(state.baseColor.B * cmul.B, 0, 1)
		)
		state.part.Color = c
	end

	if doVisualWrite and (self._hasOpacityCurve or state.baseOpacity ~= 1) then
		local om = evaluateCurve(progress, self.opacityCurve[1], self.opacityCurve[2], self.opacityCurve[3])
		local alpha = math.clamp(state.baseOpacity * om, 0, 1)
		state.part.Transparency = 1 - alpha
	end


	-- размер
	local sizeCurve = self.curves.size
	local sizeMultiplier = 1
	if sizeCurve then
		sizeMultiplier = evaluateCurve(progress, sizeCurve[1], sizeCurve[2], sizeCurve[3])
	end

	-- Пер-частичный временной нойз масштаба (общая частота и сид при желании)
	if self._useSizeNoise then
		local t = state.age * self.sizeNoiseFrequency -- «время» нойза = возраст частицы
		-- сид берём по цепочке: явный -> life -> rate -> (fallback) per-particle seed
		local seed = (self.sizeNoiseSeed ~= nil and self.sizeNoiseSeed)
			or self.lifeNoiseSeed or self.rateNoiseSeed or state.prngSeed
		local n = waveNoiseCached(t, seed)
		sizeMultiplier *= math.max(0, 1 + self.sizeNoiseAmplitude * n)
	end

	sizeMultiplier = math.max(sizeMultiplier, 0.01)

	state._tickSize += 1
	if (state._tickSize % self.sizeUpdateStep) == 0 then
		state.part.Size = state.baseSize * sizeMultiplier
	end


	-- ранний выход по ориентации
	-- ориентация + подготовка CFrame
	do
		local cf: CFrame
		if self.faceMovement then
			local dir = (velocity.Magnitude > 1e-6) and velocity.Unit or state.baseDirection
			local up  = state.steerUp
			cf = CFrame.lookAt(state.position, state.position + dir, up)
			if self._needRotation then
				cf = cf * CFrame.fromEulerAnglesXYZ(state.angularAngles.X, state.angularAngles.Y, state.angularAngles.Z)
			end
		else
			if self._needRotation then
				cf = CFrame.new(state.position) * CFrame.fromEulerAnglesXYZ(
					state.angularAngles.X, state.angularAngles.Y, state.angularAngles.Z
				)
			else
				cf = CFrame.new(state.position)
			end
		end

		-- Сохраняем прошлый/текущий для интерполяции
		local prev = state.renderCurr or cf
		state.renderPrev = prev
		state.renderCurr = cf

		-- Если считаем на каждом кадре (60 FPS) — сразу пишем в буфер BulkMoveTo
		if not drySimulate then
			local idx = #MOVE_PARTS + 1
			MOVE_PARTS[idx]   = state.part
			MOVE_CFRAMES[idx] = cf
		end
	end

	return true

end

--============== Публичный API ==============

function Emitter:Emit(count: number): number
	if self._destroyed then
		return 0
	end

	count = math.max(0, math.floor(tonumber(count) or 0))
	if count == 0 then
		return 0
	end

	local cameraScale = self:_getCameraScale()
	if cameraScale <= 0 or not self:_updateLineOfSight(true) then
		return 0
	end
	count = math.floor(count * cameraScale * _qualityMultiplier)
	if count <= 0 then
		return 0
	end

	-- Мягкий глобальный шейпер (как и для rate)
	local budgetMul = _budgetMul()
	if budgetMul < 1 then
		count = math.max(0, math.floor(count * budgetMul))
		if count == 0 then
			return 0
		end
	end

	-- Repeated bursts share the same bounded queue.
	local localCap = self.maxParticles - self._alive - (self._spawnDemand or 0)
	if localCap <= 0 then
		return 0
	end
	if count > localCap then
		count = localCap
	end

	-- Per‑emitter cap на кадр, чтобы убрать пиковую нагрузку
	if count > MAX_SPAWN_PER_FRAME then
		count = MAX_SPAWN_PER_FRAME
	end

	-- Не спавним немедленно: копим запрос и отдаём в общий кадровый аллокатор
	self._spawnDemand = (self._spawnDemand or 0) + count
	self._burstDemand = (self._burstDemand or 0) + count

	-- Гарантируем, что луп крутится
	ensureUpdateLoop()
	-- Возвращаем поставленный в очередь объём (фактический спавн распределит кадровый аллокатор)
	return count
end


function Emitter:SetEnabled(enabled: boolean)
	if self._destroyed then
		return
	end

	if enabled then
		if self._enabled then
			return
		end
		self._enabled = true
		ensureUpdateLoop()

		if self._burstOnEnable and not self._burstConsumed and self._baseRate <= 0 then
			local burstCount = self.burstCount or 0
			if burstCount > 0 then
				self:Emit(burstCount)
			end
			self._burstConsumed = true
			self._enabled = false
			return
		end
	else
		if not self._enabled then
			return
		end
		self._enabled = false
	end
end
function Emitter:IsEnabled(): boolean
	return self._enabled
end

function Emitter:Configure(config)
	self:_applyConfig(config)
end

function Emitter:SetCubicBezier(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3)
	assert(self.spawnShape == "cubicBezier", "SetCubicBezier requires cubicBezier spawn shape")
	local lut = VoxelCubicBezier.Rebuild(self._cubicBezierLut, p0, p1, p2, p3)
	self.cubicBezierPoints[1] = p0
	self.cubicBezierPoints[2] = p1
	self.cubicBezierPoints[3] = p2
	self.cubicBezierPoints[4] = p3
	self._cubicBezierLut = lut
	self._spawnMaxExtent = VoxelCubicBezier.MaxControlExtent(lut)
end

function Emitter:GetRateNoiseSample(): number
	-- Возвращает текущий множитель нойза рэйта (1.0, если нойз отключён)
	return self._lastRateNoiseMul or 1.0
end

function Emitter:SetAnchor(anchor: BasePart?)
	if self.anchor == anchor then
		if anchor and not self._lastAnchorCF then
			self._lastAnchorCF = anchor.CFrame
		end
		return
	end

	self.anchor = anchor
	if anchor then
		self._lastAnchorCF = anchor.CFrame
		self._lastAnchorFrame = nil
	else
		self._lastAnchorCF = nil
		self._lastAnchorFrame = nil
	end
	self._anchorDelta = nil
end

function Emitter:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._enabled = false
	self._admitted = false
	for index = #selectedEmitters, 1, -1 do
		if selectedEmitters[index] == self then
			table.remove(selectedEmitters, index)
			break
		end
	end
	for state in pairs(self._particles) do
		releaseParticle(state)
	end
	self._particles = {}
	for index = #emitters, 1, -1 do
		if emitters[index] == self then
			table.remove(emitters, index)
			break
		end
	end
	stopUpdateLoopIfIdle()
end

function VoxelParticleSystem.newEmitter(anchor: BasePart, config: any?): EmitterInstance
	local emitter = setmetatable({}, Emitter)
	emitter.anchor = anchor
	emitter._accumulator = 0
	emitter._particles = {}
	emitter._alive = 0
	emitter._spawnDemand = 0
	emitter._burstDemand = 0
	emitter._enabled = false
	emitter._admitted = false
	emitter._cameraScale = 0
	emitter._destroyed = false
	emitter._serial = 0
	emitter._seed32 = _u32(math.floor((os.clock()*1000000) % 0xFFFFFFFF))
	emitter._lastAnchorCF = anchor and anchor.CFrame or CFrame.new()
	emitter._visibilityElapsed = VISIBILITY_POLL_INTERVAL
	emitter._hasLineOfSight = true
	-- Пер-эмиттерный FPS (дефолт берём из DEFAULT_EMITTER_FPS, далее может переопределиться конфигом)
	emitter._simAccumulator = 0
	emitter.targetFps = DEFAULT_EMITTER_FPS
	emitter._simFps = emitter.targetFps
	emitter._simStep = (emitter._simFps == 30) and SIM_STEP_30 or SIM_STEP_60
	emitter._isFixed30 = (emitter._simFps == 30)
	emitter._accelerationDragStep = VoxelMotionIntegrator.CreateAccelerationDragStep()

	emitter:_applyConfig(config)
	table.insert(emitters, emitter)
	if config == nil or config.enabled ~= false then
		emitter:SetEnabled(true)
	end
	ensureUpdateLoop()
	return emitter
end

function VoxelParticleSystem.Attach(anchor: BasePart, config: any?): EmitterInstance
	return VoxelParticleSystem.newEmitter(anchor, config)
end

function VoxelParticleSystem.GetTotalAlive(): number
	return liveCount
end

function VoxelParticleSystem.GetDiagnostics(includeEmitters: boolean?)
	local result: any = {
		Version = 16,
		Frame = _frameSerial,
		Ready = #pool + liveCount >= _baseMaxTotalParticles,
		BaseCapacity = _baseMaxTotalParticles,
		MaxTotalParticles = MAX_TOTAL_PARTICLES,
		MaxActiveEmitters = maxActiveEmitters,
		MaxSpawnsPerFrame = math.floor(128 * _qualityMultiplier),
		FrameSpawnLimit = frameSpawnLimit,
		QualityMultiplier = _qualityMultiplier,
		RegisteredEmitters = #emitters,
		SelectedEmitters = #selectedEmitters,
		Alive = liveCount,
		Pooled = #pool,
		Allocated = #pool + liveCount,
		PartCreationsThisFrame = partCreationsThisFrame,
		SpawnsThisFrame = spawnsThisFrame,
	}
	if includeEmitters then
		local details = {}
		for _, emitter in emitters do
			table.insert(details, {
				Anchor = emitter.anchor and emitter.anchor:GetFullName() or "",
				Admitted = emitter._admitted,
				Alive = emitter._alive,
				Pending = emitter._spawnDemand,
				DistanceSquared = emitter._cameraDistanceSquared,
			})
		end
		result.Emitters = details
	end
	return result
end

function VoxelParticleSystem.SetMaxTotalParticles(count: number)
	assert(count == count and count < math.huge and count > 0, "Particle capacity must be a positive finite number")
	local newMax = math.max(1, math.floor(count))
	if newMax == _baseMaxTotalParticles then
		return
	end
	_baseMaxTotalParticles = newMax
	_applyQualityScaling()
	if RunService:IsClient() then
		ensureUpdateLoop()
	end
end


if RunService:IsClient() then
	_updateQualityMultiplier()
	_applyQualityScaling()
	_connectQualitySignals()
	ensureUpdateLoop()
else
	_applyQualityScaling()
end

return VoxelParticleSystem
