-- VGS Display for Assetto Corsa : telemetry
-- ---------------------------------------------------------------------------
-- Ported from the BeamNG version's vehicle script (vgsTelemetry.lua). Every graphics frame it
-- reads the focused car's state from Custom Shaders Patch and works out, for every wheel:
--   * where it sits on the car (captured once per car, in the car's own frame)
--   * its live steering angle, from the wheel's heading against the body
--   * how much of the tyre's grip is in use (AC's own normalised slip: 1 = at the peak) and
--     whether it's past the limit, and how far
--   * the torque through it (from its slip ratio): +1 full drive ... -1 full braking
--   * whether it's off the ground, or nearly, and whether ABS is working on it
-- plus the driver's inputs, the G-force, how much the car is actually turning (the direction
-- marker) and its understeer / oversteer balance.
--
-- It returns a "body" table in the same shape the BeamNG app's renderer drew from, so the
-- renderer (render.lua) is a straight port of app.js.
-- ---------------------------------------------------------------------------

local T = {}

-- ===== Tunables =============================================================
local TUNE = {}
T.TUNE = TUNE
-- Grip. AC reports each tyre's normalised slip (ndSlip): 1 at the peak of the tyre's curve,
-- above it past the peak. That's the grip bar, directly.
TUNE.SLIDE_ON         = 1.0   -- ndSlip above which a tyre counts as past its limit (pink/red)
TUNE.SLIDE_OFF        = 0.85  -- ... and below which it's gripping again (no flicker)
-- How red a sliding tyre is, from its slip ratio (contact-patch slip speed / road speed, here
-- from the slip ratio and the slip angle). Pink up to 30 %, deepening to a lock or spin at 100 %.
TUNE.SLIP_RATIO_PINK  = 0.30
TUNE.SLIP_RATIO_FULL  = 1.00
TUNE.PINK_SEVERITY    = 0.2   -- how far towards deep red the colour gets by the end of the pink band
TUNE.RATIO_MIN_SPEED  = 5.0   -- m/s; the slip ratio is scaled down below this (no wild values at a crawl)
TUNE.SR_PEAK          = 0.12  -- slip ratio drawn as full drive (green) or braking (red) on the outline
TUNE.SR_ABS           = 0.04  -- braking slip ratio from which a wheel gets the ABS dot while ABS works
TUNE.MIN_LOAD         = 150   -- N; below this a wheel has no grip ...
TUNE.AIR_SHOW_AFTER   = 0.25  -- s ... and is shown off the ground once it stays that way this long
TUNE.LIGHT_FRAC       = 0.25  -- a wheel carrying less than this share of its normal load is nearly off the ground
TUNE.LIGHT_HZ         = 2     -- smoothing of the load for that (a bump doesn't flash it)
TUNE.LIGHT_REF_TAU    = 2     -- s: how slowly the normal load is followed
TUNE.GRIP_SMOOTHING   = 0.4   -- share of the gap closed every 1/30 s (higher = snappier)
TUNE.STANDSTILL_SPEED = 0.5   -- m/s; below this the outline follows the brake pedal instead
-- G-force dot: least-squares slope of the velocity over GF_WINDOW, then a two-stage One Euro filter
TUNE.GF_WINDOW        = 0.10
TUNE.GF_MIN_CUTOFF    = 0.6
TUNE.GF_BETA          = 3
TUNE.GF_D_CUTOFF      = 0.5
TUNE.GF_STAGES        = 2
TUNE.GF_D_FLOOR       = 2
-- Direction marker
TUNE.TRAVEL_SMOOTH_HZ = 15
TUNE.YAW_SMOOTH_HZ    = 12
TUNE.MARK_YAW_HZ      = 10
TUNE.TRAVEL_FADE_LO   = 0.5
TUNE.TRAVEL_FADE_HI   = 1.5
TUNE.TRAVEL_MAX       = 4
TUNE.LOCK_DEFAULT     = 0.6
TUNE.CENTRE_INPUT     = 0.004
TUNE.CENTRE_TAU       = 3
TUNE.RATIO_TAU        = 1.0
TUNE.REAR_GRIP_SLIP   = 0.14
TUNE.REAR_SLIDE_SLIP  = 0.35
TUNE.STEER_EXPAND     = 20
TUNE.STEER_TARGET     = 0.6
TUNE.STEER_K_MAX      = 400
TUNE.MARK_MIN_CUTOFF  = 0.3
TUNE.MARK_BETA        = 0.005
TUNE.MARK_D_CUTOFF    = 0.5
TUNE.MARK_STEER_GAIN  = 0.06
TUNE.MARK_STEER_CUTOFF = 8
TUNE.MARK_FAST_FROM   = 180
TUNE.MARK_BETA2       = 0.002
TUNE.MARK_D_FAST_CUTOFF = 2
-- Balance: oversteer is the rear slipping more than the front (in the direction the car is
-- turning) with the rear near or past its limit
TUNE.BAL_DEADBAND     = 0.05
TUNE.BAL_FULL         = 0.21
TUNE.BAL_SLIP_START   = 0.08
TUNE.BAL_SLIP_FULL    = 0.14
TUNE.BAL_MIN_YAW      = 0.15
-- How near each axle is to its limit: its tyres' ndSlip, load-weighted (1 = at the peak)
TUNE.NEAR_ON          = 0.60  -- from here an axle is near its limit (the yellow warning) ...
TUNE.NEAR_OFF         = 0.50  -- ... and below this it's clear again
TUNE.PAST_ON          = 1.0   -- from here the front is past its peak (understeer, with the lead)
TUNE.LEAD             = 0.15  -- one axle this much nearer its limit than the other gets the warning
TUNE.WARN_HOLD        = 0.12  -- s an axle must stay near its limit before the warning shows
TUNE.GRIP_HZ          = 6     -- smoothing of each axle's ndSlip
TUNE.GRIP_MIN_SPEED   = 4     -- m/s: below this the limits aren't judged (fading in over 3 m/s)
TUNE.US_WARN_SHARE    = 0.35  -- must match UNDER_WARN in render.lua
TUNE.US_MIN_YAW       = 0.10
TUNE.DRIFT_STEER_OK   = 0.09
TUNE.DRIFT_STEER_OFF  = 0.26
TUNE.DRIFT_GROW_OK    = 0.35
TUNE.DRIFT_GROW_OFF   = 1.0
TUNE.DRIFT_MAX_ANGLE  = 1.57
TUNE.DRIFT_RATE_HZ    = 4
TUNE.PS_REAR_START    = 0.10
TUNE.PS_REAR_FULL     = 0.17
TUNE.PS_FRONT_START   = 0.035
TUNE.PS_FRONT_FULL    = 0.07
TUNE.PS_PLOUGH_START  = 0.09
TUNE.PS_PLOUGH_FULL   = 0.17
TUNE.PS_THROTTLE      = 0.2
-- Engine placement from the weight distribution (suspensions.ini CG_LOCATION, the front's share)
TUNE.MID_ENGINE_BELOW  = 0.47
TUNE.REAR_ENGINE_BELOW = 0.40

local G = 9.81
local pi = math.pi
local abs, sqrt, atan2, max, min, floor = math.abs, math.sqrt, math.atan2 or math.atan, math.max, math.min, math.floor

-- ===== Helpers ==============================================================
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function smoothstep(k) k = clamp(k, 0, 1) return k * k * (3 - 2 * k) end
local function wrapAngle(a)
  a = (a + pi) % (2 * pi)
  if a < 0 then a = a + 2 * pi end
  return a - pi
end
local function lpAlpha(cutoff, dt) return 1 / (1 + 1 / (2 * pi * cutoff * dt)) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function index(o, k) return o[k] end
-- an optional field: nil when this CSP version doesn't have it
local function get(o, k)
  local ok, v = pcall(index, o, k)
  if ok then return v end
  return nil
end
local function num(v, d) v = tonumber(v) if v == nil or v ~= v then return d end return v end
-- A pedal as a whole percent, 0 only for exactly 0 and 100 only for exactly full (like the
-- BeamNG version, so a deadzone or a pedal that never quite releases shows as a sliver).
local function pedalLevel(v)
  v = num(v, 0) * 100
  local pct = (v >= 100) and 100 or floor(v + (1 - 1e-7 - v / 100))
  return clamp(pct, 0, 100) / 100
end
T.clamp, T.smoothstep = clamp, smoothstep

-- Fixed-size history of samples (reused in place: no garbage per frame)
local function newRing(n)
  local r = { n = n, head = 0, count = 0, s = {} }
  for k = 1, n do r.s[k] = {} end
  return r
end
local function ringNext(r)
  r.head = r.head % r.n + 1
  if r.count < r.n then r.count = r.count + 1 end
  return r.s[r.head]
end

-- The steering scale (asinh(k x) / asinh(k)), shared with the renderer
local function asinhNorm(x, k) return math.log(k * x + sqrt(k * k * x * x + 1)) / math.log(k + sqrt(k * k + 1)) end
local function steerK(ref)
  local k0, target, kMax = TUNE.STEER_EXPAND, TUNE.STEER_TARGET, TUNE.STEER_K_MAX
  if not (target > 0) or not ref or not (ref > 0) or ref >= 1 then return k0 end
  if k0 > 0 and asinhNorm(ref, k0) >= target then return k0 end
  if asinhNorm(ref, kMax) <= target then return kMax end
  local lo, hi = math.log(max(k0, 1)), math.log(kMax)
  for _ = 1, 30 do
    local mid = (lo + hi) / 2
    if asinhNorm(ref, math.exp(mid)) < target then lo = mid else hi = mid end
  end
  return math.exp((lo + hi) / 2)
end
local function toScale(x, k)
  local a = abs(x)
  if not (k > 0) or a >= 1 then return x end
  return (x < 0 and -1 or 1) * asinhNorm(a, k)
end
local function fromScale(u, k)
  local a = abs(u)
  if not (k > 0) or a >= 1 then return u end
  local e = math.exp(a * math.log(k + sqrt(k * k + 1)))
  return (u < 0 and -1 or 1) * (e - 1 / e) / 2 / k
end
T.asinhNorm, T.steerK, T.toScale = asinhNorm, steerK, toScale

-- ===== State ================================================================
local lay, kin, est, mark, cal, ws, out, gm
local clock = 0

local function resetState()
  lay = nil
  clock = 0
  kin = { gx = 0, gy = 0, g1x = 0, g1y = 0, gdx = 0, gdy = 0, gInit = false, vring = newRing(64),
          yawRate = 0, yawFast = 0, yawSign = 1, yawCheck = 0, lastFwd = nil, lastLeft = nil,
          travel = 0, rearTravel = 0, speed = 0, lastPos = nil }
  est = { rn = 0, rd = 0, ratio = nil, lock = TUNE.LOCK_DEFAULT, balance = 0, frontSteer = nil, rearSteer = 0,
          slipF = nil, slipR = nil, drift = 0, slideRate = 0, prevSlide = nil, state = 0, cand = 0, candT = 0,
          ps = 0, psCtl = 0, psOn = false, psCtlOn = false, rs = 0, drvF = false, drvR = false }
  mark = { init = false, y = 0, d = 0, df = 0, ds = 0, s = 0 }
  gm = { pF = 0, pR = 0 }
  -- signs AC's values are learnt against (see calibrate()), kept per car
  cal = { steerVote = 0, steerSign = -1, lockSeen = 0, srVote = 0, srSign = 1 }
  ws = {}
  out = nil
end
resetState()

-- ===== Layout and drivetrain (once per car) =================================
local function iniData(carIndex, file)
  if not (ac.INIConfig and ac.INIConfig.carData) then return nil end
  local ok, cfg = pcall(ac.INIConfig.carData, carIndex, file)
  if ok then return cfg end
  return nil
end
local function iniGet(cfg, section, key)
  if not cfg then return nil end
  local ok, v = pcall(cfg.get, cfg, section, key, ac.INIConfig and ac.INIConfig.OptionalNumber or nil)
  if ok and type(v) == "number" then return v end
  if ok and type(v) == "table" and type(v[1]) == "number" then return v[1] end
  return nil
end
local function iniGetString(cfg, section, key)
  if not cfg then return nil end
  local ok, v = pcall(cfg.get, cfg, section, key, ac.INIConfig and ac.INIConfig.OptionalString or nil)
  if ok and type(v) == "string" then return v end
  if ok and type(v) == "table" and type(v[1]) == "string" then return v[1] end
  return nil
end

-- AC's differential: power and coast are the lock under drive and off throttle (1 = fully
-- locked), preload a constant locking torque (Nm). Locked: a spool; open: nothing locks it.
local function diffKind(power, coast, preload)
  if power == nil and coast == nil and preload == nil then return nil end
  power, coast, preload = power or 0, coast or 0, preload or 0
  if power >= 0.99 and coast >= 0.99 then return "locked" end
  if power <= 0.01 and coast <= 0.01 and preload <= 1 then return "open" end
  return "lsd"
end

local TRACTION = { [0] = "rwd", [1] = "fwd", [2] = "awd", [3] = "awd" }

-- Where the drivetrain's parts sit (metres: x right, y forward of the car's origin), and the
-- graph from the engine to the wheels, in the same node shape as the BeamNG app's.
local function buildDrivetrain(car, wheels, yF, yR, enginePref)
  local drv = get(car, "tractionType")
  local layout = TRACTION[tonumber(drv) or -1]
  local dIni = iniData(car.index, "drivetrain.ini")
  if not layout then
    local t = (iniGetString(dIni, "TRACTION", "TYPE") or ""):upper()
    layout = (t == "FWD" and "fwd") or ((t == "AWD" or t == "AWD2") and "awd") or "rwd"
  end
  local sIni = iniData(car.index, "suspensions.ini")
  local cg = iniGet(sIni, "BASIC", "CG_LOCATION")

  -- engine position: transverse at the front for front-wheel drive; otherwise from the weight
  -- distribution (or the player's choice in the settings)
  local where = enginePref
  if not where or where == "auto" then
    if layout == "fwd" then where = "transverse"
    elseif cg and cg < TUNE.REAR_ENGINE_BELOW then where = "rear"
    elseif cg and cg < TUNE.MID_ENGINE_BELOW then where = "mid"
    else where = "front" end
  end
  local ey, gy
  if where == "transverse" then ey, gy = yF + 0.05, yF - 0.45
  elseif where == "rear" then ey = yR - 0.35; gy = ey + 0.5
  elseif where == "mid" then ey = yR + 0.6; gy = ey - 0.5
  else ey = yF - 0.3; gy = ey - 0.5 end

  local main = diffKind(iniGet(dIni, "DIFFERENTIAL", "POWER"), iniGet(dIni, "DIFFERENTIAL", "COAST"), iniGet(dIni, "DIFFERENTIAL", "PRELOAD"))
  local function awdDiff(prefix)
    for _, sec in ipairs({ "AWD", "AWD2" }) do
      local k = diffKind(iniGet(dIni, sec, prefix .. "_DIFF_POWER"), iniGet(dIni, sec, prefix .. "_DIFF_COAST"), iniGet(dIni, sec, prefix .. "_DIFF_PRELOAD"))
      if k then return k end
    end
    return nil
  end

  local nodes = {}
  local function add(n) nodes[#nodes + 1] = n return #nodes end
  local src = add({ k = "src", p = 0, x = 0, y = ey })
  local gb = add({ k = "gb", p = src, x = 0, y = gy })
  local function axle(parent, front, st)
    local a, b = front and 0 or 2, front and 1 or 3
    local d = add({ k = "diff", p = parent, axle = true, st = st or "open",
                    x = (wheels[a].x + wheels[b].x) / 2, y = front and yF or yR })
    add({ k = "wheel", p = d, w = a })
    add({ k = "wheel", p = d, w = b })
  end
  local driven = { [0] = false, false, false, false }
  if layout == "awd" then
    local far = (abs(yF - gy) > abs(yR - gy)) and yF or yR
    local cy = gy + (far > gy and 1 or -1) * min(0.75, abs(far - gy) * 0.6)
    local c = add({ k = "diff", p = gb, x = 0, y = cy, st = awdDiff("CENTRE") or "lsd" })
    axle(c, true, awdDiff("FRONT") or "open")
    axle(c, false, awdDiff("REAR") or main or "open")
    for i = 0, 3 do driven[i] = true end
  elseif layout == "fwd" then
    axle(gb, true, main or "open"); driven[0], driven[1] = true, true
  else
    axle(gb, false, main or "open"); driven[2], driven[3] = true, true
  end
  return { layout = layout, engine = where, cg = cg, nodes = nodes, driven = driven,
           sources = { { k = "ice", x = 0, y = ey } } }
end

-- the car's own frame this frame: forward, and to the left (the side wheel 0, front left, is on)
local function basis(car)
  local f, u = car.look, car.up
  -- side = up x look, normalised; its sign is fixed against wheel 0 when the layout is captured
  local sx, sy, sz = u.y * f.z - u.z * f.y, u.z * f.x - u.x * f.z, u.x * f.y - u.y * f.x
  local l = sqrt(sx * sx + sy * sy + sz * sz)
  if l < 1e-6 then l = 1 end
  local s = (lay and lay.leftSign or 1) / l
  return f, { x = sx * s, y = sy * s, z = sz * s }
end

local function captureLayout(car, enginePref)
  local f, left = basis(car)
  local p = car.position
  local wl = {}
  for i = 0, 3 do
    local w = car.wheels[i]
    local q = w.position
    local dx, dy, dz = q.x - p.x, q.y - p.y, q.z - p.z
    wl[i] = { fwd = dx * f.x + dy * f.y + dz * f.z, side = dx * left.x + dy * left.y + dz * left.z,
              rd = num(get(w, "tyreRadius"), 0.32), wd = num(get(w, "tyreWidth"), 0.23) }
  end
  -- wheel 0 is front left in AC: whichever way 'side' points, make it point to the left
  local leftSign = (wl[0].side - wl[1].side) >= 0 and 1 or -1
  local wheels = {}
  for i = 0, 3 do wheels[i] = { x = -wl[i].side * leftSign, y = wl[i].fwd, rd = wl[i].rd, wd = wl[i].wd } end
  local yF, yR = (wheels[0].y + wheels[1].y) / 2, (wheels[2].y + wheels[3].y) / 2
  if yF < yR then return nil end   -- nonsense data (not loaded yet)
  local ext
  local size, centre = get(car, "aabbSize"), get(car, "aabbCenter")
  if size and centre and num(size.x, 0) > 0.5 and num(size.z, 0) > 1 then
    ext = { x0 = -size.x / 2, x1 = size.x / 2, y0 = centre.z - size.z / 2, y1 = centre.z + size.z / 2 }
  end
  local L = { idx = car.index, leftSign = leftSign, wheels = wheels, yF = yF, yR = yR, wb = yF - yR, ext = ext }
  L.drive = buildDrivetrain(car, wheels, yF, yR, enginePref)
  return L
end

-- ===== Per-frame kinematics =================================================
local function updateAccel(dt, vel, fwd, left)
  local r = kin.vring
  local s = ringNext(r)
  s.t, s.x, s.y, s.z = clock, vel.x, vel.y, vel.z
  local t0 = clock - TUNE.GF_WINDOW
  local n, st, sx, sy, sz = 0, 0, 0, 0, 0
  local idx = r.head
  for _ = 1, r.count do
    local q = r.s[idx]
    if q.t < t0 - 1e-9 then break end
    n, st, sx, sy, sz = n + 1, st + q.t, sx + q.x, sy + q.y, sz + q.z
    idx = (idx - 2) % r.n + 1
  end
  if n < 3 then return end
  local tm, xm, ym, zm = st / n, sx / n, sy / n, sz / n
  local stt, stx, sty, stz = 0, 0, 0, 0
  idx = r.head
  for _ = 1, n do
    local q = r.s[idx]
    local d = q.t - tm
    stt, stx, sty, stz = stt + d * d, stx + d * (q.x - xm), sty + d * (q.y - ym), stz + d * (q.z - zm)
    idx = (idx - 2) % r.n + 1
  end
  if stt < 1e-12 then return end
  local ax, ay, az = stx / stt, sty / stt, stz / stt
  -- x: + = accelerating to the right; y: + = accelerating forwards
  local x = -(ax * left.x + ay * left.y + az * left.z) / G
  local y = (ax * fwd.x + ay * fwd.y + az * fwd.z) / G
  if not kin.gInit then kin.gx, kin.gy, kin.g1x, kin.g1y, kin.gInit = x, y, x, y, true return end
  local ad = lpAlpha(TUNE.GF_D_CUTOFF, dt)
  kin.gdx = kin.gdx + ((x - kin.g1x) / dt - kin.gdx) * ad
  kin.gdy = kin.gdy + ((y - kin.g1y) / dt - kin.gdy) * ad
  local rate = max(0, sqrt(kin.gdx * kin.gdx + kin.gdy * kin.gdy) - TUNE.GF_D_FLOOR)
  local a = lpAlpha(TUNE.GF_MIN_CUTOFF + TUNE.GF_BETA * rate, dt)
  kin.g1x = kin.g1x + (x - kin.g1x) * a
  kin.g1y = kin.g1y + (y - kin.g1y) * a
  if TUNE.GF_STAGES >= 2 then
    kin.gx = kin.gx + (kin.g1x - kin.gx) * a
    kin.gy = kin.gy + (kin.g1y - kin.gy) * a
  else kin.gx, kin.gy = kin.g1x, kin.g1y end
end

-- Yaw rate (+ = turning left): the physics value, its sign checked against the change in heading
local function updateYaw(dt, car, fwd, left)
  local headYaw
  if kin.lastFwd then
    headYaw = atan2(dot(fwd, kin.lastLeft), dot(fwd, kin.lastFwd)) / dt
  end
  kin.lastFwd = { x = fwd.x, y = fwd.y, z = fwd.z }
  kin.lastLeft = { x = left.x, y = left.y, z = left.z }
  local physYaw
  local av = get(car, "localAngularVelocity")
  if av and type(av.y) == "number" and av.y == av.y then physYaw = av.y end
  local raw = headYaw
  if physYaw then
    if headYaw then
      kin.yawCheck = kin.yawCheck + (kin.yawSign * physYaw * headYaw - kin.yawCheck) * clamp(dt * 0.5, 0, 1)
      if kin.yawCheck < -0.01 then kin.yawSign, kin.yawCheck = -kin.yawSign, -kin.yawCheck end
    end
    raw = kin.yawSign * physYaw
  end
  if raw then
    kin.yawRate = kin.yawRate + (raw - kin.yawRate) * clamp(dt * TUNE.YAW_SMOOTH_HZ, 0, 1)
    kin.yawFast = kin.yawFast + (raw - kin.yawFast) * lpAlpha(TUNE.MARK_YAW_HZ, dt)
  end
end

-- Direction an axle at y metres forward is moving (+ = left of where the car points), all the
-- way round, from the body's velocity and yaw rate (AC's chassis is rigid)
local function axleTravel(current, y, vF, vL, k)
  local vx, vy = vL + kin.yawRate * y, vF
  if vx * vx + vy * vy < 0.09 then return current end
  local a = current + wrapAngle(atan2(vx, vy) - current) * k
  if a > 1.5 * pi then a = a - 2 * pi elseif a < -1.5 * pi then a = a + 2 * pi end
  return a
end

-- ===== Marker smoothing (as the BeamNG version) =============================
local function markerFilter(dt, tv, steerIn, k, grip)
  local x, s = toScale(tv, k) * 90, toScale(steerIn, k) * 90
  if not mark.init then
    mark.y, mark.d, mark.df, mark.ds, mark.s, mark.init = x, 0, 0, 0, s, true
    return tv
  end
  local rate = (x - mark.y) / dt
  mark.d = mark.d + (rate - mark.d) * lpAlpha(TUNE.MARK_D_CUTOFF, dt)
  mark.df = mark.df + (rate - mark.df) * lpAlpha(TUNE.MARK_D_FAST_CUTOFF, dt)
  mark.ds = mark.ds + ((s - mark.s) / dt - mark.ds) * lpAlpha(TUNE.MARK_STEER_CUTOFF, dt)
  mark.s = s
  local fast = max(0, abs(mark.df) - TUNE.MARK_FAST_FROM)
  local cutoff = TUNE.MARK_MIN_CUTOFF + TUNE.MARK_BETA * abs(mark.d) + TUNE.MARK_BETA2 * fast * fast
    + TUNE.MARK_STEER_GAIN * abs(mark.ds)
  mark.y = mark.y + (x - mark.y) * lpAlpha(cutoff, dt)
  if grip < 1 then mark.y = x + (mark.y - x) * grip end
  return fromScale(mark.y / 90, k)
end

-- ===== Balance state (as the BeamNG version, with AC's ndSlip as each axle's proximity) =====
-- 0 neutral, 1 front near its limit, 2 understeer, 3 rear near its limit, 4 both at their limit,
-- 5 oversteer (a controlled drift with dc), 6 a controlled powerslide
local function balanceStateOf(prev, bal, measured, rearSliding)
  if not measured then return 0 end
  if est.psOn then return est.psCtlOn and 6 or 5 end
  if bal >= (prev == 5 and 0.12 or 0.15) then return 5 end
  if rearSliding then return 0 end
  if abs(kin.yawRate) < TUNE.US_MIN_YAW * 0.5 then return 0 end
  if bal <= -(prev == 2 and TUNE.US_WARN_SHARE - 0.05 or TUNE.US_WARN_SHARE) then return 2 end
  local lead = gm.pF - gm.pR
  local wasF, wasR = prev == 1 or prev == 2 or prev == 4, prev == 3 or prev == 4 or prev == 5
  local nearF = gm.pF >= (wasF and TUNE.NEAR_OFF or TUNE.NEAR_ON)
  local nearR = gm.pR >= (wasR and TUNE.NEAR_OFF or TUNE.NEAR_ON)
  if nearF and nearR then
    if lead > TUNE.LEAD then return 1 elseif lead < -TUNE.LEAD then return 3 end
    return 4
  end
  if nearF then return 1 end
  if nearR then return 3 end
  return 0
end

-- ===== Signs AC's values are read with ======================================
-- The steering input's sign (which way is left) and the slip ratio's sign (which way is drive)
-- are learnt from the car itself, so nothing depends on a convention this code had to assume.
local function calibrate(dt, steerRaw, speed, gas, brake)
  if est.frontSteer and abs(steerRaw) > 0.05 and abs(est.frontSteer) > 0.01 then
    cal.steerVote = cal.steerVote + steerRaw * est.frontSteer * dt
    if abs(cal.steerVote) > 0.002 then cal.steerSign = cal.steerVote > 0 and 1 or -1 end
  end
end

-- ===== Main update ==========================================================
-- car: ac.StateCar. opts: { engine = 'auto'|'front'|'mid'|'rear'|'transverse', detail = bool }
-- Returns the body to draw, or nil (and a reason) when there's nothing to show yet.
function T.update(car, dt, opts)
  opts = opts or {}
  if not car then return nil, "no car" end
  if dt <= 0 or dt > 0.25 then
    -- paused, or a hitch: draw what we had; start the filters afresh after a long gap
    if dt > 0.25 then kin.gInit = false; mark.init = false end
    return out
  end
  if not lay or lay.idx ~= car.index or lay.enginePref ~= (opts.engine or "auto") then
    resetState()
    lay = captureLayout(car, opts.engine)
    if not lay then return nil, "waiting for car data" end
    lay.enginePref = opts.engine or "auto"
  end
  clock = clock + dt

  local fwd, left = basis(car)
  local vel = car.velocity
  local pos = car.position
  -- a teleport (back to the pits, a restart): no G-force spike, no marker sweep
  if kin.lastPos then
    local dx, dy, dz = pos.x - kin.lastPos.x, pos.y - kin.lastPos.y, pos.z - kin.lastPos.z
    if dx * dx + dy * dy + dz * dz > 100 then
      kin.vring, kin.gInit, mark.init = newRing(64), false, false
      kin.travel, kin.rearTravel = 0, 0
    end
  end
  kin.lastPos = { x = pos.x, y = pos.y, z = pos.z }
  local vF, vL = dot(vel, fwd), dot(vel, left)
  local speed = sqrt(vF * vF + vL * vL)
  kin.speed = speed
  updateAccel(dt, vel, fwd, left)
  updateYaw(dt, car, fwd, left)
  local kT = clamp(dt * TUNE.TRAVEL_SMOOTH_HZ, 0, 1)
  kin.travel = axleTravel(kin.travel, lay.yF, vF, vL, kT)
  kin.rearTravel = axleTravel(kin.rearTravel, lay.yR, vF, vL, kT)

  -- inputs
  local gas, brake = clamp(num(car.gas, 0), 0, 1), clamp(num(car.brake, 0), 0, 1)
  local clutchPedal = 1 - clamp(num(get(car, "clutch"), 1), 0, 1)   -- AC: 1 = engaged (pedal up)
  local handbrake = clamp(num(get(car, "handbrake"), 0), 0, 1)
  local steerDeg = num(car.steer, 0)
  local lockDeg = num(get(car, "steerLock"), 0)
  cal.lockSeen = max(cal.lockSeen, abs(steerDeg))
  if lockDeg < 1 then lockDeg = max(cal.lockSeen, 90) end
  if cal.lockSeen > lockDeg * 1.02 then lockDeg = cal.lockSeen end
  local steerRaw = clamp(steerDeg / lockDeg, -1, 1)

  -- slip ratio's sign: braking should read negative, drive positive
  if speed > 5 then
    local s = 0
    for i = 0, 3 do
      local w = car.wheels[i]
      local sr = num(w.slipRatio, 0)
      if brake > 0.3 and gas < 0.05 then s = s - sr
      elseif gas > 0.3 and brake < 0.05 and lay.drive.driven[i] then s = s + sr end
    end
    cal.srVote = clamp(cal.srVote + s * dt, -5, 5)
    if abs(cal.srVote) > 0.02 then cal.srSign = cal.srVote > 0 and 1 or -1 end
  end

  local absOn = get(car, "absInAction") == true
  local tcOn = get(car, "tractionControlInAction") == true
  local gripK = 1 - (1 - TUNE.GRIP_SMOOTHING) ^ (30 * dt)
  local ratioScale = min(1, speed / TUNE.RATIO_MIN_SPEED)
  local centreNow = abs(steerRaw) < TUNE.CENTRE_INPUT and abs(kin.yawRate) < 0.03 and speed > 3
  local snapNow = abs(steerRaw) < TUNE.CENTRE_INPUT and (speed < 3 or abs(kin.yawRate) < 0.03)
  local centreK = clamp(dt / TUNE.CENTRE_TAU, 0, 1)

  local o = out or { w = {}, inp = {}, gf = {}, sources = {}, nodes = lay.drive.nodes, ext = lay.ext }
  out = o
  local fSum, fN, rSum, rN = 0, 0, 0, 0
  local ndF, ldF, ndR, ldR = 0, 0, 0, 0
  for i = 0, 3 do
    local w, L = car.wheels[i], lay.wheels[i]
    local S = ws[i]
    if not S then S = { grip = 0, sliding = false, severity = 0, airT = 0, air = false } ws[i] = S end
    local load = num(w.load, 0)
    local nd = min(abs(num(w.ndSlip, 0)), 4)   -- wheelspin can send it sky-high
    local sr = num(w.slipRatio, 0) * cal.srSign
    local saDeg = num(w.slipAngle, 0)
    local blown = get(w, "isBlown") == true

    local unloaded = load < TUNE.MIN_LOAD
    if unloaded then S.airT = S.airT + dt else S.airT = 0 end
    if unloaded and S.airT >= TUNE.AIR_SHOW_AFTER then S.air = true
    elseif load > TUNE.MIN_LOAD * 2 then S.air = false end
    S.fzLp = S.fzLp and (S.fzLp + (load - S.fzLp) * lpAlpha(TUNE.LIGHT_HZ, dt)) or load
    if not S.fzRef then S.fzRef = max(load, TUNE.MIN_LOAD * 4)
    elseif load > S.fzRef * 0.5 then S.fzRef = max(S.fzRef + (load - S.fzRef) * clamp(dt / TUNE.LIGHT_REF_TAU, 0, 1), TUNE.MIN_LOAD * 4) end
    local edge = max(TUNE.LIGHT_FRAC * S.fzRef, TUNE.MIN_LOAD * 2)
    local light = S.air and 0 or clamp((edge - S.fzLp) / (edge - TUNE.MIN_LOAD), 0, 1)
    local hold = unloaded and not S.air

    -- grip in use: AC's own normalised slip
    local use = unloaded and 0 or nd
    if not hold then
      S.grip = S.grip + (use - S.grip) * gripK
      if unloaded then S.sliding = false
      elseif nd > TUNE.SLIDE_ON then S.sliding = true
      elseif nd < TUNE.SLIDE_OFF then S.sliding = false end
    end
    local severity = 0
    if S.sliding then
      local ta = math.tan(clamp(math.rad(abs(saDeg)), 0, 1.4))
      local ratio = sqrt(sr * sr + ta * ta) * ratioScale
      if ratio <= TUNE.SLIP_RATIO_PINK then severity = TUNE.PINK_SEVERITY * ratio / TUNE.SLIP_RATIO_PINK
      else
        severity = TUNE.PINK_SEVERITY + (1 - TUNE.PINK_SEVERITY) * clamp((ratio - TUNE.SLIP_RATIO_PINK) / (TUNE.SLIP_RATIO_FULL - TUNE.SLIP_RATIO_PINK), 0, 1)
      end
    end
    if not hold then S.severity = S.severity + (severity - S.severity) * gripK end

    -- torque: + drive, - braking, from the slip ratio (what the tyre is actually being asked for)
    local torque
    if speed < TUNE.STANDSTILL_SPEED then torque = -max(brake, handbrake * ((i >= 2) and 1 or 0))
    else torque = clamp(sr * ratioScale / TUNE.SR_PEAK, -1, 1) end
    local driven = lay.drive.driven[i]
    local driveline = 0
    if driven then
      if gas > 0.02 then driveline = max(torque, 0)
      elseif brake < 0.02 and handbrake < 0.02 then driveline = min(torque, 0) end   -- engine braking
    end

    -- steering: the wheel's heading against the body, against a straight-ahead reference
    local lk = w.look
    local rawYaw = atan2(dot(lk, left), dot(lk, fwd))
    if snapNow and not S.centred then S.steerBase, S.centred = rawYaw, true
    elseif not S.steerBase then S.steerBase = rawYaw
    elseif centreNow then
      local d = wrapAngle(rawYaw - S.steerBase)
      S.steerBase = S.steerBase + d * centreK
    end
    local steer = wrapAngle(rawYaw - S.steerBase)
    if steer > pi / 2 then steer = steer - pi elseif steer < -pi / 2 then steer = steer + pi end
    if i < 2 then fSum, fN = fSum + steer, fN + 1 else rSum, rN = rSum + steer, rN + 1 end

    -- each axle's ndSlip, weighted by load
    if not unloaded then
      if i < 2 then ndF, ldF = ndF + nd * load, ldF + load else ndR, ldR = ndR + nd * load, ldR + load end
    end

    -- ABS on this wheel: while ABS works, the wheels it's holding at braking slip
    local iv
    if absOn and brake > 0 and sr * ratioScale < -TUNE.SR_ABS then iv = 1 end

    local wo = o.w[i + 1]
    if not wo then wo = { i = i } o.w[i + 1] = wo end
    wo.x, wo.y, wo.rd, wo.wd = L.x, L.y, L.rd, L.wd
    wo.d = driven and 1 or 0
    wo.s = steer
    wo.g = S.grip
    wo.e = S.sliding and 1 or 0
    wo.ex = S.sliding and S.severity or 0
    wo.t = torque
    wo.dr = driveline
    wo.b = 0
    wo.a = S.air and 1 or nil
    wo.lf = (light > 0.02) and light or nil
    wo.fl = blown and 1 or nil
    wo.iv = iv
    wo.fz = opts.detail and load or nil
  end
  est.frontSteer = fN > 0 and fSum / fN or nil
  est.rearSteer = rN > 0 and rSum / rN or 0
  est.drvF = lay.drive.driven[0]
  est.drvR = lay.drive.driven[2]

  calibrate(dt, steerRaw, speed, gas, brake)
  local steerIn = clamp(steerRaw * cal.steerSign, -1, 1)   -- + = left

  -- full-lock road-wheel angle, learnt from how far the front wheels turn
  if est.frontSteer and abs(steerIn) > 0.15 then
    local front = abs(est.frontSteer)
    if front > 0.02 then est.lock = est.lock + (clamp(front / abs(steerIn), 0.15, 1.4) - est.lock) * clamp(3 * dt, 0, 1) end
  end

  -- each axle's proximity to its limit
  local slowFade = clamp((speed - TUNE.GRIP_MIN_SPEED) / 3, 0, 1)
  local kG = lpAlpha(TUNE.GRIP_HZ, dt)
  gm.pF = gm.pF + ((ldF > 0 and ndF / ldF or 0) * slowFade - gm.pF) * kG
  gm.pR = gm.pR + ((ldR > 0 and ndR / ldR or 0) * slowFade - gm.pR) * kG

  -- the balance
  local function slipAngle(steerAvg, travel)
    local d = steerAvg - travel
    return atan2(math.sin(d), abs(math.cos(d)))
  end
  local target = 0
  local slipF = slipAngle(est.frontSteer or 0, kin.travel)
  local slipR = slipAngle(est.rearSteer, kin.rearTravel)
  est.slipF, est.slipR = slipF, slipR
  local turn = kin.yawRate >= 0 and 1 or -1
  local diff = (slipR - slipF) * turn
  local rs = smoothstep((abs(kin.rearTravel) - TUNE.REAR_GRIP_SLIP) / (TUNE.REAR_SLIDE_SLIP - TUNE.REAR_GRIP_SLIP))
  est.rs = rs
  local yawOver = clamp(abs(kin.yawRate) / TUNE.BAL_MIN_YAW, 0, 1)
  local yawUnder = clamp(abs(kin.yawRate) / TUNE.US_MIN_YAW, 0, 1)
  local rearGate = max(clamp((abs(slipR) - TUNE.BAL_SLIP_START) / (TUNE.BAL_SLIP_FULL - TUNE.BAL_SLIP_START), 0, 1),
                       clamp((gm.pR - 0.8) / 0.4, 0, 1))
  local over = smoothstep((diff - TUNE.BAL_DEADBAND) / (TUNE.BAL_FULL - TUNE.BAL_DEADBAND)) * rearGate * yawOver
  if speed < TUNE.TRAVEL_FADE_LO then over = 0 end
  if over > 0 then target = over
  else
    local lead = clamp((gm.pF - gm.pR - 0.05) / 0.2, 0, 1)
    local near = smoothstep((gm.pF - (TUNE.NEAR_ON - 0.2)) / 0.3)
    local past = smoothstep((gm.pF - TUNE.PAST_ON) / 0.3)
    target = -(TUNE.US_WARN_SHARE * near + (1 - TUNE.US_WARN_SHARE) * past) * lead * yawUnder * (1 - rs)
  end
  est.balance = est.balance + (target - est.balance) * clamp(TUNE.TRAVEL_SMOOTH_HZ * dt, 0, 1)
  local cand = balanceStateOf(est.state, est.balance, speed > TUNE.TRAVEL_FADE_LO, rs > 0.05)
  local warn = cand == 1 or cand == 3 or cand == 4
  if cand ~= est.cand then est.cand, est.candT = cand, 0 else est.candT = est.candT + dt end
  if not warn or est.state == 2 or est.state == 5 or est.candT >= TUNE.WARN_HOLD or (est.state ~= 0 and warn) then est.state = cand end

  -- how controlled a slide is: 1 = a controlled drift
  local control, holdingAll = 0, 0
  do
    local slide = wrapAngle(est.rearSteer - kin.rearTravel)
    local rate = est.prevSlide and wrapAngle(slide - est.prevSlide) / dt or 0
    est.prevSlide = slide
    est.slideRate = est.slideRate + (rate - est.slideRate) * lpAlpha(TUNE.DRIFT_RATE_HZ, dt)
    local growing = max(0, est.slideRate * (slide >= 0 and 1 or -1))
    local steerOk = 1 - smoothstep((abs(slipF) - TUNE.DRIFT_STEER_OK) / (TUNE.DRIFT_STEER_OFF - TUNE.DRIFT_STEER_OK))
    local holding = 1 - smoothstep((growing - TUNE.DRIFT_GROW_OK) / (TUNE.DRIFT_GROW_OFF - TUNE.DRIFT_GROW_OK))
    control = (abs(slide) > TUNE.DRIFT_MAX_ANGLE) and 0 or steerOk * holding
    holdingAll = (abs(slide) > TUNE.DRIFT_MAX_ANGLE) and 0 or holding
  end
  est.drift = est.drift + (control - est.drift) * clamp(TUNE.TRAVEL_SMOOTH_HZ * dt, 0, 1)
  -- an all-wheel-drive powerslide, and how controlled it is
  local ps = 0
  if est.drvF and est.drvR then
    local aF, aR = slipF * turn, slipR * turn
    local rearOut = smoothstep((aR - TUNE.PS_REAR_START) / (TUNE.PS_REAR_FULL - TUNE.PS_REAR_START))
    local frontIn = smoothstep((aF - TUNE.PS_FRONT_START) / (TUNE.PS_FRONT_FULL - TUNE.PS_FRONT_START))
    local plough = smoothstep((aF - aR - TUNE.PS_PLOUGH_START) / (TUNE.PS_PLOUGH_FULL - TUNE.PS_PLOUGH_START))
    local power = smoothstep((gas - TUNE.PS_THROTTLE) / 0.2)
    ps = rearOut * frontIn * (1 - plough) * power * clamp((speed - 5) / 4, 0, 1) * yawOver
  end
  local kps = clamp(TUNE.TRAVEL_SMOOTH_HZ * dt, 0, 1)
  est.ps = est.ps + (ps - est.ps) * kps
  est.psCtl = est.psCtl + (holdingAll - est.psCtl) * kps
  est.psOn = est.ps >= (est.psOn and 0.3 or 0.5)
  est.psCtlOn = est.psOn and est.psCtl >= (est.psCtlOn and 0.45 or 0.6)

  -- the direction marker: shown whenever the car is moving, but not when reversing on purpose
  local inp = o.inp
  local gear = num(get(car, "gear"), 1)
  local reversing = gear < 0 and vF < 0
  inp.tv, inp.k, inp.ta, inp.bal, inp.dc, inp.bs = nil, nil, nil, nil, nil, nil
  local sr1g = (vF > 3) and ((lay.wb * G / (vF * vF) + 0.03) / est.lock) or nil
  local k = steerK(sr1g)
  inp.k = k
  if speed > TUNE.TRAVEL_FADE_LO and not reversing then
    local slide = abs(wrapAngle(est.rearSteer - kin.rearTravel))
    local wgt = 1 - smoothstep((slide - TUNE.REAR_GRIP_SLIP) / (TUNE.REAR_SLIDE_SLIP - TUNE.REAR_GRIP_SLIP))
    local kinTurn = kin.travel - kin.rearTravel
    if vF > 3 then kinTurn = atan2(lay.wb * kin.yawFast, vF) end   -- rigid car: exact, and clean
    local rsteer = est.rearSteer
    if abs(rsteer) < 0.01 then rsteer = 0 end
    local shown = (1 - wgt) * kin.travel + wgt * (kinTurn + rsteer)
    if est.frontSteer then
      local f = 1 - dt / TUNE.RATIO_TAU
      est.rn = est.rn * f + est.frontSteer * steerIn
      est.rd = est.rd * f + steerIn * steerIn
    end
    local eps = 2e-4
    est.ratio = clamp((est.rn + est.lock * eps) / (est.rd + eps), est.lock * 0.3, est.lock * 1.5)
    local tvRaw = clamp(shown / est.ratio, -TUNE.TRAVEL_MAX, TUNE.TRAVEL_MAX)
    inp.tv = clamp(markerFilter(dt, tvRaw, steerIn, k, wgt), -TUNE.TRAVEL_MAX, TUNE.TRAVEL_MAX)
    inp.ta = clamp((speed - TUNE.TRAVEL_FADE_LO) / (TUNE.TRAVEL_FADE_HI - TUNE.TRAVEL_FADE_LO), 0, 1)
    inp.bal = est.balance
    inp.bs = est.state
    inp.dc = (est.balance > 0.01) and est.drift or nil
  else
    mark.init = false
  end
  inp.s = steerIn
  inp.t = pedalLevel(gas)
  inp.b = pedalLevel(brake)
  inp.c = pedalLevel(clutchPedal)
  inp.p = pedalLevel(handbrake)
  inp.abs = absOn and brake > 0 and 1 or nil
  inp.tcs = tcOn and 1 or nil

  -- G-force as felt (opposite to the acceleration): x + = pushed right, y + = pushed forward
  o.gf.x, o.gf.y = -kin.gx, -kin.gy
  o.sources[1] = o.sources[1] or { k = "ice" }
  o.sources[1].x, o.sources[1].y = lay.drive.sources[1].x, lay.drive.sources[1].y
  o.sources[1].tc = tcOn and 1 or nil
  o.id = car.index

  -- numbers mode: the axle slip angles in the turn's direction
  if opts.detail then
    o.vd = o.vd or {}
    o.vd.af, o.vd.ar = slipF * turn, slipR * turn
    o.vd.sl = (est.state == 6) and abs(slipR) or nil
  else
    o.vd = nil
  end
  return o
end

-- What the estimates are doing, for the settings window's diagnostics
function T.diag()
  if not lay then return nil end
  return {
    layout = lay.drive.layout, engine = lay.drive.engine, cg = lay.drive.cg, wb = lay.wb,
    pF = gm.pF, pR = gm.pR, state = est.state, balance = est.balance, lock = est.lock, ratio = est.ratio,
    slipF = est.slipF, slipR = est.slipR, yaw = kin.yawRate, steerSign = cal.steerSign, srSign = cal.srSign,
    yawSign = kin.yawSign,
  }
end

function T.reset() resetState() end

return T
