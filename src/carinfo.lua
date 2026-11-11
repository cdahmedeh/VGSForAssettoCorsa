-- VGS Display for Assetto Corsa : where a car's engine sits
-- ---------------------------------------------------------------------------
-- AC's data files don't say where the engine is. The weight distribution alone can't tell a
-- mid-engined Lotus (38 % on the front) from a rear-engined Porsche (39 %), or a front-mid
-- Ferrari F12 (46 %) from a mid-engined Cayman (45 %). So, in order:
--   1. the car's tags (ui_car.json) if they say it ("mid-engine", "rear-engine", ...)
--   2. the car's maker and model (folder name and display name): a table of the models that
--      aren't front-engined, and of front-engined ones whose weight sits far enough back to fool
--      the weight rule
--   3. its description (ui_car.json), if it names one position only
--   4. the weight distribution (the caller's fallback)
-- ---------------------------------------------------------------------------
local M = {}

local function norm(s)
  s = tostring(s or ''):lower()
  s = s:gsub('[_%-/%.,;:%(%)%[%]"\']', ' ')
  s = s:gsub('%s+', ' ')
  return ' ' .. s .. ' '
end
M.norm = norm

-- plain substring tests (no patterns), on the normalised text
local function has(s, list)
  for _, k in ipairs(list) do
    if s:find(k, 1, true) then return true end
  end
  return false
end

-- Per maker: { mid = {...}, front = {...}, rear = {...}, default = ... }. Checked in the order
-- mid, rear, front; a maker's default applies when none matches.
local MAKERS = {
  { names = { ' ferrari ' },
    mid = { ' 458 ', ' 488 ', ' f8 ', ' sf90 ', ' 296 ', ' 308 ', ' 328 ', ' 348 ', ' 355 ', ' f355 ', ' 360 ', ' 430 ', ' f430 ', ' dino ',
            ' testarossa ', ' 512 ', ' 288 ', ' f40 ', ' f50 ', ' enzo ', ' laferrari ', ' fxx ', ' fxxk ', ' 330 p4 ', ' 312 ', ' 312t ',
            ' f2004 ', ' f138 ', ' sf15t ', ' sf16h ', ' sf70h ', ' sf71h ', ' sf1000 ', ' f1 ', ' 499p ', ' 333 sp ', ' 333sp ', ' challenge ',
            ' monza sp ', ' daytona sp3 ', ' 412 p ' },
    front = { ' 812 ', ' f12 ', ' f12tdf ', ' 599 ', ' 550 ', ' 575 ', ' 612 ', ' gtc4 ', ' roma ', ' portofino ', ' california ',
              ' 250 ', ' 275 ', ' 365 gtb ', ' purosangue ', ' 456 ', ' ff ' } },
  { names = { ' porsche ' },
    mid = { ' cayman ', ' boxster ', ' 718 ', ' 918 ', ' 919 ', ' 917 ', ' 962 ', ' 962c ', ' 956 ', ' 908 ', ' carrera gt ', ' gt1 ',
            ' rs spyder ', ' 914 ', ' 904 ', ' 906 ', ' 910 ', ' 936 ', ' 963 ', ' rsr 2017 ', ' rsr 2019 ', ' rsr 19 ', ' rsr 17 ', ' mission ' },
    front = { ' cayenne ', ' panamera ', ' macan ', ' 944 ', ' 928 ', ' 924 ', ' 968 ', ' taycan ' },
    rear = { ' 911 ', ' 930 ', ' 964 ', ' 993 ', ' 996 ', ' 997 ', ' 991 ', ' 992 ', ' 935 ', ' 934 ', ' 959 ', ' carrera ', ' gt2 ', ' gt3 ', ' 356 ' } },
  { names = { ' lamborghini ', ' lambo ' }, default = 'mid',
    front = { ' urus ', ' espada ', ' jarama ', ' lm002 ', ' islero ', ' 400 gt ', ' 350 gt ' } },
  { names = { ' mclaren ' }, default = 'mid' },
  { names = { ' pagani ' }, default = 'mid' },
  { names = { ' koenigsegg ' }, default = 'mid' },
  { names = { ' bugatti ' }, default = 'mid', front = { ' type 35 ', ' type35 ', ' type 57 ', ' royale ' } },
  { names = { ' audi ' }, mid = { ' r8 ', ' r8lms ', ' r18 ', ' r15 ', ' r10 ', ' r8c ' } },
  { names = { ' lotus ' }, mid = { ' elise ', ' exige ', ' evora ', ' eleven ', ' europa ', ' exos ', ' emira ', ' esprit ', ' 2 eleven ', ' 3 eleven ',
                                  -- the Formula 1 cars
                                  ' 18 ', ' 21 ', ' 24 ', ' 25 ', ' 33 ', ' 38 ', ' 43 ', ' 49 ', ' 49b ', ' 56 ', ' 63 ', ' 72 ', ' 72d ', ' 76 ', ' 77 ', ' 78 ', ' 79 ',
                                  ' 80 ', ' 81 ', ' 87 ', ' 88 ', ' 91 ', ' 92 ', ' 93t ', ' 94t ', ' 95t ', ' 97t ', ' 98t ', ' 99t ', ' 100t ', ' 101 ', ' 102 ', ' 107 ', ' 109 ', ' t125 ' },
    front = { ' elan ', ' seven ', ' eclat ', ' elite ', ' cortina ', ' carlton ', ' omega ' } },
  { names = { ' honda ', ' acura ' }, mid = { ' nsx ', ' s660 ', ' beat ' } },
  { names = { ' toyota ', ' lexus ' }, mid = { ' mr2 ', ' mr s ', ' mrs ', ' ts040 ', ' ts050 ', ' ts030 ', ' gt one ', ' gr010 ', ' tf10' } },
  { names = { ' ford ' }, mid = { ' gt40 ', ' ford gt ', ' gt 2017 ', ' gt le mans ', ' gt gte ', ' rs200 ' } },
  { names = { ' chevrolet ', ' chevy ', ' corvette ' }, mid = { ' c8 ', ' c8r ', ' c8 r ', ' z06 2023 ', ' corvette e ray ' }, rear = { ' corvair ' }, default = 'front' },
  { names = { ' bmw ' }, mid = { ' m1 ', ' i8 ', ' m1 procar ', ' v12 lmr ' }, default = 'front' },
  { names = { ' alfa ', ' alfa romeo ' }, mid = { ' 4c ', ' 33 stradale ', ' tz3 ', ' tipo 33 ' } },
  { names = { ' maserati ' }, mid = { ' mc12 ', ' mc20 ' }, default = 'front' },
  { names = { ' renault ', ' alpine ' }, mid = { ' clio v6 ', ' r5 turbo ', ' 5 turbo ', ' sport spider ', ' a442 ', ' a450 ', ' a470 ', ' a480 ', ' a424 ', ' rs01 ', ' a110 2017 ', ' a110 s ', ' a110 gt ', ' a110 r ', ' a110 2022 ' },
    rear = { ' 8 gordini ', ' r8 gordini ', ' dauphine ', ' 4cv ', ' twingo iii ', ' a110 1600 ', ' berlinette ', ' a310 ', ' a108 ' } },
  { names = { ' lancia ' }, mid = { ' stratos ', ' 037 ', ' delta s4 ', ' s4 ', ' lc2 ', ' lc1 ' } },
  { names = { ' peugeot ' }, mid = { ' 205 t16 ', ' t16 ', ' 905 ', ' 908 ', ' 9x8 ', ' 405 t16 ' } },
  { names = { ' nissan ', ' datsun ' }, mid = { ' r390 ', ' r89c ', ' r90c ', ' r91cp ', ' r92cp ', ' zeod ', ' deltawing ' }, default = 'front' },
  { names = { ' mazda ' }, mid = { ' 787 ', ' 787b ', ' 767 ', ' 767b ', ' 757 ', ' furai ', ' rx 792p ' }, default = 'front' },
  { names = { ' mercedes ', ' amg ' }, mid = { ' clk gtr ', ' clk lm ', ' c9 ', ' c11 ', ' amg one ', ' sauber ', ' w0' }, default = 'front' },
  { names = { ' jaguar ' }, mid = { ' xj220 ', ' xjr 9 ', ' xjr9 ', ' xjr 12 ', ' c x75 ', ' xjr 14 ' }, default = 'front' },
  { names = { ' aston ' }, mid = { ' valkyrie ', ' valhalla ', ' amr pro ' }, default = 'front' },
  { names = { ' volkswagen ', ' vw ' }, rear = { ' beetle ', ' kafer ', ' kaefer ', ' type 1 ', ' type 2 ', ' t1 ', ' t2 ', ' karmann ghia ', ' samba ' } },
  { names = { ' fiat ', ' abarth ' }, mid = { ' x1 9 ', ' x19 ' }, rear = { ' 126 ', ' 600 ', ' 850 ', ' nuova 500 ', ' 500 f ', ' 500 l 1968 ', ' 1000 tc ', ' 695 ', ' 595 ', ' 500 1957 ', ' 500 1965 ' } },
  { names = { ' skoda ' }, rear = { ' 110 r ', ' 130 rs ', ' 130 ', ' 120 ' } },
  { names = { ' smart ' }, default = 'rear' },
  { names = { ' tatra ' }, default = 'rear' },
  { names = { ' delorean ' }, default = 'rear' },
  { names = { ' ruf ' }, mid = { ' ctr3 ' }, default = 'rear' },
  { names = { ' ktm ' }, mid = { ' x bow ', ' xbow ' } },
  { names = { ' ariel ' }, default = 'mid' },
  { names = { ' bac ' }, mid = { ' mono ' } },
  { names = { ' radical ' }, default = 'mid' },
  { names = { ' praga ' }, default = 'mid' },
  { names = { ' glickenhaus ', ' scg ' }, default = 'mid' },
  { names = { ' saleen ' }, mid = { ' s7 ' } },
  { names = { ' noble ' }, default = 'mid' },
  { names = { ' gumpert ', ' apollo ' }, default = 'mid' },
  { names = { ' zenvo ' }, default = 'mid' },
  { names = { ' de tomaso ', ' detomaso ' }, mid = { ' pantera ', ' mangusta ', ' p72 ' } },
  { names = { ' mosler ' }, default = 'mid' },
  { names = { ' vector ' }, default = 'mid' },
  { names = { ' dallara ', ' tatuus ', ' formula ', ' indycar ', ' gp2 ', ' gp3 ', ' lmp1 ', ' lmp2 ', ' lmp3 ', ' lmh ', ' lmdh ', ' dpi ',
              ' prototype ', ' p4 5 ', ' kart ', ' oreca ', ' ligier js ', ' norma ', ' rf1 ', ' f1 ', ' f2 ', ' f3 ', ' fr2 0 ', ' fr3 5 ' }, default = 'mid' },
}

-- the model, from its folder name and display name (any case, any separators)
function M.fromName(text)
  local s = norm(text)
  for _, mk in ipairs(MAKERS) do
    if has(s, mk.names) then
      if mk.mid and has(s, mk.mid) then return 'mid' end
      if mk.rear and has(s, mk.rear) then return 'rear' end
      if mk.front and has(s, mk.front) then return 'front' end
      if mk.default then return mk.default end
    end
  end
  return nil
end

local TAGS = {
  mid = { ' mid engine ', ' mid engined ', ' midship ', ' mid mounted ', ' mr ' },
  rear = { ' rear engine ', ' rear engined ', ' rr ' },
  front = { ' front engine ', ' front engined ', ' front mid engine ', ' fr ', ' fmr ' },
}
local DESC = {
  mid = { ' mid engine', ' mid engined', ' midship', ' mid mounted', ' behind the driver', ' behind the cockpit' },
  rear = { ' rear engine', ' rear engined', ' rear mounted engine', ' engine in the back', ' engine at the back', ' behind the rear axle' },
  front = { ' front engine', ' front engined', ' front mid engine', ' front mid engined', ' front mounted engine' },
}

-- tags: a list of strings
function M.fromTags(tags)
  if type(tags) ~= 'table' then return nil end
  local s = ' '
  for _, t in ipairs(tags) do s = s .. norm(t) end
  for _, w in ipairs({ 'mid', 'rear', 'front' }) do
    -- 'front mid engine' is a front engine: test it before 'mid'
    if w == 'mid' and has(s, { ' front mid engine' }) then return 'front' end
    if has(s, TAGS[w]) then return w end
  end
  return nil
end

-- a description: only if it names one position (it may compare the car with others)
function M.fromDescription(desc)
  if type(desc) ~= 'string' or #desc == 0 then return nil end
  local s = norm(desc:gsub('<[^>]*>', ' '))
  local found
  local frontMid = has(s, { ' front mid engine', ' front mid mounted' })
  for _, w in ipairs({ 'mid', 'rear', 'front' }) do
    local hit = has(s, DESC[w])
    if w == 'mid' and frontMid then
      -- every 'mid' mention may be the 'front-mid' one
      local stripped = s:gsub(' front mid engine', ' '):gsub(' front mid mounted', ' ')
      hit = has(stripped, DESC.mid)
    end
    if hit then
      if found then return nil end
      found = w
    end
  end
  return found
end

-- everything CSP lets a Lua app know about the car's identity (each part is optional)
function M.identity(carIndex)
  local id, name, brand, tags, desc
  pcall(function() id = ac.getCarID(carIndex) end)
  pcall(function() name = ac.getCarName(carIndex) end)
  pcall(function() brand = ac.getCarBrand(carIndex) end)
  pcall(function()
    if id and io and io.load and ac.getFolder and ac.FolderID and ac.FolderID.ContentCars and JSON and JSON.parse then
      local raw = io.load(ac.getFolder(ac.FolderID.ContentCars) .. '/' .. id .. '/ui/ui_car.json')
      if raw then
        local j = JSON.parse(raw)
        if type(j) == 'table' then
          tags = j.tags
          desc = j.description
          name = name or j.name
          brand = brand or j.brand
        end
      end
    end
  end)
  return { id = id, name = name, brand = brand, tags = tags, desc = desc }
end

-- the engine's position from the car's identity, or nil (and where it came from)
function M.engineOf(ident)
  if not ident then return nil end
  local w = M.fromTags(ident.tags)
  if w then return w, 'tags' end
  w = M.fromName((ident.brand or '') .. ' ' .. (ident.id or '') .. ' ' .. (ident.name or ''))
  if w then return w, 'name' end
  w = M.fromDescription(ident.desc)
  if w then return w, 'description' end
  return nil
end

return M
