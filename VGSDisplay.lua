-- VGS Display for Assetto Corsa (Custom Shaders Patch Lua app)
-- ---------------------------------------------------------------------------
-- A live grip display inspired by the VGS in Enthusia Professional Racing, ported from the
-- BeamNG.drive version. Click the app for the numbers mode; the settings (the cog on the app's
-- title bar) hold the units, the engine position and a few diagnostics.
-- ---------------------------------------------------------------------------

local T = require('src/telemetry')
local R = require('src/render')

local sim = ac.getSim()
local config = ac.storage({
  numbers = false,      -- numbers mode (click the app)
  units = 1,            -- 1 = kg, 2 = lb
  engine = 1,           -- 1 = auto, 2 = front, 3 = mid, 4 = rear, 5 = transverse (front-wheel drive)
  drivetrain = true,    -- draw the drivetrain under the wheels
})
local ENGINE = { 'auto', 'front', 'mid', 'rear', 'transverse' }

local press = nil
local err = { msg = nil, count = 0, next = 0 }

local function report(where, e)
  err.count = err.count + 1
  err.msg = tostring(e)
  if os.clock() >= err.next then
    err.next = os.clock() + 10
    if ac.log then ac.log('VGS Display: ' .. where .. ' failed (' .. err.count .. 'x): ' .. err.msg) end
  end
end

local function handleClick()
  local L = ui.MouseButton and ui.MouseButton.Left or 0
  if ui.windowHovered() and ui.mouseClicked(L) then
    local p = ui.mousePos()
    press = { x = p.x, y = p.y }
  end
  if press and ui.mouseReleased(L) then
    local p = ui.mousePos()
    if math.abs(p.x - press.x) + math.abs(p.y - press.y) < 4 then config.numbers = not config.numbers end
    press = nil
  end
end

function script.windowMain(dt)
  local car = ac.getCar(sim.focusedCar) or ac.getCar(0)
  local okP, paused = pcall(function() return sim.isPaused end)
  local stepDt = (okP and paused) and 0 or dt
  local body, why
  local ok, e = pcall(function()
    body, why = T.update(car, stepDt, { engine = ENGINE[config.engine] or 'auto', detail = config.numbers })
  end)
  if not ok then
    report('update', e)
    pcall(T.reset)
    body, why = nil, 'error: see the Lua debug log'
  end
  local size = ui.windowSize()
  local okD, eD = pcall(R.draw, body, size.x, size.y, dt * 1000, {
    numbers = config.numbers, units = config.units == 2 and 'lb' or 'kg',
    drivetrain = config.drivetrain, message = why,
  })
  if not okD then report('draw', eD); pcall(R.reset) end
  handleClick()
end

local function fmtNum(v, d) if type(v) ~= 'number' then return '–' end return string.format('%.' .. (d or 2) .. 'f', v) end
local STATE_NAME = { [0] = 'neutral', 'front near limit', 'understeer', 'rear near limit', 'at the limit', 'oversteer / drift', 'controlled powerslide' }

function script.windowSettings(dt)
  ui.header('Display')
  if ui.checkbox('Numbers mode (or click the app)', config.numbers) then config.numbers = not config.numbers end
  if ui.checkbox('Show the drivetrain', config.drivetrain) then config.drivetrain = not config.drivetrain end
  ui.text('Weight unit')
  config.units = ui.combo('##units', config.units, ui.ComboFlags and ui.ComboFlags.None or 0, { 'kg', 'lb' })
  ui.offsetCursorY(8)
  ui.header('Engine position')
  ui.textWrapped('AC doesn\'t say where a car\'s engine sits, so it\'s placed from the weight distribution. Pick it here if that guesses wrong.')
  config.engine = ui.combo('##engine', config.engine, ui.ComboFlags and ui.ComboFlags.None or 0,
    { 'Automatic', 'Front', 'Mid (ahead of the rear axle)', 'Rear (behind the rear axle)', 'Transverse, at the front' })
  ui.offsetCursorY(8)
  ui.header('Diagnostics')
  local d = T.diag()
  if d then
    ui.text(string.format('Drive: %s, engine: %s, weight on the front: %s', d.layout, d.engine, d.cg and string.format('%.0f %%', d.cg * 100) or 'unknown'))
    ui.text(string.format('Wheelbase %.2f m, full lock %.1f deg (learnt)', d.wb, math.deg(d.lock)))
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
