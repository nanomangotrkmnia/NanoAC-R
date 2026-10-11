# NanoAC-R

A complete, server-authoritative anticheat for Roblox, inspired by **GrimAC** but rewritten
from scratch for Roblox's engine. It is written in Luau and built around **Parallel Luau**:
every check runs off the main thread inside its own `Actor`, and the only script that ever
touches the DataModel is the `Coordinator`.

> A missed cheat is preferable to punishing a legit player. Every threshold is scaled by ping
> and elapsed time, every confirmation is required to persist across multiple samples, and if a
> check is ever uncertain it stays silent.

It covers movement, flight, humanoid/property tampering, physics, health, combat, network and
tool traffic, plus a `BanManager` (strikes -> warn/kick, decay, whitelist, rejoin ban).

---

## 1. Actor hierarchy

Everything lives under `ServerScriptService`:

```
ServerScriptService
└─ NanoAC-R                            (Actor)
   ├─ NanoShared                       (ModuleScript)  serial communication layer + runCheck
   ├─ ExemptTeleport                   (BindableFunction) teleport whitelist API
   ├─ ReportHit                        (BindableFunction) combat API (attacker, victim)
   ├─ ReportKnockback                  (BindableFunction) combat API (victim, velocity)
   ├─ ReportShot                       (BindableFunction) shot-rate API (player, weapon)
   ├─ ReportHeal                       (BindableFunction) heal-credit API (player, amount)
   ├─ BanManager                       (BindableFunction) strike/whitelist/unban API
   ├─ Core        (Folder)
   │  └─ Coordinator                   (Actor) → Coordinator (Script)  <- serial (the only DM writer)
   ├─ Movement    (Folder)
   │  ├─ PhaseA                        (Actor) → PhaseA    (Script)  <- through-wall raycast
   │  ├─ PhaseB                        (Actor) → PhaseB    (Script)  <- collision off / NoCollisionConstraint
   │  ├─ MovementA                     (Actor) → MovementA (Script)  <- CFrame-walk / no-velocity
   │  ├─ MovementB                     (Actor) → MovementB (Script)  <- speed / sustained
   │  ├─ Timer                         (Actor) → Timer     (Script)  <- sustained game speed
   │  ├─ Teleport                      (Actor) → Teleport  (Script)
   │  ├─ Step                          (Actor) → Step      (Script)  <- instant step-up
   │  └─ Spider                        (Actor) → Spider    (Script)  <- wall climb
   ├─ Flight      (Folder)
   │  ├─ FlightA                       (Actor) → FlightA   (Script)  <- up (high-jump)
   │  ├─ FlightB                       (Actor) → FlightB   (Script)  <- hover / float
   │  ├─ FlightC                       (Actor) → FlightC   (Script)  <- controlled fall
   │  ├─ FlightD                       (Actor) → FlightD   (Script)  <- air-jump / mid-air rise
   │  ├─ FlightE                       (Actor) → FlightE  (Script)  <- PlatformStand fly/hover
   │  └─ FlightF                       (Actor) → FlightF  (Script)  <- swim-in-air
   ├─ Player      (Folder)
   │  ├─ HumanoidGuard                 (Actor) → Script   <- WalkSpeed/Jump/Hip/Slope tamper
   │  ├─ StateGuard                    (Actor) → Script   <- Flying/StrafingNoPhysics, fake sit
   │  ├─ IntegrityGuard                (Actor) → Script   <- Dead/Freefall disabled, extra Humanoids
   │  ├─ UnexpectedMoveA               (Actor) → Script   <- injected movers / forces
   │  ├─ HealthGuard                   (Actor) → Script   <- MaxHealth tamper / heal bursts
   │  └─ HitboxGuard                   (Actor) → Script   <- inflated limbs / accessories
   ├─ Combat      (Folder)
   │  ├─ ThroughWall                   (Actor) → Script   <- hit through walls (LOS)
   │  ├─ Velocity                      (Actor) → Script   <- anti-knockback
   │  ├─ Hit                           (Actor) → Script   <- reach / hit spam / kill aura
   │  ├─ Fling                         (Actor) → Script   <- extreme angular/linear velocity
   │  └─ FireRate                      (Actor) → Script   <- shot rate limits
   └─ Network     (Folder)
      ├─ RemoteGuard                   (Actor) → Script   <- RemoteEvent spam / oversized payloads
      ├─ ToolGuard                     (Actor) → Script   <- tool equip / activate spam
      └─ ExploitGuard                  (Actor) → Script   <- suspicious remote names
```

