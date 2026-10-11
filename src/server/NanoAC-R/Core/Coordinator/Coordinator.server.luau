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
	  * The BanManager (strikes -> warn/kick, idle decay, whitelist, rejoin ban)

	Every check lives under its own Actor so its movement maths runs in parallel. Checks
	never touch the DataModel; they only write into the shared queue, which this script
	drains once per frame on the serial phase.

	Actor hierarchy (ServerScriptService):
	  NanoAC-R (Actor)
	    ├─ NanoShared (ModuleScript)
	    ├─ ExemptTeleport / ReportHit / ReportKnockback / ReportShot / ReportHeal / BanManager
	    ├─ Core/           Coordinator (this file)
	    ├─ Movement/       { Phase, Speed, Timer, Teleport, Step, Spider, Movement }
	    ├─ Flight/         { FlightA, FlightB, FlightC, FlightD, Fly }
	    ├─ Player/         { HumanoidGuard, StateGuard, IntegrityGuard, NoclipGuard,
	    │                     PhysicsGuard, HealthGuard, HitboxGuard }
	    ├─ Combat/         { ThroughWall, Velocity, Hit, Fling, FireRate }
	    └─ Network/        { RemoteGuard, ToolGuard, ExploitGuard }

	PERF NOTES (see the "perf fix N" comments throughout)
	  * Config is published once as a single nested SharedTable (CONFIG.snapshot) and the
	    checks cache a plain copy of it; a timer task refreshes that copy on revision change.
	  * Violations are sharded across NanoAC_Queue / NanoAC_Queue_2..8 to lower write
	    contention between parallel checks.
	  * Joins/leaves are published as a bounded event log so checks update incrementally.
	  * Per-player state is dirty-checked so unchanged fields are not republished.
	  To measure contention/frame cost: open Studio's MicroProfiler and look for the
	  "NanoAC-R sample", "NanoAC-R drainQueue" and per-check "NanoAC-R <Check>" labels.
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
local CONFIG = Shared.config
local ROSTER_EVENTS = Shared.rosterEvents
local QUEUES = Shared.queues
local QUEUE_SHARDS = Shared.QUEUE_SHARDS

-- Combat / sensor event queues: the game reports actions via bindables; the checks
-- drain + validate these from parallel (except the serial network sensors).
local HITS = SharedTableRegistry:GetSharedTable("NanoAC_Hits")
local KNOCKS = SharedTableRegistry:GetSharedTable("NanoAC_Knockbacks")
local HITGUARD = SharedTableRegistry:GetSharedTable("NanoAC_HitGuard")
local SHOTS = SharedTableRegistry:GetSharedTable("NanoAC_Shots")
local HEALS = SharedTableRegistry:GetSharedTable("NanoAC_Heals")
local function seed(queue)
	if queue["write"] == nil then queue["write"] = 0 end
	if queue["read"] == nil then queue["read"] = 0 end
end
seed(HITS); seed(KNOCKS); seed(HITGUARD); seed(SHOTS); seed(HEALS)
-- Violation shards are seeded by NanoShared at require time. The sensor queue names are
-- published to the checks as part of the config snapshot (see publishConfig).

