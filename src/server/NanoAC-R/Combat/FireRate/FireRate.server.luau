--[[
	NanoAC-R | FireRateGuard
	Server-side shot-rate limit. The game reports each resolved shot with
	ReportShot(player, weapon); the Coordinator pushes them to the NanoAC_Shots queue and
	this check enforces a maximum shots-per-second over a rolling window.

	A rapid-fire / macro exploit fires far faster than the configured weapon rate; a short
	"grace" ignores the first moments of a burst so the window is not evaluated until it has
	enough samples.
]]

local RunService = game:GetService("RunService")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "FireRate"
local SHOTS = SharedTableRegistry:GetSharedTable(Shared.cfg("shotsName", "NanoAC_Shots"))

local times = {}     -- [userId] = { {t=, weapon=}, ... }
local streak = {}
local lastEmit = {}
local disabled, errors, lastErrLog = false, 0, 0

local function evaluate(rec)
	local now = rec.t
	local h = times[rec.userId]
	if h == nil then
		h = {}
		times[rec.userId] = h
	end
	h[#h + 1] = { t = now, weapon = rec.weapon }

	local window = Shared.cfg("fireRateWindow", 1.0)
	local cutoff = now - window
	while #h >= 1 and h[1].t < cutoff do
		table.remove(h, 1)
	end
	while #h > 256 do
		table.remove(h, 1)
	end

	local maxPer = Shared.cfg("fireRateMaxShotsPerSecond", 12)
	local allowed = maxPer * window
	local rate = #h / math.max(window, 1e-3)
	local bad = #h > allowed

	if bad then
		streak[rec.userId] = (streak[rec.userId] or 0) + 1
	else
		streak[rec.userId] = 0
	end

	if streak[rec.userId] >= Shared.cfg("fireRateRequiredStreak", 2) then
		local cd = Shared.cfg("fireRateEmitCooldown", 0.5)
		if now - (lastEmit[rec.userId] or -math.huge) >= cd then
			Shared.flag(rec.userId, CHECK, rate,
				string.format("rate=%.1f/s max=%d", rate, maxPer))
			lastEmit[rec.userId] = now
			streak[rec.userId] = 0
		end
	end
end

RunService.PreSimulation:ConnectParallel(function()
	if disabled then return end
	if Shared.cfg("paused", false) then return end
	if Shared.cfg("fireRateEnabled", true) == false then return end

	local ok, err = pcall(function()
		local write = SHOTS["write"] or 0
		local read = SHOTS["read"] or 0
		if write <= read then return end
		for i = read + 1, write do
			local rec = SHOTS[i]
			if rec ~= nil then
				evaluate(rec)
			end
			SHOTS[i] = nil
		end
		SHOTS["read"] = write
	end)

	if not ok then
		errors += 1
		if os.clock() - lastErrLog > 5 then
			warn("[NanoAC-R] FireRate error: " .. tostring(err))
			lastErrLog = os.clock()
		end
		if errors >= 10 then
			disabled = true
			warn("[NanoAC-R] FireRate check disabled after repeated errors.")
		end
	end
end)
