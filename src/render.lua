-- VGS Display for Assetto Corsa : renderer
-- ---------------------------------------------------------------------------
-- A port of the BeamNG app's canvas renderer (app.js) to Custom Shaders Patch's immediate-mode
-- UI drawing. Same picture, same colours, same rules:
--   Inner bar  : grip in use, growing from the centre; pink to deep red past the limit
--   Outline    : torque — grey neutral, greener with drive, redder with braking
--   Rotation   : each wheel's live steering angle
--   Underneath : engine, gearbox, shafts and differentials, tinted by the torque flowing
--   Rim        : steering (blue) from the top, brake (red) bottom-left, throttle (green)
--                bottom-right, clutch and handbrake along the outer edge
--   Wedge      : the direction marker (how much the car is actually turning), coloured by the
--                balance: yellow warnings, orange-red understeer, pink-magenta oversteer,
--                aquamarine a controlled drift or powerslide
--   Yellow dot : the G-force, with a fading trail
-- Numbers mode adds grip and load by every corner, and the balance in words and degrees.
-- All drawing goes through D (below), so the renderer can run outside the game too.
-- ---------------------------------------------------------------------------

local Tm = require('src/telemetry')
local R = {}

local abs, sqrt, min, max, floor, pi = math.abs, math.sqrt, math.min, math.max, math.floor, math.pi
local sin, cos = math.sin, math.cos
local clamp = Tm.clamp
local function hypot(a, b) return sqrt(a * a + b * b) end

-- ===== Drawing backend (CSP ui) =============================================
local D = {}
R.D = D
local function col(r, g, b, a) return rgbm(r / 255, g / 255, b / 255, a or 1) end
local function withAlpha(c, a) return rgbm(c.r, c.g, c.b, c.mult * a) end
local CORNERS = (ui.CornerFlags and ui.CornerFlags.All) or 0
function D.circleFilled(x, y, r, c) ui.drawCircleFilled(vec2(x, y), r, c, max(12, min(64, floor(r * 1.2)))) end
function D.circle(x, y, r, c, th) ui.drawCircle(vec2(x, y), r, c, max(12, min(64, floor(r * 1.2))), th) end
function D.arc(x, y, r, a0, a1, c, th)
  if a1 - a0 < 0.004 then return end
  ui.pathArcTo(vec2(x, y), r, a0, a1, max(4, floor((a1 - a0) / (2 * pi) * 96) + 1))
  ui.pathStroke(c, false, th)
end
function D.poly(pts, c)   -- convex polygon, filled; pts = { x1, y1, x2, y2, ... }
  for k = 1, #pts, 2 do ui.pathLineTo(vec2(pts[k], pts[k + 1])) end
  ui.pathFillConvex(c)
end
function D.polyline(pts, c, th, closed)
  for k = 1, #pts, 2 do ui.pathLineTo(vec2(pts[k], pts[k + 1])) end
  ui.pathStroke(c, closed and true or false, th)
end
function D.line(x1, y1, x2, y2, c, th) ui.drawLine(vec2(x1, y1), vec2(x2, y2), c, th) end
function D.rectFilled(x0, y0, x1, y1, c, round) ui.drawRectFilled(vec2(x0, y0), vec2(x1, y1), c, round or 0, CORNERS) end
function D.rect(x0, y0, x1, y1, c, th, round) ui.drawRect(vec2(x0, y0), vec2(x1, y1), c, round or 0, CORNERS, th) end
function D.dashed(x1, y1, x2, y2, c, th, on, off)
  local len = hypot(x2 - x1, y2 - y1)
  if len < 0.01 then return end
  local ux, uy, d = (x2 - x1) / len, (y2 - y1) / len, 0
  while d < len do
    local e = min(len, d + on)
    ui.drawLine(vec2(x1 + ux * d, y1 + uy * d), vec2(x1 + ux * e, y1 + uy * e), c, th)
    d = e + off
  end
end
-- Text. DWrite fonts, with a fallback to the plain UI font if they're not there.
local fonts = {}
local function font(weight)
  if fonts[weight] == nil then
    fonts[weight] = false
    if ui.DWriteFont then
      local ok, f = pcall(function()
        local fnt = ui.DWriteFont('Segoe UI')
        local W = ui.DWriteFont.Weight
        if weight >= 700 and W and W.Bold then fnt = fnt:weight(W.Bold)
        elseif weight >= 600 and W and (W.SemiBold or W.Bold) then fnt = fnt:weight(W.SemiBold or W.Bold) end
        return fnt
      end)
      if ok then fonts[weight] = f end
    end
  end
  return fonts[weight]
end
local measureCache, measureN = {}, 0
function D.measure(s, px, weight)
  local key = s .. '|' .. px .. '|' .. weight
  local v = measureCache[key]
  if v then return v end
  local f = font(weight)
  if f then
    ui.pushDWriteFont(f)
    v = ui.measureDWriteText(s, px).x
    ui.popDWriteFont()
  else
    v = #s * px * 0.55
  end
  measureN = measureN + 1
  if measureN > 2000 then measureCache, measureN = {}, 0 end
  measureCache[key] = v
  return v
end
-- y is the baseline, as on a canvas; align 'left' | 'center' | 'right'. A dark shadow behind it.
function D.text(s, x, y, px, weight, c, align, shadow)
  local w = D.measure(s, px, weight)
  if align == 'center' then x = x - w / 2 elseif align == 'right' then x = x - w end
  local top = y - px * 1.0
  local f = font(weight)
  if f then ui.pushDWriteFont(f) end
  if shadow then ui.dwriteDrawText(s, px, vec2(x + 1, top + 1), rgbm(0, 0, 0, 0.6 * c.mult)) end
  ui.dwriteDrawText(s, px, vec2(x, top), c)
  if f then ui.popDWriteFont() end
  return w
end

