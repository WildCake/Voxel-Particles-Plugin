--!strict
-- Run from the repository root: lune run tools/test_simulation_pause.luau
-- Executes canonical runtime/dependencies with Lune datatypes and controlled frame/quality services.
-- This is a functional unit harness, not a Studio rendering or performance test.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local Instance = roblox.Instance
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3
local manifest = serde.decode("json", fs.readFile("plugin-package.json"))
local internalPath = manifest.sourceRoot .. "/Internal/"

roblox.implementMethod("Instance", "WaitForChild", function(instance: any, name: string): any
	return assert(instance:FindFirstChild(name), name)
end)
roblox.implementMethod("Camera", "WorldToViewportPoint", function(_camera: any, _position: any): (any, boolean)
	return Vector3.new(0, 0, 1), true
end)
roblox.implementMethod("Workspace", "BulkMoveTo", function(_workspace: any, parts: {any}, frames: {any})
	for index, part in parts do part.CFrame = frames[index] end
end)

local function createRuntime(): any
	local workspace = Instance.new("Workspace")
	local camera = Instance.new("Camera")
	camera.Parent = workspace
	workspace.CurrentCamera = camera
	local renderCallback: ((number) -> ())? = nil
	local qualityCallback: (() -> ())? = nil
	local multiplier = 1
	local connections = 0
	local services: any = {
		Workspace = workspace,
		ReplicatedStorage = Instance.new("ReplicatedStorage"),
		RunService = {
			IsClient = function(): boolean return true end,
			RenderStepped = {
				Connect = function(_self: any, callback: (number) -> ()): any
					assert(renderCallback == nil, "Duplicate render connection")
					renderCallback = callback
					connections += 1
					return { Disconnect = function() renderCallback = nil end }
				end,
			},
		},
	}
	local internal = Instance.new("Folder")
	for _, name in manifest.internalModules do
		local module = Instance.new("ModuleScript")
		module.Name = name
		module.Source = fs.readFile(internalPath .. name .. ".luau")
		module.Parent = internal
	end
	local cache: {[any]: any} = {}
	local loadModule: (any) -> any
	loadModule = function(module: any): any
		if cache[module] then return cache[module] end
		if module.Name == "ClientVfxQuality" then
			return {
				GetParticleMultiplier = function(): number return multiplier end,
				OnTierChanged = function(callback: () -> ()): any
					qualityCallback = callback
					return { Disconnect = function() qualityCallback = nil end }
				end,
			}
		end
		local env: any = table.clone(roblox)
		env.script = module
		env.game = { GetService = function(_self: any, name: string): any return assert(services[name], name) end }
		env.require = loadModule
		env.debug = { profilebegin = function() end, profileend = function() end }
		cache[module] = luau.load(module.Source, { environment = env, debugName = module.Name })()
		return cache[module]
	end
	local vps = loadModule(internal:FindFirstChild("VoxelParticleSystem"))
	vps.SetMaxTotalParticles(32)
	local function frame(dt: number)
		if renderCallback then renderCallback(dt) end
	end
	for _ = 1, 4 do frame(1 / 60) end
	assert(vps.GetDiagnostics().Ready)
	return {
		vps = vps,
		frame = frame,
		workspace = workspace,
		setQuality = function(value: number)
			multiplier = value
			if qualityCallback then qualityCallback() end
		end,
		connections = function(): number return connections end,
		isConnected = function(): boolean return renderCallback ~= nil end,
	}
end

local function attach(runtime: any, fps: number, localSpace: boolean): (any, any)
	local anchor = Instance.new("Part")
	anchor.CFrame = CFrame.new(0, 0, -10)
	anchor.Position = anchor.CFrame.Position -- Lune does not derive this engine property.
	anchor.Parent = runtime.workspace
	local emitter = runtime.vps.Attach(anchor, {
		seed = 7, targetFps = fps, localSpace = localSpace,
		rate = 8, maxParticles = 16, rateNoiseAmplitude = 0.5, rateNoiseFrequency = 2,
		lifeNoiseAmplitude = 0.2, lifeNoiseFrequency = 2,
		sizeNoiseAmplitude = 0.5, sizeNoiseFrequency = 3,
		perParticle = { speed = 2, life = 10, angle = 0, size = 1 },
	})
	assert(emitter:Emit(2) == 2)
	for _ = 1, 5 do runtime.frame(1 / 60) end
	assert(emitter._alive >= 2)
	return emitter, anchor
end

local function firstParticle(emitter: any): any
	local first: any = nil
	for state in emitter._particles do
		if not first or state.index < first.index then first = state end
	end
	return assert(first, "Expected a live particle")
end

