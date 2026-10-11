--[[
	NanoAC-R | NanoShared
	Shared, serialisable communication layer for every check + the Coordinator.

	This module is REQUIRED IN A SERIAL CONTEXT (never while desynchronised), so it can
	cache service handles up-front. Every function below only reads/writes SharedTables
	or pure values, which makes them safe to call from parallel phases.

	Beware: a regular Luau table can NOT be shared across Actors. Everything that crosses
	thread boundaries lives in a SharedTable from SharedTableRegistry.
]]

local RunService = game:GetService("RunService")
local SharedTableRegistry = game:GetService("SharedTableRegistry")
local Players = game:GetService("Players")

local NanoShared = {}
NanoShared.RunService = RunService

-- Registry names. Keep in sync with the Coordinator.
NanoShared.NAMES = {
	ROSTER = "NanoAC_Roster",
	QUEUE = "NanoAC_Queue",
	CONFIG = "NanoAC_Config",
	ROSTER_EVENTS = "NanoAC_RosterEvents",
}

-- Resolve the shared handles once, at require time (serial).
NanoShared.roster = SharedTableRegistry:GetSharedTable(NanoShared.NAMES.ROSTER)
NanoShared.config = SharedTableRegistry:GetSharedTable(NanoShared.NAMES.CONFIG)
NanoShared.rosterEvents = SharedTableRegistry:GetSharedTable(NanoShared.NAMES.ROSTER_EVENTS)
NanoShared.Players = Players

--[[
	Violation queues  (perf fix 6).

	Every check used to contend on a single SharedTable's "write" counter, which
	serialises parallel flag writers under load. Violations are now spread across
	QUEUE_SHARDS independent queues, selected deterministically from the check name, so
	flags from different checks rarely touch the same atomic counter. Shard 1 keeps the
	documented "NanoAC_Queue" name; the rest are "NanoAC_Queue_<i>".

	A queue is a growable array addressed by two numeric cursors. SharedTable.increment
	requires the key to already exist and be numeric, so seed them if they are absent.
]]
local QUEUE_SHARDS = 8
NanoShared.QUEUE_SHARDS = QUEUE_SHARDS
NanoShared.queues = {}
NanoShared.queues[1] = SharedTableRegistry:GetSharedTable(NanoShared.NAMES.QUEUE)
for i = 2, QUEUE_SHARDS do
	NanoShared.queues[i] = SharedTableRegistry:GetSharedTable(NanoShared.NAMES.QUEUE .. "_" .. i)
end
for i = 1, QUEUE_SHARDS do
	local q = NanoShared.queues[i]
	if q["write"] == nil then q["write"] = 0 end
	if q["read"] == nil then q["read"] = 0 end
end
-- Backwards-compatible alias for the primary shard.
NanoShared.queue = NanoShared.queues[1]

-- Seed the roster-event log runCheck uses to track joins/leaves incrementally.
if NanoShared.rosterEvents["write"] == nil then NanoShared.rosterEvents["write"] = 0 end
if NanoShared.rosterEvents["first"] == nil then NanoShared.rosterEvents["first"] = 1 end
NanoShared.ROSTER_EVENT_WINDOW = 8192

--[[
	Config snapshot  (perf fixes 1, 3, 4).

	Reading config out of the SharedTable every frame for every check is pure overhead.
	The Coordinator publishes the whole (flat) config as a single nested SharedTable
	(CONFIG.snapshot) in one batched write and bumps CONFIG.revision. Each check Actor
	keeps a plain Luau copy of that snapshot and answers cfg()/cfgList() from it.

	Parallel threads cannot connect to signals, so rather than polling the revision on
	every Nth call (perf fix 1) we refresh on a lightweight timer task. cfg() is then a
	pure table lookup with no shared access on the hot path.
]]
local cfgCache = {}
local cfgBuilt = false
local cfgRevision = nil

