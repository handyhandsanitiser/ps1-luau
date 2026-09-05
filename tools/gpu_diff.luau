-- gpu differential: core GPU (src/shared/PS1/GPU.luau) vs tools/gpu_ref.luau, command by command.
-- feeds both engines byte-identical gp0/gp1 streams and compares, after every settled command, the
-- exact vram words written (nil-gated .vramLog + a final full sweep), clut cache, gpustat bits,
-- draw state, and vram->cpu read words.  comparison happens at command boundaries because the
-- fifo layouts differ; one side settling alone is a word-count divergence.
-- coverage: a scripted corpus over every command class, a gp1 sweep, a fixed-seed fuzz, and
-- literal-color oracle phases pinning rules engine agreement cannot see (dither, 8bpp, blending,
-- masks, v2v direction, shading/uv interpolation, tex windows, clipping, gpustat encoding,
-- polylines, timing, transfer geometry).  the rng is fixed-seed so any drift reproduces.
-- known boundaries: the reference omits the display readout pipeline (display fields fed for
-- parity, not compared; core-only pins for bit 31 / composed bits), and in the degenerate
-- polyline regime the core ends on any terminator-pattern word while the reference scans
-- phase-aligned slots -- clean streams can't hit that.  requireSettled after every feed enforces
-- the command-completion invariant (it caught an "agreed runaway" word-count class in the fuzz
-- generators).
-- usage: lune run tools/gpu_diff.luau   (or via tools/run.luau gpudiff)

local Loader = require("./lib/ps1loader")
local requirePs1 = Loader.createRequire()
local GPU = requirePs1("GPU")
local GPURef = require("./gpu_ref")

local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift
local bnot = bit32.bnot

local VRAM_W = 1024
local VRAM_H = 512
local VRAM_SIZE = VRAM_W * VRAM_H

local newRng = require("./lib/xorshift")

local function vramFirstDiff(a, b)
	for i = 1, VRAM_SIZE do
		local va = a[i] or 0
		local vb = b[i] or 0
		if va ~= vb then
			local x = (i - 1) % VRAM_W
			local y = math.floor((i - 1) / VRAM_W)
			return x, y, va, vb
		end
	end
end

local failures = 0

local function fail(msg)
	failures += 1
	print("GPU DIFF " .. msg)
end

-- static state comparison (vram handled separately, display pipeline excluded).
local function compareState(tag, gpu, ref)
	if (gpu.status or 0) ~= (ref.gpustat or 0) then
		fail(string.format("%s: gpustat core=%08X ref=%08X", tag, gpu.status, ref.gpustat))
	end
	if (gpu.drawModeReg or 0) ~= (ref.drawModeReg or 0) then
		fail(string.format("%s: drawModeReg core=%04X ref=%04X", tag, gpu.drawModeReg, ref.drawModeReg))
	end
	if (gpu.texturePaletteReg or 0) ~= (ref.texturePaletteReg or 0) then
		fail(string.format("%s: texturePaletteReg core=%04X ref=%04X", tag, gpu.texturePaletteReg, ref.texturePaletteReg))
	end
	if (gpu.gpuread or 0) ~= (ref.gpuread or 0) then
		fail(string.format("%s: gpuread core=%08X ref=%08X", tag, gpu.gpuread or 0, ref.gpuread or 0))
	end
	if (gpu.drawLeft or 0) ~= (ref.drawingArea.left or 0)
		or (gpu.drawTop or 0) ~= (ref.drawingArea.top or 0)
		or (gpu.drawRight or 0) ~= (ref.drawingArea.right or 0)
		or (gpu.drawBottom or 0) ~= (ref.drawingArea.bottom or 0) then
		fail(string.format("%s: drawingArea core=%d,%d-%d,%d ref=%d,%d-%d,%d", tag,
			gpu.drawLeft, gpu.drawTop, gpu.drawRight, gpu.drawBottom,
			ref.drawingArea.left, ref.drawingArea.top, ref.drawingArea.right, ref.drawingArea.bottom))
	end
	if (gpu.drawOffX or 0) ~= (ref.drawingOffset.x or 0)
		or (gpu.drawOffY or 0) ~= (ref.drawingOffset.y or 0) then
		fail(string.format("%s: drawingOffset core=%d,%d ref=%d,%d", tag,
			gpu.drawOffX, gpu.drawOffY, ref.drawingOffset.x, ref.drawingOffset.y))
	end
	if (gpu.setTextureDisableMask or false) ~= (ref.setTextureDisableMask or false) then
		fail(string.format("%s: setTextureDisableMask core=%s ref=%s", tag,
			tostring(gpu.setTextureDisableMask), tostring(ref.setTextureDisableMask)))
	end
	if (gpu.textureEnableMask or false) ~= (ref.textureEnableMask or false) then
		fail(string.format("%s: textureEnableMask core=%s ref=%s", tag,
			tostring(gpu.textureEnableMask), tostring(ref.textureEnableMask)))
	end
	local coreClut = gpu.clut
	local refClut = ref.clut
	for i = 1, 256 do
		if (coreClut[i] or 0) ~= (refClut[i] or 0) then
			fail(string.format("%s: clut[%d] core=%04X ref=%04X", tag, i - 1, coreClut[i] or 0, refClut[i] or 0))
			break
		end
	end
end

-- incremental vram compare: each engine logs every word it writes since the last compare
-- (flat { first, count, ... } spans in .vramLog); the final full sweep in main() proves the logs missed nothing.
local function checkVramLog(tag, log, a, b, lg, lr)
	local n = #log
	for i = 1, n, 2 do
		local first = log[i]
		local last = first + log[i + 1] - 1
		for j = first, last do
			if a[j] ~= b[j] then
				local x = (j - 1) % VRAM_W
				local yy = math.floor((j - 1) / VRAM_W)
				fail(string.format("%s: vram diverged at (%d,%d) core=%04X ref=%04X",
					tag, x, yy, a[j], b[j]))
				table.clear(lg)
				table.clear(lr)
				return false
			end
		end
	end
	return true
end

local function compareVram(tag, gpu, ref)
	local lg, lr = gpu.vramLog, ref.vramLog
	if not (lg and lr) then
		-- logging not attached: fall back to a full exact sweep.
		local x, y, va, vb = vramFirstDiff(gpu.vram, ref.vram)
		if x then
			fail(string.format("%s: vram diverged at (%d,%d) core=%04X ref=%04X", tag, x, y, va, vb))
		end
		return
	end
	local a, b = gpu.vram, ref.vram
	if not checkVramLog(tag, lg, a, b, lg, lr) then return end
	if not checkVramLog(tag, lr, a, b, lg, lr) then return end
	table.clear(lg)
	table.clear(lr)
end

-- feed one gp0 word to both and settle-compare if both reached a command
-- boundary.  returns true if the call consumed the word without a failure.
local totalSettles = 0

local function feedAndSettle(tag, gpu, ref, word)
	gpu:writeGp0(word)
	ref:gp0Word(word)
	local coreSettled = gpu.gp0mode == "cmd" and #gpu.gp0buf == 0
	local refSettled = ref.blitterState == "idle" and #ref.fifo == 0
	if coreSettled ~= refSettled then
		fail(string.format("%s: state machine diverged after %08X (core %s, ref %s)",
			tag, word, coreSettled and "settled" or "pending", refSettled and "settled" or "pending"))
		return false
	end
	if coreSettled then
		totalSettles += 1
		local before = failures
		compareState(tag, gpu, ref)
		compareVram(tag, gpu, ref)
		if failures > before then
			return false
		end
	end
	return true
end

local function feedWords(tag, gpu, ref, words)
	for _, w in ipairs(words) do
		if not feedAndSettle(tag, gpu, ref, w) then
			return false
		end
	end
	return true
end

