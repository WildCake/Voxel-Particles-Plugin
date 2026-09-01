--!strict

export type Candidate = {
	_demandForFrame: number,
	_quotaDebt: number,
}

local VoxelFairShareAllocator = {}

local function normalizeStart(startIndex: number, count: number): number
	return ((math.floor(startIndex) - 1) % count) + 1
end

function VoxelFairShareAllocator.Allocate(
	candidates: {Candidate},
	allocations: {number},
	requestedQuota: number,
	startIndex: number
): number
	table.clear(allocations)

	local count = #candidates
	if count == 0 or requestedQuota <= 0 then
		return 0
	end

	local totalDemand = 0
	for index = 1, count do
		local demand = candidates[index]._demandForFrame
		assert(demand >= 0 and demand % 1 == 0, "frame demand must be a non-negative integer")
		totalDemand += demand
	end
	if totalDemand == 0 then
		return 0
	end

	local quota = math.min(math.floor(requestedQuota), totalDemand)
	if quota <= 0 then
		return 0
	end

	for index = 1, count do
		local candidate = candidates[index]
		candidate._quotaDebt += quota * (candidate._demandForFrame / totalDemand)
	end

	local baseTotal = 0
	for index = 1, count do
		local candidate = candidates[index]
		local want = math.max(0, math.floor(candidate._quotaDebt))
		if want > candidate._demandForFrame then
			want = candidate._demandForFrame
		end
		allocations[index] = want
		baseTotal += want
	end

	local remaining = quota
	if baseTotal <= quota then
		for index = 1, count do
			local allocated = allocations[index]
			candidates[index]._quotaDebt -= allocated
		end
		remaining -= baseTotal
	else
		-- Several previously idle candidates can return with positive debt at once.
		-- Preserve the frame cap and let the highest debt win instead of over-allocating.
		for index = 1, count do
			allocations[index] = 0
		end
	end

	local start = normalizeStart(startIndex, count)
	while remaining > 0 do
		local bestIndex: number? = nil
		local bestDebt = -math.huge
		local index = start
		repeat
			local candidate = candidates[index]
			if allocations[index] < candidate._demandForFrame and candidate._quotaDebt > bestDebt then
				bestDebt = candidate._quotaDebt
				bestIndex = index
			end
			index += 1
			if index > count then
				index = 1
			end
		until index == start

		if bestIndex == nil then
			break
		end

		allocations[bestIndex] += 1
		candidates[bestIndex]._quotaDebt -= 1
		remaining -= 1
		start = bestIndex + 1
		if start > count then
			start = 1
		end
	end

	local granted = quota - remaining
	assert(granted >= 0 and granted <= quota, "allocation exceeded the effective frame quota")
	return granted
end

return VoxelFairShareAllocator
