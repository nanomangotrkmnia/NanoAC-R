--[[
	NanoAC-R | NoclipGuard
	Flags a character whose collision has been removed:
	  * HumanoidRootPart.CanCollide == false
	  * any body limb (not accessories) with CanCollide == false
	  * a NoCollisionConstraint planted in the character

	(The existing Phase check catches actually phasing *through* geometry; this catches the
	collision flags / constraints that make phasing possible, which is what most modern
	noclip scripts toggle.)

	Accessory handles are excluded from the limb check because they are legitimately
	non-collidable; only Humanoid limbs (via Humanoid:GetLimb) are inspected.
]]

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Noclip"
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

	local bad, detail
	if state.hrpCanCollide == false then
		bad, detail = true, "HRP collision off"
	elseif (state.noCollision or 0) > 0 then
		bad, detail = true, string.format("HRP NoCollisionConstraint=%d", state.noCollision)
	end

	if bad then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = 0
	end

	if streak[userId] >= Shared.cfg("noclipRequiredStreak", 2) then
		local cd = Shared.cfg("noclipEmitCooldown", 0.5)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, 0, detail or "noclip")
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

Shared.runCheck({
	check = CHECK,
	enabledKey = "noclipEnabled",
	process = process,
	reset = reset,
})