-- both engines must be back at a command boundary after each self-contained stream; a command that leaves either pending is a generator bug or an "agreed runaway" decode drift.
local function requireSettled(tag, gpu, ref)
	local coreSettled = gpu.gp0mode == "cmd" and #gpu.gp0buf == 0
	local refSettled = ref.blitterState == "idle" and #ref.fifo == 0
	if not (coreSettled and refSettled) then
		fail(string.format("%s: command did not complete (core %s, ref %s)", tag,
			coreSettled and "settled" or (gpu.gp0mode .. " buf=" .. #gpu.gp0buf),
			refSettled and "settled" or (ref.blitterState .. " fifo=" .. #ref.fifo)))
		return false
	end
	return true
end

-- gp1 write to both, then compare.
local function gp1Write(tag, gpu, ref, value)
	gpu:writeGp1(value)
	ref:gp1(value)
	compareState(tag, gpu, ref)
end

-- drive a vram->cpu transfer to completion: the command words are already fed,
-- so read words out of both and compare each.
local function drainV2C(tag, gpu, ref)
	local guard = 0
	while not (gpu.gp0mode == "cmd" and #gpu.gp0buf == 0) do
		guard += 1
		if guard > 1024 * 1024 then
			fail(tag .. ": vram->cpu transfer never completed")
			return false
		end
		local coreWord = gpu:read(0x1F801810)
		local refWord = ref:readGpuData()
		if coreWord ~= refWord then
			fail(string.format("%s: vram->cpu read core=%08X ref=%08X", tag, coreWord, refWord))
			return false
		end
	end
	if ref.blitterState ~= "idle" then
		fail(tag .. ": ref vram->cpu transfer never completed")
		return false
	end
	totalSettles += 1
	compareState(tag, gpu, ref)
	compareVram(tag, gpu, ref)
	return true
end

-- ---- word builders ----------------------------------------------------------

local function xyWord(x, y)
	return bor(band(x, 0xFFFF), lshift(band(y, 0xFFFF), 16))
end

local function colorWord(cmd, r, g, b)
	return bor(lshift(cmd, 24), r, lshift(g, 8), lshift(b, 16))
end

local function drawModeWord(pageX, pageY, texMode, semi, dither, drawToDisplay, texDisable)
	local v = band(pageX, 0xF)
	v = bor(v, lshift(band(pageY, 1), 4))
	v = bor(v, lshift(band(semi, 3), 5))
	v = bor(v, lshift(band(texMode, 3), 7))
	v = bor(v, lshift(band(dither, 1), 9))
	v = bor(v, lshift(band(drawToDisplay, 1), 10))
	v = bor(v, lshift(band(texDisable, 1), 11))
	return bor(0xE1000000, band(v, 0x1FFF))
end

-- ---- texture/CLUT fixture ---------------------------------------------------

-- upload a deterministic 4bpp texture page (64x64 at 0,0) and a 16-entry clut (at 0,508) so textured draws sample known data.
local function uploadFixture(gpu, ref, rng, tag)
	local all = { 0xA0000000, xyWord(0, 0), xyWord(64, 64) }
	-- texture: 64x64, 4bpp = 2 pixels per word, 32 words per row, 64 rows.
	local pattern = rng()
	for row = 0, 63 do
		for col = 0, 31 do
			local lo = band(rshift(pattern, band(row * 32 + col * 2, 31)) + row + col, 0xF)
			local hi = band(rshift(pattern, band(row * 32 + col * 2 + 1, 31)) + row * 2 + col, 0xF)
			table.insert(all, bor(lo, lshift(hi, 4)))
		end
	end
	-- clut: 16 entries = 16 pixels = 8 words at (0,508)
	table.insert(all, 0xA0000000)
	table.insert(all, xyWord(0, 508))
	table.insert(all, xyWord(16, 1))
	for i = 0, 7 do
		local c0 = band(i * 0x421 + rng(), 0x7FFF)
		local c1 = band(i * 0x421 + rng(), 0x7FFF)
		table.insert(all, bor(c0, lshift(c1, 16)))
	end
	return all, lshift(508, 6) -- clutY = 508
end

-- ---- scripted corpus --------------------------------------------------------

local function scripted(gpu, ref, rng)
	local tag = "[corpus]"
	local words = {}
	-- baseline config: draw area = full vram, offset zero, 4bpp texpage at 0,0.
	table.insert(words, drawModeWord(0, 0, 0, 0, 0, 0, 0))
	table.insert(words, bor(0xE3000000, 0))                        -- area top-left (0,0)
	table.insert(words, bor(0xE4000000, bor(1023, lshift(511, 10)))) -- area bottom-right
	table.insert(words, bor(0xE5000000, 0))                        -- offset (0,0)
	if not feedWords(tag, gpu, ref, words) then return end

	local cases = {}

	-- fill rectangles
	table.insert(cases, { "fill center", { colorWord(0x02, 40, 80, 120), xyWord(100, 100), xyWord(64, 32) } })
	table.insert(cases, { "fill right edge", { colorWord(0x02, 255, 0, 0), xyWord(1000, 100), xyWord(64, 32) } })
	table.insert(cases, { "fill bottom edge", { colorWord(0x02, 0, 255, 0), xyWord(100, 500), xyWord(64, 32) } })
	table.insert(cases, { "fill x16-align", { colorWord(0x02, 0, 0, 255), xyWord(105, 200), xyWord(40, 16) } })
	table.insert(cases, { "fill zero size", { colorWord(0x02, 10, 10, 10), xyWord(50, 50), xyWord(0, 0) } })
	table.insert(cases, { "fill width wrap", { colorWord(0x02, 30, 30, 30), xyWord(1020, 50), xyWord(32, 16) } })

	-- lines
	table.insert(cases, { "line h", { colorWord(0x40, 200, 100, 50), xyWord(10, 200), xyWord(300, 200) } })
	table.insert(cases, { "line v", { colorWord(0x41, 50, 200, 100), xyWord(150, 10), xyWord(150, 400) } })
	table.insert(cases, { "line diag", { colorWord(0x42, 100, 100, 200), xyWord(0, 0), xyWord(511, 511) } })
	table.insert(cases, { "line offscreen", { colorWord(0x43, 255, 255, 255), xyWord(2000, 2000), xyWord(2100, 2100) } })
	table.insert(cases, { "line degenerate", { colorWord(0x40, 90, 90, 90), xyWord(77, 77), xyWord(77, 77) } })
	table.insert(cases, { "line gouraud", { colorWord(0x50, 255, 0, 0), xyWord(20, 300), colorWord(0, 0, 255, 0), xyWord(600, 60) } })

	-- rectangles, all size classes
	table.insert(cases, { "rect var", { colorWord(0x60, 10, 200, 30), xyWord(30, 30), xyWord(70, 45) } })
	table.insert(cases, { "rect 1x1", { colorWord(0x68, 200, 10, 30), xyWord(400, 300) } })
	table.insert(cases, { "rect 8x8", { colorWord(0x70, 10, 30, 200), xyWord(80, 90) } })
	table.insert(cases, { "rect 16x16", { colorWord(0x78, 30, 200, 10), xyWord(200, 200) } })
	table.insert(cases, { "rect var offscreen", { colorWord(0x60, 60, 60, 60), xyWord(1200, 1200), xyWord(64, 64) } })

	-- triangles and quads
	table.insert(cases, { "tri mono", { colorWord(0x20, 255, 255, 0), xyWord(100, 100), xyWord(200, 100), xyWord(150, 200) } })
	table.insert(cases, { "tri mono inverted", { colorWord(0x21, 255, 0, 255), xyWord(100, 200), xyWord(200, 100), xyWord(300, 300) } })
	table.insert(cases, { "tri shaded", { colorWord(0x30, 255, 0, 0), xyWord(100, 100), colorWord(0, 0, 255, 0), xyWord(200, 100), colorWord(0, 0, 0, 255), xyWord(150, 200) } })
	table.insert(cases, { "quad mono", { colorWord(0x28, 0, 255, 255), xyWord(400, 100), xyWord(500, 100), xyWord(500, 200), xyWord(400, 200) } })
	table.insert(cases, { "quad shaded tex", { colorWord(0x3C, 255, 0, 0), xyWord(100, 300), bor(0, 0), colorWord(0, 0, 255, 0), xyWord(200, 300), bor(64, 0), colorWord(0, 0, 0, 255), xyWord(200, 400), bor(64, 64), colorWord(0, 255, 255, 0), xyWord(100, 400), bor(0, 64) } })
	table.insert(cases, { "tri collinear", { colorWord(0x20, 1, 1, 1), xyWord(10, 10), xyWord(20, 20), xyWord(30, 30) } })

	-- polylines (vertex-led on the wire per psx-spx / psxsdk: the first
	-- vertex follows the command, later vertices are (color, xy) for gouraud)
	table.insert(cases, { "polyline mono", { colorWord(0x48, 100, 100, 255), xyWord(50, 50), xyWord(100, 80), xyWord(150, 40), xyWord(200, 90), 0x50005000 } })
	table.insert(cases, { "polyline mono 2v", { colorWord(0x48, 80, 80, 80), xyWord(20, 400), xyWord(120, 420), 0x50005000 } })
	table.insert(cases, { "polyline gouraud", { colorWord(0x4C, 255, 0, 0), xyWord(50, 200), colorWord(0, 0, 255, 0), xyWord(120, 220), colorWord(0, 0, 0, 255), xyWord(190, 190), 0x50005000 } })
	table.insert(cases, { "polyline gouraud 2v", { colorWord(0x4C, 255, 0, 0), xyWord(300, 400), colorWord(0, 0, 255, 0), xyWord(420, 380), 0x50005000 } })

	-- vram-to-vram copies
	table.insert(cases, { "v2v simple", { 0x80000000, xyWord(0, 0), xyWord(200, 200), xyWord(64, 32) } })
	table.insert(cases, { "v2v reverse overlap", { 0x80000000, xyWord(0, 0), xyWord(8, 0), xyWord(64, 1) } })
	table.insert(cases, { "v2v forward overlap", { 0x80000000, xyWord(8, 0), xyWord(0, 0), xyWord(64, 1) } })
	table.insert(cases, { "v2v wrap cols", { 0x80000000, xyWord(1000, 0), xyWord(0, 0), xyWord(100, 32) } })
	table.insert(cases, { "v2v wrap rows", { 0x80000000, xyWord(0, 500), xyWord(0, 0), xyWord(64, 64) } })

	for _, c in ipairs(cases) do
		if not feedWords(tag .. " " .. c[1], gpu, ref, c[2]) then
			return
		end
	end
end

-- textured corpus phase: needs a texture + clut in vram first.
local function texturedScripted(gpu, ref, rng)
	local tag = "[corpus-tex]"
	local words, clutBits = uploadFixture(gpu, ref, rng, tag)
	table.insert(words, 1, bor(0xE3000000, 0))
	table.insert(words, 1, bor(0xE4000000, bor(1023, lshift(511, 10))))
	table.insert(words, 1, drawModeWord(0, 0, 0, 0, 0, 0, 0))
	if not feedWords(tag, gpu, ref, words) then return end

	local uv = function(u, v) return bor(u, lshift(v, 8)) end
	local clutReg = lshift(508, 6) -- fixture clut at row 508
	local uvP = function(u, v) return bor(uv(u, v), lshift(clutReg, 16)) end
	local cases = {}
	table.insert(cases, { "tex rect 4bpp", { colorWord(0x64, 255, 255, 255), xyWord(100, 100), uvP(0, 0), xyWord(64, 64) } })
	table.insert(cases, { "tex rect wrapped uv", { colorWord(0x64, 255, 255, 255), xyWord(300, 100), uvP(60, 60), xyWord(64, 64) } })
	table.insert(cases, { "tex rect 1x1", { colorWord(0x6C, 255, 255, 255), xyWord(500, 100), uvP(10, 10) } })
	table.insert(cases, { "tex rect 8x8", { colorWord(0x74, 255, 255, 255), xyWord(100, 300), uvP(20, 20) } })
	table.insert(cases, { "tex rect 16x16", { colorWord(0x7C, 255, 255, 255), xyWord(300, 300), uvP(30, 30) } })
	table.insert(cases, { "tex tri mono", { colorWord(0x24, 255, 255, 255), xyWord(100, 50), uvP(0, 0), xyWord(200, 50), uvP(63, 0), xyWord(150, 150), uvP(30, 63) } })
	table.insert(cases, { "tex tri shaded", { colorWord(0x34, 255, 0, 0), xyWord(100, 50), uvP(0, 0), colorWord(0, 0, 255, 0), xyWord(200, 50), uvP(63, 0), colorWord(0, 0, 0, 255), xyWord(150, 150), uvP(30, 63) } })
	table.insert(cases, { "tex quad", { colorWord(0x2C, 255, 255, 255), xyWord(400, 50), uvP(0, 0), xyWord(500, 50), uvP(63, 0), xyWord(500, 150), uvP(63, 63), xyWord(400, 150), uvP(0, 63) } })
	for _, c in ipairs(cases) do
		if not feedWords(tag .. " " .. c[1], gpu, ref, c[2]) then
			return
		end
	end

	-- texture window applied to textured draws
	local wcases = {}
	table.insert(wcases, { "tex window", drawModeWord(0, 0, 0, 0, 0, 0, 0) })
	table.insert(wcases, { "tex window", bor(0xE2000000, bor(band(0x0F, 0x1F), lshift(band(0x0F, 0x1F), 5))) }) -- mask 8x8 both axes
	if feedWords(tag, gpu, ref, { wcases[1][2], wcases[2][2] }) then
		feedWords(tag, gpu, ref, { colorWord(0x64, 255, 255, 255), xyWord(100, 100), bor(uv(0, 0), lshift(0, 16)), xyWord(128, 128) })
	end
	if not feedWords(tag, gpu, ref, { bor(0xE2000000, 0) }) then return end

	-- clut cache clear: upload clut data, draw, clear cache (gp0 01h), upload
	-- different clut, draw again with the same texpage.
	local upload2 = { 0xA0000000, xyWord(0, 508), xyWord(16, 2) }
	for i = 0, 15 do
		table.insert(upload2, bor(band(0x7FFF - i * 0x111, 0x7FFF), lshift(band(i * 0x555, 0x7FFF), 16)))
	end
	if not feedWords(tag, gpu, ref, upload2) then return end
	-- point the clut register at row 508
	local reTex = { drawModeWord(0, 0, 0, 0, 0, 0, 0), bor(0xE5000000, 0) }
	if not feedWords(tag, gpu, ref, reTex) then return end
	local drawWithClut = { colorWord(0x64, 255, 255, 255), xyWord(100, 400), bor(uv(0, 0), lshift(clutReg, 16)), xyWord(64, 64) }
	if not feedWords(tag, gpu, ref, drawWithClut) then return end
	if not feedWords(tag, gpu, ref, { 0x01000000 }) then return end -- clear cache
	-- overwrite the clut rows, draw again: cache must reload after the clear
	local upload3 = { 0xA0000000, xyWord(0, 508), xyWord(16, 2) }
	for i = 0, 15 do
		table.insert(upload3, bor(band(0x0000 + i, 0x7FFF), lshift(band(0x0000, 0x7FFF), 16)))
	end
	if not feedWords(tag, gpu, ref, upload3) then return end
	if not feedWords(tag, gpu, ref, drawWithClut) then return end
end

-- mask-bit phase: set/check mask bits and redraw over existing pixels.
local function maskScripted(gpu, ref, rng)
	local tag = "[corpus-mask]"
	-- reset to a clean slate
	if not feedWords(tag, gpu, ref, { 0x01000000 }) then return end
	if not feedWords(tag, gpu, ref, { bor(0xE6000000, 0) }) then return end -- mask off
	-- draw a base pattern
	if not feedWords(tag, gpu, ref, { colorWord(0x02, 200, 200, 200), xyWord(0, 0), xyWord(64, 64) }) then return end
	-- set-mask draw over it
	if not feedWords(tag, gpu, ref, { bor(0xE6000000, 1) }) then return end -- set mask
	if not feedWords(tag, gpu, ref, { colorWord(0x02, 100, 100, 100), xyWord(0, 0), xyWord(64, 64) }) then return end
	-- check-mask draw: pixels with bit 15 set are skipped
	if not feedWords(tag, gpu, ref, { bor(0xE6000000, 2) }) then return end -- check mask
	if not feedWords(tag, gpu, ref, { colorWord(0x02, 10, 10, 10), xyWord(0, 0), xyWord(64, 64) }) then return end
	-- both
	if not feedWords(tag, gpu, ref, { bor(0xE6000000, 3) }) then return end
	if not feedWords(tag, gpu, ref, { colorWord(0x02, 5, 5, 5), xyWord(32, 32), xyWord(64, 64) }) then return end
	-- v2v with masks
	if not feedWords(tag, gpu, ref, { 0x80000000, xyWord(0, 0), xyWord(100, 100), xyWord(32, 32) }) then return end
	if not feedWords(tag, gpu, ref, { bor(0xE6000000, 0) }) then return end
end

-- vram->cpu transfer phase.
local function v2cScripted(gpu, ref, rng)
	local tag = "[corpus-v2c]"
	if not feedWords(tag, gpu, ref, { 0xC0000000, xyWord(0, 0), xyWord(64, 16) }) then return end
	drainV2C(tag, gpu, ref)
	-- wrapped read
	if not feedWords(tag, gpu, ref, { 0xC0000000, xyWord(1000, 500), xyWord(64, 16) }) then return end
	drainV2C(tag, gpu, ref)
	-- odd width
	if not feedWords(tag, gpu, ref, { 0xC0000000, xyWord(300, 100), xyWord(7, 3) }) then return end
	drainV2C(tag, gpu, ref)
end

-- gp1 sweep: every command code with boundary parameters.
local function gp1Sweep(gpu, ref, rng)
	local tag = "[gp1]"
	local params = { 0x000000, 0x000001, 0x00003F, 0x000040, 0x000080, 0x0000FF, 0xFFFFFF, band(rng(), 0xFFFFFF), band(rshift(rng(), 8), 0xFFFFFF) }
	for cmd = 0x00, 0x1F do
		for _, p in ipairs(params) do
			local value = bor(lshift(cmd, 24), band(p, 0xFFFFFF))
			gpu:writeGp1(value)
			ref:gp1(value)
			compareState(string.format("[gp1 %08X]", value), gpu, ref)
		end
	end
	-- info reads with meaningful prior state
	gp1Write(tag, gpu, ref, bor(0x10000000, 2))
	gp1Write(tag, gpu, ref, bor(0x10000000, 3))
	gp1Write(tag, gpu, ref, bor(0x10000000, 4))
	gp1Write(tag, gpu, ref, bor(0x10000000, 5))
	gp1Write(tag, gpu, ref, bor(0x10000000, 7))
end

-- ---- fuzz ----------------------------------------------------------------

local FUZZ_SEQS = 90
local FUZZ_CMDS = 6

local function fuzzWord(rng, lo, hi)
	return lo + band(rng(), hi - lo)
end

-- build one random command's words (already includes the header words).
local function fuzzCommand(gpu, ref, rng)
	local choice = band(rng(), 7)
	local x = fuzzWord(rng, 0, 1023)
	local y = fuzzWord(rng, 0, 511)
	if band(rng(), 15) == 0 then x = fuzzWord(rng, 0, 1279) end
	if band(rng(), 15) == 0 then y = fuzzWord(rng, 0, 767) end
	-- command transparency is a single bit (duckstation bit 25); the 4 modes live in the texpage draw mode.  two random bits would bleed into bit 26 and change the word count.
	local semi = band(rng(), 1)
	local shade = band(rng(), 1)
	if choice == 0 then -- fill
		local w = fuzzWord(rng, 1, 200)
		local h = fuzzWord(rng, 1, 150)
		return { colorWord(0x02, band(rng(), 255), band(rng(), 255), band(rng(), 255)), xyWord(x, y), xyWord(w, h) }
	elseif choice == 1 then -- line
		local x2 = fuzzWord(rng, 0, 1023)
		local y2 = fuzzWord(rng, 0, 511)
		if shade == 1 then
			return { colorWord(0x50, band(rng(), 255), band(rng(), 255), band(rng(), 255)), xyWord(x, y), colorWord(0, band(rng(), 255), band(rng(), 255), band(rng(), 255)), xyWord(x2, y2) }
		end
		return { colorWord(bor(0x40, lshift(semi, 1)), band(rng(), 255), band(rng(), 255), band(rng(), 255)), xyWord(x, y), xyWord(x2, y2) }
	elseif choice == 2 then -- rect (random size class)
		local tex = band(rng(), 1)
		-- rectangle size class 0..3 (variable / 1x1 / 8x8 / 16x16); a value of
		-- 4 would shift the opcode out of the rectangle space into 0x80+.
		local size = band(rng(), 3)
		local cmdBase = bor(0x60, lshift(semi, 1), lshift(tex, 2), lshift(size, 3))
		if tex == 1 then
			local uvW = fuzzWord(rng, 0, 63)
			local uvH = fuzzWord(rng, 0, 63)
			local clut = fuzzWord(rng, 0, 255) -- clutY << 6 | clutX>>4 (within vram)
			local uvPal = bor(uvW, lshift(uvH, 8), lshift(clut, 16))
			if size == 0 then
				return { colorWord(cmdBase, band(rng(), 255), band(rng(), 255), band(rng(), 255)), xyWord(x, y), uvPal, xyWord(fuzzWord(rng, 1, 64), fuzzWord(rng, 1, 64)) }
			end
			return { colorWord(cmdBase, band(rng(), 255), band(rng(), 255), band(rng(), 255)), xyWord(x, y), uvPal }
		end
		if size == 0 then
			return { colorWord(cmdBase, band(rng(), 255), band(rng(), 255), band(rng(), 255)), xyWord(x, y), xyWord(fuzzWord(rng, 1, 128), fuzzWord(rng, 1, 128)) }
		end
		return { colorWord(cmdBase, band(rng(), 255), band(rng(), 255), band(rng(), 255)), xyWord(x, y) }
	elseif choice == 3 then -- triangle
		local tex = band(rng(), 1)
		local quad = band(rng(), 1)
		local cmd = bor(0x20, lshift(semi, 1), lshift(tex, 2), lshift(quad, 3), lshift(shade, 4))
		local words = { colorWord(cmd, band(rng(), 255), band(rng(), 255), band(rng(), 255)) }
		-- quad is a raw 0/1 bit and 0 is truthy in lua, so `quad and 4 or 3` would always pick 4 vertices and desync the engines.
		local nv = quad == 1 and 4 or 3
		for i = 0, nv - 1 do
			if shade == 1 and i > 0 then
				table.insert(words, colorWord(0, band(rng(), 255), band(rng(), 255), band(rng(), 255)))
			end
			table.insert(words, xyWord(fuzzWord(rng, 0, 640), fuzzWord(rng, 0, 480)))
			if tex == 1 then
				table.insert(words, bor(fuzzWord(rng, 0, 255), lshift(fuzzWord(rng, 0, 255), 8), lshift(fuzzWord(rng, 0, 0x7FFF), 16)))
			end
		end
		return words
	elseif choice == 4 then -- polyline (vertex-led: first vertex after the
		-- command, later vertices (color, xy) when shaded; >=3 vertices mono /
		-- >=2 shaded keep the reference's word-count buffering clean)
		local cmd = bor(0x48, lshift(semi, 1), lshift(shade, 4))
		local words = { colorWord(cmd, band(rng(), 255), band(rng(), 255), band(rng(), 255)) }
		-- segment colors have a 0x00 top byte, so only the command word itself can carry the 0x5x terminator pattern.
		local segs = fuzzWord(rng, shade == 1 and 2 or 3, 6)
		table.insert(words, xyWord(fuzzWord(rng, 0, 640), fuzzWord(rng, 0, 480)))
		for i = 2, segs do
			if shade == 1 then
				table.insert(words, colorWord(0, band(rng(), 255), band(rng(), 255), band(rng(), 255)))
			end
			table.insert(words, xyWord(fuzzWord(rng, 0, 640), fuzzWord(rng, 0, 480)))
		end
		table.insert(words, 0x50005000)
		return words
	elseif choice == 5 then -- c2v
		-- even widths only: an odd total pixel count leaves a stray half-word neither model is verified on.
		local w = fuzzWord(rng, 1, 40) * 2
		local h = fuzzWord(rng, 1, 60)
		local words = { 0xA0000000, xyWord(x, y), xyWord(w, h) }
		local nWords = math.floor((w * h + 1) / 2)
		for i = 1, nWords do
			table.insert(words, band(rng(), 0xFFFFFFFF))
		end
		return words
	else -- v2v
		local w = fuzzWord(rng, 1, 128)
		local h = fuzzWord(rng, 1, 64)
		local dx = fuzzWord(rng, 0, 640)
		local dy = fuzzWord(rng, 0, 480)
		return { 0x80000000, xyWord(x, y), xyWord(dx, dy), xyWord(w, h) }
	end
end

local function fuzz(gpu, ref, rng)
	for seq = 1, FUZZ_SEQS do
		local tag = string.format("[fuzz s%02d]", seq)
		-- random config preamble
		local cfg = {}
		local pageX = band(rng(), 0xF)
		local pageY = band(rng(), 1)
		-- texmode is a 2-bit field, so band(rng, 2) never produced 8bpp (mode 1) and the 256-entry clut path never ran; remap the direct16 slot onto 8bpp, weighted double.
		local texMode = band(rng(), 3)
		if texMode == 3 then texMode = 1 end
		local dither = band(rng(), 1)
		local texDisable = band(rng(), 1)
		table.insert(cfg, drawModeWord(pageX, pageY, texMode, band(rng(), 3), dither, band(rng(), 1), texDisable))
		if band(rng(), 1) == 1 then
			table.insert(cfg, bor(0xE2000000, band(rng(), 0xFFFFF)))
		end
		table.insert(cfg, bor(0xE3000000, bor(band(rng(), 0x3FF), lshift(band(rng(), 0x1FF), 10))))
		table.insert(cfg, bor(0xE4000000, bor(band(rng(), 0x3FF), lshift(band(rng(), 0x1FF), 10))))
		if band(rng(), 1) == 1 then
			table.insert(cfg, bor(0xE5000000, bor(band(rng(), 0x7FF), lshift(band(rng(), 0x7FF), 11))))
		end
		if band(rng(), 1) == 1 then
			table.insert(cfg, bor(0xE6000000, band(rng(), 3)))
		end
		if not feedWords(tag, gpu, ref, cfg) then
			return
		end
		if not requireSettled(tag .. " cfg", gpu, ref) then
			return
		end
		for ci = 1, FUZZ_CMDS do
			local cmd = fuzzCommand(gpu, ref, rng)
			if not feedWords(tag .. " cmd" .. ci, gpu, ref, cmd) then
				return
			end
			if not requireSettled(tag .. " cmd" .. ci, gpu, ref) then
				return
			end
		end
	end
end

-- ---- dither-rule oracle ------------------------------------------------------
-- only lines, shaded polygons, and modulated-textured polygons dither (rects and flat/raw
-- polygons never do, regardless of the draw-mode bit).  pins literal colors because both
-- engines used to dither everything and agreed on the bug; dither-off uses the fixed (2,3) lut cell.
local function ditherOracle(gpu, ref)
	local tag = "[oracle-dither]"
	local MAT = { { -4, 0, -3, 1 }, { 2, -2, 3, -1 }, { -3, 1, -4, 0 }, { 3, -1, 2, -2 } }
	local function lut(v, dy, dx)
		return math.max(0, math.min(31, math.floor((v + MAT[dy + 1][dx + 1]) / 8)))
	end
	local function cell23(r, g, b)
		return bor(lut(r, 2, 3), lshift(lut(g, 2, 3), 5), lshift(lut(b, 2, 3), 10))
	end
	local function rgb15(r, g, b)
		return bor(math.floor(r / 8), lshift(math.floor(g / 8), 5), lshift(math.floor(b / 8), 10))
	end
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	local function checkRect(where, x, y, w, h, expected)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local idx = (y + j) * VRAM_W + (x + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= expected or rv ~= expected then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x + i, y + j, c, rv, expected))
					ok = false
					return false
				end
			end
		end
		return true
	end

	-- every case runs with the draw-mode dither bit set; the expected values
	-- are the dither-disabled outcomes the primitive rules require.
	feed({ drawModeWord(0, 0, 0, 0, 1, 0, 0) })
	-- 0x02 fill is a raw vram fill: never dithered.
	feed({ colorWord(0x02, 200, 100, 50), xyWord(0, 400), xyWord(16, 16) })
	checkRect("fill", 0, 400, 16, 16, rgb15(200, 100, 50))
	-- flat triangle: dithering applies only when shaded or modulated-textured.
	feed({ colorWord(0x20, 200, 100, 50), xyWord(32, 400), xyWord(64, 400), xyWord(48, 416) })
	-- interior box only: the triangle edges sit at x = 32+(48-32)*(y-400)/16 .. 64-(64-48)*(y-400)/16.
	checkRect("flat tri", 44, 404, 8, 6, cell23(200, 100, 50))
	-- mono rectangle: rectangles never dither.
	feed({ colorWord(0x60, 200, 100, 50), xyWord(80, 400), xyWord(16, 16) })
	checkRect("mono rect", 80, 400, 16, 16, cell23(200, 100, 50))
	-- raw 15bpp rectangle: texture color used unmodulated and undithered.
	local rawWords = { 0xA0000000, xyWord(512, 380), xyWord(16, 16) }
	for i = 1, 128 do rawWords[#rawWords + 1] = 0x42104210 end
	feed(rawWords)
	feed({ drawModeWord(8, 1, 2, 0, 1, 0, 0) })
	feed({ colorWord(0x65, 255, 255, 255), xyWord(112, 400), bor(0, lshift(124, 8)), xyWord(16, 16) })
	checkRect("raw rect", 112, 400, 16, 16, 0x4210)
	-- modulated 4bpp rectangle over a solid texture and solid clut: the rect
	-- rule must yield the flat clut color, not dithered noise.
	local texWords = { 0xA0000000, xyWord(0, 440), xyWord(16, 16) }
	for i = 1, 128 do texWords[#texWords + 1] = 0x0000 end
	feed(texWords)
	local clutWords = { 0xA0000000, xyWord(0, 470), xyWord(16, 1) }
	for i = 1, 8 do clutWords[#clutWords + 1] = 0x7FFF end
	feed(clutWords)
	feed({ drawModeWord(0, 1, 0, 0, 1, 0, 0) })
	feed({ colorWord(0x64, 255, 255, 255), xyWord(0, 480), bor(lshift(184, 8), lshift(bor(lshift(470, 6), 0), 16)), xyWord(16, 16) })
	checkRect("tex rect", 0, 480, 16, 16, 0x7FFF)
	-- restore the baseline draw mode.
	feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) })
	return ok
end

-- ---- 8bpp texture oracle ---------------------------------------------------
-- pins the 256-entry clut path against literal colors (neither the corpus nor the fuzz ever
-- set 8bpp mode).  layout: texture A = 64x64 texels of index (17u + 37v) mod 256 on rows
-- 256..319, uniform 16x16 block of index 200 on rows 320..335, clut A on row 470 at x 0..255,
-- clut B wrapping the row end (x 1008..1023 then 0..239).  draws: raw + white-modulated rects,
-- a 1x1 sweep over the wrapped cache half, a stale-cache check (clut vram writes only observed
-- after gp0(01h)), and a raw polygon whose texpage comes from the second vertex's texcoord.
local function eightBitOracle(gpu, ref)
	local tag = "[oracle-8bpp]"
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	-- authored clut colors: 15-bit, no mask bit (bit 15), no zero channel so
	-- textured pixels always draw.
	local function clutColor(i)
		local r = 1 + band(i, 30)
		local g = 1 + band(i * 3, 30)
		local b = 1 + band(i * 5, 30)
		return bor(r, lshift(g, 5), lshift(b, 10))
	end
	-- texture A's per-texel index; 17 and 37 are both coprime to 256, so as
	-- u,v run 0..63 every index 0..255 (indexes >= 128 included) appears.
	local function texIndex(u, v)
		return band(u * 17 + v * 37, 255)
	end
	-- white-modulated 5-bit clut channel: min(31, floor(c*255/128)) via the shared duckstation lut (fixed (2,3) cell, >>3, clamp 31).
	local function modWhite(c)
		return math.min(31, math.floor(c * 255 / 128))
	end
	local function checkRect(where, x, y, w, h, expected)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local idx = (y + j) * VRAM_W + (x + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= expected or rv ~= expected then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x + i, y + j, c, rv, expected))
					ok = false
					return false
				end
			end
		end
		return true
	end
	-- per-pixel grid variant (texture content varies, so the expected value
	-- is a function of the pixel's offset into the draw).
	local function checkGrid(where, x, y, w, h, expectedFn)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local idx = (y + j) * VRAM_W + (x + i) + 1
				local exp = expectedFn(i, j)
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= exp or rv ~= exp then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x + i, y + j, c, rv, exp))
					ok = false
					return false
				end
			end
		end
		return true
	end
	-- pack a list of vram cells into cpu->vram data words (two cells each).
	local function cellsToWords(cells)
		local words = {}
		for j = 1, math.ceil(#cells / 2) do
			words[#words + 1] = bor(cells[(j - 1) * 2 + 1] or 0, lshift(cells[(j - 1) * 2 + 2] or 0, 16))
		end
		return words
	end
	-- uv word with the clut register in the upper 16 bits (the texpage rides
	-- there for polygons' second vertex only, set explicitly below).
	local function uvWord(u, v, upper)
		return bor(u, lshift(v, 8), lshift(upper, 16))
	end
	local clutA = lshift(470, 6) -- y=470, x=0
	local clutB = bor(lshift(470, 6), 63) -- y=470, x=1008 (wrap on cache load)

	if not feed({ 0x01000000 }) then return ok end -- clear cache
	if not feed({ bor(0xE6000000, 0) }) then return ok end -- mask off
	if not feed({ bor(0xE2000000, 0) }) then return ok end -- no texture window
	if not feed({ bor(0xE5000000, 0) }) then return ok end -- no drawing offset
	-- 8bpp texpage at page (0, y=1), which maps texel v to vram row 256+v.
	if not feed({ drawModeWord(0, 1, 1, 0, 0, 0, 0) }) then return ok end

	-- texture A: 64 rows of 32 cells (u 0..63), cell c = index(2c, v) | index(2c+1, v) << 8.
	do
		local all = { 0xA0000000, xyWord(0, 256), xyWord(32, 64) }
		for v = 0, 63 do
			local cells = {}
			for c = 0, 31 do
				cells[c + 1] = bor(texIndex(c * 2, v), lshift(texIndex(c * 2 + 1, v), 8))
			end
			for _, w in ipairs(cellsToWords(cells)) do
				all[#all + 1] = w
			end
		end
		if not feed(all) then return ok end
	end

	-- clut A: 256 entries on row 470, cells x 0..255.
	do
		local all = { 0xA0000000, xyWord(0, 470), xyWord(256, 1) }
		local cells = {}
		for i = 0, 255 do
			cells[i + 1] = clutColor(i)
		end
		for _, w in ipairs(cellsToWords(cells)) do
			all[#all + 1] = w
		end
		if not feed(all) then return ok end
	end

	-- raw 64x64 rect over texture A / clut A: every pixel asserted against
	-- the authored index -> color chain (both u parities, indexes >= 128).
	if not feed({ colorWord(0x65, 255, 255, 255), xyWord(0, 380), uvWord(0, 0, clutA), xyWord(64, 64) }) then return ok end
	if not checkGrid("raw 8bpp rect", 0, 380, 64, 64, function(i, j)
		return clutColor(texIndex(i, j))
	end) then return ok end

	-- white-modulated 16x16 rect over the same texture/clut: pins the
	-- modulate8bit arithmetic (and that it bypasses dithering) literally.
	if not feed({ colorWord(0x64, 255, 255, 255), xyWord(0, 444), uvWord(0, 0, clutA), xyWord(16, 16) }) then return ok end
	if not checkGrid("modulated 8bpp rect", 0, 444, 16, 16, function(i, j)
		local col = clutColor(texIndex(i, j))
		return bor(modWhite(band(col, 0x1F)), lshift(modWhite(band(rshift(col, 5), 0x1F)), 5), lshift(modWhite(band(rshift(col, 10), 0x1F)), 10))
	end) then return ok end

	-- uniform 8bpp block rows 320..335 (v 64..79), constant index 200.
	do
		local all = { 0xA0000000, xyWord(0, 320), xyWord(16, 16) }
		for v = 0, 15 do
			local cells = {}
			for c = 0, 15 do
				cells[c + 1] = bor(200, lshift(200, 8))
			end
			for _, w in ipairs(cellsToWords(cells)) do
				all[#all + 1] = w
			end
		end
		if not feed(all) then return ok end
	end
	-- polygon texpage-merge: gp0(e1) says 4bpp, but the second vertex's texcoord carries texpage 0x0090 (8bpp), which duckstation merges in -- every covered pixel must read clut[200].
	if not feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) }) then return ok end
	if not feed({ colorWord(0x25, 200, 200, 200), xyWord(32, 300), uvWord(0, 64, clutA), xyWord(64, 300), uvWord(16, 64, 0x0090), xyWord(48, 316), uvWord(8, 80, 0) }) then return ok end
	if not checkRect("poly texpage-merge tri", 44, 304, 8, 6, clutColor(200)) then return ok end

	-- back to the 8bpp texpage for the clut-B draws.
	if not feed({ drawModeWord(0, 1, 1, 0, 0, 0, 0) }) then return ok end

	-- clut B at y=470, x=1008: the 256-entry load reads x 1008..1023 then wraps to x 0..239.
	do
		local all = { 0xA0000000, xyWord(1008, 470), xyWord(16, 1) }
		local cells = {}
		for i = 0, 15 do
			cells[i + 1] = clutColor(i)
		end
		for _, w in ipairs(cellsToWords(cells)) do
			all[#all + 1] = w
		end
		if not feed(all) then return ok end
	end
	do
		local all = { 0xA0000000, xyWord(0, 470), xyWord(240, 1) }
		local cells = {}
		for i = 16, 255 do
			cells[i - 16 + 1] = clutColor(i)
		end
		for _, w in ipairs(cellsToWords(cells)) do
			all[#all + 1] = w
		end
		if not feed(all) then return ok end
	end
	-- 1x1 raw rects: indexes 0/14 (u,v = (0,0), (5,5)) prove the unwrapped cache tail; 47/27/74 prove the wrapped half.
	local wrapCases = { { 0, 0, 300 }, { 5, 5, 302 }, { 63, 0, 304 }, { 0, 63, 306 }, { 63, 63, 308 } }
	for _, c in ipairs(wrapCases) do
		if not feed({ colorWord(0x6D, 255, 255, 255), xyWord(c[3], 300), uvWord(c[1], c[2], clutB) }) then return ok end
		if not checkRect("clut-B wrap 1x1", c[3], 300, 1, 1, clutColor(texIndex(c[1], c[2]))) then return ok end
	end

	-- stale-cache check: overwrite clut B and redraw -- the cache must NOT observe the write until gp0(01h) clear-cache.
	local function clutColorB2(i)
		return clutColor(band(255 - i, 255))
	end
	-- rewrite both halves of clut B (the wrapped half at x 0..239 and the
	-- unwrapped tail at x 1008..1023 holding indexes 0..15).
	do
		local all = { 0xA0000000, xyWord(0, 470), xyWord(240, 1) }
		local cells = {}
		for i = 16, 255 do
			cells[i - 16 + 1] = clutColorB2(i)
		end
		for _, w in ipairs(cellsToWords(cells)) do
			all[#all + 1] = w
		end
		if not feed(all) then return ok end
	end
	do
		local all = { 0xA0000000, xyWord(1008, 470), xyWord(16, 1) }
		local cells = {}
		for i = 0, 15 do
			cells[i + 1] = clutColorB2(i)
		end
		for _, w in ipairs(cellsToWords(cells)) do
			all[#all + 1] = w
		end
		if not feed(all) then return ok end
	end
	-- same clut register, no clear: cache still holds the old colors.
	if not feed({ colorWord(0x6D, 255, 255, 255), xyWord(310, 300), uvWord(5, 5, clutB) }) then return ok end
	if not checkRect("stale 8bpp clut", 310, 300, 1, 1, clutColor(14)) then return ok end
	-- gp0(01h) invalidates the cache: the reload must see the new colors.
	if not feed({ 0x01000000 }) then return ok end
	if not feed({ colorWord(0x6D, 255, 255, 255), xyWord(312, 300), uvWord(5, 5, clutB) }) then return ok end
	if not checkRect("reloaded 8bpp clut", 312, 300, 1, 1, clutColorB2(14)) then return ok end

	-- restore the baseline.
	feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) })
	feed({ 0x01000000 })
	return ok
end

-- ---- semi-transparency blend oracle ---------------------------------------
-- pins literal stored pixels for all four abr modes, textured and untextured, because both
-- engines share the same blargg blend block verbatim (a shared typo is invisible to agreement).
-- expected values are per-channel closed forms of the duckstation formulas (abr 0 is plain
-- floor((f+b)/2) in the no-carry regime).  untextured results store bit 15 clear; textured keep it set.
local function blendOracle(gpu, ref)
	local tag = "[oracle-blend]"
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	local function checkRect(where, x, y, w, h, expected)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local idx = (y + j) * VRAM_W + (x + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= expected or rv ~= expected then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x + i, y + j, c, rv, expected))
					ok = false
					return false
				end
			end
		end
		return true
	end
	local function sat(c) return math.max(0, math.min(31, c)) end
	-- 5-bit blend of foreground channel f over backdrop channel b.
	local function mix(abr, f, b)
		if abr == 0 then return (f + b) // 2 end
		if abr == 1 then return sat(f + b) end
		if abr == 2 then return sat(b - f) end
		return sat(b + f // 4)
	end
	local function blend15(abr, fg, bg, keepBit15)
		local low = bor(
			mix(abr, band(fg, 0x1F), band(bg, 0x1F)),
			lshift(mix(abr, band(rshift(fg, 5), 0x1F), band(rshift(bg, 5), 0x1F)), 5),
			lshift(mix(abr, band(rshift(fg, 10), 0x1F), band(rshift(bg, 10), 0x1F)), 10))
		return keepBit15 and bor(low, 0x8000) or low
	end
	local function c15(chan)
		return bor(chan[1], lshift(chan[2], 5), lshift(chan[3], 10))
	end

	-- start from a clean slate.
	if not feed({ 0x01000000 }) then return ok end
	if not feed({ bor(0xE6000000, 0) }) then return ok end
	if not feed({ bor(0xE2000000, 0) }) then return ok end

	-- ---- untextured semi-transparent rectangles, all four abr modes.
	-- backdrop fill (0x02) + a semi mono rect (0x62); abr rides in gp0(e1) bits 5-6.  fg channels
	-- are multiples of 8 so dither-off quantization is identity; abr 0 uses odd sums to separate floor from round-half-up.
	local untexturedCases = {
		{ 0, { 4, 2, 6 }, { 6, 4, 2 } }, { 0, { 15, 9, 1 }, { 1, 9, 15 } }, { 0, { 3, 1, 5 }, { 2, 4, 2 } },
		{ 1, { 16, 16, 16 }, { 16, 16, 16 } }, { 1, { 7, 3, 9 }, { 10, 20, 2 } }, { 1, { 31, 0, 31 }, { 0, 31, 0 } },
		{ 2, { 5, 10, 15 }, { 20, 15, 10 } }, { 2, { 20, 15, 10 }, { 5, 10, 15 } }, { 2, { 0, 0, 0 }, { 0, 0, 0 } },
		{ 3, { 28, 12, 4 }, { 0, 0, 0 } }, { 3, { 31, 31, 31 }, { 31, 31, 31 } }, { 3, { 4, 8, 12 }, { 30, 20, 10 } },
	}
	-- the 0x02 fill aligns x to 16 and rounds width up to 16, so backdrops sit at 16-aligned x with the semi rect inside.
	local ux, uy = 0, 40
	for _, c in ipairs(untexturedCases) do
		local abr, f, b = c[1], c[2], c[3]
		if not feed({ colorWord(0x02, b[1] * 8, b[2] * 8, b[3] * 8), xyWord(ux, uy), xyWord(16, 8) }) then return ok end
		if not feed({ drawModeWord(0, 0, 0, abr, 0, 0, 0) }) then return ok end
		if not feed({ colorWord(0x62, f[1] * 8, f[2] * 8, f[3] * 8), xyWord(ux, uy), xyWord(8, 8) }) then return ok end
		if not checkRect("untextured abr" .. abr, ux, uy, 8, 8, blend15(abr, c15(f), c15(b), false)) then return ok end
		ux += 16
		if ux >= 128 then
			ux = 0
			uy += 10
		end
	end

	-- ---- textured semi-transparent 1x1 raw direct15 draws.
	-- direct15 row at page (1,0); each case is a semi 1x1 rect (0x6f) over a small backdrop.
	-- texel bit 15 clear => written opaque; set => blended per gp0(e1) abr.
	do
		local all = { 0xA0000000, xyWord(64, 0), xyWord(32, 1) }
		local texels = {
			bor(c15({ 4, 8, 12 }), 0), -- 0: opaque texel (gate case)
			bor(c15({ 2, 4, 6 }), 0x8000), -- 1: abr 0
			bor(c15({ 16, 16, 16 }), 0x8000), -- 2: abr 1 clamp
			bor(c15({ 5, 10, 15 }), 0x8000), -- 3: abr 2
			bor(c15({ 20, 15, 10 }), 0x8000), -- 4: abr 2 negative -> 0
			bor(c15({ 28, 12, 4 }), 0x8000), -- 5: abr 3
		}
		for u = 0, 30, 2 do
			all[#all + 1] = bor(texels[(u % #texels) + 1], lshift(texels[((u + 1) % #texels) + 1], 16))
		end
		if not feed(all) then return ok end
	end
	local tx, ty = 0, 180
	local function runTextured(texIdx, abr, b, expected)
		if not ok then return false end
		if not feed({ colorWord(0x02, b[1] * 8, b[2] * 8, b[3] * 8), xyWord(tx, ty), xyWord(2, 2) }) then return false end
		if not feed({ drawModeWord(1, 0, 2, abr, 0, 0, 0) }) then return false end
		-- raw 1x1 semi textured rect sampling texel (texIdx, 0)
		if not feed({ colorWord(0x6F, 255, 255, 255), xyWord(tx, ty), bor(texIdx, lshift(0, 8)) }) then return false end
		return checkRect("textured abr" .. abr .. " texel" .. texIdx, tx, ty, 1, 1, expected)
	end
	-- opaque texel under a semi command: written unchanged, bit 15 clear.
	if not runTextured(0, 1, { 16, 8, 24 }, bor(c15({ 4, 8, 12 }), 0)) then return ok end
	tx += 4
	-- texel bit 15 set keeps the stored bit in the no-carry regime; odd backdrop green (11) discriminates truncation on the textured path too.
	if not runTextured(1, 0, { 8, 11, 12 }, bor(blend15(0, c15({ 2, 4, 6 }), c15({ 8, 11, 12 }), false), 0x8000)) then return ok end
	tx += 4
	if not runTextured(2, 1, { 16, 16, 16 }, bor(blend15(1, c15({ 16, 16, 16 }), c15({ 16, 16, 16 }), false), 0x8000)) then return ok end
	tx += 4
	if not runTextured(3, 2, { 20, 15, 10 }, bor(blend15(2, c15({ 5, 10, 15 }), c15({ 20, 15, 10 }), false), 0x8000)) then return ok end
	tx += 4
	if not runTextured(4, 2, { 5, 10, 15 }, bor(blend15(2, c15({ 20, 15, 10 }), c15({ 5, 10, 15 }), false), 0x8000)) then return ok end
	tx += 4
	if not runTextured(5, 3, { 8, 8, 8 }, bor(blend15(3, c15({ 28, 12, 4 }), c15({ 8, 8, 8 }), false), 0x8000)) then return ok end

	-- restore the baseline.
	feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) })
	feed({ 0x01000000 })
	return ok
end

-- ---- mask-bit oracle -------------------------------------------------------
-- pins gp0(e6) set/check-mask against literal pixels: set-mask ors bit 15 in, check-mask skips
-- bit-15 pixels, the 0x02 fill ignores both bits, transfers honor them at the destination, and
-- a semi draw with check-mask skips before blending.
local function maskOracle(gpu, ref)
	local tag = "[oracle-mask]"
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	local function checkRect(where, x, y, w, h, expected)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local idx = (y + j) * VRAM_W + (x + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= expected or rv ~= expected then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x + i, y + j, c, rv, expected))
					ok = false
					return false
				end
			end
		end
		return true
	end
	-- per-half checker: first w1 columns expected e1, remaining columns e2.
	local function checkSplit(where, x, y, w, h, w1, e1, e2)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local exp = i < w1 and e1 or e2
				local idx = (y + j) * VRAM_W + (x + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= exp or rv ~= exp then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x + i, y + j, c, rv, exp))
					ok = false
					return false
				end
			end
		end
		return true
	end
	local function c15(chan)
		return bor(chan[1], lshift(chan[2], 5), lshift(chan[3], 10))
	end
	local function sat(c) return math.max(0, math.min(31, c)) end
	local function avg15(fg, bg)
		local function mix(f, b) return (f + b) // 2 end
		return bor(mix(band(fg, 0x1F), band(bg, 0x1F)),
			lshift(mix(band(rshift(fg, 5), 0x1F), band(rshift(bg, 5), 0x1F)), 5),
			lshift(mix(band(rshift(fg, 10), 0x1F), band(rshift(bg, 10), 0x1F)), 10))
	end
	local fg1 = c15({ 10, 20, 30 })
	local fg2 = c15({ 5, 5, 5 })
	local fg3 = c15({ 12, 12, 12 })
	local fg4 = c15({ 3, 6, 9 })
	local fg5 = c15({ 15, 15, 15 })
	local fg6 = c15({ 7, 7, 7 })
	local F1 = c15({ 21, 13, 29 })
	local b1 = c15({ 8, 9, 10 })
	local semiFg = c15({ 4, 4, 4 })

	if not feed({ 0x01000000 }) then return ok end
	if not feed({ bor(0xE6000000, 0) }) then return ok end
	if not feed({ bor(0xE2000000, 0) }) then return ok end
	if not feed({ bor(0xE5000000, 0) }) then return ok end

	-- A: set-mask draw ors bit 15 into every written pixel.
	if not feed({ bor(0xE6000000, 1) }) then return ok end
	if not feed({ colorWord(0x60, 80, 160, 240), xyWord(0, 210), xyWord(8, 8) }) then return ok end
	if not checkRect("set-mask draw", 0, 210, 8, 8, bor(fg1, 0x8000)) then return ok end
	-- B: check-mask draw skips masked pixels; unmasked pixels draw normally.
	if not feed({ bor(0xE6000000, 2) }) then return ok end
	if not feed({ colorWord(0x60, 40, 40, 40), xyWord(0, 210), xyWord(8, 8) }) then return ok end
	if not checkRect("check-mask skip", 0, 210, 8, 8, bor(fg1, 0x8000)) then return ok end
	if not feed({ colorWord(0x60, 40, 40, 40), xyWord(16, 210), xyWord(8, 8) }) then return ok end
	if not checkRect("check-mask clean draw", 16, 210, 8, 8, fg2) then return ok end
	-- C: both bits together: masked skipped, clean pixels set.
	if not feed({ bor(0xE6000000, 3) }) then return ok end
	if not feed({ colorWord(0x60, 96, 96, 96), xyWord(0, 210), xyWord(8, 8) }) then return ok end
	if not checkRect("both-mask skip", 0, 210, 8, 8, bor(fg1, 0x8000)) then return ok end
	if not feed({ colorWord(0x60, 96, 96, 96), xyWord(32, 210), xyWord(8, 8) }) then return ok end
	if not checkRect("both-mask set", 32, 210, 8, 8, bor(fg3, 0x8000)) then return ok end
	-- D: the 0x02 fill ignores both mask bits: it overwrites masked pixels
	-- (check ignored) and stores without bit 15 (set ignored).
	if not feed({ bor(0xE6000000, 2) }) then return ok end
	if not feed({ colorWord(0x02, 168, 104, 232), xyWord(0, 210), xyWord(16, 8) }) then return ok end
	if not checkRect("fill ignores check-mask", 0, 210, 16, 8, F1) then return ok end
	if not feed({ bor(0xE6000000, 1) }) then return ok end
	if not feed({ colorWord(0x02, 168, 104, 232), xyWord(0, 210), xyWord(16, 8) }) then return ok end
	if not checkRect("fill ignores set-mask", 0, 210, 16, 8, F1) then return ok end

	-- E: vram->vram copies honor both bits at the destination.
	-- source (0,220) 4x4: right half plain fg4, left half masked fg5.
	if not feed({ bor(0xE6000000, 0) }) then return ok end
	if not feed({ colorWord(0x60, 24, 48, 72), xyWord(0, 220), xyWord(4, 4) }) then return ok end
	if not feed({ bor(0xE6000000, 1) }) then return ok end
	if not feed({ colorWord(0x60, 120, 120, 120), xyWord(0, 220), xyWord(2, 4) }) then return ok end
	-- plain copy: bit 15 travels with the source pixels.
	if not feed({ bor(0xE6000000, 0) }) then return ok end
	if not feed({ 0x80000000, xyWord(0, 220), xyWord(8, 220), xyWord(4, 4) }) then return ok end
	if not checkSplit("v2v plain", 8, 220, 4, 4, 2, bor(fg5, 0x8000), fg4) then return ok end
	-- set-mask copy: every written destination pixel gets bit 15.
	if not feed({ bor(0xE6000000, 1) }) then return ok end
	if not feed({ 0x80000000, xyWord(0, 220), xyWord(16, 220), xyWord(4, 4) }) then return ok end
	if not checkSplit("v2v set-mask", 16, 220, 4, 4, 2, bor(fg5, 0x8000), bor(fg4, 0x8000)) then return ok end
	-- check-mask copy: masked destination pixels are skipped, clean ones
	-- receive the source verbatim.
	if not feed({ bor(0xE6000000, 1) }) then return ok end
	if not feed({ colorWord(0x60, 56, 56, 56), xyWord(24, 220), xyWord(2, 4) }) then return ok end
	if not feed({ bor(0xE6000000, 2) }) then return ok end
	if not feed({ 0x80000000, xyWord(0, 220), xyWord(24, 220), xyWord(4, 4) }) then return ok end
	if not checkSplit("v2v check-mask", 24, 220, 4, 4, 2, bor(fg6, 0x8000), fg4) then return ok end

	-- F: cpu->vram uploads honor both bits at the destination.
	local upload = { 0x12481248, 0x12481248, 0x12481248, 0x12481248 }
	if not feed({ bor(0xE6000000, 1) }) then return ok end
	if not feed({ 0xA0000000, xyWord(32, 220), xyWord(4, 2) }) then return ok end
	for _, w in ipairs(upload) do
		if not feed({ w }) then return ok end
	end
	if not checkRect("c2v set-mask", 32, 220, 4, 2, 0x9248) then return ok end
	-- check-mask upload: pre-masked cells keep their content, clean cells get
	-- the upload data.
	if not feed({ bor(0xE6000000, 1) }) then return ok end
	if not feed({ colorWord(0x60, 0, 0, 0), xyWord(40, 220), xyWord(2, 2) }) then return ok end
	if not feed({ bor(0xE6000000, 2) }) then return ok end
	if not feed({ 0xA0000000, xyWord(40, 220), xyWord(4, 2) }) then return ok end
	for _, w in ipairs(upload) do
		if not feed({ w }) then return ok end
	end
	if not checkSplit("c2v check-mask", 40, 220, 4, 2, 2, 0x8000, 0x1248) then return ok end

	-- G: semi draw with check-mask skips masked pixels before blending -- masked half untouched, clean half averaged.
	if not feed({ bor(0xE6000000, 0) }) then return ok end
	if not feed({ colorWord(0x02, 64, 72, 80), xyWord(0, 230), xyWord(8, 8) }) then return ok end
	if not feed({ bor(0xE6000000, 1) }) then return ok end
	if not feed({ colorWord(0x60, 80, 160, 240), xyWord(0, 230), xyWord(4, 8) }) then return ok end
	if not feed({ bor(0xE6000000, 2) }) then return ok end
	if not feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) }) then return ok end
	if not feed({ colorWord(0x62, 32, 32, 32), xyWord(0, 230), xyWord(8, 8) }) then return ok end
	if not checkSplit("semi check-mask", 0, 230, 8, 8, 4, bor(fg1, 0x8000), avg15(semiFg, b1)) then return ok end

	-- restore.
	feed({ bor(0xE6000000, 0) })
	feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) })
	feed({ 0x01000000 })
	return ok
