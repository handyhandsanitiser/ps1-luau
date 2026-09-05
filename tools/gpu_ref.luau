-- standalone gpu model for renderer checks, with its own vram so mistakes don't cancel between
-- the two implementations.  interlace and pgxp are outside the model; the integer stuff below is
-- not: fixed-point dda, signed coordinates, wrapping, and dithering all matter.

local GPU_REF = {}
GPU_REF.__index = GPU_REF

local band = bit32.band
local bor  = bit32.bor
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift
local bnot = bit32.bnot

local VRAM_W = 1024
local VRAM_H = 512
local VRAM_W_MASK = 0x3FF
local VRAM_H_MASK = 0x1FF
local MAX_PRIMITIVE_WIDTH = 1024
local MAX_PRIMITIVE_HEIGHT = 512

local ATTRIB_SHIFT = 12
local ATTRIB_POST_SHIFT = 12

-- c++ s32/s64 division truncates toward zero (for all sign combinations).
local function divTrunc(n, d)
	local q = n / d
	if q >= 0 then return math.floor(q) end
	return math.ceil(q)
end

-- signextendn<11, s32>
local function sx11(v)
	v = band(v, 0x7FF)
	if v >= 0x400 then v = v - 0x800 end
	return v
end

-- truncategpuvertexposition (sx11) on an s32 value.
local function truncVertexPos(x)
	return sx11(x)
end

-- s32 wrap: convert a lua number (possibly > 2^31) to signed 32-bit.
local function s32(v)
	v = band(v, 0xFFFFFFFF)
	if v >= 0x80000000 then v = v - 0x100000000 end
	return v
end

-- u32 wrap.
local function u32(v)
	return band(v, 0xFFFFFFFF)
end

-- truncate8 / truncate16
local function t8(v) return band(v, 0xFF) end
local function t16(v) return band(v, 0xFFFF) end

-- vramrgba8888torgba5551
local function rgb888to5551(color)
	local r = rshift(band(color, 0xFF), 3)
	local g = rshift(band(rshift(color, 8), 0xFF), 3)
	local b = rshift(band(rshift(color, 16), 0xFF), 3)
	local a = band(rshift(color, 24), 1)
	return band(bor(r, lshift(g, 5), lshift(b, 10), lshift(a, 15)), 0xFFFF)
end

-- dither lut: lut[i][j][v] = clamp((v + matrix[i][j]) >> 3, 0, 31),
-- computed with c++ arithmetic-shift semantics (floor for negatives).
local DITHER_MATRIX = {
	{ -4, 0, -3, 1 },
	{ 2, -2, 3, -1 },
	{ -3, 1, -4, 0 },
	{ 3, -1, 2, -2 },
}
local ditherLut = table.create(4 * 4 * 512)
do
	for i = 0, 3 do
		for j = 0, 3 do
			for v = 0, 511 do
				ditherLut[i * 2048 + j * 512 + v + 1] = math.max(0, math.min(31, math.floor((v + DITHER_MATRIX[i + 1][j + 1]) / 8)))
			end
		end
	end
end
local function ditherValue(i, j, v)
	return ditherLut[i * 2048 + j * 512 + v + 1]
end

-- gp0 word counts (duckstation command sizing; 255 = polyline).
local GP0_WORDS = {
	[0x00] = 1, [0x01] = 1, [0x02] = 3,
	[0x20] = 4, [0x21] = 4, [0x22] = 4, [0x23] = 4,
	[0x24] = 7, [0x25] = 7, [0x26] = 7, [0x27] = 7,
	[0x28] = 5, [0x29] = 5, [0x2A] = 5, [0x2B] = 5,
	[0x2C] = 9, [0x2D] = 9, [0x2E] = 9, [0x2F] = 9,
	[0x30] = 6, [0x31] = 6, [0x32] = 6, [0x33] = 6,
	[0x34] = 9, [0x35] = 9, [0x36] = 9, [0x37] = 9,
	[0x38] = 8, [0x39] = 8, [0x3A] = 8, [0x3B] = 8,
	[0x3C] = 12, [0x3D] = 12, [0x3E] = 12, [0x3F] = 12,
	[0x40] = 3, [0x41] = 3, [0x42] = 3, [0x43] = 3,
	[0x44] = 4, [0x45] = 4, [0x46] = 4, [0x47] = 4,
	[0x48] = 255, [0x49] = 255, [0x4A] = 255, [0x4B] = 255,
	[0x4C] = 255, [0x4D] = 255, [0x4E] = 255, [0x4F] = 255,
	[0x50] = 255, [0x51] = 255, [0x52] = 255, [0x53] = 255,
	[0x54] = 255, [0x55] = 255, [0x56] = 255, [0x57] = 255,
	[0x58] = 255, [0x59] = 255, [0x5A] = 255, [0x5B] = 255,
	[0x5C] = 255, [0x5D] = 255, [0x5E] = 255, [0x5F] = 255,
	[0x60] = 3, [0x61] = 3, [0x62] = 3, [0x63] = 3,
	[0x64] = 4, [0x65] = 4, [0x66] = 4, [0x67] = 4,
	[0x68] = 2, [0x69] = 2, [0x6A] = 2, [0x6B] = 2,
	[0x6C] = 3, [0x6D] = 3, [0x6E] = 3, [0x6F] = 3,
	[0x70] = 3, [0x71] = 3, [0x72] = 3, [0x73] = 3,
	[0x74] = 4, [0x75] = 4, [0x76] = 4, [0x77] = 4,
	[0x78] = 3, [0x79] = 3, [0x7A] = 3, [0x7B] = 3,
	[0x7C] = 4, [0x7D] = 4, [0x7E] = 4, [0x7F] = 4,
	[0x80] = 4, [0xA0] = 3, [0xC0] = 3,
	[0xE1] = 1, [0xE2] = 1, [0xE3] = 1, [0xE4] = 1, [0xE5] = 1, [0xE6] = 1,
}

-- 11-bit signed vertex position from a word (gpuvertexposition).
local function vertexPos(word)
	local vx = sx11(band(word, 0x7FF))
	local vy = sx11(band(rshift(word, 16), 0x7FF))
	return vx, vy
end

function GPU_REF.new()
	local self = setmetatable({}, GPU_REF)
	self.vram = table.create(VRAM_W * VRAM_H, 0)
	self.clut = table.create(256, 0) -- g_gpu_clut
	self.fifo = {} -- GP0 FIFO (words)
	self.gp0needed = 0
	self.polylineBuffer = {}
	self.blitBuffer = {}
	self.blitRemaining = 0
	self.blitterState = "idle" -- idle | writingVRAM | readingVRAM | drawingPolyLine
	self.vramTransfer = { x = 0, y = 0, width = 0, height = 0, col = 0, row = 0 }
	-- differential vram write log (set by the harness; nil = off): flat { firstIndex, count, ... } spans of words written since the last compare (same contract as the core).
	self.vramLog = nil
	-- drawing state
	self.drawModeReg = 0      -- GPUDrawModeReg bits
	self.texturePaletteReg = 0 -- GPUTexturePaletteReg bits
	self.textureWindow = { andX = 0xFF, andY = 0xFF, orX = 0, orY = 0 }
	self.drawingArea = { left = 0, top = 0, right = 0, bottom = 0 }
	self.drawingOffset = { x = 0, y = 0 }
	self.gpustat = 0x14802000
	self.renderCommand = 0
	self.setTextureDisableMask = false
	self.textureEnableMask = true
	self.currentClutRegBits = nil
	self.currentClutIs8bit = false
	self.forceProgressiveScan = true -- interlaced field-skip disabled (see header)
	self.gpuread = 0 -- gp1(10h) get-gpu-info readback
	return self
end

-- drawing state

