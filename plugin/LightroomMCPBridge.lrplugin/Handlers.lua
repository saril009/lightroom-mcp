--------------------------------------------------------------------------------
-- Handlers.lua
--
-- One function per MCP tool. Contract: return a table on success, or
-- nil + "message" on failure. Everything runs inside the bridge's background
-- task, so yielding catalog APIs are allowed - but any *protected* call must
-- use LrTasks.pcall, because Lua 5.1's pcall cannot yield across the C
-- boundary and Lightroom's catalog APIs yield constantly.
--------------------------------------------------------------------------------

local LrApplication = import 'LrApplication'
local LrApplicationView = import 'LrApplicationView'
local LrDevelopController = import 'LrDevelopController'
local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local Json = require 'Json'
local Config = require 'Config'

local Handlers = {}

-- ---------------------------------------------------------------------------
-- primitives
-- ---------------------------------------------------------------------------

local function cat()
  return LrApplication.activeCatalog()
end

local function isNilish(v)
  return v == nil or v == Json.null
end

local function asList(v)
  if isNilish(v) then return nil end
  if type(v) == 'string' then return { v } end
  if type(v) == 'table' then return v end
  return nil
end

local function lstr(s)
  return string.lower(tostring(s))
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function round(v, places)
  local mult = 10 ^ (places or 0)
  if v >= 0 then return math.floor(v * mult + 0.5) / mult end
  return math.ceil(v * mult - 0.5) / mult
end

-- Empty Lua tables encode as JSON objects, so arrays need a marker.
local function listOrEmpty(t)
  if t == nil or #t == 0 then return Json.emptyArray end
  return t
end

local VIDEO_EXTENSIONS = {
  mov = true, mp4 = true, m4v = true, avi = true, mpg = true, mpeg = true, mkv = true,
}

local function isVideo(photo)
  local path = photo:getRawMetadata('path')
  if type(path) ~= 'string' then return false end
  local ext = LrPathUtils.extension(path)
  return ext ~= nil and VIDEO_EXTENSIONS[lstr(ext)] == true
end

-- Runs fn inside a catalog write gate, returning true or nil + message.
local function withWrite(label, fn, timeout)
  local ok, ret = LrTasks.pcall(function()
    return cat():withWriteAccessDo(label, fn, { timeout = timeout or 60 })
  end)
  if not ok then
    return nil, tostring(ret)
  end
  -- SDK 4.0+ returns "executed" / "queued" / "aborted"; older builds return nil.
  if ret == 'aborted' then
    return nil, 'Lightroom did not grant catalog write access within the timeout '
      .. '(is another plugin blocking it, or is Lightroom busy?).'
  end
  if ret == 'queued' then
    return nil, 'Lightroom queued the write but it did not run before the timeout.'
  end
  return true
end

-- LrPhoto userdata is not reliably compared by identity, so fall back to the
-- localIdentifier (nil safe: pcall catches indexing a missing target photo).
local function isSamePhoto(a, b)
  if a == nil or b == nil then return false end
  if a == b then return true end
  local okA, idA = LrTasks.pcall(function() return a.localIdentifier end)
  local okB, idB = LrTasks.pcall(function() return b.localIdentifier end)
  return okA and okB and idA ~= nil and idA == idB
end

-- ---------------------------------------------------------------------------
-- photo resolution
-- ---------------------------------------------------------------------------