end

-- ---- vram-to-vram copy oracle ----------------------------------------------
-- pins the console-verified copy-direction rule (reverse when src_x < dst_x or the wrapped
-- end-of-span comparison inverts) against literal pixels: forward/reverse copies, destructive
-- same-row overlap both directions, the wrapped-end clause, a row-wrap copy, and self-copies
-- with and without set-mask.  the engines use one per-pixel-wrapped pass, no chunking.
local function v2vOracle(gpu, ref)
	local tag = "[oracle-v2v]"
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	-- per-column checker: column i of the checked box must equal pat[i + 1].
	local function checkPattern(where, x, y, w, h, pat)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local exp = pat[i + 1] or 0
				local idx = (y + j) * VRAM_W + (x + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= exp or rv ~= exp then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x + i, y + j, c, rv, exp))
					ok = false
					return false
				end
			end
		end
		return true
	end
	-- clear a box to 0x0000 with a 0x02 fill (offset/mask/clip-exempt).
	local function clearBox(x, y, w, h)
		return feed({ colorWord(0x02, 0, 0, 0), xyWord(x, y), xyWord(w, h) })
	end
	-- upload an h-row strip: pat has one color per column, words pack two
	-- pixels each (lo = left, hi = right); the upload wraps at the vram edge.
	local function uploadStrip(x, y, pat, h)
		h = h or 8
		local words = { 0xA0000000, xyWord(x, y), xyWord(#pat, h) }
		for _ = 1, h do
			for m = 0, #pat // 2 - 1 do
				words[#words + 1] = bor(pat[2 * m + 1] or 0, lshift(pat[2 * m + 2] or 0, 16))
			end
		end
		return feed(words)
	end
	-- per-column colors: (base + k) * 0x421, distinct 15-bit values with bit
	-- 15 clear.
	local function cols(n, base)
		local p = {}
		for k = 0, n - 1 do
			p[k + 1] = band((base + k) * 0x421, 0x7FFF)
		end
		return p
	end
	local function areaWord(x, y) return bor(x, lshift(y, 10)) end

	if not feed({ 0x01000000 }) then return ok end
	if not feed({ bor(0xE6000000, 0) }) then return ok end
	if not feed({ bor(0xE5000000, 0) }) then return ok end
	if not feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) }) then return ok end
	if not feed({ bor(0xE3000000, 0) }) then return ok end
	if not feed({ bor(0xE4000000, areaWord(1023, 511)) }) then return ok end

	-- A: forward copy (src_x > dst_x): pattern moves verbatim.
	if not clearBox(0, 240, 160, 8) then return ok end
	local patA = cols(16, 0)
	if not uploadStrip(10, 240, patA) then return ok end
	if not feed({ 0x80000000, xyWord(10, 240), xyWord(40, 240), xyWord(16, 8) }) then return ok end
	if not checkPattern("forward", 40, 240, 16, 8, patA) then return ok end

	-- B: reverse branch with no overlap (src_x < dst_x): same result, but the
	-- reverse loop actually runs.
	if not clearBox(0, 250, 160, 8) then return ok end
	local patB = cols(16, 16)
	if not uploadStrip(10, 250, patB) then return ok end
	if not feed({ 0x80000000, xyWord(10, 250), xyWord(60, 250), xyWord(16, 8) }) then return ok end
	if not checkPattern("reverse plain", 60, 250, 16, 8, patB) then return ok end

	-- C: destructive rightward overlap (src_x < dst_x): must copy in reverse or the source smears.  dst 80..95 = original src 70..85.
	if not clearBox(60, 260, 60, 8) then return ok end
	local patC = cols(16, 32)
	if not uploadStrip(70, 260, patC) then return ok end
	if not feed({ 0x80000000, xyWord(70, 260), xyWord(80, 260), xyWord(16, 8) }) then return ok end
	if not checkPattern("overlap rightward", 80, 260, 16, 8, patC) then return ok end

	-- D: destructive leftward overlap (src_x > dst_x): forward is correct.
	if not clearBox(60, 270, 60, 8) then return ok end
	local patD = cols(16, 48)
	if not uploadStrip(90, 270, patD) then return ok end
	if not feed({ 0x80000000, xyWord(90, 270), xyWord(80, 270), xyWord(16, 8) }) then return ok end
	if not checkPattern("overlap leftward", 80, 270, 16, 8, patD) then return ok end

	-- E: wrapped-end reversal: src (1020,280) wraps to 0..3; src_end 3 < dst_end 9 fires the clause even though src_x > dst_x.  dst 2..9 = original src 1020..1023,0..3.
	if not clearBox(0, 280, 40, 8) then return ok end
	if not clearBox(1008, 280, 16, 8) then return ok end
	local patE = cols(8, 64)
	if not uploadStrip(1020, 280, patE) then return ok end
	if not feed({ 0x80000000, xyWord(1020, 280), xyWord(2, 280), xyWord(8, 8) }) then return ok end
	if not checkPattern("wrapped-end", 2, 280, 8, 8, patE) then return ok end

	-- F: row-wrap copy: source rows 500..515 wrap to 0..3; destination rows
	-- 240..255 receive the unwrapped pattern.
	if not clearBox(10, 240, 16, 16) then return ok end
	local patF = cols(16, 80)
	if not uploadStrip(10, 500, patF, 16) then return ok end
	if not feed({ 0x80000000, xyWord(10, 500), xyWord(10, 240), xyWord(16, 16) }) then return ok end
	if not checkPattern("row wrap", 10, 240, 16, 16, patF) then return ok end

	-- G: self-copy with set-mask runs and sets bit 15 on every pixel; H: the
	-- identical copy with set-mask off is skipped and leaves pixels untouched.
	if not clearBox(30, 290, 8, 8) then return ok end
	local patG0 = cols(8, 96)
	if not uploadStrip(30, 290, patG0) then return ok end
	if not feed({ bor(0xE6000000, 1) }) then return ok end
	if not feed({ 0x80000000, xyWord(30, 290), xyWord(30, 290), xyWord(8, 8) }) then return ok end
	local patG = {}
	for k = 1, 8 do patG[k] = bor(patG0[k], 0x8000) end
	if not checkPattern("self-copy set-mask", 30, 290, 8, 8, patG) then return ok end
	if not feed({ bor(0xE6000000, 0) }) then return ok end
	if not feed({ 0x80000000, xyWord(30, 290), xyWord(30, 290), xyWord(8, 8) }) then return ok end
	if not checkPattern("self-copy skip", 30, 290, 8, 8, patG) then return ok end

	-- restore the baseline.
	feed({ bor(0xE6000000, 0) })
	feed({ bor(0xE3000000, 0) })
	feed({ bor(0xE4000000, areaWord(1023, 511)) })
	feed({ bor(0xE5000000, 0) })
	feed({ 0x01000000 })
	return ok