-- Rebuild the local snapshot from CONFIG.snapshot when the revision changes.
function NanoShared.syncConfig()
	local rev = NanoShared.config.revision
	if cfgBuilt and rev == cfgRevision then
		return
	end
	local snapshot = {}
	local src = NanoShared.config.snapshot
	if typeof(src) == "SharedTable" then
		for k, v in src do
			snapshot[k] = v
		end
	end
	cfgCache = snapshot
	cfgRevision = rev
	cfgBuilt = true
end

-- Periodic refresh: one revision read per interval per Actor, replacing the per-call
-- call-count polling. A config republish propagates within CFG_SYNC_INTERVAL.
local CFG_SYNC_INTERVAL = 0.5
if not NanoShared._configSyncing then
	NanoShared._configSyncing = true
	task.spawn(function()
		while true do
			NanoShared.syncConfig()
			task.wait(CFG_SYNC_INTERVAL)
		end
	end)
end

-- Pure local lookup. A miss triggers one refresh so a check that loaded before the
-- Coordinator still picks values up; afterwards it is answered from the plain table.
function NanoShared.cfg(key, default)
	local v = cfgCache[key]
	if v ~= nil then
		return v
	end
	NanoShared.syncConfig()
	v = cfgCache[key]
	if v == nil then
		return default
	end
	return v
end

--[[
	Comma-list config  (perf fix 3).

	The Coordinator pre-parses the raw delimited strings at publish time into
	"<key>List" SharedTable arrays, so the check Actors never run gmatch/match on them.
	The converted Luau array is memoised per published list (and the string form remains
	a fallback for compatibility).
]]
local cfgListCache = {}   -- [key] = { src = any, parsed = {string} }

local function copySharedList(st)
	local out = {}
	local n = SharedTable.size(st)
	for i = 1, n do
		out[i] = st[i]
	end
	return out
end

