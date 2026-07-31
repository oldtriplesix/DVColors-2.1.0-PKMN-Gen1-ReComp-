-- DV Colors
-- ---------------------------------------------------------------------
-- Per-Pokemon palette variation keyed on DVs, in the spirit of the
-- Stadium games' hue sliding (which actually keys on nickname + OT + TID;
-- DVs are the right key here because wild mons share all three of those).
--
-- How it hooks in, since there is no per-mon palette hook:
--
--   makeBattler() calls Sprites.path(...) and then, on the very next
--   expression, monPalette(data, species). Sprites.path fires the
--   `pokemon.sprite` hook with ctx.mon in scope, so this mod uses that
--   moment to write a DV-derived palette into data.palettes.palettes and
--   point the species record's `palette` field at it. Both PaletteFX.monPal
--   and PaletteFX.monPalName honor that per-record override, and the
--   getImage cache is keyed on the palette NAME -- so each DV bucket gets
--   its own correctly cached tinted sprite rather than re-mapping pixels
--   every frame.
--
--   As of engine 0.1.31 the Summary screen resolves its pic through the
--   same seam WITH the mon in scope (SummaryMenu.new passes
--   { mon = mon, kind = "summary" }), so the tint now follows a mon onto
--   its status screen for free -- the pre-0.1.31 "summary shows the last
--   battler's tint" leak is gone at the source.
--
-- The species record is restored on every call where there is no mon, so a
-- Pokedex entry or a Transform pic never inherits a battler's tint. It is
-- ALSO restored before computing a variant, so the base palette is always
-- read from the true original rather than from this mod's own previous
-- override (which would compound the rotation on repeat encounters of the
-- same species).

local mod = ...

-- ── options ────────────────────────────────────────────────────────────

-- Choice rows are {label, value} pairs: the manager reads choice[1] as the
-- display text and choice[2] as the stored value. Bare strings leave
-- choice[2] nil, which makes the row unsteppable.
-- The value IS the max hue rotation in degrees, so there is no second table
-- to keep in sync -- and a save that stored 8/15/30 under the old labels
-- resolves to the same behaviour under the new ones. Stadium bounded its
-- shifts per species so a Charizard never came out green; on a 4-colour
-- palette STADIUM keeps inside the "slightly odd one"
-- band; WILD (60) deliberately trades that for spectacle, capped where the
-- worst bucket still sits 80 degrees shy of the shiny rotation.
mod.options:define({
  { key = "intensity", type = "choice", label = "VARIANCE", default = 15,
    choices = { { "OFF", 0 }, { "MILD", 8 }, { "STADIUM", 15 }, { "WILD", 60 } } },
  { key = "shinies", type = "toggle", label = "DV SHINIES", default = true },
  { key = "greyBoost", type = "toggle", label = "GREY BOOST", default = false },
})

-- 15, not 16. The DV key packs the four DVs as hex nybbles, so with any
-- bucket count sharing a factor with 16, `key % BUCKETS` collapses onto the
-- low nybble and only the Attack DV ends up mattering (the v1.1.0 bug).
-- 15 is coprime with 16, so all four DVs contribute to the bucket.
local BUCKETS = 15
local VANILLA = (BUCKETS - 1) / 2 -- bucket 7: the untouched middle
-- Shinies get a rotation far outside the variance band so they can never be
-- confused with an ordinary high-DV roll.
local SHINY_ROTATION = 140
local SHINY_SAT = 1.25

-- ── colour maths ───────────────────────────────────────────────────────