end

-- ---- shading / line-dda oracle ---------------------------------------------
-- pins every pixel of mono/gouraud lines and a shaded-triangle interior from closed forms of
-- the duckstation dda math (both models scalarize it verbatim, so a shared typo is invisible):
-- the k+1-pixel span, the right-to-left swap, both fractional-step directions, the descending-y
-- bias, and the affine interior floor(0.5 + 7.96875*(x-20) + 6.375*(y-360)).
local function shadeOracle(gpu, ref)
	local tag = "[oracle-shade]"
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	local function c15(r, g, b)
		return bor(r // 8, lshift(g // 8, 5), lshift(b // 8, 10))
	end
	-- pixels is a list of { x, y, color }; every listed pixel must equal color.
	local function checkPixels(where, pixels)
		if not ok then return false end
		for _, p in ipairs(pixels) do
			local idx = p[2] * VRAM_W + p[1] + 1
			local c = gpu.vram[idx] or 0
			local rv = ref.vram[idx] or 0
			if c ~= p[3] or rv ~= p[3] then
				fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
					tag, where, p[1], p[2], c, rv, p[3]))
				ok = false
				return false
			end
		end
		return true
	end
	-- box check with an expectedFn(x, y) -> 15-bit color (or 0 untouched).
	local function checkBox(where, x, y, w, h, expectedFn)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local exp = expectedFn(x + i, y + j) or 0
				local idx = (y + j) * VRAM_W + (x + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= exp or rv ~= exp then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x + i, y + j, c, rv, exp))
					ok = false
					return false
				end
			end
		end
		return true
	end
	local function clearBox(x, y, w, h)
		return feed({ colorWord(0x02, 0, 0, 0), xyWord(x, y), xyWord(w, h) })
	end
	-- build the k+1 pixels of a line given closed forms for position and the
	-- three 8-bit channels.
	local function linePixels(k, px, py, cr, cg, cb)
		local pixels = {}
		for i = 0, k do
			pixels[#pixels + 1] = { px(i), py(i), c15(cr(i), cg(i), cb(i)) }
		end
		return pixels
	end
	local function areaWord(x, y) return bor(x, lshift(y, 10)) end

	if not feed({ 0x01000000 }) then return ok end
	if not feed({ bor(0xE6000000, 0) }) then return ok end
	if not feed({ bor(0xE5000000, 0) }) then return ok end
	if not feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) }) then return ok end
	if not feed({ bor(0xE3000000, 0) }) then return ok end
	if not feed({ bor(0xE4000000, areaWord(1023, 511)) }) then return ok end

	-- mono horizontal (20,300)-(60,300): k=40, 41 pixels, flat color.
	if not clearBox(0, 300, 120, 13) then return ok end
	local monoC = c15(200, 100, 50)
	if not feed({ colorWord(0x40, 200, 100, 50), xyWord(20, 300), xyWord(60, 300) }) then return ok end
	if not checkPixels("mono horizontal", linePixels(40,
		function(i) return 20 + i end, function() return 300 end,
		function() return 200 end, function() return 100 end, function() return 50 end)) then return ok end
	-- mono vertical (70,300)-(70,312): x constant.
	if not feed({ colorWord(0x40, 50, 200, 100), xyWord(70, 300), xyWord(70, 312) }) then return ok end
	if not checkPixels("mono vertical", linePixels(12,
		function() return 70 end, function(i) return 300 + i end,
		function() return 50 end, function() return 200 end, function() return 100 end)) then return ok end
	-- mono diagonal (10,300)-(22,312): x and y step together.
	if not feed({ colorWord(0x40, 100, 100, 100), xyWord(10, 300), xyWord(22, 312) }) then return ok end
	if not checkPixels("mono diagonal", linePixels(12,
		function(i) return 10 + i end, function(i) return 300 + i end,
		function() return 100 end, function() return 100 end, function() return 100 end)) then return ok end
	-- mono shallow (10,300)-(12,304): dy > dx, so x steps 0.5/pixel and doubles up: x = 10 + floor(i/2), y = 300 + i.
	if not feed({ colorWord(0x40, 150, 50, 200), xyWord(10, 300), xyWord(12, 304) }) then return ok end
	if not checkPixels("mono shallow x", linePixels(4,
		function(i) return 10 + i // 2 end, function(i) return 300 + i end,
		function() return 150 end, function() return 50 end, function() return 200 end)) then return ok end
	-- mono shallow y (10,300)-(22,306): dx > dy, y steps 0.5/pixel, the +0.5 rounds the first step up: y = 300 + floor((i+1)/2).
	if not feed({ colorWord(0x40, 200, 200, 200), xyWord(10, 300), xyWord(22, 306) }) then return ok end
	if not checkPixels("mono shallow y", linePixels(12,
		function(i) return 10 + i end, function(i) return 300 + (i + 1) // 2 end,
		function() return 200 end, function() return 200 end, function() return 200 end)) then return ok end
	-- mono descending (10,306)-(22,300): dydk < 0, the -1024 bias lands the first step on the next row: y = 306 - ceil(i/2), x = 10 + i.
	if not feed({ colorWord(0x40, 80, 80, 80), xyWord(10, 306), xyWord(22, 300) }) then return ok end
	if not checkPixels("mono descending", linePixels(12,
		function(i) return 10 + i end, function(i) return 306 - (i + 1) // 2 end,
		function() return 80 end, function() return 80 end, function() return 80 end)) then return ok end

	-- gouraud horizontal ramp (20,320)-(32,320): r 0 -> 255 over k=12;
	-- r_i = floor(0.5 + 21.25*i), g = b = 0.
	if not clearBox(0, 320, 80, 1) then return ok end
	if not feed({ colorWord(0x50, 0, 0, 0), xyWord(20, 320), colorWord(0, 255, 0, 0), xyWord(32, 320) }) then return ok end
	if not checkPixels("gouraud ramp", linePixels(12,
		function(i) return 20 + i end, function() return 320 end,
		function(i) return math.floor(0.5 + 21.25 * i) end, function() return 0 end, function() return 0 end)) then return ok end

	-- gouraud diagonal, two channels (10,330)-(22,342): (255,0,0) -> (0,0,255).
	-- r_i = floor(255.5 - 21.25*i), b_i = floor(0.5 + 21.25*i), g = 0.
	if not clearBox(0, 330, 70, 13) then return ok end
	if not feed({ colorWord(0x50, 255, 0, 0), xyWord(10, 330), colorWord(0, 0, 0, 255), xyWord(22, 342) }) then return ok end
	if not checkPixels("gouraud diagonal", linePixels(12,
		function(i) return 10 + i end, function(i) return 330 + i end,
		function(i) return math.floor(255.5 - 21.25 * i) end, function() return 0 end,
		function(i) return math.floor(0.5 + 21.25 * i) end)) then return ok end

	-- gouraud right-to-left (60,330)-(48,330): p0.x > p1.x forces the swap,
	-- which also swaps the endpoint colors, so r ramps 0 -> 255 left to right.
	if not feed({ colorWord(0x50, 255, 0, 0), xyWord(60, 330), colorWord(0, 0, 0, 255), xyWord(48, 330) }) then return ok end
	if not checkPixels("gouraud swap", linePixels(12,
		function(i) return 48 + i end, function() return 330 end,
		function(i) return math.floor(0.5 + 21.25 * i) end, function() return 0 end,
		function(i) return math.floor(255.5 - 21.25 * i) end)) then return ok end

	-- shaded triangle v0(20,360,r=0) v1(52,360,r=255) v2(36,380,r=255): determinant 640 divides exactly,
	-- so interior red = floor(0.5 + 7.96875*(x-20) + 6.375*(y-360)).  the checked box (33,366)-(36,374) stays clear of the edges.
	if not clearBox(0, 360, 80, 21) then return ok end
	if not feed({ colorWord(0x30, 0, 0, 0), xyWord(20, 360), colorWord(0, 255, 0, 0), xyWord(52, 360), colorWord(0, 255, 0, 0), xyWord(36, 380) }) then return ok end
	if not checkBox("shaded tri interior", 33, 366, 4, 9, function(x, y)
		return c15(math.floor(0.5 + 7.96875 * (x - 20) + 6.375 * (y - 360)), 0, 0)
	end) then return ok end

	-- restore the baseline.
	feed({ bor(0xE6000000, 0) })
	feed({ bor(0xE3000000, 0) })
	feed({ bor(0xE4000000, areaWord(1023, 511)) })
	feed({ bor(0xE5000000, 0) })
	feed({ 0x01000000 })
	return ok