Each check is one `Actor` containing one `Script` inside a category Folder (folders do not
affect parallelism — only the nearest ancestor `Actor` matters). `Player/` and `Network/` are
plain Folders; every leaf check folder carries `{"className":"Actor"}`.

`ReplicatedStorage` gets a `NanoAC_AlertEvent` (RemoteEvent), and
`StarterPlayer.StarterPlayerScripts` gets a `NanoAC_AlertClient` (LocalScript) that renders the
alerts in chat. Both are created/installed automatically; the Coordinator also creates the
remote and every bindable at runtime if they are missing.

**Adding a new check = adding one new child `Actor` containing one `Script`** that reads the
shared roster/config and pushes to the shared queue (see `NanoShared.runCheck`).

---

## 2. Threading model

| Concern | Owner |
| --- | --- |
| DataModel writes (setbacks, alerts, lifecycle, scans) | `Coordinator` — **serial only** |
| Per-player shared state (position, health, flags, baselines, limits) | `Coordinator` writes, checks read |
| Per-frame maths (prediction, raycasts, rolling windows) | check scripts — **parallel** |
| Confirmed violations | checks push into a `SharedTable` queue |
| Violation levels, decay, alerts, setbacks, strikes | `Coordinator` drains the queue each frame |
| Network / tool hooks | `Network/*` serial sensors (also push to the shared queue) |

* Regular Lua tables **cannot** be shared between parallel contexts. Cross-thread state lives in
  `SharedTable`s obtained from `SharedTableRegistry`.
* `NanoShared` (the module) is required in a **serial** context so it can cache service handles;
  its functions only touch `SharedTable`s / pure values, so they are safe to call in parallel.
* Pure-data checks use `RunService.PreSimulation:ConnectParallel` (usually via
  `NanoShared.runCheck`). `Phase(A)` and `Spider` use `PreSimulation:Connect` + `task.desynchronize()`
  because building a `RaycastParams` exclusion list is not allowed in parallel.
* Every check wraps its tick in `pcall`. On error it logs (throttled) and, after 10 errors,
  disables **only itself** — every other check keeps running.

### Shared tables (created via `SharedTableRegistry`)

| Name | Shape |
| --- | --- |
| `NanoAC_Roster` | `userId -> playerState` (a nested SharedTable) |
| `NanoAC_Queue` | `{ write:number, read:number, [i] = {userId, check, magnitude, detail} }` |
| `NanoAC_Config` | flat `string -> number/boolean/string` mirror of the Settings table |
| `NanoAC_Hits` / `NanoAC_HitGuard` | per-hit records (LOS / reach+rate respectively) |
| `NanoAC_Knockbacks` | reported knockbacks |
| `NanoAC_Shots` | reported shots (FireRate) |
| `NanoAC_Heals` | reported heals (HealthGuard credit) |

`playerState` keys include: `userId, name, pos (Vector3), time, dt, ping, walkSpeed, jumpPower,
jumpHeight, maxSlopeAngle, hipHeight, grounded, stateName, swim, climb, seated, platform, phys,
dead, freefall, jumping, vy, pvy, airborne, wasAirborne, alive, graceUntil, exemptUntil,
lastValidPos (Vector3), lastValidYaw, lastValidTime, setbackCount`, plus the extended fields:
`health, maxHealth, walkBase, jumpBase, jumpHeightBase, hipBase, slopeBase, healthBase,
maxHealthBase, hitbox, hitboxBase, accessory, accessoryBase, hrpCanCollide, limbNoCollide,
noCollision, platformStand, flying, flyingEnabled(+Base), deadDisabled(+Base),
freefallDisabled(+Base), strafingNoPhysics, sitNoSeat, swimInAir, humanoidCount, physCount,
vel (Vector3), angVel (Vector3), angSpeed, whitelisted, strikes`.
Only SharedTable-compatible types are stored (numbers, booleans, strings, `Vector3`, nested
SharedTables); CFrames are stored as a position + a yaw scalar.

