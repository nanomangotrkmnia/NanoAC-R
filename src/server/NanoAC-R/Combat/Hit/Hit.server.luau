--[[
	NanoAC-R | HitGuard
	Validates the *geometry and rate* of reported hits (the existing ThroughWall check owns
	line-of-sight). The game reports each resolved hit with ReportHit(attacker, victim); the
	Coordinator publishes attacker/victim positions to the NanoAC_HitGuard queue.

	Three detections:
	  * Reach      -- attacker->victim distance beyond hitReach + ping cushion.
	  * Hit spam   -- more than hitMaxHitsPerSecond hits in the window.
	  * Kill aura  -- more than hitAuraTargets *distinct* victims within hitAuraWindow.

	Only melee hits should be reported through ReportHit; ranged weapons that legitimately
	reach further should not call it (or raise hitReach).
]]

local RunService = game:GetService("RunService")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Hit"
local roster = Shared.roster
local HITGUARD = SharedTableRegistry:GetSharedTable(Shared.cfg("hitguardName", "NanoAC_HitGuard"))

local history = {}   -- [attackerId] = { {t=, victim=}, ... }
local streak = {}
local lastEmit = {}
local disabled, errors, lastErrLog = false, 0, 0

local function evaluate(rec, now)
	local attacker = rec.attacker
	local origin = Vector3.new(rec.ax, rec.ay, rec.az)
	local target = Vector3.new(rec.vx, rec.vy, rec.vz)
	local dist = (target - origin).Magnitude

	local st = roster[attacker]
	local ping = st and st.ping or 0
	local allowed = Shared.cfg("hitReach", 9.0) + Shared.cfg("hitPingAllowance", 3.0) * ping

	local bad, detail
	if dist > allowed then
		bad, detail = true, string.format("reach=%.1f allowed=%.1f", dist, allowed)
	end

	-- rolling history for spam + aura
	local h = history[attacker]
	if h == nil then
		h = {}
		history[attacker] = h
	end
	h[#h + 1] = { t = now, victim = rec.victim }

	local window = 1.0
	local cutoff = now - math.max(window, Shared.cfg("hitAuraWindow", 0.6))
	while #h >= 1 and h[1].t < cutoff do
		table.remove(h, 1)
	end
	while #h > 256 do
		table.remove(h, 1)
	end

	local perSecond = 0
	for _, e in ipairs(h) do
		if e.t >= now - window then perSecond += 1 end
	end
	if not bad and perSecond > Shared.cfg("hitMaxHitsPerSecond", 20) then
		bad, detail = true, string.format("spam=%d/s", perSecond)
	end

	if not bad then
		local auraWindow = Shared.cfg("hitAuraWindow", 0.6)
		local seen, distinct = {}, 0
		for _, e in ipairs(h) do
			if e.t >= now - auraWindow and not seen[e.victim] then
				seen[e.victim] = true
				distinct += 1
			end
		end
		if distinct > Shared.cfg("hitAuraTargets", 4) then
			bad, detail = true, string.format("aura targets=%d", distinct)
		end
	end

	if bad then
		streak[attacker] = (streak[attacker] or 0) + 1
	else
		streak[attacker] = 0
	end

	if streak[attacker] >= Shared.cfg("hitRequiredStreak", 1) then
		local cd = Shared.cfg("hitEmitCooldown", 0.4)
		if now - (lastEmit[attacker] or -math.huge) >= cd then
			Shared.flag(attacker, CHECK, dist, detail or "hit")
			lastEmit[attacker] = now
			streak[attacker] = 0
		end
	end
end

RunService.PreSimulation:ConnectParallel(function()
	if disabled then return end
	if Shared.cfg("paused", false) then return end
	if Shared.cfg("hitEnabled", true) == false then return end

	local ok, err = pcall(function()
		local write = HITGUARD["write"] or 0
		local read = HITGUARD["read"] or 0
		if write <= read then return end
		local now = os.clock()
		for i = read + 1, write do
			local rec = HITGUARD[i]
			if rec ~= nil then
				evaluate(rec, now)
			end
			HITGUARD[i] = nil
		end
		HITGUARD["read"] = write
	end)

	if not ok then
		errors += 1
		if os.clock() - lastErrLog > 5 then
			warn("[NanoAC-R] Hit error: " .. tostring(err))
			lastErrLog = os.clock()
		end
		if errors >= 10 then
			disabled = true
			warn("[NanoAC-R] Hit check disabled after repeated errors.")
		end
	end
end)