-- =====================================================================================
--  SETTINGS  (everything is tunable here; the checks read a mirrored copy of this table)
-- =====================================================================================
local Settings = {
	-- Master switches
	Enabled = true,
	Debug = false,                 -- true = verbose server console output for every flag

	-- How often (seconds) the serial character scan runs for the property guards
	-- (hitbox / physics / collision / humanoid-count). Between scans the cached values
	-- are republished, so this is a pure CPU saving, not a detection delay for movement.
	ScanInterval = 0.5,

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
		AllowSelfToggle = false,   -- any player may type /verbose to always see flags (debug)
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
		OnEveryFlag = true,        -- set back on ANY flag, not only threshold crossings
		FreezeSafeSpotOnFlag = true, -- don't advance the safe spot while a player is flagged
	},

	-- Placeholder punishment hook -----------------------------------------------------
	Punish = {
		KickAfterSetbacks = 0,     -- 0 = never kick; else kick after this many setbacks
		KickMessage = "NanoAC-R: too many movement violations.",
	},

	-- BanManager: strikes -> warn / kick, idle decay, whitelist, rejoin ban ------------
	BanManager = {
		Enabled = true,
		KickEnabled = true,        -- master switch for the kick punishment
		WarnAt = 8,                -- total strikes before the player is warned
		KickAt = 20,               -- total strikes before the player is kicked (0 = never)
		StrikeDecayPerSecond = 0.25, -- idle decay of the strike counter
		WarnCooldown = 15,         -- seconds between warnings to one player
		WhitelistIds = {           -- never flagged, never struck
			-- 12345678,
		},
		WhitelistAttribute = "NanoAC_Whitelisted",
		Persist = false,           -- true = store rejoin bans in a DataStore
		DataStoreName = "NanoAC_Bans",
		BanDuration = 3600,        -- seconds a rejoin ban lasts
		KickMessage = "NanoAC-R: you have been removed by the anti-cheat.",
		BanMessage = "NanoAC-R: you are temporarily banned from this server.",
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

		-- NEW GUARDS ------------------------------------------------------------------
		Movement = {                  -- CFrame-walk: moved with no matching velocity
			Enabled = true, VLThreshold = 6, RequiredStreak = 3, EmitCooldown = 0.4,
			MinMove = 3.0,             -- ignore moves shorter than this (studs)
			VelocitySlack = 1.8,       -- allowance = |vel|*dt*this + PingAllowance
			PingAllowance = 6,
		},
		Humanoid = {                  -- WalkSpeed / JumpPower / JumpHeight / HipHeight / MaxSlopeAngle
			Enabled = true, VLThreshold = 5, RequiredStreak = 2, EmitCooldown = 0.5,
			WalkTolerance = 0.75,      -- absolute studs/s tolerance vs baseline
			JumpTolerance = 2,         -- absolute jump-power tolerance
			JumpHeightTolerance = 0.5,
			HipTolerance = 0.35,
			SlopeTolerance = 1.0,      -- degrees
		},
		State = {                     -- Flying / StrafingNoPhysics, fake sit
			Enabled = true, VLThreshold = 5, RequiredStreak = 2, EmitCooldown = 0.5,
			SitGrace = 1.0,            -- seconds a Sit-with-no-seat must persist
		},
		Integrity = {                 -- disabled Dead/Freefall, enabled Flying, extra Humanoids
			Enabled = true, VLThreshold = 5, RequiredStreak = 2, EmitCooldown = 0.5,
		},
		Noclip = {                    -- HRP/limb collision off, NoCollisionConstraint
			Enabled = true, VLThreshold = 5, RequiredStreak = 2, EmitCooldown = 0.5,
		},
		Fly = {                       -- PlatformStand fly/hover, illegal ascent
			Enabled = true, VLThreshold = 6, RequiredStreak = 2, EmitCooldown = 0.4,
			MaxDescent = 8,            -- |vy| below this while platform/hovering counts as hover
			MinAirTime = 0.6,          -- seconds before a hover/ascent flags
			MinAscent = 8,             -- studs/s upward that is illegal without a launcher
		},
		Swim = {                      -- swim-in-air (own mode; separate from Fly)
			Enabled = true, VLThreshold = 5, RequiredStreak = 2, EmitCooldown = 0.4,
			MinTime = 0.4,             -- seconds swimming outside water before flagging
		},
		Physics = {                   -- injected movers / constraints / LineForce
			Enabled = true, VLThreshold = 4, RequiredStreak = 1, EmitCooldown = 0.5,
			IgnoreNames = "NanoAC_Legit,NanoAC_FlyAtt,NanoAC_Fly", -- comma list or attribute
		},
		Health = {                    -- MaxHealth tamper, Health > MaxHealth, heal bursts
			Enabled = true, VLThreshold = 5, RequiredStreak = 1, EmitCooldown = 0.5,
			MaxHealthTolerance = 1,    -- absolute change of MaxHealth vs baseline
			OverhealTolerance = 0.5,   -- Health may exceed MaxHealth by this
			HealBurst = 25,            -- single-sample health gain above this is illegal
			HealPerSecond = 10,        -- sustained regen credit per second
		},
		Hitbox = {                    -- inflated limbs / HRP / accessory handles
			Enabled = true, VLThreshold = 5, RequiredStreak = 2, EmitCooldown = 0.5,
			GrowthRatio = 1.15,        -- part magnitude above baseline * this flags
			GrowthTolerance = 0.5,     -- absolute studs of tolerance
			AccessoryMaxSize = 4.0,    -- accessory handle magnitude above this flags
		},
		Fling = {                     -- extreme angular/linear velocity used to fling
			Enabled = true, VLThreshold = 4, RequiredStreak = 2, EmitCooldown = 0.4,
			MaxAngular = 60,           -- rad/s
			MaxSpeed = 750,            -- studs/s
		},
		Hit = {                       -- reach, ping cushion, hit spam, kill aura
			Enabled = true, VLThreshold = 5, RequiredStreak = 1, EmitCooldown = 0.4,
			Reach = 9.0,               -- studs of allowed reach
			PingAllowance = 3.0,       -- extra studs of reach per second of ping
			MaxHitsPerSecond = 20,
			AuraTargets = 4,           -- distinct victims within AuraWindow = kill aura
			AuraWindow = 0.6,
		},
		FireRate = {                  -- shot rate limits
			Enabled = true, VLThreshold = 5, RequiredStreak = 2, EmitCooldown = 0.5,
			MaxShotsPerSecond = 12,
			Window = 1.0,
			Grace = 0.15,              -- ignore the very first shots in a burst window
		},
		Remote = {                    -- global + per-remote spam + oversized payloads
			Enabled = true, VLThreshold = 6, RequiredStreak = 1, EmitCooldown = 0.5,
			MaxPerSecond = 60,         -- per player, across all remotes
			MaxPerRemotePerSecond = 30,
			MaxPayload = 8000,         -- characters of string payload per call
			MaxArgs = 12,
		},
		Tool = {                      -- tool equip / activate spam
			Enabled = true, VLThreshold = 5, RequiredStreak = 1, EmitCooldown = 0.5,
			MaxEquipsPerSecond = 6,
			MaxActivatesPerSecond = 14,
			Window = 1.0,
		},
		Exploit = {                   -- suspicious remote names
			Enabled = true, VLThreshold = 3, RequiredStreak = 1, EmitCooldown = 2.0,
			Patterns = "getgenv,getrawmetatable,httpget,loadstring,backdoor,exploit,hack,killaura,aimbot,godmode,virus,redeem,unlimited,admin,kick,ban,ss,__",
		},
	},
}