end

-- ---- textured-polygon uv interpolation oracle -------------------------------
-- pins the polygon uv interpolator to literal texels (a shared typo would sample every textured
-- model from the wrong texel).  draws raw textured polygons against a direct15 page whose texel
-- color encodes (u, v) as u | (v << 6), with gradients of exactly one texel per pixel so the
-- sampled coordinate is the exact affine of the pixel position.
local function texUvOracle(gpu, ref)
	local tag = "[oracle-texuv]"
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	local function texel(u, v)
		return bor(band(u, 0x3F), lshift(band(v, 0x3F), 6))
	end
	local function checkBox(where, x0, y0, w, h, expectedFn)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local exp = expectedFn(x0 + i, y0 + j) or 0
				local idx = (y0 + j) * VRAM_W + (x0 + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= exp or rv ~= exp then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x0 + i, y0 + j, c, rv, exp))
					ok = false
					return false
				end
			end
		end
		return true
	end
	local function clearBox(x, y, w, h)
		return feed({ colorWord(0x02, 0, 0, 0), xyWord(x, y), xyWord(w, h) })
	end
	local function areaWord(x, y) return bor(x, lshift(y, 10)) end
	local function uv(u, v) return bor(u, lshift(v, 8)) end
	-- a textured vertex texcoord word: uv in the low 16 bits, texpage/clut
	-- bits in the upper 16 (only the second vertex's texpage bits matter).
	local function tc(u, v, pageBits)
		return bor(uv(u, v), lshift(pageBits or 0, 16))
	end

	if not feed({ 0x01000000 }) then return ok end
	if not feed({ bor(0xE6000000, 0) }) then return ok end
	if not feed({ bor(0xE5000000, 0) }) then return ok end
	if not feed({ bor(0xE3000000, 0) }) then return ok end
	if not feed({ bor(0xE4000000, areaWord(1023, 511)) }) then return ok end
	if not feed({ bor(0xE2000000, 0) }) then return ok end

	-- direct15 page at (576,256) with texel(u,v) = u | (v << 6), u,v in 0..63.
	if not feed({ 0xA0000000, xyWord(576, 256), xyWord(64, 64) }) then return ok end
	for r = 0, 63 do
		for m = 0, 31 do
			if not feed({ bor(texel(2 * m, r), lshift(texel(2 * m + 1, r), 16)) }) then return ok end
		end
	end
	-- page x = 9 (base 576), page y = 1 (base 256), texture mode 2 (direct15).
	local pageBits = bor(9, lshift(1, 4), lshift(2, 7))
	if not feed({ drawModeWord(9, 1, 2, 0, 0, 0, 0) }) then return ok end
	if not clearBox(0, 450, 175, 52) then return ok end

	-- raw textured triangle (0x25): v0 (40,450) (0,0), v1 (72,450) (32,0), v2 (56,470) (16,20); sampled coordinate = (x-40, y-450).
	if not feed({ colorWord(0x25, 255, 255, 255), xyWord(40, 450), tc(0, 0, 0),
		xyWord(72, 450), tc(32, 0, pageBits), xyWord(56, 470), tc(16, 20, 0) }) then return ok end
	if not checkBox("uv tri interior", 53, 454, 9, 9, function(x, y)
		return texel(x - 40, y - 450)
	end) then return ok end

	-- mirror triangle (100..132): u = 132 - x, v = y - 450 -- reversed x gradient through the same machinery.
	if not feed({ colorWord(0x25, 255, 255, 255), xyWord(100, 450), tc(32, 0, 0),
		xyWord(132, 450), tc(0, 0, pageBits), xyWord(116, 470), tc(16, 20, 0) }) then return ok end
	if not checkBox("uv tri reversed", 113, 454, 9, 9, function(x, y)
		return texel(132 - x, y - 450)
	end) then return ok end

	-- rotated triangle (40..72, 480..500): u = y - 480, v = x - 40 -- the coordinate pair is swept in both directions.
	if not feed({ colorWord(0x25, 255, 255, 255), xyWord(40, 480), tc(0, 0, 0),
		xyWord(72, 480), tc(0, 32, pageBits), xyWord(56, 500), tc(20, 16, 0) }) then return ok end
	if not checkBox("uv tri rotated", 50, 484, 13, 7, function(x, y)
		return texel(y - 480, x - 40)
	end) then return ok end

	-- raw textured quad (0x2d), corners tl,tr,bl,br: split into (tl,tr,bl) + (bl,tr,br) on the
	-- descending tr-bl diagonal; affine u = x-140, v = y-450 on both halves, so each checked box
	-- (kept clear of the diagonal) is unambiguous.
	if not feed({ colorWord(0x2D, 255, 255, 255), xyWord(140, 450), tc(0, 0, 0),
		xyWord(172, 450), tc(32, 0, pageBits), xyWord(140, 470), tc(0, 20, 0),
		xyWord(172, 470), tc(32, 20, 0) }) then return ok end
	if not checkBox("uv quad half a", 143, 452, 12, 7, function(x, y)
		return texel(x - 140, y - 450)
	end) then return ok end
	if not checkBox("uv quad half b", 156, 462, 12, 7, function(x, y)
		return texel(x - 140, y - 450)
	end) then return ok end

	-- restore the baseline.
	feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) })
	feed({ bor(0xE2000000, 0) })
	feed({ bor(0xE6000000, 0) })
	feed({ bor(0xE3000000, 0) })
	feed({ bor(0xE4000000, areaWord(1023, 511)) })
	feed({ bor(0xE5000000, 0) })
	feed({ 0x01000000 })
	return ok
end

-- ---- textured modulation multiply oracle --------------------------------
-- pins the modulate multiply min(31, floor(t5*c8/128)) against literal colors for non-white
-- colors, the clip ceiling, and the shaded path (crop-off default semantics -- a future "fix"
-- toward 5-bit modulation dies here).  texel channels (18, 1, 31) discriminate the crop rule on
-- c8 == 7 mod 8; three flat rects pin c8 = 128 (identity), 79 (crop differs), 255 (clip); a
-- shaded triangle reuses the round-27 affine red with g/b constant at 132/205.
local function modulateOracle(gpu, ref)
	local tag = "[oracle-modulate]"
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	local function mod8(t5, c8)
		return math.min(31, math.floor((t5 * c8) / 128))
	end
	local function px15(red, green, blue)
		return bor(red, lshift(green, 5), lshift(blue, 10))
	end
	local function checkRect(where, x, y, w, h, expected)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local idx = (y + j) * VRAM_W + (x + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= expected or rv ~= expected then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x + i, y + j, c, rv, expected))
					ok = false
					return false
				end
			end
		end
		return true
	end
	local function checkBox(where, x0, y0, w, h, expectedFn)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local exp = expectedFn(x0 + i, y0 + j) or 0
				local idx = (y0 + j) * VRAM_W + (x0 + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= exp or rv ~= exp then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x0 + i, y0 + j, c, rv, exp))
					ok = false
					return false
				end
			end
		end
		return true
	end
	local function clearBox(x, y, w, h)
		return feed({ colorWord(0x02, 0, 0, 0), xyWord(x, y), xyWord(w, h) })
	end
	local function areaWord(x, y) return bor(x, lshift(y, 10)) end
	local function uv(u, v) return bor(u, lshift(v, 8)) end

	-- a constant direct15 page at (384,256), page x = 6, page y = 1: texel
	-- channels (red 18, green 1, blue 31) for every u, v the draws sample.
	local TEX = px15(18, 1, 31)
	local pageBits = bor(6, lshift(1, 4), lshift(2, 7))

	if not feed({ 0x01000000 }) then return ok end
	if not feed({ bor(0xE6000000, 0) }) then return ok end
	if not feed({ bor(0xE5000000, 0) }) then return ok end
	if not feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) }) then return ok end
	if not feed({ bor(0xE3000000, 0) }) then return ok end
	if not feed({ bor(0xE4000000, areaWord(1023, 511)) }) then return ok end
	if not feed({ 0xA0000000, xyWord(384, 256), xyWord(64, 24) }) then return ok end
	for r = 0, 23 do
		for m = 0, 31 do
			if not feed({ bor(TEX, lshift(TEX, 16)) }) then return ok end
		end
	end
	if not feed({ drawModeWord(6, 1, 2, 0, 0, 0, 0) }) then return ok end
	if not clearBox(0, 96, 96, 56) then return ok end

	-- flat textured rect, color 128: the identity point of the >>7 multiply,
	-- so every modulated channel must come back as the texel exactly.
	if not feed({ colorWord(0x64, 128, 128, 128), xyWord(0, 100), uv(0, 0), xyWord(16, 16) }) then return ok end
	if not checkRect("identity", 0, 100, 16, 16, TEX) then return ok end
	-- flat textured rect, color (79, 143, 205): red 79 = 9*8+7 discriminates the crop (11 vs 10); blue 205 clips to the 31 ceiling.
	if not feed({ colorWord(0x64, 79, 143, 205), xyWord(0, 116), uv(0, 0), xyWord(16, 16) }) then return ok end
	if not checkRect("flat crop-sensitive", 0, 116, 16, 16, px15(11, 1, 31)) then return ok end
	-- flat textured rect, white: 255 = 31*8+7 but (t*255) >> 7 == (t*31) >> 4
	-- for every t, so white pins can never see the crop rule; red clips.
	if not feed({ colorWord(0x64, 255, 255, 255), xyWord(0, 132), uv(0, 0), xyWord(16, 16) }) then return ok end
	if not checkRect("white clip", 0, 132, 16, 16, px15(31, 1, 31)) then return ok end

	-- shaded textured triangle (round-27 geometry): red = floor(0.5 + 7.96875*(x-20) + 6.375*(y-360)) with
	-- g/b constant at 132/205; pixels whose red is 7 mod 8 (row 370 at x = 33 -> 167) discriminate the crop.
	if not clearBox(0, 360, 80, 21) then return ok end
	if not feed({ colorWord(0x34, 0, 132, 205), xyWord(20, 360), uv(0, 0),
		colorWord(0, 255, 132, 205), xyWord(52, 360), bor(uv(32, 0), lshift(pageBits, 16)),
		colorWord(0, 255, 132, 205), xyWord(36, 380), uv(16, 20) }) then return ok end
	if not checkBox("shaded tri interior", 33, 366, 4, 9, function(x, y)
		local r8 = math.floor(0.5 + 7.96875 * (x - 20) + 6.375 * (y - 360))
		return px15(mod8(18, r8), mod8(1, 132), mod8(31, 205))
	end) then return ok end

	-- restore the baseline.
	feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) })
	feed({ bor(0xE6000000, 0) })
	feed({ bor(0xE3000000, 0) })
	feed({ bor(0xE4000000, areaWord(1023, 511)) })
	feed({ bor(0xE5000000, 0) })
	feed({ 0x01000000 })
	return ok
end

-- ---- polygon semi-transparency oracle ------------------------------------
-- pins the full semi-transparent polygon chain (command semi bit, modulate multiply, texel
-- bit-15 gate, abr, backdrop blend) against literal pixels: mono textured semi triangles (0x26)
-- with flat color 79, a raw textured semi triangle (0x27) whose stream texpage abr overrides
-- gp0(e1), and a shaded untextured semi triangle (0x32) storing bit 15 clear.  expectations are
-- the carry-free blend formulas applied to round-27 / round-35 foregrounds.
local function polySemiOracle(gpu, ref)
	local tag = "[oracle-polysemi]"
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	local function mod8(t5, c8)
		return math.min(31, math.floor((t5 * c8) / 128))
	end
	local function sat(c) return math.max(0, math.min(31, c)) end
	local function mix(abr, f, b)
		if abr == 0 then return (f + b) // 2 end
		if abr == 1 then return sat(f + b) end
		if abr == 2 then return sat(b - f) end
		return sat(b + f // 4)
	end
	local function blend15(abr, fg, bg, keepBit15)
		local low = bor(
			mix(abr, band(fg, 0x1F), band(bg, 0x1F)),
			lshift(mix(abr, band(rshift(fg, 5), 0x1F), band(rshift(bg, 5), 0x1F)), 5),
			lshift(mix(abr, band(rshift(fg, 10), 0x1F), band(rshift(bg, 10), 0x1F)), 10))
		return keepBit15 and bor(low, 0x8000) or low
	end
	local function checkBox(where, x0, y0, w, h, expectedFn)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local exp = expectedFn(x0 + i, y0 + j) or 0
				local idx = (y0 + j) * VRAM_W + (x0 + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= exp or rv ~= exp then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x0 + i, y0 + j, c, rv, exp))
					ok = false
					return false
				end
			end
		end
		return true
	end
	local function areaWord(x, y) return bor(x, lshift(y, 10)) end
	local function uv(u, v) return bor(u, lshift(v, 8)) end
	-- stream texpage word upper bits: page x, page y, abr, texture mode 2.
	local function pageW(pageX, abr)
		return bor(pageX, lshift(1, 4), lshift(abr, 5), lshift(2, 7))
	end
	-- the backdrop (2,4,6) of the shaded abr-1 case as a 15-bit word.
	local BG15 = bor(2, lshift(4, 5), lshift(6, 10))

	-- three constant direct15 pages at (256,256), (320,256), (384,256): texels (30,20,10)+bit15, (5,7,9)+bit15, (10,9,8) bit15 clear.
	local TS = 0xAA9E
	local TX = 0xA4E5
	local TC = 0x212A
	local function uploadPage(x, texel)
		if not ok then return false end
		if not feed({ 0xA0000000, xyWord(x, 256), xyWord(64, 24) }) then return false end
		for r = 0, 23 do
			for m = 0, 31 do
				if not feed({ bor(texel, lshift(texel, 16)) }) then return false end
			end
		end
		return true
	end

	if not feed({ 0x01000000 }) then return ok end
	if not feed({ bor(0xE6000000, 0) }) then return ok end
	if not feed({ bor(0xE5000000, 0) }) then return ok end
	if not feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) }) then return ok end
	if not feed({ bor(0xE3000000, 0) }) then return ok end
	if not feed({ bor(0xE4000000, areaWord(1023, 511)) }) then return ok end
	if not uploadPage(256, TS) then return ok end
	if not uploadPage(320, TX) then return ok end
	if not uploadPage(384, TC) then return ok end

	-- mono textured semi triangle (0x26), flat color 79: every interior pixel blends identically, so each case checks a constant box in the round-27 geometry.
	local function texTri(where, y0, pageX, abrE1, abrStream, cmdByte, flat, expected, bg)
		if not ok then return false end
		if not feed({ colorWord(0x02, bg[1] * 8, bg[2] * 8, bg[3] * 8), xyWord(0, y0), xyWord(64, 22) }) then return false end
		if not feed({ drawModeWord(pageX, 1, 2, abrE1, 0, 0, 0) }) then return false end
		if not feed({ colorWord(cmdByte, flat[1], flat[2], flat[3]), xyWord(20, y0), uv(0, 0),
			xyWord(52, y0), bor(uv(32, 0), lshift(pageW(pageX, abrStream), 16)),
			xyWord(36, y0 + 20), uv(16, 20) }) then return false end
		return checkBox(where, 33, y0 + 6, 4, 9, function() return expected end)
	end
	local flat79 = { 79, 79, 79 }

	-- a bit-15-clear texel under a semi command: written opaque, exactly the
	-- modulated color (10,9,8 at flat 79 -> (6,5,4)), never blended.
	if not texTri("bit15-clear gate", 150, 6, 2, 2, 0x26, flat79, 0x10A6, { 20, 15, 10 }) then return ok end
	-- bit-15 texel blends under abr 2: texel (30,20,10) at flat 79 -> modulated (18,12,6) over (20,15,10) gives (2,3,4), bit 15 kept.
	if not texTri("modulated abr2", 176, 4, 2, 2, 0x26, flat79, 0x9062, { 20, 15, 10 }) then return ok end
	-- abr 0 with odd sums: texel (5,7,9) at flat 79 -> (3,4,5) over (4,2,6) gives (3,3,5), separating truncation from round-half-up.
	if not texTri("modulated abr0", 202, 5, 0, 0, 0x26, flat79, 0x9463, { 4, 2, 6 }) then return ok end
	-- raw textured semi triangle: stream texpage says abr 2 while gp0(e1) says abr 1 -- the blend must follow the polygon's own word (texel (30,20,10) over (25,25,25) gives (0,5,15), not (31,31,31)).
	if not texTri("stream abr override", 228, 4, 1, 2, 0x27, { 255, 255, 255 }, 0xBCA0, { 25, 25, 25 }) then return ok end

	-- shaded untextured semi triangle (0x32), round-27 geometry at y0 = 260: red ramps 0..255, g/b constant
	-- at 200/100, so fg = (r8//8, 25, 12); abr 1 over backdrop (2,4,6), stored bit-15 clear.
	if not feed({ colorWord(0x02, 16, 32, 48), xyWord(0, 260), xyWord(64, 22) }) then return ok end
	if not feed({ drawModeWord(0, 0, 0, 1, 0, 0, 0) }) then return ok end
	if not feed({ colorWord(0x32, 0, 200, 100), xyWord(20, 260),
		colorWord(0, 255, 200, 100), xyWord(52, 260),
		colorWord(0, 255, 200, 100), xyWord(36, 280) }) then return ok end
	if not checkBox("shaded untextured abr1", 33, 266, 4, 9, function(x, y)
		local r8 = math.floor(0.5 + 7.96875 * (x - 20) + 6.375 * (y - 260))
		return blend15(1, bor(r8 // 8, lshift(25, 5), lshift(12, 10)), BG15, false)
	end) then return ok end

	-- restore the baseline.
	feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) })
	feed({ bor(0xE6000000, 0) })
	feed({ bor(0xE3000000, 0) })
	feed({ bor(0xE4000000, areaWord(1023, 511)) })
	feed({ bor(0xE5000000, 0) })
	feed({ 0x01000000 })
	return ok
end

