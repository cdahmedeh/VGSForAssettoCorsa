-- VGS Display for Assetto Corsa (Custom Shaders Patch Lua app)
-- ---------------------------------------------------------------------------
-- A live grip display inspired by the VGS in Enthusia Professional Racing, ported from the
-- BeamNG.drive version. The settings (the cog on the app's title bar) hold the engine position,
-- whether to draw the drivetrain, and a few diagnostics.
-- ---------------------------------------------------------------------------

local T = require('src/telemetry')
local R = require('src/render')

local sim = ac.getSim()
local config = ac.storage({
  engine = 1,           -- 1 = auto, 2 = front, 3 = mid, 4 = rear, 5 = transverse (front-wheel drive)
  drivetrain = true,    -- draw the drivetrain under the wheels
})
local ENGINE = { 'auto', 'front', 'mid', 'rear', 'transverse' }

local err = { msg = nil, count = 0, next = 0 }

local function report(where, e)
  err.count = err.count + 1
  err.msg = tostring(e)
  if os.clock() >= err.next then
    err.next = os.clock() + 10
    if ac.log then ac.log('VGS Display: ' .. where .. ' failed (' .. err.count .. 'x): ' .. err.msg) end
  end
end

function script.windowMain(dt)
  local car = ac.getCar(sim.focusedCar) or ac.getCar(0)
  local okP, paused = pcall(function() return sim.isPaused end)
  local stepDt = (okP and paused) and 0 or dt
  local body, why
  local ok, e = pcall(function()
    body, why = T.update(car, stepDt, { engine = ENGINE[config.engine] or 'auto' })
  end)
  if not ok then
    report('update', e)
    pcall(T.reset)
    body, why = nil, 'error: see the Lua debug log'
  end
  local size = ui.windowSize()
  local okD, eD = pcall(R.draw, body, size.x, size.y, dt * 1000, {
    drivetrain = config.drivetrain, message = why,
  })
  if not okD then report('draw', eD); pcall(R.reset) end
end

local function fmtNum(v, d) if type(v) ~= 'number' then return '–' end return string.format('%.' .. (d or 2) .. 'f', v) end
local STATE_NAME = { [0] = 'neutral', 'front near limit', 'understeer', 'rear near limit', 'at the limit', 'oversteer / drift', 'powerslide' }

function script.windowSettings(dt)
  ui.header('Display')
  if ui.checkbox('Show the drivetrain', config.drivetrain) then config.drivetrain = not config.drivetrain end
  ui.offsetCursorY(8)
  ui.header('Engine position')
  ui.textWrapped('AC doesn\'t say where a car\'s engine sits. It\'s placed from the car\'s tags, its maker and model, its description, or else its weight distribution. Pick it here if that guesses wrong.')
  config.engine = ui.combo('##engine', config.engine, ui.ComboFlags and ui.ComboFlags.None or 0,
    { 'Automatic', 'Front', 'Mid (ahead of the rear axle)', 'Rear (behind the rear axle)', 'Transverse, at the front' })
  ui.offsetCursorY(8)
  ui.header('Diagnostics')
  local d = T.diag()
  if d then
    ui.text(string.format('Drive: %s, engine: %s (%s), weight on the front: %s', d.layout, d.engine, d.engineFrom or '?', d.cg and string.format('%.0f %%', d.cg * 100) or 'unknown'))
    ui.text(string.format('Wheelbase %.2f m, full lock %.1f deg (%s)', d.wb, math.deg(d.lock), d.lockKnown and 'car.ini, then learnt' or 'learnt'))
    ui.text(string.format('Peak slip ratio (learnt): front %s, rear %s', fmtNum(d.srPeakF, 3), fmtNum(d.srPeakR, 3)))
    ui.text(string.format('Near limit (ndSlip): front %s, rear %s', fmtNum(d.pF), fmtNum(d.pR)))
    ui.text(string.format('Slip angle: front %s deg, rear %s deg', fmtNum(d.slipF and math.deg(d.slipF), 1), fmtNum(d.slipR and math.deg(d.slipR), 1)))
    ui.text(string.format('Yaw rate %s rad/s, state: %s', fmtNum(d.yaw), STATE_NAME[d.state] or '?'))
    ui.text(string.format('Drift angle (rear tyres) %s deg: %s', fmtNum(d.driftAngle, 0), d.drifting and 'drifting' or 'not drifting'))
    ui.text(string.format('Signs learnt: steering %d, slip ratio %d, yaw %d', d.steerSign, d.srSign, d.yawSign))
  else
    ui.text('No car yet.')
  end
  if err.msg then
    ui.offsetCursorY(4)
    ui.textWrapped('Last error (' .. err.count .. 'x): ' .. err.msg)
  end
end
