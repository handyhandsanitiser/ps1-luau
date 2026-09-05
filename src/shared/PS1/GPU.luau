-- ps1 gpu with vram, gp0 drawing commands, gp1 display config, and frame readout
local GPU = {}
GPU.__index = GPU

local band   = bit32.band
local bor    = bit32.bor
local bxor   = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift
local bnot   = bit32.bnot

local VRAM_W = 1024
local VRAM_H = 512
local MAX_PRIMITIVE_WIDTH = 1024
local MAX_PRIMITIVE_HEIGHT = 512

-- duckstation s_setup_time[quad][shaded][textured] for polygon setup ticks.
local POLY_SETUP_TIME = {
	{ { 46, 226 }, { 334, 496 } }, -- quad = 0
	{ { 82, 262 }, { 370, 532 } }, -- quad = 1
}

local function sx11(v) v = band(v, 0x7FF); if v >= 0x400 then return v - 0x800 end return v end

-- fixed-point helpers used by the software rasterizer
-- c++ s32/s64 division truncates toward zero (for all sign combinations).
local function divTrunc(n, d)
	local q = n / d
	if q >= 0 then return math.floor(q) end
	return math.ceil(q)
end
-- s32 wrap: convert a lua number (possibly > 2^31) to signed 32-bit.
local function s32(v)
	v = band(v, 0xFFFFFFFF)
	if v >= 0x80000000 then v = v - 0x100000000 end
	return v
end
-- u32 wrap.
local function u32(v) return band(v, 0xFFFFFFFF) end
-- truncate8 / truncate16
local function t8(v) return band(v, 0xFF) end
local function t16(v) return band(v, 0xFFFF) end
-- truncategpuvertexposition (sx11) on an s32 value.
local function truncVertexPos(x) return sx11(x) end
-- fp12 -> s32 helpers (module-level: these used to be per-call closures)
local function unfpXy(x)
	local v = math.floor(x / 4294967296)
	v = band(v, 0xFFFFFFFF)
	if v >= 0x80000000 then v = v - 0x100000000 end
	return v
end
local function makefpXy(x) return x * 4294967296 + (4294967296 - 2048) end
local function makeStepXy(dx, dy)
	local num = dx * 4294967296
	if dx < 0 then num = num - (dy - 1)
	elseif dx > 0 then num = num + (dy - 1) end
	return divTrunc(num, dy)
end
local function getTexturePageBaseX(bits) return band(bits, 0xF) * 64 end
local function getTexturePageBaseY(bits) return band(rshift(bits, 4), 1) * 256 end

-- 15-bit vram color helpers
local function rgb24to15(r, g, b)
	return bor(band(rshift(r, 3), 0x1F), lshift(band(rshift(g, 3), 0x1F), 5), lshift(band(rshift(b, 3), 0x1F), 10))
end
local function rgb15r(c) return band(c, 0x1F) * 8 end
local function rgb15g(c) return band(rshift(c, 5), 0x1F) * 8 end
local function rgb15b(c) return band(rshift(c, 10), 0x1F) * 8 end

-- dither lut (duckstation g_dither_lut): lut[i][j][v] = clamp((v + matrix[i][j]) >> 3, 0, 31),
-- 512 entries per matrix cell (modulation products can reach ~31*255/16 = 494).
local DITHER_MATRIX = {
	{ -4, 0, -3, 1 },
	{ 2, -2, 3, -1 },
	{ -3, 1, -4, 0 },
	{ 3, -1, 2, -2 },
}
local ditherLut = table.create(4 * 4 * 512)
for di = 0, 3 do
	for dj = 0, 3 do
		for dv = 0, 511 do
			ditherLut[di * 2048 + dj * 512 + dv + 1] = math.max(0, math.min(31, math.floor((dv + DITHER_MATRIX[di + 1][dj + 1]) / 8)))
		end
	end
end
-- dithering off still runs the lut at the fixed (2,3) cell, which is the identity v>>3.

-- gpustat compose for the poll-hot 0x1f801814 read (module-local so the metatable dispatch is gone):
-- dynamic bits 25 dma_data_request / 26 gpu_idle / 27 ready_to_send_vram / 28 ready_to_receive_dma,
-- where gpu_idle also requires pendingcycles drained.  cached: a hit is one field read; ckpt clears the cache on restore.
local function composeStatus(self)
	local cached = self._statusCache
	if cached ~= nil then return cached end
	local s = self.status
	local readySendVram = self.gp0mode == "vramToCpu"
	local readyReceiveDma = not readySendVram
	local idle = self.pendingCycles <= 0 and self.gp0mode == "cmd" and #(self.gp0buf or {}) == 0
	local dr = 0
	if self.dmaDirection == 1 or self.dmaDirection == 2 then
		dr = readyReceiveDma and 1 or 0 -- FIFO / CPUtoGP0: ready to receive
	elseif self.dmaDirection == 3 then
		dr = readySendVram and 1 or 0 -- GPUREADtoCPU: ready to send
	end
	s = band(s, bnot(0x1E000000))
	if dr ~= 0 then s = bor(s, 0x02000000) end
	if idle then s = bor(s, 0x04000000) end
	if readySendVram then s = bor(s, 0x08000000) end
	if readyReceiveDma then s = bor(s, 0x10000000) end
	s = band(s, 0xFFFFFFFF)
	self._statusCache = s
	return s
end

-- invalidate the gpustat cache wherever one of the five inputs changes.
local function invalidateStatus(self)
	self._statusCache = nil
end

function GPU.new()
	local self = setmetatable({}, GPU)
	self.vram   = table.create(VRAM_W * VRAM_H, 0)
	self.status = 0x14802000
	self.frameCycleCounter = 0
	self.cyclesPerFrame = 564480
	self.dmaDirection = 0
	self.gpuread  = 0
	-- gp1 display settings
	self.displayStartX = 0; self.displayStartY = 0
	self.displayWidth  = 320; self.displayHeight = 240
	self.displayDisabled = true; self.interlaced = false
	self.dispMode = 0
	self.hdispX1 = nil; self.hdispX2 = nil; self.vdispY1 = nil; self.vdispY2 = nil
	-- drawing area
	self.drawLeft = 0; self.drawTop = 0; self.drawRight = 0; self.drawBottom = 0
	self.drawOffX = 0; self.drawOffY = 0
	-- texture settings
	self.tpX = 0; self.tpY = 0; self.tpMode = 0; self.rawTP = 0
	self.clutX = 0; self.clutY = 0
	self.texWindowMaskX = 0; self.texWindowMaskY = 0
	self.texWindowOffX  = 0; self.texWindowOffY  = 0
	self.dither = false; self.drawToDisplay = false; self.texDisable = false
	self.maskSet = false; self.maskCheck = false
	self.semiTrans = 0
	-- duckstation draw-state registers (the drawing path's source of truth; the
	-- tpx/clutx/... legacy fields above are kept in sync as mirrors).
	self.drawModeReg = 0
	self.texturePaletteReg = 0
	self.clut = table.create(256, 0) -- CLUT cache (g_gpu_clut)
	self.currentClutRegBits = nil
	self.currentClutIs8bit = false
	self.setTextureDisableMask = false
	self.textureEnableMask = true
	-- gp0 state machine
	self.gp0buf = {}; self.gp0needed = 0; self.gp0handler = nil
	self.gp0mode = "cmd"  -- "cmd" | "cpuToVram" | "vramToCpu"
	-- cpu→vram transfer
	self.cvX = 0; self.cvY = 0; self.cvW = 0; self.cvH = 0; self.cvPX = 0; self.cvPY = 0; self.cvHalf = nil
	-- vram→cpu
	self.vcX = 0; self.vcY = 0; self.vcW = 0; self.vcH = 0; self.vcPX = 0; self.vcPY = 0
	-- frame callback for display output
	self.onFrame = nil
	-- differential recorder (set to a function(event, ...) to enable; nil = off)
	self.recordHook = nil
	-- differential vram write log (set by the harness; nil = off): flat { firstIndex, count, ... } spans of words written since the last compare.
	self.vramLog = nil
	-- monotonic "vram may have changed" epoch, bumped on every gp0/gp1 word; front-ends compare it across frames to skip repacking an identical frame.
	self._vramEpoch = 0
	-- modeled command/draw time (duckstation pending_command_ticks), drained by gpu:step; drives gpustat bit 26 (gpu_idle).
	self.pendingCycles = 0
	return self
end

