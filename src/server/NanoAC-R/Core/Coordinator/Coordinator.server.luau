--[[
	=====================================================================================
	NanoAC-R | Coordinator
	=====================================================================================
	The Coordinator is the ONLY NanoAC-R script that runs in the serial phase and the ONLY
	script allowed to write to the DataModel. It owns:

	  * Player lifecycle  (PlayerAdded / PlayerRemoving / CharacterAdded / Removing)
	  * The per-player shared-state SharedTable that every check reads
	  * A violation queue that checks push into from parallel threads
	  * Violation Levels (VL), VL decay, chat alerts and setbacks
	  * The ExemptTeleport() whitelist API

	Every check lives under its own Actor so its movement maths runs in parallel. Checks
	never touch the DataModel; they only write into the shared queue, which this script
	drains once per frame on the serial phase.

	Actor hierarchy (ServerScriptService):
	  NanoAC-R (Actor)
	    ├─ NanoShared (ModuleScript)
	    ├─ ExemptTeleport (BindableFunction)
	    ├─ ReportHit / ReportKnockback (BindableFunctions)
	    ├─ Core/Coordinator (Actor) ─ Coordinator (Script)   <- this file
	    ├─ Movement/ { Phase, Speed, Timer, Teleport, Step, Spider }
	    ├─ Flight/   { FlightA, FlightB, FlightC, FlightD }
	    └─ Combat/   { ThroughWall, Velocity }
	=====================================================================================
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local ROSTER = Shared.roster
local QUEUE = Shared.queue
local CONFIG = Shared.config

-- Combat event queues: the game reports hits / knockbacks via the ReportHit and
-- ReportKnockback bindables; the combat checks drain + validate these from parallel.
local HITS = SharedTableRegistry:GetSharedTable("NanoAC_Hits")
local KNOCKS = SharedTableRegistry:GetSharedTable("NanoAC_Knockbacks")
if HITS["write"] == nil then HITS["write"] = 0 end
if HITS["read"] == nil then HITS["read"] = 0 end
if KNOCKS["write"] == nil then KNOCKS["write"] = 0 end
if KNOCKS["read"] == nil then KNOCKS["read"] = 0 end

-- expose them to the combat checks
CONFIG.hitsName = "NanoAC_Hits"
CONFIG.knocksName = "NanoAC_Knockbacks"

-- =====================================================================================
--  SETTINGS  (everything is tunable here; the checks read a mirrored copy of this table)
-- =====================================================================================
local Settings = {
	-- Master switches
	Enabled = true,
	Debug = false,                 -- true = verbose server console output for every flag

	-- Chat alert behaviour ------------------------------------------------------------
	Alerts = {
		Enabled = true,
		StaffOnly = true,          -- true = only staff receive alerts, false = everybody
		EveryoneIsStaff = false,   -- when true every player is treated as staff (alerts to all)
		Color = Color3.fromRGB(255, 85, 85),
		StaffUserIds = {           -- explicit staff accounts
			-- 12345678,
		},
		StaffGroupId = 0,          -- > 0 enables group-based staff
		MinGroupRank = 250,        -- rank needed in StaffGroupId
		StaffAttribute = "NanoAC_Staff", -- player attribute that also marks staff
	},

	-- Verbose (raw per-flag chat output) ----------------------------------------------
	Verbose = {
		AllowSelfToggle = true,    -- any player may type /verbose to always see flags
	},

	-- Grace windows (seconds) ---------------------------------------------------------
	Grace = {
		AfterSpawn = 4,            -- after character load / respawn
		AfterTeleport = 1.5,       -- after a whitelisted teleport
		AfterSetback = 1.0,        -- after we ourselves set the player back
		AfterSeat = 0.5,           -- after entering / leaving a seat
	},

	-- Violation level behaviour -------------------------------------------------------
	VL = {
		DecayPerSecond = 0.6,      -- VL points removed per second of clean play
		MaxDisplay = 999,          -- cap for the number shown in alerts
	},

	-- Setback behaviour ---------------------------------------------------------------
	Setback = {
		Enabled = true,
		Cooldown = 1.5,            -- seconds between setbacks for a single player
		OnEveryFlag = false,       -- set back on ANY flag, not only threshold crossings
		FreezeSafeSpotOnFlag = true, -- don't advance the safe spot while a player is flagged
	},

	-- Placeholder punishment hook -----------------------------------------------------
	Punish = {
		KickAfterSetbacks = 0,     -- 0 = never kick; else kick after this many setbacks
		KickMessage = "NanoAC-R: too many movement violations.",
	},

	-- Per-check tuning ----------------------------------------------------------------
	Checks = {
		Phase = {
			Enabled = true, VLThreshold = 5, RequiredStreak = 2, EmitCooldown = 0.6,
			MinMove = 2.5,             -- ignore segments shorter than this (studs)
			MinPartThickness = 0.6,    -- thinner parts are steppable -> ignore
			MaxTransparency = 0.9,     -- invisible parts -> ignore
			MaxSegment = 60,           -- ignore paths longer than this (unreliable)
			SpeedFactor = 1.6,         -- if moving faster than walk*this, defer to Speed/Teleport
		},
		Speed = {
			Enabled = true, VLThreshold = 10, RequiredStreak = 6, EmitCooldown = 0.6,
			MaxMultiplier = 1.4,       -- allowed multiple of Humanoid.WalkSpeed
			PingAllowance = 8,         -- extra studs/s of tolerance per second of ping
			AbsoluteCap = 200,         -- never tolerate speeds above this
			MinSpeed = 26,             -- don't bother below this (studs/s)
			Window = 10,               -- rolling average window (samples)
		},
		FlightA = {
			Enabled = true, VLThreshold = 6, RequiredStreak = 2, EmitCooldown = 0.4,
			MaxMultiplier = 1.35,      -- upward speed above jumpPower * this flags (high-jump bypass)
			MinSpeed = 14,             -- ignore gentle upward drift
			GainMultiplier = 1.3,      -- climbed more than maxJumpHeight * this within GainWindow flags
			GainWindow = 0.35,
			Leniency = 2,              -- extra studs of tolerance (jump + clip a block edge)
		},
		FlightB = {
			Enabled = true, VLThreshold = 6, RequiredStreak = 0, EmitCooldown = 0.4,
			MaxDescent = 8,            -- |vy| below this while airborne counts as hovering
			MinAirTime = 0.6,          -- seconds of hovering before flagging
		},
		FlightC = {
			Enabled = true, VLThreshold = 6, RequiredStreak = 0, EmitCooldown = 0.5,
			MinFallTime = 0.3,         -- seconds of falling before comparing to freefall
			ExpectedRatio = 0.55,      -- actual fall below this fraction of freefall -> glide-down
			MinFallSpeed = 8,          -- must be descending at least this fast to matter
		},
		FlightD = {
			Enabled = true, VLThreshold = 5, RequiredStreak = 1, EmitCooldown = 0.3,
			AirDelay = 0.55,           -- seconds airborne before a rise is illegal
			MinRise = 8,               -- upward speed (studs/s) that counts as rising
		},
		Step = {
			Enabled = true, VLThreshold = 5, RequiredStreak = 2, EmitCooldown = 0.4,
			MaxStep = 2.75,            -- grounded climb taller than this in one frame (studs)
		},
		Spider = {
			Enabled = true, VLThreshold = 6, RequiredStreak = 0, EmitCooldown = 0.4,
			MinClimbSpeed = 4,         -- upward speed while airborne (studs/s)
			MinSustain = 0.35,         -- seconds of wall-climbing before flagging
			WallDistance = 2.2,        -- how close a solid wall must be (studs)
		},
		ThroughWall = {
			Enabled = true, VLThreshold = 4, RequiredStreak = 1, EmitCooldown = 0.3,
			StartOffset = 1.5,         -- start the validating ray this far from the attacker
			EndOffset = 1.0,           -- stop it this far before the victim
		},
		Velocity = {
			Enabled = true, VLThreshold = 5, RequiredStreak = 1, EmitCooldown = 0.3,
			MinKnockback = 20,         -- ignore small knockbacks (studs/s)
			Ratio = 0.5,               -- actual below expected * this -> anti-knockback
			Window = 0.35,             -- seconds to observe the victim's speed
			Room = 3.5,                -- skip if a wall sits this close in the knockback direction
		},
		Timer = {
			Enabled = true, VLThreshold = 8, RequiredStreak = 3, EmitCooldown = 1.0,
			Window = 1.5,              -- rolling window (seconds)
			AllowedRatio = 1.12,       -- sustained speed may not exceed walk*ratio
			MinSamples = 20,           -- need this many samples in the window first
			MinSpeed = 20,             -- ignore slow movement entirely
		},
		Teleport = {
			Enabled = true, VLThreshold = 4, RequiredStreak = 2, EmitCooldown = 0.6,
			HorizMultiplier = 2.0,     -- horizontal allowance = walk * mult * dt
			PingAllowance = 14,        -- flat studs of slack per second of ping
			MinDistance = 12,          -- ignore small jumps
			UpMultiplier = 3.0,        -- upward allowance = jumpPower * mult * dt
			TerminalVelocity = 300,    -- downward allowance = terminal * mult * dt
			DownMultiplier = 1.5,
		},
	},
}

-- =====================================================================================
--  PUBLISH CONFIG  (mirror the numeric/bool settings into a SharedTable for the checks)
-- =====================================================================================
local function publishConfig()
	CONFIG.paused = not Settings.Enabled
	CONFIG.debug = Settings.Debug
	CONFIG.gravity = Workspace.Gravity

	CONFIG.graceSpawn = Settings.Grace.AfterSpawn
	CONFIG.graceTeleport = Settings.Grace.AfterTeleport
	CONFIG.graceSetback = Settings.Grace.AfterSetback
	CONFIG.graceSeat = Settings.Grace.AfterSeat

	CONFIG.vlDecay = Settings.VL.DecayPerSecond
	CONFIG.vlMax = Settings.VL.MaxDisplay
	CONFIG.setbackEnabled = Settings.Setback.Enabled
	CONFIG.setbackCooldown = Settings.Setback.Cooldown
	CONFIG.kickAfterSetbacks = Settings.Punish.KickAfterSetbacks

	local p = Settings.Checks.Phase
	CONFIG.phaseEnabled = p.Enabled
	CONFIG.phaseVlThreshold = p.VLThreshold
	CONFIG.phaseRequiredStreak = p.RequiredStreak
	CONFIG.phaseEmitCooldown = p.EmitCooldown
	CONFIG.phaseMinMove = p.MinMove
	CONFIG.phaseMinPartThickness = p.MinPartThickness
	CONFIG.phaseMaxTransparency = p.MaxTransparency
	CONFIG.phaseSpeedFactor = p.SpeedFactor
	CONFIG.phaseMaxSegment = p.MaxSegment

	local s = Settings.Checks.Speed
	CONFIG.speedEnabled = s.Enabled
	CONFIG.speedVlThreshold = s.VLThreshold
	CONFIG.speedRequiredStreak = s.RequiredStreak
	CONFIG.speedEmitCooldown = s.EmitCooldown
	CONFIG.speedMaxMultiplier = s.MaxMultiplier
	CONFIG.speedPingAllowance = s.PingAllowance
	CONFIG.speedAbsoluteCap = s.AbsoluteCap
	CONFIG.speedMinSpeed = s.MinSpeed
	CONFIG.speedWindow = s.Window

	local a = Settings.Checks.FlightA
	CONFIG.flightAEnabled = a.Enabled
	CONFIG.flightAVlThreshold = a.VLThreshold
	CONFIG.flightARequiredStreak = a.RequiredStreak
	CONFIG.flightAEmitCooldown = a.EmitCooldown
	CONFIG.flightAMaxMultiplier = a.MaxMultiplier
	CONFIG.flightAMinSpeed = a.MinSpeed
	CONFIG.flightAGainMultiplier = a.GainMultiplier
	CONFIG.flightAGainWindow = a.GainWindow
	CONFIG.flightALeniency = a.Leniency

	local g2 = Settings.Checks.FlightB
	CONFIG.flightBEnabled = g2.Enabled
	CONFIG.flightBVlThreshold = g2.VLThreshold
	CONFIG.flightBRequiredStreak = g2.RequiredStreak
	CONFIG.flightBEmitCooldown = g2.EmitCooldown
	CONFIG.flightBMaxDescent = g2.MaxDescent
	CONFIG.flightBMinAirTime = g2.MinAirTime

	local d = Settings.Checks.FlightC
	CONFIG.flightCEnabled = d.Enabled
	CONFIG.flightCVlThreshold = d.VLThreshold
	CONFIG.flightCRequiredStreak = d.RequiredStreak
	CONFIG.flightCEmitCooldown = d.EmitCooldown
	CONFIG.flightCMinFallTime = d.MinFallTime
	CONFIG.flightCExpectedRatio = d.ExpectedRatio
	CONFIG.flightCMinFallSpeed = d.MinFallSpeed

	local fd = Settings.Checks.FlightD
	CONFIG.flightDEnabled = fd.Enabled
	CONFIG.flightDVlThreshold = fd.VLThreshold
	CONFIG.flightDRequiredStreak = fd.RequiredStreak
	CONFIG.flightDEmitCooldown = fd.EmitCooldown
	CONFIG.flightDAirDelay = fd.AirDelay
	CONFIG.flightDMinRise = fd.MinRise

	local st = Settings.Checks.Step
	CONFIG.stepEnabled = st.Enabled
	CONFIG.stepVlThreshold = st.VLThreshold
	CONFIG.stepRequiredStreak = st.RequiredStreak
	CONFIG.stepEmitCooldown = st.EmitCooldown
	CONFIG.stepMaxStep = st.MaxStep

	local sp = Settings.Checks.Spider
	CONFIG.spiderEnabled = sp.Enabled
	CONFIG.spiderVlThreshold = sp.VLThreshold
	CONFIG.spiderRequiredStreak = sp.RequiredStreak
	CONFIG.spiderEmitCooldown = sp.EmitCooldown
	CONFIG.spiderMinClimbSpeed = sp.MinClimbSpeed
	CONFIG.spiderMinSustain = sp.MinSustain
	CONFIG.spiderWallDistance = sp.WallDistance

	local tw = Settings.Checks.ThroughWall
	CONFIG.throughWallEnabled = tw.Enabled
	CONFIG.throughWallVlThreshold = tw.VLThreshold
	CONFIG.throughWallRequiredStreak = tw.RequiredStreak
	CONFIG.throughWallEmitCooldown = tw.EmitCooldown
	CONFIG.throughWallStartOffset = tw.StartOffset
	CONFIG.throughWallEndOffset = tw.EndOffset

	local ve = Settings.Checks.Velocity
	CONFIG.velocityEnabled = ve.Enabled
	CONFIG.velocityVlThreshold = ve.VLThreshold
	CONFIG.velocityRequiredStreak = ve.RequiredStreak
	CONFIG.velocityEmitCooldown = ve.EmitCooldown
	CONFIG.velocityMinKnockback = ve.MinKnockback
	CONFIG.velocityRatio = ve.Ratio
	CONFIG.velocityWindow = ve.Window
	CONFIG.velocityRoom = ve.Room

	local tm = Settings.Checks.Timer
	CONFIG.timerEnabled = tm.Enabled
	CONFIG.timerVlThreshold = tm.VLThreshold
	CONFIG.timerRequiredStreak = tm.RequiredStreak
	CONFIG.timerEmitCooldown = tm.EmitCooldown
	CONFIG.timerWindow = tm.Window
	CONFIG.timerAllowedRatio = tm.AllowedRatio
	CONFIG.timerMinSamples = tm.MinSamples
	CONFIG.timerMinSpeed = tm.MinSpeed

	local tp = Settings.Checks.Teleport
	CONFIG.teleportEnabled = tp.Enabled
	CONFIG.teleportVlThreshold = tp.VLThreshold
	CONFIG.teleportRequiredStreak = tp.RequiredStreak
	CONFIG.teleportEmitCooldown = tp.EmitCooldown
	CONFIG.teleportHorizMultiplier = tp.HorizMultiplier
	CONFIG.teleportPingAllowance = tp.PingAllowance
	CONFIG.teleportMinDistance = tp.MinDistance
	CONFIG.teleportUpMultiplier = tp.UpMultiplier
	CONFIG.teleportTerminalVelocity = tp.TerminalVelocity
	CONFIG.teleportDownMultiplier = tp.DownMultiplier
end

publishConfig()

-- =====================================================================================
--  HELPERS
-- =====================================================================================
local function now()
	return Workspace:GetServerTimeNow()
end

local function yawOf(root)
	local look = root.CFrame.LookVector
	return math.atan2(-look.X, -look.Z)
end

-- Plain Lua record owned exclusively by this serial script.
local records = {}        -- [userId] = record
local verbosePlayers = {} -- [userId] = true (raw flag output)
local setupCommands       -- forward declaration

local function newRecord(plr)
	local stateTable = SharedTable.new({
		userId = plr.UserId,
		name = plr.Name,
		pos = Vector3.zero,
		time = 0,
		dt = 0,
		ping = 0,
		walkSpeed = 16,
		jumpPower = 50,
		hipHeight = 2,
		grounded = false,
		stateName = "",
		swim = false,
		climb = false,
		seated = false,
		platform = false,
		phys = false,
		dead = true,
		freefall = false,
		jumping = false,
		vy = 0,
		pvy = 0,
		airborne = false,
		wasAirborne = false,
		alive = false,
		graceUntil = 0,
		exemptUntil = 0,
		lastValidPos = Vector3.zero,
		lastValidYaw = 0,
		lastValidTime = 0,
		setbackCount = 0,
	})
	return {
		player = plr,
		userId = plr.UserId,
		name = plr.Name,
		stateTable = stateTable,
		lastSampleTime = nil,
		lastValidPos = Vector3.zero,
		lastValidYaw = 0,
		lastValidTime = 0,
		graceUntil = 0,
		exemptUntil = 0,
		setbacks = 0,
		setbackCooldownUntil = 0,
		vl = {},
		lastDecay = now(),
	}
end

-- =====================================================================================
--  LIFECYCLE
-- =====================================================================================
local function onCharacterAdded(plr)
	local rec = records[plr.UserId]
	if rec == nil then return end
	local t = now()
	rec.graceUntil = t + Settings.Grace.AfterSpawn
	rec.exemptUntil = t + Settings.Grace.AfterTeleport
	rec.setbackCooldownUntil = t + Settings.Grace.AfterSetback
	rec.lastSampleTime = nil
	local st = rec.stateTable
	st.graceUntil = rec.graceUntil
	st.exemptUntil = rec.exemptUntil
	st.dead = true
	st.alive = false
end

local function onPlayerAdded(plr)
	if records[plr.UserId] ~= nil then return end
	local rec = newRecord(plr)
	rec.graceUntil = now() + Settings.Grace.AfterSpawn
	rec.exemptUntil = now() + Settings.Grace.AfterTeleport
	rec.lastDecay = now()
	records[plr.UserId] = rec
	ROSTER[plr.UserId] = rec.stateTable

	if setupCommands then setupCommands(plr) end

	plr.CharacterAdded:Connect(function()
		onCharacterAdded(plr)
	end)

	-- Seat enter / exit also grants a little grace so the seat transition is not flagged.
	plr.CharacterAdded:Connect(function(char)
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum then return end
		hum.Seated:Connect(function()
			local r = records[plr.UserId]
			if not r then return end
			r.exemptUntil = now() + Settings.Grace.AfterSeat
			r.stateTable.exemptUntil = r.exemptUntil
		end)
	end)

	if plr.Character then
		onCharacterAdded(plr)
	end
end

local function onPlayerRemoving(plr)
	records[plr.UserId] = nil
	ROSTER[plr.UserId] = nil
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, plr in ipairs(Players:GetPlayers()) do
	onPlayerAdded(plr)
end

-- =====================================================================================
--  ALERTS
-- =====================================================================================
local alertEvent = ReplicatedStorage:FindFirstChild("NanoAC_AlertEvent")
if alertEvent == nil then
	alertEvent = Instance.new("RemoteEvent")
	alertEvent.Name = "NanoAC_AlertEvent"
	alertEvent.Parent = ReplicatedStorage
end

local function notify(plr, text, color)
	alertEvent:FireClient(plr, text, color or Settings.Alerts.Color)
end

-- ---------------------------------------------------------------------------------
--  CHAT COMMANDS  --  /verbose toggles raw per-flag output for the typing player
-- ---------------------------------------------------------------------------------
setupCommands = function(plr)
	plr.Chatted:Connect(function(message)
		if type(message) ~= "string" then return end
		local cmd, a1, a2, a3 = message:match("^%s*/(%S+)%s*(%S*)%s*(%S*)%s*(%S*)")
		if cmd == nil then return end
		cmd = cmd:lower()
		local rec = records[plr.UserId]
		if rec == nil then return end
		local nowT = os.clock()
		if rec.lastCommand ~= nil and (nowT - rec.lastCommand) < 0.4 then return end
		rec.lastCommand = nowT
		if cmd == "verbose" and Settings.Verbose.AllowSelfToggle then
			local on = not (verbosePlayers[plr.UserId] == true)
			verbosePlayers[plr.UserId] = on or nil
			notify(plr, string.format("[NanoAC-R] verbose %s", on and "ON" or "OFF"), Settings.Alerts.Color)
			if Settings.Debug then
				print(string.format("[NanoAC-R] %s verbose=%s", plr.Name, tostring(on)))
			end
		elseif cmd == "velocity" then
			-- test command:  /velocity <amount> <left|right|up|down|forward|back> [fake]
			-- applies a knockback in that direction and reports it (add "fake" to report
			-- WITHOUT applying it, i.e. simulate anti-knockback so the check can flag).
			local amount = tonumber(a1)
			local dirName = (a2 or ""):lower()
			local fake = (a3 or ""):lower() == "fake"
			if amount == nil or amount <= 0 then
				notify(plr, "[NanoAC-R] usage: /velocity <amount> <left|right|up|down>", Settings.Alerts.Color)
				return
			end
			if amount ~= nil and amount > 0 then
				amount = math.min(amount, 1000)
				local root = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
				if root ~= nil then
					local cf = root.CFrame
					local right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
					if right.Magnitude < 1e-3 then right = Vector3.new(1, 0, 0) end
					right = right.Unit
					local forward = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
					if forward.Magnitude < 1e-3 then forward = Vector3.new(0, 0, -1) end
					forward = forward.Unit
					local dir
					if dirName == "left" then dir = -right
					elseif dirName == "right" then dir = right
					elseif dirName == "up" then dir = Vector3.new(0, 1, 0)
					elseif dirName == "down" then dir = Vector3.new(0, -1, 0)
					elseif dirName == "forward" then dir = forward
					elseif dirName == "back" then dir = -forward
					end
					if dir == nil then
						notify(plr, "[NanoAC-R] unknown direction (left/right/up/down/forward/back)", Settings.Alerts.Color)
					else
						local vec = dir * amount
						notify(plr, string.format("[NanoAC-R] velocity %d %s%s", amount, dirName, fake and " (fake)" or ""), Settings.Alerts.Color)
						if not fake then
							-- apply a real, short impulse via a mover (a plain velocity write is
							-- fought by the Humanoid controller, so it would under-report).
							local att = Instance.new("Attachment")
							att.Parent = root
							local lv = Instance.new("LinearVelocity")
							lv.Attachment0 = att
							lv.RelativeTo = Enum.ActuatorRelativeTo.World
							lv.MaxForce = 1e6
							lv.VectorVelocity = vec
							lv.Parent = root
							task.delay(0.15, function()
								pcall(function() lv:Destroy() end)
								pcall(function() att:Destroy() end)
							end)
						end
						local i = SharedTable.increment(KNOCKS, "write", 1) + 1
						KNOCKS[i] = SharedTable.new({
							victim = plr.UserId,
							vx = vec.X, vy = vec.Y, vz = vec.Z,
							px = root.Position.X, py = root.Position.Y, pz = root.Position.Z,
							t = now(),
						})
					end
				end
			end
		end
	end)
end

for _, plr in ipairs(Players:GetPlayers()) do
	setupCommands(plr)
end

local function isStaff(plr)
	if Settings.Alerts.EveryoneIsStaff then
		return true
	end
	if plr:GetAttribute(Settings.Alerts.StaffAttribute) == true then
		return true
	end
	if table.find(Settings.Alerts.StaffUserIds, plr.UserId) then
		return true
	end
	if Settings.Alerts.StaffGroupId > 0 then
		local ok, rank = pcall(function()
			return plr:GetRankInGroup(Settings.Alerts.StaffGroupId)
		end)
		if ok and rank and rank >= Settings.Alerts.MinGroupRank then
			return true
		end
	end
	return false
end

local function sendAlert(text)
	if not Settings.Alerts.Enabled then return end
	local color = Settings.Alerts.Color
	for _, plr in ipairs(Players:GetPlayers()) do
		if not Settings.Alerts.StaffOnly or isStaff(plr) then
			notify(plr, text, color)
		end
	end
	if Settings.Debug then
		warn("[NanoAC-R] " .. text)
	end
end

-- =====================================================================================
--  EXEMPT TELEPORT API
--   Other server scripts can whitelist a legitimate teleport with:
--     game.ServerScriptService["NanoAC-R"].ExemptTeleport:Invoke(player, optionalSeconds)
-- =====================================================================================
local exemptBindable = rootActor:FindFirstChild("ExemptTeleport")
if exemptBindable == nil then
	exemptBindable = Instance.new("BindableFunction")
	exemptBindable.Name = "ExemptTeleport"
	exemptBindable.Parent = rootActor
end

exemptBindable.OnInvoke = function(plr, duration)
	if typeof(plr) ~= "Instance" or not plr:IsA("Player") then
		return false
	end
	local rec = records[plr.UserId]
	if rec == nil then
		return false
	end
	local seconds = tonumber(duration) or Settings.Grace.AfterTeleport
	rec.exemptUntil = now() + seconds
	rec.stateTable.exemptUntil = rec.exemptUntil
	return true
end

-- =====================================================================================
--  COMBAT REPORTING API
--   Game code reports resolved hits + applied knockback here; the Combat checks validate.
--     game.ServerScriptService["NanoAC-R"].ReportHit:Invoke(attacker, victim)
--     game.ServerScriptService["NanoAC-R"].ReportKnockback:Invoke(victim, knockbackVelocity)
-- =====================================================================================
local function ensureBindable(name)
	local b = rootActor:FindFirstChild(name)
	if b == nil then
		b = Instance.new("BindableFunction")
		b.Name = name
		b.Parent = rootActor
	end
	return b
end

local reportHit = ensureBindable("ReportHit")
reportHit.OnInvoke = function(attacker, victim)
	if typeof(attacker) ~= "Instance" or not attacker:IsA("Player") then return false end
	if typeof(victim) ~= "Instance" or not victim:IsA("Player") then return false end
	local at = attacker.Character and attacker.Character:FindFirstChild("HumanoidRootPart")
	local vt = victim.Character and victim.Character:FindFirstChild("HumanoidRootPart")
	if at == nil or vt == nil then return false end
	local i = SharedTable.increment(HITS, "write", 1) + 1
	HITS[i] = SharedTable.new({
		attacker = attacker.UserId,
		victim = victim.UserId,
		ax = at.Position.X, ay = at.Position.Y, az = at.Position.Z,
		vx = vt.Position.X, vy = vt.Position.Y, vz = vt.Position.Z,
		t = now(),
	})
	return true
end

local reportKnock = ensureBindable("ReportKnockback")
reportKnock.OnInvoke = function(victim, velocity)
	if typeof(victim) ~= "Instance" or not victim:IsA("Player") then return false end
	if typeof(velocity) ~= "Vector3" then return false end
	local root = victim.Character and victim.Character:FindFirstChild("HumanoidRootPart")
	local px, py, pz = 0, 0, 0
	if root ~= nil then
		px, py, pz = root.Position.X, root.Position.Y, root.Position.Z
	end
	local i = SharedTable.increment(KNOCKS, "write", 1) + 1
	KNOCKS[i] = SharedTable.new({
		victim = victim.UserId,
		vx = velocity.X, vy = velocity.Y, vz = velocity.Z,
		px = px, py = py, pz = pz,
		t = now(),
	})
	return true
end

-- =====================================================================================
--  VIOLATIONS / SETBACKS
-- =====================================================================================
local function thresholdFor(check)
	local c = Settings.Checks[check]
	if c ~= nil then
		return c.VLThreshold
	end
	return 6
end

local function setback(rec)
	local plr = rec.player
	local char = plr.Character
	if char == nil then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = hum and hum.RootPart
	if root == nil then return end

	local t = now()
	rec.setbacks += 1
	rec.setbackCooldownUntil = t + Settings.Setback.Cooldown
	rec.exemptUntil = t + Settings.Grace.AfterSetback
	rec.stateTable.exemptUntil = rec.exemptUntil
	rec.stateTable.setbackCount = rec.setbacks

	local target = CFrame.new(rec.lastValidPos) * CFrame.Angles(0, rec.lastValidYaw or 0, 0)
	pcall(function()
		char:PivotTo(target)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end)

	if Settings.Debug then
		warn(string.format("[NanoAC-R] set back %s to (%.1f, %.1f, %.1f)", rec.name, rec.lastValidPos.X, rec.lastValidPos.Y, rec.lastValidPos.Z))
	end

	if Settings.Punish.KickAfterSetbacks > 0 and rec.setbacks >= Settings.Punish.KickAfterSetbacks then
		plr:Kick(Settings.Punish.KickMessage)
	end
end

local function handleViolation(vrec, t)
	local rec = records[vrec.userId]
	if rec == nil then return end
	if not Settings.Enabled then return end
	if t < rec.graceUntil or t < rec.exemptUntil then return end

	local check = vrec.check
	local cfg = Settings.Checks[check]
	if cfg ~= nil and cfg.Enabled == false then return end

	local cur = (rec.vl[check] or 0) + 1
	rec.vl[check] = cur

	if Settings.Debug then
		print(string.format("[NanoAC-R] %s failed %s VL=%.1f mag=%.2f %s",
			rec.name, check, cur, vrec.magnitude or 0, vrec.detail or ""))
	end

	-- remember we flagged this player so the safe spot stops advancing (see sample())
	rec.lastFlagTime = t

	-- always-show-flags mode (/verbose): emit every raw flag to the typing player
	if verbosePlayers[vrec.userId] == true then
		alertEvent:FireClient(rec.player, string.format("[NanoAC-R] %s failed %s VL:%.1f mag:%.2f %s",
			rec.name, check, cur, vrec.magnitude or 0, vrec.detail or ""), Settings.Alerts.Color)
	end

	if t >= rec.setbackCooldownUntil then
		local crossedThreshold = cur >= thresholdFor(check)
		if crossedThreshold then
			-- Exact required alert format: "<username> failed <Check> VL:<times> Times"
			sendAlert(string.format("%s failed %s VL:%d Times", rec.name, check, math.floor(math.min(cur, Settings.VL.MaxDisplay))))
		end
		if Settings.Setback.Enabled and (Settings.Setback.OnEveryFlag or crossedThreshold) then
			setback(rec)
		end
	end
end

local function drainQueue(t)
	local write = QUEUE["write"]
	local read = QUEUE["read"]
	if write <= read then return end
	for i = read + 1, write do
		local vrec = QUEUE[i]
		if vrec ~= nil then
			local ok, err = pcall(handleViolation, vrec, t)
			if not ok then
				warn("[NanoAC-R] violation handling error: " .. tostring(err))
			end
		end
		QUEUE[i] = nil
	end
	QUEUE["read"] = write
end

-- =====================================================================================
--  PER-FRAME SAMPLING  (serial)
-- =====================================================================================
local function overlapsSolid(pos, char)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char }
	params.MaxParts = 8
	local parts = Workspace:GetPartBoundsInRadius(pos, 1.0, params)
	for _, part in ipairs(parts) do
		if part:IsA("BasePart") and part.CanCollide and part.Transparency < 0.9 then
			local lp = part.CFrame:PointToObjectSpace(pos)
			local h = part.Size * 0.5
			if math.abs(lp.X) <= h.X and math.abs(lp.Y) <= h.Y and math.abs(lp.Z) <= h.Z then
				return true
			end
		end
	end
	return false
end

local function sample(rec, t)
	local plr = rec.player
	local st = rec.stateTable
	local char = plr.Character
	if char == nil then
		st.dead = true
		st.alive = false
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = hum and hum.RootPart
	if hum == nil or root == nil then
		st.alive = false
		return
	end
	if hum.Health <= 0 then
		st.dead = true
		st.alive = false
		return
	end

	local pos = root.Position
	local prevT = rec.lastSampleTime
	local dt = prevT and (t - prevT) or 0
	rec.lastSampleTime = t
	local vy = 0
	if rec.lastSamplePos ~= nil and dt > 0.001 then
		vy = (pos.Y - rec.lastSamplePos.Y) / dt
	end
	rec.lastSamplePos = pos
	local pvy = rec.lastVy or vy
	rec.lastVy = vy

	local hstate = hum:GetState()
	local grounded = hum.FloorMaterial ~= Enum.Material.Air
	local seated = (hstate == Enum.HumanoidStateType.Seated) or hum.Sit
	local swim = (hstate == Enum.HumanoidStateType.Swimming) or (hum.FloorMaterial == Enum.Material.Water)
	local climb = hstate == Enum.HumanoidStateType.Climbing
	local platform = hstate == Enum.HumanoidStateType.PlatformStanding
	local phys = (hstate == Enum.HumanoidStateType.Physics) or (hstate == Enum.HumanoidStateType.Ragdoll)
	local freefall = hstate == Enum.HumanoidStateType.Freefall
	local jumping = hstate == Enum.HumanoidStateType.Jumping

	-- Remember the most recent safe, supported spot for setbacks.
	local supported = grounded or seated or swim or climb or platform
	local inGrace = t < rec.graceUntil
	local exempt = t < rec.exemptUntil
	local moved = rec.prevSamplePos ~= nil and (pos - rec.prevSamplePos).Magnitude or 1
	rec.prevSamplePos = pos
	-- Advance the safe spot only on open, supported ground (never while intersecting a solid),
	-- so a player phasing through a wall keeps their last valid position behind the wall.
	local recentlyFlagged = Settings.Setback.FreezeSafeSpotOnFlag and rec.lastFlagTime ~= nil and (t - rec.lastFlagTime) <= 0.75
	if supported and not inGrace and not exempt and moved > 0.25 and not recentlyFlagged then
		if not overlapsSolid(pos, char) then
			rec.lastValidPos = pos
			rec.lastValidYaw = yawOf(root)
			rec.lastValidTime = t
		end
	end

	st.pos = pos
	st.time = t
	st.dt = dt
	st.ping = plr:GetNetworkPing()
	st.walkSpeed = hum.WalkSpeed
	st.jumpPower = hum.JumpPower
	st.hipHeight = hum.HipHeight
	st.grounded = grounded
	st.vy = vy
	st.pvy = pvy
	st.airborne = not grounded
	st.wasAirborne = rec.prevAirborne == true
	rec.prevAirborne = not grounded
	st.stateName = hstate.Name
	st.swim = swim
	st.climb = climb
	st.seated = seated
	st.platform = platform
	st.phys = phys
	st.freefall = freefall
	st.jumping = jumping
	st.dead = false
	st.alive = true
	st.graceUntil = rec.graceUntil
	st.exemptUntil = rec.exemptUntil
	st.lastValidPos = rec.lastValidPos
	st.lastValidYaw = rec.lastValidYaw
	st.lastValidTime = rec.lastValidTime
	st.setbackCount = rec.setbacks
end

RunService.PostSimulation:Connect(function()
	local t = now()

	for _, rec in pairs(records) do
		local ok, err = pcall(sample, rec, t)
		if not ok then
			warn("[NanoAC-R] sample error for " .. tostring(rec.name) .. ": " .. tostring(err))
		end

		-- Continuous VL decay.
		local dt = t - rec.lastDecay
		if dt > 0 then
			rec.lastDecay = t
			for k, v in pairs(rec.vl) do
				local nv = v - Settings.VL.DecayPerSecond * dt
				rec.vl[k] = nv > 0 and nv or 0
			end
		end
	end

	local ok, err = pcall(drainQueue, t)
	if not ok then
		warn("[NanoAC-R] drain error: " .. tostring(err))
	end
end)

if Settings.Debug then
	print("[NanoAC-R] Coordinator online. " .. tostring(#Players:GetPlayers()) .. " player(s) tracked.")
end
