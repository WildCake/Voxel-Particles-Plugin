--!strict

local VoxelCubicBezier = {}

local DEFAULT_SUBDIVISIONS = 64
local MIN_LENGTH = 1e-5

export type ArcLengthLut = {
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3,
	subdivisions: number,
	cumulativeLengths: {number},
	samplePositions: {Vector3},
	totalLength: number,
}

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function assertFiniteVector(value: Vector3, name: string)
	assert(
		isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z),
		name .. " must be finite"
	)
end

local function assertValidCurve(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3)
	assertFiniteVector(p0, "p0")
	assertFiniteVector(p1, "p1")
	assertFiniteVector(p2, "p2")
	assertFiniteVector(p3, "p3")
	local maxControlDistance = math.max(
		(p1 - p0).Magnitude,
		(p2 - p0).Magnitude,
		(p3 - p0).Magnitude
	)
	assert(maxControlDistance > MIN_LENGTH * 4, "cubic Bezier curve must have non-zero length")
end

local function evaluate(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local oneMinusT = 1 - t
	local oneMinusTSquared = oneMinusT * oneMinusT
	local tSquared = t * t
	return p0 * (oneMinusTSquared * oneMinusT)
		+ p1 * (3 * oneMinusTSquared * t)
		+ p2 * (3 * oneMinusT * tSquared)
		+ p3 * (tSquared * t)
end

local function derivative(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local oneMinusT = 1 - t
	return (p1 - p0) * (3 * oneMinusT * oneMinusT)
		+ (p2 - p1) * (6 * oneMinusT * t)
		+ (p3 - p2) * (3 * t * t)
end

local function rebuild(
	lut: ArcLengthLut,
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3
): ArcLengthLut
	assertValidCurve(p0, p1, p2, p3)
	local segmentCount = lut.subdivisions
	local cumulativeLengths = lut.cumulativeLengths
	local samplePositions = lut.samplePositions
	local previous = p0
	local totalLength = 0
	cumulativeLengths[1] = 0
	samplePositions[1] = p0

	for index = 1, segmentCount do
		local position = evaluate(p0, p1, p2, p3, index / segmentCount)
		totalLength += (position - previous).Magnitude
		cumulativeLengths[index + 1] = totalLength
		samplePositions[index + 1] = position
		previous = position
	end

	assert(totalLength > MIN_LENGTH, "cubic Bezier curve must have non-zero length")
	lut.p0 = p0
	lut.p1 = p1
	lut.p2 = p2
	lut.p3 = p3
	lut.totalLength = totalLength
	return lut
end

function VoxelCubicBezier.Build(
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3,
	subdivisions: number?
): ArcLengthLut
	local segmentCount = subdivisions or DEFAULT_SUBDIVISIONS
	assert(
		isFiniteNumber(segmentCount) and segmentCount % 1 == 0 and segmentCount >= 4 and segmentCount <= 128,
		"subdivisions must be an integer in [4, 128]"
	)
	local lut: ArcLengthLut = {
		p0 = p0,
		p1 = p1,
		p2 = p2,
		p3 = p3,
		subdivisions = segmentCount,
		cumulativeLengths = table.create(segmentCount + 1, 0),
		samplePositions = table.create(segmentCount + 1, Vector3.zero),
		totalLength = 0,
	}
	return rebuild(lut, p0, p1, p2, p3)
end

function VoxelCubicBezier.Rebuild(
	lut: ArcLengthLut,
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3
): ArcLengthLut
	return rebuild(lut, p0, p1, p2, p3)
end

function VoxelCubicBezier.Sample(lut: ArcLengthLut, distanceAlpha: number): (Vector3, Vector3)
	assert(
		isFiniteNumber(distanceAlpha) and distanceAlpha >= 0 and distanceAlpha <= 1,
		"distanceAlpha must be in [0, 1]"
	)

	local targetLength = distanceAlpha * lut.totalLength
	local cumulativeLengths = lut.cumulativeLengths
	local low = 2
	local high = lut.subdivisions + 1
	while low < high do
		local middle = math.floor((low + high) * 0.5)
		if cumulativeLengths[middle] < targetLength then
			low = middle + 1
		else
			high = middle
		end
	end

	local upperIndex = low
	local lowerIndex = upperIndex - 1
	local lowerLength = cumulativeLengths[lowerIndex]
	local segmentLength = cumulativeLengths[upperIndex] - lowerLength
	local segmentAlpha = if segmentLength > MIN_LENGTH
		then math.clamp((targetLength - lowerLength) / segmentLength, 0, 1)
		else 0
	local t = ((lowerIndex - 1) + segmentAlpha) / lut.subdivisions
	local position = evaluate(lut.p0, lut.p1, lut.p2, lut.p3, t)
	local tangent = derivative(lut.p0, lut.p1, lut.p2, lut.p3, t)

	if tangent.Magnitude <= MIN_LENGTH then
		local samplePositions = lut.samplePositions
		for radius = 0, lut.subdivisions - 1 do
			local before = math.max(1, lowerIndex - radius)
			local after = math.min(lut.subdivisions + 1, upperIndex + radius)
			tangent = samplePositions[after] - samplePositions[before]
			if tangent.Magnitude > MIN_LENGTH then
				break
			end
		end
	end

	assert(tangent.Magnitude > MIN_LENGTH, "cubic Bezier sample must have a non-zero tangent")
	return position, tangent.Unit
end

function VoxelCubicBezier.MaxControlExtent(lut: ArcLengthLut): number
	return math.max(lut.p0.Magnitude, lut.p1.Magnitude, lut.p2.Magnitude, lut.p3.Magnitude)
end

return table.freeze(VoxelCubicBezier)
