--!strict

local VoxelCylinderStream = {}

local ORTHOGONAL_TOLERANCE = 1e-5

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function assertFiniteVector(value: Vector3, name: string)
	assert(
		isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z),
		name .. " must be finite"
	)
end

function VoxelCylinderStream.Sample(
	flowDirection: Vector3,
	cylinderAxis: Vector3,
	radius: number,
	halfHeight: number,
	heightAlpha: number,
	lateralAlpha: number
): (Vector3, number)
	assertFiniteVector(flowDirection, "flowDirection")
	assertFiniteVector(cylinderAxis, "cylinderAxis")
	assert(flowDirection.Magnitude > 0, "flowDirection must be non-zero")
	assert(cylinderAxis.Magnitude > 0, "cylinderAxis must be non-zero")
	assert(isFiniteNumber(radius) and radius > 0, "radius must be finite and positive")
	assert(isFiniteNumber(halfHeight) and halfHeight >= 0, "halfHeight must be finite and non-negative")
	assert(isFiniteNumber(heightAlpha) and heightAlpha >= 0 and heightAlpha <= 1, "heightAlpha must be in [0, 1]")
	assert(
		isFiniteNumber(lateralAlpha) and lateralAlpha >= 0 and lateralAlpha <= 1,
		"lateralAlpha must be in [0, 1]"
	)

	local flowUnit = flowDirection.Unit
	local axisUnit = cylinderAxis.Unit
	assert(
		math.abs(flowUnit:Dot(axisUnit)) <= ORTHOGONAL_TOLERANCE,
		"flowDirection must be perpendicular to cylinderAxis"
	)

	local lateralDirection = axisUnit:Cross(flowUnit).Unit
	local height = (heightAlpha * 2 - 1) * halfHeight
	local lateral = (lateralAlpha * 2 - 1) * radius
	local halfChord = math.sqrt(math.max(0, radius * radius - lateral * lateral))
	local offset = axisUnit * height + lateralDirection * lateral - flowUnit * halfChord

	return offset, halfChord * 2
end

return table.freeze(VoxelCylinderStream)