-- ===== Style ================================================================
local STYLE = {
  neutral = { 128, 134, 145 }, drive = { 70, 225, 95 }, brake = { 255, 60, 50 },
  gripFill = col(236, 240, 246, 0.92), panelFill = col(12, 14, 18, 0.62), panelStroke = col(255, 255, 255, 0.22),
  tyreBg = col(0, 0, 0, 0.5), broken = col(160, 160, 160, 0.6), airborne = col(40, 130, 235),
  airLight = { 120, 178, 245 }, text = col(255, 255, 255, 0.88),
}
local DRIVETRAIN = {
  axle = col(255, 255, 255, 0.22), diffBg = col(22, 25, 31), gearbox = col(200, 205, 214, 0.88),
  diff = col(236, 240, 246, 0.75), engine = col(236, 240, 246, 0.88), engineEdge = col(0, 0, 0, 0.55),
}
local ASSIST = { [1] = col(255, 85, 75, 0.9), [2] = col(80, 220, 120, 0.9), [3] = col(95, 165, 255, 0.9) }
local TYRE_W, TYRE_H, PAD = 0.23, 0.8, 0.28
local TYRE_WIDEN = 1.5
local ENGINE_W, ENGINE_H, DIFF, GB_SIZE = 0.62, 0.48, 0.2, 0.34
local MIN_TYRE_W, MIN_TYRE_L = 3, 6
local DOT_SPACE = 0.22
local function dotRadius(tyreW) return clamp(tyreW * 0.22, 1.8, 3.2) end

local function mix(a, b, t, alpha)
  return rgbm((a[1] + (b[1] - a[1]) * t) / 255, (a[2] + (b[2] - a[2]) * t) / 255, (a[3] + (b[3] - a[3]) * t) / 255, alpha or 1)
end
local function torqueColour(t, alpha)
  t = clamp(tonumber(t) or 0, -1, 1)
  if t >= 0 then return mix(STYLE.neutral, STYLE.drive, t, alpha) end
  return mix(STYLE.neutral, STYLE.brake, -t, alpha)
end
-- HSL -> rgbm (for the slide colour, which blends in HSL as the canvas version did)
local function hsl(h, s, l, a)
  h, s, l = (h % 360) / 360, s / 100, l / 100
  local function f(n)
    local k = (n + h * 12) % 12
    local q = s * min(l, 1 - l)
    return l - q * max(-1, min(k - 3, 9 - k, 1))
  end
  return rgbm(f(0), f(8), f(4), a or 1)
end
local SLIDE_LOW, SLIDE_HIGH = { 3, 48, 64 }, { 0, 100, 47 }
local function slideColour(severity, alpha)
  local k = clamp(tonumber(severity) or 1, 0, 1)
  return hsl(SLIDE_LOW[1] + (SLIDE_HIGH[1] - SLIDE_LOW[1]) * k, SLIDE_LOW[2] + (SLIDE_HIGH[2] - SLIDE_LOW[2]) * k,
             SLIDE_LOW[3] + (SLIDE_HIGH[3] - SLIDE_LOW[3]) * k, alpha)
end
R.slideColour, R.torqueColour = slideColour, torqueColour

-- ===== Geometry (once per car and app size) =================================
local function geometry(body)
  local wheels = body.w
  for _, w in ipairs(wheels) do
    w._len = (w.rd > 0.02 and w.rd < 3) and 2 * w.rd or TYRE_H
    w._wd = ((w.wd > 0.005 and w.wd < 2) and w.wd or TYRE_W) * TYRE_WIDEN
    w._mx = w.x
    w._side = w.x < 0 and -1 or 1
  end
  local tx0, tx1, ty0, ty1 = math.huge, -math.huge, math.huge, -math.huge
  for _, w in ipairs(wheels) do
    tx0, tx1 = min(tx0, w._mx - w._wd / 2), max(tx1, w._mx + w._wd / 2)
    ty0, ty1 = min(ty0, w.y - w._len / 2), max(ty1, w.y + w._len / 2)
  end
  local mid = (wheels[1].x + wheels[2].x + wheels[3].x + wheels[4].x) / 4
  local ext, box = body.ext, nil
  local hasExt = ext ~= nil
  if hasExt then
    local half = min(mid - ext.x0, ext.x1 - mid)
    box = { x0 = min(mid - half, tx0), x1 = max(mid + half, tx1), y0 = min(ext.y0, ty0), y1 = max(ext.y1, ty1) }
  else
    local sy0, sy1 = ty0, ty1
    for _, s in ipairs(body.sources) do sy0, sy1 = min(sy0, s.y - ENGINE_H / 2), max(sy1, s.y + ENGINE_H / 2) end
    box = { x0 = tx0 - PAD / 2, x1 = tx1 + PAD / 2, y0 = sy0 - PAD / 2, y1 = sy1 + PAD / 2 }
  end
  local g = { cx = (box.x0 + box.x1) / 2, cy = (box.y0 + box.y1) / 2, box = box, hasExt = hasExt }
  g.boxHalfW, g.boxHalfH = (box.x1 - box.x0) / 2, (box.y1 - box.y0) / 2
  g.centreX = mid
  -- radius (metres from the body centre) the circle must hold: body, tyres at any steer, engine
  local rM = hypot(g.boxHalfW, g.boxHalfH)
  for _, w in ipairs(wheels) do
    local ox, oy = abs(w._mx - g.cx), w.y - g.cy
    rM = max(rM, hypot(ox, oy) + hypot(w._wd, w._len) / 2, hypot(ox + w._wd / 2 + DOT_SPACE, oy))
  end
  for _, s in ipairs(body.sources) do rM = max(rM, hypot(s.x - g.cx, s.y - g.cy) + hypot(ENGINE_W, ENGINE_H) / 2) end
  g.fitR = rM
  return g
end

-- ===== Steering scale and the direction marker's state =====================
local STEER_HIDE_DEG, STEER_SHOW_DEG, STEER_VIS_K = 8 / 3, 6, 60
local function steerScale(x, k) return Tm.toScale(x, k or 20) end

local TRAVEL_COLOUR = { neutral = { 150, 210, 245 }, near = { 255, 214, 10 }, rnear = { 255, 214, 10 }, limit = { 255, 214, 10 },
                        under = { 255, 96, 24 }, over = { 250, 130, 235 }, drift = { 60, 230, 195 }, pslide = { 60, 230, 195 } }
