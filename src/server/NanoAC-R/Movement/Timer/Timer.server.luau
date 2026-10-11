--[[
	NanoAC-R | TimerCheck  (increased game speed / sustained speed)
	Roblox does not expose per-movement packets server-side, so the observable proxy for a
	"timer"/game-speed cheat is how much ground a player covers per unit of REAL time. This
	check keeps a rolling window of horizontal distance vs elapsed wall-clock time and only
	flags when the SUSTAINED rate exceeds the server-predicted maximum by the configured
	ratio (default 110%+). Isolated bursts never flag because the window must be full and
	the streak must be met. (Vertical movement is handled by Flight/Teleport.)

	Runs fully in the parallel phase; pushes to the shared queue.
]]

local RunService = game:GetService("RunService")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Timer"
local roster = Shared.roster

local tracks = {}    -- [userId] = { samples = { {t, pos} }, total = number }
local streak = {}    -- [userId] = number
local lastEmit = {}  -- [userId] = number

local disabled = false
local errors = 0
local lastErrLog = 0

local function reset(userId)
	tracks[userId] = nil
	streak[userId] = 0
end

local function horizDist(a, b)
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function process(state, userId, t)
	local pos = state.pos
	if pos == nil then return end

	local tr = tracks[userId]
	if tr == nil then
		tr = { samples = {}, total = 0 }
		tracks[userId] = tr
	end

	if Shared.isExempt(state, t) then
		tr.samples = {}
		tr.total = 0
		streak[userId] = 0
		return
	end

	local samples = tr.samples
	local last = samples[#samples]
	if last ~= nil then
		tr.total += horizDist(pos, last.pos)
	end
	samples[#samples + 1] = { t = t, pos = pos }

	-- drop samples that have left the rolling window (incremental, O(1) amortised)
	local window = Shared.cfg("timerWindow", 1.5)
	local cutoff = t - window
	while #samples >= 2 and samples[1].t < cutoff do
		tr.total -= horizDist(samples[1].pos, samples[2].pos)
		table.remove(samples, 1)
	end
	-- hard cap so a stalled clock cannot grow the window unbounded
	while #samples > 600 do
		tr.total -= horizDist(samples[1].pos, samples[2].pos)
		table.remove(samples, 1)
	end

	if #samples < Shared.cfg("timerMinSamples", 20) then return end

	local duration = samples[#samples].t - samples[1].t
	if duration <= 0.05 then return end

	local sustained = tr.total / duration
	local walk = state.walkSpeed or 16
	local allowed = walk * Shared.cfg("timerAllowedRatio", 1.12)
	local minSpeed = Shared.cfg("timerMinSpeed", 20)

	if sustained > allowed and sustained > minSpeed then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = math.max(0, (streak[userId] or 0) - 0.5)
	end

	if streak[userId] >= Shared.cfg("timerRequiredStreak", 2) then
		local cd = Shared.cfg("timerEmitCooldown", 1.0)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, sustained - allowed,
				string.format("sustained=%.1f allowed=%.1f over %.2fs", sustained, allowed, duration))
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

RunService.PreSimulation:ConnectParallel(function()
	if disabled then return end
	if Shared.cfg("paused", false) then return end
	if Shared.cfg("timerEnabled", true) == false then return end

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
			warn("[NanoAC-R] Timer error: " .. tostring(err))
			lastErrLog = os.clock()
		end
		if errors >= 10 then
			disabled = true
			warn("[NanoAC-R] Timer check disabled after repeated errors.")
		end
	end
end)