function GPU_REF:setDrawMode(value)
	value = band(value, 0x1FFF) -- GPUDrawModeReg::MASK = 13 bits
	if not self.setTextureDisableMask then
		value = band(value, bnot(0x800)) -- texture_disable forced false
	end
	self.drawModeReg = value
	-- gpustat bits 0..10 mirror the draw mode; bit 15 = texture disable.
	local gpustatMask = 0x7FF
	self.gpustat = band(self.gpustat, bnot(gpustatMask)) or 0
	self.gpustat = bor(self.gpustat, band(value, gpustatMask))
	self.gpustat = band(self.gpustat, bnot(0x8000))
	self.gpustat = bor(self.gpustat, lshift(band(value, 0x800) ~= 0 and 1 or 0, 15))
end

function GPU_REF:setTexturePalette(value)
	self.texturePaletteReg = band(value, 0x7FFF)
end

function GPU_REF:setTextureWindow(value)
	value = band(value, 0xFFFFF) -- 20-bit mask
	local maskX = t8(value)
	local maskY = t8(rshift(value, 5))
	local offsetX = t8(rshift(value, 10))
	local offsetY = t8(rshift(value, 15))
	self.textureWindow.andX = band(bnot(maskX * 8), 0xFF)
	self.textureWindow.andY = band(bnot(maskY * 8), 0xFF)
	self.textureWindow.orX = band(offsetX * 8, band(maskX * 8, 0xFF))
	self.textureWindow.orY = band(offsetY * 8, band(maskY * 8, 0xFF))
end

-- clut caching (updateclutifneeded): reload vram clut rows into self.clut.
function GPU_REF:updateCLUTIfNeeded(texmode, clutBits)
	if texmode >= 2 then return end -- Direct16Bit and above
	local needs8bit = texmode == 1
	if clutBits ~= self.currentClutRegBits or (needs8bit and not self.currentClutIs8bit) then
		self.currentClutRegBits = clutBits
		self.currentClutIs8bit = needs8bit
		local reg = clutBits
		local yBase = band(rshift(reg, 6), 0x1FF)
		local xBase = band(reg, 0x3F) * 16
		local row = yBase * VRAM_W
		if not needs8bit then
			for i = 0, 15 do
				self.clut[i + 1] = self.vram[row + xBase + i + 1] or 0
			end
		else
			if xBase + 256 <= VRAM_W then
				for i = 0, 255 do
					self.clut[i + 1] = self.vram[row + xBase + i + 1] or 0
				end
			else
				local endN = VRAM_W - xBase
				for i = 0, endN - 1 do
					self.clut[i + 1] = self.vram[row + xBase + i + 1] or 0
				end
				for i = endN, 255 do
					self.clut[i + 1] = self.vram[row + (i - endN) + 1] or 0
				end
			end
		end
	end
end

function GPU_REF:invalidateCLUT()
	self.currentClutRegBits = 0xFFFF
	self.currentClutIs8bit = false
end

-- command decoding

-- filldrawcommand shared state.  returns the command table.
function GPU_REF:fillDrawCommand(rc, isLine)
	local cmd = {}
	cmd.interlacedRendering = false -- progressive
	cmd.activeLineLsb = 0
	cmd.checkMaskBeforeDraw = band(self.gpustat, 0x1000) ~= 0
	cmd.setMaskWhileDrawing = band(self.gpustat, 0x800) ~= 0
	local textureEnable = (not isLine) and (band(rc, 0x4000000) ~= 0) and self.textureEnableMask
	local rawTextureEnable = textureEnable and (band(rc, 0x1000000) ~= 0)
	cmd.textureEnable = textureEnable
	cmd.rawTextureEnable = rawTextureEnable
	cmd.transparencyEnable = band(rc, 0x2000000) ~= 0
	cmd.shadingEnable = band(rc, 0x10000000) ~= 0
	cmd.quadPolygon = band(rc, 0x8000000) ~= 0
	cmd.ditherEnable = band(self.drawModeReg, 0x200) ~= 0
	cmd.drawModeBits = self.drawModeReg
	cmd.paletteBits = self.texturePaletteReg
	cmd.windowAndX = self.textureWindow.andX
	cmd.windowAndY = self.textureWindow.andY
	cmd.windowOrX = self.textureWindow.orX
	cmd.windowOrY = self.textureWindow.orY
	return cmd
end

local function getTexturePageBaseX(bits)
	return band(bits, 0xF) * 64
end
local function getTexturePageBaseY(bits)
	return band(rshift(bits, 4), 1) * 256
end

-- texpage/clut peek positions for polygons (duckstation peeks the second
-- vertex's texcoord for the texpage and the first vertex's for the clut).
local function peekPolygonTexpage(rc, fifo)
	local shaded = band(rc, 0x10000000) ~= 0
	return band(rshift(fifo[shaded and 6 or 5] or 0, 16), 0xFFFF)
end
local function peekPolygonClut(fifo)
	return band(rshift(fifo[3] or 0, 16), 0xFFFF)
end

-- unpack a vertex's 24-bit color into 8-bit r/g/b (and texcoord into u/v).
-- duckstation keeps these fields on gpubackenddrawpolygoncommand::vertex.
local function unpackVertex(v)
	local color = v.color or 0
	v.r = band(color, 0xFF)
	v.g = band(rshift(color, 8), 0xFF)
	v.b = band(rshift(color, 16), 0xFF)
	local tc = v.texcoord or 0
	v.u = band(tc, 0xFF)
	v.v = band(rshift(tc, 8), 0xFF)
end

function GPU_REF:handlePolygon(rc)
	local wordsPerVertex = 1
	if band(rc, 0x4000000) ~= 0 then wordsPerVertex += 1 end
	if band(rc, 0x10000000) ~= 0 then wordsPerVertex += 1 end
	local numVertices = band(rc, 0x8000000) ~= 0 and 4 or 3
	local totalWords = wordsPerVertex * numVertices
	if band(rc, 0x10000000) == 0 then totalWords += 1 end
	if #self.fifo < totalWords then return false end

	if band(rc, 0x4000000) ~= 0 then
		local texpageAttr = peekPolygonTexpage(rc, self.fifo)
		-- (texpage & polygon_texpage_mask) | (drawmode & ~polygon_texpage_mask)
		-- polygon_texpage_mask = 0b0000100111111111
		local merged = bor(band(texpageAttr, 0x9FF), band(self.drawModeReg, bnot(0x9FF)))
		self:setDrawMode(merged)
		self:setTexturePalette(peekPolygonClut(self.fifo))
		self:updateCLUTIfNeeded(band(rshift(merged, 7), 3), self.texturePaletteReg)
	end

	self.renderCommand = rc
	table.remove(self.fifo, 1) -- command word

	local cmd = self:fillDrawCommand(rc, false)
	-- duckstation: polygons dither only when shaded or texture-modulated; flat/raw-textured polygons never dither.
	cmd.ditherEnable = cmd.ditherEnable and (cmd.shadingEnable or (cmd.textureEnable and not cmd.rawTextureEnable))
	local firstColor = band(rc, 0xFFFFFF)
	local shaded = band(rc, 0x10000000) ~= 0
	local textured = band(rc, 0x4000000) ~= 0
	local vertices = {}
	for i = 0, numVertices - 1 do
		local v = {}
		if shaded and i > 0 then
			v.color = band(self.fifo[1] or 0, 0xFFFFFF)
			table.remove(self.fifo, 1)
		else
			v.color = firstColor
		end
		local posWord = table.remove(self.fifo, 1) or 0
		local px, py = vertexPos(posWord)
		v.x = self.drawingOffset.x + px
		v.y = self.drawingOffset.y + py
		v.texcoord = textured and (table.remove(self.fifo, 1) or 0) or 0
		unpackVertex(v)
		vertices[i + 1] = v
	end

	-- cull too-large polygons (duckstation: rect > max_primitive).
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
		if not cmd.quadPolygon then return true end
	end
	if not firstCulled then
		self:drawTriangle(cmd, v0, v1, v2)
	end
	if cmd.quadPolygon then
		local v3 = vertices[4]
		local secondCulled = triCulled(v2, v1, v3)
		if not secondCulled then
			-- quad second triangle: (v2, v1, v3)
			self:drawTriangle(cmd, v2, v1, v3)
		end
	end
	return true
end

