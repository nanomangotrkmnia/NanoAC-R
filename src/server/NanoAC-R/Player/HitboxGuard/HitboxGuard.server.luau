--[[
	NanoAC-R | HitboxGuard
	Flags an inflated hitbox:
	  * a Humanoid limb / HumanoidRootPart whose size magnitude has grown beyond the
	    per-character spawn baseline (GrowthRatio / GrowthTolerance),
	  * an accessory handle larger than AccessoryMaxSize.

	The Coordinator captures the spawn baseline for every character and republishes the
	current maximum limb magnitude each scan, so this check is a cheap comparison.
]]

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Hitbox"
local roster = Shared.roster

local streak = {}
local lastEmit = {}

local function reset(userId)
	streak[userId] = nil
end

local function process(state, userId, t)
	if Shared.isGrace(state, t) then
		streak[userId] = 0
		return
	end

	local hitbox = state.hitbox or 0
	local hitboxBase = state.hitboxBase or 0
	local accessory = state.accessory or 0

	local bad, detail
	if hitboxBase > 0 then
		local allowed = hitboxBase * Shared.cfg("hitboxGrowthRatio", 1.15) + Shared.cfg("hitboxGrowthTolerance", 0.5)
		if hitbox > allowed then
			bad, detail = true, string.format("limb=%.2f base=%.2f", hitbox, hitboxBase)
		end
	end
	if not bad then
		local accessoryBase = state.accessoryBase or 0
		if accessoryBase > 0 then
			local allowed = accessoryBase * Shared.cfg("hitboxGrowthRatio", 1.15) + Shared.cfg("hitboxGrowthTolerance", 0.5)
			if accessory > allowed then
				bad, detail = true, string.format("accessory=%.2f base=%.2f", accessory, accessoryBase)
			end
		end
	end

	if bad then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = 0
	end

	if streak[userId] >= Shared.cfg("hitboxRequiredStreak", 2) then
		local cd = Shared.cfg("hitboxEmitCooldown", 0.5)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, accessory > 0 and accessory or hitbox, detail or "hitbox")
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

Shared.runCheck({
	check = CHECK,
	enabledKey = "hitboxEnabled",
	process = process,
	reset = reset,
})