-- =====================================================================================
--  PUBLISH CONFIG  (mirror the numeric/bool settings into a SharedTable for the checks)
-- =====================================================================================
-- Split a comma-delimited settings string into an array (perf fix 3: parsed once here,
-- at publish time, instead of on every cfgList() call in the checks).
local function parseCsvList(raw)
	local out = {}
	if type(raw) == "string" then
		for item in string.gmatch(raw, "[^,]+") do
			local trimmed = string.match(item, "^%s*(.-)%s*$")
			if trimmed ~= "" then
				out[#out + 1] = trimmed
			end
		end
	end
	return out
end

-- Legacy checks are filled into the flat config table supplied by publishConfig, so the
-- whole config is written to the SharedTable in a single batched operation (perf fix 4).
local function fillLegacy(flat)
	local p = Settings.Checks.Phase
	flat.phaseEnabled = p.Enabled
	flat.phaseVlThreshold = p.VLThreshold
	flat.phaseRequiredStreak = p.RequiredStreak
	flat.phaseEmitCooldown = p.EmitCooldown
	flat.phaseMinMove = p.MinMove
	flat.phaseMinPartThickness = p.MinPartThickness
	flat.phaseMaxTransparency = p.MaxTransparency
	flat.phaseSpeedFactor = p.SpeedFactor
	flat.phaseMaxSegment = p.MaxSegment

	local s = Settings.Checks.Speed
	flat.speedEnabled = s.Enabled
	flat.speedVlThreshold = s.VLThreshold
	flat.speedRequiredStreak = s.RequiredStreak
	flat.speedEmitCooldown = s.EmitCooldown
	flat.speedMaxMultiplier = s.MaxMultiplier
	flat.speedPingAllowance = s.PingAllowance
	flat.speedAbsoluteCap = s.AbsoluteCap
	flat.speedMinSpeed = s.MinSpeed
	flat.speedWindow = s.Window

	local a = Settings.Checks.FlightA
	flat.flightAEnabled = a.Enabled
	flat.flightAVlThreshold = a.VLThreshold
	flat.flightARequiredStreak = a.RequiredStreak
	flat.flightAEmitCooldown = a.EmitCooldown
	flat.flightAMaxMultiplier = a.MaxMultiplier
	flat.flightAMinSpeed = a.MinSpeed
	flat.flightAGainMultiplier = a.GainMultiplier
	flat.flightAGainWindow = a.GainWindow
	flat.flightALeniency = a.Leniency

	local g2 = Settings.Checks.FlightB
	flat.flightBEnabled = g2.Enabled
	flat.flightBVlThreshold = g2.VLThreshold
	flat.flightBRequiredStreak = g2.RequiredStreak
	flat.flightBEmitCooldown = g2.EmitCooldown
	flat.flightBMaxDescent = g2.MaxDescent
	flat.flightBMinAirTime = g2.MinAirTime

	local d = Settings.Checks.FlightC
	flat.flightCEnabled = d.Enabled
	flat.flightCVlThreshold = d.VLThreshold
	flat.flightCRequiredStreak = d.RequiredStreak
	flat.flightCEmitCooldown = d.EmitCooldown
	flat.flightCMinFallTime = d.MinFallTime
	flat.flightCExpectedRatio = d.ExpectedRatio
	flat.flightCMinFallSpeed = d.MinFallSpeed

	local fd = Settings.Checks.FlightD
	flat.flightDEnabled = fd.Enabled
	flat.flightDVlThreshold = fd.VLThreshold
	flat.flightDRequiredStreak = fd.RequiredStreak
	flat.flightDEmitCooldown = fd.EmitCooldown
	flat.flightDAirDelay = fd.AirDelay
	flat.flightDMinRise = fd.MinRise

	local st = Settings.Checks.Step
	flat.stepEnabled = st.Enabled
	flat.stepVlThreshold = st.VLThreshold
	flat.stepRequiredStreak = st.RequiredStreak
	flat.stepEmitCooldown = st.EmitCooldown
	flat.stepMaxStep = st.MaxStep

	local sp = Settings.Checks.Spider
	flat.spiderEnabled = sp.Enabled
	flat.spiderVlThreshold = sp.VLThreshold
	flat.spiderRequiredStreak = sp.RequiredStreak
	flat.spiderEmitCooldown = sp.EmitCooldown
	flat.spiderMinClimbSpeed = sp.MinClimbSpeed
	flat.spiderMinSustain = sp.MinSustain
	flat.spiderWallDistance = sp.WallDistance

	local tw = Settings.Checks.ThroughWall
	flat.throughWallEnabled = tw.Enabled
	flat.throughWallVlThreshold = tw.VLThreshold
	flat.throughWallRequiredStreak = tw.RequiredStreak
	flat.throughWallEmitCooldown = tw.EmitCooldown
	flat.throughWallStartOffset = tw.StartOffset
	flat.throughWallEndOffset = tw.EndOffset

	local ve = Settings.Checks.Velocity
	flat.velocityEnabled = ve.Enabled
	flat.velocityVlThreshold = ve.VLThreshold
	flat.velocityRequiredStreak = ve.RequiredStreak
	flat.velocityEmitCooldown = ve.EmitCooldown
	flat.velocityMinKnockback = ve.MinKnockback
	flat.velocityRatio = ve.Ratio
	flat.velocityWindow = ve.Window
	flat.velocityRoom = ve.Room

	local tm = Settings.Checks.Timer
	flat.timerEnabled = tm.Enabled
	flat.timerVlThreshold = tm.VLThreshold
	flat.timerRequiredStreak = tm.RequiredStreak
	flat.timerEmitCooldown = tm.EmitCooldown
	flat.timerWindow = tm.Window
	flat.timerAllowedRatio = tm.AllowedRatio
	flat.timerMinSamples = tm.MinSamples
	flat.timerMinSpeed = tm.MinSpeed

	local tp = Settings.Checks.Teleport
	flat.teleportEnabled = tp.Enabled
	flat.teleportVlThreshold = tp.VLThreshold
	flat.teleportRequiredStreak = tp.RequiredStreak
	flat.teleportEmitCooldown = tp.EmitCooldown
	flat.teleportHorizMultiplier = tp.HorizMultiplier
	flat.teleportPingAllowance = tp.PingAllowance
	flat.teleportMinDistance = tp.MinDistance
	flat.teleportUpMultiplier = tp.UpMultiplier
	flat.teleportTerminalVelocity = tp.TerminalVelocity
	flat.teleportDownMultiplier = tp.DownMultiplier
end

-- New checks use a table-driven publisher: every scalar field becomes
-- "<prefix><Field>" (e.g. Humanoid.Enabled -> humanoidEnabled).
local PUBLISH = {
	{ name = "Movement",  prefix = "movement",  fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown", "MinMove", "VelocitySlack", "PingAllowance" } },
	{ name = "Humanoid",  prefix = "humanoid",  fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown", "WalkTolerance", "JumpTolerance", "JumpHeightTolerance", "HipTolerance", "SlopeTolerance" } },
	{ name = "State",     prefix = "state",     fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown", "SitGrace" } },
	{ name = "Integrity", prefix = "integrity", fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown" } },
	{ name = "Noclip",    prefix = "noclip",    fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown" } },
	{ name = "Fly",       prefix = "fly",       fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown", "MaxDescent", "MinAirTime", "MinAscent" } },
	{ name = "Swim",      prefix = "swim",      fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown", "MinTime" } },
	{ name = "Physics",   prefix = "physics",   fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown" } },
	{ name = "Health",    prefix = "health",    fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown", "MaxHealthTolerance", "OverhealTolerance", "HealBurst", "HealPerSecond" } },
	{ name = "Hitbox",    prefix = "hitbox",    fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown", "GrowthRatio", "GrowthTolerance", "AccessoryMaxSize" } },
	{ name = "Fling",     prefix = "fling",     fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown", "MaxAngular", "MaxSpeed" } },
	{ name = "Hit",       prefix = "hit",       fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown", "Reach", "PingAllowance", "MaxHitsPerSecond", "AuraTargets", "AuraWindow" } },
	{ name = "FireRate",  prefix = "fireRate",  fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown", "MaxShotsPerSecond", "Window", "Grace" } },
	{ name = "Remote",    prefix = "remote",    fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown", "MaxPerSecond", "MaxPerRemotePerSecond", "MaxPayload", "MaxArgs" } },
	{ name = "Tool",      prefix = "tool",      fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown", "MaxEquipsPerSecond", "MaxActivatesPerSecond", "Window" } },
	{ name = "Exploit",   prefix = "exploit",   fields = { "Enabled", "VLThreshold", "RequiredStreak", "EmitCooldown" } },
}

local function publishConfig()
	local flat = {}

	flat.paused = not Settings.Enabled
	flat.debug = Settings.Debug
	flat.gravity = Workspace.Gravity
	flat.scanInterval = Settings.ScanInterval

	flat.graceSpawn = Settings.Grace.AfterSpawn
	flat.graceTeleport = Settings.Grace.AfterTeleport
	flat.graceSetback = Settings.Grace.AfterSetback
	flat.graceSeat = Settings.Grace.AfterSeat

	flat.vlDecay = Settings.VL.DecayPerSecond
	flat.vlMax = Settings.VL.MaxDisplay
	flat.setbackEnabled = Settings.Setback.Enabled
	flat.setbackCooldown = Settings.Setback.Cooldown
	flat.kickAfterSetbacks = Settings.Punish.KickAfterSetbacks

	fillLegacy(flat)

	for _, spec in ipairs(PUBLISH) do
		local c = Settings.Checks[spec.name]
		if c ~= nil then
			for _, f in ipairs(spec.fields) do
				flat[spec.prefix .. f] = c[f]
			end
		end
	end

	-- Combat / sensor queue names (read by the combat checks at require time).
	flat.hitsName = "NanoAC_Hits"
	flat.knocksName = "NanoAC_Knockbacks"
	flat.hitguardName = "NanoAC_HitGuard"
	flat.shotsName = "NanoAC_Shots"
	flat.healsName = "NanoAC_Heals"

	-- String / list configs: the raw strings are kept and the parsed arrays are
	-- published alongside them so cfgList() never parses on the check side (fix 3).
	flat.physicsIgnoreNames = Settings.Checks.Physics.IgnoreNames
	flat.exploitPatterns = Settings.Checks.Exploit.Patterns
	flat.physicsIgnoreNamesList = SharedTable.new(parseCsvList(Settings.Checks.Physics.IgnoreNames))
	flat.exploitPatternsList = SharedTable.new(parseCsvList(Settings.Checks.Exploit.Patterns))

	-- BanManager
	local bm = Settings.BanManager
	flat.banEnabled = bm.Enabled
	flat.banKickEnabled = bm.KickEnabled
	flat.banWarnAt = bm.WarnAt
	flat.banKickAt = bm.KickAt
	flat.banDecay = bm.StrikeDecayPerSecond

	-- Single batched publish (perf fix 4): the whole flat config becomes one nested
	-- SharedTable assigned with a single CONFIG write; the revision then signals the
	-- checks to refresh their local snapshot.
	CONFIG.snapshot = SharedTable.new(flat)
	CONFIG.revision = (CONFIG.revision or 0) + 1
end

publishConfig()

-- =====================================================================================
--  HELPERS
-- =====================================================================================
local function now()
	return Workspace:GetServerTimeNow()
end

-- Roster-event log (perf fix 2). Appends one add/remove event; runCheck applies these
-- incrementally instead of rebuilding its whole roster array. The log is a bounded
-- window: a reader that falls behind it (e.g. a disabled check) does one full rebuild.
local ROSTER_EVENT_WINDOW = Shared.ROSTER_EVENT_WINDOW
local function pushRosterEvent(userId, add)
	local old = SharedTable.increment(ROSTER_EVENTS, "write", 1)
	local index = old + 1
	ROSTER_EVENTS[index] = SharedTable.new({ userId = userId, add = add })
	local first = ROSTER_EVENTS["first"] or 1
	if index - first >= ROSTER_EVENT_WINDOW then
		local newFirst = index - ROSTER_EVENT_WINDOW + 1
		for i = first, newFirst - 1 do
			ROSTER_EVENTS[i] = nil
		end
		ROSTER_EVENTS["first"] = newFirst
	end
end

local function yawOf(root)
	local look = root.CFrame.LookVector
	return math.atan2(-look.X, -look.Z)
end

-- Plain Lua record owned exclusively by this serial script.
local records = {}        -- [userId] = record
local verbosePlayers = {} -- [userId] = true (raw flag output)
local setupCommands       -- forward declaration
local isWhitelisted       -- forward declaration
local notify              -- forward declaration
local Bans                -- forward declaration

local DEFAULT_BASELINE = {
	walk = 16, jump = 50, jumpHeight = 7.2, hip = 2, slope = 89,
	health = 100, maxHealth = 100, hitbox = 0, accessory = 0,
}

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
		jumpHeight = 7.2,
		maxSlopeAngle = 89,
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
		-- extended state (new guards)
		health = 100,
		maxHealth = 100,
		walkBase = 16,
		jumpBase = 50,
		jumpHeightBase = 7.2,
		hipBase = 2,
		slopeBase = 89,
		healthBase = 100,
		maxHealthBase = 100,
		hitbox = 0,
		hitboxBase = 0,
		accessory = 0,
		accessoryBase = 0,
		hrpCanCollide = true,
		limbNoCollide = 0,
		noCollision = 0,
		platformStand = false,
		flying = false,
		flyingEnabled = true,
		flyingEnabledBase = true,
		deadDisabled = false,
		deadDisabledBase = false,
		freefallDisabled = false,
		freefallDisabledBase = false,
		strafingNoPhysics = false,
		sitNoSeat = false,
		swimInAir = false,
		humanoidCount = 1,
		physCount = 0,
		vel = Vector3.zero,
		angVel = Vector3.zero,
		angSpeed = 0,
		whitelisted = false,
		strikes = 0,
		-- Precomputed exemption aggregates (see NanoShared.isExempt/isGrace): the checks
		-- read one field instead of re-deriving the same booleans every frame.
		exemptMove = true,
		exemptGrace = true,
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
		strikes = 0,
		lastDecay = now(),
		lastWarn = 0,
		lastScan = 0,
		baseSet = false,
		baseline = {},
		vl = {},
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
	rec.baseSet = false
	rec.baseline = {}
	rec.lastScan = 0
	local st = rec.stateTable
	st.graceUntil = rec.graceUntil
	st.exemptUntil = rec.exemptUntil
	st.dead = true
	st.alive = false
	st.exemptMove = true
	st.exemptGrace = true
end

local function onPlayerAdded(plr)
	if records[plr.UserId] ~= nil then return end

	-- BanManager: refuse a still-active rejoin ban.
	if Settings.BanManager.Enabled then
		local banned, until_ = Bans.isBanned(plr, function(expiry)
			plr:Kick(Settings.BanManager.BanMessage)
		end)
		if banned then
			return
		end
	end

	local rec = newRecord(plr)
	rec.graceUntil = now() + Settings.Grace.AfterSpawn
	rec.exemptUntil = now() + Settings.Grace.AfterTeleport
	rec.lastDecay = now()
	records[plr.UserId] = rec
	ROSTER[plr.UserId] = rec.stateTable
	pushRosterEvent(plr.UserId, true)

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
	pushRosterEvent(plr.UserId, false)
end

-- =====================================================================================
--  BAN MANAGER  (strikes -> warn / kick, idle decay, whitelist, rejoin ban)
-- =====================================================================================
local DataStoreService
local banStore
if Settings.BanManager.Persist then
	local ok, dss = pcall(function() return game:GetService("DataStoreService") end)
	if ok then
		DataStoreService = dss
		local ok2, store = pcall(function()
			return DataStoreService:GetDataStore(Settings.BanManager.DataStoreName)
		end)
		if ok2 then banStore = store end
	end
end

local sessionBans = {}   -- [userId] = expiry (server time seconds)
local banNegCache = {}   -- [userId] = server time of the last "not banned" result
local BAN_NEG_TTL = 60   -- seconds to trust a negative result before re-checking
Bans = {}
function Bans.isBanned(plr, kickFn)
	local userId = plr.UserId
	local expiry = sessionBans[userId]
	if expiry == nil and banStore ~= nil then
		-- Negative caching (perf fix 7): most players are not banned, and a DataStore
		-- GetAsync is pure added join latency. Cache the "not banned" verdict briefly.
		local t = now()
		local negAt = banNegCache[userId]
		if negAt ~= nil and (t - negAt) < BAN_NEG_TTL then
			return false, 0
		end
		local ok, val = pcall(function() return banStore:GetAsync("ban_" .. userId) end)
		if ok and type(val) == "number" then
			expiry = val
			sessionBans[userId] = val
			banNegCache[userId] = nil
		else
			banNegCache[userId] = t
		end
	end
	if expiry == nil then return false, 0 end
	if now() >= expiry then
		sessionBans[userId] = nil
		if banStore ~= nil then
			pcall(function() banStore:RemoveAsync("ban_" .. userId) end)
		end
		banNegCache[userId] = now()
		return false, 0
	end
	if kickFn then
		task.defer(kickFn, expiry)
	end
	return true, expiry
end

function Bans.ban(plr, reason)
	local expiry = now() + Settings.BanManager.BanDuration
	sessionBans[plr.UserId] = expiry
	banNegCache[plr.UserId] = nil
	if banStore ~= nil then
		pcall(function() banStore:SetAsync("ban_" .. plr.UserId, expiry) end)
	end
	if Settings.Debug then
		warn(string.format("[NanoAC-R] banned %s (%s) until %d", plr.Name, tostring(reason), expiry))
	end
end

function Bans.strike(rec, reason, count)
	local amount = tonumber(count) or 1
	rec.strikes += amount
	rec.stateTable.strikes = rec.strikes
	local bm = Settings.BanManager
	if not bm.Enabled then return end
	if bm.KickEnabled and bm.KickAt > 0 and rec.strikes >= bm.KickAt then
		Bans.ban(rec.player, reason)
		if not isWhitelisted(rec.player) then
			rec.player:Kick(bm.KickMessage)
		end
		return
	end
	local t = now()
	if bm.WarnAt > 0 and rec.strikes >= bm.WarnAt and (t - rec.lastWarn) >= bm.WarnCooldown then
		rec.lastWarn = t
		notify(rec.player, string.format("[NanoAC-R] warning: strikes %d/%d (%s)", rec.strikes, bm.WarnAt, tostring(reason)))
	end
end

-- =====================================================================================
--  BINDABLES
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

-- ExemptTeleport API: other server scripts whitelist a legitimate teleport.
local exemptBindable = ensureBindable("ExemptTeleport")
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

-- Combat reporting API --------------------------------------------------------------
local reportHit = ensureBindable("ReportHit")
reportHit.OnInvoke = function(attacker, victim)
	if typeof(attacker) ~= "Instance" or not attacker:IsA("Player") then return false end
	if typeof(victim) ~= "Instance" or not victim:IsA("Player") then return false end
	local at = attacker.Character and attacker.Character:FindFirstChild("HumanoidRootPart")
	local vt = victim.Character and victim.Character:FindFirstChild("HumanoidRootPart")
	if at == nil or vt == nil then return false end
	local payload = {
		attacker = attacker.UserId,
		victim = victim.UserId,
		ax = at.Position.X, ay = at.Position.Y, az = at.Position.Z,
		vx = vt.Position.X, vy = vt.Position.Y, vz = vt.Position.Z,
		t = now(),
	}
	local i = SharedTable.increment(HITS, "write", 1) + 1
	HITS[i] = SharedTable.new(payload)
	local j = SharedTable.increment(HITGUARD, "write", 1) + 1
	HITGUARD[j] = SharedTable.new(payload)
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

-- FireRate API: game reports each shot it resolves.
local reportShot = ensureBindable("ReportShot")
reportShot.OnInvoke = function(plr, weapon)
	if typeof(plr) ~= "Instance" or not plr:IsA("Player") then return false end
	local i = SharedTable.increment(SHOTS, "write", 1) + 1
	SHOTS[i] = SharedTable.new({
		userId = plr.UserId,
		weapon = typeof(weapon) == "string" and weapon or "",
		t = now(),
	})
	return true
end

-- Health API: game reports a legitimate heal so HealthGuard can credit it.
local reportHeal = ensureBindable("ReportHeal")
reportHeal.OnInvoke = function(plr, amount)
	if typeof(plr) ~= "Instance" or not plr:IsA("Player") then return false end
	local amt = tonumber(amount) or 0
	local i = SharedTable.increment(HEALS, "write", 1) + 1
	HEALS[i] = SharedTable.new({ userId = plr.UserId, amount = amt, t = now() })
	return true
end

-- BanManager API: BanManager:Invoke(action, playerOrUserId, arg)
local banBindable = ensureBindable("BanManager")
banBindable.OnInvoke = function(action, subject, arg)
	if action == "strike" then
		local rec = typeof(subject) == "Instance" and records[subject.UserId]
		if rec then Bans.strike(rec, arg or "manual", 1); return true end
	elseif action == "whitelist" then
		if typeof(subject) == "Instance" then
			subject:SetAttribute(Settings.BanManager.WhitelistAttribute, true)
			local rec = records[subject.UserId]
			if rec then rec.stateTable.whitelisted = true end
			return true
		end
	elseif action == "unban" then
		local uid = typeof(subject) == "Instance" and subject.UserId or tonumber(subject)
		if uid then
			sessionBans[uid] = nil
			banNegCache[uid] = nil
			if banStore ~= nil then pcall(function() banStore:RemoveAsync("ban_" .. uid) end) end
			return true
		end
	elseif action == "isWhitelisted" then
		if typeof(subject) == "Instance" then return isWhitelisted(subject) end
	elseif action == "isBanned" then
		local uid = typeof(subject) == "Instance" and subject.UserId or tonumber(subject)
		if uid then return sessionBans[uid] ~= nil end
	end
	return false
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

local function topLevelNotify(plr, text, color)
	alertEvent:FireClient(plr, text, color or Settings.Alerts.Color)
end
notify = topLevelNotify

-- ---------------------------------------------------------------------------------
--  CHAT COMMANDS  --  /verbose toggles raw per-flag output for the typing player
-- ---------------------------------------------------------------------------------
setupCommands = function(plr)
	plr.Chatted:Connect(function(message)
		if type(message) ~= "string" then return end
		local text = message :: string
		-- Cheap early-out (perf fix 5): only a leading '/' (after optional whitespace)
		-- can start a command, so skip the 4-capture pattern for ordinary chat lines.
		if not string.find(text, "^%s*/") then return end
		local cmd, a1, a2, a3 = text:match("^%s*/(%S+)%s*(%S*)%s*(%S*)%s*(%S*)")
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
		elseif cmd == "velocity" and Settings.Debug then
			-- test command (debug only):  /velocity <amount> <left|right|up|down|forward|back> [fake]
			local amount = tonumber(a1)
			local dirName = (a2 or ""):lower()
			local fake = (a3 or ""):lower() == "fake"
			if amount == nil or amount <= 0 then
				notify(plr, "[NanoAC-R] usage: /velocity <amount> <left|right|up|down>", Settings.Alerts.Color)
				return
			end
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
						local att = Instance.new("Attachment")
						att.Name = "NanoAC_Legit"
						att.Parent = root
						local lv = Instance.new("LinearVelocity")
						lv.Name = "NanoAC_Legit"
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
	end)
end

for _, plr in ipairs(Players:GetPlayers()) do
	setupCommands(plr)
end

-- Staff / whitelist ---------------------------------------------------------------
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

isWhitelisted = function(plr)
	if plr == nil then return false end
	if table.find(Settings.BanManager.WhitelistIds, plr.UserId) then return true end
	if plr:GetAttribute(Settings.BanManager.WhitelistAttribute) == true then return true end
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
	if isWhitelisted(rec.player) then return end
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

	if verbosePlayers[vrec.userId] == true then
		alertEvent:FireClient(rec.player, string.format("[NanoAC-R] %s failed %s VL:%.1f mag:%.2f %s",
			rec.name, check, cur, vrec.magnitude or 0, vrec.detail or ""), Settings.Alerts.Color)
	end

	if t >= rec.setbackCooldownUntil then
		local crossedThreshold = cur >= thresholdFor(check)
		if crossedThreshold then
			sendAlert(string.format("%s failed %s VL:%d Times", rec.name, check, math.floor(math.min(cur, Settings.VL.MaxDisplay))))
			Bans.strike(rec, check, 1)
		end
		if Settings.Setback.Enabled and (Settings.Setback.OnEveryFlag or crossedThreshold) then
			setback(rec)
		end
	end
end

-- Violation queues are fed from parallel checks and drained here once per frame. Sharding
-- spreads the parallel write contention (perf fix 6), so the drainer now visits each shard.
-- If the checks ever outrun the drainer (a mass flag burst, a very slow frame) we must not
-- let a shard grow without bound. Two guards per shard:
--   * MAX_DRAIN_PER_FRAME bounds the serial work this frame can do (keeps frame time sane);
--   * MAX_QUEUE_BACKLOG drops the *oldest* surpluses when the backlog exceeds the cap, so
--     memory is bounded and the freshest violations are the ones that survive.
local MAX_DRAIN_PER_FRAME = 128   -- per shard; total per frame is SHARDS * this
local MAX_QUEUE_BACKLOG = 1024    -- per shard; total retained is bounded by SHARDS * this

local function drainShard(queue, t)
	local write = queue["write"]
	local read = queue["read"]
	if write <= read then return end

	-- Enforce the backlog cap before doing any work.
	local backlog = write - read
	if backlog > MAX_QUEUE_BACKLOG then
		local drop = backlog - MAX_QUEUE_BACKLOG
		local stop = read + drop
		for i = read + 1, stop do
			queue[i] = nil
		end
		read = stop
		queue["read"] = read
		if Settings.Debug then
			warn(string.format("[NanoAC-R] violation queue overrun: dropped %d oldest", drop))
		end
	end

	local target = write
	if target - read > MAX_DRAIN_PER_FRAME then
		target = read + MAX_DRAIN_PER_FRAME
	end
	for i = read + 1, target do
		local vrec = queue[i]
		if vrec ~= nil then
			local ok, err = pcall(handleViolation, vrec, t)
			if not ok then
				warn("[NanoAC-R] violation handling error: " .. tostring(err))
			end
		end
		queue[i] = nil
	end
	queue["read"] = target
end

local function drainQueue(t)
	for i = 1, QUEUE_SHARDS do
		drainShard(QUEUES[i], t)
	end
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

-- Physics item classes that are never part of a legitimately-joined character. The modern
-- R15 rig uses BallSocketConstraint / AnimationConstraint / RigidConstraint for its joints
-- and NoCollisionConstraint for accessory non-collision, so those are deliberately EXCLUDED.
local PHYS_CLASSES = {
	BodyVelocity = true, BodyAngularVelocity = true, BodyForce = true, BodyThrust = true,
	BodyPosition = true, BodyGyro = true, RocketPropulsion = true,
	LinearVelocity = true, AngularVelocity = true, VectorForce = true,
	AlignOrientation = true, AlignPosition = true, Torque = true, LineForce = true,
	CylindricalConstraint = true, HingeConstraint = true, PrismaticConstraint = true,
	RopeConstraint = true, RodConstraint = true, SpringConstraint = true,
	UniversalConstraint = true, PlaneConstraint = true,
}

local function scanCharacter(rec, char, hum)
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local limbNoCollide, hitbox, accessory = 0, 0, 0
	if hum ~= nil then
		for _, part in ipairs(char:GetChildren()) do
			if part:IsA("BasePart") then
				local limb = hum:GetLimb(part)
				-- HumanoidRootPart is not a "limb" to GetLimb, so include it explicitly.
				if limb ~= Enum.Limb.Unknown or part == hrp then
					local mag = part.Size.Magnitude
					if mag > hitbox then hitbox = mag end
					if part.CanCollide == false and part ~= hrp then limbNoCollide += 1 end
				end
			elseif part:IsA("Accessory") then
				local handle = part:FindFirstChild("Handle")
				if handle and handle:IsA("BasePart") then
					local mag = handle.Size.Magnitude
					if mag > accessory then accessory = mag end
				end
			end
		end
	end

	local noCollision, physCount, humanoidCount = 0, 0, 0
	local ignore = Settings.Checks.Physics.IgnoreNames
	local function ignored(inst)
		if inst:GetAttribute("NanoAC_Legit") == true then return true end
		if ignore ~= "" and string.find(ignore, inst.Name, 1, true) then return true end
		return false
	end
	for _, inst in ipairs(char:GetDescendants()) do
		local cls = inst.ClassName
		if inst:IsA("Humanoid") then
			humanoidCount += 1
		elseif cls == "NoCollisionConstraint" then
			-- The rig creates these for accessories on the limbs; an injected noclip
			-- constraint targets the HumanoidRootPart, so only count those.
			if inst.Parent == hrp then
				noCollision += 1
			end
		elseif PHYS_CLASSES[cls] == true then
			if not ignored(inst) then
				physCount += 1
			end
		end
	end

	rec.stateTable.hrpCanCollide = (hrp == nil) or hrp.CanCollide
	rec.stateTable.limbNoCollide = limbNoCollide
	rec.stateTable.noCollision = noCollision
	rec.stateTable.hitbox = hitbox
	rec.stateTable.accessory = accessory
	rec.stateTable.physCount = physCount
	rec.stateTable.humanoidCount = humanoidCount
end

local function sample(rec, t)
	local plr = rec.player
	local st = rec.stateTable
	local char = plr.Character
	if char == nil then
		st.dead = true
		st.alive = false
		st.exemptMove = true
		st.exemptGrace = true
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = hum and hum.RootPart
	if hum == nil or root == nil then
		st.alive = false
		st.exemptMove = true
		st.exemptGrace = true
		return
	end
	if hum.Health <= 0 then
		st.dead = true
		st.alive = false
		st.exemptMove = true
		st.exemptGrace = true
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

	-- Capture the spawn baseline once per character (used by the property guards).
	if not rec.baseSet then
		rec.baseSet = true
		rec.baseline = {
			walk = hum.WalkSpeed,
			jump = hum.JumpPower,
			jumpHeight = hum.JumpHeight,
			hip = hum.HipHeight,
			slope = hum.MaxSlopeAngle,
			health = hum.Health,
			maxHealth = hum.MaxHealth,
		}
		st.walkBase = rec.baseline.walk
		st.jumpBase = rec.baseline.jump
		st.jumpHeightBase = rec.baseline.jumpHeight
		st.hipBase = rec.baseline.hip
		st.slopeBase = rec.baseline.slope
		st.healthBase = rec.baseline.health
		st.maxHealthBase = rec.baseline.maxHealth
		st.flyingEnabledBase = hum:GetStateEnabled(Enum.HumanoidStateType.Flying)
		st.deadDisabledBase = not hum:GetStateEnabled(Enum.HumanoidStateType.Dead)
		st.freefallDisabledBase = not hum:GetStateEnabled(Enum.HumanoidStateType.Freefall)
		scanCharacter(rec, char, hum)
		st.hitboxBase = st.hitbox
		st.accessoryBase = st.accessory
		rec.lastScan = t
	end

	-- Throttled expensive character scan.
	local scanInterval = Settings.ScanInterval
	if (t - rec.lastScan) >= scanInterval then
		rec.lastScan = t
		local okScan, errScan = pcall(scanCharacter, rec, char, hum)
		if not okScan and Settings.Debug then
			warn("[NanoAC-R] scan error for " .. tostring(rec.name) .. ": " .. tostring(errScan))
		end
	end

	-- Remember the most recent safe, supported spot for setbacks.
	local supported = grounded or seated or swim or climb or platform
	local inGrace = t < rec.graceUntil
	local exempt = t < rec.exemptUntil
	local moved = rec.prevSamplePos ~= nil and (pos - rec.prevSamplePos).Magnitude or 1
	rec.prevSamplePos = pos
	local recentlyFlagged = Settings.Setback.FreezeSafeSpotOnFlag and rec.lastFlagTime ~= nil and (t - rec.lastFlagTime) <= 0.75
	if supported and not inGrace and not exempt and moved > 0.25 and not recentlyFlagged then
		if not overlapsSolid(pos, char) then
			rec.lastValidPos = pos
			rec.lastValidYaw = yawOf(root)
			rec.lastValidTime = t
		end
	end

	local vel = root.AssemblyLinearVelocity
	local angVel = root.AssemblyAngularVelocity

	st.pos = pos
	st.time = t
	st.dt = dt
	st.ping = plr:GetNetworkPing()
	--[[
		Dirty-checked republish (perf fix 8).

		These fields change rarely, so each is compared against a plain-Lua cache on the
		record and only written to the SharedTable when it actually changed. That removes
		most of the per-player, per-frame SharedTable lock acquisitions without splitting
		the state (the schema and every check's `state.<field>` access are unchanged).
	]]
	if hum.WalkSpeed ~= rec.lastWalkSpeed then
		rec.lastWalkSpeed = hum.WalkSpeed
		st.walkSpeed = hum.WalkSpeed
	end
	if hum.JumpPower ~= rec.lastJumpPower then
		rec.lastJumpPower = hum.JumpPower
		st.jumpPower = hum.JumpPower
	end
	if hum.JumpHeight ~= rec.lastJumpHeight then
		rec.lastJumpHeight = hum.JumpHeight
		st.jumpHeight = hum.JumpHeight
	end
	if hum.MaxSlopeAngle ~= rec.lastMaxSlopeAngle then
		rec.lastMaxSlopeAngle = hum.MaxSlopeAngle
		st.maxSlopeAngle = hum.MaxSlopeAngle
	end
	if hum.HipHeight ~= rec.lastHipHeight then
		rec.lastHipHeight = hum.HipHeight
		st.hipHeight = hum.HipHeight
	end
	st.grounded = grounded
	st.vy = vy
	st.pvy = pvy
	st.airborne = not grounded
	st.wasAirborne = rec.prevAirborne == true
	rec.prevAirborne = not grounded
	-- Only republish the state name when the Humanoid actually changes state: this is the
	-- one string field written every frame, and nothing reads it in the steady state.
	if hstate ~= rec.lastHState then
		rec.lastHState = hstate
		st.stateName = hstate.Name
	end
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

	-- Extended state -------------------------------------------------------------
	local health = hum.Health
	if health ~= rec.lastHealth then
		rec.lastHealth = health
		st.health = health
	end
	local maxHealth = hum.MaxHealth
	if maxHealth ~= rec.lastMaxHealth then
		rec.lastMaxHealth = maxHealth
		st.maxHealth = maxHealth
	end
	st.vel = vel
	st.angVel = angVel
	st.angSpeed = angVel.Magnitude
	local platformStand = hum.PlatformStand
	if platformStand ~= rec.lastPlatformStand then
		rec.lastPlatformStand = platformStand
		st.platformStand = platformStand
	end
	local flying = hstate == Enum.HumanoidStateType.Flying
	if flying ~= rec.lastFlying then
		rec.lastFlying = flying
		st.flying = flying
	end
	local flyingEnabled = hum:GetStateEnabled(Enum.HumanoidStateType.Flying)
	if flyingEnabled ~= rec.lastFlyingEnabled then
		rec.lastFlyingEnabled = flyingEnabled
		st.flyingEnabled = flyingEnabled
	end
	local deadDisabled = not hum:GetStateEnabled(Enum.HumanoidStateType.Dead)
	if deadDisabled ~= rec.lastDeadDisabled then
		rec.lastDeadDisabled = deadDisabled
		st.deadDisabled = deadDisabled
	end
	local freefallDisabled = not hum:GetStateEnabled(Enum.HumanoidStateType.Freefall)
	if freefallDisabled ~= rec.lastFreefallDisabled then
		rec.lastFreefallDisabled = freefallDisabled
		st.freefallDisabled = freefallDisabled
	end
	local strafingNoPhysics = hstate == Enum.HumanoidStateType.StrafingNoPhysics
	if strafingNoPhysics ~= rec.lastStrafingNoPhysics then
		rec.lastStrafingNoPhysics = strafingNoPhysics
		st.strafingNoPhysics = strafingNoPhysics
	end
	local sitNoSeat = (hum.Sit == true) and (hum.SeatPart == nil)
	if sitNoSeat ~= rec.lastSitNoSeat then
		rec.lastSitNoSeat = sitNoSeat
		st.sitNoSeat = sitNoSeat
	end
	local swimInAir = (hstate == Enum.HumanoidStateType.Swimming) and (hum.FloorMaterial ~= Enum.Material.Water)
	if swimInAir ~= rec.lastSwimInAir then
		rec.lastSwimInAir = swimInAir
		st.swimInAir = swimInAir
	end
	st.whitelisted = isWhitelisted(plr)
	st.strikes = rec.strikes

	-- Precomputed exemption aggregates consumed by NanoShared.isExempt/isGrace. Computed
	-- here (once per player per frame) from the values we just published so the ~20 checks
	-- each read a single field instead of re-evaluating the same booleans and windows.
	-- `t` is the same sample time every caller passes, so semantics are identical.
	local baseExempt = st.whitelisted or (t < rec.graceUntil) or (t < rec.exemptUntil)
	st.exemptGrace = baseExempt
	st.exemptMove = baseExempt or seated or swim or climb or platform or phys
end

RunService.PostSimulation:Connect(function()
	local t = now()

	-- MicroProfiler labels (perf instrumentation): open the MicroProfiler in Studio to
	-- measure the serial per-frame state publish and the violation drain under peak load.
	debug.profilebegin("NanoAC-R sample")
	for _, rec in pairs(records) do
		local ok, err = pcall(sample, rec, t)
		if not ok then
			warn("[NanoAC-R] sample error for " .. tostring(rec.name) .. ": " .. tostring(err))
		end

		-- Continuous VL + strike decay.
		local dt = t - rec.lastDecay
		if dt > 0 then
			rec.lastDecay = t
			for k, v in pairs(rec.vl) do
				local nv = v - Settings.VL.DecayPerSecond * dt
				rec.vl[k] = nv > 0 and nv or 0
			end
			if rec.strikes > 0 then
				rec.strikes = math.max(0, rec.strikes - Settings.BanManager.StrikeDecayPerSecond * dt)
				rec.stateTable.strikes = rec.strikes
			end
		end
	end
	debug.profileend()

	debug.profilebegin("NanoAC-R drainQueue")
	local ok, err = pcall(drainQueue, t)
	debug.profileend()
	if not ok then
		warn("[NanoAC-R] drain error: " .. tostring(err))
	end
end)

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, plr in ipairs(Players:GetPlayers()) do
	onPlayerAdded(plr)
end

if Settings.Debug then
	print("[NanoAC-R] Coordinator online. " .. tostring(#Players:GetPlayers()) .. " player(s) tracked.")
end
