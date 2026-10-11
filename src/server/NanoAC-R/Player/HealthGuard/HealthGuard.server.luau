--[[
	NanoAC-R | HealthGuard
	Flags health tampering:
	  * MaxHealth changed from its spawn baseline (godmode: "MaxHealth = math.huge").
	  * Health above MaxHealth (+ tolerance).
	  * illegal heal bursts -- a single-sample health gain larger than any legitimate regen,
	    unless the game reported the heal via the ReportHeal(player, amount) bindable.

	Healing is credited: the coordinator-side ReportHeal adds credit, and a slow baseline
	regen credit accrues each second (healPerSecond), so normal regeneration never flags.
]]

local RunService = game:GetService("RunService")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Health"
local roster = Shared.roster
local HEALS = SharedTableRegistry:GetSharedTable(Shared.cfg("healsName", "NanoAC_Heals"))

local prevHealth = {}  -- [userId] = number
local credit = {}      -- [userId] = number
local streak = {}
local lastEmit = {}
local disabled, errors, lastErrLog = false, 0, 0

local function reset(userId)
	prevHealth[userId] = nil
	credit[userId] = nil
	streak[userId] = 0
end

local function process(state, userId, t)
	local health = state.health
	local maxHealth = state.maxHealth
	if health == nil or maxHealth == nil then return end

	-- ingest reported heals
	local write = HEALS["write"] or 0
	local read = HEALS["read"] or 0
	if write > read then
		for i = read + 1, write do
			local rec = HEALS[i]
			if rec ~= nil then
				credit[rec.userId] = (credit[rec.userId] or 0) + (rec.amount or 0)
			end
			HEALS[i] = nil
		end
		HEALS["read"] = write
	end

	local dt = state.dt or 0
	-- "Permission" to heal faster than baseline, granted by ReportHeal and decaying over
	-- time. Passive regen gains are small (<= HealBurst) and never consult it.
	credit[userId] = math.max(0, (credit[userId] or 0) - Shared.cfg("healthHealPerSecond", 10) * dt)

	if Shared.isGrace(state, t) then
		prevHealth[userId] = health
		streak[userId] = 0
		return
	end

	local bad, detail

	local maxBase = state.maxHealthBase
	if maxBase ~= nil and math.abs(maxHealth - maxBase) > Shared.cfg("healthMaxHealthTolerance", 1) then
		bad, detail = true, string.format("maxHealth=%.1f base=%.1f", maxHealth, maxBase)
	elseif health > maxHealth + Shared.cfg("healthOverhealTolerance", 0.5) then
		bad, detail = true, string.format("health=%.1f > max=%.1f", health, maxHealth)
	else
		local prev = prevHealth[userId]
		if prev ~= nil then
			local gain = health - prev
			local burst = Shared.cfg("healthHealBurst", 25)
			if gain > burst then
				local c = credit[userId] or 0
				if gain > burst + c then
					credit[userId] = 0
					bad, detail = true, string.format("heal=+%.1f credit=%.1f", gain, c)
				else
					credit[userId] = math.max(0, c - (gain - burst))
				end
			end
		end
	end
	prevHealth[userId] = health

	if bad then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = 0
	end

	if streak[userId] >= Shared.cfg("healthRequiredStreak", 2) then
		local cd = Shared.cfg("healthEmitCooldown", 0.5)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, 0, detail or "health")
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

RunService.PreSimulation:ConnectParallel(function()
	if disabled then return end
	if Shared.cfg("paused", false) then return end
	if Shared.cfg("healthEnabled", true) == false then return end

	local ok, err = pcall(function()
		for userId, state in roster do
			local t = state.time
			if t ~= nil and t > 0 then
				if state.dead == true or state.alive == false then
					reset(userId)
				else
					process(state, userId, t)
				end
			end
		end
	end)

	if not ok then
		errors += 1
		if os.clock() - lastErrLog > 5 then
			warn("[NanoAC-R] Health error: " .. tostring(err))
			lastErrLog = os.clock()
		end
		if errors >= 10 then
			disabled = true
			warn("[NanoAC-R] Health check disabled after repeated errors.")
		end
	end
end)