local function toHsl(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local max, min = math.max(r, g, b), math.min(r, g, b)
  local l = (max + min) / 2
  if max == min then return 0, 0, l end
  local d = max - min
  local s = l > 0.5 and d / (2 - max - min) or d / (max + min)
  local h
  if max == r then
    h = (g - b) / d + (g < b and 6 or 0)
  elseif max == g then
    h = (b - r) / d + 2
  else
    h = (r - g) / d + 4
  end
  return h / 6, s, l
end

local function hueToRgb(p, q, t)
  if t < 0 then t = t + 1 end
  if t > 1 then t = t - 1 end
  if t < 1 / 6 then return p + (q - p) * 6 * t end
  if t < 1 / 2 then return q end
  if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
  return p
end

local function toRgb(h, s, l)
  if s == 0 then
    local v = math.floor(l * 255 + 0.5)
    return v, v, v
  end
  local q = l < 0.5 and l * (1 + s) or l + s - l * s
  local p = 2 * l - q
  return math.floor(hueToRgb(p, q, h + 1 / 3) * 255 + 0.5),
         math.floor(hueToRgb(p, q, h) * 255 + 0.5),
         math.floor(hueToRgb(p, q, h - 1 / 3) * 255 + 0.5)
end

local function clamp01(v)
  return v < 0 and 0 or (v > 1 and 1 or v)
end

-- Rotate hue by `degrees`. satScale multiplies saturation; satFloor lifts
-- near-greyscale colours far enough that a hue rotation is visible at all
-- (rotating a zero-saturation grey is a no-op, which is why Unown was
-- immune to this in Stadium -- Magnemite and Onix have the same problem).
local function shiftPalette(colors, degrees, satScale, satFloor)
  local out = {}
  for i = 1, 4 do
    local c = colors[i]
    local r = c[1] or c.r or 0
    local g = c[2] or c.g or 0
    local b = c[3] or c.b or 0
    local h, s, l = toHsl(r, g, b)
    -- leave the extremes alone: they are the DMG white and black that carry
    -- the sprite's readable silhouette
    if l > 0.02 and l < 0.98 then
      if satFloor and s < satFloor then s = satFloor end
      s = clamp01(s * (satScale or 1))
      h = (h + degrees / 360) % 1
      if h < 0 then h = h + 1 end
      local nr, ng, nb = toRgb(h, s, l)
      out[i] = { nr, ng, nb }
    else
      out[i] = { r, g, b }
    end
  end
  return out
end

-- ── DV keying ──────────────────────────────────────────────────────────

-- Stadium's Smeargle Sub ID packs the DVs as hex nybbles in special,
-- defense, speed, attack order and takes a remainder. Same packing here,
-- so the ordering matches the one piece of the original this can mirror.
local function dvKey(dvs)
  return ((((dvs.special or 0) % 16) * 16
          + ((dvs.defense or 0) % 16)) * 16
          + ((dvs.speed or 0) % 16)) * 16
          + ((dvs.attack or 0) % 16)
end

-- Bucket to a symmetric offset so the VANILLA middle bucket is the
-- untouched colour and the spread fans out either side of it.
local function bucketOffset(key, spread)
  local bucket = key % BUCKETS
  return ((bucket - VANILLA) / VANILLA) * spread, bucket
end

-- ── engine handles ─────────────────────────────────────────────────────

-- Stats is on the loader's supported-require list precisely for this.
local okStats, Stats = pcall(require, "src.pokemon.Stats")
if not okStats then Stats = nil end

-- PaletteFX gives the palette for the ACTIVE colour pack, so variants track
-- the player's COLORS setting instead of freezing the ROM defaults. It is an
-- engine internal, hence the declared permission; the raw data tables are
-- the fallback if it ever moves.
local okFX, PaletteFX = pcall(require, "src.render.PaletteFX")
if not okFX then PaletteFX = nil end

local function basePalette(data, species)
  if PaletteFX and PaletteFX.monPal then
    local colors = PaletteFX.monPal(data, species)
    if colors then return colors end
  end
  local palettes = data and data.palettes
  if not palettes then return nil end
  local name = palettes.pokemon and palettes.pokemon[species] or "MEWMON"
  return palettes.palettes and palettes.palettes[name]
end

local function packTag()
  return (PaletteFX and PaletteFX.mode) or "base"
end

-- OG RED colours the whole battle with the boot-ROM's single global
-- palette: PaletteFX.monPal returns that global BG early and never reads
-- the per-record override, while monPalName still would -- so a variant
-- here can never render AND would poison the image cache with keys whose
-- colours are the untinted global red. One global palette with no
-- per-species colour is also just what OG RED is; skipping is the
-- faithful behaviour, not a limitation.
local function packSupportsVariants()
  return packTag() ~= "ogred"
end

-- ── override bookkeeping ───────────────────────────────────────────────

local NONE = {} -- sentinel: the species had no palette field of its own
local original = {} -- [species] = previous def.palette, or NONE

local function remember(def, species)
  if original[species] == nil then
    original[species] = def.palette or NONE
  end
end

local function restore(data, species)
  local saved = original[species]
  if saved == nil then return end
  local def = data and data.pokemon and data.pokemon[species]
  if def then
    def.palette = (saved ~= NONE) and saved or nil
  end
  original[species] = nil
end

local function ensurePalette(data, name, colors)
  local store = data and data.palettes and data.palettes.palettes
  if not store then return false end
  if not store[name] then store[name] = colors end
  return true
end

-- ── the hook ───────────────────────────────────────────────────────────

local function variantFor(data, species, mon)
  local dvs = mon and mon.dvs
  if type(dvs) ~= "table" then return nil end
  if not packSupportsVariants() then return nil end

  local spread = tonumber(mod.options:get("intensity")) or 0
  local shiny = mod.options:get("shinies") and Stats and Stats.isShiny(dvs)
  if spread == 0 and not shiny then return nil end

  local base = basePalette(data, species)
  if not base or #base < 4 then return nil end

  local degrees, satScale, satFloor, tag
  if shiny then
    degrees, satScale = SHINY_ROTATION, SHINY_SAT
    tag = "S"
  else
    local offset, bucket = bucketOffset(dvKey(dvs), spread)
    if bucket == VANILLA then return nil end -- the vanilla bucket
    degrees, satScale = offset, 1
    tag = tostring(bucket)
  end
  if mod.options:get("greyBoost") then satFloor = 0.18 end

  -- the name is the getImage cache key, so it has to capture everything
  -- that changes the pixels: species, pack, variance band, bucket, and the
  -- grey-boost flag (which alters saturation without touching the bucket)
  local name = ("DVC_%s_%s_%s_%s%s"):format(
    tostring(species), packTag(),
    shiny and "sh" or tostring(math.floor(spread)), tag,
    satFloor and "g" or "")

  if not ensurePalette(data, name,
       shiftPalette(base, degrees, satScale, satFloor)) then
    return nil
  end
  return name
end

mod.hooks:wrap("pokemon.sprite", function(continue, path, ctx)
  local data, species, mon = ctx.data, ctx.species, ctx.mon
  local def = data and data.pokemon and data.pokemon[species]

  if not def or ctx.trueColor then
    -- trueColor art opts out of the 4-shade quantize entirely, so there is
    -- no palette to shift
    return continue(path, ctx)
  end

  -- Always put the true original back BEFORE computing anything. For the
  -- no-mon case (Pokedex, Transform pic, menus) that is the whole job. For
  -- the mon case it is what stops basePalette() from reading this mod's
  -- own previous override off the species record and rotating an
  -- already-rotated palette -- monPal honours def.palette, so a second
  -- encounter of the same species would otherwise compound the shift.
  restore(data, species)

  if not mon then
    return continue(path, ctx)
  end

  local name = variantFor(data, species, mon)
  if name then
    remember(def, species)
    def.palette = name
  end
  return continue(path, ctx)
end)

-- a fresh file must not keep the last session's overrides pinned
mod.events:on("save.loaded", function()
  original = {}
end)

mod.log:info("dv colors ready")