-- ---- texture-window oracle -------------------------------------------------
-- pins gp0(e2) masking to literal texels: and = ~(mask*8), or = (offset & mask)*8, i.e. block
-- arithmetic on 8-texel blocks (offset ignored when the mask is zero).  a direct15 page whose
-- texel color encodes (u, v) makes the sampled coordinate directly observable; one 4bpp case
-- proves the window applies before the nibble decode.
local function windowOracle(gpu, ref)
	local tag = "[oracle-window]"
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	-- 8-pixel-block restatement of the window semantics (mask field m clears
	-- block-index bits, offset field o re-sets them).
	local function winU(u, m, o)
		return bor(band(u // 8, bnot(m)) * 8, band(u, 7), lshift(band(o, m), 3))
	end
	local function texel(u, v)
		return bor(band(u, 0x3F), lshift(band(v, 0x3F), 6))
	end
	-- expectedFn(i, j) with i, j relative to the drawn rect's top-left.
	local function checkRect(where, x0, y0, w, h, expectedFn)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local exp = expectedFn(i, j)
				local idx = (y0 + j) * VRAM_W + (x0 + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= exp or rv ~= exp then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x0 + i, y0 + j, c, rv, exp))
					ok = false
					return false
				end
			end
		end
		return true
	end
	local function clearBox(x, y, w, h)
		return feed({ colorWord(0x02, 0, 0, 0), xyWord(x, y), xyWord(w, h) })
	end
	local function areaWord(x, y) return bor(x, lshift(y, 10)) end
	local function uv(u, v) return bor(u, lshift(v, 8)) end

	-- a raw textured rect at (0,400) sampling u=0..31, v=0..7.
	local function drawWinRect(texMode, clutReg)
		return feed({ colorWord(0x65, 255, 255, 255), xyWord(0, 400),
			bor(uv(0, 0), lshift(clutReg or 0, 16)), xyWord(32, 8) })
	end

	if not feed({ 0x01000000 }) then return ok end
	if not feed({ bor(0xE6000000, 0) }) then return ok end
	if not feed({ bor(0xE5000000, 0) }) then return ok end
	if not feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) }) then return ok end
	if not feed({ bor(0xE3000000, 0) }) then return ok end
	if not feed({ bor(0xE4000000, areaWord(1023, 511)) }) then return ok end

	-- direct15 page at (512,256): texel(u,v) = u | (v << 6).  (page y has 2 bits, so pages sit on rows 0/256/512.)
	if not feed({ 0xA0000000, xyWord(512, 256), xyWord(64, 64) }) then return ok end
	for r = 0, 63 do
		for m = 0, 31 do
			if not feed({ bor(texel(2 * m, r), lshift(texel(2 * m + 1, r), 16)) }) then return ok end
		end
	end
	-- 4bpp page at (576,256): texel t holds value t.  transfers count 16-bit cells (2 per word), so 8 cells needs 4 words per row, not 2.
	local function cell4(k)
		local c = 0
		for t = 0, 3 do
			c = bor(c, lshift(4 * k + t, t * 4))
		end
		return c
	end
	if not feed({ 0xA0000000, xyWord(576, 256), xyWord(8, 16) }) then return ok end
	for r = 0, 15 do
		for m = 0, 3 do
			if not feed({ bor(cell4(2 * m), lshift(cell4(2 * m + 1), 16)) }) then return ok end
		end
	end
	-- clut at (0,480): clut[i] = i + 1 (entry 0 is the transparent texel, so values start at 1 to keep every checked pixel load-bearing).
	if not feed({ 0xA0000000, xyWord(0, 480), xyWord(16, 1) }) then return ok end
	local clutReg = 0x7800 -- (480 << 6) | (0 >> 4)
	for m = 0, 7 do
		if not feed({ bor(2 * m + 1, lshift(2 * m + 2, 16)) }) then return ok end
	end

	-- clear the draw region once; each case re-clears its own box.
	if not clearBox(0, 400, 100, 40) then return ok end

	-- 1: identity (E2 = 0): pixel (i,j) = i | (j << 6).
	if not feed({ bor(0xE2000000, 0) }) then return ok end
	if not feed({ bor(0xE1000000, drawModeWord(8, 1, 2, 0, 0, 0, 0)) }) then return ok end
	if not drawWinRect(2, 0) then return ok end
	if not checkRect("identity", 0, 400, 32, 8, function(i, j) return texel(i, j) end) then return ok end

	-- 2: mask x = 1, offset 0: block bit 0 cleared.
	if not clearBox(0, 400, 32, 8) then return ok end
	if not feed({ bor(0xE2000000, 0x01) }) then return ok end
	if not drawWinRect(2, 0) then return ok end
	if not checkRect("mask x=1", 0, 400, 32, 8, function(i, j) return texel(winU(i, 1, 0), j) end) then return ok end

	-- 3: mask x = 1, offset x = 1.
	if not clearBox(0, 400, 32, 8) then return ok end
	if not feed({ bor(0xE2000000, bor(0x01, lshift(0x01, 10))) }) then return ok end
	if not drawWinRect(2, 0) then return ok end
	if not checkRect("mask+offset x", 0, 400, 32, 8, function(i, j) return texel(winU(i, 1, 1), j) end) then return ok end

	-- 4: mask x = 3 (two block bits), offset 0.
	if not clearBox(0, 400, 32, 8) then return ok end
	if not feed({ bor(0xE2000000, 0x03) }) then return ok end
	if not drawWinRect(2, 0) then return ok end
	if not checkRect("mask x=3", 0, 400, 32, 8, function(i, j) return texel(winU(i, 3, 0), j) end) then return ok end

	-- 5: mask y = 1, offset 0; rect samples v = 0..31 (drawn at (40,400) 8x32).
	if not clearBox(40, 400, 8, 32) then return ok end
	if not feed({ bor(0xE2000000, lshift(0x01, 5)) }) then return ok end
	if not feed({ colorWord(0x65, 255, 255, 255), xyWord(40, 400),
		bor(uv(0, 0), lshift(0, 16)), xyWord(8, 32) }) then return ok end
	if not checkRect("mask y=1", 40, 400, 8, 32, function(i, j) return texel(i, winU(j, 1, 0)) end) then return ok end

	-- 6: mask y = 1, offset y = 1.
	if not clearBox(40, 400, 8, 32) then return ok end
	if not feed({ bor(0xE2000000, bor(lshift(0x01, 5), lshift(0x01, 15))) }) then return ok end
	if not feed({ colorWord(0x65, 255, 255, 255), xyWord(40, 400),
		bor(uv(0, 0), lshift(0, 16)), xyWord(8, 32) }) then return ok end
	if not checkRect("mask+offset y", 40, 400, 8, 32, function(i, j) return texel(i, winU(j, 1, 1)) end) then return ok end

	-- 7: both axes, mask 1 offset 1 each.
	if not clearBox(0, 400, 32, 8) then return ok end
	if not feed({ bor(0xE2000000, bor(0x01, lshift(0x01, 5), lshift(0x01, 10), lshift(0x01, 15))) }) then return ok end
	if not drawWinRect(2, 0) then return ok end
	if not checkRect("both axes", 0, 400, 32, 8, function(i, j) return texel(winU(i, 1, 1), winU(j, 1, 1)) end) then return ok end

	-- 8: offset x = 4 with mask 0: the offset must be ignored entirely.
	if not clearBox(0, 400, 32, 8) then return ok end
	if not feed({ bor(0xE2000000, lshift(0x04, 10)) }) then return ok end
	if not drawWinRect(2, 0) then return ok end
	if not checkRect("offset ignored", 0, 400, 32, 8, function(i, j) return texel(i, j) end) then return ok end

	-- 9: raw 4bpp -- the window applies before the nibble decode.  page x = 9, clut[i] = i + 1, mask x = 1: sampled index is winU(i, 1, 0), pixel = index + 1.
	if not clearBox(0, 430, 16, 8) then return ok end
	if not feed({ bor(0xE2000000, 0x01) }) then return ok end
	if not feed({ bor(0xE1000000, drawModeWord(9, 1, 0, 0, 0, 0, 0)) }) then return ok end
	if not feed({ colorWord(0x65, 255, 255, 255), xyWord(0, 430),
		bor(uv(0, 0), lshift(clutReg, 16)), xyWord(16, 8) }) then return ok end
	if not checkRect("4bpp window", 0, 430, 16, 8, function(i) return winU(i, 1, 0) + 1 end) then return ok end

	-- restore the baseline.
	feed({ bor(0xE1000000, drawModeWord(0, 0, 0, 0, 0, 0, 0)) })
	feed({ bor(0xE2000000, 0) })
	feed({ bor(0xE6000000, 0) })
	feed({ bor(0xE3000000, 0) })
	feed({ bor(0xE4000000, areaWord(1023, 511)) })
	feed({ bor(0xE5000000, 0) })
	feed({ 0x01000000 })
	return ok
end

-- ---- drawing-area / offset oracle ------------------------------------------
-- pins gp0(e3)/gp0(e4) area clipping, gp0(e5) offsets, and the sx11 coordinate wrap to literal
-- per-pixel coverage: edge clips, the vram right-edge clamp, degenerate areas, positive/negative
-- offsets, the -1 wrap, and a flat triangle under an offset.  each box is pre-cleared with a 0x02
-- fill (which ignores offset, masks, and clipping) so "untouched is zero" holds.
local function clipOracle(gpu, ref)
	local tag = "[oracle-clip]"
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	-- expectedFn(i, j) = expected color at offset (i, j) in the checked box, or 0 when untouched.
	local function checkPattern(where, x, y, w, h, expectedFn)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local exp = expectedFn(i, j) or 0
				local idx = (y + j) * VRAM_W + (x + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= exp or rv ~= exp then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x + i, y + j, c, rv, exp))
					ok = false
					return false
				end
			end
		end
		return true
	end
	local function areaWord(x, y) return bor(x, lshift(y, 10)) end
	local function offWord(x, y) return bor(band(x, 0x7FF), lshift(band(y, 0x7FF), 11)) end
	local fg = 0x7F10 -- 5-bit (16, 24, 31), 8-bit (128, 192, 248)
	local fg8r, fg8g, fg8b = 128, 192, 248

	-- clearBox: paint the checked box 0x0000 with a 0x02 fill so "untouched is zero" holds; the fill aligns x to 16 and rounds width up, so boxes are x-aligned 16-multiples.
	local function clearBox(x, y, w, h)
		return feed({ colorWord(0x02, 0, 0, 0), xyWord(x, y), xyWord(w, h) })
	end

	if not feed({ 0x01000000 }) then return ok end
	if not feed({ bor(0xE6000000, 0) }) then return ok end
	if not feed({ bor(0xE2000000, 0) }) then return ok end
	if not feed({ bor(0xE5000000, 0) }) then return ok end
	if not feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) }) then return ok end
	if not feed({ bor(0xE3000000, 0) }) then return ok end
	if not feed({ bor(0xE4000000, areaWord(1023, 511)) }) then return ok end

	-- A: area (10,240)-(50,252); rect (0,230,80,60) clips on all four edges,
	-- right/bottom edges inclusive.  the pattern pins the exact clipped box.
	if not clearBox(0, 230, 80, 60) then return ok end
	if not feed({ bor(0xE3000000, areaWord(10, 240)) }) then return ok end
	if not feed({ bor(0xE4000000, areaWord(50, 252)) }) then return ok end
	if not feed({ colorWord(0x60, fg8r, fg8g, fg8b), xyWord(0, 230), xyWord(80, 60) }) then return ok end
	if not checkPattern("area clip", 0, 230, 80, 60, function(i, j)
		return (10 <= i and i <= 50 and 10 <= j and j <= 22) and fg or 0
	end) then return ok end
	-- B: fully outside the area draws nothing.
	if not clearBox(0, 260, 16, 16) then return ok end
	if not feed({ colorWord(0x60, fg8r, fg8g, fg8b), xyWord(0, 260), xyWord(16, 16) }) then return ok end
	if not checkPattern("area outside", 0, 260, 16, 16, function() return 0 end) then return ok end
	-- C: degenerate area (left > right) draws nothing even for a huge rect.
	if not clearBox(0, 230, 100, 100) then return ok end
	if not feed({ bor(0xE3000000, areaWord(50, 240)) }) then return ok end
	if not feed({ bor(0xE4000000, areaWord(40, 252)) }) then return ok end
	if not feed({ colorWord(0x60, fg8r, fg8g, fg8b), xyWord(0, 230), xyWord(100, 100) }) then return ok end
	if not checkPattern("degenerate area", 0, 230, 100, 100, function() return 0 end) then return ok end

	-- D: vram right-edge clamp: area (1000,340)-(1023,360); a rect starting
	-- at 990 gets cut at x = 1023.
	if not clearBox(992, 330, 48, 50) then return ok end
	if not feed({ bor(0xE3000000, areaWord(1000, 340)) }) then return ok end
	if not feed({ bor(0xE4000000, areaWord(1023, 360)) }) then return ok end
	if not feed({ colorWord(0x60, fg8r, fg8g, fg8b), xyWord(990, 330), xyWord(50, 50) }) then return ok end
	-- the check box stops at x = 1023 (vram width): indexing past the row end
	-- would read into the next row, where earlier phases have drawn.
	if not checkPattern("vram right edge", 990, 330, 34, 50, function(i, j)
		return (10 <= i and i <= 33 and 10 <= j and j <= 30) and fg or 0
	end) then return ok end

	-- E: positive offset (100, 10) moves a rect exactly.
	if not clearBox(0, 330, 124, 34) then return ok end
	if not feed({ bor(0xE3000000, areaWord(0, 0)) }) then return ok end
	if not feed({ bor(0xE4000000, areaWord(1023, 511)) }) then return ok end
	if not feed({ bor(0xE5000000, offWord(100, 10)) }) then return ok end
	if not feed({ colorWord(0x60, fg8r, fg8g, fg8b), xyWord(0, 330), xyWord(24, 24) }) then return ok end
	if not checkPattern("offset positive", 0, 330, 124, 34, function(i, j)
		return (100 <= i and i <= 123 and 10 <= j and j <= 33) and fg or 0
	end) then return ok end
	-- F: negative offset (-50, -10) moves a rect left and up; a rect pushed
	-- fully off-vram by the offset draws nothing.
	if not clearBox(0, 340, 96, 34) then return ok end
	if not feed({ bor(0xE5000000, offWord(-50, -10)) }) then return ok end
	if not feed({ colorWord(0x60, fg8r, fg8g, fg8b), xyWord(60, 350), xyWord(24, 24) }) then return ok end
	-- rect (60,350) 24x24 minus offset (50,10) lands at (10,340)-(33,363).
	if not checkPattern("offset negative", 10, 340, 74, 34, function(i, j)
		return (0 <= i and i <= 23 and 0 <= j and j <= 23) and fg or 0
	end) then return ok end
	if not clearBox(0, 340, 16, 16) then return ok end
	if not feed({ colorWord(0x60, fg8r, fg8g, fg8b), xyWord(0, 350), xyWord(16, 16) }) then return ok end
	if not checkPattern("offset cull", 0, 340, 16, 16, function() return 0 end) then return ok end

	-- G: sx11 coordinate wrap: xy x = -1 with offset +2 lands at x = 1.
	if not clearBox(0, 336, 16, 8) then return ok end
	if not feed({ bor(0xE5000000, offWord(2, 0)) }) then return ok end
	if not feed({ colorWord(0x60, fg8r, fg8g, fg8b), xyWord(0x7FF, 336), xyWord(8, 8) }) then return ok end
	if not checkPattern("sx11 wrap", 0, 336, 16, 8, function(i, j)
		return (1 <= i and i <= 8) and fg or 0
	end) then return ok end

	-- H: flat triangle under offset (10,4): vertices land at (42,340), (74,340), (58,356); the fully-inside box is x 51..64 across rows 344..349, so no pre-clear is needed.
	if not feed({ bor(0xE5000000, offWord(10, 4)) }) then return ok end
	if not feed({ colorWord(0x20, fg8r, fg8g, fg8b), xyWord(32, 336), xyWord(64, 336), xyWord(48, 352) }) then return ok end
	if not checkPattern("offset tri interior", 51, 344, 14, 6, function() return fg end) then return ok end

	-- restore the baseline.
	feed({ bor(0xE3000000, 0) })
	feed({ bor(0xE4000000, areaWord(1023, 511)) })
	feed({ bor(0xE5000000, 0) })
	feed({ 0x01000000 })
	return ok
end