-- Accepts a uuid string, an array of uuid strings, or nothing (current
-- selection). Returns photos, nil, missingIds  OR  nil, errorMessage.
local function resolvePhotos(spec, opts)
  opts = opts or {}
  local c = cat()
  local list = asList(spec)

  if list == nil or #list == 0 then
    if opts.optional then
      return {}, nil, {}
    end
    if c:getTargetPhoto() == nil then
      return nil, 'No photo ids were given and nothing is selected in Lightroom. '
        .. 'Pass photo uuids (from list_photos / get_selected_photos) or select photos first.'
    end
    return c:getTargetPhotos(), nil, {}
  end

  local photos, missing = {}, {}
  for _, id in ipairs(list) do
    if type(id) == 'string' and id ~= '' then
      local photo = c:findPhotoByUuid(id)
      if photo then
        photos[#photos + 1] = photo
      else
        missing[#missing + 1] = id
      end
    end
  end
  if #photos == 0 then
    return nil, 'None of those photo ids exist in this catalog: ' .. table.concat(missing, ', ')
  end
  return photos, nil, missing
end

local function firstPhoto(args)
  local photos, err = resolvePhotos(args.photos)
  if not photos then return nil, err end
  return photos[1], nil, photos
end

-- ---------------------------------------------------------------------------
-- photo summaries
-- ---------------------------------------------------------------------------

local function summarize(photos)
  local c = cat()
  local raw = c:batchGetRawMetadata(photos, {
    'uuid', 'path', 'rating', 'pickStatus', 'colorNameForLabel', 'fileFormat',
    'width', 'height', 'dateTimeOriginalISO8601', 'keywords', 'isVirtualCopy',
  })
  local fmt = c:batchGetFormattedMetadata(photos, {
    'fileName', 'folderName', 'title', 'caption',
  })

  local out = {}
  for i, photo in ipairs(photos) do
    local r = raw[photo] or {}
    local f = fmt[photo] or {}

    local keywords = {}
    if type(r.keywords) == 'table' then
      for _, kw in ipairs(r.keywords) do
        local ok, name = LrTasks.pcall(function() return kw:getName() end)
        if ok and name then keywords[#keywords + 1] = name end
      end
    end

    local pick = r.pickStatus
    out[i] = {
      uuid = r.uuid,
      fileName = f.fileName,
      path = r.path,
      folder = f.folderName,
      fileFormat = r.fileFormat,
      width = r.width,
      height = r.height,
      rating = r.rating or 0,
      pick = (pick == 1 and 'flagged') or (pick == -1 and 'rejected') or 'unflagged',
      colorLabel = r.colorNameForLabel or 'none',
      capturedAt = r.dateTimeOriginalISO8601,
      isVirtualCopy = r.isVirtualCopy or false,
      isVideo = r.fileFormat == 'VIDEO',
      keywords = keywords,
      title = f.title,
      caption = f.caption,
    }
  end
  return out
end

-- ---------------------------------------------------------------------------
-- develop settings schema
--
-- Lightroom has renamed several sliders over the years (Exposure ->
-- Exposure2012), and a couple of documented keys carry typos
-- (HueAdjustmentMagenha, Parametriclights). Each field lists its candidates
-- in preference order; the first one present in the photo's own settings
-- table wins, so we always write back the spelling this Lightroom understands.
-- ---------------------------------------------------------------------------

local DEVELOP_FIELDS = {
  { aliases = { 'exposure' }, candidates = { 'Exposure2012', 'Exposure' },
    type = 'number', min = -5, max = 5 },
  { aliases = { 'contrast' }, candidates = { 'Contrast2012', 'Contrast' },
    type = 'number', min = -100, max = 100 },
  { aliases = { 'highlights', 'highlight' }, candidates = { 'Highlights2012', 'Highlights' },
    type = 'number', min = -100, max = 100 },
  { aliases = { 'shadows', 'shadow' }, candidates = { 'Shadows2012', 'Shadows' },
    type = 'number', min = -100, max = 100 },
  { aliases = { 'whites' }, candidates = { 'Whites2012', 'Whites' },
    type = 'number', min = -100, max = 100 },
  { aliases = { 'blacks' }, candidates = { 'Blacks2012', 'Blacks' },
    type = 'number', min = -100, max = 100 },
  { aliases = { 'clarity' }, candidates = { 'Clarity2012', 'Clarity' },
    type = 'number', min = -100, max = 100 },

  { aliases = { 'texture' }, candidates = { 'Texture' }, type = 'number', min = -100, max = 100 },
  { aliases = { 'dehaze' }, candidates = { 'Dehaze' }, type = 'number', min = -100, max = 100 },
  { aliases = { 'vibrance' }, candidates = { 'Vibrance' }, type = 'number', min = -100, max = 100 },
  { aliases = { 'saturation' }, candidates = { 'Saturation' }, type = 'number', min = -100, max = 100 },
  { aliases = { 'brightness' }, candidates = { 'Brightness' }, type = 'number', min = -100, max = 100 },

  -- White balance. Temperature/Tint are deliberately unclamped: RAW photos use
  -- absolute Kelvin, processed photos use a relative scale.
  { aliases = { 'temperature', 'temp' }, candidates = { 'Temperature' }, type = 'number' },
  { aliases = { 'tint' }, candidates = { 'Tint' }, type = 'number' },
  { aliases = { 'whitebalance', 'white_balance' }, candidates = { 'WhiteBalance' },
    type = 'string', allowed = { 'asShot', 'auto', 'custom', 'daylight', 'cloudy', 'shade',
      'tungsten', 'fluorescent', 'flash', 'blackAndWhite' } },
  { aliases = { 'grayscale', 'monochrome', 'blackandwhite', 'bw' },
    candidates = { 'ConvertToGrayscale' }, type = 'boolean' },

  -- Parametric tone curve
  { aliases = { 'tone_shadows' }, candidates = { 'ParametricShadows' }, type = 'number', min = -100, max = 100 },
  { aliases = { 'tone_darks' }, candidates = { 'ParametricDarks' }, type = 'number', min = -100, max = 100 },
  { aliases = { 'tone_lights' }, candidates = { 'ParametricLights', 'Parametriclights' }, type = 'number', min = -100, max = 100 },
  { aliases = { 'tone_highlights' }, candidates = { 'ParametricHighlights' }, type = 'number', min = -100, max = 100 },
  { aliases = { 'tone_shadow_split' }, candidates = { 'ParametricShadowSplit' }, type = 'number', min = -10, max = 10 },
  { aliases = { 'tone_midtone_split' }, candidates = { 'ParametricMidtoneSplit' }, type = 'number', min = -10, max = 10 },
  { aliases = { 'tone_highlight_split' }, candidates = { 'ParametricHighlightSplit' }, type = 'number', min = -10, max = 10 },

  -- Detail panel
  { aliases = { 'sharpness', 'sharpening' }, candidates = { 'Sharpness' }, type = 'number', min = 0, max = 150 },
  { aliases = { 'sharpen_radius' }, candidates = { 'SharpenRadius' }, type = 'number', min = 0.5, max = 3 },
  { aliases = { 'sharpen_detail' }, candidates = { 'SharpenDetail' }, type = 'number', min = 0, max = 100 },
  { aliases = { 'sharpen_masking', 'sharpening_masking' },
    candidates = { 'SharpenEdgeMasking' }, type = 'number', min = 0, max = 100 },
  { aliases = { 'noise_reduction', 'luminance_smoothing', 'nr' },
    candidates = { 'LuminanceSmoothing' }, type = 'number', min = 0, max = 100 },
  { aliases = { 'color_noise_reduction', 'color_nr' },
    candidates = { 'ColorNoiseReduction' }, type = 'number', min = 0, max = 100 },

  -- Effects
  { aliases = { 'vignette', 'vignette_amount', 'post_crop_vignette' },
    candidates = { 'PostCropVignetteAmount', 'VignetteAmount' }, type = 'number', min = -100, max = 100 },
  { aliases = { 'vignette_midpoint' }, candidates = { 'PostCropVignetteMidpoint', 'VignetteMidpoint' },
    type = 'number', min = 0, max = 100 },
  { aliases = { 'vignette_feather' }, candidates = { 'PostCropVignetteFeather' }, type = 'number', min = 0, max = 100 },
  { aliases = { 'grain_amount', 'grain' }, candidates = { 'GrainAmount' }, type = 'number', min = 0, max = 100 },

  -- Crop. Lightroom stores the frame as normalized coordinates of the
  -- original image (an uncropped photo is 0,0,1,1); reset_develop_settings
  -- uses these instead of a HasCrop flag, which is not in the documented key
  -- list. There is no supported way to *set* an arbitrary crop from a settings
  -- table - use the Develop module's crop tool for that.
  { aliases = { 'crop_angle' }, candidates = { 'CropAngle' }, type = 'number', min = -90, max = 90 },

  -- Split toning
  { aliases = { 'split_shadow_hue' }, candidates = { 'SplitToningShadowHue' }, type = 'number', min = 0, max = 360 },
  { aliases = { 'split_shadow_sat' }, candidates = { 'SplitToningShadowSaturation' }, type = 'number', min = 0, max = 100 },
  { aliases = { 'split_highlight_hue' }, candidates = { 'SplitToningHighlightHue' }, type = 'number', min = 0, max = 360 },
  { aliases = { 'split_highlight_sat' }, candidates = { 'SplitToningHighlightSaturation' }, type = 'number', min = 0, max = 100 },
  { aliases = { 'split_balance' }, candidates = { 'SplitToningBalance' }, type = 'number', min = -100, max = 100 },
}

-- HSL mixer
local HSL_COLORS = { 'Red', 'Orange', 'Yellow', 'Green', 'Aqua', 'Blue', 'Purple', 'Magenta' }
local HSL_TYPOS = {
  HueAdjustmentMagenta = 'HueAdjustmentMagenha',
  LuminanceAdjustmentAqua = 'LuminanceAdjustmentAque',
}
for _, color in ipairs(HSL_COLORS) do
  local c = lstr(color)
  local hueKey = 'HueAdjustment' .. color
  local satKey = 'SaturationAdjustment' .. color
  local lumKey = 'LuminanceAdjustment' .. color
  local hueCandidates = { hueKey }
  if HSL_TYPOS[hueKey] then hueCandidates[#hueCandidates + 1] = HSL_TYPOS[hueKey] end
  local lumCandidates = { lumKey }
  if HSL_TYPOS[lumKey] then lumCandidates[#lumCandidates + 1] = HSL_TYPOS[lumKey] end

  DEVELOP_FIELDS[#DEVELOP_FIELDS + 1] =
    { aliases = { 'hue_' .. c }, candidates = hueCandidates, type = 'number', min = -100, max = 100 }
  DEVELOP_FIELDS[#DEVELOP_FIELDS + 1] =
    { aliases = { 'sat_' .. c, 'saturation_' .. c }, candidates = { satKey }, type = 'number', min = -100, max = 100 }
  DEVELOP_FIELDS[#DEVELOP_FIELDS + 1] =
    { aliases = { 'lum_' .. c, 'luminance_' .. c }, candidates = lumCandidates, type = 'number', min = -100, max = 100 }
end

local FIELD_INDEX = {}
for _, field in ipairs(DEVELOP_FIELDS) do
  for _, name in ipairs(field.aliases) do FIELD_INDEX[lstr(name)] = field end
  for _, name in ipairs(field.candidates) do FIELD_INDEX[lstr(name)] = field end
end

local FIELD_HINT = 'Valid names: exposure, contrast, highlights, shadows, whites, blacks, '
  .. 'clarity, texture, dehaze, vibrance, saturation, temperature, tint, whitebalance, '
  .. 'grayscale, sharpness, noise_reduction, color_noise_reduction, vignette, grain, '
  .. 'tone_* (shadows/darks/lights/highlights), hue_red|orange|yellow|green|aqua|blue|purple|magenta, '
  .. 'sat_*, lum_* - or any raw Lightroom settings key (Exposure2012, PostCropVignetteAmount, ...).'

local function pickCandidate(field, ref)
  if type(ref) == 'table' then
    for _, candidate in ipairs(field.candidates) do
      if ref[candidate] ~= nil then return candidate end
    end
  end
  return field.candidates[1]
end

-- Returns settings, nil, clampedNotes   OR   nil, errorMessage
local function normalizeSettings(raw, ref)
  if type(raw) ~= 'table' then
    return nil, 'settings must be an object of develop adjustments.'
  end

  local out, errors, clamped = {}, {}, {}
  local claimed = {}

  for key, value in pairs(raw) do
    local name = lstr(key)
    local field = FIELD_INDEX[name]
    if field == nil then
      errors[#errors + 1] = tostring(key)
    elseif claimed[field] then
      -- two aliases for one field; later write wins, harmless
    else
      claimed[field] = true
      local v = value

      if field.type == 'number' then
        local n = tonumber(v)
        if n == nil or n ~= n then
          errors[#errors + 1] = tostring(key) .. ' must be a number (got '
            .. type(v) .. ')'
        else
          local original = n
          if field.min then n = math.max(field.min, n) end
          if field.max then n = math.min(field.max, n) end
          if n ~= original then
            clamped[#clamped + 1] = string.format('%s: %s -> %s',
              field.candidates[1], tostring(original), tostring(n))
          end
          out[pickCandidate(field, ref)] = n
        end

      elseif field.type == 'boolean' then
        if type(v) == 'boolean' then
          out[pickCandidate(field, ref)] = v
        elseif v == 0 or lstr(v) == 'false' or lstr(v) == 'no' then
          out[pickCandidate(field, ref)] = false
        elseif v == 1 or lstr(v) == 'true' or lstr(v) == 'yes' then
          out[pickCandidate(field, ref)] = true
        else
          errors[#errors + 1] = tostring(key) .. ' must be true or false'
        end

      else -- string
        local s = tostring(v)
        if field.allowed then
          local okValue = false
          for _, allowed in ipairs(field.allowed) do
            if lstr(allowed) == lstr(s) then s = allowed; okValue = true break end
          end
          if not okValue then
            errors[#errors + 1] = tostring(key) .. ' must be one of '
              .. table.concat(field.allowed, ', ')
          else
            out[pickCandidate(field, ref)] = s
          end
        else
          out[pickCandidate(field, ref)] = s
        end
      end
    end
  end

  if #errors > 0 then
    return nil, 'Invalid develop setting(s): ' .. table.concat(errors, ', ') .. '. ' .. FIELD_HINT
  end
  if next(out) == nil then
    return nil, 'settings is empty. ' .. FIELD_HINT
  end
  return out, nil, clamped
end

-- ---------------------------------------------------------------------------
-- catalog / discovery tools
-- ---------------------------------------------------------------------------

function Handlers.status(args)
  local Bridge = require 'Bridge'
  local c = cat()
  local selected = c:getTargetPhoto() and c:getTargetPhotos() or {}
  local module = 'unknown'
  local okModule, currentModule = LrTasks.pcall(function()
    return LrApplicationView.getCurrentModule()
  end)
  if okModule and currentModule then module = currentModule end

  return {
    connected = Bridge.isConnected(),
    running = Bridge.isRunning(),
    serverReachable = Bridge.state.serverReachable,
    port = Config.port(),
    polls = Bridge.state.polls,
    jobsCompleted = Bridge.state.jobsCompleted,
    currentJob = Bridge.state.currentJob,
    lastError = Bridge.state.lastError,
    module = module,
    catalogPath = c:getPath(),
    selectedCount = #selected,
    selectedUuids = (function()
      local ids = {}
      for i = 1, math.min(25, #selected) do ids[i] = selected[i]:getRawMetadata('uuid') end
      return listOrEmpty(ids)
    end)(),
  }
end

local function buildCriteria(args)
  local criteria = {}
  local function add(c) criteria[#criteria + 1] = c end
  local function fail(msg) return nil, msg end

  if type(args.query) == 'string' and args.query ~= '' then
    add({ criteria = 'all', operation = 'words', value = args.query })
  end
  if type(args.filename) == 'string' and args.filename ~= '' then
    add({ criteria = 'filename', operation = 'any', value = args.filename })
  end
  for _, kw in ipairs(asList(args.keywords) or {}) do
    add({ criteria = 'keywords', operation = 'any', value = tostring(kw) })
  end
  if not isNilish(args.minRating) then
    add({ criteria = 'rating', operation = '>=', value = tonumber(args.minRating) or 0 })
  end
  if not isNilish(args.maxRating) then
    add({ criteria = 'rating', operation = '<=', value = tonumber(args.maxRating) or 5 })
  end
  if not isNilish(args.pick) then
    local map = { flagged = 1, picked = 1, rejected = -1, unflagged = 0, none = 0 }
    local value = map[lstr(args.pick)]
    if value == nil then
      return fail('pick must be one of: flagged, unflagged, rejected')
    end
    add({ criteria = 'pick', operation = '==', value = value })
  end
  if not isNilish(args.colorLabel) then
    local map = { red = 1, yellow = 2, green = 3, blue = 4, purple = 5, none = 'none' }
    local value = map[lstr(args.colorLabel)]
    if value == nil then
      return fail('colorLabel must be one of: red, yellow, green, blue, purple, none')
    end
    add({ criteria = 'labelColor', operation = '==', value = value })
  end
  if not isNilish(args.fileFormat) then
    local map = {
      dng = 'DNG', raw = 'RAW', jpg = 'JPG', jpeg = 'JPG', tiff = 'TIFF', tif = 'TIFF',
      png = 'PNG', psd = 'PSD', video = 'VIDEO',
    }
    local value = map[lstr(args.fileFormat)]
    if value == nil then
      return fail('fileFormat must be one of: dng, raw, jpg, tiff, png, psd, video')
    end
    add({ criteria = 'fileFormat', operation = '==', value = value })
  end
  if not isNilish(args.folder) then
    add({ criteria = 'folder', operation = 'any', value = tostring(args.folder) })
  end
  if not isNilish(args.collection) then
    add({ criteria = 'collection', operation = 'any', value = tostring(args.collection) })
  end
  if not isNilish(args.dateAfter) then
    add({ criteria = 'captureTime', operation = '>', value = tostring(args.dateAfter) })
  end
  if not isNilish(args.dateBefore) then
    add({ criteria = 'captureTime', operation = '<', value = tostring(args.dateBefore) })
  end
  if not isNilish(args.lastDays) then
    add({
      criteria = 'captureTime', operation = 'inLast',
      value = tonumber(args.lastDays) or 30, value_units = 'days',
    })
  end
  if args.edited == true then
    add({ criteria = 'hasAdjustments', operation = 'isTrue' })
  elseif args.edited == false then
    add({ criteria = 'hasAdjustments', operation = 'isFalse' })
  end
  if not isNilish(args.treatment) then
    local value = lstr(args.treatment)
    if value ~= 'grayscale' and value ~= 'color' then
      return fail('treatment must be "grayscale" or "color"')
    end
    add({ criteria = 'treatment', operation = '==', value = value })
  end
  if not isNilish(args.aspect) then
    local value = lstr(args.aspect)
    if value ~= 'portrait' and value ~= 'landscape' and value ~= 'square' then
      return fail('aspect must be "portrait", "landscape" or "square"')
    end
    add({ criteria = 'aspectRatio', operation = '==', value = value })
  end
  if not isNilish(args.camera) then
    add({ criteria = 'camera', operation = '==', value = tostring(args.camera) })
  end
  if not isNilish(args.lens) then
    add({ criteria = 'lens', operation = '==', value = tostring(args.lens) })
  end
  if not isNilish(args.isoMin) then
    add({ criteria = 'isoSpeedRating', operation = '>=', value = tonumber(args.isoMin) or 0 })
  end
  if not isNilish(args.isoMax) then
    add({ criteria = 'isoSpeedRating', operation = '<=', value = tonumber(args.isoMax) or 1000000 })
  end

  return criteria
end

function Handlers.list_photos(args)
  args = args or {}
  local c = cat()
  local criteria, criteriaErr = buildCriteria(args)
  if criteria == nil then return nil, criteriaErr end

  local limit = math.min(tonumber(args.limit) or 50, 500)
  limit = math.max(limit, 1)

  local photos, total
  if #criteria == 0 then
    -- No filter: whatever the grid/filmstrip is showing (or the selection).
    photos = c:getMultipleSelectedOrAllPhotos()
    total = #photos
  else
    local searchDesc
    if #criteria == 1 then
      -- A lone criterion must be passed directly, not wrapped in a list.
      searchDesc = criteria[1]
    else
      searchDesc = { combine = 'intersect' }
      for i, criterion in ipairs(criteria) do searchDesc[i] = criterion end
    end
    local sortField = 'captureTime'
    if args.sort == 'fileName' or args.sort == 'extension' then sortField = args.sort end

    local ok, result = LrTasks.pcall(function()
      return c:findPhotos{
        searchDesc = searchDesc,
        sort = sortField,
        ascending = args.ascending == true,
      }
    end)
    if not ok then
      return nil, 'findPhotos failed: ' .. tostring(result)
    end
    photos = result
    total = #photos
  end

  local slice = {}
  for i = 1, math.min(limit, #photos) do slice[i] = photos[i] end

  return {
    total = total,
    returned = #slice,
    truncated = total > #slice,
    photos = listOrEmpty(summarize(slice)),
  }
end

function Handlers.get_selected_photos(args)
  args = args or {}
  local c = cat()
  if c:getTargetPhoto() == nil then
    return { total = 0, returned = 0, photos = Json.emptyArray }
  end
  local photos = c:getTargetPhotos()
  local limit = math.min(tonumber(args.limit) or 200, 500)
  local slice = {}
  for i = 1, math.min(limit, #photos) do slice[i] = photos[i] end
  return {
    total = #photos,
    returned = #slice,
    truncated = #photos > #slice,
    photos = listOrEmpty(summarize(slice)),
  }
end

function Handlers.get_photo_details(args)
  args = args or {}
  local photo, err, photos = firstPhoto(args)
  if not photo then return nil, err end

  local details = { photo = summarize({ photo })[1] }
  if #photos > 1 then details.alsoMatched = #photos end

  if args.includeDevelop ~= false then
    local ok, settings = LrTasks.pcall(function() return photo:getDevelopSettings() end)
    if ok and type(settings) == 'table' then
      details.develop = settings
    end
  end
  return details
end

-- ---------------------------------------------------------------------------
-- develop tools
-- ---------------------------------------------------------------------------

function Handlers.get_develop_settings(args)
  args = args or {}
  local photo, err = firstPhoto(args)
  if not photo then return nil, err end
  local ok, settings = LrTasks.pcall(function() return photo:getDevelopSettings() end)
  if not ok then return nil, 'getDevelopSettings failed: ' .. tostring(settings) end
  if type(settings) ~= 'table' then return nil, 'Lightroom returned no settings' end
  return { uuid = photo:getRawMetadata('uuid'), settings = settings }
end

function Handlers.set_develop_settings(args)
  args = args or {}
  local photos, err, missing = resolvePhotos(args.photos)
  if not photos then return nil, err end
  if isVideo(photos[1]) then
    return nil, 'That is a video file - develop settings only apply to still images.'
  end

  -- Use the first photo's own settings table to learn the right key spellings.
  local ref
  local okRef, refOrErr = LrTasks.pcall(function() return photos[1]:getDevelopSettings() end)
  if okRef and type(refOrErr) == 'table' then ref = refOrErr end

  local settings, normalizeErr, clamped = normalizeSettings(args.settings, ref)
  if not settings then return nil, normalizeErr end

  -- Temperature/Tint are ignored unless white balance is custom.
  if (settings.Temperature or settings.Tint) and settings.WhiteBalance == nil then
    settings.WhiteBalance = 'custom'
  end

  local label = 'MCP: ' .. (type(args.historyLabel) == 'string' and args.historyLabel
    or 'apply develop settings')

  local written, firstApplyError = 0, nil
  local writeOk, writeErr = withWrite(label, function()
    for _, photo in ipairs(photos) do
      if isVideo(photo) then
        firstApplyError = firstApplyError or 'skipped a video file'
      else
        local okApply, applyErr = LrTasks.pcall(function()
          photo:applyDevelopSettings(settings, label)
        end)
        if okApply then
          written = written + 1
        else
          firstApplyError = firstApplyError or tostring(applyErr)
        end
      end
    end
  end)

  if not writeOk then return nil, writeErr end

  return {
    applied = written,
    requested = #photos,
    skipped = #photos - written,
    settings = settings,
    clamped = listOrEmpty(clamped or {}),
    missing = listOrEmpty(missing or {}),
    error = firstApplyError,
  }
end

local NEUTRAL_SETTINGS = {
  exposure = 0, contrast = 0, highlights = 0, shadows = 0, whites = 0, blacks = 0,
  clarity = 0, texture = 0, dehaze = 0, vibrance = 0, saturation = 0,
  whitebalance = 'asShot', grayscale = false,
  tone_shadows = 0, tone_darks = 0, tone_lights = 0, tone_highlights = 0,
  tone_shadow_split = 0, tone_midtone_split = 0, tone_highlight_split = 0,
}

function Handlers.reset_develop_settings(args)
  args = args or {}
  local photos, err = resolvePhotos(args.photos)
  if not photos then return nil, err end

  local ref
  local okRef, refOrErr = LrTasks.pcall(function() return photos[1]:getDevelopSettings() end)
  if okRef and type(refOrErr) == 'table' then ref = refOrErr end

  local settings = {}
  local neutral = NEUTRAL_SETTINGS
  if args.resetEffects == true then
    neutral = {}
    for k, v in pairs(NEUTRAL_SETTINGS) do neutral[k] = v end
    neutral.vignette = 0
    neutral.grain_amount = 0
    neutral.split_shadow_sat = 0
    neutral.split_highlight_sat = 0
  end
  local normalized = normalizeSettings(neutral, ref)
  if not normalized then return nil, 'Could not build neutral settings' end
  for k, v in pairs(normalized) do settings[k] = v end

  if args.resetCrop == true then
    -- Full-frame rect: every key here is in Lightroom's documented settings
    -- table (unlike HasCrop, which is not).
    settings.CropLeft = 0
    settings.CropTop = 0
    settings.CropRight = 1
    settings.CropBottom = 1
    settings.CropAngle = 0
  end

  local label = 'MCP: reset develop settings'
  local writeOk, writeErr = withWrite(label, function()
    for _, photo in ipairs(photos) do
      if not isVideo(photo) then photo:applyDevelopSettings(settings, label) end
    end
  end)
  if not writeOk then return nil, writeErr end

  return {
    reset = #photos,
    settings = settings,
    note = 'Tone, presence and white balance were reset. The tone curve, '
      .. 'masks, local adjustments, spot removal and sharpening/noise are left '
      .. 'alone; pass resetCrop=true / resetEffects=true to also clear crop, '
      .. 'vignette and grain.',
  }
end

function Handlers.copy_develop_settings(args)
  args = args or {}
  local source, err = firstPhoto({ photos = args.source })
  if not source then return nil, err end

  local targets, targetErr = resolvePhotos(args.photos)
  if not targets then return nil, targetErr end

  local settings
  local okGet, result = LrTasks.pcall(function() return source:getDevelopSettings() end)
  if not okGet or type(result) ~= 'table' then
    return nil, 'Could not read develop settings from the source photo: ' .. tostring(result)
  end
  settings = result

  local label = 'MCP: copy develop settings'
  local writeOk, writeErr = withWrite(label, function()
    for _, photo in ipairs(targets) do
      if not isSamePhoto(photo, source) and not isVideo(photo) then
        photo:applyDevelopSettings(settings, label)
      end
    end
  end)
  if not writeOk then return nil, writeErr end

  return {
    copiedFrom = source:getRawMetadata('uuid'),
    applied = #targets,
    settings = settings,
  }
end

-- Lightroom's own Auto Tone. Only works on the photo currently displayed in
-- the Develop module, so this may switch module and change selection.
function Handlers.auto_tone(args)
  args = args or {}
  local photos, err = resolvePhotos(args.photos)
  if not photos then return nil, err end

  local originalModule = LrApplicationView.getCurrentModule()
  local switchedModule = false
  if originalModule ~= 'develop' then
    if args.switchToDevelop == true then
      LrApplicationView.switchToModule('develop')
      switchedModule = true
      LrTasks.sleep(0.7)
    else
      return nil, "Lightroom's Auto Tone only runs in the Develop module (currently '"
        .. tostring(originalModule) .. "'). Pass switchToDevelop=true to switch "
        .. 'automatically, or use auto_enhance instead, which works from any module '
        .. 'by analysing a rendered preview.'
    end
  end

  local c = cat()
  -- Remember what the user had selected so we can put it back afterwards.
  local originalSelection = nil
  if c:getTargetPhoto() ~= nil then originalSelection = c:getTargetPhotos() end

  local done, failed = {}, {}
  local settle = tonumber(args.settleSeconds) or 0.6

  for _, photo in ipairs(photos) do
    if not isSamePhoto(c:getTargetPhoto(), photo) then
      c:setSelectedPhotos(photo, {})
      LrTasks.sleep(settle)
    end
    if not isSamePhoto(c:getTargetPhoto(), photo) then
      failed[#failed + 1] = {
        uuid = photo:getRawMetadata('uuid'),
        error = 'could not make this the active Develop photo',
      }
    else
      local okTone, toneErr = LrTasks.pcall(function()
        LrDevelopController.setAutoTone()
      end)
      if not okTone then
        failed[#failed + 1] = { uuid = photo:getRawMetadata('uuid'), error = tostring(toneErr) }
      else
        if args.whiteBalance == true then
          LrTasks.pcall(function() LrDevelopController.setAutoWhiteBalance() end)
        end
        done[#done + 1] = photo:getRawMetadata('uuid')
      end
    end
  end

  if switchedModule then
    LrTasks.pcall(function()
      if originalModule and originalModule ~= 'develop' then
        LrApplicationView.switchToModule(originalModule)
      end
    end)
  end

  -- Put the user's selection back now that no photo needs to be "active".
  local restored = false
  if originalSelection and #originalSelection > 0 then
    local unpackFn = table.unpack or unpack
    local okRestore = LrTasks.pcall(function()
      c:setSelectedPhotos(originalSelection[1], { unpackFn(originalSelection, 2) })
    end)
    restored = okRestore and isSamePhoto(c:getTargetPhoto(), originalSelection[1])
  end

  if #done == 0 and #failed > 0 then
    return nil, 'Auto Tone failed: ' .. tostring(failed[1].error)
  end

  return {
    applied = listOrEmpty(done),
    failed = listOrEmpty(failed),
    selectionRestored = restored,
    note = "Auto Tone is Adobe's own algorithm and only applies to the photo shown "
      .. 'in Develop, so the selection was changed while it ran'
      .. (restored and ' (your previous selection was restored).' or '.'),
  }
end

-- ---------------------------------------------------------------------------
-- presets
-- ---------------------------------------------------------------------------

local function rootPresetFolders()
  local fn = LrApplication.getDevelopPresetFolders or LrApplication.developPresetFolders
  if type(fn) ~= 'function' then return nil end
  local ok, folders = LrTasks.pcall(fn)
  if ok and type(folders) == 'table' then return folders end
  return nil
end

-- Walks a preset folder (and any subfolders this SDK exposes) collecting the
-- presets it holds.
local function collectPresetsInto(out, folder, depth)
  if depth > 8 then return end
  local okName, folderName = LrTasks.pcall(function() return folder:getName() end)
  local okPresets, presets = LrTasks.pcall(function() return folder:getDevelopPresets() end)
  if okPresets and type(presets) == 'table' then
    for _, preset in ipairs(presets) do
      local okPresetName, presetName = LrTasks.pcall(function() return preset:getName() end)
      local okPath, presetPath = LrTasks.pcall(function() return preset:getPath() end)
      out[#out + 1] = {
        name = okPresetName and presetName or nil,
        folder = okName and folderName or nil,
        path = okPath and presetPath or nil,
      }
    end
  end
  local children, okChildren
  if type(folder.getSubfolders) == 'function' then
    okChildren, children = LrTasks.pcall(function() return folder:getSubfolders() end)
  elseif type(folder.getChildFolders) == 'function' then
    okChildren, children = LrTasks.pcall(function() return folder:getChildFolders() end)
  end
  if okChildren and type(children) == 'table' then
    for _, child in ipairs(children) do
      collectPresetsInto(out, child, depth + 1)
    end
  end
end

local function allPresets()
  local out = {}
  local folders = rootPresetFolders()
  if folders then
    for _, folder in ipairs(folders) do
      collectPresetsInto(out, folder, 0)
    end
  end
  return out
end

local function findPreset(list, needle)
  if needle == nil then return nil, nil end
  local wanted = lstr(needle)
  local partial = nil
  for _, entry in ipairs(list) do
    if entry.path and lstr(entry.path) == wanted then return entry, true end
  end
  for _, entry in ipairs(list) do
    if entry.name and lstr(entry.name) == wanted then
      if partial then return nil, 'Several presets are named "' .. needle
        .. '". Use list_presets and pass its path instead.' end
      partial = entry
    end
  end
  if partial then return partial, true end
  for _, entry in ipairs(list) do
    if entry.name and string.find(lstr(entry.name), wanted, 1, true) then
      if partial then return nil, 'Several presets match "' .. needle
        .. '". Use list_presets and pass an exact name or path.' end
      partial = entry
    end
  end
  if partial then return partial, true end
  return nil, 'No preset matches "' .. tostring(needle) .. '". Call list_presets to see what exists.'
end

-- Looks up the actual LrDevelopPreset object by path (unique on disk).
local function loadPresetObject(entry)
  local folders = rootPresetFolders()
  if not folders then return nil end
  local found
  local function walk(folder, depth)
    if found or depth > 8 then return end
    local ok, presets = LrTasks.pcall(function() return folder:getDevelopPresets() end)
    if ok and type(presets) == 'table' then
      for _, preset in ipairs(presets) do
        local okPath, p = LrTasks.pcall(function() return preset:getPath() end)
        if okPath and entry.path and p == entry.path then
          found = preset
          return
        end
      end
    end
    local children, okChildren
    if type(folder.getSubfolders) == 'function' then
      okChildren, children = LrTasks.pcall(function() return folder:getSubfolders() end)
    elseif type(folder.getChildFolders) == 'function' then
      okChildren, children = LrTasks.pcall(function() return folder:getChildFolders() end)
    end
    if okChildren and type(children) == 'table' then
      for _, child in ipairs(children) do walk(child, depth + 1) end
    end
  end
  for _, folder in ipairs(folders) do walk(folder, 0) end
  return found
end

function Handlers.list_presets(args)
  args = args or {}
  local list = allPresets()
  local filtered = list
  if type(args.query) == 'string' and args.query ~= '' then
    local wanted = lstr(args.query)
    filtered = {}
    for _, entry in ipairs(list) do
      if (entry.name and string.find(lstr(entry.name), wanted, 1, true))
        or (entry.folder and string.find(lstr(entry.folder), wanted, 1, true)) then
        filtered[#filtered + 1] = entry
      end
    end
  end
  local limit = math.min(tonumber(args.limit) or 300, 1000)
  local slice = {}
  for i = 1, math.min(limit, #filtered) do slice[i] = filtered[i] end
  return {
    total = #list,
    returned = #slice,
    presets = listOrEmpty(slice),
    note = 'Identify a preset by its path (unique) or by its exact name.',
  }
end

function Handlers.apply_preset(args)
  args = args or {}
  local photos, err = resolvePhotos(args.photos)
  if not photos then return nil, err end

  local needle = args.preset or args.name
  if isNilish(needle) or tostring(needle) == '' then
    return nil, 'preset is required (a preset name or path from list_presets).'
  end

  local list = allPresets()
  local entry, findErr = findPreset(list, needle)
  if not entry then return nil, findErr end

  local presetObject = loadPresetObject(entry)
  if not presetObject then
    return nil, 'Could not load preset "' .. tostring(entry.name) .. '".'
  end

  local amount = tonumber(args.amount)
  if amount then
    amount = math.floor(clamp(amount, 0, 200)) -- presetAmount must be an integer
  end
  local label = 'MCP: apply preset ' .. tostring(entry.name)
  local applied = 0
  local writeOk, writeErr = withWrite(label, function()
    for _, photo in ipairs(photos) do
      if not isVideo(photo) then
        local okApply = LrTasks.pcall(function()
          if amount then
            photo:applyDevelopPreset(presetObject, nil, amount)
          else
            photo:applyDevelopPreset(presetObject)
          end
        end)
        if okApply then applied = applied + 1 end
      end
    end
  end)
  if not writeOk then return nil, writeErr end

  return {
    preset = { name = entry.name, folder = entry.folder, path = entry.path },
    amount = amount,
    applied = applied,
    requested = #photos,
  }
end

-- ---------------------------------------------------------------------------
-- snapshots (safety net for experimentation)
-- ---------------------------------------------------------------------------

local function photoSnapshots(photo)
  if type(photo.getDevelopSnapshots) ~= 'function' then return nil end
  local ok, snapshots = LrTasks.pcall(function() return photo:getDevelopSnapshots() end)
  if not ok or type(snapshots) ~= 'table' then return nil end
  local out = {}
  for i, snapshot in ipairs(snapshots) do
    local entry = { index = i }
    if type(snapshot) == 'table' then
      -- SDK: "a table of tables ... contains snapshotID, name and id_global"
      entry.id = snapshot.snapshotID or snapshot.uuid or snapshot.id
      entry.name = snapshot.name
      entry.time = snapshot.time or snapshot.timeCreated
    elseif type(snapshot) == 'userdata' then
      local okName, name = LrTasks.pcall(function() return snapshot:getName() end)
      if okName then entry.name = name end
      local okId, id = LrTasks.pcall(function() return snapshot.snapshotID end)
      if okId then entry.id = id end
    else
      entry.name = tostring(snapshot)
    end
    out[i] = entry
  end
  return out
end

function Handlers.snapshots(args)
  args = args or {}
  local action = lstr(args.action or 'list')
  local photo, err = firstPhoto(args)
  if not photo then return nil, err end

  if action == 'list' then
    local snapshots = photoSnapshots(photo)
    if snapshots == nil then
      return nil, 'This Lightroom version does not expose develop snapshots to plugins.'
    end
    return { uuid = photo:getRawMetadata('uuid'), snapshots = listOrEmpty(snapshots) }
  end

  if action == 'create' then
    if isNilish(args.name) or tostring(args.name) == '' then
      return nil, 'name is required for action=create.'
    end
    if type(photo.createDevelopSnapshot) ~= 'function' then
      return nil, 'createDevelopSnapshot is not available in this Lightroom version.'
    end
    local name = tostring(args.name)
    local created = false
    local writeOk, writeErr = withWrite('MCP: create snapshot', function()
      local okCreate, result = LrTasks.pcall(function()
        return photo:createDevelopSnapshot(name, args.updateExisting == true)
      end)
      created = okCreate and result or false
    end, 30)
    if not writeOk then return nil, writeErr end
    if not created then
      return nil, 'A snapshot named "' .. name .. '" already exists. '
        .. 'Pass updateExisting=true to overwrite it.'
    end
    return { created = name, uuid = photo:getRawMetadata('uuid') }
  end

  if action == 'apply' then
    if type(photo.applyDevelopSnapshot) ~= 'function' then
      return nil, 'applyDevelopSnapshot is not available in this Lightroom version.'
    end
    local snapshots = photoSnapshots(photo) or {}
    local wantedId = not isNilish(args.id) and tostring(args.id) or nil
    local wantedName = not isNilish(args.name) and lstr(args.name) or nil
    if not wantedId and not wantedName then
      return nil, 'Pass name or id to apply (use action=list to see snapshots).'
    end

    local match = nil
    for _, entry in ipairs(snapshots) do
      if wantedId and entry.id and tostring(entry.id) == wantedId then
        match = entry
        break
      end
      if wantedName and entry.name and lstr(entry.name) == wantedName then
        match = entry
        break
      end
    end
    if not match then
      return nil, 'No matching snapshot. Use action=list first.'
    end
    if match.id == nil then
      return nil, 'This snapshot has no usable id in this Lightroom version.'
    end

    local writeOk, writeErr = withWrite('MCP: apply snapshot', function()
      photo:applyDevelopSnapshot(match.id)
    end, 30)
    if not writeOk then return nil, writeErr end
    return { applied = match.name or tostring(match.id), uuid = photo:getRawMetadata('uuid') }
  end

  return nil, 'action must be one of: list, create, apply.'
end

-- ---------------------------------------------------------------------------
-- organise / cull
-- ---------------------------------------------------------------------------

function Handlers.set_marks(args)
  args = args or {}
  local photos, err = resolvePhotos(args.photos)
  if not photos then return nil, err end

  local rating = args.rating
  local pick = args.pick
  local colorLabel = args.colorLabel
  local title = args.title
  local caption = args.caption

  if isNilish(rating) and isNilish(pick) and isNilish(colorLabel)
    and isNilish(title) and isNilish(caption) then
    return nil, 'Provide at least one of: rating, pick, colorLabel, title, caption.'
  end

  if not isNilish(rating) then
    local r = tonumber(rating)
    if not r or r < 0 or r > 5 or r % 1 ~= 0 then
      return nil, 'rating must be an integer 0-5.'
    end
    rating = r
  else
    rating = nil
  end

  local pickValue = nil
  if not isNilish(pick) then
    local map = { flagged = 1, picked = 1, unflagged = 0, none = 0, rejected = -1 }
    pickValue = map[lstr(pick)]
    if pickValue == nil then return nil, 'pick must be one of: flagged, unflagged, rejected.' end
  end

  if not isNilish(colorLabel) then
    local allowed = { red = true, yellow = true, green = true, blue = true, purple = true, none = true }
    if not allowed[lstr(colorLabel)] then
      return nil, 'colorLabel must be one of: red, yellow, green, blue, purple, none.'
    end
    colorLabel = lstr(colorLabel)
  end

  local label = 'MCP: set marks'
  local writeOk, writeErr = withWrite(label, function()
    for _, photo in ipairs(photos) do
      if rating ~= nil then photo:setRawMetadata('rating', rating) end
      if pickValue ~= nil then photo:setRawMetadata('pickStatus', pickValue) end
      if colorLabel ~= nil then photo:setRawMetadata('colorNameForLabel', colorLabel) end
      if not isNilish(title) then photo:setRawMetadata('title', tostring(title)) end
      if not isNilish(caption) then photo:setRawMetadata('caption', tostring(caption)) end
    end
  end)
  if not writeOk then return nil, writeErr end

  return { updated = #photos, photos = listOrEmpty(summarize(photos)) }
end

local function keywordByName(name)
  local wanted = lstr(name)
  local found = nil
  local function walk(list, depth)
    if found or depth > 10 then return end
    for _, kw in ipairs(list) do
      local ok, kwName = LrTasks.pcall(function() return kw:getName() end)
      if ok and kwName and lstr(kwName) == wanted then
        found = kw
        return
      end
    end
    for _, kw in ipairs(list) do
      local ok, children = LrTasks.pcall(function() return kw:getChildren() end)
      if ok and type(children) == 'table' then walk(children, depth + 1) end
    end
  end
  walk(cat():getKeywords(), 0)
  return found
end

function Handlers.set_keywords(args)
  args = args or {}
  local photos, err = resolvePhotos(args.photos)
  if not photos then return nil, err end

  local add = asList(args.add) or {}
  local remove = asList(args.remove) or {}
  if #add == 0 and #remove == 0 then
    return nil, 'Provide add (array of keyword strings) and/or remove.'
  end

  local added, removed = 0, 0
  local writeOk, writeErr = withWrite('MCP: set keywords', function()
    local c = cat()
    for _, photo in ipairs(photos) do
      for _, name in ipairs(add) do
        name = tostring(name)
        local keyword = keywordByName(name)
        if not keyword then
          -- createKeyword(name, synonyms, includeOnExport, parent, returnExisting)
          local okCreate, created = LrTasks.pcall(function()
            return c:createKeyword(name, nil, true, nil, true)
          end)
          keyword = okCreate and created or nil
        end
        if keyword and type(keyword) == 'userdata' then
          local okAdd = LrTasks.pcall(function() photo:addKeyword(keyword) end)
          if okAdd then added = added + 1 end
        end
      end

      if #remove > 0 then
        local current = photo:getRawMetadata('keywords') or {}
        for _, name in ipairs(remove) do
          for _, kw in ipairs(current) do
            local okName, kwName = LrTasks.pcall(function() return kw:getName() end)
            if okName and kwName and lstr(kwName) == lstr(name) then
              local okRemove = LrTasks.pcall(function() photo:removeKeyword(kw) end)
              if okRemove then removed = removed + 1 end
              break
            end
          end
        end
      end
    end
  end)
  if not writeOk then return nil, writeErr end

  return {
    updated = #photos,
    keywordAdds = added,
    keywordRemoves = removed,
    photos = listOrEmpty(summarize(photos)),
  }
end

-- ---------------------------------------------------------------------------
-- collections
-- ---------------------------------------------------------------------------

local function collectionEntries(includeCounts)
  local c = cat()
  local out = {}

  local function walkSets(sets, depth, parentPath)
    if depth > 8 then return end
    for _, set in ipairs(sets) do
      local okName, name = LrTasks.pcall(function() return set:getName() end)
      local okId, id = LrTasks.pcall(function() return set.localIdentifier end)
      out[#out + 1] = {
        type = 'set',
        name = okName and name or nil,
        localIdentifier = okId and id or nil,
        parent = parentPath,
      }
      local okChildren, children = LrTasks.pcall(function() return set:getChildCollectionSets() end)
      if okChildren and type(children) == 'table' then
        walkSets(children, depth + 1, (okName and name) or parentPath)
      end
    end
  end

  local function walkCollections(list, depth, parentPath)
    if depth > 8 then return end
    for _, collection in ipairs(list) do
      local okName, name = LrTasks.pcall(function() return collection:getName() end)
      local okId, id = LrTasks.pcall(function() return collection.localIdentifier end)
      local entry = {
        type = 'collection',
        name = okName and name or nil,
        localIdentifier = okId and id or nil,
        parent = parentPath,
      }
      if includeCounts then
        local okPhotos, photos = LrTasks.pcall(function() return collection:getPhotos() end)
        if okPhotos and type(photos) == 'table' then entry.photoCount = #photos end
      end
      out[#out + 1] = entry

      local okChildren, children = LrTasks.pcall(function()
        return collection:getChildCollections()
      end)
      if okChildren and type(children) == 'table' then
        walkCollections(children, depth + 1, (okName and name) or parentPath)
      end
    end
  end

  local okSets, sets = LrTasks.pcall(function() return c:getChildCollectionSets() end)
  if okSets and type(sets) == 'table' then walkSets(sets, 0, nil) end
  local okCols, collections = LrTasks.pcall(function() return c:getChildCollections() end)
  if okCols and type(collections) == 'table' then walkCollections(collections, 0, nil) end

  return out
end

function Handlers.list_collections(args)
  args = args or {}
  local entries = collectionEntries(args.includeCounts == true)
  local filtered = entries
  if type(args.query) == 'string' and args.query ~= '' then
    local wanted = lstr(args.query)
    filtered = {}
    for _, entry in ipairs(entries) do
      if entry.name and string.find(lstr(entry.name), wanted, 1, true) then
        filtered[#filtered + 1] = entry
      end
    end
  end
  local limit = math.min(tonumber(args.limit) or 300, 1000)
  local slice = {}
  for i = 1, math.min(limit, #filtered) do slice[i] = filtered[i] end
  return { total = #entries, returned = #slice, collections = listOrEmpty(slice) }
end

function Handlers.create_collection(args)
  args = args or {}
  if isNilish(args.name) or tostring(args.name) == '' then
    return nil, 'name is required.'
  end
  local name = tostring(args.name)

  local parent = nil
  if not isNilish(args.parent) then
    local wanted = lstr(args.parent)
    local okSets, sets = LrTasks.pcall(function() return cat():getChildCollectionSets() end)
    if okSets and type(sets) == 'table' then
      for _, set in ipairs(sets) do
        local okName, setName = LrTasks.pcall(function() return set:getName() end)
        if okName and setName and lstr(setName) == wanted then parent = set end
      end
    end
    if not parent then
      return nil, 'No collection set named "' .. tostring(args.parent) .. '" found.'
    end
  end

  local created = nil
  local writeOk, writeErr = withWrite('MCP: create collection', function()
    local okCreate, result = LrTasks.pcall(function()
      return cat():createCollection(name, parent, true)
    end)
    if okCreate then created = result end
  end, 30)
  if not writeOk then return nil, writeErr end
  if not created then return nil, 'Collection could not be created.' end

  local okName, createdName = LrTasks.pcall(function() return created:getName() end)
  local okId, id = LrTasks.pcall(function() return created.localIdentifier end)
  return {
    created = okName and createdName or name,
    localIdentifier = okId and id or nil,
    photoCount = (function()
      local ok, photos = LrTasks.pcall(function() return created:getPhotos() end)
      if ok and type(photos) == 'table' then return #photos end
      return 0
    end)(),
  }
end

function Handlers.add_to_collection(args)
  args = args or {}
  local photos, err = resolvePhotos(args.photos)
  if not photos then return nil, err end
  if isNilish(args.collection) then return nil, 'collection is required.' end

  local wanted = lstr(args.collection)
  local all = {}
  local function collect(list, depth)
    if depth > 8 then return end
    for _, collection in ipairs(list) do
      local okName, name = LrTasks.pcall(function() return collection:getName() end)
      if okName and name then
        all[#all + 1] = { obj = collection, name = lstr(name) }
      end
      local okChildren, children = LrTasks.pcall(function()
        return collection:getChildCollections()
      end)
      if okChildren and type(children) == 'table' then collect(children, depth + 1) end
    end
  end
  local okTop, top = LrTasks.pcall(function() return cat():getChildCollections() end)
  if okTop and type(top) == 'table' then collect(top, 0) end

  -- Exact name wins over a substring match, so "Trips" picks the collection
  -- actually called "Trips" rather than "Work Trips".
  local match = nil
  for _, entry in ipairs(all) do
    if entry.name == wanted then match = entry.obj break end
  end
  if not match then
    for _, entry in ipairs(all) do
      if string.find(entry.name, wanted, 1, true) then match = entry.obj break end
    end
  end
  if not match then
    return nil, 'No collection matches "' .. tostring(args.collection) .. '". Use list_collections.'
  end

  local removing = args.remove == true
  local count = 0
  local writeOk, writeErr = withWrite('MCP: update collection', function()
    local okUpdate = LrTasks.pcall(function()
      if removing then
        match:removePhotos(photos)
      else
        match:addPhotos(photos)
      end
    end)
    if okUpdate then count = #photos end
  end)
  if not writeOk then return nil, writeErr end

  local okName, name = LrTasks.pcall(function() return match:getName() end)
  return {
    collection = okName and name or tostring(args.collection),
    action = removing and 'removed' or 'added',
    count = count,
  }
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

-- Renders a JPEG preview of the photo as it looks *with current develop
-- settings*, and waits for Lightroom to finish (builds previews on demand).
local function renderJpeg(photo, edge)
  local jpegData, failReason = nil, nil
  local done = false

  local request = photo:requestJpegThumbnail(edge, edge, function(data, err)
    if done then return end
    done = true
    if data then
      jpegData = data
    else
      failReason = err or 'unknown error'
    end
  end)

  local deadline = os.time() + 90
  while not done and os.time() < deadline do
    LrTasks.sleep(0.05)
  end
  request = nil -- release only once the callback has fired (or we gave up)

  if not done then
    return nil, 'Timed out after 90s waiting for Lightroom to render a preview.'
  end
  if not jpegData then
    return nil, 'Preview render failed: ' .. tostring(failReason)
  end
  return jpegData
end

function Handlers.render_preview(args)
  args = args or {}
  local photo, err = firstPhoto(args)
  if not photo then return nil, err end

  local destDir = args.destDir
  if type(destDir) ~= 'string' or destDir == '' then
    return nil, 'destDir is required (the MCP server normally supplies it).'
  end

  local edge = clamp(math.floor(tonumber(args.longEdge) or 1200), 64, 4096)
  local data, renderErr = renderJpeg(photo, edge)
  if not data then return nil, renderErr end

  LrTasks.pcall(function() LrFileUtils.createAllDirectories(destDir) end)

  local uuid = photo:getRawMetadata('uuid') or 'unknown'
  local safeId = string.gsub(uuid, '[^%w%-]', '_')
  local outPath = LrPathUtils.child(destDir, 'preview_' .. safeId .. '.jpg')

  local okWrite, writeResult = LrTasks.pcall(function()
    return LrFileUtils.writeFile(outPath, data)
  end)
  if not okWrite then
    return nil, 'Could not write preview file: ' .. tostring(writeResult)
  end
  if not LrFileUtils.exists(outPath) then
    return nil, 'Preview file was not written: ' .. outPath
  end

  return {
    path = outPath,
    bytes = #data,
    uuid = uuid,
    requestedEdge = edge,
  }
end

function Handlers.export_photos(args)
  args = args or {}
  local photos, err = resolvePhotos(args.photos)
  if not photos then return nil, err end

  local destination = args.destination
  if type(destination) ~= 'string' or destination == '' then
    return nil, 'destination is required (an absolute folder path).'
  end

  local format = lstr(args.format or 'jpeg')
  if format == 'jpg' then format = 'jpeg' end
  local formats = {
    jpeg = 'JPEG', jpg = 'JPEG', tiff = 'TIFF', tif = 'TIFF', png = 'PNG',
    dng = 'DNG', psd = 'PSD',
  }
  local lrFormat = formats[format]
  if not lrFormat then
    return nil, 'format must be one of: jpeg, tiff, png, dng, psd.'
  end

  local okDir, dirResult = LrTasks.pcall(function()
    return LrFileUtils.createAllDirectories(destination)
  end)
  if not okDir then
    return nil, 'Could not create destination folder: ' .. tostring(dirResult)
  end

  local settings = {
    LR_format = lrFormat,
    LR_export_destinationType = 'specificFolder',
    LR_export_destinationPathPrefix = destination,
    LR_export_useSubfolder = false,
    LR_reimportExportedPhoto = false,
    -- Valid values (SDK guide): ask | rename | overwrite | skip. "ask" would
    -- pop a dialog and block the agent, so it is opt-in only.
    LR_collisionHandling = (function()
      local wanted = lstr(args.collision or 'overwrite')
      if wanted == 'ask' or wanted == 'rename' or wanted == 'skip'
        or wanted == 'overwrite' then
        return wanted
      end
      return 'overwrite'
    end)(),
    LR_export_colorSpace = (args.colorSpace == 'adobeRGB') and 'AdobeRGB' or 'sRGB',
  }

  local quality = tonumber(args.quality)
  if lrFormat == 'JPEG' then
    settings.LR_jpeg_quality = quality and clamp(quality, 0, 1) or 0.9
  elseif lrFormat == 'TIFF' or lrFormat == 'PSD' then
    settings.LR_export_bitDepth = (tonumber(args.bitDepth) == 16) and 16 or 8
  end

  local longEdge = tonumber(args.longEdge)
  if longEdge and longEdge > 0 then
    settings.LR_size_doConstrain = true
    settings.LR_size_resizeType = 'dimensions'
    settings.LR_size_maxWidth = math.floor(longEdge)
    settings.LR_size_maxHeight = math.floor(longEdge)
    settings.LR_size_units = 'pixels'
  else
    settings.LR_size_doConstrain = false
  end

  if args.includeWatermark == true then settings.LR_includeWatermark = true end

  local session = LrExportSession {
    photosToExport = photos,
    exportSettings = settings,
  }

  local exported, failed = {}, {}
  for _, rendition in session:renditions() do
    local okRender, success, pathOrMessage = LrTasks.pcall(function()
      return rendition:waitForRender()
    end)
    if not okRender then
      failed[#failed + 1] = tostring(success)
    elseif success then
      exported[#exported + 1] = pathOrMessage
    else
      failed[#failed + 1] = tostring(pathOrMessage)
    end
  end

  return {
    destination = destination,
    format = lrFormat,
    exported = listOrEmpty(exported),
    exportedCount = #exported,
    failed = listOrEmpty(failed),
  }
end

return Handlers
