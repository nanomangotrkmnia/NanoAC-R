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

--[[
	Per-player rolling window.

	The old version stored samples in a plain array and dropped the front with
	table.remove(samples, 1). table.remove shifts every remaining element, so trimming
	and summing the window were both O(n) every frame -> O(n^2) over a session in the
	hottest path. This is a fixed-capacity ring buffer with running totals:

	  * samples live in three parallel numeric arrays addressed by a slot index;
	  * head/count track the live range, so eviction is `head = head % cap + 1` (O(1));
	  * sumD/sumV are maintained incrementally, so the per-frame total is O(1) not O(n).

	The window length, tolerances and streak rules below are unchanged.
]]
local tracks = {}    -- [userId] = ring buffer track
local streak = {}
local lastEmit = {}

local WINDOW = 0.35
local SAMPLE_CAP = 128   -- >= WINDOW / min-dt for any sane server frame rate

local function newTrack(t, pos)
	return {
		sT = table.create(SAMPLE_CAP),   -- sample times
		sD = table.create(SAMPLE_CAP),   -- displacement per step
		sV = table.create(SAMPLE_CAP),   -- velocity integral per step
		head = 1,                        -- slot of the oldest live sample
		count = 0,                       -- live samples
		sumD = 0,
		sumV = 0,
		windowStart = t,
		prevPos = pos,
		prevT = t,
	}
end

-- Clear a track in place (reuses the allocated arrays: no per-reset garbage).
local function resetTrack(tr, t, pos)
	tr.head = 1
	tr.count = 0
	tr.sumD = 0
	tr.sumV = 0
	tr.windowStart = t
	tr.prevPos = pos
	tr.prevT = t
end

local function reset(userId)
	tracks[userId] = nil
	streak[userId] = 0
end

local function process(state, userId, t)
	local pos = state.pos
	if pos == nil then return end

	local tr = tracks[userId]
	if tr == nil then
		tr = newTrack(t, pos)
		tracks[userId] = tr
		return
	end

	local dt = t - tr.prevT
	if dt <= 0.001 then return end
	if dt > 0.5 or Shared.isExempt(state, t) then
		-- lag spike / rebaseline, or an exempt movement state
		resetTrack(tr, t, pos)
		streak[userId] = 0
		return
	end

	local vel = state.vel
	local speed = vel and vel.Magnitude or 0
	local disp = (pos - tr.prevPos).Magnitude
	tr.prevPos = pos
	tr.prevT = t

	-- Push the new sample into the ring, keeping the running totals. On the (unrealistic)
	-- event of a full ring, evict the oldest slot first so the cap is hard.
	local cap = SAMPLE_CAP
	local head, count = tr.head, tr.count
	if count >= cap then
		tr.sumD -= tr.sD[head]
		tr.sumV -= tr.sV[head]
		head = head % cap + 1
		count -= 1
	end
	local slot = (head - 1 + count) % cap + 1
	tr.sT[slot] = t
	tr.sD[slot] = disp
	tr.sV[slot] = speed * dt
	count += 1
	tr.sumD += disp
	tr.sumV += speed * dt

	-- Drop samples that have left the rolling window from the front.
	local cutoff = t - WINDOW
	while count >= 2 and tr.sT[head] < cutoff do
		tr.sumD -= tr.sD[head]
		tr.sumV -= tr.sV[head]
		head = head % cap + 1
		count -= 1
	end
	tr.head = head
	tr.count = count
	tr.windowStart = count > 0 and tr.sT[head] or t

	local duration = t - tr.windowStart
	local totalDisp, totalVel = tr.sumD, tr.sumV

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