-- ---- gpustat / gpuread encoding oracle --------------------------------------
-- pins status words to literal values (a shared bit-mapping bug is invisible to agreement).  ground
-- truth is duckstation's GPUSTATReg bitfield: 0-10 draw mode, 11/12 mask bits, 13 interlace, 14
-- reverse, 15 texture disable, 16-22 display-mode fields, 23 display disable, 24 irq request, 25-28
-- dynamic dma/idle/vram lines, 29-30 dma direction, 31 display lsb.  the core's composed bits 25-28
-- and the per-frame bit-31 toggle are core-only pins; the gp1(10h) latches are pinned too.  neither
-- model asserts bit 24 (crtc path out of scope), so gp1 02h is pinned as a no-op.
local function statusOracle(gpu, ref)
	local tag = "[oracle-status]"
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	local function gp1(v)
		if ok then
			gpu:writeGp1(v)
			ref:gp1(v)
			local before = failures
			compareState(tag, gpu, ref)
			if failures > before then ok = false end
		end
		return ok
	end
	local function checkRaw(where, expected)
		if not ok then return false end
		local c = gpu.status or 0
		local r = ref.gpustat or 0
		if c ~= expected or r ~= expected then
			fail(string.format("%s %s: status core=%08X ref=%08X expected=%08X", tag, where, c, r, expected))
			ok = false
			return false
		end
		return true
	end
	-- the composed register read exists only in the core (ref gpustat is the
	-- raw field), so this is a one-sided pin of the dynamic bits 25-28.
	local function checkComposed(where, expected)
		if not ok then return false end
		local c = gpu:read(0x1F801814)
		if c ~= expected then
			fail(string.format("%s %s: composed status core=%08X expected=%08X", tag, where, c, expected))
			ok = false
			return false
		end
		return true
	end
	local function checkStatus(where, expectedRaw, expectedComposed)
		return checkRaw(where, expectedRaw) and checkComposed(where, expectedComposed)
	end
	local function checkGpuread(where, expected)
		if not ok then return false end
		local c = gpu.gpuread or 0
		local r = ref.gpuread or 0
		if c ~= expected or r ~= expected then
			fail(string.format("%s %s: gpuread core=%08X ref=%08X expected=%08X", tag, where, c, r, expected))
			ok = false
			return false
		end
		return true
	end

	-- 1: soft reset (gp1 00h) restores 0x14802000: bit 13 (interlaced, preserved from power-on), 23 (display disable), 26/28 (idle / ready to receive).
	if not gp1(0x00000000) then return ok end
	if not checkStatus("reset", 0x14802000, 0x14802000) then return ok end

	-- 2: display enable/disable (gp1 03h) maps param 0 -> clear bit 23.
	if not gp1(0x03000000) then return ok end
	if not checkStatus("display enable", 0x14002000, 0x14002000) then return ok end
	if not gp1(0x03000001) then return ok end
	if not checkStatus("display disable", 0x14802000, 0x14802000) then return ok end

	-- 3: dma direction (gp1 04h) writes bits 29-30; the composed read adds bit 25 only for directions 1/2 while idle.
	if not gp1(0x04000000) then return ok end
	if not checkStatus("dma dir 0", 0x14802000, 0x14802000) then return ok end
	if not gp1(0x04000001) then return ok end
	if not checkStatus("dma dir 1", 0x34802000, 0x36802000) then return ok end
	if not gp1(0x04000002) then return ok end
	if not checkStatus("dma dir 2", 0x54802000, 0x56802000) then return ok end
	if not gp1(0x04000003) then return ok end
	if not checkStatus("dma dir 3", 0x74802000, 0x74802000) then return ok end

	-- 4: ack interrupt (gp1 02h) is a no-op -- neither model asserts bit 24 (crtc path out of scope).
	if not gp1(0x02000000) then return ok end
	if not checkStatus("ack interrupt", 0x74802000, 0x74802000) then return ok end

	-- 5: display mode (gp1 08h) lands on bits 17-18 HR1, 19 vres, 20 pal, 21 24bpp, 22 interlace, 16 HR2, 14 reverse; each write replaces the whole 0x007F4000 field.
	if not gp1(0x00000000) then return ok end
	if not gp1(0x08000000) then return ok end
	if not checkStatus("dmode 0", 0x14802000, 0x14802000) then return ok end
	if not gp1(0x08000003) then return ok end
	if not checkStatus("dmode hr1=3", 0x14862000, 0x14862000) then return ok end
	if not gp1(0x08000028) then return ok end
	if not checkStatus("dmode pal+interlace", 0x14D02000, 0x14D02000) then return ok end
	if not gp1(0x08000040) then return ok end
	if not checkStatus("dmode hr2", 0x14812000, 0x14812000) then return ok end
	if not gp1(0x08000080) then return ok end
	if not checkStatus("dmode reverse", 0x14806000, 0x14806000) then return ok end
	if not gp1(0x080000FF) then return ok end
	if not checkStatus("dmode all", 0x14FF6000, 0x14FF6000) then return ok end

	-- 6: gp0(e1) mirrors bits 0-10 into status and bit 11 into bit 15 (texture disable), gated by gp1 09h.  composed expectations carry the core's +1 pending tick per config command.
	if not gp1(0x00000000) then return ok end
	if not gp1(0x09000000) then return ok end
	if not feed({ 0xE1001FFF }) then return ok end
	if not checkStatus("draw mode masked", 0x148027FF, 0x108027FF) then return ok end
	if not gp1(0x09000001) then return ok end
	if not feed({ 0xE1001FFF }) then return ok end
	if not checkStatus("draw mode unmasked", 0x1480A7FF, 0x1080A7FF) then return ok end
	if not feed({ 0xE1000800 }) then return ok end
	if not checkStatus("texture disable only", 0x1480A000, 0x1080A000) then return ok end
	if not gp1(0x09000000) then return ok end
	if not feed({ 0xE1000000 }) then return ok end
	if not checkStatus("draw mode 0", 0x14802000, 0x10802000) then return ok end

	-- 7: gp0(e6) SetMaskBit: param bits 0-1 land on gpustat bits 11-12; composed carries the +1 pending tick.
	if not feed({ 0xE6000001 }) then return ok end
	if not checkStatus("mask set", 0x14802800, 0x10802800) then return ok end
	if not feed({ 0xE6000002 }) then return ok end
	if not checkStatus("mask check", 0x14803000, 0x10803000) then return ok end
	if not feed({ 0xE6000003 }) then return ok end
	if not checkStatus("mask both", 0x14803800, 0x10803800) then return ok end
	if not feed({ 0xE6000000 }) then return ok end
	if not checkStatus("mask clear", 0x14802000, 0x10802000) then return ok end

	-- 8: gp1(10h) info latches read back the texture window, drawing area, and signed 11-bit drawing offsets.
	if not feed({ 0xE20001EF }) then return ok end
	if not gp1(0x10000002) then return ok end
	if not checkGpuread("info window", 0x000001EF) then return ok end
	if not feed({ 0xE300500A }) then return ok end
	if not gp1(0x10000003) then return ok end
	if not checkGpuread("info area tl", 0x0000500A) then return ok end
	if not feed({ 0xE403212C }) then return ok end
	if not gp1(0x10000004) then return ok end
	if not checkGpuread("info area br", 0x0003212C) then return ok end
	if not feed({ 0xE501969C }) then return ok end
	if not gp1(0x10000005) then return ok end
	if not checkGpuread("info offset", 0x0001969C) then return ok end
	if not feed({ 0xE53FF800 }) then return ok end
	if not gp1(0x10000005) then return ok end
	if not checkGpuread("info offset neg y", 0x003FF800) then return ok end

	-- 9: composed read flips bits 25/27/28 while a vram->cpu transfer is in flight (duckstation: asserts ready_to_send, clears ready_to_receive, keeps dma request for direction 3).
	if not gp1(0x00000000) then return ok end
	if not gp1(0x04000003) then return ok end
	if not feed({ 0xC0000000, xyWord(0, 0), xyWord(8, 1) }) then return ok end
	if not checkComposed("v2c in flight", 0x6A802000) then return ok end
	if not drainV2C(tag, gpu, ref) then return ok end
	-- after the drain the core still reports non-idle: the four read words
	-- each cost 2 modeled ticks, which only drain via step().
	if not checkStatus("v2c drained", 0x74802000, 0x70802000) then return ok end

	-- 10: the core's per-frame step toggles bit 31 (display line lsb); core-only pin -- the trailing reset proves the toggle round-trips.
	if not gp1(0x00000000) then return ok end
	gpu:step(564480)
	if not checkComposed("frame odd", 0x94802000) then return ok end
	gpu:step(564480)
	if not checkComposed("frame even", 0x14802000) then return ok end

	-- restore the baseline for the phases that run after this one.
	gp1(0x00000000)
	feed({ 0x01000000 })
	return ok
end

-- ---- line drawing-area clip oracle ------------------------------------------
-- pins the per-pixel area filter (duckstation drawline: skip when x < left or x > right or
-- y < top or y > bottom, with sx11-wrapped coordinates feeding a signed dda) against literal
-- pixels: a horizontal entering from the left, a vertical clipped at the top, a negative sx11
-- endpoint (0x7d8 = -40), a right-edge clip, and a descending shallow line clipped at the
-- bottom.  each band is pre-cleared with a 0x02 fill (which ignores the clip).
local function lineClipOracle(gpu, ref)
	local tag = "[oracle-lineclip]"
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	local function clearBox(x, y, w, h)
		return feed({ colorWord(0x02, 0, 0, 0), xyWord(x, y), xyWord(w, h) })
	end
	local function areaWord(x, y) return bor(x, lshift(y, 10)) end
	local function c15(r, g, b)
		return bor(r // 8, lshift(g // 8, 5), lshift(b // 8, 10))
	end
	-- check a box where expectedFn(x, y) returns the 15-bit color or 0.
	local function checkBox(where, x0, y0, w, h, expectedFn)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local exp = expectedFn(x0 + i, y0 + j) or 0
				local idx = (y0 + j) * VRAM_W + (x0 + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= exp or rv ~= exp then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x0 + i, y0 + j, c, rv, exp))
					ok = false
					return false
				end
			end
		end
		return true
	end

	if not feed({ 0x01000000 }) then return ok end
	if not feed({ bor(0xE6000000, 0) }) then return ok end
	if not feed({ bor(0xE5000000, 0) }) then return ok end
	if not feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) }) then return ok end
	if not clearBox(0, 100, 380, 100) then return ok end

	-- a: horizontal (60,170)-(160,170), area left edge 100: exact positions, x < 100 filtered, so the drawn run is x = 100..160.
	local ca = c15(255, 0, 0)
	if not feed({ bor(0xE3000000, areaWord(100, 100)), bor(0xE4000000, areaWord(500, 400)) }) then return ok end
	if not feed({ colorWord(0x40, 255, 0, 0), xyWord(60, 170), xyWord(160, 170) }) then return ok end
	if not checkBox("left clip", 60, 169, 101, 3, function(x, y)
		return (y == 170 and x >= 100) and ca or 0
	end) then return ok end

	-- b: vertical (140,70)-(140,170): the p0.x >= p1.x swap runs the dda descending from y = 170, so rows 100..170 pass the area top of 100.
	local cb = c15(0, 255, 0)
	if not feed({ colorWord(0x40, 0, 255, 0), xyWord(140, 70), xyWord(140, 170) }) then return ok end
	if not checkBox("top clip", 139, 100, 3, 70, function(x, y)
		return x == 140 and cb or 0
	end) then return ok end

	-- c: sx11 endpoint -40 (0x7d8): the signed dda runs from x = -40, the filter admits x >= 0, so the visible run is x = 0..60.
	local cc = c15(0, 0, 255)
	if not feed({ bor(0xE3000000, 0), bor(0xE4000000, areaWord(1023, 511)) }) then return ok end
	if not feed({ colorWord(0x40, 0, 0, 255), xyWord(0x7D8, 185), xyWord(60, 185) }) then return ok end
	if not checkBox("negative x entry", 0, 184, 61, 3, function(x, y)
		return (y == 185 and x >= 0) and cc or 0
	end) then return ok end

	-- d: horizontal (260,195)-(360,195) against an area whose right edge is
	-- 300: the run x = 260..360 is exact and pixels x > 300 are filtered.
	local cd = c15(255, 255, 255)
	if not feed({ bor(0xE3000000, areaWord(0, 0)), bor(0xE4000000, areaWord(300, 511)) }) then return ok end
	if not feed({ colorWord(0x40, 255, 255, 255), xyWord(260, 195), xyWord(360, 195) }) then return ok end
	if not checkBox("right clip", 260, 194, 101, 3, function(x, y)
		return (y == 195 and x <= 300) and cd or 0
	end) then return ok end

	-- e: descending shallow (200,156)-(212,150), k = 12, dy = -6: the -1024 bias steps y down every other pixel
	-- (y = 156 - floor((i+1)/2)); an area bottom of 153 leaves the eight pixels at y = 153..150.
	local ce = c15(255, 255, 0)
	if not feed({ bor(0xE3000000, areaWord(100, 100)), bor(0xE4000000, areaWord(1023, 153)) }) then return ok end
	if not feed({ colorWord(0x40, 255, 255, 0), xyWord(200, 156), xyWord(212, 150) }) then return ok end
	local drawnE = {}
	for i = 0, 12 do
		local y = 156 - (i + 1) // 2
		if y <= 153 then
			drawnE[(200 + i) .. "," .. y] = true
		end
	end
	if not checkBox("bottom clip", 199, 150, 14, 7, function(x, y)
		return drawnE[x .. "," .. y] and ce or 0
	end) then return ok end

	-- restore the baseline.
	feed({ bor(0xE3000000, 0) })
	feed({ bor(0xE4000000, areaWord(1023, 511)) })
	feed({ bor(0xE6000000, 0) })
	feed({ 0x01000000 })
	return ok
end

-- ---- polyline oracle ---------------------------------------------------------
-- pins the variable-length command's wire parsing (vertex-led: first vertex follows the command
-- word, later ones are (color, xy)), its terminator ((word & 0xf000f000) == 0x50005000), and
-- per-segment chaining (consecutive segments share the join pixel) to literal pixels: a mono
-- three-vertex L, a gouraud three-vertex L, and a short mono polyline ending right after two
-- vertices (the reference's swallowed-terminator path).
local function polylineOracle(gpu, ref)
	local tag = "[oracle-polyline]"
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	local function clearBox(x, y, w, h)
		return feed({ colorWord(0x02, 0, 0, 0), xyWord(x, y), xyWord(w, h) })
	end
	local function c15(r, g, b)
		return bor(r // 8, lshift(g // 8, 5), lshift(b // 8, 10))
	end
	local function areaWord(x, y) return bor(x, lshift(y, 10)) end
	local function checkBox(where, x0, y0, w, h, expectedFn)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local exp = expectedFn(x0 + i, y0 + j) or 0
				local idx = (y0 + j) * VRAM_W + (x0 + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= exp or rv ~= exp then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x0 + i, y0 + j, c, rv, exp))
					ok = false
					return false
				end
			end
		end
		return true
	end
	-- per-pixel ramp over a run whose color span is a clean multiple of 40 texel-eighths (duckstation makefp/div_rgb): value = c*4096 + 2048 + i*step, sampled as floor(value/4096).
	local function ramp(step, i)
		return math.floor(0.5 + step * i)
	end

	if not feed({ 0x01000000 }) then return ok end
	if not feed({ bor(0xE6000000, 0) }) then return ok end
	if not feed({ bor(0xE5000000, 0) }) then return ok end
	if not feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) }) then return ok end
	if not clearBox(55, 205, 200, 70) then return ok end

	-- mono L: v0 (60,220) -> v1 (100,220) -> v2 (100,260); the corner (100,220) is both segments' endpoint.  horizontal x = 60+i, vertical y = 260-i, both exact.
	local cA = c15(200, 100, 50)
	if not feed({ colorWord(0x48, 200, 100, 50), xyWord(60, 220), xyWord(100, 220),
		xyWord(100, 260), 0x50005000 }) then return ok end
	if not checkBox("mono L", 60, 218, 42, 44, function(x, y)
		if y == 220 and x >= 60 and x <= 100 then return cA end
		if x == 100 and y >= 220 and y <= 260 then return cA end
		return 0
	end) then return ok end

	-- gouraud L: c1 (255,0,0) in the command, c2 (0,0,255), c3 (0,255,0); wire = cmd, xy1, c2, xy2, c3, xy3, term.
	-- horizontal ramps red->blue (r = 255.5-6.375i, b = 0.5+6.375i); the vertical swaps to run green->blue
	-- upward (g = 255.5-6.375i, b = 0.5+6.375i, i = 260-y).  the join (190,220) is blue from both.
	if not feed({ colorWord(0x58, 255, 0, 0), xyWord(150, 220),
		colorWord(0, 0, 0, 255), xyWord(190, 220),
		colorWord(0, 0, 255, 0), xyWord(190, 260), 0x50005000 }) then return ok end
	if not checkBox("gouraud L", 150, 218, 42, 44, function(x, y)
		if y == 220 and x >= 150 and x <= 190 then
			local i = x - 150
			return c15(ramp(-6.375, i) + 255, 0, ramp(6.375, i))
		end
		if x == 190 and y >= 220 and y <= 260 then
			local i = 260 - y
			return c15(0, ramp(-6.375, i) + 255, ramp(6.375, i))
		end
		return 0
	end) then return ok end

	-- short mono polyline: the terminator follows the second vertex, so the
	-- whole command is one horizontal segment (210,220)-(250,220).
	local cB = c15(50, 200, 150)
	if not feed({ colorWord(0x48, 50, 200, 150), xyWord(210, 220), xyWord(250, 220), 0x50005000 }) then return ok end
	if not checkBox("short mono", 210, 218, 41, 3, function(x, y)
		return (y == 220 and x >= 210 and x <= 250) and cB or 0
	end) then return ok end

	-- restore the baseline.
	feed({ bor(0xE6000000, 0) })
	feed({ bor(0xE3000000, 0) })
	feed({ bor(0xE4000000, areaWord(1023, 511)) })
	feed({ 0x01000000 })
	return ok
end