Because `SharedTable.increment` requires a pre-existing numeric key, the Coordinator seeds every
queue's `write`/`read` to `0` at load, and drains them each frame.

---

## 3. Movement & flight checks

### Phase(A) (through-wall) — `Movement/PhaseA`
Casts a ray from the last safe position to the current position and a second ray backwards. When
both hit the **same** obstacle, the thickness crossed is `len - forwardDistance - backDistance`;
a positive thickness that is a meaningful fraction of the segment means the path went fully
through the wall. Ignores thin/steppable, non-collidable, invisible parts, other characters and
water; ignores corner clipping; defers to Movement(B)/Teleport when the player moved fast enough to
tunnel legitimately.

### Phase(B) (collision) — `Movement/PhaseB`
Flags a character whose collision has been removed: `HumanoidRootPart.CanCollide == false`, an
HRP-parented `NoCollisionConstraint` (the modern rig's accessory `NoCollisionConstraint`s live on
limbs and are ignored), or a body limb with `CanCollide == false`. This is the collision-off side
of phasing that `Phase(A)` (which catches actually passing **through** geometry) does not see.

### Movement(A) (CFrame-walk) — `Movement/MovementA`
Compares windowed displacement against the integral of `AssemblyLinearVelocity`. A client that
writes its CFrame directly (or suppresses velocity while noclip-drifting) moves far more than its
real velocity explains, even if the displacement stays under the WalkSpeed baseline — so this
catches the movement that Movement(B) alone cannot see. Ping-scaled, streaked, exempts states.

### Movement(B) (speed) — `Movement/MovementB`
Horizontal displacement / `dt` versus `WalkSpeed * MaxMultiplier + ping allowance`, confirmed by
a rolling average and a consecutive-sample streak. Exempts unsupported movement states and grace
windows.

### Vertical motion — `Flight/FlightA` (up) / `FlightB` (hover) / `FlightC` (controlled fall) / `FlightD` (air-jump)
* **Ascend**: while airborne, flags gaining altitude beyond a legitimate jump. Uses a windowed
  average climb rate over `GainWindow` (not a single-frame `dy/dt`), and flags when the average
  upward rate exceeds `jumpPower * MaxMultiplier` or the windowed climb exceeds
  `maxJumpHeight * GainMultiplier` (`maxJumpHeight` derives from `jumpPower` and gravity).
* **Glide**: airborne while barely falling (`|vy| < MaxDescent`) for `MinAirTime`.
* **Descend**: falling far slower than gravity allows (below `ExpectedRatio` of `gravity *
  fallTime`).
* **Air-jump**: airborne well past takeoff while still rising (keys off the *sign* of vy).

A legitimate launcher (jump pad, cannon) can be whitelisted with the `ExemptTeleport` API.

### Flight(E) (PlatformStand) — `Flight/FlightE`
PlatformStand flight: flags a PlatformStand + airborne body that hovers (`|vy| < MaxDescent` for
`MinAirTime`) or ascends faster than `MinAscent`. Ragdoll/physics states are skipped.

### Flight(F) (swim-in-air) — `Flight/FlightF`
Flags the `Swimming` state while `FloorMaterial ~= Water` for `MinTime`. Kept separate from
Flight(E) so each mode owns one concern.

### Timer (sustained game speed) — `Movement/Timer`
Rolling window of horizontal distance vs real elapsed time; flags only when the *sustained* rate
exceeds `WalkSpeed * AllowedRatio` once the window is full.

### Teleport — `Movement/Teleport`
Single-sample displacement against the maximum possible travel over the elapsed time (WalkSpeed
horizontal / JumpPower up / terminal velocity down + ping slack). A hard overrun flags
immediately; smaller ones must persist. Respawns, spawns, seat entry/exit and whitelisted game
teleports are covered by the shared `exemptUntil` window.

