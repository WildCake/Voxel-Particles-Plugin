--!strict
-- Packaged runtime geometry and v20 cone regression; no Studio or performance measurements.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local R = require("@lune/roblox")
local manifest = require("@lune/serde").decode("json", fs.readFile("plugin-package.json"))
local checks = 0
local function check(value: boolean, message: string) checks += 1; assert(value, message) end
local release = R.deserializeModel(fs.readFile("dist/VoxelParticlesPlugin-v" .. manifest.pluginVersion .. ".rbxmx"))[1]
local sourceCount = 1
luau.compile(release.Source)
for _, item in release:GetDescendants() do
	if item:IsA("LuaSourceContainer") then luau.compile(item.Source); sourceCount += 1 end
end
check(sourceCount == 1 + #manifest.internalModules + #manifest.bundledPresets, "All 41 packaged sources compile")
release:Destroy()
R.implementMethod("Instance", "WaitForChild", function(instance: any, name: string): any
	return assert(instance:FindFirstChild(name), name)
end)
R.implementMethod("Camera", "WorldToViewportPoint", function(): (any, boolean)
	return R.Vector3.new(0, 0, 1), true
end)
R.implementMethod("Workspace", "BulkMoveTo", function(_workspace: any, parts: {any}, frames: {any})
	for i, part in parts do part.CFrame = frames[i] end
end)

local function runtime(version: number): any
	local package = R.deserializeModel(fs.readFile("dist/VoxelParticlesPlugin-v" .. version .. ".rbxmx"))[1]
	local internal = package.Internal
	local workspace = R.Instance.new("Workspace")
	local camera = R.Instance.new("Camera"); camera.Parent = workspace; workspace.CurrentCamera = camera
	local render: ((number) -> ())? = nil
	local services: any = { Workspace = workspace, ReplicatedStorage = R.Instance.new("ReplicatedStorage"),
		RunService = { IsClient = function() return true end, RenderStepped = {
			Connect = function(_self: any, callback: (number) -> ())
				render = callback; return { Disconnect = function() render = nil end }
			end,
		} } }
	local cache: {[any]: any} = {}
	local loadModule: (any) -> any
	loadModule = function(module: any): any
		if cache[module] then return cache[module] end
		if module.Name == "ClientVfxQuality" then
			return { GetParticleMultiplier = function() return 1 end, OnTierChanged = function() return nil end }
		end
		local env: any = table.clone(R)
		env.script = module; env.require = loadModule
		env.game = { GetService = function(_self: any, name: string) return assert(services[name], name) end }
		env.debug = { profilebegin = function() end, profileend = function() end }
		cache[module] = luau.load(module.Source, { environment = env, debugName = module.Name })()
		return cache[module]
	end
	local voxel = loadModule(internal.VoxelParticleSystem)
	voxel.SetMaxTotalParticles(32)
	local function frame() if render then render(1 / 60) end end
	for _ = 1, 4 do frame() end
	local anchor = R.Instance.new("Part"); anchor.Parent = workspace
	anchor.CFrame = R.CFrame.new(0, 0, -10); anchor.Position = anchor.CFrame.Position
	return { voxel = voxel, anchor = anchor, frame = frame, internal = internal, load = loadModule,
		close = function() check(voxel.GetTotalAlive() == 0, "All emitter particles released"); workspace:Destroy(); package:Destroy() end }
end

local function particles(emitter: any): {any}
	local list = {}
	for state in emitter._particles do table.insert(list, state) end
	table.sort(list, function(a, b) return a.index < b.index end)
	return list
end

local current = runtime(manifest.runtimeVersion)
for _, case in {
	{ normal = R.Vector3.yAxis, direction = R.Vector3.xAxis, min = 0, max = 40 },
	{ normal = R.Vector3.zAxis, direction = R.Vector3.yAxis, min = 10, max = 25 },
	{ normal = R.Vector3.yAxis, direction = R.Vector3.xAxis, min = 0, max = 0 },
} do
	current.anchor.CFrame = R.CFrame.new(0, 0, -10) * R.CFrame.Angles(0.3, 0.8, -0.4)
	local config = { seed = 7, enabled = false, rate = 0, maxParticles = 32, spreadMode = "fan",
		spreadPlaneNormal = case.normal, emissionDirection = case.direction,
		perParticle = { speed = 10, size = 1, life = 10, angle = { min = case.min, max = case.max } } }
	local emitter = current.voxel.Attach(current.anchor, config)
	check(emitter:Emit(32) == 32, "Fan burst accepted")
	current.frame()
	local negative, positive = false, false
	local samples = particles(emitter)
	check(#samples == 32, "Fan burst emits all requested samples")
	for _, state in samples do
		local direction = current.anchor.CFrame:VectorToObjectSpace(state.baseDirection)
		local angle = math.deg(math.acos(math.clamp(direction:Dot(case.direction), -1, 1)))
		check(math.abs(direction:Dot(case.normal)) < 1e-5, "Fan remains in the rotated anchor-local plane")
		check(angle >= case.min - 0.05 and angle <= case.max + 0.05, "Fan respects both angular bounds")
		local side = direction:Dot(case.normal:Cross(case.direction))
		negative = negative or side < -1e-5; positive = positive or side > 1e-5
	end
	check(case.max == 0 or (negative and positive), "Fan covers both sides of its axis")
	local sideBefore = emitter._fanSide
	local invalid = table.clone(config); invalid.spreadPlaneNormal = case.direction
	check(not pcall(function() emitter:Configure(invalid) end) and emitter._fanSide == sideBefore,
		"Invalid plane rejected before mutating configured emitter")
	invalid.spreadPlaneNormal = case.normal; invalid.spawnDirectionMode = "radialOutward"
	check(not pcall(function() emitter:Configure(invalid) end), "Incompatible direction mode rejected")
	config.spreadMode = "cone"; emitter:Configure(config)
	check(emitter._fanSide == nil, "Returning to cone clears fan basis")
	emitter:Destroy()
end
current.close()

-- Every previously bundled preset has identical sampled motion with the same seed.
for _, name in manifest.bundledPresets do
	local before, after = runtime(20), runtime(manifest.runtimeVersion)
	local emitters = {}
	for _, host in { before, after } do
		local config = host.load(host.internal.BundledPresets:FindFirstChild(name)).state
		config.seed = 17; config.enabled = false; config.rate = 0; config.maxParticles = 8
		local emitter = host.voxel.Attach(host.anchor, config)
		table.insert(emitters, emitter)
		emitter:Emit(8); host.frame()
	end
	local old, new = particles(emitters[1]), particles(emitters[2])
	check(#old == #new and #new > 0, name .. " emits on both releases")
	for i, state in old do
		check(state.baseDirection == new[i].baseDirection and state.position == new[i].position
			and state.life == new[i].life and state.part.Size == new[i].part.Size,
			name .. " retains v20 seeded motion, lifetime and size")
	end
	for _, emitter in emitters do emitter:Destroy() end
	before.close(); after.close()
end
print("PASS packaged fan geometry and all 32 v20 presets: " .. checks .. " checks")
