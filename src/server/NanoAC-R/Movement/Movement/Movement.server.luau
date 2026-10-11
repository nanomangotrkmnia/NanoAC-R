--[[
	NanoAC-R | MovementGuard
	Detects "CFrame walking" / move-with-no-velocity: a client that writes its CFrame
	directly (or suppresses velocity, e.g. anti-knockback + noclip drift) so that the
	observed displacement over a short window is far larger than the integral of the
	body's real AssemblyLinearVelocity.

	Speed cannot catch this on its own because a CFrame-walker can keep its displacement
	at/under the Humanoid.WalkSpeed baseline while its velocity stays ~0. This check ties
	displacement to actual velocity, so the mismatch is the signature.

	Rolling window over ~0.35s; requires a filled window and a sustained streak, scales
	the tolerance by ping, and exempts every supported movement state via isExempt.
]]

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Movement"
local roster = Shared.roster

local tracks = {}    -- [userId] = { samples = {{t, disp, veldt}}, windowStart = t }
local streak = {}
local lastEmit = {}

local WINDOW = 0.35

local function reset(userId)
	tracks[userId] = nil
	streak[userId] = 0
end

local function process(state, userId, t)
	local pos = state.pos
	if pos == nil then return end

	local tr = tracks[userId]
	if tr == nil then
		tr = { samples = {}, windowStart = t, prevPos = pos, prevT = t }
		tracks[userId] = tr
		return
	end

	local dt = t - tr.prevT
	if dt <= 0.001 then return end
	if dt > 0.5 then
		-- lag spike / rebaseline
		tr.samples = {}
		tr.windowStart = t
		tr.prevPos = pos
		tr.prevT = t
		streak[userId] = 0
		return
	end

	if Shared.isExempt(state, t) then
		tr.samples = {}
		tr.windowStart = t
		tr.prevPos = pos
		tr.prevT = t
		streak[userId] = 0
		return
	end

	local vel = state.vel
	local speed = vel and vel.Magnitude or 0
	local disp = (pos - tr.prevPos).Magnitude
	tr.prevPos = pos
	tr.prevT = t
	tr.samples[#tr.samples + 1] = { t = t, d = disp, v = speed * dt }

	-- drop samples that left the rolling window
	while #tr.samples >= 2 and tr.samples[1].t < t - WINDOW do
		table.remove(tr.samples, 1)
	end
	tr.windowStart = tr.samples[1] and tr.samples[1].t or t

	local duration = t - tr.windowStart
	local totalDisp, totalVel = 0, 0
	for _, s in ipairs(tr.samples) do
		totalDisp += s.d
		totalVel += s.v
	end

	local minMove = Shared.cfg("movementMinMove", 5)
	local slack = Shared.cfg("movementVelocitySlack", 1.8)
	local ping = state.ping or 0
	local allowance = totalVel * slack + Shared.cfg("movementPingAllowance", 6) * ping
	local filled = duration >= WINDOW * 0.8

	local bad = filled and totalDisp > minMove and totalDisp > allowance
	if bad then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = 0
	end

	if streak[userId] >= Shared.cfg("movementRequiredStreak", 3) then
		local cd = Shared.cfg("movementEmitCooldown", 0.4)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, totalDisp - allowance,
				string.format("moved=%.1f velIntegral=%.1f over %.2fs", totalDisp, totalVel, duration))
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

Shared.runCheck({
	check = CHECK,
	enabledKey = "movementEnabled",
	process = process,
	reset = reset,
})