local DRIFT_ON, DRIFT_OFF = 0.6, 0.45
local DRIFT_CONFIRM_MS, STATE_HOLD_MS, STATE_BLEND_MS = 200, 450, 80
local MARK_FADE_IN_MS, MARK_FADE_OUT_MS = 30, 120
local STATE_SEVERITY = { near = 1, rnear = 1, limit = 2, under = 3, over = 3, drift = 3, pslide = 3 }
local BS_STATE = { [1] = 'near', [2] = 'under', [3] = 'rnear', [4] = 'limit', [5] = 'over', [6] = 'pslide' }
local function balanceState(inp, cur)
  if not inp or inp.bs == nil then return nil end
  local st = BS_STATE[inp.bs]
  if st == 'over' then return (inp.dc or 0) >= (cur == 'drift' and DRIFT_OFF or DRIFT_ON) and 'drift' or 'over' end
  return st
end
local function stateRgb(st) return TRAVEL_COLOUR[st] or TRAVEL_COLOUR.neutral end

local MS = { now = 0 }   -- the renderer's clock, ms
local markState
local function markerState(inp)
  local now, m = MS.now, markState
  if not m then
    local s0 = balanceState(inp, nil)
    local c0 = stateRgb(s0)
    m = { cur = s0, cand = s0, candT = -1e9, since = now, t = now, a = s0 and 1 or 0,
          rgb = { c0[1], c0[2], c0[3] }, from = { c0[1], c0[2], c0[3] }, t0 = -1e9 }
    markState = m
  end
  local dt = clamp(now - m.t, 0, 100)
  m.t = now
  local cand, cur = balanceState(inp, m.cur), m.cur
  if cand ~= m.cand then m.cand, m.candT = cand, now end
  if (cand == 'drift' or cand == 'pslide') and cur ~= cand and now - m.candT < DRIFT_CONFIRM_MS then cand = 'over' end
  if cand == cur then m.since = now
  else
    local at = cand and (not cur or STATE_SEVERITY[cand] > STATE_SEVERITY[cur] or (STATE_SEVERITY[cand] == 3 and STATE_SEVERITY[cur] == 3))
    if at or now - m.since >= STATE_HOLD_MS then
      if cand then m.from = { m.rgb[1], m.rgb[2], m.rgb[3] }; m.t0 = cur and now or -1e9 end
      m.cur, m.since = cand, now
    end
  end
  if m.cur then
    local to, k = stateRgb(m.cur), clamp((now - m.t0) / STATE_BLEND_MS, 0, 1)
    for c = 1, 3 do m.rgb[c] = m.from[c] + (to[c] - m.from[c]) * k end
  end
  local target = m.cur and 1 or 0
  m.a = m.a + (target - m.a) * (1 - math.exp(-dt / (target > m.a and MARK_FADE_IN_MS or MARK_FADE_OUT_MS)))
  if m.a < 0.01 then m.a = 0 end
  return { state = m.cur, rgb = m.rgb, a = m.a }
end
R.markerState = markerState

-- ===== Input arcs and the marker ============================================
local INPUT = {
  steer = { 45, 115, 205 }, brake = { 205, 45, 40 }, throttle = { 60, 180, 75 },
  brakePulse = { 240, 80, 70 }, throttlePulse = { 30, 110, 45 }, clutch = { 225, 229, 236 }, handbrake = { 135, 22, 58 },
}
local PULSE_HZ = 5
local function markerSize(rPx) return clamp(rPx * 0.1, 8, 16) end

local function drawInputArcs(cx, cy, rPx, inp, mk)
  local lw = clamp(rPx * 0.05, 3, 7)
  local r, Q, TOP, BOTTOM = rPx - lw / 2, pi / 2, -pi / 2, pi / 2
  local steer, thr, brk = clamp(inp.s or 0, -1, 1), clamp(inp.t or 0, 0, 1), clamp(inp.b or 0, 0, 1)
  local sk = inp.k or 20
  local steerShown = steerScale(steer, sk)
  local steerDeg = steerScale(abs(steer), min(sk, STEER_VIS_K)) * 90
  local steerVis = clamp((steerDeg - STEER_HIDE_DEG) / (STEER_SHOW_DEG - STEER_HIDE_DEG), 0, 1)
  steerVis = steerVis * steerVis * (3 - 2 * steerVis)
  if steerVis > 0 then
    local c = mix(INPUT.steer, INPUT.steer, 0, steerVis)
    if steerShown > 0 then D.arc(cx, cy, r, TOP - steerShown * Q, TOP, c, lw)
    else D.arc(cx, cy, r, TOP, TOP - steerShown * Q, c, lw) end
  end
  local pulse = 0.5 + 0.5 * sin(MS.now / 1000 * 2 * pi * PULSE_HZ)
  D.arc(cx, cy, r, BOTTOM, BOTTOM + brk * Q, mix(INPUT.brake, INPUT.brakePulse, inp.abs and pulse or 0), lw)
  D.arc(cx, cy, r, BOTTOM - thr * Q, BOTTOM, mix(INPUT.throttle, INPUT.throttlePulse, inp.tcs and pulse or 0), lw)
  local clu, hb = clamp(inp.c or 0, 0, 1), clamp(inp.p or 0, 0, 1)
  local r2 = rPx - lw / 4
  D.arc(cx, cy, r2, BOTTOM, BOTTOM + hb * Q, mix(INPUT.handbrake, INPUT.handbrake, 0), lw / 2)
  D.arc(cx, cy, r2, BOTTOM - clu * Q, BOTTOM, mix(INPUT.clutch, INPUT.clutch, 0), lw / 2)

  -- the direction marker, with a band in its colour back to the end of the steering arc
  local alpha = clamp(inp.ta or 0, 0, 1) * mk.a
  if inp.tv ~= nil and alpha > 0 then
    local tvd = steerScale(clamp(inp.tv, -4, 4), sk)
    local ang = TOP - tvd * Q
    local mh = markerSize(rPx)
    local tip = rPx - lw - 0.5
    local base, half = tip - mh, mh * 0.55
    local ux, uy = cos(ang), sin(ang)
    local px, py = -uy, ux
    local steerAng = TOP - steerShown * Q
    local gap = ang - steerAng
    local c3 = mk.rgb
    if abs(gap) > 0.03 and abs(gap) < pi then
      local bw = clamp(lw * 0.6, 2, 4.5)
      D.arc(cx, cy, tip - bw / 2 - 0.5, min(ang, steerAng), max(ang, steerAng), rgbm(c3[1] / 255, c3[2] / 255, c3[3] / 255, 0.7 * alpha), bw)
    end
    local pts = { cx + ux * tip, cy + uy * tip, cx + ux * base + px * half, cy + uy * base + py * half,
                  cx + ux * base - px * half, cy + uy * base - py * half }
    D.poly(pts, rgbm(c3[1] / 255, c3[2] / 255, c3[3] / 255, alpha))
    D.polyline(pts, rgbm(8 / 255, 10 / 255, 14 / 255, 0.85 * alpha), 1.5, true)
  end