function GPU_REF:handleRectangle(rc)
	local totalWords = 2
	if band(rc, 0x4000000) ~= 0 then totalWords += 1 end
	-- duckstation: the wh word is present only for variable-size rectangles (rectangle_size bits 27-28 == 0); bits 23-24 overlap the color and must not be used.
	if band(rshift(rc, 27), 3) == 0 then totalWords += 1 end -- variable size
	if #self.fifo < totalWords then return false end

	if band(rc, 0x4000000) ~= 0 then
		self:setTexturePalette(band(rshift(self.fifo[3] or 0, 16), 0xFFFF))
		self:updateCLUTIfNeeded(band(rshift(self.drawModeReg, 7), 3), self.texturePaletteReg)
	end

	self.renderCommand = rc
	table.remove(self.fifo, 1)

	local cmd = self:fillDrawCommand(rc, false)
	-- duckstation: rectangles (sprites) never dither, regardless of the
	-- draw-mode bit.
	cmd.ditherEnable = false
	cmd.color = band(rc, 0xFFFFFF)
	local posWord = table.remove(self.fifo, 1) or 0
	local px, py = vertexPos(posWord)
	cmd.x = truncVertexPos(self.drawingOffset.x + px)
	cmd.y = truncVertexPos(self.drawingOffset.y + py)

	if band(rc, 0x4000000) ~= 0 then
		local uvPal = table.remove(self.fifo, 1) or 0
		cmd.paletteBits = band(rshift(uvPal, 16), 0xFFFF)
		cmd.texcoord = t16(uvPal)
	else
		cmd.paletteBits = 0
		cmd.texcoord = 0
	end

	local size = band(rshift(rc, 27), 3)
	if size == 1 then
		cmd.width, cmd.height = 1, 1
	elseif size == 2 then
		cmd.width, cmd.height = 8, 8
	elseif size == 3 then
		cmd.width, cmd.height = 16, 16
	else
		local wh = table.remove(self.fifo, 1) or 0
		cmd.width = t16(band(wh, VRAM_W_MASK))
		cmd.height = t16(band(rshift(wh, 16), VRAM_H_MASK))
	end

	self:drawRectangle(cmd)
	return true
end

function GPU_REF:handleLine(rc)
	local totalWords = band(rc, 0x10000000) ~= 0 and 4 or 3
	if #self.fifo < totalWords then return false end

	self.renderCommand = rc
	table.remove(self.fifo, 1)

	local cmd = self:fillDrawCommand(rc, true)
	cmd.paletteBits = 0
	if band(rc, 0x10000000) ~= 0 then
		cmd.vertices = {}
		local v0 = {}
		v0.color = band(rc, 0xFFFFFF)
		local pos0 = table.remove(self.fifo, 1) or 0
		local p0x, p0y = vertexPos(pos0)
		v0.x = self.drawingOffset.x + p0x
		v0.y = self.drawingOffset.y + p0y
		unpackVertex(v0)
		cmd.vertices[1] = v0
		local v1 = {}
		v1.color = band(table.remove(self.fifo, 1) or 0, 0xFFFFFF)
		local pos1 = table.remove(self.fifo, 1) or 0
		local p1x, p1y = vertexPos(pos1)
		v1.x = self.drawingOffset.x + p1x
		v1.y = self.drawingOffset.y + p1y
		unpackVertex(v1)
		cmd.vertices[2] = v1
	else
		cmd.vertices = {}
		local c = band(rc, 0xFFFFFF)
		local v0 = { color = c }
		local pos0 = table.remove(self.fifo, 1) or 0
		local p0x, p0y = vertexPos(pos0)
		v0.x = self.drawingOffset.x + p0x
		v0.y = self.drawingOffset.y + p0y
		unpackVertex(v0)
		cmd.vertices[1] = v0
		local v1 = { color = c }
		local pos1 = table.remove(self.fifo, 1) or 0
		local p1x, p1y = vertexPos(pos1)
		v1.x = self.drawingOffset.x + p1x
		v1.y = self.drawingOffset.y + p1y
		unpackVertex(v1)
		cmd.vertices[2] = v1
	end
	self:drawLine(cmd, cmd.vertices[1], cmd.vertices[2])
	return true
end

