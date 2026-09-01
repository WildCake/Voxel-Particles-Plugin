--!strict

export type MotionState = {
	position: Vector3,
	accelerationVelocity: Vector3,
}

export type AccelerationDragStep = {
	velocityDecay: number,
	velocityIntegral: number,
	accelerationPositionIntegral: number,
}

local VoxelMotionIntegrator = {}

function VoxelMotionIntegrator.CreateAccelerationDragStep(): AccelerationDragStep
	return {
		velocityDecay = 1,
		velocityIntegral = 0,
		accelerationPositionIntegral = 0,
	}
end

function VoxelMotionIntegrator.ConfigureAccelerationDragStep(
	step: AccelerationDragStep,
	drag: number,
	deltaTime: number
)
	assert(drag == drag and drag > 0 and drag < math.huge, "drag must be finite and positive")
	assert(deltaTime == deltaTime and deltaTime >= 0 and deltaTime < math.huge, "deltaTime must be finite and non-negative")

	local velocityDecay = math.exp(-drag * deltaTime)
	local velocityIntegral = (1 - velocityDecay) / drag
	step.velocityDecay = velocityDecay
	step.velocityIntegral = velocityIntegral
	step.accelerationPositionIntegral = (deltaTime - velocityIntegral) / drag
end

function VoxelMotionIntegrator.Step(
	state: MotionState,
	kinematicVelocity: Vector3,
	acceleration: Vector3,
	deltaTime: number,
	dragStep: AccelerationDragStep?
): Vector3
	assert(deltaTime == deltaTime and deltaTime >= 0 and deltaTime < math.huge, "deltaTime must be finite and non-negative")

	local initialAccelerationVelocity = state.accelerationVelocity
	local finalAccelerationVelocity
	if dragStep then
		state.position += kinematicVelocity * deltaTime
			+ initialAccelerationVelocity * dragStep.velocityIntegral
			+ acceleration * dragStep.accelerationPositionIntegral
		finalAccelerationVelocity = initialAccelerationVelocity * dragStep.velocityDecay
			+ acceleration * dragStep.velocityIntegral
	else
		state.position += (kinematicVelocity + initialAccelerationVelocity) * deltaTime
			+ acceleration * (0.5 * deltaTime * deltaTime)
		finalAccelerationVelocity = initialAccelerationVelocity + acceleration * deltaTime
	end

	state.accelerationVelocity = finalAccelerationVelocity
	return kinematicVelocity + finalAccelerationVelocity
end

return VoxelMotionIntegrator