### Step — `Movement/Step`
Flags being lifted vertically while **grounded** by more than `MaxStep` (2.75 studs) in one frame.
Stairs/ramps produce small gains and jumps leave the ground, so neither false-flags.

### Spider — `Movement/Spider`
Flags climbing a vertical wall without a ladder. Hybrid threading: serial prep builds the raycast
exclusion, then four horizontal probes look for a nearby solid wall while airborne with upward
speed, sustained for `MinSustain`. Ladders set the Climbing state, which exempts.

---

## 4. State, property & integrity checks

### HumanoidGuard — `Player/HumanoidGuard`
Flags WalkSpeed / JumpPower / JumpHeight / HipHeight / MaxSlopeAngle that drifted from the
per-character **spawn baseline** beyond tolerance. Games that change these should set them before
the baseline is captured or whitelist the player.

### StateGuard — `Player/StateGuard`
Flags the Flying / StrafingNoPhysics states and a seatless fake `Sit` (`Sit` with no `SeatPart`,
persisted `SitGrace`).

### IntegrityGuard — `Player/IntegrityGuard`
Flags Dead/Freefall state disabled, Flying enabled (both **baseline-relative**, so engine defaults
never false-flag) and extra Humanoids in the character.

### UnexpectedMove(A) — `Player/UnexpectedMoveA`
Flags injected body movers / forces / constraints (`BodyVelocity`, `LinearVelocity`,
`VectorForce`, `LineForce`, ...). The R15 rig's `BallSocketConstraint` / `AnimationConstraint` /
`RigidConstraint` joints are excluded. Tag legitimate instances with `NanoAC_Legit` or add the
name to `Checks["UnexpectedMove(A)"].IgnoreNames`.

### HealthGuard — `Player/HealthGuard`
Flags MaxHealth changed from baseline, Health above MaxHealth, and illegal heal bursts (a
single-sample gain above `HealBurst` beyond the decaying `ReportHeal` credit).

### HitboxGuard — `Player/HitboxGuard`
Flags limbs / HRP / accessory handles grown beyond the spawn baseline (`GrowthRatio` /
`GrowthTolerance`).

### FlingGuard — `Combat/Fling`
Flags extreme `AssemblyAngularVelocity` (rad/s) or `AssemblyLinearVelocity` on the root, with a
streak so a momentarily-flung victim is not flagged.

---

## 5. Combat checks

### ThroughWall — `Combat/ThroughWall`
Validates melee line-of-sight. `ReportHit` records attacker/victim positions; a ray between them
(start/end offsets avoid their bodies) flags the attacker if a solid, collidable, non-character
part blocks the path.

### Velocity — `Combat/Velocity`
Anti-knockback. `ReportKnockback` records the intended velocity + victim position; the check
measures the victim's real sampled speed over `Window`. If it never reaches `Ratio` of the
intended knockback — and no wall sits within `Room` studs in that direction — the client
suppressed it -> flag.

### Hit — `Combat/Hit`
Reach (distance beyond `Reach` + ping cushion), hit spam (`MaxHitsPerSecond`) and kill aura
(more than `AuraTargets` distinct victims within `AuraWindow`). Fed by `ReportHit`; LOS stays in
ThroughWall.

### FireRate — `Combat/FireRate`
Shot-rate limit over `Window`, fed by the `ReportShot(player, weapon)` API.

---

## 6. Network sensors

Serial sensor scripts that hook the DataModel directly (they do not desynchronise) and push to
the shared queue.

### RemoteGuard — `Network/RemoteGuard`
Hooks every `RemoteEvent.OnServerEvent` and flags global spam (`MaxPerSecond`), per-remote spam
(`MaxPerRemotePerSecond`) and oversized payloads (`MaxPayload`, `MaxArgs`). `RemoteFunction`s
cannot be hooked safely (single `OnServerInvoke`) and are left alone.

### ToolGuard — `Network/ToolGuard`
Auto-hooks every Tool that enters a character and flags equip / activate spam. Nothing needs to
be registered by the game.