-- ---- gpu timing oracle ------------------------------------------------------
-- pins the core's pendingCycles delta per command class to literals from duckstation's formulas;
-- an audit found three real divergences (single lines charged the polyline setup, textured-rect
-- overhead was one width per row in every mode, and the rect box clamped instead of intersecting,
-- so disjoint rects cost a row).  contract: config words 1; fill 46 + ((w/8)+9)*h (w rounded to
-- 16); lines max(w,h), no setup; polylines 16 + per-segment max(w,h); rects 16 + per-row x drawn
-- height; polygons setup table {{46,226},{334,496}}/{{82,262},{370,532}} + shoelace area/2
-- (doubled textured, +50% semi/mask); v2v width*height*2; clut reloads 16/256 on the first
-- palette/8bpp change.  nothing else compares ticks, so these are the only gate on timing drift.
local function ticksOracle(gpu, ref)
	local tag = "[oracle-ticks]"
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	local function gp1(v)
		if ok then
			gpu:writeGp1(v)
			ref:gp1(v)
			local before = failures
			compareState(tag, gpu, ref)
			if failures > before then ok = false end
		end
		return ok
	end
	-- feed one whole command (a flat word list) and pin the core's modeled
	-- gpu time delta.
	local function pin(where, expected, words)
		if not ok then return false end
		local before = gpu.pendingCycles or 0
		if not feed(words) then return false end
		local delta = (gpu.pendingCycles or 0) - before
		if delta ~= expected then
			fail(string.format("%s %s: core pendingCycles += %d, expected %d", tag, where, delta, expected))
			ok = false
			return false
		end
		return true
	end
	local function areaWord(x, y) return bor(x, lshift(y, 10)) end
	-- palette 0x600: zero under the 0x9ff texpage merge mask (no page/mode/semi change), so only the deliberate first-draw clut reloads fire.
	local function uvP(u, v) return bor(u, lshift(v, 8), lshift(0x600, 16)) end

	-- soft reset zeroes pendingCycles and invalidates the clut cache.
	if not gp1(0x00000000) then return ok end
	if (gpu.pendingCycles or 0) ~= 0 then
		fail(string.format("%s reset: pendingCycles = %d, expected 0", tag, gpu.pendingCycles or 0))
		return false
	end

	-- config words: nop 0, cache-clear 1, every gp0(e1..e6) write 1.
	if not pin("nop", 0, { 0x00000000 }) then return ok end
	if not pin("clear cache", 1, { 0x01000000 }) then return ok end
	if not pin("e6", 1, { 0xE6000000 }) then return ok end
	if not pin("e5", 1, { 0xE5000000 }) then return ok end
	if not pin("e2", 1, { 0xE2000000 }) then return ok end
	if not pin("e3", 1, { 0xE3000000 }) then return ok end
	-- draw area = full vram.
	if not pin("e4", 1, { bor(0xE4000000, areaWord(1023, 511)) }) then return ok end
	if not pin("e1 mode0", 1, { drawModeWord(0, 0, 0, 0, 0, 0, 0) }) then return ok end

	-- fill (0x02): 46 + ((width/8) + 9) * height, width pre-rounded up to 16.
	-- a 48-wide 1-tall fill: 46 + (6 + 9) * 1 = 61.
	if not pin("fill 48x1", 61, { colorWord(0x02, 0, 0, 0), xyWord(0, 0), xyWord(48, 1) }) then return ok end
	-- a zero-size fill rounds to width 0, height 0: 46 + (0 + 9) * 0 = 46.
	if not pin("fill zero", 46, { colorWord(0x02, 0, 0, 0), xyWord(0, 0), xyWord(0, 0) }) then return ok end

	-- lines: max(w, h) of the drawn span, no setup for single lines (the audit finding).  (60,220)-(100,220) spans 41: 41.
	if not pin("line h", 41, { colorWord(0x40, 200, 100, 50), xyWord(60, 220), xyWord(100, 220) }) then return ok end
	-- vertical (60,220)-(60,260): 41.
	if not pin("line v", 41, { colorWord(0x40, 200, 100, 50), xyWord(60, 220), xyWord(60, 260) }) then return ok end
	-- gouraud shallow diagonal: max(41, 5) = 41, not the pixel count 41*5.
	if not pin("line gouraud", 41, { colorWord(0x50, 255, 0, 0), xyWord(60, 220), colorWord(0, 0, 255, 0), xyWord(100, 224) }) then return ok end
	-- a degenerate point line spans 1x1: 1.
	if not pin("line point", 1, { colorWord(0x40, 90, 90, 90), xyWord(60, 220), xyWord(60, 220) }) then return ok end
	-- a line whose bounding box exceeds max_primitive is culled before ticks:
	-- (0x400 -> -1024) to (0) spans 1025 > 1024, so 0.
	if not pin("line culled", 0, { colorWord(0x40, 90, 90, 90), xyWord(1024, 200), xyWord(0, 200) }) then return ok end

	-- polylines: 16 setup once + per-segment line ticks.
	-- mono 2-vertex (210,220)-(250,220): 16 + 41 = 57.
	if not pin("polyline mono", 57, { colorWord(0x48, 50, 200, 150), xyWord(210, 220), xyWord(250, 220), 0x50005000 }) then return ok end
	-- mono L: 16 + 41 + 41 = 98.
	if not pin("polyline L", 98, { colorWord(0x48, 200, 100, 50), xyWord(60, 220), xyWord(100, 220), xyWord(100, 260), 0x50005000 }) then return ok end
	-- gouraud 2-vertex (0x58 = gouraud + polyline bit) (300,400)-(420,380): 16 + max(121,21) = 137.
	-- (0x4c would parse its color words as extra vertices, so the wire must use 0x58.)
	if not pin("polyline gouraud", 137, { colorWord(0x58, 255, 0, 0), xyWord(300, 400), colorWord(0, 0, 255, 0), xyWord(420, 380), 0x50005000 }) then return ok end

	-- rectangles: 16 setup + per-row cost x drawn height of the area-intersect (a disjoint rect is empty).  untextured 60x40 at (300,100): 16 + 60*40 = 2416.
	if not pin("rect var", 2416, { colorWord(0x60, 10, 200, 30), xyWord(300, 100), xyWord(60, 40) }) then return ok end
	-- untextured 16x16 at (300,100): 16 + 16 * 16 = 272.
	if not pin("rect 16x16", 272, { colorWord(0x78, 30, 200, 10), xyWord(300, 100) }) then return ok end
	-- a rect whose sx11-wrapped corner lands fully left of the drawing area
	-- (0x4b0 -> -848, span -848..-785): intersect empty -> 16.
	if not pin("rect off-area", 16, { colorWord(0x60, 60, 60, 60), xyWord(1200, 100), xyWord(64, 64) }) then return ok end
	-- mask-check adds half the width per row (duckstation (w + 1) / 2).
	if not pin("mask check on", 1, { 0xE6000002 }) then return ok end
	if not pin("rect mask-check", 3616, { colorWord(0x60, 10, 200, 30), xyWord(300, 100), xyWord(60, 40) }) then return ok end
	if not pin("mask check off", 1, { 0xE6000000 }) then return ok end

	-- textured rects: mode-dependent cache reload per row; palette 0x600 stays constant, so only the first draw (+16) and first 8bpp draw (+256) reload.  4bpp 60x40: 16 + 16 + (60+60)*40 = 4832.
	if not pin("tex rect 4bpp first", 4832, { colorWord(0x64, 255, 255, 255), xyWord(300, 100), uvP(0, 0), xyWord(60, 40) }) then return ok end
	-- same draw again, no reload: 16 + 120 * 40 = 4816.
	if not pin("tex rect 4bpp", 4816, { colorWord(0x64, 255, 255, 255), xyWord(300, 100), uvP(0, 0), xyWord(60, 40) }) then return ok end
	-- 8bpp, width 200 (> 128): reload 256 + setup 16 + (200 + (200/4)*8) * 3
	-- = 272 + 600 * 3 = 2072.
	if not pin("mode 8bpp", 1, { drawModeWord(0, 0, 1, 0, 0, 0, 0) }) then return ok end
	if not pin("tex rect 8bpp wide", 2072, { colorWord(0x64, 255, 255, 255), xyWord(300, 100), uvP(0, 0), xyWord(200, 3) }) then return ok end
	if not pin("tex rect 8bpp wide2", 1816, { colorWord(0x64, 255, 255, 255), xyWord(300, 100), uvP(0, 0), xyWord(200, 3) }) then return ok end
	-- 8bpp small row: 64x20 area 1280 <= 2048 keeps one width per row:
	-- 16 + (64 + 64) * 20 = 2576.
	if not pin("tex rect 8bpp small", 2576, { colorWord(0x64, 255, 255, 255), xyWord(300, 200), uvP(0, 0), xyWord(64, 20) }) then return ok end
	-- 8bpp 64x33 area 2112 > 2048 switches to the reload term
	-- (64/4)*(4*(128/64)) = 128 per row: 16 + (64 + 128) * 33 = 6352.
	if not pin("tex rect 8bpp cache", 6352, { colorWord(0x64, 255, 255, 255), xyWord(300, 220), uvP(0, 0), xyWord(64, 33) }) then return ok end
	-- direct15, width 200 (> 128): overhead (200/2)*8 = 800 per row:
	-- 16 + (200 + 800) * 3 = 3016.
	if not pin("mode direct15", 1, { drawModeWord(0, 0, 2, 0, 0, 0, 0) }) then return ok end
	if not pin("tex rect 15bpp wide", 3016, { colorWord(0x64, 255, 255, 255), xyWord(300, 100), uvP(0, 0), xyWord(200, 3) }) then return ok end
	-- direct15 64x17 area 1088 > 1024: reload term (64/4)*(8*(128/64)) = 256
	-- per row: 16 + (64 + 256) * 17 = 5456.
	if not pin("tex rect 15bpp cache", 5456, { colorWord(0x64, 255, 255, 255), xyWord(300, 200), uvP(0, 0), xyWord(64, 17) }) then return ok end
	-- direct15 60x10 area 600 <= 1024 stays one width: 16 + 120 * 10 = 1216.
	if not pin("tex rect 15bpp small", 1216, { colorWord(0x64, 255, 255, 255), xyWord(300, 220), uvP(0, 0), xyWord(60, 10) }) then return ok end

	-- polygons: setup table {{46,226},{334,496}} (tris) / {{82,262},{370,532}} (quads), indexed [quad][shaded][textured],
	-- plus shoelace area/2 (doubled textured, +50% semi/mask).  a collinear polygon isolates the setup entry.  (20,360),(300,360),(20,460): 28000/2 = 14000.
	if not pin("mode back 4bpp", 1, { drawModeWord(0, 0, 0, 0, 0, 0, 0) }) then return ok end
	if not pin("poly flat", 14046, { colorWord(0x20, 255, 255, 0), xyWord(20, 360), xyWord(300, 360), xyWord(20, 460) }) then return ok end
	if not pin("poly flat tex", 28226, { colorWord(0x24, 255, 255, 255), xyWord(20, 360), uvP(0, 0), xyWord(300, 360), uvP(0, 0), xyWord(20, 460), uvP(0, 0) }) then return ok end
	if not pin("poly shaded", 14334, { colorWord(0x30, 255, 0, 0), xyWord(20, 360), colorWord(0, 0, 255, 0), xyWord(300, 360), colorWord(0, 0, 0, 255), xyWord(20, 460) }) then return ok end
	if not pin("poly shaded tex", 28496, { colorWord(0x34, 255, 0, 0), xyWord(20, 360), uvP(0, 0), colorWord(0, 0, 255, 0), xyWord(300, 360), uvP(0, 0), colorWord(0, 0, 0, 255), xyWord(20, 460), uvP(0, 0) }) then return ok end
	-- a triangle whose bounding box exceeds max_primitive is culled before
	-- the area ticks: only the 46 setup.
	if not pin("poly culled", 46, { colorWord(0x20, 1, 1, 1), xyWord(0, 0), xyWord(3000, 200), xyWord(0, 3000) }) then return ok end
	-- collinear quads isolate the quad setup entries (both split triangles
	-- have zero area).
	if not pin("quad flat", 82, { colorWord(0x28, 0, 255, 255), xyWord(100, 100), xyWord(200, 100), xyWord(300, 100), xyWord(400, 100) }) then return ok end
	if not pin("quad flat tex", 262, { colorWord(0x2C, 255, 255, 255), xyWord(100, 100), uvP(0, 0), xyWord(200, 100), uvP(0, 0), xyWord(300, 100), uvP(0, 0), xyWord(400, 100), uvP(0, 0) }) then return ok end
	if not pin("quad shaded", 370, { colorWord(0x38, 255, 0, 0), xyWord(100, 100), colorWord(0, 0, 255, 0), xyWord(200, 100), colorWord(0, 0, 0, 255), xyWord(300, 100), colorWord(0, 255, 255, 0), xyWord(400, 100) }) then return ok end
	if not pin("quad shaded tex", 532, { colorWord(0x3C, 255, 0, 0), xyWord(100, 100), uvP(0, 0), colorWord(0, 0, 255, 0), xyWord(200, 100), uvP(0, 0), colorWord(0, 0, 0, 255), xyWord(300, 100), uvP(0, 0), colorWord(0, 255, 255, 0), xyWord(400, 100), uvP(0, 0) }) then return ok end

	-- vram-to-vram: width * height * 2, charged even when the copy is skipped
	-- (src == dst without set-mask).
	if not pin("v2v", 4096, { 0x80000000, xyWord(0, 0), xyWord(300, 0), xyWord(64, 32) }) then return ok end
	if not pin("v2v self skip", 64, { 0x80000000, xyWord(200, 200), xyWord(200, 200), xyWord(8, 4) }) then return ok end

	-- restore the baseline for the phases that run after this one.
	gp1(0x00000000)
	feed({ 0x01000000 })
	return ok
end

-- ---- vram transfer oracle ---------------------------------------------------
-- pins cpu->vram / vram->cpu transfer geometry to literal vram words: each data word carries two
-- 16-bit pixels low half first, x wraps within the row (1024-wide ring, (x + col) % 1024), rows
-- wrap % 512, and each transferred word costs 2 modeled ticks.  a gp1 soft reset mid-upload aborts
-- the transfer, keeping the pixels already written.
local function transferOracle(gpu, ref)
	local tag = "[oracle-transfer]"
	local ok = true
	local function feed(words)
		if ok then ok = feedWords(tag, gpu, ref, words) end
		return ok
	end
	local function gp1(v)
		if ok then
			gpu:writeGp1(v)
			ref:gp1(v)
			local before = failures
			compareState(tag, gpu, ref)
			if failures > before then ok = false end
		end
		return ok
	end
	-- feed one whole command stream (transfer header + payload) and pin the
	-- core's modeled gpu time delta (2 per transferred word, 0 for headers).
	local function pin(where, expected, words)
		if not ok then return false end
		local before = gpu.pendingCycles or 0
		if not feed(words) then return false end
		local delta = (gpu.pendingCycles or 0) - before
		if delta ~= expected then
			fail(string.format("%s %s: core pendingCycles += %d, expected %d", tag, where, delta, expected))
			ok = false
			return false
		end
		return true
	end
	local function areaWord(x, y) return bor(x, lshift(y, 10)) end
	local function checkBox(where, x0, y0, w, h, expectedFn)
		if not ok then return false end
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local exp = expectedFn(x0 + i, y0 + j) or 0
				local idx = (y0 + j) * VRAM_W + (x0 + i) + 1
				local c = gpu.vram[idx] or 0
				local rv = ref.vram[idx] or 0
				if c ~= exp or rv ~= exp then
					fail(string.format("%s %s: pixel (%d,%d) core=%04X ref=%04X expected=%04X",
						tag, where, x0 + i, y0 + j, c, rv, exp))
					ok = false
					return false
				end
			end
		end
		return true
	end
	-- build n data words whose two halves are the consecutive pixel values
	-- 0..2n-1 (low half first, as the wire carries them).
	local function pairWords(n)
		local out = {}
		for k = 0, n - 1 do
			out[k + 1] = bor(2 * k, lshift(2 * k + 1, 16))
		end
		return out
	end
	local function concat(a, b)
		local out = {}
		for _, v in ipairs(a) do out[#out + 1] = v end
		for _, v in ipairs(b) do out[#out + 1] = v end
		return out
	end
	-- read n literal words from a vram->cpu transfer (header already fed) and
	-- pin the core's per-word read ticks.
	local function readWords(where, expected)
		if not ok then return false end
		local before = gpu.pendingCycles or 0
		for i = 1, #expected do
			local c = gpu:read(0x1F801810)
			local r = ref:readGpuData()
			if c ~= expected[i] or r ~= expected[i] then
				fail(string.format("%s %s: read word %d core=%08X ref=%08X expected=%08X",
					tag, where, i - 1, c, r, expected[i]))
				ok = false
				return false
			end
		end
		if (gpu.pendingCycles or 0) - before ~= 2 * #expected then
			fail(string.format("%s %s: read ticks %d, expected %d", tag, where,
				(gpu.pendingCycles or 0) - before, 2 * #expected))
			ok = false
			return false
		end
		if not (gpu.gp0mode == "cmd" and #gpu.gp0buf == 0 and ref.blitterState == "idle" and #ref.fifo == 0) then
			fail(string.format("%s %s: transfer did not complete", tag, where))
			ok = false
			return false
		end
		return true
	end

	if not gp1(0x00000000) then return ok end
	if not feed({ 0xE6000000 }) then return ok end
	if not feed({ 0xE5000000 }) then return ok end
	if not feed({ 0xE3000000 }) then return ok end
	if not feed({ bor(0xE4000000, areaWord(1023, 511)) }) then return ok end
	if not feed({ drawModeWord(0, 0, 0, 0, 0, 0, 0) }) then return ok end

	-- a: aligned cpu->vram upload, 16x4 at (300,100): 32 data words x 2 ticks = 64; pixel n holds value n; region pre-cleared with a 0x02 fill.
	if not feed({ colorWord(0x02, 0, 0, 0), xyWord(300, 100), xyWord(16, 4) }) then return ok end
	if not pin("c2v aligned", 64, concat({ 0xA0000000, xyWord(300, 100), xyWord(16, 4) }, pairWords(32))) then return ok end
	if not checkBox("c2v aligned", 300, 100, 16, 4, function(x, y)
		return (y - 100) * 16 + (x - 300)
	end) then return ok end

	-- b: odd-x upload at (1,200), 8x2: the halves must land at consecutive
	-- pixels starting at the odd column, not re-aligned to even.
	if not feed({ colorWord(0x02, 0, 0, 0), xyWord(0, 200), xyWord(32, 4) }) then return ok end
	if not pin("c2v odd-x", 16, concat({ 0xA0000000, xyWord(1, 200), xyWord(8, 2) }, pairWords(8))) then return ok end
	if not checkBox("c2v odd-x", 1, 200, 8, 2, function(x, y)
		return (y - 200) * 8 + (x - 1)
	end) then return ok end

	-- c: word boundary at the right vram edge: an 8-pixel upload at x = 1020 writes 1020..1023 then wraps within the row to 0..3.
	if not feed({ colorWord(0x02, 0, 0, 0), xyWord(1000, 300), xyWord(64, 1) }) then return ok end
	if not pin("c2v straddle", 8, concat({ 0xA0000000, xyWord(1020, 300), xyWord(8, 1) }, pairWords(4))) then return ok end
	if not checkBox("c2v straddle", 1018, 300, 6, 1, function(x, y)
		if x >= 1020 then return x - 1020 end
		return 0
	end) then return ok end
	if not checkBox("c2v straddle wrap", 0, 300, 6, 1, function(x, y)
		if x < 4 then return x + 4 end
		return 0
	end) then return ok end
	if not checkBox("c2v straddle row", 0, 301, 8, 1, function(x, y)
		return 0
	end) then return ok end

	-- d: rows wrap with % 512: an upload at y = 510 with height 3 writes rows
	-- 510, 511, then row 0.
	if not feed({ colorWord(0x02, 0, 0, 0), xyWord(10, 508), xyWord(16, 6) }) then return ok end
	if not pin("c2v row wrap", 24, concat({ 0xA0000000, xyWord(10, 510), xyWord(8, 3) }, pairWords(12))) then return ok end
	if not checkBox("c2v row wrap", 10, 510, 8, 1, function(x, y)
		return x - 10
	end) then return ok end
	if not checkBox("c2v row wrap2", 10, 511, 8, 1, function(x, y)
		return 8 + (x - 10)
	end) then return ok end
	if not checkBox("c2v row wrap3", 10, 0, 8, 1, function(x, y)
		return 16 + (x - 10)
	end) then return ok end

	-- e: vram->cpu readback of the aligned upload: 32 literal words, 2 ticks
	-- each, cursor stepping continuously across the row ends.
	if not feed({ 0xC0000000, xyWord(300, 100), xyWord(16, 4) }) then return ok end
	local readE = {}
	for k = 0, 31 do
		readE[k + 1] = bor(2 * k, lshift(2 * k + 1, 16))
	end
	if not readWords("v2c aligned", readE) then return ok end

	-- f: vram->cpu read crossing the row ring: (1020,300) width 8 reads the
	-- straddle upload's pixels 1020..1023 then 0..3 in one continuous cursor.
	if not feed({ 0xC0000000, xyWord(1020, 300), xyWord(8, 1) }) then return ok end
	local readF = {}
	for k = 0, 3 do
		readF[k + 1] = bor(2 * k, lshift(2 * k + 1, 16))
	end
	if not readWords("v2c ring", readF) then return ok end

	-- g: gp1 soft reset mid-upload aborts the transfer -- the two data words already written (4 pixels, 4 ticks) stay in vram.
	if not feed({ colorWord(0x02, 0, 0, 0), xyWord(400, 100), xyWord(16, 2) }) then return ok end
	if not pin("c2v partial", 4, { 0xA0000000, xyWord(400, 100), xyWord(8, 2), 0x00010000, 0x00030002 }) then return ok end
	if not gp1(0x00000000) then return ok end
	if not (gpu.gp0mode == "cmd" and #gpu.gp0buf == 0 and ref.blitterState == "idle" and #ref.fifo == 0) then
		fail(tag .. " mid-reset: transfer did not abort to command idle")
		ok = false
		return false
	end
	if not checkBox("c2v partial", 400, 100, 8, 1, function(x, y)
		local i = x - 400
		if i < 4 then return i end
		return 0
	end) then return ok end
	if not checkBox("c2v partial row2", 400, 101, 8, 1, function(x, y)
		return 0
	end) then return ok end
	if not pin("post-reset e6", 1, { 0xE6000000 }) then return ok end

	-- restore the baseline for the phases that run after this one.
	gp1(0x00000000)
	feed({ 0x01000000 })
	return ok
end

-- ---- main ------------------------------------------------------------------

local function main()
	local gpu = GPU.new()
	local ref = GPURef.new()
	local rng = newRng(0x51E51E5)
	gpu.vramLog = {}
	ref.vramLog = {}

	scripted(gpu, ref, rng)
	texturedScripted(gpu, ref, rng)
	if not ditherOracle(gpu, ref) then
		return 1
	end
	if not eightBitOracle(gpu, ref) then
		return 1
	end
	if not blendOracle(gpu, ref) then
		return 1
	end
	if not maskOracle(gpu, ref) then
		return 1
	end
	if not v2vOracle(gpu, ref) then
		return 1
	end
	if not shadeOracle(gpu, ref) then
		return 1
	end
	if not texUvOracle(gpu, ref) then
		return 1
	end
	if not modulateOracle(gpu, ref) then
		return 1
	end
	if not polySemiOracle(gpu, ref) then
		return 1
	end
	if not windowOracle(gpu, ref) then
		return 1
	end
	if not clipOracle(gpu, ref) then
		return 1
	end
	if not statusOracle(gpu, ref) then
		return 1
	end
	if not lineClipOracle(gpu, ref) then
		return 1
	end
	if not polylineOracle(gpu, ref) then
		return 1
	end
	if not ticksOracle(gpu, ref) then
		return 1
	end
	if not transferOracle(gpu, ref) then
		return 1
	end
	maskScripted(gpu, ref, rng)
	v2cScripted(gpu, ref, rng)
	gp1Sweep(gpu, ref, rng)
	fuzz(gpu, ref, rng)

	-- belt-and-braces: one exact full-vram sweep proves the incremental log
	-- compares missed nothing (the logs only see words the engines wrote).
	local sweepX, sweepY, sweepA, sweepB = vramFirstDiff(gpu.vram, ref.vram)
	if sweepX then
		fail(string.format("final sweep: vram diverged at (%d,%d) core=%04X ref=%04X",
			sweepX, sweepY, sweepA, sweepB))
	end
	if failures == 0 then
		print(string.format("GPU_DIFF PASS: %d settled commands in agreement", totalSettles))
		return 0
	end
	print(string.format("GPU_DIFF FAIL: %d divergence(s)", failures))
	return 1
end

require("@lune/process").exit(main())