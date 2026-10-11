--[[
	NanoAC-R | Movement(B)  (speed)
	Runs fully in the parallel phase (ConnectParallel). Reads the shared per-player state
	from the Coordinator and flags sustained horizontal speeds above the server-predicted
	maximum (Humanoid.WalkSpeed + ping/elapsed-time allowance). It never touches the
	DataModel; confirmed violations are pushed to the shared queue.

	False-positive guards: rolling average window, required consecutive streak, ping
	scaling, execution for seated/swimming/climbing/ragdoll/dead/grace (via isExempt).
]]

local RunService = game:GetService("RunService")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Movement(B)"
local roster = Shared.roster

local prev = {}      -- [userId] = { pos = Vector3, time = number }
local windows = {}   -- [userId] = { data = {number}, sum = number }
local streak = {}    -- [userId] = number
local lastEmit = {}  -- [userId] = number

local disabled = false
local errors = 0
local lastErrLog = 0

local function reset(userId)
	prev[userId] = nil
	windows[userId] = nil
	streak[userId] = 0
end

local function process(state, userId, t)
	local pos = state.pos
	if pos == nil then return end

	local p = prev[userId]
	if p == nil or p.time == nil or p.time <= 0 or (t - p.time) > 0.5 then
		-- fresh baseline (new player, respawn, or a large gap from a lag spike)
		prev[userId] = { pos = pos, time = t }
		windows[userId] = nil
		streak[userId] = 0
		return
	end

	local dt = t - p.time
	local oldPos = p.pos
	p.pos = pos
	p.time = t
	if dt <= 0.001 then return end
	if Shared.isExempt(state, t) then
		streak[userId] = 0
		return
	end

	local delta = pos - oldPos
	local horiz = Vector3.new(delta.X, 0, delta.Z).Magnitude
	local speed = horiz / dt

	local walk = state.walkSpeed or 16
	local ping = state.ping or 0
	local allowed = walk * Shared.cfg("movementBMaxMultiplier", 1.4)
		+ Shared.cfg("movementBPingAllowance", 8) * ping
	local cap = Shared.cfg("movementBAbsoluteCap", 200)
	local minSpeed = Shared.cfg("movementBMinSpeed", 26)

	-- rolling average over the last N samples
	local win = windows[userId]
	if win == nil then
		win = { data = {}, sum = 0 }
		windows[userId] = win
	end
	table.insert(win.data, speed)
	win.sum += speed
	local maxN = Shared.cfg("movementBWindow", 10)
	while #win.data > maxN do
		win.sum -= table.remove(win.data, 1)
	end
	local avg = win.sum / math.max(1, #win.data)

	local over = (speed > allowed and speed > minSpeed) or speed > cap
	local violating = over and (avg > allowed or speed > cap)

	if violating then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = math.max(0, (streak[userId] or 0) - 0.5)
	end

	if streak[userId] >= Shared.cfg("movementBRequiredStreak", 3) then
		local cd = Shared.cfg("movementBEmitCooldown", 0.6)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, speed - allowed,
				string.format("speed=%.1f avg=%.1f allowed=%.1f", speed, avg, allowed))
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

RunService.PreSimulation:ConnectParallel(function()
	if disabled then return end
	if Shared.cfg("paused", false) then return end
	if Shared.cfg("movementBEnabled", true) == false then return end

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
			warn("[NanoAC-R] Movement(B) error: " .. tostring(err))
			lastErrLog = os.clock()
		end
		if errors >= 10 then
			disabled = true
			warn("[NanoAC-R] Movement(B) check disabled after repeated errors.")
		end
	end
end)