-- record a vram write span for the differential (no-op when logging is off).
local function logVram(gpu, first, count)
	local vlog = gpu.vramLog
	if vlog then vlog[#vlog + 1] = first; vlog[#vlog + 1] = count end
end

-- pooled scratch tables for per-command draw state: every field is rewritten before use and nothing retains them, so one shared set replaces per-command hash-table allocations.
local cmdPool = {}
local polyVerts = { {}, {}, {}, {} }
local triVerts = { nil, nil, nil }
local triTpo = {}
local triTpp = {}
local triUvStep = {}
local triRgbStep = {}
local triUv = {}
local triRgb = {}

-- hoisted drawtriangle step helpers: pure functions of their arguments (the per-call closures they replace were allocated once per triangle).
local function attrStep(detExpr, det)
	return u32(lshift(band(divTrunc(detExpr * 4096, det), 0xFFFFFFFF), 12))
end
local function stepXCount(stepper, steps, count)
	stepper.u = u32(stepper.u + s32(steps.dudx) * count)
	stepper.v = u32(stepper.v + s32(steps.dvdx) * count)
end
local function stepYCount(stepper, steps, count)
	stepper.u = u32(stepper.u + s32(steps.dudy) * count)
	stepper.v = u32(stepper.v + s32(steps.dvdy) * count)
end
local function stepRgbXCount(stepper, steps, count)
	stepper.r = u32(stepper.r + s32(steps.drdx) * count)
	stepper.g = u32(stepper.g + s32(steps.dgdx) * count)
	stepper.b = u32(stepper.b + s32(steps.dbdx) * count)
end
local function stepRgbYCount(stepper, steps, count)
	stepper.r = u32(stepper.r + s32(steps.drdy) * count)
	stepper.g = u32(stepper.g + s32(steps.dgdy) * count)
	stepper.b = u32(stepper.b + s32(steps.dbdy) * count)
end

-- vram access
function GPU:vpoke(x, y, pix)
	x = band(x, 0x3FF); y = band(y, 0x1FF)
	-- full 16-bit write: bit 15 is the stp / mask bit and must be preserved
	-- (clut index data and masked draws rely on it).
	local idx = y * VRAM_W + x + 1
	self.vram[idx] = band(pix, 0xFFFF)
	self._vramEpoch = (self._vramEpoch or 0) + 1
	logVram(self, idx, 1)
end

-- mask-aware pixel write (duckstation shadepixel semantics): check_mask_before_draw skips bit-15 pixels; set_mask_while_drawing ors bit 15 in.
function GPU:maskedWrite(x, y, color)
	local idx = band(y, 0x1FF) * VRAM_W + band(x, 0x3FF) + 1
	if self.maskCheck and band(self.vram[idx] or 0, 0x8000) ~= 0 then return end
	if self.maskSet then color = bor(color, 0x8000) end
	self.vram[idx] = band(color, 0xFFFF)
	self._vramEpoch = (self._vramEpoch or 0) + 1
	logVram(self, idx, 1)
end
function GPU:vpeek(x, y)
	x = band(x, 0x3FF); y = band(y, 0x1FF)
	return self.vram[y * VRAM_W + x + 1] or 0
end

-- texel fetch with clut support
function GPU:texel(u, v)
	if self.texWindowMaskX ~= 0 then
		u = bor(band(u, bnot(self.texWindowMaskX)), band(self.texWindowOffX, self.texWindowMaskX))
	end
	if self.texWindowMaskY ~= 0 then
		v = bor(band(v, bnot(self.texWindowMaskY)), band(self.texWindowOffY, self.texWindowMaskY))
	end

	if self.tpMode == 0 then
		-- 4-bit clut
		local x = self.tpX + math.floor(u / 4)
		local y = self.tpY + v
		local raw = self:vpeek(x, y)
		local nibbleShift = band(u, 0x3) * 4
		local idx = band(rshift(raw, nibbleShift), 0xF)
		local res = self.vram[(self.clutY * VRAM_W + self.clutX + idx) + 1] or 0
		return res
	elseif self.tpMode == 1 then
		-- 8-bit clut
		local x = self.tpX + math.floor(u / 2)
		local y = self.tpY + v
		local raw = self:vpeek(x, y)
		local idx
		if band(u, 1) == 0 then
			idx = band(raw, 0xFF)
		else
			idx = band(rshift(raw, 8), 0xFF)
		end
		local res = self.vram[(self.clutY * VRAM_W + self.clutX + idx) + 1] or 0
		return res
	else
		-- 15-bit direct
		return self:vpeek(self.tpX + u, self.tpY + v)
	end
end

-- drawing state
function GPU:setDrawMode(value)
	value = band(value, 0x1FFF) -- GPUDrawModeReg::MASK = 13 bits
	if not self.setTextureDisableMask then
		value = band(value, bnot(0x800)) -- texture_disable forced false
	end
	self.drawModeReg = value
	-- gpustat bits 0..10 mirror the draw mode; bit 15 = texture disable.
	self.status = bor(band(self.status, bnot(0x7FF)), band(value, 0x7FF))
	self.status = band(self.status, bnot(0x8000))
	self.status = bor(self.status, lshift(band(value, 0x800) ~= 0 and 1 or 0, 15))
	invalidateStatus(self)
	-- legacy mirror fields (checkpoint format + probes read these).
	self.tpX = getTexturePageBaseX(value)
	self.tpY = getTexturePageBaseY(value)
	self.tpMode = band(rshift(value, 7), 3)
	self.rawTP = band(value, 0x1FF)
	self.semiTrans = band(rshift(value, 5), 3)
	self.dither = band(rshift(value, 9), 1) == 1
	self.drawToDisplay = band(rshift(value, 10), 1) == 1
	self.texDisable = band(rshift(value, 11), 1) == 1
end

function GPU:setTexturePalette(value)
	self.texturePaletteReg = band(value, 0x7FFF)
	self.clutX = band(value, 0x3F) * 16
	self.clutY = band(rshift(value, 6), 0x1FF)
end

-- clut caching (duckstation updateclutifneeded): reloads vram clut rows; not invalidated on vram writes -- only on reset and gp0(01h) clear-cache.
function GPU:updateCLUTIfNeeded(texmode, clutBits)
	if texmode >= 2 then return end -- Direct16Bit and above
	local needs8bit = texmode == 1
	if clutBits ~= self.currentClutRegBits or (needs8bit and not self.currentClutIs8bit) then
		self.currentClutRegBits = clutBits
		self.currentClutIs8bit = needs8bit
		-- clut reload costs gpu time (duckstation updateclutifneeded).
		self:addCommandTicks(needs8bit and 256 or 16)
		local yBase = band(rshift(clutBits, 6), 0x1FF)
		local xBase = band(clutBits, 0x3F) * 16
		local row = yBase * VRAM_W
		local vram = self.vram
		if not needs8bit then
			for i = 0, 15 do
				self.clut[i + 1] = vram[row + xBase + i + 1] or 0
			end
		else
			if xBase + 256 <= VRAM_W then
				for i = 0, 255 do
					self.clut[i + 1] = vram[row + xBase + i + 1] or 0
				end
			else
				local endN = VRAM_W - xBase
				for i = 0, endN - 1 do
					self.clut[i + 1] = vram[row + xBase + i + 1] or 0
				end
				for i = endN, 255 do
					self.clut[i + 1] = vram[row + (i - endN) + 1] or 0
				end
			end
		end
	end
end

function GPU:invalidateCLUT()
	self.currentClutRegBits = 0xFFFF
	self.currentClutIs8bit = false
end

-- filldrawcommand shared state (gpu.cpp filldrawcommand).
function GPU:fillDrawCommand(rc, isLine)
	local cmd = cmdPool
	cmd.checkMaskBeforeDraw = self.maskCheck
	cmd.setMaskWhileDrawing = self.maskSet
	local textureEnable = (not isLine) and (band(rc, 0x4000000) ~= 0) and self.textureEnableMask
	cmd.textureEnable = textureEnable
	cmd.rawTextureEnable = textureEnable and (band(rc, 0x1000000) ~= 0)
	cmd.transparencyEnable = band(rc, 0x2000000) ~= 0
	cmd.shadingEnable = band(rc, 0x10000000) ~= 0
	cmd.quadPolygon = band(rc, 0x8000000) ~= 0
	cmd.ditherEnable = band(self.drawModeReg, 0x200) ~= 0
	cmd.drawModeBits = self.drawModeReg
	cmd.paletteBits = self.texturePaletteReg
	cmd.windowAndX = band(bnot(self.texWindowMaskX or 0), 0xFF)
	cmd.windowAndY = band(bnot(self.texWindowMaskY or 0), 0xFF)
	cmd.windowOrX = band(self.texWindowOffX or 0, band(self.texWindowMaskX or 0, 0xFF))
	cmd.windowOrY = band(self.texWindowOffY or 0, band(self.texWindowMaskY or 0, 0xFF))
	return cmd
end

-- software rasterizer
function GPU:shadePixel(cmd, x, y, r, g, b, u, v)
	-- keep the framebuffer table and dither lookup local. this is called once
	-- for every covered pixel.
	local textureEnable = cmd.textureEnable
	local vram = self.vram
	local color
	if textureEnable then
		-- texture window
		u = bor(band(u, cmd.windowAndX), cmd.windowOrX)
		v = bor(band(v, cmd.windowAndY), cmd.windowOrY)
		local drawMode = cmd.drawModeBits
		local texBaseX = getTexturePageBaseX(drawMode)
		local texBaseY = getTexturePageBaseY(drawMode)
		local texMode = band(rshift(drawMode, 7), 3)
		local textureColor
		-- getpixel inlined (module helper is just this index expression)
		if texMode == 0 then -- Palette4Bit
			local paletteValue = vram[band(texBaseY + v, 0x1FF) * VRAM_W + band(texBaseX + rshift(u, 2), 0x3FF) + 1] or 0
			local paletteIndex = band(rshift(paletteValue, band(u, 3) * 4), 0xF)
			textureColor = self.clut[paletteIndex + 1]
		elseif texMode == 1 then -- Palette8Bit
			local paletteValue = vram[band(texBaseY + v, 0x1FF) * VRAM_W + band(texBaseX + rshift(u, 1), 0x3FF) + 1] or 0
			local paletteIndex = band(rshift(paletteValue, band(u, 1) * 8), 0xFF)
			textureColor = self.clut[paletteIndex + 1]
		else -- Direct15Bit
			textureColor = vram[band(texBaseY + v, 0x1FF) * VRAM_W + band(texBaseX + u, 0x3FF) + 1] or 0
		end
		if textureColor == 0 then return end
		if not cmd.rawTextureEnable then
			-- modulate8bit (modulation_crop = false)
			local dithering = cmd.ditherEnable
			local dithBase = dithering and (band(y, 3) * 2048 + band(x, 3) * 512) or 5632
			color = bor(
				ditherLut[dithBase + rshift(band(textureColor, 0x1F) * r, 4) + 1],
				lshift(ditherLut[dithBase + rshift(band(rshift(textureColor, 5), 0x1F) * g, 4) + 1], 5),
				lshift(ditherLut[dithBase + rshift(band(rshift(textureColor, 10), 0x1F) * b, 4) + 1], 10),
				band(textureColor, 0x8000))
		else
			color = textureColor -- NoModulation
		end
	else
		local dithering = cmd.ditherEnable
		local dithBase = dithering and (band(y, 3) * 2048 + band(x, 3) * 512) or 5632
		color = bor(
			ditherLut[dithBase + r + 1],
			lshift(ditherLut[dithBase + g + 1], 5),
			lshift(ditherLut[dithBase + b + 1], 10))
		if cmd.transparencyEnable then
			color = bor(color, 0x8000)
		end
	end

	local maskAnd = cmd.checkMaskBeforeDraw and 0x8000 or 0
	local transparencyEnable = cmd.transparencyEnable
	local maskOr = cmd.setMaskWhileDrawing and 0x8000 or 0
	if maskAnd ~= 0 or transparencyEnable then
		-- read the destination pixel once; the mask check and blending both use it.
		local bg = vram[band(y, 0x1FF) * VRAM_W + band(x, 0x3FF) + 1]
		if maskAnd ~= 0 and band(bg, maskAnd) ~= 0 then return end
		if transparencyEnable then
			if band(color, 0x8000) ~= 0 or not textureEnable then
				local bgBits = bg
				local fgBits = band(color, 0xFFFFFFFF)
				local abr = band(rshift(cmd.drawModeBits, 5), 3)
				if abr == 0 then
					-- halfbackgroundplushalfforeground
					bgBits = bor(bgBits, 0x8000)
					color = band(math.floor((band(fgBits + bgBits, 0xFFFFFFFF) - band(bxor(fgBits, bgBits), 0x0421)) / 2), 0xFFFF)
				elseif abr == 1 then
					-- backgroundplusforeground (blargg)
					bgBits = band(bgBits, bnot(0x8000))
					local sum = band(fgBits + bgBits, 0xFFFFFFFF)
					local carry = band(band(sum - band(bxor(fgBits, bgBits), 0x8421), 0xFFFFFFFF), 0x8420)
					color = band(bor(band(band(sum - carry, 0xFFFFFFFF), 0xFFFF), band(carry - rshift(carry, 5), 0xFFFFFFFF)), 0xFFFF)
				elseif abr == 2 then
					-- backgroundminusforeground
					bgBits = bor(bgBits, 0x8000)
					fgBits = band(fgBits, bnot(0x8000))
					local diff = band(bgBits - fgBits + 0x108420, 0xFFFFFFFF)
					local borrow = band(band(diff - band(bxor(bgBits, fgBits), 0x108420), 0xFFFFFFFF), 0x108420)
					color = band(band(band(diff - borrow, 0xFFFFFFFF), band(borrow - rshift(borrow, 5), 0xFFFFFFFF)), 0xFFFF)
				else
					-- backgroundplusquarterforeground
					bgBits = band(bgBits, bnot(0x8000))
					fgBits = bor(band(rshift(fgBits, 2), 0x1CE7), 0x8000)
					local sum = band(fgBits + bgBits, 0xFFFFFFFF)
					local carry = band(band(sum - band(bxor(fgBits, bgBits), 0x8421), 0xFFFFFFFF), 0x8420)
					color = band(bor(band(band(sum - carry, 0xFFFFFFFF), 0xFFFF), band(carry - rshift(carry, 5), 0xFFFFFFFF)), 0xFFFF)
				end
				if not textureEnable then
					color = band(color, bnot(0x8000))
				end
			end
		end
	end

	local idx = band(y, 0x1FF) * VRAM_W + band(x, 0x3FF) + 1
	vram[idx] = band(bor(color, maskOr), 0xFFFF)
	local vlog = self.vramLog
	if vlog then vlog[#vlog + 1] = idx; vlog[#vlog + 1] = 1 end
end


-- drawrectangle
function GPU:drawRectangle(cmd)
	-- shadepixel hoisted out of the per-pixel metatable __index dispatch.
	local shadePixel = self.shadePixel
	local originX = cmd.x
	local originY = cmd.y
	local r = band(cmd.color, 0xFF)
	local g = band(rshift(cmd.color, 8), 0xFF)
	local b = band(rshift(cmd.color, 16), 0xFF)
	local originU = t8(cmd.texcoord)
	local originV = t8(rshift(cmd.texcoord, 8))
	local left = self.drawLeft
	local right = self.drawRight
	local top = self.drawTop
	local bottom = self.drawBottom
	-- flat opaque rects never dither and have no per-pixel variation, so the whole fill is one constant word; compute once, write runs.
	if not cmd.textureEnable and not cmd.transparencyEnable and not cmd.checkMaskBeforeDraw and not cmd.ditherEnable then
		local lut = ditherLut
		local vram = self.vram
		local vlog = self.vramLog
		local color = t16(bor(
			lut[5632 + r + 1],
			lshift(lut[5632 + g + 1], 5),
			lshift(lut[5632 + b + 1], 10)))
		if cmd.setMaskWhileDrawing then
			color = bor(color, 0x8000)
		end
		-- clip y first (a row that misses the drawing area is skipped whole),
		-- then fill the clipped x run of that row with the constant word.
		local yEnd = originY + cmd.height - 1
		local yStart = originY
		if yStart < top then yStart = top end
		if yEnd > bottom then yEnd = bottom end
		for y = yStart, yEnd do
			local xStart = originX
			local xEnd = originX + cmd.width - 1
			if xStart < left then xStart = left end
			if xEnd > right then xEnd = right end
			if xEnd >= xStart then
				-- y/x are inside the drawing area (0..511 / 0..1023), so the vram
				-- index is contiguous: band is identity and the run is one span.
				local first = y * VRAM_W + xStart + 1
				local count = xEnd - xStart + 1
				for idx = first, first + count - 1 do
					vram[idx] = color
				end
				if vlog then vlog[#vlog + 1] = first; vlog[#vlog + 1] = count end
			end
		end
		return
	end

	-- textured rects never dither, so modulate uses the fixed (2,3) identity lut cell; hoist texpage/tex-window decode and inline the shadePixel pipeline for the common case.
	if cmd.textureEnable and not cmd.transparencyEnable and not cmd.checkMaskBeforeDraw and not cmd.ditherEnable then
		local vram = self.vram
		local clut = self.clut
		local vlog = self.vramLog
		local lut = ditherLut
		local windowAndX = cmd.windowAndX
		local windowOrX = cmd.windowOrX
		local windowAndY = cmd.windowAndY
		local windowOrY = cmd.windowOrY
		local drawMode = cmd.drawModeBits
		local texBaseX = getTexturePageBaseX(drawMode)
		local texBaseY = getTexturePageBaseY(drawMode)
		local texMode = band(rshift(drawMode, 7), 3)
		local rawTex = cmd.rawTextureEnable
		local maskOr = cmd.setMaskWhileDrawing and 0x8000 or 0
		-- color is constant across the rect, so memoize texel -> final color in a per-rect cache (entries stored +1 so black != not-cached).
		local colorCache = {}
		-- clip y first (a row that misses the drawing area is skipped whole),
		-- then fill the clipped x run of that row (mirrors the flat path).
		local yEnd = originY + cmd.height - 1
		local yStart = originY
		if yStart < top then yStart = top end
		if yEnd > bottom then yEnd = bottom end
		for y = yStart, yEnd do
			local texV = band(originV + (y - originY), 0xFF)
			texV = bor(band(texV, windowAndY), windowOrY)
			local vRow = band(texBaseY + texV, 0x1FF) * VRAM_W
			local xStart2 = originX
			local xEnd2 = originX + cmd.width - 1
			if xStart2 < left then xStart2 = left end
			if xEnd2 > right then xEnd2 = right end
			if xEnd2 >= xStart2 then
				local yMasked = band(y, 0x1FF) * VRAM_W
				for x = xStart2, xEnd2 do
					local texU = band(originU + (x - originX), 0xFF)
					texU = bor(band(texU, windowAndX), windowOrX)
					local textureColor
					if texMode == 0 then
						local paletteValue = vram[vRow + band(texBaseX + rshift(texU, 2), 0x3FF) + 1] or 0
						textureColor = clut[band(rshift(paletteValue, band(texU, 3) * 4), 0xF) + 1]
					elseif texMode == 1 then
						local paletteValue = vram[vRow + band(texBaseX + rshift(texU, 1), 0x3FF) + 1] or 0
						textureColor = clut[band(rshift(paletteValue, band(texU, 1) * 8), 0xFF) + 1]
					else
						textureColor = vram[vRow + band(texBaseX + texU, 0x3FF) + 1] or 0
					end
					if textureColor ~= 0 then
						local cached = colorCache[textureColor]
						local color
						if cached then
							color = cached - 1
						else
							if not rawTex then
								color = bor(
									lut[5632 + rshift(band(textureColor, 0x1F) * r, 4) + 1],
									lshift(lut[5632 + rshift(band(rshift(textureColor, 5), 0x1F) * g, 4) + 1], 5),
									lshift(lut[5632 + rshift(band(rshift(textureColor, 10), 0x1F) * b, 4) + 1], 10),
									band(textureColor, 0x8000))
							else
								color = textureColor
							end
							colorCache[textureColor] = color + 1
						end
						-- x is clipped to the drawing area (0..1023), so the band
						-- is identity and the vram index is contiguous.
						local idx = yMasked + x + 1
						vram[idx] = bor(color, maskOr)
						if vlog then vlog[#vlog + 1] = idx; vlog[#vlog + 1] = 1 end
					end
				end
			end
		end
		return
	end
	for offsetY = 0, cmd.height - 1 do
		local y = originY + offsetY
		if y >= top and y <= bottom then
			local texY = t8(originV + offsetY)
			for offsetX = 0, cmd.width - 1 do
				local x = originX + offsetX
				if x >= left and x <= right then
					local texX = t8(originU + offsetX)
					shadePixel(self, cmd, x, y, r, g, b, texX, texY)
				end
			end
		end
	end
end

-- drawline (duckstation gpu_sw_rasterizer.inl drawline)
function GPU:drawLine(cmd, p0, p1)
	local makefpXy = function(x) return x * 4294967296 + 2147483648 end
	local unfpXy = function(x)
		return sx11(s32(math.floor(x / 4294967296)))
	end
	local divXy = function(delta, dk)
		local num = delta * 4294967296
		if delta < 0 then num = num - (dk - 1)
		elseif delta > 0 then num = num + (dk - 1) end
		return divTrunc(num, dk)
	end
	local makefpRgb = function(c) return c * 4096 + 2048 end
	local unfpRgb = function(c) return t8(math.floor(c / 4096)) end
	local divRgb = function(c1, c0, dk)
		return divTrunc((s32(c1) - s32(c0)) * 4096, dk)
	end

	local iDx = math.abs(p1.x - p0.x)
	local iDy = math.abs(p1.y - p0.y)
	local k = math.max(iDx, iDy)
	if iDx >= MAX_PRIMITIVE_WIDTH or iDy >= MAX_PRIMITIVE_HEIGHT then return end

	if p0.x >= p1.x and k > 0 then
		p0, p1 = p1, p0
	end

	local dxdk, dydk = 0, 0
	local drdk, dgdk, dbdk = 0, 0, 0
	if k ~= 0 then
		dxdk = divXy(p1.x - p0.x, k)
		dydk = divXy(p1.y - p0.y, k)
		if cmd.shadingEnable then
			drdk = divRgb(p1.r, p0.r, k)
			dgdk = divRgb(p1.g, p0.g, k)
			dbdk = divRgb(p1.b, p0.b, k)
		end
	end

	local curx = makefpXy(p0.x) - 1024
	local cury = makefpXy(p0.y) - (dydk < 0 and 1024 or 0)
	local curr, curg, curb = 0, 0, 0
	if cmd.shadingEnable then
		curr = makefpRgb(p0.r)
		curg = makefpRgb(p0.g)
		curb = makefpRgb(p0.b)
	end

	local left = self.drawLeft
	local right = self.drawRight
	local top = self.drawTop
	local bottom = self.drawBottom
	-- shadepixel hoisted out of the per-pixel metatable __index dispatch.
	local shadePixel = self.shadePixel
	for _ = 0, k do
		local x = unfpXy(curx)
		local y = unfpXy(cury)
		if x >= left and x <= right and y >= top and y <= bottom then
			local r = cmd.shadingEnable and unfpRgb(curr) or p0.r
			local g = cmd.shadingEnable and unfpRgb(curg) or p0.g
			local b = cmd.shadingEnable and unfpRgb(curb) or p0.b
			shadePixel(self, cmd, x, band(y, 0x1FF), r, g, b, 0, 0)
		end
		curx += dxdk
		cury += dydk
		if cmd.shadingEnable then
			curr += drdk
			curg += dgdk
			curb += dbdk
		end
	end
end

-- drawspan (scalar): uv/rgb arrive as plain fixed-point scalars -- no per-call table copies.
function GPU:drawSpan(cmd, y, xStart, xBound, uvu, uvv, uvstep, rr, gg, bb, rgbstep)
	local width = xBound - xStart
	local currentX = truncVertexPos(xStart)

	if currentX < self.drawLeft then
		local delta = self.drawLeft - currentX
		xStart += delta
		currentX += delta
		width -= delta
	end
	if (currentX + width) > (self.drawRight + 1) then
		width = self.drawRight + 1 - currentX
	end
	if width <= 0 then return end

	-- flat opaque spans are common enough to deserve their own path. dithering
	-- repeats every four pixels, so calculate those four colors once.
	if not cmd.textureEnable and not cmd.shadingEnable and not cmd.transparencyEnable and not cmd.checkMaskBeforeDraw then
		local lut = ditherLut
		local dithY = cmd.ditherEnable and (band(y, 3) * 2048) or 5632
		local rv = band(rshift(rr, 24), 0xFF)
		local gv = band(rshift(gg, 24), 0xFF)
		local bv = band(rshift(bb, 24), 0xFF)
		-- dither cell step: 512 per x%4 phase when dithering; 0 when off (the fixed (2,3) cell must not walk into neighbors).
		local step = cmd.ditherEnable and 512 or 0
		local c0 = band(bor(lut[dithY + rv + 1], lshift(lut[dithY + gv + 1], 5), lshift(lut[dithY + bv + 1], 10)), 0xFFFF)
		local c1 = band(bor(lut[dithY + rv + step + 1], lshift(lut[dithY + gv + step + 1], 5), lshift(lut[dithY + bv + step + 1], 10)), 0xFFFF)
		local c2 = band(bor(lut[dithY + rv + step * 2 + 1], lshift(lut[dithY + gv + step * 2 + 1], 5), lshift(lut[dithY + bv + step * 2 + 1], 10)), 0xFFFF)
		local c3 = band(bor(lut[dithY + rv + step * 3 + 1], lshift(lut[dithY + gv + step * 3 + 1], 5), lshift(lut[dithY + bv + step * 3 + 1], 10)), 0xFFFF)
		if cmd.setMaskWhileDrawing then
			c0 = bor(c0, 0x8000)
			c1 = bor(c1, 0x8000)
			c2 = bor(c2, 0x8000)
			c3 = bor(c3, 0x8000)
		end
		local vram = self.vram
		local vlog = self.vramLog
		local x = currentX
		-- both terms are mod-4 aligned, so the target index is band(y,0x1ff)*vram_w + band(x,0x3ff) + 1 with consecutive pixels consecutive.
		local addr = band(y, 0x1FF) * VRAM_W + band(x, 0x3FF) + 1
		local stopX = x + width
		local res = band(x, 3)
		-- lead-in pixels to the 4-pixel dither alignment
		local leadStart = addr
		while res ~= 0 and x < stopX do
			if res == 1 then vram[addr] = c1
			elseif res == 2 then vram[addr] = c2
			else vram[addr] = c3 end
			addr += 1
			x += 1
			res = band(x, 3)
		end
		if vlog and addr > leadStart then vlog[#vlog + 1] = leadStart; vlog[#vlog + 1] = addr - leadStart end
		-- 4-aligned body: the dither cycle repeats, so c[k] maps to x%4 == k
		local bodyStart = addr
		while x + 4 <= stopX do
			vram[addr] = c0
			vram[addr + 1] = c1
			vram[addr + 2] = c2
			vram[addr + 3] = c3
			addr += 4
			x += 4
		end
		if vlog and addr > bodyStart then vlog[#vlog + 1] = bodyStart; vlog[#vlog + 1] = addr - bodyStart end
		-- tail pixels after the last aligned quad
		local tailStart = addr
		while x < stopX do
			local r4 = band(x, 3)
			if r4 == 0 then vram[addr] = c0
			elseif r4 == 1 then vram[addr] = c1
			elseif r4 == 2 then vram[addr] = c2
			else vram[addr] = c3 end
			addr += 1
			x += 1
		end
		if vlog and addr > tailStart then vlog[#vlog + 1] = tailStart; vlog[#vlog + 1] = addr - tailStart end
		return
	end

	local textureEnable = cmd.textureEnable
	local shadingEnable = cmd.shadingEnable
	-- per-pixel stepping in locals (the u32/t8 function calls are inlined as
	-- band/rshift): no table copies, no per-pixel table writes.
	local du, dv = 0, 0
	local drr, dgg, dbb = 0, 0, 0
	if textureEnable then
		local sdu = band(uvstep.dudx, 0xFFFFFFFF)
		if sdu >= 0x80000000 then sdu = sdu - 0x100000000 end
		local sdv = band(uvstep.dvdx, 0xFFFFFFFF)
		if sdv >= 0x80000000 then sdv = sdv - 0x100000000 end
		uvu = band(uvu + sdu * xStart, 0xFFFFFFFF)
		uvv = band(uvv + sdv * xStart, 0xFFFFFFFF)
		du = uvstep.dudx
		dv = uvstep.dvdx
	end
	if shadingEnable then
		local sdrr = band(rgbstep.drdx, 0xFFFFFFFF)
		if sdrr >= 0x80000000 then sdrr = sdrr - 0x100000000 end
		local sdgg = band(rgbstep.dgdx, 0xFFFFFFFF)
		if sdgg >= 0x80000000 then sdgg = sdgg - 0x100000000 end
		local sdbb = band(rgbstep.dbdx, 0xFFFFFFFF)
		if sdbb >= 0x80000000 then sdbb = sdbb - 0x100000000 end
		rr = band(rr + sdrr * xStart, 0xFFFFFFFF)
		gg = band(gg + sdgg * xStart, 0xFFFFFFFF)
		bb = band(bb + sdbb * xStart, 0xFFFFFFFF)
		drr = rgbstep.drdx
		dgg = rgbstep.dgdx
		dbb = rgbstep.dbdx
	end

	-- textured fast path (no blend, no mask check): tex-window/texpage/texmode are loop-invariant; only the dither phase varies per pixel.
	if textureEnable and not cmd.transparencyEnable and not cmd.checkMaskBeforeDraw then
		local vram = self.vram
		local clut = self.clut
		local vlog = self.vramLog
		local lut = ditherLut
		local windowAndX = cmd.windowAndX
		local windowOrX = cmd.windowOrX
		local windowAndY = cmd.windowAndY
		local windowOrY = cmd.windowOrY
		local drawMode = cmd.drawModeBits
		local texBaseX = getTexturePageBaseX(drawMode)
		local texBaseY = getTexturePageBaseY(drawMode)
		local texMode = band(rshift(drawMode, 7), 3)
		local rawTex = cmd.rawTextureEnable
		local maskOr = cmd.setMaskWhileDrawing and 0x8000 or 0
		local dithering = cmd.ditherEnable
		local dithY = band(y, 3) * 2048
		local yMasked = band(y, 0x1FF) * VRAM_W
		-- spans are clipped to the drawing area, so the vram index is contiguous and the dither phase steps in a running base.
		local dithBase = dithering and (dithY + band(currentX, 3) * 512) or 5632
		local dithStep = dithering and 512 or 0
		local dithWrap = dithering and (dithY + 2048) or math.huge
		local x = currentX
		repeat
			local u = rshift(uvu, 24)
			local v = rshift(uvv, 24)
			u = bor(band(u, windowAndX), windowOrX)
			v = bor(band(v, windowAndY), windowOrY)
			local textureColor
			if texMode == 0 then
				local paletteValue = vram[band(texBaseY + v, 0x1FF) * VRAM_W + band(texBaseX + rshift(u, 2), 0x3FF) + 1] or 0
				textureColor = clut[band(rshift(paletteValue, band(u, 3) * 4), 0xF) + 1]
			elseif texMode == 1 then
				local paletteValue = vram[band(texBaseY + v, 0x1FF) * VRAM_W + band(texBaseX + rshift(u, 1), 0x3FF) + 1] or 0
				textureColor = clut[band(rshift(paletteValue, band(u, 1) * 8), 0xFF) + 1]
			else
				textureColor = vram[band(texBaseY + v, 0x1FF) * VRAM_W + band(texBaseX + u, 0x3FF) + 1] or 0
			end
			if textureColor ~= 0 then
				local color
				if not rawTex then
					color = bor(
						lut[dithBase + rshift(band(textureColor, 0x1F) * rshift(rr, 24), 4) + 1],
						lshift(lut[dithBase + rshift(band(rshift(textureColor, 5), 0x1F) * rshift(gg, 24), 4) + 1], 5),
						lshift(lut[dithBase + rshift(band(rshift(textureColor, 10), 0x1F) * rshift(bb, 24), 4) + 1], 10),
						band(textureColor, 0x8000))
				else
					color = textureColor
				end
				local idx = yMasked + x + 1
				vram[idx] = bor(color, maskOr)
				if vlog then vlog[#vlog + 1] = idx; vlog[#vlog + 1] = 1 end
			end
			x += 1
			dithBase += dithStep
			if dithBase >= dithWrap then dithBase = dithY end
			uvu = band(uvu + du, 0xFFFFFFFF)
			uvv = band(uvv + dv, 0xFFFFFFFF)
			if shadingEnable then
				rr = band(rr + drr, 0xFFFFFFFF)
				gg = band(gg + dgg, 0xFFFFFFFF)
				bb = band(bb + dbb, 0xFFFFFFFF)
			end
			width -= 1
		until width <= 0
		return
	end

	-- untextured shaded fast path: per-pixel color stepping, no blend/mask.
	if not textureEnable and not cmd.transparencyEnable and not cmd.checkMaskBeforeDraw then
		local vram = self.vram
		local vlog = self.vramLog
		local lut = ditherLut
		local maskOr = cmd.setMaskWhileDrawing and 0x8000 or 0
		local dithering = cmd.ditherEnable
		local dithY = band(y, 3) * 2048
		local yMasked = band(y, 0x1FF) * VRAM_W
		-- spans are clipped to the drawing area, so the vram index is contiguous and the dither phase steps in a running base.
		local dithBase = dithering and (dithY + band(currentX, 3) * 512) or 5632
		local dithStep = dithering and 512 or 0
		local dithWrap = dithering and (dithY + 2048) or math.huge
		local x = currentX
		repeat
			local color = bor(
				lut[dithBase + rshift(rr, 24) + 1],
				lshift(lut[dithBase + rshift(gg, 24) + 1], 5),
				lshift(lut[dithBase + rshift(bb, 24) + 1], 10))
			local idx = yMasked + x + 1
			vram[idx] = bor(color, maskOr)
			if vlog then vlog[#vlog + 1] = idx; vlog[#vlog + 1] = 1 end
			x += 1
			dithBase += dithStep
			if dithBase >= dithWrap then dithBase = dithY end
			rr = band(rr + drr, 0xFFFFFFFF)
			gg = band(gg + dgg, 0xFFFFFFFF)
			bb = band(bb + dbb, 0xFFFFFFFF)
			width -= 1
		until width <= 0
		return
	end

	-- textured semi-transparent fast path (no mask check): same hoists as the opaque path with the blargg blend inlined per pixel; abr is loop-invariant.
	if textureEnable and cmd.transparencyEnable and not cmd.checkMaskBeforeDraw then
		local vram = self.vram
		local clut = self.clut
		local vlog = self.vramLog
		local lut = ditherLut
		local windowAndX = cmd.windowAndX
		local windowOrX = cmd.windowOrX
		local windowAndY = cmd.windowAndY
		local windowOrY = cmd.windowOrY
		local drawMode = cmd.drawModeBits
		local texBaseX = getTexturePageBaseX(drawMode)
		local texBaseY = getTexturePageBaseY(drawMode)
		local texMode = band(rshift(drawMode, 7), 3)
		local rawTex = cmd.rawTextureEnable
		local abr = band(rshift(drawMode, 5), 3)
		local maskOr = cmd.setMaskWhileDrawing and 0x8000 or 0
		local dithering = cmd.ditherEnable
		local dithY = band(y, 3) * 2048
		local yMasked = band(y, 0x1FF) * VRAM_W
		-- spans are clipped to the drawing area, so the vram index is contiguous and the dither phase steps in a running base.
		local dithBase = dithering and (dithY + band(currentX, 3) * 512) or 5632
		local dithStep = dithering and 512 or 0
		local dithWrap = dithering and (dithY + 2048) or math.huge
		local x = currentX
		repeat
			local u = rshift(uvu, 24)
			local v = rshift(uvv, 24)
			u = bor(band(u, windowAndX), windowOrX)
			v = bor(band(v, windowAndY), windowOrY)
			local textureColor
			if texMode == 0 then
				local paletteValue = vram[band(texBaseY + v, 0x1FF) * VRAM_W + band(texBaseX + rshift(u, 2), 0x3FF) + 1] or 0
				textureColor = clut[band(rshift(paletteValue, band(u, 3) * 4), 0xF) + 1]
			elseif texMode == 1 then
				local paletteValue = vram[band(texBaseY + v, 0x1FF) * VRAM_W + band(texBaseX + rshift(u, 1), 0x3FF) + 1] or 0
				textureColor = clut[band(rshift(paletteValue, band(u, 1) * 8), 0xFF) + 1]
			else
				textureColor = vram[band(texBaseY + v, 0x1FF) * VRAM_W + band(texBaseX + u, 0x3FF) + 1] or 0
			end
			if textureColor ~= 0 then
				local color
				if not rawTex then
					color = bor(
						lut[dithBase + rshift(band(textureColor, 0x1F) * rshift(rr, 24), 4) + 1],
						lshift(lut[dithBase + rshift(band(rshift(textureColor, 5), 0x1F) * rshift(gg, 24), 4) + 1], 5),
						lshift(lut[dithBase + rshift(band(rshift(textureColor, 10), 0x1F) * rshift(bb, 24), 4) + 1], 10),
						band(textureColor, 0x8000))
				else
					color = textureColor
				end
				local idx = yMasked + x + 1
				local bg = vram[idx]
				if band(color, 0x8000) ~= 0 then
					local bgBits = bg
					local fgBits = band(color, 0xFFFFFFFF)
					if abr == 0 then
						-- halfbackgroundplushalfforeground
						bgBits = bor(bgBits, 0x8000)
						color = band(math.floor((band(fgBits + bgBits, 0xFFFFFFFF) - band(bxor(fgBits, bgBits), 0x0421)) / 2), 0xFFFF)
					elseif abr == 1 then
						-- backgroundplusforeground (blargg)
						bgBits = band(bgBits, bnot(0x8000))
						local sum = band(fgBits + bgBits, 0xFFFFFFFF)
						local carry = band(band(sum - band(bxor(fgBits, bgBits), 0x8421), 0xFFFFFFFF), 0x8420)
						color = band(bor(band(band(sum - carry, 0xFFFFFFFF), 0xFFFF), band(carry - rshift(carry, 5), 0xFFFFFFFF)), 0xFFFF)
					elseif abr == 2 then
						-- backgroundminusforeground
						bgBits = bor(bgBits, 0x8000)
						fgBits = band(fgBits, bnot(0x8000))
						local diff = band(bgBits - fgBits + 0x108420, 0xFFFFFFFF)
						local borrow = band(band(diff - band(bxor(bgBits, fgBits), 0x108420), 0xFFFFFFFF), 0x108420)
						color = band(band(band(diff - borrow, 0xFFFFFFFF), band(borrow - rshift(borrow, 5), 0xFFFFFFFF)), 0xFFFF)
					else
						-- backgroundplusquarterforeground
						bgBits = band(bgBits, bnot(0x8000))
						fgBits = bor(band(rshift(fgBits, 2), 0x1CE7), 0x8000)
						local sum = band(fgBits + bgBits, 0xFFFFFFFF)
						local carry = band(band(sum - band(bxor(fgBits, bgBits), 0x8421), 0xFFFFFFFF), 0x8420)
						color = band(bor(band(band(sum - carry, 0xFFFFFFFF), 0xFFFF), band(carry - rshift(carry, 5), 0xFFFFFFFF)), 0xFFFF)
					end
				end
				vram[idx] = bor(color, maskOr)
				if vlog then vlog[#vlog + 1] = idx; vlog[#vlog + 1] = 1 end
			end
			x += 1
			dithBase += dithStep
			if dithBase >= dithWrap then dithBase = dithY end
			uvu = band(uvu + du, 0xFFFFFFFF)
			uvv = band(uvv + dv, 0xFFFFFFFF)
			if shadingEnable then
				rr = band(rr + drr, 0xFFFFFFFF)
				gg = band(gg + dgg, 0xFFFFFFFF)
				bb = band(bb + dbb, 0xFFFFFFFF)
			end
			width -= 1
		until width <= 0
		return
	end

	-- flat semi-transparent fast path (no mask check): untextured transparent primitives always blend; blargg math inlined with abr hoisted.
	if not textureEnable and cmd.transparencyEnable and not cmd.checkMaskBeforeDraw then
		local vram = self.vram
		local vlog = self.vramLog
		local lut = ditherLut
		local abr = band(rshift(cmd.drawModeBits, 5), 3)
		local maskOr = cmd.setMaskWhileDrawing and 0x8000 or 0
		local dithering = cmd.ditherEnable
		local dithY = band(y, 3) * 2048
		local yMasked = band(y, 0x1FF) * VRAM_W
		-- spans are clipped to the drawing area, so the vram index is contiguous and the dither phase steps in a running base.
		local dithBase = dithering and (dithY + band(currentX, 3) * 512) or 5632
		local dithStep = dithering and 512 or 0
		local dithWrap = dithering and (dithY + 2048) or math.huge
		local x = currentX
		repeat
			local color = bor(
				lut[dithBase + rshift(rr, 24) + 1],
				lshift(lut[dithBase + rshift(gg, 24) + 1], 5),
				lshift(lut[dithBase + rshift(bb, 24) + 1], 10),
				0x8000)
			local idx = yMasked + x + 1
			local bg = vram[idx]
			local bgBits = bg
			local fgBits = band(color, 0xFFFFFFFF)
			if abr == 0 then
				-- halfbackgroundplushalfforeground
				bgBits = bor(bgBits, 0x8000)
				color = band(math.floor((band(fgBits + bgBits, 0xFFFFFFFF) - band(bxor(fgBits, bgBits), 0x0421)) / 2), 0xFFFF)
			elseif abr == 1 then
				-- backgroundplusforeground (blargg)
				bgBits = band(bgBits, bnot(0x8000))
				local sum = band(fgBits + bgBits, 0xFFFFFFFF)
				local carry = band(band(sum - band(bxor(fgBits, bgBits), 0x8421), 0xFFFFFFFF), 0x8420)
				color = band(bor(band(band(sum - carry, 0xFFFFFFFF), 0xFFFF), band(carry - rshift(carry, 5), 0xFFFFFFFF)), 0xFFFF)
			elseif abr == 2 then
				-- backgroundminusforeground
				bgBits = bor(bgBits, 0x8000)
				fgBits = band(fgBits, bnot(0x8000))
				local diff = band(bgBits - fgBits + 0x108420, 0xFFFFFFFF)
				local borrow = band(band(diff - band(bxor(bgBits, fgBits), 0x108420), 0xFFFFFFFF), 0x108420)
				color = band(band(band(diff - borrow, 0xFFFFFFFF), band(borrow - rshift(borrow, 5), 0xFFFFFFFF)), 0xFFFF)
			else
				-- backgroundplusquarterforeground
				bgBits = band(bgBits, bnot(0x8000))
				fgBits = bor(band(rshift(fgBits, 2), 0x1CE7), 0x8000)
				local sum = band(fgBits + bgBits, 0xFFFFFFFF)
				local carry = band(band(sum - band(bxor(fgBits, bgBits), 0x8421), 0xFFFFFFFF), 0x8420)
				color = band(bor(band(band(sum - carry, 0xFFFFFFFF), 0xFFFF), band(carry - rshift(carry, 5), 0xFFFFFFFF)), 0xFFFF)
			end
			-- untextured semi results are stored with bit 15 clear (matches the
			-- reference shadePixel: the blend clears the flag after mixing).
			vram[idx] = bor(band(color, bnot(0x8000)), maskOr)
			if vlog then vlog[#vlog + 1] = idx; vlog[#vlog + 1] = 1 end
			x += 1
			dithBase += dithStep
			if dithBase >= dithWrap then dithBase = dithY end
			rr = band(rr + drr, 0xFFFFFFFF)
			gg = band(gg + dgg, 0xFFFFFFFF)
			bb = band(bb + dbb, 0xFFFFFFFF)
			width -= 1
		until width <= 0
		return
	end

	-- general path (blend or mask-check): exact shadePixel pipeline, computed inline -- closure calls per pixel add measurable overhead.
	local shadePixel = self.shadePixel
	repeat
		shadePixel(self, cmd, currentX, y,
			rshift(rr, 24), rshift(gg, 24), rshift(bb, 24),
			rshift(uvu, 24), rshift(uvv, 24))
		currentX += 1
		if textureEnable then
			uvu = band(uvu + du, 0xFFFFFFFF)
			uvv = band(uvv + dv, 0xFFFFFFFF)
		end
		if shadingEnable then
			rr = band(rr + drr, 0xFFFFFFFF)
			gg = band(gg + dgg, 0xFFFFFFFF)
			bb = band(bb + dbb, 0xFFFFFFFF)
		end
		width -= 1
	until width <= 0
end

-- drawtrianglepart (scalar)
function GPU:drawTrianglePart(cmd, tp, uv, uvstep, rgb, rgbstep)
	local leftXStep = tp.stepX1
	local rightXStep = tp.stepX2
	local endY = tp.endY
	local leftX = tp.startX1
	local rightX = tp.startX2
	local currentY = tp.startY
	-- per-row attribute state as scalars (was two table copies per call).
	local luvU, luvV = uv.u, uv.v
	local lrgbR, lrgbG, lrgbB = rgb.r, rgb.g, rgb.b
	-- signed row deltas precomputed once (s32 inlined)
	local sduy, sdvy = 0, 0
	local sdrr, sdgg, sdbb = 0, 0, 0
	if cmd.textureEnable then
		sduy = band(uvstep.dudy, 0xFFFFFFFF)
		if sduy >= 0x80000000 then sduy = sduy - 0x100000000 end
		sdvy = band(uvstep.dvdy, 0xFFFFFFFF)
		if sdvy >= 0x80000000 then sdvy = sdvy - 0x100000000 end
		luvU = band(luvU + sduy * currentY, 0xFFFFFFFF)
		luvV = band(luvV + sdvy * currentY, 0xFFFFFFFF)
	end
	if cmd.shadingEnable then
		sdrr = band(rgbstep.drdy, 0xFFFFFFFF)
		if sdrr >= 0x80000000 then sdrr = sdrr - 0x100000000 end
		sdgg = band(rgbstep.dgdy, 0xFFFFFFFF)
		if sdgg >= 0x80000000 then sdgg = sdgg - 0x100000000 end
		sdbb = band(rgbstep.dbdy, 0xFFFFFFFF)
		if sdbb >= 0x80000000 then sdbb = sdbb - 0x100000000 end
		lrgbR = band(lrgbR + sdrr * currentY, 0xFFFFFFFF)
		lrgbG = band(lrgbG + sdgg * currentY, 0xFFFFFFFF)
		lrgbB = band(lrgbB + sdbb * currentY, 0xFFFFFFFF)
	end
	-- drawspan hoisted out of the per-row metatable __index dispatch.
	local drawSpan = self.drawSpan
	if tp.fillUpsideDown then
		if currentY <= endY then return end
		repeat
			currentY -= 1
			leftX -= leftXStep
			rightX -= rightXStep
			local y = band(currentY, 0x7FF)
			if y >= 0x400 then y = y - 0x800 end
			if y < self.drawTop then break end
			if cmd.textureEnable then
				luvU = band(luvU - uvstep.dudy, 0xFFFFFFFF)
				luvV = band(luvV - uvstep.dvdy, 0xFFFFFFFF)
			end
			if cmd.shadingEnable then
				lrgbR = band(lrgbR - rgbstep.drdy, 0xFFFFFFFF)
				lrgbG = band(lrgbG - rgbstep.dgdy, 0xFFFFFFFF)
				lrgbB = band(lrgbB - rgbstep.dbdy, 0xFFFFFFFF)
			end
			if y <= self.drawBottom then
				drawSpan(self, cmd, band(y, 0x1FF), unfpXy(leftX), unfpXy(rightX), luvU, luvV, uvstep, lrgbR, lrgbG, lrgbB, rgbstep)
			end
		until currentY <= endY
	else
		if currentY >= endY then return end
		repeat
			local y = band(currentY, 0x7FF)
			if y >= 0x400 then y = y - 0x800 end
			if y > self.drawBottom then
				break
			end
			if y >= self.drawTop then
				drawSpan(self, cmd, band(y, 0x1FF), unfpXy(leftX), unfpXy(rightX), luvU, luvV, uvstep, lrgbR, lrgbG, lrgbB, rgbstep)
			end
			currentY += 1
			leftX += leftXStep
			rightX += rightXStep
			if cmd.textureEnable then
				luvU = band(luvU + uvstep.dudy, 0xFFFFFFFF)
				luvV = band(luvV + uvstep.dvdy, 0xFFFFFFFF)
			end
			if cmd.shadingEnable then
				lrgbR = band(lrgbR + rgbstep.drdy, 0xFFFFFFFF)
				lrgbG = band(lrgbG + rgbstep.dgdy, 0xFFFFFFFF)
				lrgbB = band(lrgbB + rgbstep.dbdy, 0xFFFFFFFF)
			end
		until currentY >= endY
	end
end

-- drawtriangle (duckstation gpu_sw_rasterizer.inl drawtriangle)
function GPU:drawTriangle(cmd, v0in, v1in, v2in)
	local v0, v1, v2 = v0in, v1in, v2in

	-- sort so v0 is the top vertex, v1 the bottom, v2 the side.
	local tl = 0
	if v1.x <= v0.x then
		tl = (v2.x <= v1.x) and 4 or 2
	elseif v2.x < v0.x then
		tl = 4
	else
		tl = 1
	end
	if v2.y < v1.y then
		v2, v1 = v1, v2
		tl = bor(band(rshift(tl, 1), 0x2), band(lshift(tl, 1), 0x4), band(tl, 0x1))
	end
	if v1.y < v0.y then
		v1, v0 = v0, v1
		tl = bor(band(rshift(tl, 1), 0x1), band(lshift(tl, 1), 0x2), band(tl, 0x4))
	end
	if v2.y < v1.y then
		v2, v1 = v1, v2
		tl = bor(band(rshift(tl, 1), 0x2), band(lshift(tl, 1), 0x4), band(tl, 0x1))
	end

	local vertices = triVerts
	vertices[1] = v0
	vertices[2] = v1
	vertices[3] = v2
	tl = rshift(tl, 1)

	if v0.y == v2.y then return end

	local baseCoord = makefpXy(v0.x)
	local baseStep = makeStepXy(v2.x - v0.x, v2.y - v0.y)
	local boundCoordUs = (v1.y == v0.y) and 0 or makeStepXy(v1.x - v0.x, v1.y - v0.y)
	local boundCoordLs = (v2.y == v1.y) and 0 or makeStepXy(v2.x - v1.x, v2.y - v1.y)
	local vo = (tl ~= 0) and 1 or 0
	local vp = (tl == 2) and 3 or 0
	local rightFacing = (v1.y == v0.y) and (v1.x > v0.x) or (boundCoordUs > baseStep)
	local rfi = rightFacing and 1 or 0
	local ofi = (not rightFacing) and 1 or 0

	local tpo = triTpo
	local tpp = triTpp
	tpo.startY = vertices[1 + bxor(0, vo)].y
	tpo.endY = vertices[1 + bxor(1, vo)].y
	tpp.startY = vertices[1 + bxor(1, vp)].y
	tpp.endY = vertices[1 + bxor(2, vp)].y
	-- slot 0 = startx1, slot 1 = startx2.
	if rfi == 1 then
		tpo.startX2 = makefpXy(vertices[1 + bxor(0, vo)].x)
		tpo.stepX2 = boundCoordUs
	else
		tpo.startX1 = makefpXy(vertices[1 + bxor(0, vo)].x)
		tpo.stepX1 = boundCoordUs
	end
	if ofi == 1 then
		tpo.startX2 = baseCoord + (vertices[1 + vo].y - vertices[1].y) * baseStep
		tpo.stepX2 = baseStep
	else
		tpo.startX1 = baseCoord + (vertices[1 + vo].y - vertices[1].y) * baseStep
		tpo.stepX1 = baseStep
	end
	tpo.fillUpsideDown = vo ~= 0
	if rfi == 1 then
		tpp.startX2 = makefpXy(vertices[1 + bxor(1, vp)].x)
		tpp.stepX2 = boundCoordLs
	else
		tpp.startX1 = makefpXy(vertices[1 + bxor(1, vp)].x)
		tpp.stepX1 = boundCoordLs
	end
	if ofi == 1 then
		tpp.startX2 = baseCoord + (vertices[1 + bxor(1, vp)].y - vertices[1].y) * baseStep
		tpp.stepX2 = baseStep
	else
		tpp.startX1 = baseCoord + (vertices[1 + bxor(1, vp)].y - vertices[1].y) * baseStep
		tpp.stepX1 = baseStep
	end
	tpp.fillUpsideDown = vp ~= 0

	local det = (v1.x - v0.x) * (v2.y - v1.y) - (v2.x - v1.x) * (v1.y - v0.y)
	if det == 0 then return end

	local uvstep = triUvStep
	local rgbstep = triRgbStep
	if cmd.textureEnable then
		uvstep.dudx = attrStep((v1.u - v0.u) * (v2.y - v1.y) - (v2.u - v1.u) * (v1.y - v0.y), det)
		uvstep.dvdx = attrStep((v1.v - v0.v) * (v2.y - v1.y) - (v2.v - v1.v) * (v1.y - v0.y), det)
		uvstep.dudy = attrStep((v1.x - v0.x) * (v2.u - v1.u) - (v2.x - v1.x) * (v1.u - v0.u), det)
		uvstep.dvdy = attrStep((v1.x - v0.x) * (v2.v - v1.v) - (v2.x - v1.x) * (v1.v - v0.v), det)
	end
	if cmd.shadingEnable then
		rgbstep.drdx = attrStep((v1.r - v0.r) * (v2.y - v1.y) - (v2.r - v1.r) * (v1.y - v0.y), det)
		rgbstep.dgdx = attrStep((v1.g - v0.g) * (v2.y - v1.y) - (v2.g - v1.g) * (v1.y - v0.y), det)
		rgbstep.dbdx = attrStep((v1.b - v0.b) * (v2.y - v1.y) - (v2.b - v1.b) * (v1.y - v0.y), det)
		rgbstep.drdy = attrStep((v1.x - v0.x) * (v2.r - v1.r) - (v2.x - v1.x) * (v1.r - v0.r), det)
		rgbstep.dgdy = attrStep((v1.x - v0.x) * (v2.g - v1.g) - (v2.x - v1.x) * (v1.g - v0.g), det)
		rgbstep.dbdy = attrStep((v1.x - v0.x) * (v2.b - v1.b) - (v2.x - v1.x) * (v1.b - v0.b), det)
	end

	local topLeftVertex = vertices[1 + tl]
	local uv = triUv
	local rgb = triRgb

	if cmd.textureEnable then
		local v = topLeftVertex
		uv.u = u32(u32(u32(v.u) * 4096 + 2048) * 4096)
		uv.v = u32(u32(u32(v.v) * 4096 + 2048) * 4096)
		stepXCount(uv, uvstep, -v.x)
		stepYCount(uv, uvstep, -v.y)
	end
	if cmd.shadingEnable then
		local v = topLeftVertex
		rgb.r = u32(u32(u32(v.r) * 4096 + 2048) * 4096)
		rgb.g = u32(u32(u32(v.g) * 4096 + 2048) * 4096)
		rgb.b = u32(u32(u32(v.b) * 4096 + 2048) * 4096)
		stepRgbXCount(rgb, rgbstep, -v.x)
		stepRgbYCount(rgb, rgbstep, -v.y)
	else
		local v = topLeftVertex
		rgb.r = u32(u32(u32(v.r) * 4096 + 2048) * 4096)
		rgb.g = u32(u32(u32(v.g) * 4096 + 2048) * 4096)
		rgb.b = u32(u32(u32(v.b) * 4096 + 2048) * 4096)
	end

	self:drawTrianglePart(cmd, tpo, uv, uvstep, rgb, rgbstep)
	self:drawTrianglePart(cmd, tpp, uv, uvstep, rgb, rgbstep)
end


function GPU:gp0Exec()
	-- gp0 commands can mutate status (mask bits, texpage merge via
	-- setdrawmode) and reset gp0buf at completion.
	invalidateStatus(self)
	local buf = self.gp0buf
	local cmd = rshift(buf[1], 24)
	local r0 = band(buf[1], 0xFF); local g0 = band(rshift(buf[1], 8), 0xFF); local b0 = band(rshift(buf[1], 16), 0xFF)
	local dox = self.drawOffX; local doy = self.drawOffY

	if cmd == 0x00 then -- NOP
	elseif cmd == 0x01 then -- clear cache (DuckStation: also invalidates the CLUT cache)
		self:invalidateCLUT()
		self:addCommandTicks(1)
	elseif cmd == 0x02 then
		-- fill rectangle in vram (duckstation: x is 16-aligned via & 0x3f0)
		local x = band(band(buf[2], 0xFFFF), 0x3F0); local y = rshift(buf[2], 16)
		-- hardware masks: width 10-bit (rounded up to a multiple of 16), height 9-bit.
		local w = band(band(buf[3], 0x3FF) + 0xF, bnot(0xF)); local h = band(rshift(buf[3], 16), 0x1FF)
		local col = rgb24to15(r0, g0, b0)
		-- inline the write: no vpoke method call, no coordinate masking, no
		-- bounds wrap for the common fully-inside-vram case.
		if x >= 0 and x + w <= VRAM_W and y >= 0 and y + h <= VRAM_H then
			local v = self.vram
			local base = y * VRAM_W + x + 1
			for fy = 0, h - 1 do
				local rowFirst = base + fy * VRAM_W
				for fx = 0, w - 1 do v[rowFirst + fx] = col end
				logVram(self, rowFirst, w)
			end
		else
			for fy = y, y + h - 1 do for fx = x, x + w - 1 do self:vpoke(fx, fy, col) end end
		end
		-- duckstation handlefillvramcommand: 46 + ((width/8) + 9) * height.
		self:addCommandTicks(46 + ((w // 8) + 9) * h)
	elseif cmd >= 0x20 and cmd <= 0x3F then self:gp0Poly(cmd, buf)
	elseif cmd >= 0x40 and cmd <= 0x5F then self:gp0Line(cmd, buf)
	elseif cmd >= 0x60 and cmd <= 0x7F then self:gp0Rect(cmd, buf)
	elseif cmd == 0x80 then -- VRAM-to-VRAM copy (DuckStation CopyVRAM semantics)
		local sx = band(buf[2], 0x3FF); local sy = band(rshift(buf[2], 16), 0x1FF)
		local dx = band(buf[3], 0x3FF); local dy = band(rshift(buf[3], 16), 0x1FF)
		-- hardware masks: width 10-bit, height 9-bit; zero means full size.
		local w  = band(buf[4], 0x3FF); local h  = band(rshift(buf[4], 16), 0x1FF)
		if w == 0 then w = 0x400 end
		if h == 0 then h = 0x200 end
		if not (w == 0 or h == 0 or (sx == dx and sy == dy and not self.maskSet)) then
			-- copy in reverse when src_x < dst_x (or rows wrap) so the source isn't overwritten ahead of the read.  mask: dst = ((dst & mask_and) == 0) ? (src | mask_or) : dst
			local maskAnd = self.maskCheck and 0x8000 or 0
			local maskOr = self.maskSet and 0x8000 or 0
			local vram = self.vram
			local reverseX = (sx < dx) or ((sx + w - 1) % VRAM_W) < ((dx + w - 1) % VRAM_W)
			for fy = 0, h - 1 do
				local syy = band(sy + fy, 0x1FF)
				local dyy = band(dy + fy, 0x1FF)
				local sRow = syy * VRAM_W
				local dRow = dyy * VRAM_W
				for fx = (reverseX and w - 1 or 0), (reverseX and 0 or w - 1), (reverseX and -1 or 1) do
					local sxx = band(sx + fx, 0x3FF)
					local dxx = band(dx + fx, 0x3FF)
					local src = vram[sRow + sxx + 1] or 0
					local didx = dRow + dxx + 1
					if band(vram[didx] or 0, maskAnd) == 0 then
						vram[didx] = band(bor(src, maskOr), 0xFFFF)
						local vlog = self.vramLog
						if vlog then vlog[#vlog + 1] = didx; vlog[#vlog + 1] = 1 end
					end
				end
			end
		end
		-- duckstation handlecopyvramcommand: width * height * 2.
		self:addCommandTicks(w * h * 2)
	elseif cmd == 0xA0 then -- CPU-to-VRAM
		local size = buf[3] or 0
		if size == 0xFFFFFFFF then return end -- DuckStation skips invalid uploads
		self.cvX = band(buf[2], 0x3FF); self.cvY = band(rshift(buf[2], 16), 0x1FF)
		self.cvW = band(size, 0x3FF); if self.cvW == 0 then self.cvW = 0x400 end
		self.cvH = band(rshift(size, 16), 0x1FF); if self.cvH == 0 then self.cvH = 0x200 end
		self.cvPX = 0; self.cvPY = 0; self.cvHalf = nil
		self.gp0mode = "cpuToVram"; self.gp0buf = {}; self.gp0needed = 0; self.gp0handler = nil; return
	elseif cmd == 0xC0 then -- VRAM-to-CPU
		self.vcX = band(buf[2], 0x3FF); self.vcY = band(rshift(buf[2], 16), 0x1FF)
		-- duckstation: (size-1) & mask, +1 (a zero size becomes a full-width read).
		local size = buf[3] or 0
		self.vcW = t16(band(t16(size) - 1, 0x3FF)) + 1
		self.vcH = t16(band(t16(rshift(size, 16)) - 1, 0x1FF)) + 1
		self.vcPX = 0; self.vcPY = 0
		self.gp0mode = "vramToCpu"; self.gp0buf = {}; self.gp0needed = 0; self.gp0handler = nil; return
	elseif cmd == 0xE1 then -- draw mode
		self:setDrawMode(buf[1])
		self:addCommandTicks(1)
	elseif cmd == 0xE2 then -- texture window
		self.texWindowMaskX = band(buf[1], 0x1F) * 8; self.texWindowMaskY = band(rshift(buf[1], 5), 0x1F) * 8
		self.texWindowOffX  = band(rshift(buf[1], 10), 0x1F) * 8; self.texWindowOffY = band(rshift(buf[1], 15), 0x1F) * 8
		self:addCommandTicks(1)
	elseif cmd == 0xE3 then -- draw area top-left
		self.drawLeft = band(buf[1], 0x3FF); self.drawTop = band(rshift(buf[1], 10), 0x1FF)
		self:addCommandTicks(1)
	elseif cmd == 0xE4 then -- draw area bottom-right
		self.drawRight = band(buf[1], 0x3FF); self.drawBottom = band(rshift(buf[1], 10), 0x1FF)
		self:addCommandTicks(1)
	elseif cmd == 0xE5 then -- draw offset
		self.drawOffX = sx11(band(buf[1], 0x7FF)); self.drawOffY = sx11(band(rshift(buf[1], 11), 0x7FF))
		self:addCommandTicks(1)
	elseif cmd == 0xE6 then -- mask bit setting (GPUSTAT bits 11-12)
		local bits = lshift(band(buf[1], 0x3), 11)
		self.status = bor(band(self.status, bnot(0x1800)), bits)
		self.maskSet = band(self.status, 0x800) ~= 0
		self.maskCheck = band(self.status, 0x1000) ~= 0
		self:addCommandTicks(1)
	end
	self.gp0buf = {}; self.gp0needed = 0; self.gp0handler = nil
end

-- determine word count for a gp0 command
local GP0_WORDS = {
	[0x00]=1,[0x01]=1,[0x02]=3,
	[0x20]=4,[0x21]=4,[0x22]=4,[0x23]=4, -- mono tri
	[0x24]=7,[0x25]=7,[0x26]=7,[0x27]=7, -- tex tri
	[0x28]=5,[0x29]=5,[0x2A]=5,[0x2B]=5, -- mono quad
	[0x2C]=9,[0x2D]=9,[0x2E]=9,[0x2F]=9, -- tex quad
	[0x30]=6,[0x31]=6,[0x32]=6,[0x33]=6, -- shaded tri
	[0x34]=9,[0x35]=9,[0x36]=9,[0x37]=9, -- shaded tex tri
	[0x38]=8,[0x39]=8,[0x3A]=8,[0x3B]=8, -- shaded quad
	[0x3C]=12,[0x3D]=12,[0x3E]=12,[0x3F]=12, -- shaded tex quad
	[0x40]=3,[0x41]=3,[0x42]=3,[0x43]=3, -- mono line: cmd(+color), XY1, XY2
	[0x44]=3,[0x45]=3,[0x46]=3,[0x47]=3, -- mono line variants (bit 2 ignored for lines)
	[0x48]=255,[0x49]=255,[0x4A]=255,[0x4B]=255, -- mono polyline (variable)
	[0x4C]=255,[0x4D]=255,[0x4E]=255,[0x4F]=255, -- mono polyline variants (bit 2 ignored)
	[0x50]=4,[0x51]=4,[0x52]=4,[0x53]=4, -- gouraud line: cmd(+color1), XY1, color2, XY2
	[0x54]=4,[0x55]=4,[0x56]=4,[0x57]=4, -- gouraud line variants (bit 2 ignored)
	[0x58]=255,[0x59]=255,[0x5A]=255,[0x5B]=255, -- gouraud polyline (variable)
	[0x5C]=255,[0x5D]=255,[0x5E]=255,[0x5F]=255, -- gouraud polyline variants
	[0x60]=3,[0x61]=3,[0x62]=3,[0x63]=3, -- mono rect
	[0x64]=4,[0x65]=4,[0x66]=4,[0x67]=4, -- tex rect
	[0x68]=2,[0x69]=2,[0x6A]=2,[0x6B]=2, -- 1x1 rect (dot): cmd(+color), XY
	[0x6C]=3,[0x6D]=3,[0x6E]=3,[0x6F]=3, -- 1x1 textured rect: cmd(+color), XY, UV
	[0x70]=2,[0x71]=2,[0x72]=2,[0x73]=2, -- 8x8 rect (fixed size: no WH word)
	[0x74]=3,[0x75]=3,[0x76]=3,[0x77]=3, -- 8x8 tex rect
	[0x78]=2,[0x79]=2,[0x7A]=2,[0x7B]=2, -- 16x16 rect
	[0x7C]=3,[0x7D]=3,[0x7E]=3,[0x7F]=3, -- 16x16 tex rect
	[0x80]=4,[0xA0]=3,[0xC0]=3,
	[0xE1]=1,[0xE2]=1,[0xE3]=1,[0xE4]=1,[0xE5]=1,[0xE6]=1,
}

-- polygon: duckstation handlepolygon semantics (texpage merge + clut peek
-- + vertex unpacking) feeding the fixed-point rasterizer.
function GPU:gp0Poly(cmd, buf)
	local rc = buf[1] or 0
	local dox = self.drawOffX; local doy = self.drawOffY
	local textured = band(cmd, 0x04) ~= 0
	local quad     = band(cmd, 0x08) ~= 0
	local shaded   = band(cmd, 0x10) ~= 0

	-- duckstation: texpage comes from the second vertex's texcoord, clut from the first; merged via (texpage & 0x9ff) | (drawmode & ~0x9ff).
	if textured then
		local tp = band(rshift(buf[shaded and 6 or 5] or 0, 16), 0xFFFF)
		local merged = bor(band(tp, 0x9FF), band(self.drawModeReg, bnot(0x9FF)))
		self:setDrawMode(merged)
		self:setTexturePalette(band(rshift(buf[3] or 0, 16), 0xFFFF))
		self:updateCLUTIfNeeded(band(rshift(merged, 7), 3), self.texturePaletteReg)
	end

	local cmdT = self:fillDrawCommand(rc, false)
	-- duckstation: polygons dither only when shaded or texture-modulated; flat/raw-textured polygons never dither.
	cmdT.ditherEnable = cmdT.ditherEnable and (cmdT.shadingEnable or (cmdT.textureEnable and not cmdT.rawTextureEnable))
	local firstColor = band(rc, 0xFFFFFF)
	local nv = quad and 4 or 3
	local vertices = polyVerts
	local i = 1
	local function nextWord() i += 1; return buf[i] or 0 end
	for vi = 0, nv - 1 do
		local v = polyVerts[vi + 1]
		if shaded and vi > 0 then
			v.color = band(nextWord(), 0xFFFFFF)
		else
			v.color = firstColor
		end
		local xy = nextWord()
		v.x = dox + sx11(band(xy, 0xFFFF))
		v.y = doy + sx11(rshift(xy, 16))
		v.texcoord = textured and nextWord() or 0
		v.r = band(v.color, 0xFF)
		v.g = band(rshift(v.color, 8), 0xFF)
		v.b = band(rshift(v.color, 16), 0xFF)
		v.u = band(v.texcoord, 0xFF)
		v.v = band(rshift(v.texcoord, 8), 0xFF)
		vertices[vi + 1] = v
	end

	-- modeled gpu time (duckstation): polygon setup table + per-triangle pixel
	-- area.
	self:addCommandTicks(POLY_SETUP_TIME[quad and 2 or 1][shaded and 2 or 1][textured and 2 or 1])

	-- cull polygons larger than max_primitive (duckstation).
	local function triCulled(a, b, c)
		local minX = math.min(a.x, math.min(b.x, c.x))
		local maxX = math.max(a.x, math.max(b.x, c.x))
		local minY = math.min(a.y, math.min(b.y, c.y))
		local maxY = math.max(a.y, math.max(b.y, c.y))
		return (maxX - minX + 1) > MAX_PRIMITIVE_WIDTH or (maxY - minY + 1) > MAX_PRIMITIVE_HEIGHT
	end
	local v0, v1, v2 = vertices[1], vertices[2], vertices[3]
	local firstCulled = triCulled(v0, v1, v2)
	if firstCulled then
		if not cmdT.quadPolygon then return end
	end
	if not firstCulled then
		self:addDrawTriangleTicks(v0, v1, v2, cmdT.textureEnable, cmdT.transparencyEnable)
		self:drawTriangle(cmdT, v0, v1, v2)
	end
	if cmdT.quadPolygon then
		local v3 = vertices[4]
		local secondCulled = triCulled(v2, v1, v3)
		if not secondCulled then
			-- quad second triangle: (v2, v1, v3) -- reversed winding so the shared diagonal is covered exactly once.
			self:addDrawTriangleTicks(v2, v1, v3, cmdT.textureEnable, cmdT.transparencyEnable)
			self:drawTriangle(cmdT, v2, v1, v3)
		end
	end
end

-- line / polyline: duckstation handleline/finishpolyline semantics feeding the
-- fixed-point line rasterizer (textureenable forced false for lines).
function GPU:gp0Line(cmd, buf)
	local rc = buf[1] or 0
	local dox = self.drawOffX; local doy = self.drawOffY
	local gouraud = band(cmd, 0x10) ~= 0
	local poly = band(cmd, 0x08) ~= 0
	local cmdT = self:fillDrawCommand(rc, true)
	cmdT.paletteBits = 0
	-- duckstation setup ticks: polylines pay 16 once at issue; single lines pay none.
	if poly then
		self:addCommandTicks(16)
	end
	local firstColor = band(rc, 0xFFFFFF)
	local function getXY(w) return dox + sx11(band(w, 0xFFFF)), doy + sx11(rshift(w, 16)) end
	local function mkVertex(x, y, color)
		local v = { x = x, y = y, color = color }
		v.r = band(color, 0xFF)
		v.g = band(rshift(color, 8), 0xFF)
		v.b = band(rshift(color, 16), 0xFF)
		return v
	end
	local function drawSeg(ax, ay, bx, by, cA, cB)
		-- cull segments whose bounding box exceeds max_primitive (duckstation).
		local minX = math.min(ax, bx); local maxX = math.max(ax, bx)
		local minY = math.min(ay, by); local maxY = math.max(ay, by)
		if (maxX - minX + 1) > MAX_PRIMITIVE_WIDTH or (maxY - minY + 1) > MAX_PRIMITIVE_HEIGHT then return end
		self:addDrawLineTicks(ax, ay, bx, by)
		self:drawLine(cmdT, mkVertex(ax, ay, cA), mkVertex(bx, by, cB))
	end
	if poly then
		-- variable-length polyline: vertex-led on the wire -- first vertex follows the command word, later ones are (color, xy); ends at the terminator (word & 0xf000f000) == 0x50005000 or buffer end.
		local i = 2
		local px, py, pc
		while i <= #buf do
			local w = buf[i]
			if band(w, 0xF000F000) == 0x50005000 then break end
			local c = firstColor
			if gouraud and px ~= nil then
				c = band(w, 0xFFFFFF)
				i += 1
				if i > #buf then break end
				w = buf[i]
			end
			local x, y = getXY(w)
			if px ~= nil then
				drawSeg(px, py, x, y, pc, c)
			end
			px, py, pc = x, y, c
			i += 1
		end
		return
	end
	local c1 = firstColor
	local ax, ay
	local bx, by
	if gouraud then
		-- gouraud line layout: cmd(+color1), xy1, color2, xy2.
		c1 = band(buf[3] or 0, 0xFFFFFF)
		ax, ay = getXY(buf[2] or 0)
		bx, by = getXY(buf[4] or 0)
	else
		ax, ay = getXY(buf[2] or 0)
		bx, by = getXY(buf[3] or 0)
	end
	drawSeg(ax, ay, bx, by, firstColor, c1)
end

-- rectangle: duckstation handlerectangle semantics (clut peek + truncvertexpos
-- position) feeding drawrectangle.
function GPU:gp0Rect(cmd, buf)
	local rc = buf[1] or 0
	local textured = band(cmd, 0x04) ~= 0
	local size = rshift(band(cmd, 0x18), 3)
	if textured then
		self:setTexturePalette(band(rshift(buf[3] or 0, 16), 0xFFFF))
		self:updateCLUTIfNeeded(band(rshift(self.drawModeReg, 7), 3), self.texturePaletteReg)
	end
	local cmdT = self:fillDrawCommand(rc, false)
	-- duckstation: rectangles (sprites) never dither, regardless of the
	-- draw-mode bit.
	cmdT.ditherEnable = false
	cmdT.color = band(rc, 0xFFFFFF)
	local xy = buf[2] or 0
	cmdT.x = truncVertexPos(self.drawOffX + sx11(band(xy, 0xFFFF)))
	cmdT.y = truncVertexPos(self.drawOffY + sx11(rshift(xy, 16)))
	if textured then
		local uvPal = buf[3] or 0
		cmdT.paletteBits = band(rshift(uvPal, 16), 0xFFFF)
		cmdT.texcoord = t16(uvPal)
	else
		cmdT.paletteBits = 0
		cmdT.texcoord = 0
	end
	if size == 1 then
		cmdT.width, cmdT.height = 1, 1
	elseif size == 2 then
		cmdT.width, cmdT.height = 8, 8
	elseif size == 3 then
		cmdT.width, cmdT.height = 16, 16
	else
		-- variable size: the wh word sits after the texcoord for textured
		-- rects (buf[4]) but directly after xy for plain ones (buf[3]).
		local wh = buf[textured and 4 or 3] or 0
		cmdT.width = t16(band(wh, 0x3FF))
		cmdT.height = t16(band(rshift(wh, 16), 0x1FF))
	end
	-- modeled gpu time (duckstation): 16 setup ticks + per-row x height.
	self:addCommandTicks(16)
	self:addDrawRectangleTicks(cmdT.x, cmdT.y, cmdT.width, cmdT.height, cmdT.textureEnable, cmdT.transparencyEnable)
	self:drawRectangle(cmdT)
end

function GPU:writeGp0(word)
	word = band(word, 0xFFFFFFFF)
	-- every write can grow gp0buf or flip gp0mode.
	invalidateStatus(self)
	if self.recordHook then self.recordHook("gp0", word) end
	self._vramEpoch = (self._vramEpoch or 0) + 1
	if self.gp0mode == "cpuToVram" then
		-- blit words cost modeled gpu time (duckstation charges per word during
		-- writingvram): 2 cycles per 32-bit word (1 cycle per pixel).
		self:addCommandTicks(2)
		-- pack two 16-bit halves per word; bit 15 (stp/mask) must be preserved -- loadimage stores raw halves.
		if self.cvX + self.cvW <= VRAM_W and self.cvY + self.cvH <= VRAM_H and not self.maskSet and not self.maskCheck then
			local vram = self.vram
			local rowBase = (self.cvY + self.cvPY) * VRAM_W + self.cvX
			local p0 = band(word, 0xFFFF)
			local p0Idx = rowBase + self.cvPX + 1
			vram[p0Idx] = p0
			logVram(self, p0Idx, 1)
			self.cvPX += 1
			if self.cvPX >= self.cvW then
				self.cvPX = 0
				self.cvPY += 1
				rowBase = (self.cvY + self.cvPY) * VRAM_W + self.cvX
			end
			local p1 = band(rshift(word, 16), 0xFFFF)
			local p1Idx = rowBase + self.cvPX + 1
			vram[p1Idx] = p1
			logVram(self, p1Idx, 1)
			self.cvPX += 1
			if self.cvPX >= self.cvW then
				self.cvPX = 0
				self.cvPY += 1
			end
			if self.cvPY >= self.cvH then self.gp0mode = "cmd" end
			return
		end
		-- slow path: transfer may cross vram edges (x wraps within the row,
		-- y wraps to the top) -- delegate to vpoke which handles the wrap.
		local p0 = band(word, 0xFFFF)
		local p1 = band(rshift(word, 16), 0xFFFF)
		if self.maskSet or self.maskCheck then
			self:maskedWrite(self.cvX + self.cvPX, self.cvY + self.cvPY, p0)
		else
			self:vpoke(self.cvX + self.cvPX, self.cvY + self.cvPY, p0)
		end
		self.cvPX += 1; if self.cvPX >= self.cvW then self.cvPX=0; self.cvPY+=1 end
		if self.maskSet or self.maskCheck then
			self:maskedWrite(self.cvX + self.cvPX, self.cvY + self.cvPY, p1)
		else
			self:vpoke(self.cvX + self.cvPX, self.cvY + self.cvPY, p1)
		end
		self.cvPX += 1; if self.cvPX >= self.cvW then self.cvPX=0; self.cvPY+=1 end
		if self.cvPY >= self.cvH then self.gp0mode = "cmd" end
		return
	end
	if self.gp0mode == "vramToCpu" then return end  -- ignore, reads go through readGpuData
	table.insert(self.gp0buf, word)
	if #self.gp0buf == 1 then
		local cmd = rshift(word, 24)
		local n = GP0_WORDS[cmd]
		if not n then n = 1 end
		self.gp0needed = n
	end
	local done
	if self.gp0needed == 255 then
		-- polyline: consumes words until the terminator (word & 0xf000f000) == 0x50005000; the command word itself never counts, or a color in 0x50-0x5f would self-terminate.
		done = #self.gp0buf > 1 and band(word, 0xF000F000) == 0x50005000
	else
		done = #self.gp0buf >= self.gp0needed
	end
	if done and #self.gp0buf > 0 then
		self:gp0Exec()
	end
end

function GPU:recomputeDisplay()
	-- display size from the gp1 display-range registers: width (x2-x1)/cpp, height y2-y1 -- the vertical range defines the true frame height.
	local hreses = {256, 320, 512, 640, 368}
	local hmode = band(self.dispMode or 0, 3)
	if band(self.dispMode or 0, 0x40) ~= 0 then hmode = 4 end
	local cpp = 8
	if hmode == 2 or hmode == 3 then cpp = 4 elseif hmode == 4 then cpp = 7 end
	local w = 0
	if self.hdispX1 and self.hdispX2 and self.hdispX2 > self.hdispX1 then
		w = math.floor((self.hdispX2 - self.hdispX1) / cpp)
	end
	if w <= 0 then w = hreses[hmode + 1] or 320 end
	local h = 0
	if self.vdispY1 and self.vdispY2 and self.vdispY2 > self.vdispY1 then
		h = self.vdispY2 - self.vdispY1
	end
	if h <= 0 then h = band(self.dispMode or 0, 4) ~= 0 and 480 or 240 end
	-- in interlaced mode the vertical display range counts half-lines, so the
	-- displayed frame is twice as tall (e.g. vdisp 24..248 -> 448 lines).
	if self.interlaced then h = h * 2 end
	self.displayWidth = w
	self.displayHeight = h
end

function GPU:writeGp1(value)
	-- any command can rewrite the composed-status inputs; invalidating here is cheaper and safer than tagging each branch.
	invalidateStatus(self)
	if self.recordHook then self.recordHook("gp1", value) end
	self._vramEpoch = (self._vramEpoch or 0) + 1
	local cmd   = band(rshift(value, 24), 0xFF)
	local param = band(value, 0x00FFFFFF)
	if cmd == 0x00 then -- reset (DuckStation soft-reset semantics)
		self.status = 0x14802000; self.dmaDirection = 0; self.gp0buf = {}; self.gp0needed = 0; self.gp0mode = "cmd"
		self.frameCycleCounter = 0
		self.pendingCycles = 0
		self.displayStartX = 0; self.displayStartY = 0; self.displayDisabled = true
		self.drawLeft = 0; self.drawTop = 0; self.drawRight = 0; self.drawBottom = 0
		self.drawOffX = 0; self.drawOffY = 0
		self.texWindowMaskX = 0; self.texWindowMaskY = 0; self.texWindowOffX = 0; self.texWindowOffY = 0
		self:setDrawMode(0)
		self:setTexturePalette(0)
		self:invalidateCLUT()
		self.setTextureDisableMask = false
		self.textureEnableMask = true
	elseif cmd == 0x01 then
		self.gp0buf = {}; self.gp0needed = 0; self.gp0mode = "cmd"
		self.pendingCycles = 0
	elseif cmd == 0x02 then -- ack interrupt
		self.status = band(self.status, bnot(0x01000000))
	elseif cmd == 0x03 then
		-- gpustat bit 23 = display_disable (duckstation writegp1 0x03: value & 1).
		self.displayDisabled = band(param, 1) == 1
		if band(param, 1) ~= 0 then self.status = bor(self.status, 0x00800000) else self.status = band(self.status, bnot(0x00800000)) end
	elseif cmd == 0x04 then
		self.dmaDirection = band(param, 3)
		self.status = band(self.status, bnot(0x60000000))
		self.status = bor(self.status, lshift(self.dmaDirection, 29))
	elseif cmd == 0x05 then
		self.displayStartX = band(param, 0x3FE); self.displayStartY = band(rshift(param, 10), 0x1FF)
	elseif cmd == 0x06 then -- horizontal display range: X1/X2 in video-clock units
		self.hdispX1 = band(param, 0xFFF)
		self.hdispX2 = band(rshift(param, 12), 0xFFF)
		self:recomputeDisplay()
	elseif cmd == 0x07 then -- vertical display range: Y1/Y2 in half-lines
		self.vdispY1 = band(param, 0x3FF)
		self.vdispY2 = band(rshift(param, 10), 0x3FF)
		self:recomputeDisplay()
	elseif cmd == 0x08 then -- display mode
		self.dispMode = param
		self.interlaced    = band(rshift(param, 5), 1) == 1
		self:recomputeDisplay()
		-- gp1 08h param -> gpustat: 0-1 HR1 (17-18), 2 vres (19), 3 pal (20), 4 24bpp (21), 5 interlace (22), 6 HR2 (16), 7 reverse (14).
		local bits = lshift(band(param, 0x3), 17)
		bits = bor(bits, lshift(band(rshift(param, 2), 1), 19))
		bits = bor(bits, lshift(band(rshift(param, 3), 1), 20))
		bits = bor(bits, lshift(band(rshift(param, 4), 1), 21))
		bits = bor(bits, lshift(band(rshift(param, 5), 1), 22))
		bits = bor(bits, lshift(band(rshift(param, 6), 1), 16))
		bits = bor(bits, lshift(band(rshift(param, 7), 1), 14))
		self.status = bor(band(self.status, bnot(0x007F4000)), bits)
	elseif cmd == 0x09 then -- allow texture disable
		self.setTextureDisableMask = band(param, 1) ~= 0
	elseif cmd == 0x10 then -- get GPU info
		local info = band(param, 7)
		if info == 2 then self.gpuread = bor(self.texWindowMaskX / 8, lshift(self.texWindowMaskY / 8, 5))
		elseif info == 3 then self.gpuread = bor(self.drawLeft, lshift(self.drawTop, 10))
		elseif info == 4 then self.gpuread = bor(self.drawRight, lshift(self.drawBottom, 10))
		elseif info == 5 then self.gpuread = bor(band(self.drawOffX, 0x7FF), lshift(band(self.drawOffY, 0x7FF), 11))
		end
	end
end

-- switch console region at runtime: 564480 cycles/frame (ntsc) vs 677376 (pal).
function GPU:addCommandTicks(ticks)
	self.pendingCycles += ticks
	invalidateStatus(self)
end

local function gpuClampPoint(x, y, left, right, top, bottom)
	local function clamp(v, lo, hi)
		if v < lo then return lo elseif v > hi then return hi end
		return v
	end
	return clamp(x, left, right), clamp(y, top, bottom)
end

-- duckstation adddrawtriangleticks: shoelace area of the drawing-area-clamped
-- triangle / 2; textured doubles it; semi-transparent or mask-check adds 50%.
function GPU:addDrawTriangleTicks(v1, v2, v3, textured, semiTransparent)
	local left, right = self.drawLeft, self.drawRight
	local top, bottom = self.drawTop, self.drawBottom
	if left > right or top > bottom then return end
	local c1x, c1y = gpuClampPoint(v1.x, v1.y, left, right, top, bottom)
	local c2x, c2y = gpuClampPoint(v2.x, v2.y, left, right, top, bottom)
	local c3x, c3y = gpuClampPoint(v3.x, v3.y, left, right, top, bottom)
	local area2 = math.abs(c1x * c2y + c2x * c3y + c3x * c1y - c1x * c3y - c2x * c1y - c3x * c2y)
	local pixels = area2 // 2
	if textured then pixels += pixels end
	if semiTransparent or self.maskCheck then pixels += (pixels + 1) // 2 end
	self:addCommandTicks(pixels)
end

-- duckstation adddrawrectangleticks: per-row cost x drawn height of the rect intersected with the drawing area (a disjoint rect costs zero).
function GPU:addDrawRectangleTicks(x, y, w, h, textured, semiTransparent)
	local left, right = self.drawLeft, self.drawRight
	local top, bottom = self.drawTop, self.drawBottom
	if left > right or top > bottom then return end
	local ix0 = math.max(x, left)
	local ix1 = math.min(x + w - 1, right)
	local iy0 = math.max(y, top)
	local iy1 = math.min(y + h - 1, bottom)
	local drawnWidth = ix1 - ix0 + 1
	local drawnHeight = iy1 - iy0 + 1
	if drawnWidth <= 0 or drawnHeight <= 0 then return end
	local ticksPerRow = drawnWidth
	if textured then
		-- textured-rect overhead is the texture-cache reload per row (duckstation): 4bpp adds one width per row; 8bpp/direct15 switch to a reload term once width > 128 or the area exceeds the cache.
		local texMode = band(rshift(self.drawModeReg, 7), 3)
		if texMode == 1 then
			-- Palette8Bit.
			if drawnWidth > 128 then
				ticksPerRow += (drawnWidth // 4) * 8
			elseif drawnWidth * drawnHeight > 2048 then
				ticksPerRow += (drawnWidth // 4) * (4 * (128 // drawnWidth))
			else
				ticksPerRow += drawnWidth
			end
		elseif texMode == 2 or texMode == 3 then
			-- Direct16Bit (and the reserved direct15 mode).
			if drawnWidth > 128 then
				ticksPerRow += (drawnWidth // 2) * 8
			elseif drawnWidth * drawnHeight > 1024 then
				ticksPerRow += (drawnWidth // 4) * (8 * (128 // drawnWidth))
			else
				ticksPerRow += drawnWidth
			end
		else
			-- Palette4Bit.
			ticksPerRow += drawnWidth
		end
	end
	if semiTransparent or self.maskCheck then
		ticksPerRow += (drawnWidth + 1) // 2
	end
	self:addCommandTicks(ticksPerRow * drawnHeight)
end

-- duckstation adddrawlineticks: max(width, height) of the clamped segment.
function GPU:addDrawLineTicks(ax, ay, bx, by)
	local left, right = self.drawLeft, self.drawRight
	local top, bottom = self.drawTop, self.drawBottom
	if left > right or top > bottom then return end
	local function clamp(v, lo, hi)
		if v < lo then return lo elseif v > hi then return hi end
		return v
	end
	local ix0 = clamp(math.min(ax, bx), left, right)
	local ix1 = clamp(math.max(ax, bx), left, right)
	local iy0 = clamp(math.min(ay, by), top, bottom)
	local iy1 = clamp(math.max(ay, by), top, bottom)
	local w = ix1 - ix0 + 1
	local h = iy1 - iy0 + 1
	if w <= 0 or h <= 0 then return end
	self:addCommandTicks(math.max(w, h))
end

function GPU:setConsoleRegion(isPal)
	self.cyclesPerFrame = isPal and 677376 or 564480
end

function GPU:step(cycles)
	cycles = cycles or 0
	if cycles <= 0 then
		return
	end

	-- fast path: skip when no pending draw time and no frame boundary imminent.
	-- this is the common case during non-rendering code.
	if self.pendingCycles <= 0 and self.frameCycleCounter + cycles < self.cyclesPerFrame then
		self.frameCycleCounter += cycles
		return
	end

	-- drain the modeled command/draw time (duckstation commandtickevent: the
	-- gpu finishes pending commands as time advances).
	if self.pendingCycles > 0 then
		self.pendingCycles -= cycles
		if self.pendingCycles < 0 then
			self.pendingCycles = 0
		end
		invalidateStatus(self)
	end

	self.frameCycleCounter += cycles
	while self.frameCycleCounter >= self.cyclesPerFrame do
		self.frameCycleCounter -= self.cyclesPerFrame
		self.status = bxor(self.status, 0x80000000)
		invalidateStatus(self)
		if self.recordHook then self.recordHook("frame") end
	end
end

function GPU:read(address)
	if address == 0x1F801810 then
		if self.recordHook then self.recordHook("gpuread") end
		if self.gp0mode == "vramToCpu" then
			-- readingvram words cost modeled gpu time (2 cycles per 32-bit word).
			self:addCommandTicks(2)
			local p0 = self:vpeek(self.vcX + self.vcPX, self.vcY + self.vcPY)
			self.vcPX+=1; if self.vcPX>=self.vcW then self.vcPX=0; self.vcPY+=1 end
			local p1 = self:vpeek(self.vcX + self.vcPX, self.vcY + self.vcPY)
			self.vcPX+=1; if self.vcPX>=self.vcW then self.vcPX=0; self.vcPY+=1; if self.vcPY>=self.vcH then self.gp0mode="cmd"; invalidateStatus(self) end end
			return bor(p0, lshift(p1, 16))
		end
		return self.gpuread
	elseif address == 0x1F801814 then return composeStatus(self) end
	-- unused gpu register lanes (0x818-0x81f) read open bus (duckstation)
	return 0xFFFFFFFF
end

function GPU:write(address, value)
	value = band(value, 0xFFFFFFFF)
	if address == 0x1F801810 then self:writeGp0(value)
	elseif address == 0x1F801814 then self:writeGp1(value) end
end

-- capture display area as rgba byte table (width × height × 4 bytes) for client display
function GPU:captureFrame()
	local sx = self.displayStartX; local sy = self.displayStartY
	local w  = self.displayWidth;  local h  = self.displayHeight
	local pixels = table.create(w * h * 4)
	local idx = 1
	for fy = 0, h - 1 do
		for fx = 0, w - 1 do
			local c = self:vpeek(sx + fx, sy + fy)
			pixels[idx]   = rgb15r(c)
			pixels[idx+1] = rgb15g(c)
			pixels[idx+2] = rgb15b(c)
			pixels[idx+3] = 255
			idx += 4
		end
	end
	return pixels, w, h
end

return GPU