### ExploitGuard — `Network/ExploitGuard`
Flags invocations of suspiciously-named remotes (`Checks.Exploit.Patterns`, comma-separated,
case-insensitive substring). Tune the patterns for your game.

---

## 7. Reporting & management APIs

```lua
local nano = game.ServerScriptService["NanoAC-R"]

nano.ReportHit:Invoke(attackerPlayer, victimPlayer)                 -- after you resolve a hit
nano.ReportKnockback:Invoke(victimPlayer, knockbackVelocityVector)  -- when you apply knockback
nano.ReportShot:Invoke(player, weapon)                              -- per resolved shot
nano.ReportHeal:Invoke(player, amount)                              -- credit a legitimate heal
nano.ExemptTeleport:Invoke(player, optionalSeconds)                 -- whitelist a real teleport

nano.BanManager:Invoke("strike", player, reason)                    -- add a strike manually
nano.BanManager:Invoke("whitelist", player)                         -- never flag this player
nano.BanManager:Invoke("unban", userId)                             -- clear a rejoin ban
nano.BanManager:Invoke("isWhitelisted", player)                     -- -> boolean
nano.BanManager:Invoke("isBanned", playerOrUserId)                  -- -> boolean
```

All are server-side `BindableFunction`s that capture state and enqueue the event; the checks
validate from the parallel phase. Without the reporting calls the combat/rate checks stay idle.

---

## 8. Violations, alerts, setbacks & bans (Coordinator, serial)

* Every confirmed violation increments that check's **VL**, which decays continuously at
  `VL.DecayPerSecond`.
* When a check flags and the setback cooldown has elapsed:
  1. A chat alert is sent (staff-only by default) in the exact format
     `<username> failed <Check> VL:<times> Times` (e.g. `Builderman failed Movement(B) VL:5 Times`).
  2. A **setback** teleports the player to the last verified safe, supported CFrame and zeroes
     their linear and angular velocity, then arms a cooldown + grace window so setbacks cannot
     loop. By default `Setback.OnEveryFlag = true`, so **any** flag sets the player back (bounded
     by `Setback.Cooldown`); set it to `false` to only setback on VL-threshold crossings.
* **BanManager**: each threshold crossing also adds a strike. Strikes decay at
  `BanManager.StrikeDecayPerSecond`; at `WarnAt` the player is warned, at `KickAt` they are
  kicked and (optionally persisted to a DataStore) temporarily rejoin-banned for
  `BanDuration`. Whitelisted players (`BanManager("whitelist", ...)` / the
  `NanoAC_Whitelisted` attribute / `WhitelistIds`) are never flagged or struck.

### Staff detection
A player counts as staff if any of these is true: they carry the configured attribute
(`NanoAC_Staff`), their `UserId` is in `Alerts.StaffUserIds`, or their rank in
`Alerts.StaffGroupId` is `>= Alerts.MinGroupRank`. Set `Alerts.StaffOnly = false` to show alerts
to everyone in chat.

---

## 9. Settings

All tuning lives in the `Settings` table at the top of `Coordinator.Coordinator`. It is the
single source of truth; the Coordinator mirrors every scalar value into the `NanoAC_Config`
SharedTable (and string lists such as `Exploit.Patterns` / `UnexpectedMove(A).IgnoreNames`), which the
checks read from parallel threads.

| Section | What it controls |
| --- | --- |
| `Enabled` / `Debug` / `ScanInterval` | master switch; debug console output; throttled character-scan period |
| `Alerts` | on/off, staff-only, colour, staff ids/group/attribute |
| `Verbose` | whether players may `/verbose` (off by default) |
| `Grace` | spawn / teleport / setback / seat grace windows (seconds) |
| `VL` | per-second decay, alert display cap |
| `Setback` | enable, cooldown, on-every-flag, freeze-safe-spot |
| `Punish` | legacy kick-after-N-setbacks hook |
| `BanManager` | warn/kick thresholds, strike decay, whitelist, persistence, rejoin-ban duration |
| `Checks.<Name>` | per-check `Enabled`, `VLThreshold`, `RequiredStreak`, `EmitCooldown` and check-specific tolerances |