end

-- ===== G-force dot ==========================================================
local GF_MAX, TRAIL_MS, TRAIL_STEP_MS = 1.5, 1300, 12
local GF_COLOUR, GF_ALPHA, GF_RIM_ALPHA = { 240, 215, 130 }, 0.68, 0.95
local trail = {}
local function drawGForce(cx, cy, R0, gf)
  local now = MS.now
  local gx, gy = gf.x or 0, gf.y or 0
  local mag = hypot(gx, gy)
  if mag > GF_MAX then gx, gy = gx * GF_MAX / mag, gy * GF_MAX / mag end
  local last = trail[#trail]
  if last and now - last.t < TRAIL_STEP_MS then last.x, last.y = gx / GF_MAX, -gy / GF_MAX
  else trail[#trail + 1] = { x = gx / GF_MAX, y = -gy / GF_MAX, t = now } end
  while #trail > 0 and now - trail[1].t > TRAIL_MS do table.remove(trail, 1) end
  local dotR = clamp(R0 * 0.058, 3.5, 8.5)
  local reach = R0 - dotR - 2
  local head = trail[#trail]
  local minStep, lastX, lastY = dotR * 0.6 / reach, math.huge, math.huge
  for k = 1, #trail - 1 do
    local tk = trail[k]
    if hypot(tk.x - head.x, tk.y - head.y) >= dotR / reach and hypot(tk.x - lastX, tk.y - lastY) >= minStep then
      lastX, lastY = tk.x, tk.y
      local life = 1 - (now - tk.t) / TRAIL_MS
      D.circleFilled(cx + tk.x * reach, cy + tk.y * reach, dotR * (0.7 + 0.3 * life), mix(GF_COLOUR, GF_COLOUR, 0, 0.42 * life * life))
    end
  end
  local hx, hy = cx + head.x * reach, cy + head.y * reach
  D.circle(hx, hy, dotR + 1.2, rgbm(8 / 255, 10 / 255, 14 / 255, 0.55), 1.5)
  D.circleFilled(hx, hy, dotR, mix(GF_COLOUR, GF_COLOUR, 0, GF_ALPHA))
  D.circle(hx, hy, dotR, mix(GF_COLOUR, GF_COLOUR, 0, GF_RIM_ALPHA), 1.25)
end

-- ===== Tyres ================================================================
-- a rectangle of half-size (hw, hh) around (x, y), rotated by -s on screen (+ steer = left)
local function quad(x, y, hw, hh, cs, sn, ox, oy)
  ox, oy = ox or 0, oy or 0
  local pts = {}
  local corners = { -hw, -hh, hw, -hh, hw, hh, -hw, hh }
  for k = 1, 8, 2 do
    local px, py = corners[k] + ox, corners[k + 1] + oy
    pts[#pts + 1] = x + px * cs + py * sn
    pts[#pts + 1] = y - px * sn + py * cs
  end
  return pts
end
local function drawTyre(x, y, w, h, wh)
  local broken, sliding = wh.b == 1, wh.e == 1
  local flat = not broken and wh.fl == 1
  local airborne = not broken and wh.a == 1
  local grip = clamp(wh.g or 0, 0, 1)
  local lw = clamp(w * 0.16, 1, 3.5)
  local s = wh.s or 0
  local cs, sn = cos(s), sin(s)
  D.poly(quad(x, y, w / 2, h / 2, cs, sn), STYLE.tyreBg)
  if not broken then
    local inset = w > 8 and 2 or 1
    local iw, ih = w - lw * 2 - inset, h - lw * 2 - inset
    if iw > 0 and ih > 0 then
      local fh = (sliding or airborne) and ih or ih * grip
      local fill = airborne and STYLE.airborne or (sliding and slideColour(wh.ex) or STYLE.gripFill)
      if fh > 0.3 then D.poly(quad(x, y, iw / 2, fh / 2, cs, sn), fill) end
      local lf = airborne and 0 or clamp(wh.lf or 0, 0, 1)
      if lf > 0 then
        D.poly(quad(x, y, iw / 2, ih / 2, cs, sn), mix(STYLE.airLight, STYLE.airLight, 0, lf * lf * (3 - 2 * lf)))
      end
    end
  end
  local outline = broken and STYLE.broken or torqueColour(wh.t)
  local pts = quad(x, y, w / 2 - lw / 2, h / 2 - lw / 2, cs, sn)
  if broken or flat then
    local on, off = 3, 3
    if flat then on, off = max(2, h * 0.12), max(1.5, h * 0.08) end
    for k = 1, 8, 2 do
      local n = (k + 1) % 8 + 1
      D.dashed(pts[k], pts[k + 1], pts[n], pts[n + 1], outline, lw, on, off)
    end
  else
    D.polyline(pts, outline, lw, true)
  end
end

-- ===== Drivetrain ===========================================================
local function drawEngine(p, ew, eh)
  D.rectFilled(p.x - ew / 2, p.y - eh / 2, p.x + ew / 2, p.y + eh / 2, DRIVETRAIN.engine, min(4, eh * 0.2))
  D.rect(p.x - ew / 2, p.y - eh / 2, p.x + ew / 2, p.y + eh / 2, DRIVETRAIN.engineEdge, 1.5, min(4, eh * 0.2))
  for k = 1, 3 do
    local yy = p.y - eh / 2 + eh * k / 4
    D.line(p.x - ew * 0.32, yy, p.x + ew * 0.32, yy, rgbm(0, 0, 0, 0.35), 1)
  end
end
local function drawDiff(p, d, st)
  local x0, y0 = p.x - d / 2, p.y - d / 2
  if st == 'locked' then
    D.rectFilled(x0, y0, x0 + d, y0 + d, DRIVETRAIN.diff)
    D.rect(x0 + 0.5, y0 + 0.5, x0 + d - 0.5, y0 + d - 0.5, DRIVETRAIN.engineEdge, 1)
  else
    local lw = clamp(d * 0.16, 1.2, 2)
    D.rectFilled(x0, y0, x0 + d, y0 + d, DRIVETRAIN.diffBg)
    D.rect(x0 + lw / 2, y0 + lw / 2, x0 + d - lw / 2, y0 + d - lw / 2, DRIVETRAIN.diff, lw)
    if st == 'lsd' then
      local c = max(2, d * 0.34)
      D.rectFilled(p.x - c / 2, p.y - c / 2, p.x + c / 2, p.y + c / 2, DRIVETRAIN.diff)
    end
  end
end
local function drawGearbox(p, size)
  local r = min(3, size * 0.2)
  D.rectFilled(p.x - size / 2, p.y - size / 2, p.x + size / 2, p.y + size / 2, DRIVETRAIN.gearbox, r)
  D.rect(p.x - size / 2, p.y - size / 2, p.x + size / 2, p.y + size / 2, DRIVETRAIN.engineEdge, 1.2, r)
  local g, th, c = size * 0.24, max(1, size * 0.09), rgbm(0, 0, 0, 0.6)
  D.line(p.x - g, p.y - g, p.x - g, p.y + g, c, th)
  D.line(p.x + g, p.y - g, p.x + g, p.y + g, c, th)
  D.line(p.x - g, p.y, p.x + g, p.y, c, th)
end

-- The drivetrain under the tyres: parts spread so none overlaps another (engines, gearboxes and
-- centre diffs move fore and aft only; axle diffs stay put), then the shafts, never diagonal,
-- tinted by the torque reaching the wheels they feed, then the parts on top.
local function drawDrivetrain(body, g, map, s, wheelPoint, tyreBox)
  local nodes = {}
  for k, n in ipairs(body.nodes) do
    nodes[k] = { k = n.k, p = n.p, x = n.x, y = n.y, w = n.w, st = n.st, axle = n.axle }
  end
  local wheelByIdx = {}
  for _, w in ipairs(body.w) do wheelByIdx[w.i] = w end
  for _, n in ipairs(nodes) do
    n.parent = n.p > 0 and nodes[n.p] or nil
    n.kids = {}
  end
  for _, n in ipairs(nodes) do if n.parent then table.insert(n.parent.kids, n) end end
  local function under(n)
    if n.ws then return n.ws end
    local list = {}
    if n.k == 'wheel' then list[1] = wheelByIdx[n.w]
    else for _, c in ipairs(n.kids) do for _, w in ipairs(under(c)) do list[#list + 1] = w end end end
    n.ws = list
    return list
  end
  local drivenWidth = clamp(0.09 * s, 2, 4.5)
  local ew, eh = clamp(ENGINE_W * s, 12, 34), clamp(ENGINE_H * s, 9, 26)
  local diffPx, gbPx = clamp(DIFF * s, 6, 12), clamp(GB_SIZE * s, 9, 18)
  for _, n in ipairs(nodes) do
    under(n)
    if n.k == 'wheel' then local wp = wheelPoint(wheelByIdx[n.w]); n.pt = { x = wp.x, y = wp.y }
    else n.pt = map(n.x, n.y) end
  end

  -- spread the parts so none overlaps another (the BeamNG app's rules)
  do
    local GAP, items = 3, {}
    for _, n in ipairs(nodes) do
      local it
      if n.k == 'src' then it = { n = n, hw = ew / 2, hh = eh / 2 }
      elseif n.k == 'gb' then it = { n = n, hw = gbPx / 2, hh = gbPx / 2 }
      elseif n.k == 'diff' then it = { n = n, hw = diffPx / 2, hh = diffPx / 2, fixed = n.axle and true or false } end
      if it then items[#items + 1] = it end
    end
    local top, bottom = map(g.cx, g.box.y1).y, map(g.cx, g.box.y0).y
    local midY = (top + bottom) / 2
    local function isAncestor(a, b) local m = b.parent while m do if m == a then return true end m = m.parent end return false end
    local function wheelsY(n)
      local list = n.ws or {}
      if #list == 0 then return midY end
      local sy = 0 for _, w in ipairs(list) do sy = sy + w.y end
      return map(0, sy / #list).y
    end
    local function awayDir(a, b)
      if isAncestor(a.n, b.n) then return wheelsY(b.n) >= a.n.pt.y and 1 or -1 end
      if isAncestor(b.n, a.n) then return wheelsY(a.n) >= b.n.pt.y and -1 or 1 end
      if b.n.pt.y <= midY then return a.n.pt.y <= b.n.pt.y and 1 or -1 end
      return a.n.pt.y >= b.n.pt.y and -1 or 1
    end
    local function clampY(it)
      local lo, hi = top + it.hh + 2, bottom - it.hh - 2
      if lo < hi then it.n.pt.y = clamp(it.n.pt.y, lo, hi) end
    end
    local function overlap(a, b)
      return abs(b.n.pt.x - a.n.pt.x) < a.hw + b.hw + GAP - 0.5 and abs(b.n.pt.y - a.n.pt.y) < a.hh + b.hh + GAP - 0.5
    end
    local function relax()
      for _ = 1, 80 do
        local moved = false
        for i = 1, #items do
          for j = i + 1, #items do
            local a, b = items[i], items[j]
            if not (a.fixed and b.fixed) then
              local dx, dy = b.n.pt.x - a.n.pt.x, b.n.pt.y - a.n.pt.y
              if abs(dx) < a.hw + b.hw + GAP then
                local need = a.hh + b.hh + GAP - abs(dy)
                if need > 0.01 then
                  local dir = abs(dy) > 0.5 and (dy > 0 and 1 or -1) or awayDir(a, b)
                  if a.fixed then b.n.pt.y = b.n.pt.y + dir * need
                  elseif b.fixed then a.n.pt.y = a.n.pt.y - dir * need
                  else a.n.pt.y, b.n.pt.y = a.n.pt.y - dir * need / 2, b.n.pt.y + dir * need / 2 end
                  if not a.fixed then clampY(a) end
                  if not b.fixed then clampY(b) end
                  moved = true
                end
              end
            end
          end
        end
        if not moved then break end
      end
    end
    relax()
    local function nearestFixed(it)
      local best
      for _, f in ipairs(items) do
        if f.fixed and abs(f.n.pt.x - it.n.pt.x) < f.hw + it.hw + GAP then
          if not best or abs(f.n.pt.y - it.n.pt.y) < abs(best.n.pt.y - it.n.pt.y) then best = f end
        end
      end
      return best
    end
    for _ = 1, #items do
      local flip
      for i = 1, #items do
        for j = i + 1, #items do
          local a, b = items[i], items[j]
          if not (a.fixed and b.fixed) and overlap(a, b) then
            for _, it in ipairs({ a, b }) do
              if not it.fixed and not it.flipped then
                local f = nearestFixed(it)
                if f then
                  local d = abs(f.n.pt.y - it.n.pt.y)
                  if not flip or d < flip.d then flip = { it = it, f = f, d = d } end
                end
              end
            end
          end
        end
      end
      if not flip then break end
      local side = flip.it.n.pt.y >= flip.f.n.pt.y and -1 or 1
      flip.it.n.pt.y = flip.f.n.pt.y + side * (flip.it.hh + flip.f.hh + GAP)
      clampY(flip.it)
      flip.it.flipped = true
      relax()
    end
  end

  -- shafts
  for _, n in ipairs(nodes) do
    local P = n.parent
    if P then
      local a = P.pt
      local b = (n.k == 'wheel' and P.k == 'diff' and P.axle) and { x = n.pt.x, y = P.pt.y } or n.pt
      local pts = { { x = a.x, y = a.y } }
      if abs(b.x - a.x) > 0.5 and abs(b.y - a.y) > 0.5 then pts[#pts + 1] = { x = a.x, y = b.y } end
      pts[#pts + 1] = { x = b.x, y = b.y }
      if n.k == 'wheel' then
        local wh = wheelByIdx[n.w]
        local own = tyreBox(wh)
        local from, e = pts[#pts - 1], pts[#pts]
        if abs(from.y - b.y) <= 0.5 then
          local toRight = from.x < own.x
          e.x = toRight and (own.x - own.hx) or (own.x + own.hx)
          if (toRight and e.x < from.x) or (not toRight and e.x > from.x) then e.x = from.x end
        else
          e.x = own.x
          if #pts > 2 then pts[#pts - 1].x = own.x end
          local down = from.y < own.y
          e.y = own.y + (down and -own.hy or own.hy)
          if (down and e.y < from.y) or (not down and e.y > from.y) then e.y = from.y end
        end
      end
      local torque, cnt = 0, 0
      for _, w in ipairs(n.ws or {}) do torque, cnt = torque + (w.dr or 0), cnt + 1 end
      torque = cnt > 0 and torque / cnt or 0
      local c = torqueColour(torque * 0.7)
      for q = 2, #pts do D.line(pts[q - 1].x, pts[q - 1].y, pts[q].x, pts[q].y, c, drivenWidth) end
      -- square joint where a shaft turns
      if #pts == 3 then D.rectFilled(pts[2].x - drivenWidth / 2, pts[2].y - drivenWidth / 2, pts[2].x + drivenWidth / 2, pts[2].y + drivenWidth / 2, c) end
    end
  end
  -- engines, then gearboxes, then differentials on top; the traction-control dot last
  local tcDot
  for _, n in ipairs(nodes) do
    if n.k == 'src' then
      drawEngine(n.pt, ew, eh)
      local src = body.sources[1]
      if src and src.tc then tcDot = { p = n.pt, r = clamp(min(ew, eh) * 0.17, 2, 3.6) } end
    end
  end
  for _, n in ipairs(nodes) do if n.k == 'gb' then drawGearbox(n.pt, gbPx) end end
  for _, n in ipairs(nodes) do if n.k == 'diff' then drawDiff(n.pt, diffPx, n.st) end end
  if tcDot then
    D.circleFilled(tcDot.p.x, tcDot.p.y, tcDot.r, ASSIST[2])
    D.circle(tcDot.p.x, tcDot.p.y, tcDot.r, rgbm(10 / 255, 12 / 255, 16 / 255, 0.75), 0.8)
  end
end

-- ===== Assist dots ==========================================================
local function drawAssistDots(body, wheelPoint, dims)
  for _, w in ipairs(body.w) do
    local c = ASSIST[w.iv or 0]
    if c then
      local p, d = wheelPoint(w), dims(w)
      local r = dotRadius(d.w)
      local gap = max(3, r)
      local reach = d.w / 2 + abs(sin(w.s or 0)) * d.h / 2 + gap + r
      D.circleFilled(p.x + (w._side < 0 and -reach or reach), p.y, r, c)
    end
  end
end

-- ===== Numbers mode =========================================================
local READ_MS = 150
local read = { acc = {}, val = {}, t0 = 0 }
local function readAdd(key, v)
  if v == nil or v ~= v then return end
  local a = read.acc[key]
  if not a then a = { s = 0, n = 0 } read.acc[key] = a end
  a.s, a.n = a.s + v, a.n + 1
  if read.val[key] == nil then read.val[key] = v end
end
local function readTick(now)
  if now - read.t0 < READ_MS then return end
  read.t0 = now
  for k, a in pairs(read.acc) do
    if a.n > 0 then read.val[k], a.s, a.n = a.s / a.n, 0, 0
    else read.val[k], read.acc[k] = nil, nil end
  end
end
local function readGet(key, fallback) local v = read.val[key] if v == nil then return fallback end return v end

local DIM_TEXT = col(255, 255, 255, 0.55)
local function cornerFont(tyreH) return clamp(tyreH * 0.33, 10, 15) end
local function fmt(v, d)
  if v == nil or v ~= v then return '–' end
  local s = string.format('%.' .. (d or 0) .. 'f', v)
  if s:match('^%-0%.?0*$') then s = s:sub(2) end
  return (s:gsub('%-', '−'))
end

local function drawCornerReadouts(body, wheelPoint, dims, circle, units)
  local blocks = {}
  for _, wh in ipairs(body.w) do
    local grip = readGet('w' .. wh.i .. '.g', wh.g or 0)
    local load = wh.fz and readGet('w' .. wh.i .. '.fz', wh.fz) or nil
    local pt, d = wheelPoint(wh), dims(wh)
    local onLeft = wh._side < 0
    local fs = cornerFont(d.h)
    local small = fs * 0.88
    local lines = {}
    local gc
    if wh.a == 1 then gc = STYLE.airborne
    elseif (wh.lf or 0) >= 0.5 then gc = mix(STYLE.airLight, STYLE.airLight, 0)
    elseif wh.e == 1 then gc = slideColour(wh.ex)
    else gc = STYLE.text end
    lines[1] = { s = (grip >= 3 and '300+' or floor(grip * 100 + 0.5)) .. '%', px = fs, w = 600, c = gc }
    if load and not circle.compact then
      local kg = max(0, load) / 9.81
      local v, u = kg, 'kg'
      if units == 'lb' then v, u = kg * 2.20462262, 'lb' end
      lines[2] = { s = fmt(v, 0) .. ' ' .. u, px = small, w = 400, c = DIM_TEXT }
    end
    local widest, height = 0, 0
    for _, l in ipairs(lines) do l.width = D.measure(l.s, l.px, l.w); widest = max(widest, l.width); height = height + l.px * 1.2 end
    blocks[#blocks + 1] = { wh = wh, pt = pt, d = d, onLeft = onLeft, lines = lines, widest = widest, height = height, y0 = pt.y - height / 2 }
  end
  for _, b in ipairs(blocks) do
    local wh, pt, d = b.wh, b.pt, b.d
    local r = dotRadius(d.w)
    local clear = d.w / 2 + abs(sin(wh.s or 0)) * d.h / 2 + max(3, r) + 2 * r + 4
    local tx, align = b.onLeft and pt.x - clear or pt.x + clear, b.onLeft and 'right' or 'left'
    local y0 = b.y0
    local worst = max(abs(y0 - circle.cy), abs(y0 + b.height - circle.cy))
    local half = sqrt(max(0, circle.r * circle.r - worst * worst)) - 3
    local reachX = d.w / 2 + abs(sin(wh.s or 0)) * d.h / 2 + 2
    if b.onLeft then
      tx = max(tx, circle.cx - half + b.widest)
      if tx > pt.x - reachX then tx, align = pt.x + reachX + 2, 'left' end
    else
      tx = min(tx, circle.cx + half - b.widest)
      if tx < pt.x + reachX then tx, align = pt.x - reachX - 2, 'right' end
    end
    local y = y0
    for _, l in ipairs(b.lines) do
      y = y + l.px * 1.2
      D.text(l.s, tx, y - l.px * 0.24, l.px, l.w, l.c, align, true)
    end
  end
end

local function balanceFont(rPx) return clamp(rPx * 0.058, 8.5, 11) end
local function degreeFont(rPx) return balanceFont(rPx) * 1.15 end
local STATE_WORD = { near = 'Front near limit', rnear = 'Rear near limit', limit = 'At the limit', under = 'Understeer',
                     over = 'Oversteer', drift = 'Controlled drift', pslide = 'Controlled powerslide' }
local SHORT_WORD = { ['Understeer'] = 'Under', ['Front near limit'] = 'Front near', ['Rear near limit'] = 'Rear near',
                     ['At the limit'] = 'At limit', ['Oversteer'] = 'Over', ['Controlled drift'] = 'Drift', ['Controlled powerslide'] = 'Powerslide' }
local function chordDrop(inner, width)
  local half = width / 2 + 4
  if half >= inner then return inner end
  return inner - sqrt(inner * inner - half * half)
end
local function balanceLayout(rPx, inner, compact)
  local fs, dfs = balanceFont(rPx), degreeFont(rPx)
  local h1, h2 = dfs, fs * 1.15
  local w1 = D.measure('88.8°', dfs, 700)
  local w2 = D.measure(compact and 'Powerslide' or 'Controlled powerslide', fs, 600)
  local drop = max(chordDrop(inner, w1), chordDrop(inner, w2) - h1) + 1
  return { fs = fs, dfs = dfs, drop = drop, h1 = h1, band = drop + h1 + h2 + fs * 0.25 }
end
local function drawBalance(body, cx, cy, inner, rPx, compact, mk)
  local st = mk.state
  if not st then return end
  local vd = body.vd or {}
  local diff
  if vd.af and vd.ar then diff = readGet('bal', (vd.af - vd.ar) * 180 / pi) end
  if st == 'pslide' and vd.sl then diff = readGet('sl', vd.sl * 180 / pi) end
  local word = STATE_WORD[st]
  if compact then word = SHORT_WORD[word] or word end
  local c = rgbm(mk.rgb[1] / 255, mk.rgb[2] / 255, mk.rgb[3] / 255, 1)
  local L = balanceLayout(rPx, inner, compact)
  local top = cy - inner + L.drop
  if diff then D.text(fmt(abs(diff), 1) .. '°', cx, top + L.dfs * 0.9, L.dfs, 700, c, 'center', true) end
  D.text(word, cx, top + L.h1 + L.fs, L.fs, 600, c, 'center', true)
end

-- how much smaller the car is drawn in numbers mode so every readout fits inside the circle
local function readoutShrink(body, g, scale, inner, band, compact)
  local sample, nLines = compact and '100%' or '1888 kg', compact and 1 or 2
  local k = 1
  while k >= 0.35 do
    local s2 = scale * k
    local ok = g.boxHalfH * s2 <= inner - band - 2
    for _, w in ipairs(body.w) do
      if not ok then break end
      local tw, th = max(w._wd * s2, MIN_TYRE_W), max(w._len * s2, MIN_TYRE_L)
      local fs = cornerFont(th)
      local textW = D.measure(sample, compact and fs or fs * 0.88, compact and 600 or 400)
      local textH = fs * 1.2 * nLines
      local x = abs(w._mx - g.cx) * s2 + tw / 2 + dotRadius(tw) * 3 + 7 + textW
      local y = abs(w.y - g.cy) * s2 + textH / 2
      if x * x + y * y > (inner - 3) * (inner - 3) then ok = false end
      if w.y > g.cy and (w.y - g.cy) * s2 + textH / 2 > inner - band - 2 then ok = false end
    end
    if ok then return k end
    k = k - 0.025
  end
  return 0.35
end

-- ===== Frame ================================================================
local geoCache = { body = nil, geo = nil }
local shrinkCache = {}
local COMPACT_BELOW = 62

local function drawEmpty(W, H, msg)
  local r = min(W, H) / 2 - 2
  D.circleFilled(W / 2, H / 2, r, STYLE.panelFill)
  D.circle(W / 2, H / 2, r, STYLE.panelStroke, 1.5)
  D.text('VGS', W / 2, H / 2 - r * 0.02, clamp(r * 0.16, 10, 18), 600, col(255, 255, 255, 0.45), 'center')
  D.text(msg or 'waiting for car', W / 2, H / 2 + r * 0.16, clamp(r * 0.09, 8, 12), 400, col(255, 255, 255, 0.45), 'center')
end

-- body: telemetry output (or nil); W, H: the window's size; dtMs: time since the last frame;
-- opts: { numbers = bool, units = 'kg'|'lb', message = string }
function R.draw(body, W, H, dtMs, opts)
  MS.now = MS.now + (dtMs or 16)
  opts = opts or {}
  if not body then
    trail, markState, geoCache.body = {}, nil, nil
    drawEmpty(W, H, opts.message)
    return
  end
  if geoCache.body ~= body or geoCache.id ~= body.id or geoCache.nodes ~= body.nodes then
    geoCache.body, geoCache.id, geoCache.nodes, geoCache.geo = body, body.id, body.nodes, geometry(body)
    trail = {}
  end
  local g = geoCache.geo
  local rPx = max(4, min(W, H) / 2 - 2)
  local ccx, ccy = W / 2, H / 2
  local inner = rPx - clamp(rPx * 0.05, 3, 7) - markerSize(rPx) - 2
  local compact = rPx < COMPACT_BELOW
  local band = opts.numbers and balanceLayout(rPx, inner, compact).band or 0

  D.circleFilled(ccx, ccy, rPx, STYLE.panelFill)
  D.circle(ccx, ccy, rPx, STYLE.panelStroke, 1.5)
  local mk = markerState(body.inp)
  drawInputArcs(ccx, ccy, rPx, body.inp, mk)

  local scale = inner / g.fitR
  if opts.numbers then
    local key = string.format('%.4f|%.2f|%s', scale, inner, tostring(compact))
    if shrinkCache.geo ~= g or shrinkCache.key ~= key then
      local k = readoutShrink(body, g, scale, inner, band, compact)
      local cmp = compact
      -- the full readouts would squeeze the car to nothing: show just the grip, short words
      if k < 0.6 and not compact then
        cmp = true
        k = readoutShrink(body, g, scale, inner, balanceLayout(rPx, inner, true).band, true)
      end
      shrinkCache.geo, shrinkCache.key, shrinkCache.k, shrinkCache.compact = g, key, k, cmp
    end
    scale = scale * shrinkCache.k
    if shrinkCache.compact ~= compact then
      compact = shrinkCache.compact
      band = balanceLayout(rPx, inner, compact).band
    end
  end
  local function map(x, y) return { x = ccx + (x - g.cx) * scale, y = ccy - (y - g.cy) * scale } end
  local function dims(w) return { w = max(w._wd * scale, MIN_TYRE_W), h = max(w._len * scale, MIN_TYRE_L) } end
  local function wheelPoint(w) return map(w._mx, w.y) end
  local function tyreBox(w)
    local pt, d, st = wheelPoint(w), dims(w), w.s or 0
    local c, sn = abs(cos(st)), abs(sin(st))
    return { x = pt.x, y = pt.y,
             hx = min(c > 1e-6 and d.w / 2 / c or math.huge, sn > 1e-6 and d.h / 2 / sn or math.huge),
             hy = min(c > 1e-6 and d.h / 2 / c or math.huge, sn > 1e-6 and d.w / 2 / sn or math.huge) }
  end

  if g.hasExt then
    local hw, hh = g.boxHalfW * scale, g.boxHalfH * scale
    D.rect(ccx - hw, ccy - hh, ccx + hw, ccy + hh, STYLE.panelStroke, 1, min(6, hw * 0.2))
  end
  if opts.drivetrain ~= false then drawDrivetrain(body, g, map, scale, wheelPoint, tyreBox) end
  if body.gf then drawGForce(ccx, ccy, rPx, body.gf) end
  for _, w in ipairs(body.w) do
    local pt, d = wheelPoint(w), dims(w)
    drawTyre(pt.x, pt.y, d.w, d.h, w)
  end
  drawAssistDots(body, wheelPoint, dims)

  if opts.numbers then
    for _, w in ipairs(body.w) do
      readAdd('w' .. w.i .. '.g', w.g)
      if w.fz then readAdd('w' .. w.i .. '.fz', w.fz) end
    end
    local vd = body.vd
    if vd and vd.af and vd.ar then readAdd('bal', (vd.af - vd.ar) * 180 / pi) end
    if vd and vd.sl then readAdd('sl', vd.sl * 180 / pi) end
    readTick(MS.now)
    local circle = { cx = ccx, cy = ccy, r = inner, compact = compact }
    drawCornerReadouts(body, wheelPoint, dims, circle, opts.units)
    drawBalance(body, ccx, ccy, inner, rPx, compact, mk)
  end
end

function R.reset() trail, markState, geoCache.body = {}, nil, nil end

return R