for _, fps in {30, 60} do
	local subject = createRuntime()
	local control = createRuntime()
	local emitter, anchor = attach(subject, fps, true)
	local expected = attach(control, fps, true)
	local disabled = subject.vps.Attach(anchor, { enabled = false, rate = 0 })
	local state = firstParticle(emitter)
	local age, life, position, cf, size = state.age, state.life, state.position, state.part.CFrame, state.part.Size
	local accumulator, simAccumulator = emitter._accumulator, emitter._simAccumulator
	local noise = emitter:GetRateNoiseSample()
	local diagnostics = subject.vps.GetDiagnostics()
	local connectionCount = subject.connections()
	subject.vps.SetSimulationPaused(true)
	subject.vps.SetSimulationPaused(true)
	assert(subject.vps.GetDiagnostics().SimulationPaused)
	for _, dt in {1 / 60, 6, 120, 1 / 30} do
		subject.frame(dt)
		assert(emitter:Emit(96) == 0, "Paused burst must not accumulate")
	end
	anchor.CFrame = CFrame.new(100, 0, -10)
	anchor.Position = anchor.CFrame.Position
	assert(state.age == age and state.life == life and state.position == position)
	assert(state.part.CFrame == cf and state.part.Size == size)
	assert(emitter._accumulator == accumulator and emitter._simAccumulator == simAccumulator)
	assert(emitter:GetRateNoiseSample() == noise)
	assert(subject.vps.GetDiagnostics().Allocated == diagnostics.Allocated)
	assert(subject.vps.GetDiagnostics().Alive == diagnostics.Alive)
	assert(emitter:IsEnabled() and not disabled:IsEnabled())
	subject.vps.SetSimulationPaused(false)
	subject.vps.SetSimulationPaused(false)
	assert(subject.connections() == connectionCount, "Idempotent calls must not create loops")
	for _ = 1, 8 do subject.frame(1 / 60); control.frame(1 / 60) end
	local expectedState = firstParticle(expected)
	assert(math.abs(state.age - expectedState.age) < 1e-9, "No lifetime catch-up")
	assert((state.position - expectedState.position).Magnitude < 1e-5, "No motion/anchor catch-up")
	assert(math.abs(emitter:GetRateNoiseSample() - expected:GetRateNoiseSample()) < 1e-9, "No noise catch-up")
	assert(emitter._alive == expected._alive, "No emission catch-up")
	assert(not disabled:IsEnabled(), "Manual disable must survive resume")
	emitter:SetEnabled(false)
	local previousAge = state.age
	subject.frame(1 / 30)
	assert(state.age > previousAge, "SetEnabled still only gates emission")
	subject.vps.SetSimulationPaused(true)
	subject.setQuality(0)
	subject.frame(60)
	assert(subject.vps.GetTotalAlive() > 0, "Quality must not reclaim frozen particles")
	subject.vps.SetSimulationPaused(false)
	subject.frame(1 / 60)
	assert(subject.vps.GetTotalAlive() == 0, "Resume applies the current quality budget")
	subject.vps.SetSimulationPaused(true)
	emitter:Destroy(); emitter:Destroy(); disabled:Destroy()
	assert(not subject.isConnected(), "Destroy must release an idle paused loop")
	assert(not pcall(subject.vps.SetSimulationPaused, "true"), "Reject non-boolean pause")
	print("PASS pause/resume/idempotency/no-catchup/enabled/quality/destroy", fps)
end

do
	local runtime = createRuntime()
	local anchor = Instance.new("Part")
	anchor.CFrame = CFrame.new(0, 0, -10)
	anchor.Position = anchor.CFrame.Position
	anchor.Parent = runtime.workspace
	local queued = runtime.vps.Attach(anchor, { enabled = false, rate = 0 })
	assert(queued:Emit(3) == 3)
	runtime.vps.SetSimulationPaused(true)
	local attachedDuringPause = runtime.vps.Attach(anchor, { rate = 60 })
	assert(attachedDuringPause:IsEnabled())
	assert(attachedDuringPause:Emit(3) == 0)
	attachedDuringPause:SetEnabled(false)
	runtime.frame(6)
	assert(queued._spawnDemand == 3 and runtime.vps.GetTotalAlive() == 0)
	runtime.vps.SetSimulationPaused(false)
	runtime.frame(1 / 60)
	assert(queued._alive == 3 and queued._spawnDemand == 0)
	assert(not attachedDuringPause:IsEnabled() and attachedDuringPause._alive == 0)
	queued:Destroy(); attachedDuringPause:Destroy()
	assert(not runtime.isConnected())
	print("PASS pre-pause demand preserved; paused Attach/Emit/manual disable and cleanup")
end

local count = 0
local function compileTree(path: string)
	for _, name in fs.readDir(path) do
		local child = path .. "/" .. name
		if fs.isDir(child) then compileTree(child)
		elseif string.sub(name, -5) == ".luau" then
			luau.compile(fs.readFile(child))
			count += 1
		end
	end
end
compileTree(manifest.sourceRoot)
assert(count == 1 + #manifest.internalModules + #manifest.bundledPresets)
print("PASS compile complete package", count)