Checks read thresholds with `Shared.cfg("key", default)`, so even if the Coordinator is edited,
the checks fall back to sane defaults.

---

## 10. Verified behaviour

Tested in Studio (Play Solo) on this place:

* The Coordinator samples every `PostSimulation`, publishes the roster/config, and drains every
  queue each frame — no `[NanoAC-R] ... error` lines.
* Idle at spawn and real engine-driven **walking + jumping produced zero** flags
  (`queue.write` stayed at 0/40 while the character moved ~126 studs).
* Tamper tests each produced flags: Humanoid (WalkSpeed/JumpPower), Phase(B) (HRP collision),
  Hitbox (HRP/limb growth), Health (MaxHealth, heal burst; a **reported** heal is credited and
  does **not** flag), Integrity (Dead disabled, extra Humanoid), UnexpectedMove(A) (LinearVelocity),
  State (seatless sit), Flight(E) (PlatformStand hover + ascent), Flight(F) (synthetic swim-in-air),
  Fling (sustained angular velocity), Movement(A) (CFrame-walk), Movement(B) (speed), Hit spam, FireRate, RemoteGuard
  (spam + oversized), ExploitGuard (suspicious name), ToolGuard (equip spam).
* `BanManager("whitelist", player)` suppressed a subsequent tamper entirely; a single flag
  produced one setback (`setbackCount 0 -> 1`).

---

## 11. Shipping state (test affordances)

The test/debug affordances are **off** in this build:

| Item | State |
| --- | --- |
| `Debug` | `false` (verbose server console output off) |
| `Alerts.EveryoneIsStaff` | `false` (alerts go to staff only) |
| `Verbose.AllowSelfToggle` | `false` (`/verbose` inert) |
| `/velocity` test command | gated behind `Debug` (off) |
| client `/speed`, `/fly` hacks | **removed** |
| `Setback.OnEveryFlag` | `true` — every flag sets the player back (now the norm) |

`Workspace.NanoAC_TestMap` (a labelled test ground around `(200, 0, 0)`) is not part of the Rojo
project and can be deleted; it is a plain Folder of anchored parts.

---

## 12. Building & sharing (Rojo)

Sources live on disk in a Rojo project:

```
default.project.json      maps src/ into the DataModel
rokit.toml                toolchain pin (rojo)
src/server/NanoAC-R/      the Actor tree (Actor + BindableFunctions + Core/Movement/Flight/Player/Combat/Network)
src/client/               NanoAC_AlertClient.client.luau
```

Mapping notes:
- `src/server/NanoAC-R/init.meta.json` (`{"className":"Actor"}`) makes the folder an **Actor**.
- Each check folder has an `init.meta.json` Actor + `<Name>.server.luau` (the Script).
- `Player/` and `Network/` are plain Folders (no `init.meta.json`).
- `ExemptTeleport` / `ReportHit` / `ReportKnockback` / `ReportShot` / `ReportHeal` / `BanManager`
  are runtime `BindableFunction`s; `NanoAC_AlertEvent` (RemoteEvent) is created at runtime if
  missing, so no extra instances are needed.

Build / sync:
```bash
rokit install                 # or: cargo install rojo  / download the rojo binary
rojo serve                    # then connect with the Rojo Studio plugin and Sync
rojo build -o NanoAC-R.rbxlx  # produce a place file you can share
```

To install for someone: `rojo build` a place (or hand them the repo and have them `rojo serve`),
or export the `NanoAC-R` Actor to an `.rbxmx` and drop it in `ServerScriptService`.

Notes:
- **Defaults**: `Setback.OnEveryFlag = true`, `Setback.Cooldown = 0.5`, `Grace.AfterSetback = 0.25`,
  tighter Movement(A)/Movement(B)/Timer streaks (they accumulate across on/off toggles instead of resetting),
  `Alerts.EveryoneIsStaff = false`. Add your UserId to
  `Alerts.StaffUserIds` (or set the `NanoAC_Staff` attribute) to receive alerts.
