-- Unit tests for the plug-in's JSON module (pure Lua, no Lightroom APIs).
-- Run:  lua scripts/test-json.lua
--
-- Written for Lua 5.1 compatibility (Lightroom's runtime) but also passes on
-- newer interpreters, which is what CI/dev machines are likely to have.

package.path = 'plugin/LightroomMCPBridge.lrplugin/?.lua;' .. package.path

local Json = require 'Json'

local passed, failed = 0, 0

local function check(label, condition, detail)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    print(('FAIL  %s%s'):format(label, detail and ('  -> ' .. tostring(detail)) or ''))
  end
end

local function checkThrows(label, fn)
  local ok, err = pcall(fn)
  check(label, not ok, 'expected an error, got ' .. tostring(err))
end

-- ---------------------------------------------------------------- decoding --

local t = Json.decode('{"a":1,"b":"x","c":true,"d":false,"e":null,"f":[1,2,3]}')
check('decode numbers', t.a == 1)
check('decode strings', t.b == 'x')
check('decode true', t.c == true)
check('decode false', t.d == false)
check('decode null -> Json.null', t.e == Json.null)
check('decode array length', #t.f == 3 and t.f[3] == 3)

local nested = Json.decode('{"o":{"n":[[1,2],{"k":"v"}]}}')
check('decode nesting', nested.o.n[1][2] == 2 and nested.o.n[2].k == 'v')

local escaped = Json.decode('{"s":"line\\nbreak \\"q\\" tab\\there back\\\\slash \\/ok \\u0041"}')
check('decode escapes', escaped.s == 'line\nbreak "q" tab\there back\\slash /ok A',
  escaped.s)

local eAcute = Json.decode('{"s":"\\u00e9"}')
check('decode \\u -> utf8', eAcute.s == string.char(0xC3, 0xA9),
  eAcute.s and eAcute.s:byte(1))

local emoji = Json.decode('{"s":"\\ud83d\\ude00"}')
check('decode surrogate pair', emoji.s == string.char(0xF0, 0x9F, 0x98, 0x80),
  emoji.s and table.concat({ emoji.s:byte(1, -1) }, ','))

local bmp = Json.decode('{"s":"\\ud800\\udc00"}')
check('decode U+10000', bmp.s == string.char(0xF0, 0x90, 0x80, 0x80))

check('decode negative number', Json.decode('-17') == -17)
check('decode decimal', Json.decode('1.5') == 1.5)
check('decode exponent', Json.decode('-1.5e3') == -1500)
check('decode top-level number', Json.decode('42') == 42)
check('decode top-level string', Json.decode('"hi"') == 'hi')
check('decode top-level bool', Json.decode('true') == true)
check('decode whitespace', Json.decode('  {  "a" :  1  }  ').a == 1)
check('decode empty object', next(Json.decode('{}')) == nil)

-- null inside an object must survive assignment (hence the sentinel)
local withNull = Json.decode('{"a":null,"b":1}')
check('null member survives', withNull.a == Json.null and withNull.b == 1)

-- null inside an array stays a table entry
local nullArray = Json.decode('[1,null,3]')
check('null array slot', #nullArray == 3 and nullArray[2] == Json.null)

-- ---------------------------------------------------------------- errors --

checkThrows('reject empty string', function() Json.decode('') end)
checkThrows('reject trailing data', function() Json.decode('{} x') end)
checkThrows('reject bare word', function() Json.decode('nope') end)
checkThrows('reject unterminated string', function() Json.decode('{"a":') end)
checkThrows('reject missing colon', function() Json.decode('{"a" 1}') end)
checkThrows('reject bad escape', function() Json.decode('"\\q"') end)
checkThrows('reject bad \\u escape', function() Json.decode('"\\u12"') end)
checkThrows('reject unclosed array', function() Json.decode('[1,2') end)
checkThrows('reject non-string', function() Json.decode(42) end)

-- --------------------------------------------------------------- encoding --

local encoded = Json.encode({ name = 'Lightroom "MCP"', count = -3, ratio = 1.5,
  flag = false, list = { 1, 2, 3 }, nested = { deep = true } })
local round = Json.decode(encoded)
check('round-trip string', round.name == 'Lightroom "MCP"')
check('round-trip int', round.count == -3)
check('round-trip float', round.ratio == 1.5)
check('round-trip bool', round.flag == false)
check('round-trip array', round.list[3] == 3)
check('round-trip nested', round.nested.deep == true)

check('encode empty array marker',
  Json.encode({ items = Json.emptyArray }):find('"items":[]', 1, true) ~= nil)
check('encode empty table as object',
  Json.encode({ meta = {} }):find('"meta":{}', 1, true) ~= nil)
check('encode null', Json.encode({ a = Json.null }):find('"a":null', 1, true) ~= nil)
check('encode top-level null', Json.encode(Json.null) == 'null')

local ctrl = Json.encode({ s = string.char(1) })
check('encode control char', ctrl:find('\\u0001', 1, true) ~= nil, ctrl)

local esc = Json.encode({ s = 'a"b\\c\nd\te' })
check('encode quote/backslash/newline',
  esc == '{"s":"a\\"b\\\\c\\nd\\te"}', esc)

local big = {}
for i = 1, 500 do big[i] = i * 2 end
local bigRound = Json.decode(Json.encode({ list = big }))
check('large array round-trip', #bigRound.list == 500 and bigRound.list[500] == 1000)

local unicode = Json.encode({ s = 'é😀' })
check('encode unicode passthrough', Json.decode(unicode).s == 'é😀', unicode)

check('encode integer formatting', Json.encode({ n = 1000000 }) == '{"n":1000000}')

-- NaN and infinities are not valid JSON numbers
local nan = Json.encode({ v = 0 / 0 })
check('encode NaN as null', nan:find('"v":null', 1, true) ~= nil, nan)
local inf = Json.encode({ v = math.huge })
check('encode +inf as null', inf:find('"v":null', 1, true) ~= nil, inf)

-- ------------------------------------------------------------------ depth --

local levels = 100
local deep = '{"a":1}'
for _ = 2, levels do deep = '{"x":' .. deep .. '}' end
local deepOk, deepResult = pcall(Json.decode, deep)
local walked, reached = deepResult, true
for _ = 2, levels do
  if type(walked) ~= 'table' then reached = false break end
  walked = walked.x
end
check('decode 100 levels',
  deepOk and reached and type(walked) == 'table' and walked.a == 1,
  deepOk and ('walked to ' .. type(walked)) or tostring(deepResult))

local bigEmptyArray = Json.encode({ rows = Json.emptyArray })
check('empty array in object stays []', bigEmptyArray == '{"rows":[]}')

-- ----------------------------------------------------------------- report --

print(('%d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