function NanoShared.cfgList(key, default)
	-- Prefer the pre-parsed array published as "<key>List".
	local pre = NanoShared.cfg(key .. "List", nil)
	if typeof(pre) == "SharedTable" then
		local cached = cfgListCache[key]
		if cached ~= nil and cached.src == pre then
			return cached.parsed
		end
		local parsed = copySharedList(pre)
		cfgListCache[key] = { src = pre, parsed = parsed }
		return parsed
	end

	-- Fallback: parse the raw string once and memoise it.
	local v = NanoShared.cfg(key, nil)
	if type(v) == "string" then
		local raw = v :: string
		local cached = cfgListCache[key]
		if cached ~= nil and cached.src == raw then
			return cached.parsed
		end
		local out = {}
		for item in string.gmatch(raw, "[^,]+") do
			local trimmed = string.match(item, "^%s*(.-)%s*$")
			if trimmed ~= "" then
				out[#out + 1] = trimmed
			end
		end
		cfgListCache[key] = { src = raw, parsed = out }
		return out
	end
	if type(v) == "table" then
		return v
	end
	return default or {}
end

-- ---- Generic cross-thread queues ------------------------------------------------
-- A named queue is a SharedTable shaped { write:number, read:number, [i] = SharedTable }.
-- Returns (queue, indexWrittenTo). Safe to call from parallel contexts.
function NanoShared.pushQueue(queue, payload)
	local old = SharedTable.increment(queue, "write", 1)
	local index = old + 1
	queue[index] = SharedTable.new(payload)
	return index
end

-- Deterministic shard for a check name (perf fix 6). Cached because every check emits
-- hundreds of times with the same constant name.
local shardCache = {}
local function shardFor(checkName)
	local s = shardCache[checkName]
	if s ~= nil then
		return s
	end
	-- Small bit32 mixer (FNV offset basis + xor-shift) so the fixed check names spread
	-- evenly across shards without any large-number precision loss.
	local h = 2166136261
	for i = 1, #checkName do
		h = bit32.bxor(h, string.byte(checkName, i))
		h = bit32.band(h + bit32.lshift(h, 5), 0xFFFFFFFF)
		h = bit32.bxor(h, bit32.rshift(h, 4))
	end
	s = 1 + (h % QUEUE_SHARDS)
	shardCache[checkName] = s
	return s
end

-- Push a confirmed violation onto the shared queue. Safe to call in parallel.
-- Returns the slot index it wrote to.
function NanoShared.pushViolation(userId, checkName, magnitude, detail)
	if checkName == nil then checkName = "Check" end
	local queue = NanoShared.queues[shardFor(checkName)]
	local old = SharedTable.increment(queue, "write", 1)
	local index = old + 1
	queue[index] = SharedTable.new({
		userId = userId,
		check = checkName,
		magnitude = magnitude or 0,
		detail = detail or "",
	})
	return index
end

-- Canonical flag API used by every check. pushViolation is kept as an alias.
NanoShared.flag = NanoShared.pushViolation

--[[
	Exemption checks.

	Every movement/death flag here is only ever published by the Coordinator's sample(),
	so the Coordinator can precompute them as one aggregate (state.exemptMove / .exemptGrace)
	and a check pays a single shared read instead of up to nine. The whitelist flag and the
	grace windows, however, are also written asynchronously (ExemptTeleport, seat changes,
	setbacks, the whitelist API), so those are still read live to keep the exact
	same-frame behaviour. `now` is the caller's sample time.

	The individual checks remain the fallback for any state table that predates the
	aggregate fields.
]]
function NanoShared.isExempt(state, now)
	if state == nil then return true end

	local aggregate = state.exemptMove
	if aggregate == true then return true end

	-- Live values that can change between samples.
	if state.whitelisted == true then return true end
	local grace = state.graceUntil
	if grace ~= nil and now < grace then return true end
	local exempt = state.exemptUntil
	if exempt ~= nil and now < exempt then return true end

	-- With an aggregate present, the movement flags are authoritative (sample-only).
	if aggregate ~= nil then
		return false
	end

	-- No aggregate: fall back to the full original evaluation.
	if state.dead == true then return true end
	if state.seated == true then return true end
	if state.swim == true then return true end
	if state.climb == true then return true end
	if state.platform == true then return true end
	if state.phys == true then return true end
	return false
end

-- Stricter variant that ignores the *movement* exemptions (swim/climb/seat/platform)
-- but still honours death, whitelist and grace windows. Used by the property/state
-- guards (HumanoidGuard, StateGuard, NoclipGuard, PhysicsGuard, ...) which must still
-- run while a player is seated/swimming. Aggregated as state.exemptGrace (see above).
function NanoShared.isGrace(state, now)
	if state == nil then return true end

	local aggregate = state.exemptGrace
	if aggregate == true then return true end

	-- Live values that can change between samples.
	if state.whitelisted == true then return true end
	local grace = state.graceUntil
	if grace ~= nil and now < grace then return true end
	local exempt = state.exemptUntil
	if exempt ~= nil and now < exempt then return true end

	-- The aggregate is authoritative for the sample-only death flags.
	if aggregate ~= nil then
		return false
	end
	if state.dead == true then return true end
	if state.alive == false then return true end
	return false
end

-- Clamp helper used by the sustained checks.
function NanoShared.clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

--[[
	runCheck -- boilerplate-free parallel check runner.

	New checks pass closures instead of copy-pasting the roster loop + pcall + disable
	guard. The callbacks run inside the parallel phase; they must only touch SharedTables
	and pure values (never the DataModel).

	  NanoShared.runCheck({
	     check       = "HumanoidGuard",
	     enabledKey  = "humanoidEnabled",
	     process     = function(state, userId, t) ... end,
	     reset       = function(userId) ... end,   -- optional, on death/despawn
	     serial      = true,                        -- optional, run in serial phase
	  })
]]
function NanoShared.runCheck(opts)
	local check = opts.check or "Check"
	local enabledKey = opts.enabledKey
	local process = opts.process
	local reset = opts.reset
	local disabled = false
	local errors = 0
	local lastErrLog = 0

	--[[
		Roster snapshot  (perf fix 2).

		Iterating the roster SharedTable costs a locked shared read per element every tick,
		so each check keeps a plain Luau array of (userId, state) pairs and iterates that.
		Join/leave are applied incrementally from the Coordinator's roster-event log
		(ROSTER_EVENTS) instead of rebuilding the whole array O(n) on every membership
		change. An index map keeps add/remove O(1). If a check falls behind the retained
		event window (e.g. it was disabled for a while) it does one authoritative rebuild.
	]]
	local snapshot = {}        -- [i] = state
	local snapshotIds = {}     -- [i] = userId
	local snapshotIndex = {}   -- [userId] = i
	local snapshotCount = 0
	local eventRead = 0

	local function addEntry(userId, state)
		local n = snapshotCount + 1
		snapshot[n] = state
		snapshotIds[n] = userId
		snapshotIndex[userId] = n
		snapshotCount = n
	end

	local function removeEntry(userId)
		local slot = snapshotIndex[userId]
		if slot == nil then
			return
		end
		local last = snapshotCount
		if slot ~= last then
			local movedState = snapshot[last]
			local movedId = snapshotIds[last]
			snapshot[slot] = movedState
			snapshotIds[slot] = movedId
			snapshotIndex[movedId] = slot
		end
		snapshot[last] = nil
		snapshotIds[last] = nil
		snapshotIndex[userId] = nil
		snapshotCount = last - 1
	end

	local function fullRebuild()
		local events = NanoShared.rosterEvents
		-- Read the write cursor before iterating so a join racing this rebuild is
		-- picked up from its event on the next tick rather than being skipped.
		local writeAtStart = events["write"] or 0
		for i = 1, snapshotCount do
			local id = snapshotIds[i]
			if id ~= nil then
				snapshotIndex[id] = nil
			end
			snapshot[i] = nil
			snapshotIds[i] = nil
		end
		snapshotCount = 0
		local n = 0
		for userId, state in NanoShared.roster do
			n += 1
			snapshot[n] = state
			snapshotIds[n] = userId
			snapshotIndex[userId] = n
		end
		snapshotCount = n
		eventRead = writeAtStart
	end

	local function applyRosterEvents()
		local events = NanoShared.rosterEvents
		local write = events["write"] or 0
		local first = events["first"] or 1
		if eventRead + 1 < first then
			-- Fell behind the retained window: one authoritative rebuild.
			fullRebuild()
			return
		end
		if write <= eventRead then
			return
		end
		for i = eventRead + 1, write do
			local ev = events[i]
			if ev ~= nil then
				local userId = ev.userId
				if ev.add == true then
					if snapshotIndex[userId] == nil then
						local state = NanoShared.roster[userId]
						if state ~= nil then
							addEntry(userId, state)
						end
					end
				else
					removeEntry(userId)
				end
			end
		end
		eventRead = write
	end

	-- Defined once (not per tick) so the frame path allocates no closures.
	local function runRoster()
		for i = 1, snapshotCount do
			local state = snapshot[i]
			local t = state.time
			if t ~= nil and t > 0 then
				if state.dead == true or state.alive == false then
					if reset ~= nil then reset(snapshotIds[i]) end
				else
					process(state, snapshotIds[i], t)
				end
			end
		end
	end

	-- MicroProfiler label (perf instrumentation): open the MicroProfiler in Studio to see
	-- each check's parallel cost and any SharedTable stalls under peak player load.
	local profileLabel = "NanoAC-R " .. check

	local function tick()
		if disabled then return end
		if NanoShared.cfg("paused", false) then return end
		if enabledKey ~= nil and NanoShared.cfg(enabledKey, true) == false then return end

		applyRosterEvents()

		debug.profilebegin(profileLabel)
		local ok, err = pcall(runRoster)
		debug.profileend()

		if not ok then
			errors += 1
			if os.clock() - lastErrLog > 5 then
				warn(string.format("[NanoAC-R] %s error: %s", check, tostring(err)))
				lastErrLog = os.clock()
			end
			if errors >= 10 then
				disabled = true
				warn(string.format("[NanoAC-R] %s check disabled after repeated errors.", check))
			end
		end
	end

	if opts.serial then
		RunService.PreSimulation:Connect(tick)
	else
		RunService.PreSimulation:ConnectParallel(tick)
	end
end

return NanoShared
