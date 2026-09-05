-- mdec copy for decoder checks; the command format and block math stay separate from the emulator
-- so both sides can be wrong in different ways.  blocks are processed eagerly (no 448-tick copy-out
-- event, no 768-word output fifo gate) -- duckstation's gate only defers yuv->rgb + packing until
-- the output fifo drains, and the produced words are identical.
-- interface matches src/shared/ps1/mdec.luau: writedata(v), writecontrol(v), dmain(words,
-- wordcount), dmaout(wordcount), readdata(), readstatus().

local REF = {}
REF.__index = REF

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift
local bnot = bit32.bnot

local DATA_IN_FIFO_SIZE_HALFWORDS = 512 -- DuckStation: 1024 bytes

-- row-major zigzag used by decoderle_new (psx-spx zigzag with the swap to
-- row-major storage so the idct can be vectorized; duckstation layout).
local ZIGZAG = {
	0, 8, 1, 2, 9, 16, 24, 17, 10, 3, 4, 11, 18, 25, 32, 40,
	33, 26, 19, 12, 5, 6, 13, 20, 27, 34, 41, 48, 56, 49, 42, 35,
	28, 21, 14, 7, 15, 22, 29, 36, 43, 50, 57, 58, 51, 44, 37, 30,
	23, 31, 38, 45, 52, 59, 60, 53, 46, 39, 47, 54, 61, 62, 55, 63,
}

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function signExtend(value, bits)
	local signBit = lshift(1, bits - 1)
	if band(value, signBit) ~= 0 then
		return value - lshift(1, bits)
	end
	return value
end

local function arshift(v, n)
	if v >= 0 then
		return rshift(v, n)
	end
	return -(rshift(-v - 1, n)) - 1
end

function REF.new()
	local self = setmetatable({}, REF)
	self.enableDmaIn = false
	self.enableDmaOut = false
	self.state = "idle" -- idle | decoding | setIq | setScale | noop
	self.command = 0
	self.depth = 0
	self.signed = false
	self.bit15 = false

	-- duckstation zero-initializes iq_uv/iq_y/scale_table; games upload them
	-- via mdec(2)/mdec(3) before decoding.
	self.iqY = table.create(64, 0)
	self.iqUV = table.create(64, 0)
	for i = 1, 64 do self.iqY[i] = 0; self.iqUV[i] = 0 end
	self.scaleTable = table.create(64, 0)
	for i = 1, 64 do self.scaleTable[i] = 0 end

	self.dataInFifo = {} -- halfwords (command + params), head index
	self.inHead = 0
	self.dataOutFifo = {} -- output words, head index
	self.outHead = 0

	self.blocks = {}
	for i = 1, 6 do self.blocks[i] = table.create(64, 0) end
	self.blockRgb = table.create(256, 0)

	self.remainingHalfwords = 0
	self.currentBlock = 0 -- 0-5 (Cr, Cb, Y1..Y4)
	self.currentCoefficient = 64
	self.currentQScale = 0

	self.irqCallback = nil
	return self
end

function REF:setIrqCallback(cb)
	self.irqCallback = cb
end

function REF:fifoSize()
	return #self.dataInFifo - self.inHead
end

function REF:popHalfword()
	local i = self.inHead + 1
	local v = self.dataInFifo[i]
	if v == nil then return nil end
	self.inHead = i
	if self.inHead > 2048 then
		local rest = #self.dataInFifo - self.inHead
		for j = 1, rest do
			self.dataInFifo[j] = self.dataInFifo[self.inHead + j]
		end
		for j = rest + 1, #self.dataInFifo do
			self.dataInFifo[j] = nil
		end
		self.inHead = 0
	end
	return v
end

function REF:removeHalfwords(n)
	for _ = 1, n do
		self:popHalfword()
	end
end