function GPU_REF:handlePolyLine(rc)
	-- buffered until the terminator arrives (see gp0word); the buffer
	-- holds the first min_words-1 words after the command.
	local shaded = band(rc, 0x10000000) ~= 0
	local minWords = shaded and 3 or 4
	-- need the command plus min_words-1 payload words before committing: check depth before consuming the command (duckstation checks with the command still in the fifo), or a short polyline parks with an empty fifo and reads as "settled".
	if #self.fifo < minWords then return false end
	self.renderCommand = rc
	table.remove(self.fifo, 1)
	for _ = 1, minWords - 1 do
		table.insert(self.polylineBuffer, table.remove(self.fifo, 1))
	end
	-- the blind min_words-1 buffering can swallow a valid short polyline's terminator: psx-spx allows two-vertex polylines, so if the last buffered word is the terminator, drop it and finish immediately.
	if band(self.polylineBuffer[#self.polylineBuffer] or 0, 0xF000F000) == 0x50005000 then
		table.remove(self.polylineBuffer)
		self:finishPolyLine()
		return true
	end
	self.blitterState = "drawingPolyLine"
	return true
end

function GPU_REF:finishPolyLine()
	local shaded = band(self.renderCommand, 0x10000000) ~= 0
	local numVertices = (#self.polylineBuffer + (shaded and 1 or 0))
	if shaded then numVertices = rshift(numVertices, 1) end
	if numVertices < 2 then
		self.polylineBuffer = {}
		self.blitterState = "idle"
		return
	end

	local cmd = self:fillDrawCommand(self.renderCommand, true)
	cmd.paletteBits = 0
	local bufferPos = 1
	local startVp = self.polylineBuffer[bufferPos]
	bufferPos += 1
	local sx, sy = vertexPos(startVp)
	local startPos = { x = self.drawingOffset.x + sx, y = self.drawingOffset.y + sy }
	local startColor = band(self.renderCommand, 0xFFFFFF)
	local firstColor = startColor

	for i = 1, numVertices - 1 do
		local endColor
		if shaded then
			endColor = band(self.polylineBuffer[bufferPos] or 0, 0xFFFFFF)
			bufferPos += 1
		else
			endColor = firstColor
		end
		local vp = self.polylineBuffer[bufferPos]
		bufferPos += 1
		local ex, ey = vertexPos(vp)
		local endPos = { x = self.drawingOffset.x + ex, y = self.drawingOffset.y + ey }
		-- cull too-large segment
		local minX = math.min(startPos.x, endPos.x)
		local maxX = math.max(startPos.x, endPos.x)
		local minY = math.min(startPos.y, endPos.y)
		local maxY = math.max(startPos.y, endPos.y)
		if (maxX - minX + 1) <= MAX_PRIMITIVE_WIDTH and (maxY - minY + 1) <= MAX_PRIMITIVE_HEIGHT then
			local vA = { x = startPos.x, y = startPos.y, color = startColor }
			local vB = { x = endPos.x, y = endPos.y, color = endColor }
			unpackVertex(vA)
			unpackVertex(vB)
			self:drawLine(cmd, vA, vB)
		end
		startPos = endPos
		startColor = endColor
	end

	self.polylineBuffer = {}
	self.blitterState = "idle"
end

function GPU_REF:handleFillRectangle()
	if #self.fifo < 3 then return false end
	-- duckstation: color comes from the command word (word 0); the fifo pop
	-- removes it before xy/wh are read.
	local color = band(self.fifo[1] or 0, 0xFFFFFF)
	table.remove(self.fifo, 1)
	local dstX = band(self.fifo[1] or 0, 0x3F0)
	local dstY = band(rshift(self.fifo[1] or 0, 16), VRAM_H_MASK)
	table.remove(self.fifo, 1)
	local width = band(band(self.fifo[1] or 0, VRAM_W_MASK) + 0xF, bnot(0xF))
	local height = band(rshift(self.fifo[1] or 0, 16), VRAM_H_MASK)
	table.remove(self.fifo, 1)
	if width > 0 and height > 0 then
		self:fillVRAM(dstX, dstY, width, height, color)
	end
	return true
end

function GPU_REF:handleCpuToVram()
	if #self.fifo < 3 then return false end
	table.remove(self.fifo, 1)
	local coords = self.fifo[1] or 0
	local size = self.fifo[2] or 0
	table.remove(self.fifo, 1)
	table.remove(self.fifo, 1)
	if size == 0xFFFFFFFF then
		return true -- DuckStation skips invalid uploads
	end
	local dstX = band(coords, VRAM_W_MASK)
	local dstY = band(rshift(coords, 16), VRAM_H_MASK)
	local copyWidth = band(size, VRAM_W_MASK)
	if copyWidth == 0 then copyWidth = 0x400 end
	local copyHeight = band(rshift(size, 16), VRAM_H_MASK)
	if copyHeight == 0 then copyHeight = 0x200 end
	local numPixels = copyWidth * copyHeight
	local numWords = math.floor((numPixels + 1) / 2)
	self.blitterState = "writingVRAM"
	self.blitBuffer = {}
	self.blitRemaining = numWords
	self.vramTransfer.x = t16(dstX)
	self.vramTransfer.y = t16(dstY)
	self.vramTransfer.width = t16(copyWidth)
	self.vramTransfer.height = t16(copyHeight)
	return true
end

function GPU_REF:finishVramWrite()
	local width = self.vramTransfer.width
	local height = self.vramTransfer.height
	local x = self.vramTransfer.x
	local y = self.vramTransfer.y
	-- blitbuffer holds u16 pixels (two per word), little-endian halves.
	local pixels = table.create(width * height, 0)
	local n = 0
	for _, word in ipairs(self.blitBuffer) do
		pixels[n + 1] = t16(word)
		pixels[n + 2] = t16(rshift(word, 16))
		n += 2
	end
	self:writeVRAM(x, y, width, height, pixels,
		band(self.gpustat, 0x800) ~= 0, band(self.gpustat, 0x1000) ~= 0)
	self.blitterState = "idle"
end

function GPU_REF:handleVramToCpu()
	if #self.fifo < 3 then return false end
	table.remove(self.fifo, 1)
	local x = t16(band(self.fifo[1] or 0, VRAM_W_MASK))
	local y = t16(band(rshift(self.fifo[1] or 0, 16), VRAM_H_MASK))
	table.remove(self.fifo, 1)
	local width = t16(band(t16(self.fifo[1] or 0) - 1, VRAM_W_MASK)) + 1
	local height = t16(band(t16(rshift(self.fifo[1] or 0, 16)) - 1, VRAM_H_MASK)) + 1
	table.remove(self.fifo, 1)
	self.vramTransfer.x = x
	self.vramTransfer.y = y
	self.vramTransfer.width = width
	self.vramTransfer.height = height
	self.vramTransfer.col = 0
	self.vramTransfer.row = 0
	self.blitterState = "readingVRAM"
	return true
end

function GPU_REF:handleVramToVram()
	if #self.fifo < 4 then return false end
	table.remove(self.fifo, 1)
	local srcX = band(self.fifo[1] or 0, VRAM_W_MASK)
	local srcY = band(rshift(self.fifo[1] or 0, 16), VRAM_H_MASK)
	table.remove(self.fifo, 1)
	local dstX = band(self.fifo[1] or 0, VRAM_W_MASK)
	local dstY = band(rshift(self.fifo[1] or 0, 16), VRAM_H_MASK)
	table.remove(self.fifo, 1)
	local width = band(self.fifo[1] or 0, VRAM_W_MASK)
	if width == 0 then width = 0x400 end
	local height = band(rshift(self.fifo[1] or 0, 16), VRAM_H_MASK)
	if height == 0 then height = 0x200 end
	table.remove(self.fifo, 1)
	local skip = width == 0 or height == 0
		or (srcX == dstX and srcY == dstY and band(self.gpustat, 0x800) == 0)
	if not skip then
		self:copyVRAM(srcX, srcY, dstX, dstY, width, height,
			band(self.gpustat, 0x800) ~= 0, band(self.gpustat, 0x1000) ~= 0)
	end
	return true
end

function GPU_REF:handleNop()
	table.remove(self.fifo, 1)
	return true
end

-- gp0(01h) clear cache: invalidates the clut cache (games upload new clut data, clear, and redraw with the same texpage).
function GPU_REF:handleClearCache()
	if #self.fifo < 1 then return false end
	table.remove(self.fifo, 1)
	self:invalidateCLUT()
	return true
end

function GPU_REF:handleE1()
	if #self.fifo < 1 then return false end
	self:setDrawMode(t16(self.fifo[1] or 0))
	table.remove(self.fifo, 1)
	return true
end

function GPU_REF:handleE2()
	if #self.fifo < 1 then return false end
	self:setTextureWindow(self.fifo[1] or 0)
	table.remove(self.fifo, 1)
	return true
end

function GPU_REF:handleE3()
	if #self.fifo < 1 then return false end
	local param = self.fifo[1] or 0
	self.drawingArea.left = band(param, 0x3FF)
	self.drawingArea.top = band(rshift(param, 10), 0x1FF)
	table.remove(self.fifo, 1)
	return true
end

function GPU_REF:handleE4()
	if #self.fifo < 1 then return false end
	local param = self.fifo[1] or 0
	self.drawingArea.right = band(param, 0x3FF)
	self.drawingArea.bottom = band(rshift(param, 10), 0x1FF)
	table.remove(self.fifo, 1)
	return true
end

function GPU_REF:handleE5()
	if #self.fifo < 1 then return false end
	local param = self.fifo[1] or 0
	self.drawingOffset.x = sx11(band(param, 0x7FF))
	self.drawingOffset.y = sx11(band(rshift(param, 11), 0x7FF))
	table.remove(self.fifo, 1)
	return true
end

function GPU_REF:handleE6()
	if #self.fifo < 1 then return false end
	local param = self.fifo[1] or 0
	local mask = 0x1800
	local bits = lshift(band(param, 0x3), 11)
	self.gpustat = bor(band(self.gpustat, bnot(mask)), bits)
	table.remove(self.fifo, 1)
	return true
end

local GP0_HANDLERS = {
	[0x00] = "nop", [0x01] = "clearCache", [0x02] = "fillRect",
	[0x20] = "poly", [0x21] = "poly", [0x22] = "poly", [0x23] = "poly",
	[0x24] = "poly", [0x25] = "poly", [0x26] = "poly", [0x27] = "poly",
	[0x28] = "poly", [0x29] = "poly", [0x2A] = "poly", [0x2B] = "poly",
	[0x2C] = "poly", [0x2D] = "poly", [0x2E] = "poly", [0x2F] = "poly",
	[0x30] = "poly", [0x31] = "poly", [0x32] = "poly", [0x33] = "poly",
	[0x34] = "poly", [0x35] = "poly", [0x36] = "poly", [0x37] = "poly",
	[0x38] = "poly", [0x39] = "poly", [0x3A] = "poly", [0x3B] = "poly",
	[0x3C] = "poly", [0x3D] = "poly", [0x3E] = "poly", [0x3F] = "poly",
	[0x40] = "line", [0x41] = "line", [0x42] = "line", [0x43] = "line",
	[0x44] = "line", [0x45] = "line", [0x46] = "line", [0x47] = "line",
	[0x48] = "polyline", [0x49] = "polyline", [0x4A] = "polyline", [0x4B] = "polyline",
	[0x4C] = "polyline", [0x4D] = "polyline", [0x4E] = "polyline", [0x4F] = "polyline",
	[0x50] = "line", [0x51] = "line", [0x52] = "line", [0x53] = "line",
	[0x54] = "line", [0x55] = "line", [0x56] = "line", [0x57] = "line",
	[0x58] = "polyline", [0x59] = "polyline", [0x5A] = "polyline", [0x5B] = "polyline",
	[0x5C] = "polyline", [0x5D] = "polyline", [0x5E] = "polyline", [0x5F] = "polyline",
	[0x60] = "rect", [0x61] = "rect", [0x62] = "rect", [0x63] = "rect",
	[0x64] = "rect", [0x65] = "rect", [0x66] = "rect", [0x67] = "rect",
	[0x68] = "rect", [0x69] = "rect", [0x6A] = "rect", [0x6B] = "rect",
	[0x6C] = "rect", [0x6D] = "rect", [0x6E] = "rect", [0x6F] = "rect",
	[0x70] = "rect", [0x71] = "rect", [0x72] = "rect", [0x73] = "rect",
	[0x74] = "rect", [0x75] = "rect", [0x76] = "rect", [0x77] = "rect",
	[0x78] = "rect", [0x79] = "rect", [0x7A] = "rect", [0x7B] = "rect",
	[0x7C] = "rect", [0x7D] = "rect", [0x7E] = "rect", [0x7F] = "rect",
	[0x80] = "v2v", [0xA0] = "c2v", [0xC0] = "v2c",
	[0xE1] = "e1", [0xE2] = "e2", [0xE3] = "e3", [0xE4] = "e4", [0xE5] = "e5", [0xE6] = "e6",
}

-- gp0 word ingestion

function GPU_REF:gp0Word(word)
	word = u32(word)
	table.insert(self.fifo, word)
	local progress = true
	while progress and #self.fifo > 0 do
		progress = false
		if self.blitterState == "writingVRAM" then
			local wordsToCopy = math.min(self.blitRemaining, #self.fifo)
			for i = 1, wordsToCopy do
				table.insert(self.blitBuffer, table.remove(self.fifo, 1))
			end
			self.blitRemaining -= wordsToCopy
			if self.blitRemaining == 0 then
				self:finishVramWrite()
			end
			progress = true
		elseif self.blitterState == "drawingPolyLine" then
			local shaded = band(self.renderCommand, 0x10000000) ~= 0
			local wordsPerVertex = shaded and 2 or 1
			-- scan for terminator on vertex-first words
			local termIndex
			local startIdx = shaded and (band(#self.polylineBuffer, 1) == 1 and 0 or 1) or 0
			for idx = startIdx, #self.fifo - 1, wordsPerVertex do
				if band(self.fifo[idx + 1] or 0, 0xF000F000) == 0x50005000 then
					termIndex = idx
					break
				end
			end
			if termIndex ~= nil then
				for i = 1, termIndex do
					table.insert(self.polylineBuffer, table.remove(self.fifo, 1))
				end
				table.remove(self.fifo, 1) -- terminator
				self:finishPolyLine()
			else
				for i = 1, #self.fifo do
					table.insert(self.polylineBuffer, table.remove(self.fifo, 1))
				end
			end
			progress = true
		elseif self.blitterState == "readingVRAM" then
			progress = false
		else
			local command = rshift(band(self.fifo[1] or 0, 0xFF000000), 24)
			local handler = GP0_HANDLERS[command]
			if handler == "poly" then
				progress = self:handlePolygon(self.fifo[1])
			elseif handler == "rect" then
				progress = self:handleRectangle(self.fifo[1])
			elseif handler == "line" then
				progress = self:handleLine(self.fifo[1])
			elseif handler == "polyline" then
				progress = self:handlePolyLine(self.fifo[1])
			elseif handler == "fillRect" then
				progress = self:handleFillRectangle()
			elseif handler == "c2v" then
				progress = self:handleCpuToVram()
			elseif handler == "v2c" then
				progress = self:handleVramToCpu()
			elseif handler == "v2v" then
				progress = self:handleVramToVram()
	elseif handler == "clearCache" then
		progress = self:handleClearCache()
	elseif handler == "e1" then
		progress = self:handleE1()
			elseif handler == "e2" then
				progress = self:handleE2()
			elseif handler == "e3" then
				progress = self:handleE3()
			elseif handler == "e4" then
				progress = self:handleE4()
			elseif handler == "e5" then
				progress = self:handleE5()
			elseif handler == "e6" then
				progress = self:handleE6()
			else
				progress = self:handleNop()
			end
		end
	end
end

-- vram->cpu readout (one word = two pixels, row-major continuous).
function GPU_REF:readGpuData()
	local x = self.vramTransfer.x
	local y = self.vramTransfer.y
	local width = self.vramTransfer.width
	local height = self.vramTransfer.height
	local col = self.vramTransfer.col
	local row = self.vramTransfer.row
	local p0 = self.vram[((y + row) % VRAM_H) * VRAM_W + ((x + col) % VRAM_W) + 1] or 0
	col += 1
	if col >= width then
		col = 0
		row += 1
	end
	local p1 = self.vram[((y + row) % VRAM_H) * VRAM_W + ((x + col) % VRAM_W) + 1] or 0
	col += 1
	if col >= width then
		col = 0
		row += 1
	end
	self.vramTransfer.col = col
	self.vramTransfer.row = row
	if row >= height then
		self.blitterState = "idle"
	end
	return bor(p0, lshift(p1, 16))
end

-- gp1 commands

function GPU_REF:gp1(value)
	value = u32(value)
	local cmd = band(rshift(value, 24), 0xFF)
	local param = band(value, 0xFFFFFF)
	if cmd == 0x00 then -- reset
		self:softReset()
	elseif cmd == 0x01 then -- clear FIFO
		self:flushPartialVramWrite()
		self.fifo = {}
		self.blitterState = "idle"
	elseif cmd == 0x02 then -- ack interrupt
		self.gpustat = band(self.gpustat, bnot(0x1000000))
	elseif cmd == 0x03 then -- display disable
		if band(param, 1) ~= 0 then
			self.gpustat = bor(self.gpustat, 0x800000)
		else
			self.gpustat = band(self.gpustat, bnot(0x800000))
		end
	elseif cmd == 0x04 then -- DMA direction
		local dir = band(param, 3)
		self.gpustat = band(self.gpustat, bnot(0x60000000))
		self.gpustat = bor(self.gpustat, lshift(dir, 29))
	elseif cmd == 0x08 then -- display mode
		local mask = 0x007F4000 -- bits 14 (reverse) and 16-22 (display mode)
		local newBits = 0
		-- canonical gpustat mapping (psx-spx / duckstation): param 0-1 HR1 (17-18), 2 vres (19), 3 pal (20),
		-- 4 24bpp (21), 5 interlace (22), 6 HR2 (16), 7 reverse (14).  the tests are rshift-based
		-- (the old band(param, 5/6/7) forms tested multi-bit masks and misfired).
		newBits = bor(newBits, lshift(band(param, 3), 17))      -- horizontal_resolution_1
		newBits = bor(newBits, lshift(band(rshift(param, 2), 1), 19)) -- vertical_resolution
		newBits = bor(newBits, lshift(band(rshift(param, 3), 1), 20)) -- pal_mode
		newBits = bor(newBits, lshift(band(rshift(param, 4), 1), 21)) -- display_area_color_depth_24
		newBits = bor(newBits, lshift(band(rshift(param, 5), 1), 22)) -- vertical_interlace
		newBits = bor(newBits, lshift(band(rshift(param, 6), 1), 16)) -- horizontal_resolution_2
		newBits = bor(newBits, lshift(band(rshift(param, 7), 1), 14)) -- reverse_flag
		self.gpustat = bor(band(self.gpustat, bnot(mask)), band(newBits, mask))
	elseif cmd == 0x09 then -- allow texture disable
		self.setTextureDisableMask = band(param, 1) ~= 0
	elseif cmd == 0x10 then -- get gpu info
		local info = band(param, 7)
		if info == 2 then -- texture window setting
			local maskX = band(bnot(self.textureWindow.andX), 0xFF) // 8
			local maskY = band(bnot(self.textureWindow.andY), 0xFF) // 8
			self.gpuread = bor(maskX, lshift(maskY, 5))
		elseif info == 3 then -- drawing area top-left
			self.gpuread = bor(self.drawingArea.left, lshift(self.drawingArea.top, 10))
		elseif info == 4 then -- drawing area bottom-right
			self.gpuread = bor(self.drawingArea.right, lshift(self.drawingArea.bottom, 10))
		elseif info == 5 then -- drawing offset
			self.gpuread = bor(band(self.drawingOffset.x, 0x7FF), lshift(band(self.drawingOffset.y, 0x7FF), 11))
		end
	end
end

-- duckstation flushes a partially-transferred cpu->vram write on reset and gp1(01h) clear-fifo: the pixels already received stay in vram with the mask bits applied; the core streams into vram so it keeps the same pixels on abort.
function GPU_REF:flushPartialVramWrite()
	if self.blitterState ~= "writingVRAM" or #self.blitBuffer == 0 then
		return
	end
	local width = self.vramTransfer.width
	local x = self.vramTransfer.x
	local y = self.vramTransfer.y
	local setMask = band(self.gpustat, 0x800) ~= 0
	local checkMask = band(self.gpustat, 0x1000) ~= 0
	local pixels = table.create(#self.blitBuffer * 2, 0)
	local n = 0
	for _, word in ipairs(self.blitBuffer) do
		pixels[n + 1] = t16(word)
		pixels[n + 2] = t16(rshift(word, 16))
		n += 2
	end
	local fullRows = n // width
	local last = n % width
	if fullRows > 0 then
		local rows = table.create(fullRows * width, 0)
		for i = 1, fullRows * width do rows[i] = pixels[i] end
		self:writeVRAM(x, y, width, fullRows, rows, setMask, checkMask)
	end
	if last > 0 then
		local tail = table.create(last, 0)
		for i = 1, last do tail[i] = pixels[fullRows * width + i] end
		self:writeVRAM(x, y + fullRows, last, 1, tail, setMask, checkMask)
	end
	self.blitterState = "idle"
	self.blitBuffer = {}
end

function GPU_REF:softReset()
	self:flushPartialVramWrite()
	self.fifo = {}
	self.gp0needed = 0
	self.polylineBuffer = {}
	self.blitterState = "idle"
	self.drawModeReg = 0
	self.texturePaletteReg = 0
	self:setTextureWindow(0)
	self.drawingArea = { left = 0, top = 0, right = 0, bottom = 0 }
	self.drawingOffset = { x = 0, y = 0 }
	self.gpustat = 0x14802000
	self.setTextureDisableMask = false
	self.textureEnableMask = true
	self:invalidateCLUT()
end

function GPU_REF:step(cycles)
	-- frame-toggle only affects gpustat bit 31 (display readout), not vram.
end

-- record a vram write span for the differential (no-op when logging is off).
local function logVram(gpu, first, count)
	local vlog = gpu.vramLog
	if vlog then vlog[#vlog + 1] = first; vlog[#vlog + 1] = count end
end

-- rasterizer

local function getPixel(vram, x, y)
	return vram[band(y, VRAM_H_MASK) * VRAM_W + band(x, VRAM_W_MASK) + 1] or 0
end

function GPU_REF:shadePixel(cmd, x, y, r, g, b, u, v)
	local textureEnable = cmd.textureEnable
	local color
	if textureEnable then
		-- texture window
		u = bor(band(u, cmd.windowAndX), cmd.windowOrX)
		v = bor(band(v, cmd.windowAndY), cmd.windowOrY)
		local drawMode = cmd.drawModeBits
		local texMode = band(rshift(drawMode, 7), 3)
		local textureColor
		if texMode == 0 then -- Palette4Bit
			local paletteValue = getPixel(self.vram, getTexturePageBaseX(drawMode) + math.floor(u / 4),
				getTexturePageBaseY(drawMode) + v)
			local paletteIndex = band(rshift(paletteValue, band(u, 3) * 4), 0xF)
			textureColor = self.clut[paletteIndex + 1] or 0
		elseif texMode == 1 then -- Palette8Bit
			local paletteValue = getPixel(self.vram, getTexturePageBaseX(drawMode) + math.floor(u / 2),
				getTexturePageBaseY(drawMode) + v)
			local paletteIndex = band(rshift(paletteValue, band(u, 1) * 8), 0xFF)
			textureColor = self.clut[paletteIndex + 1] or 0
		else
			textureColor = getPixel(self.vram, getTexturePageBaseX(drawMode) + u,
				getTexturePageBaseY(drawMode) + v)
		end
		if textureColor == 0 then return end
		if not cmd.rawTextureEnable then
			local dithering = cmd.ditherEnable
			local dy = dithering and band(y, 3) or 2
			local dx = dithering and band(x, 3) or 3
			-- modulate8bit (modulation_crop = false)
			color = bor(
				ditherValue(dy, dx, math.floor((band(textureColor, 0x1F) * r) / 16)),
				lshift(ditherValue(dy, dx, math.floor((band(rshift(textureColor, 5), 0x1F) * g) / 16)), 5),
				lshift(ditherValue(dy, dx, math.floor((band(rshift(textureColor, 10), 0x1F) * b) / 16)), 10),
				band(textureColor, 0x8000))
		else
			color = textureColor -- NoModulation
		end
	else
		local dithering = cmd.ditherEnable
		local dy = dithering and band(y, 3) or 2
		local dx = dithering and band(x, 3) or 3
		color = bor(
			ditherValue(dy, dx, r),
			lshift(ditherValue(dy, dx, g), 5),
			lshift(ditherValue(dy, dx, b), 10))
		if cmd.transparencyEnable then
			color = bor(color, 0x8000)
		end
	end

	local bgColor = getPixel(self.vram, x, y)
	if cmd.transparencyEnable then
		if band(color, 0x8000) ~= 0 or not textureEnable then
			local bgBits = u32(bgColor)
			local fgBits = u32(color)
			local abr = band(rshift(cmd.drawModeBits, 5), 3)
			if abr == 0 then
				-- halfbackgroundplushalfforeground
				bgBits = bor(bgBits, 0x8000)
				color = t16(math.floor((u32(fgBits + bgBits) - band(bxor(fgBits, bgBits), 0x0421)) / 2))
			elseif abr == 1 then
				-- backgroundplusforeground (blargg)
				bgBits = band(bgBits, bnot(0x8000))
				local sum = u32(fgBits + bgBits)
				local carry = band(u32(sum - band(bxor(fgBits, bgBits), 0x8421)), 0x8420)
				color = t16(u32(bor(band(u32(sum - carry), 0xFFFF), u32(carry - rshift(carry, 5)))))
			elseif abr == 2 then
				-- backgroundminusforeground
				bgBits = bor(bgBits, 0x8000)
				fgBits = band(fgBits, bnot(0x8000))
				local diff = u32(bgBits - fgBits + 0x108420)
				local borrow = band(u32(diff - band(bxor(bgBits, fgBits), 0x108420)), 0x108420)
				color = t16(u32(band(band(u32(diff - borrow), 0xFFFFFFFF), u32(borrow - rshift(borrow, 5)))))
			else
				-- backgroundplusquarterforeground
				bgBits = band(bgBits, bnot(0x8000))
				fgBits = bor(band(rshift(fgBits, 2), 0x1CE7), 0x8000)
				local sum = u32(fgBits + bgBits)
				local carry = band(u32(sum - band(bxor(fgBits, bgBits), 0x8421)), 0x8420)
				color = t16(u32(bor(band(u32(sum - carry), 0xFFFF), u32(carry - rshift(carry, 5)))))
			end
			if not textureEnable then
				color = band(color, bnot(0x8000))
			end
		end
	end

	local maskAnd = cmd.checkMaskBeforeDraw and 0x8000 or 0
	if band(bgColor, maskAnd) ~= 0 then return end
	local maskOr = cmd.setMaskWhileDrawing and 0x8000 or 0
	local idx = band(y, VRAM_H_MASK) * VRAM_W + band(x, VRAM_W_MASK) + 1
	self.vram[idx] = t16(bor(color, maskOr))
	local vlog = self.vramLog
	if vlog then vlog[#vlog + 1] = idx; vlog[#vlog + 1] = 1 end
end

-- drawrectangle
function GPU_REF:drawRectangle(cmd)
	local originX = cmd.x
	local originY = cmd.y
	local r = band(cmd.color, 0xFF)
	local g = band(rshift(cmd.color, 8), 0xFF)
	local b = band(rshift(cmd.color, 16), 0xFF)
	local originU = t8(cmd.texcoord)
	local originV = t8(rshift(cmd.texcoord, 8))
	local left = self.drawingArea.left
	local right = self.drawingArea.right
	local top = self.drawingArea.top
	local bottom = self.drawingArea.bottom
	for offsetY = 0, cmd.height - 1 do
		local y = originY + offsetY
		if y < top or y > bottom then
			-- continue (interlaced skip disabled)
		else
			local texY = t8(originV + offsetY)
			for offsetX = 0, cmd.width - 1 do
				local x = originX + offsetX
				if x >= left and x <= right then
					local texX = t8(originU + offsetX)
					self:shadePixel(cmd, x, y, r, g, b, texX, texY)
				end
			end
		end
	end
end

-- drawline
function GPU_REF:drawLine(cmd, p0, p1)
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

	local left = self.drawingArea.left
	local right = self.drawingArea.right
	local top = self.drawingArea.top
	local bottom = self.drawingArea.bottom
	for _ = 0, k do
		local x = unfpXy(curx)
		local y = unfpXy(cury)
		if x >= left and x <= right and y >= top and y <= bottom then
			local r = cmd.shadingEnable and unfpRgb(curr) or p0.r
			local g = cmd.shadingEnable and unfpRgb(curg) or p0.g
			local b = cmd.shadingEnable and unfpRgb(curb) or p0.b
			self:shadePixel(cmd, x, band(y, VRAM_H_MASK), r, g, b, 0, 0)
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

-- drawspan (scalar)
function GPU_REF:drawSpan(cmd, y, xStart, xBound, uv, uvstep, rgb, rgbstep)
	-- duckstation passes the steppers by value: drawspan steps a copy, so the
	-- caller's per-row steppers must not be mutated by the per-pixel stepping.
	uv = { u = uv.u, v = uv.v }
	rgb = { r = rgb.r, g = rgb.g, b = rgb.b }
	local width = xBound - xStart
	local currentX = truncVertexPos(xStart)

	if currentX < self.drawingArea.left then
		local delta = self.drawingArea.left - currentX
		xStart += delta
		currentX += delta
		width -= delta
	end
	if (currentX + width) > (self.drawingArea.right + 1) then
		width = self.drawingArea.right + 1 - currentX
	end
	if width <= 0 then return end

	if cmd.textureEnable then
		uv.u = u32(uv.u + s32(uvstep.dudx) * xStart)
		uv.v = u32(uv.v + s32(uvstep.dvdx) * xStart)
	end
	if cmd.shadingEnable then
		rgb.r = u32(rgb.r + s32(rgbstep.drdx) * xStart)
		rgb.g = u32(rgb.g + s32(rgbstep.dgdx) * xStart)
		rgb.b = u32(rgb.b + s32(rgbstep.dbdx) * xStart)
	end

	local function getU() return t8(rshift(uv.u, 24)) end
	local function getV() return t8(rshift(uv.v, 24)) end
	local function getR() return t8(rshift(rgb.r, 24)) end
	local function getG() return t8(rshift(rgb.g, 24)) end
	local function getB() return t8(rshift(rgb.b, 24)) end		repeat
		self:shadePixel(cmd, currentX, y, getR(), getG(), getB(), getU(), getV())
		currentX += 1
		if cmd.textureEnable then
			uv.u = u32(uv.u + uvstep.dudx)
			uv.v = u32(uv.v + uvstep.dvdx)
		end
		if cmd.shadingEnable then
			rgb.r = u32(rgb.r + rgbstep.drdx)
			rgb.g = u32(rgb.g + rgbstep.dgdx)
			rgb.b = u32(rgb.b + rgbstep.dbdx)
		end
		width -= 1
	until width <= 0
end

-- drawtrianglepart (scalar)
function GPU_REF:drawTrianglePart(cmd, tp, uv, uvstep, rgb, rgbstep)
	local unfpXy = function(x)
		return s32(math.floor(x / 4294967296))
	end
	local leftXStep = tp.stepX1
	local rightXStep = tp.stepX2
	local endY = tp.endY
	local leftX = tp.startX1
	local rightX = tp.startX2
	local currentY = tp.startY
	if currentY == nil or leftX == nil or rightX == nil or endY == nil then
		error("drawTrianglePart nil tp fields: " .. table.concat({ tostring(currentY), tostring(leftX), tostring(rightX), tostring(endY) }, ","))
	end

	if tp.fillUpsideDown then
		if currentY <= endY then return end
		local luv = { u = uv.u, v = uv.v }
		if cmd.textureEnable then
			luv.u = u32(luv.u + s32(uvstep.dudy) * currentY)
			luv.v = u32(luv.v + s32(uvstep.dvdy) * currentY)
		end
		local lrgb = { r = rgb.r, g = rgb.g, b = rgb.b }
		if cmd.shadingEnable then
			lrgb.r = u32(lrgb.r + s32(rgbstep.drdy) * currentY)
			lrgb.g = u32(lrgb.g + s32(rgbstep.dgdy) * currentY)
			lrgb.b = u32(lrgb.b + s32(rgbstep.dbdy) * currentY)
		end
		repeat
			currentY -= 1
			leftX -= leftXStep
			rightX -= rightXStep
			local y = truncVertexPos(currentY) -- current_y is a plain integer (DuckStation TruncateGPUVertexPosition)
			if y < self.drawingArea.top then break end
			if cmd.textureEnable then
				luv.u = u32(luv.u - uvstep.dudy)
				luv.v = u32(luv.v - uvstep.dvdy)
			end
			if cmd.shadingEnable then
				lrgb.r = u32(lrgb.r - rgbstep.drdy)
				lrgb.g = u32(lrgb.g - rgbstep.dgdy)
				lrgb.b = u32(lrgb.b - rgbstep.dbdy)
			end
			if y <= self.drawingArea.bottom then
				self:drawSpan(cmd, band(y, VRAM_H_MASK), unfpXy(leftX), unfpXy(rightX), luv, uvstep, lrgb, rgbstep)
			end
		until currentY <= endY
	else
		if currentY >= endY then return end
		local luv = { u = uv.u, v = uv.v }
		if cmd.textureEnable then
			luv.u = u32(luv.u + s32(uvstep.dudy) * currentY)
			luv.v = u32(luv.v + s32(uvstep.dvdy) * currentY)
		end
		local lrgb = { r = rgb.r, g = rgb.g, b = rgb.b }
		if cmd.shadingEnable then
			lrgb.r = u32(lrgb.r + s32(rgbstep.drdy) * currentY)
			lrgb.g = u32(lrgb.g + s32(rgbstep.dgdy) * currentY)
			lrgb.b = u32(lrgb.b + s32(rgbstep.dbdy) * currentY)
		end
		repeat
			local y = truncVertexPos(currentY) -- current_y is a plain integer (DuckStation TruncateGPUVertexPosition)
			if y > self.drawingArea.bottom then
				break
			end
			if y >= self.drawingArea.top then
				self:drawSpan(cmd, band(y, VRAM_H_MASK), unfpXy(leftX), unfpXy(rightX), luv, uvstep, lrgb, rgbstep)
			end
			currentY += 1
			leftX += leftXStep
			rightX += rightXStep
			if cmd.textureEnable then
				luv.u = u32(luv.u + uvstep.dudy)
				luv.v = u32(luv.v + uvstep.dvdy)
			end
			if cmd.shadingEnable then
				lrgb.r = u32(lrgb.r + rgbstep.drdy)
				lrgb.g = u32(lrgb.g + rgbstep.dgdy)
				lrgb.b = u32(lrgb.b + rgbstep.dbdy)
			end
		until currentY >= endY
	end
end

-- drawtriangle
function GPU_REF:drawTriangle(cmd, v0in, v1in, v2in)
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

	local vertices = { v0, v1, v2 }
	tl = rshift(tl, 1)

	if v0.y == v2.y then return end

	local makefpXy = function(x) return x * 4294967296 + (4294967296 - 2048) end
	local makeStepXy = function(dx, dy)
		local num = dx * 4294967296
		if dx < 0 then num = num - (dy - 1)
		elseif dx > 0 then num = num + (dy - 1) end
		return divTrunc(num, dy)
	end
	local baseCoord = makefpXy(v0.x)
	local baseStep = makeStepXy(v2.x - v0.x, v2.y - v0.y)
	local boundCoordUs = (v1.y == v0.y) and 0 or makeStepXy(v1.x - v0.x, v1.y - v0.y)
	local boundCoordLs = (v2.y == v1.y) and 0 or makeStepXy(v2.x - v1.x, v2.y - v1.y)
	local vo = (tl ~= 0) and 1 or 0
	local vp = (tl == 2) and 3 or 0
	local rightFacing = (v1.y == v0.y) and (v1.x > v0.x) or (boundCoordUs > baseStep)
	local rfi = rightFacing and 1 or 0
	local ofi = (not rightFacing) and 1 or 0

	local tpo = {}
	local tpp = {}
	tpo.startY = vertices[1 + bxor(0, vo)].y
	tpo.endY = vertices[1 + bxor(1, vo)].y
	tpp.startY = vertices[1 + bxor(1, vp)].y
	tpp.endY = vertices[1 + bxor(2, vp)].y
	-- duckstation: tpo.start_x[rfi] = vertex x; tpo.start_x[ofi] = base edge.
	-- slot 0 = startx1, slot 1 = startx2 (0-indexed in the c++).
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

	local function attrStep(detExpr)
		return u32(lshift(band(divTrunc(detExpr * 4096, det), 0xFFFFFFFF), 12))
	end

	local uvstep = { dudx = 0, dvdx = 0, dudy = 0, dvdy = 0 }
	local rgbstep = { drdx = 0, dgdx = 0, dbdx = 0, drdy = 0, dgdy = 0, dbdy = 0 }
	if cmd.textureEnable then
		-- dudx = det(u,y); dvdx = det(v,y); dudy = det(x,u); dvdy = det(x,v)
		uvstep.dudx = attrStep((v1.u - v0.u) * (v2.y - v1.y) - (v2.u - v1.u) * (v1.y - v0.y))
		uvstep.dvdx = attrStep((v1.v - v0.v) * (v2.y - v1.y) - (v2.v - v1.v) * (v1.y - v0.y))
		uvstep.dudy = attrStep((v1.x - v0.x) * (v2.u - v1.u) - (v2.x - v1.x) * (v1.u - v0.u))
		uvstep.dvdy = attrStep((v1.x - v0.x) * (v2.v - v1.v) - (v2.x - v1.x) * (v1.v - v0.v))
	end
	if cmd.shadingEnable then
		rgbstep.drdx = attrStep((v1.r - v0.r) * (v2.y - v1.y) - (v2.r - v1.r) * (v1.y - v0.y))
		rgbstep.dgdx = attrStep((v1.g - v0.g) * (v2.y - v1.y) - (v2.g - v1.g) * (v1.y - v0.y))
		rgbstep.dbdx = attrStep((v1.b - v0.b) * (v2.y - v1.y) - (v2.b - v1.b) * (v1.y - v0.y))
		rgbstep.drdy = attrStep((v1.x - v0.x) * (v2.r - v1.r) - (v2.x - v1.x) * (v1.r - v0.r))
		rgbstep.dgdy = attrStep((v1.x - v0.x) * (v2.g - v1.g) - (v2.x - v1.x) * (v1.g - v0.g))
		rgbstep.dbdy = attrStep((v1.x - v0.x) * (v2.b - v1.b) - (v2.x - v1.x) * (v1.b - v0.b))
	end

	local topLeftVertex = vertices[1 + tl]
	local uv = { u = 0, v = 0 }
	local rgb = { r = 0, g = 0, b = 0 }
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

-- vram operations (gpu_sw_rasterizer.inl: fillvramimpl/writevramimpl/copyvramimpl)

function GPU_REF:fillVRAM(x, y, width, height, color)
	local color16 = rgb888to5551(color)
	for yoffs = 0, height - 1 do
		local row = (y + yoffs) % VRAM_H
		local rowBase = row * VRAM_W
		local vlog = self.vramLog
		for xoffs = 0, width - 1 do
			local col = (x + xoffs) % VRAM_W
			local didx = rowBase + col + 1
			self.vram[didx] = color16
			if vlog then vlog[#vlog + 1] = didx; vlog[#vlog + 1] = 1 end
		end
	end
end

function GPU_REF:writeVRAM(x, y, width, height, data, setMask, checkMask)
	local maskAnd = checkMask and 0x8000 or 0
	local maskOr = setMask and 0x8000 or 0
	local srcIdx = 1
	if (x + width) <= VRAM_W and (y + height) <= VRAM_H and not setMask and not checkMask then
		for yoffs = 0, height - 1 do
			local dstBase = (y + yoffs) * VRAM_W + x + 1
			for i = 0, width - 1 do
				self.vram[dstBase + i] = data[srcIdx + i] or 0
			end
			logVram(self, dstBase, width)
			srcIdx += width
		end
	else
		local vlog = self.vramLog
		for row = 0, height - 1 do
			local dstRowBase = ((y + row) % VRAM_H) * VRAM_W
			for col = 0, width - 1 do
				local pix = data[srcIdx]
				srcIdx += 1
				local dstPtr = dstRowBase + ((x + col) % VRAM_W) + 1
				if band(self.vram[dstPtr] or 0, maskAnd) == 0 then
					self.vram[dstPtr] = t16(bor(pix or 0, maskOr))
					if vlog then vlog[#vlog + 1] = dstPtr; vlog[#vlog + 1] = 1 end
				end
			end
		end
	end
end

function GPU_REF:copyVRAM(srcX, srcY, dstX, dstY, width, height, setMask, checkMask)
	-- single-pass copy with per-pixel wrapping on both axes, the reverse direction decided once by the
	-- console-verified condition (src_x < dst_x, or the wrapped end-of-span comparison).  duckstation
	-- instead splits oversized copies into chunks, a path its own comment flags as "not verified on
	-- console", and the chunk boundaries can re-read cells the command already wrote when the wrapped
	-- source overlaps the destination.
	local maskAnd = checkMask and 0x8000 or 0
	local maskOr = setMask and 0x8000 or 0
	local vram = self.vram
	local vlog = self.vramLog
	local reverse = srcX < dstX
		or (((srcX + width - 1) % VRAM_W) < ((dstX + width - 1) % VRAM_W))
	for row = 0, height - 1 do
		local srcRow = ((srcY + row) % VRAM_H) * VRAM_W
		local dstRow = ((dstY + row) % VRAM_H) * VRAM_W
		if reverse then
			for col = width - 1, 0, -1 do
				local srcPixel = vram[srcRow + ((srcX + col) % VRAM_W) + 1] or 0
				local dstPtr = dstRow + ((dstX + col) % VRAM_W) + 1
				if band(vram[dstPtr] or 0, maskAnd) == 0 then
					vram[dstPtr] = t16(bor(srcPixel, maskOr))
					if vlog then vlog[#vlog + 1] = dstPtr; vlog[#vlog + 1] = 1 end
				end
			end
		else
			for col = 0, width - 1 do
				local srcPixel = vram[srcRow + ((srcX + col) % VRAM_W) + 1] or 0
				local dstPtr = dstRow + ((dstX + col) % VRAM_W) + 1
				if band(vram[dstPtr] or 0, maskAnd) == 0 then
					vram[dstPtr] = t16(bor(srcPixel, maskOr))
					if vlog then vlog[#vlog + 1] = dstPtr; vlog[#vlog + 1] = 1 end
				end
			end
		end
	end
end

return GPU_REF
