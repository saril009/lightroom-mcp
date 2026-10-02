-- Minimal JSON encoder/decoder for Lightroom's Lua 5.1 sandbox.
-- Decoding maps JSON null to the sentinel Json.null (not nil, so that object
-- members survive table assignment).
local Json = {}

local nullValue = {}
Json.null = nullValue

-- ---------------------------------------------------------------------------
-- decoding
-- ---------------------------------------------------------------------------

local decodeValue

local escapeMap = {
  ['"'] = '"',
  ['\\'] = '\\',
  ['/'] = '/',
  b = '\b',
  f = '\f',
  n = '\n',
  r = '\r',
  t = '\t',
}

local function skipWhitespace(s, i)
  if i > #s then return i end
  local _, j = string.find(s, '^[ \t\r\n]*', i)
  if not j then return i end
  return j + 1
end

local function utf8Char(code)
  if code < 0x80 then
    return string.char(code)
  elseif code < 0x800 then
    return string.char(
      0xC0 + math.floor(code / 64),
      0x80 + code % 64
    )
  elseif code < 0x10000 then
    return string.char(
      0xE0 + math.floor(code / 4096),
      0x80 + math.floor(code / 64) % 64,
      0x80 + code % 64
    )
  else
    return string.char(
      0xF0 + math.floor(code / 262144),
      0x80 + math.floor(code / 4096) % 64,
      0x80 + math.floor(code / 64) % 64,
      0x80 + code % 64
    )
  end
end

-- i points at the opening quote. Returns the string and the index just past
-- the closing quote.
local function decodeString(s, i)
  local buf = {}
  local pos = i + 1
  while true do
    local c = string.sub(s, pos, pos)
    if c == '' then
      error('JSON: unterminated string', 0)
    end
    if c == '"' then
      return table.concat(buf), pos + 1
    end
    if c ~= '\\' then
      buf[#buf + 1] = c
      pos = pos + 1
    else
      local esc = string.sub(s, pos + 1, pos + 1)
      if esc == 'u' then
        local code = tonumber(string.sub(s, pos + 2, pos + 5), 16)
        if not code then
          error('JSON: bad \\u escape', 0)
        end
        pos = pos + 6
        -- surrogate pair
        if code >= 0xD800 and code <= 0xDBFF
          and string.sub(s, pos, pos + 1) == '\\u' then
          local low = tonumber(string.sub(s, pos + 2, pos + 5), 16)
          if low and low >= 0xDC00 and low <= 0xDFFF then
            code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
            pos = pos + 6
          end
        end
        buf[#buf + 1] = utf8Char(code)
      else
        local mapped = escapeMap[esc]
        if not mapped then
          error('JSON: bad escape sequence \\' .. esc, 0)
        end
        buf[#buf + 1] = mapped
        pos = pos + 2
      end
    end
  end
end

decodeValue = function(s, i)
  i = skipWhitespace(s, i)
  local c = string.sub(s, i, i)

  if c == '{' then
    local obj = {}
    i = skipWhitespace(s, i + 1)
    if string.sub(s, i, i) == '}' then
      return obj, i + 1
    end
    while true do
      if string.sub(s, i, i) ~= '"' then
        error('JSON: expected object key', 0)
      end
      local key
      key, i = decodeString(s, i)
      i = skipWhitespace(s, i)
      if string.sub(s, i, i) ~= ':' then
        error('JSON: expected ":"', 0)
      end
      local value
      value, i = decodeValue(s, i + 1)
      obj[key] = value
      i = skipWhitespace(s, i)
      local ch = string.sub(s, i, i)
      if ch == ',' then
        i = i + 1
      elseif ch == '}' then
        return obj, i + 1
      else
        error('JSON: expected "," or "}"', 0)
      end
    end

  elseif c == '[' then
    local arr = {}
    i = skipWhitespace(s, i + 1)
    if string.sub(s, i, i) == ']' then
      return arr, i + 1
    end
    while true do
      local value
      value, i = decodeValue(s, i)
      arr[#arr + 1] = value
      i = skipWhitespace(s, i)
      local ch = string.sub(s, i, i)
      if ch == ',' then
        i = i + 1
      elseif ch == ']' then
        return arr, i + 1
      else
        error('JSON: expected "," or "]"', 0)
      end
    end

  elseif c == '"' then
    return decodeString(s, i)

  elseif c == 't' and string.sub(s, i, i + 3) == 'true' then
    return true, i + 4
  elseif c == 'f' and string.sub(s, i, i + 4) == 'false' then
    return false, i + 5
  elseif c == 'n' and string.sub(s, i, i + 3) == 'null' then
    return nullValue, i + 4
  else
    -- number: match on a fresh substring so '^' anchors at i
    local numStr = string.match(string.sub(s, i), '^%-?%d+%.?%d*[eE]?[%+%-]?%d*')
    local value = numStr and tonumber(numStr)
    if not value then
      error('JSON: unexpected character at offset ' .. i, 0)
    end
    return value, i + #numStr
  end
end

function Json.decode(s)
  if type(s) ~= 'string' then
    error('JSON: expected a string', 0)
  end
  local value, pos = decodeValue(s, 1)
  pos = skipWhitespace(s, pos)
  if pos <= #s then
    error('JSON: trailing data at offset ' .. pos, 0)
  end
  return value
end

-- ---------------------------------------------------------------------------
-- encoding
-- ---------------------------------------------------------------------------

local stringEscapes = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

local function encodeString(s)
  local escaped = string.gsub(s, '[%c"\\]', function(c)
    return stringEscapes[c] or string.format('\\u%04x', string.byte(c))
  end)
  return '"' .. escaped .. '"'
end

-- Marker metatable: an empty table must be able to declare "I am an array".
local arrayMeta = {}
Json.emptyArray = setmetatable({}, arrayMeta)

local function isArray(t)
  if getmetatable(t) == arrayMeta then
    return true
  end
  local count, max = 0, 0
  for k in pairs(t) do
    if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then
      return false
    end
    if k > max then max = k end
    count = count + 1
  end
  if count == 0 then
    return false -- ambiguous: default to an object
  end
  return max == count -- no holes
end

local encodeValue

encodeValue = function(v)
  local t = type(v)
  if v == nil then
    return 'null'
  elseif t == 'boolean' then
    return v and 'true' or 'false'
  elseif t == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then
      return 'null'
    end
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return string.format('%.0f', v)
    end
    return string.format('%.10g', v)
  elseif t == 'string' then
    return encodeString(v)
  elseif t == 'table' then
    if v == nullValue then
      return 'null'
    end
    local parts = {}
    if isArray(v) then
      for i = 1, #v do
        parts[#parts + 1] = encodeValue(v[i])
      end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    for k, val in pairs(v) do
      local key = k
      if type(k) ~= 'string' then
        key = tostring(k)
      end
      parts[#parts + 1] = encodeString(key) .. ':' .. encodeValue(val)
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return 'null'
end

function Json.encode(v)
  return encodeValue(v)
end

return Json