function REF:pushHalfwords(list, count)
	local fifo = self.dataInFifo
	for i = 1, count do
		fifo[#fifo + 1] = list[i]
	end
end

-- soft reset (duckstation softreset)
function REF:softReset()
	self.enableDmaIn = false
	self.enableDmaOut = false
	self.dataInFifo = {}
	self.inHead = 0
	self.dataOutFifo = {}
	self.outHead = 0
	self.state = "idle"
	self.remainingHalfwords = 0
	self.currentBlock = 0
	self.currentCoefficient = 64
	self.currentQScale = 0
end

function REF:reset()
	self:softReset()
end

-- register interface
function REF:readData()
	local fifo = self.dataOutFifo
	local head = self.outHead
	if head >= #fifo then
		return 0xFFFFFFFF
	end
	local v = fifo[head + 1]
	self.outHead = head + 1
	if self.outHead >= #fifo then
		self.dataOutFifo = {}
		self.outHead = 0
	end
	return v
end

function REF:readStatus()
	local status = 0
	if self.outHead >= #self.dataOutFifo then
		status = bor(status, 0x80000000) -- data-out FIFO empty
	end
	if self:fifoSize() >= DATA_IN_FIFO_SIZE_HALFWORDS then
		status = bor(status, 0x40000000) -- data-in FIFO full
	end
	if self.state ~= "idle" then
		status = bor(status, 0x20000000) -- command busy
	end
	if self.enableDmaIn and (DATA_IN_FIFO_SIZE_HALFWORDS - self:fifoSize()) >= 64 then
		status = bor(status, 0x10000000) -- data-in request
	end
	if self.enableDmaOut and self.outHead < #self.dataOutFifo then
		status = bor(status, 0x08000000) -- data-out request
	end
	status = bor(status, lshift(band(self.depth, 3), 25))
	if self.signed then
		status = bor(status, 0x01000000)
	end
	if self.bit15 then
		status = bor(status, 0x00800000)
	end
	status = bor(status, lshift((self.currentBlock + 4) % 6, 16))
	status = bor(status, band((self.remainingHalfwords // 2) - 1, 0xFFFF))
	return status
end

function REF:writeData(value)
	value = band(value, 0xFFFFFFFF)
	self.dataInFifo[#self.dataInFifo + 1] = band(value, 0xFFFF)
	self.dataInFifo[#self.dataInFifo + 1] = band(rshift(value, 16), 0xFFFF)
	self:execute()
end

function REF:writeControl(value)
	value = band(value, 0xFFFFFFFF)
	if band(value, 0x80000000) ~= 0 then
		self:softReset()
	end
	self.enableDmaIn = band(value, 0x40000000) ~= 0
	self.enableDmaOut = band(value, 0x20000000) ~= 0
	self:execute()
end

-- dma
function REF:dmaIn(words, wordCount)
	local fifo = self.dataInFifo
	for i = 0, wordCount - 1 do
		local w = words(i)
		fifo[#fifo + 1] = band(w, 0xFFFF)
		fifo[#fifo + 1] = band(rshift(w, 16), 0xFFFF)
	end
	self:execute()
end

-- duckstation dmaread: returns only the words actually available (no
-- zero-padding); the dma controller transfers fewer words.
function REF:dmaOut(wordCount)
	local out = {}
	local fifo = self.dataOutFifo
	local head = self.outHead
	local avail = #fifo - head
	local count = math.min(wordCount, avail)
	for i = 1, count do
		out[i] = fifo[head + i]
	end
	self.outHead = head + count
	if self.outHead >= #fifo then
		self.dataOutFifo = {}
		self.outHead = 0
	elseif self.outHead > 2048 then
		local rest = #fifo - self.outHead
		for i = 1, rest do
			fifo[i] = fifo[self.outHead + i]
		end
		for i = rest + 1, #fifo do
			fifo[i] = nil
		end
		self.outHead = 0
	end
	return out
end

-- command state machine (duckstation execute)
function REF:execute()
	local guard = 0
	while true do
		guard += 1
		if guard > 100000 then
			error("mdec_ref execute guard hit")
		end
		if self.state == "idle" then
			if self:fifoSize() < 2 then
				break
			end
			local lo = self.dataInFifo[self.inHead + 1]
			local hi = self.dataInFifo[self.inHead + 2]
			self:removeHalfwords(2)
			local cmd = bor(lo, lshift(hi, 16))
			self.command = cmd
			self.depth = band(rshift(cmd, 27), 3)
			self.signed = band(rshift(cmd, 26), 1) ~= 0
			self.bit15 = band(rshift(cmd, 25), 1) ~= 0
			-- duckstation clears the output fifo when a new command is consumed.
			self.dataOutFifo = {}
			self.outHead = 0
			local c = band(rshift(cmd, 29), 7)
			local numWords
			if c == 1 then
				numWords = band(cmd, 0xFFFF)
				self.state = "decoding"
			elseif c == 2 then
				numWords = 16 + (band(cmd, 1) ~= 0 and 16 or 0)
				self.state = "setIq"
			elseif c == 3 then
				numWords = 32
				self.state = "setScale"
			else
				numWords = band(cmd, 0xFFFF)
				self.state = "noop"
			end
			self.remainingHalfwords = numWords * 2
		elseif self.state == "decoding" then
			local done = self:decodeMacroblock()
			if not done then
				if self.remainingHalfwords == 0 and self.currentBlock ~= 6 then
					self:resetDecoder()
					self.state = "idle"
				end
				break
			end
			self:resetDecoder()
			if self.remainingHalfwords == 0 then
				self.state = "idle"
				if self.irqCallback then
					self.irqCallback()
				end
			end
			-- else: stay decoding, process the next macroblock
		elseif self.state == "setIq" then
			if self:fifoSize() < self.remainingHalfwords then
				break
			end
			self:handleSetIq()
			self.state = "idle"
		elseif self.state == "setScale" then
			if self:fifoSize() < self.remainingHalfwords then
				break
			end
			self:handleSetScale()
			self.state = "idle"
		elseif self.state == "noop" then
			local n = math.min(self.remainingHalfwords, self:fifoSize())
			self:removeHalfwords(n)
			self.remainingHalfwords -= n
			if self.remainingHalfwords > 0 then
				break
			end
			self.state = "idle"
		else
			break
		end
	end
end

function REF:resetDecoder()
	self.currentBlock = 0
	self.currentCoefficient = 64
	self.currentQScale = 0
end

-- decode one macroblock. returns true when complete (output produced), false
-- when the stream ran out mid-block.
function REF:decodeMacroblock()
	if self.depth <= 1 then
		-- mono: one block, iq_y, yuvtomono (64 pixels)
		if not self:decodeRLE(self.blocks[1], self.iqY) then
			return false
		end
		self:idct(self.blocks[1])
		local addval = self.signed and 0 or 0x80
		for i = 1, 64 do
			local v = self.blocks[1][i]
			if band(v, 0x100) ~= 0 then v = v - 0x200 end
			v = clamp(v, -128, 127) + addval
			self.blockRgb[i] = band(v, 0xFFFFFFFF)
		end
		self:packOutput()
		return true
	end

	-- colored: cr, cb (iq_uv), y1..y4 (iq_y)
	for b = 1, 6 do
		local qt = (b <= 2) and self.iqUV or self.iqY
		if not self:decodeRLE(self.blocks[b], qt) then
			return false
		end
		self:idct(self.blocks[b])
	end
	self:yuvToRgb(0, 0, self.blocks[1], self.blocks[2], self.blocks[3])
	self:yuvToRgb(8, 0, self.blocks[1], self.blocks[2], self.blocks[4])
	self:yuvToRgb(0, 8, self.blocks[1], self.blocks[2], self.blocks[5])
	self:yuvToRgb(8, 8, self.blocks[1], self.blocks[2], self.blocks[6])
	self:packOutput()
	return true
end

-- decoderle_new (duckstation)
function REF:decodeRLE(blk, qt)
	if self.currentCoefficient == 64 then
		for i = 1, 64 do
			blk[i] = 0
		end
		local n
		while true do
			if self:fifoSize() == 0 or self.remainingHalfwords == 0 then
				return false
			end
			n = self:popHalfword()
			self.remainingHalfwords -= 1
			if n ~= 0xFE00 then
				break
			end
		end
		self.currentCoefficient = 0
		self.currentQScale = rshift(n, 10)
		local val = signExtend(band(n, 0x3FF), 10)
		local coeff
		if self.currentQScale == 0 then
			coeff = lshift(val, 5)
		else
			local round = (val ~= 0) and ((val < 0) and 8 or -8) or 0
			coeff = lshift(val * qt[1], 4) + round
		end
		-- zigzag is 0-based, blk is 1-based: the +1 keeps the dc inside the array (the idct reads indices 1..64); the old indexing wrote dc to blk[0] where the idct never sees it.
		blk[ZIGZAG[1] + 1] = clamp(coeff, -0x4000, 0x3FFF)
	end

	while self:fifoSize() > 0 and self.remainingHalfwords > 0 do
		local n = self:popHalfword()
		self.remainingHalfwords -= 1
		self.currentCoefficient += rshift(n, 10) + 1
		if self.currentCoefficient < 64 then
			local val = signExtend(band(n, 0x3FF), 10)
			local scq = self.currentQScale * qt[self.currentCoefficient + 1]
			local coeff
			if scq == 0 then
				coeff = lshift(val, 5)
			else
				local round = (val ~= 0) and ((val < 0) and 8 or -8) or 0
				coeff = lshift(arshift(val * scq, 3), 4) + round
			end
			blk[ZIGZAG[self.currentCoefficient + 1] + 1] = clamp(coeff, -0x4000, 0x3FFF)
		end
		if self.currentCoefficient >= 63 then
			self.currentCoefficient = 64
			return true
		end
	end
	return false
end

-- idct_new (duckstation idctrow: ((sum + 0x20000) >> 18), sign-extend 9 + clamp)
function REF:idct(blk)
	local scale = self.scaleTable
	local temp = table.create(64, 0)
	for x = 0, 7 do
		local xo = x * 8
		for y = 0, 7 do
			local yo = y * 8
			local sum = 0
			for i = 0, 7 do
				sum += blk[xo + i + 1] * scale[yo + i + 1]
			end
			temp[yo + x + 1] = arshift(sum + 0x20000, 18)
		end
	end
	for x = 0, 7 do
		local xo = x * 8
		for y = 0, 7 do
			local yo = y * 8
			local sum = 0
			for i = 0, 7 do
				sum += temp[xo + i + 1] * scale[yo + i + 1]
			end
			local v = arshift(sum + 0x20000, 18)
			if band(v, 0x100) ~= 0 then v = v - 0x200 end
			blk[xo + y + 1] = clamp(v, -128, 127)
		end
	end
end

-- yuvtorgb_new (duckstation; bt.601 coefficients with mednafen rounding)
function REF:yuvToRgb(xx, yy, crblk, cbblk, yblk)
	local addval = self.signed and 0 or 0x80
	for y = 0, 7 do
		local cy = (y + yy) // 2
		local cbase = (xx // 2) + cy * 8
		for x = 0, 7 do
			local cidx = cbase + (x // 2)
			local cr = crblk[cidx + 1]
			local cb = cbblk[cidx + 1]
			local crm = arshift(cr * 359 + 0x80, 8)
			local cbm = arshift(cb * 454 + 0x80, 8)
			local crcbm = arshift(band(cb * -88, bnot(0x1F)) + band(cr * -183, bnot(0x07)) + 0x80, 8)
			local yv = yblk[y * 8 + x + 1]
			local function conv(v)
				if band(v, 0x100) ~= 0 then v = v - 0x200 end
				return clamp(v, -128, 127) + addval
			end
			local r = conv(yv + crm)
			local g = conv(yv + crcbm)
			local b = conv(yv + cbm)
			self.blockRgb[(x + xx) + (y + yy) * 16 + 1] = bor(r, lshift(g, 8), lshift(b, 16), lshift(addval, 24))
		end
	end
end

-- output packing (duckstation copyoutblock)
function REF:packOutput()
	local depth = band(self.depth, 3)
	local fifo = self.dataOutFifo
	local rgb = self.blockRgb

	if depth == 3 then
		-- 15-bit: two pixels per word, e8to5 = min(((c + 4) >> 3), 0x1f)
		local a = self.bit15 and 0x8000 or 0
		local function e8to5(c)
			local v = rshift(c + 4, 3)
			return v > 0x1F and 0x1F or v
		end
		for i = 1, 256, 2 do
			local c0 = rgb[i]
			local c1 = rgb[i + 1]
			local r0 = e8to5(band(c0, 0xFF))
			local g0 = e8to5(band(rshift(c0, 8), 0xFF))
			local b0 = e8to5(band(rshift(c0, 16), 0xFF))
			local r1 = e8to5(band(c1, 0xFF))
			local g1 = e8to5(band(rshift(c1, 8), 0xFF))
			local b1 = e8to5(band(rshift(c1, 16), 0xFF))
			local p0 = bor(r0, lshift(g0, 5), lshift(b0, 10), a)
			local p1 = bor(r1, lshift(g1, 5), lshift(b1, 10), a)
			fifo[#fifo + 1] = band(bor(p0, lshift(p1, 16)), 0xFFFFFFFF)
		end
	elseif depth == 2 then
		-- 24-bit: tight-packed 3 bytes per pixel, 256 pixels -> 192 words
		local index = 1
		local state = 0
		local rgbw = 0
		while index <= 256 do
			if state == 0 then
				rgbw = rgb[index]
				index += 1
				state = 1
			elseif state == 1 then
				rgbw = bor(rgbw, lshift(band(rgb[index], 0xFF), 24))
				fifo[#fifo + 1] = band(rgbw, 0xFFFFFFFF)
				rgbw = rshift(rgb[index], 8)
				index += 1
				state = 2
			elseif state == 2 then
				rgbw = bor(rgbw, lshift(rgb[index], 16))
				fifo[#fifo + 1] = band(rgbw, 0xFFFFFFFF)
				rgbw = rshift(rgb[index], 16)
				index += 1
				state = 3
			else
				rgbw = bor(rgbw, lshift(rgb[index], 8))
				fifo[#fifo + 1] = band(rgbw, 0xFFFFFFFF)
				index += 1
				state = 0
			end
		end
	elseif depth == 0 then
		-- 4-bit mono: 64 pixels -> 8 words. duckstation chains the raw u32
		-- (wrapped for signed negatives) without byte pre-masking.
		for i = 1, 64, 8 do
			local w = 0
			for j = 0, 7 do
				w = bor(w, lshift(rshift(rgb[i + j], 4), j * 4))
			end
			fifo[#fifo + 1] = band(w, 0xFFFFFFFF)
		end
	else
		-- 8-bit mono: 64 pixels -> 16 words
		for i = 1, 64, 4 do
			local w = 0
			for j = 0, 3 do
				w = bor(w, lshift(rgb[i + j], j * 8))
			end
			fifo[#fifo + 1] = band(w, 0xFFFFFFFF)
		end
	end
end

-- table commands
function REF:handleSetIq()
	-- duckstation: 32 halfwords (64 bytes) -> iq_y, then (if declared) another
	-- 32 halfwords -> iq_uv.  bytes are packed little-endian from the words.
	for i = 1, 32 do
		local hw = self:popHalfword()
		self.remainingHalfwords -= 1
		self.iqY[i * 2 - 1] = band(hw, 0xFF)
		self.iqY[i * 2] = band(rshift(hw, 8), 0xFF)
	end
	if self.remainingHalfwords > 0 then
		for i = 1, 32 do
			local hw = self:popHalfword()
			self.remainingHalfwords -= 1
			self.iqUV[i * 2 - 1] = band(hw, 0xFF)
			self.iqUV[i * 2] = band(rshift(hw, 8), 0xFF)
		end
	end
end

function REF:handleSetScale()
	-- duckstation setscalematrix: scale_table[y*8+x] = values[x*8+y] (transpose)
	for i = 1, 64 do
		local hw = self:popHalfword()
		self.remainingHalfwords -= 1
		-- duckstation setscalematrix: scale_table[y*8+x] = values[x*8+y]; for input index k = i-1, the output index is (k%8)*8 + k//8.
		local k = i - 1
		-- duckstation stores the scale matrix in an std::array<s16, 64>, so
		-- halfwords >= 0x8000 are negative coefficients (sign-extended).
		if hw >= 0x8000 then
			hw = hw - 0x10000
		end
		self.scaleTable[(k % 8) * 8 + k // 8 + 1] = hw
	end
end

return REF
