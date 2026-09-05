-- standalone xa/cd-da audio model; shares no implementation with cdrom.luau, so the decoder and resampler can be checked independently.  the public methods mirror the audio state the emulator exposes.

local Ref = {}
Ref.__index = Ref

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift


local XA_ADPCM_SAMPLES_PER_SECTOR_4BIT = 4032
local XA_ADPCM_SAMPLES_PER_SECTOR_8BIT = 2016
local XA_RESAMPLE_RING_BUFFER_SIZE = 32
local AUDIO_FIFO_SIZE = 44100 * 2
local AUDIO_FIFO_LOW_WATERMARK = 10
local NUM_CHUNKS = 18
local CHUNK_SIZE_IN_BYTES = 128
local WORDS_PER_CHUNK = 28
local NUM_BLOCKS_4BIT = 8
local NUM_BLOCKS_8BIT = 4
local WORDS_PER_BLOCK = 28

-- xa-adpcm predictor tables (filter 0..3; entries beyond are zero).
local FILTER_TABLE_POS = { 0, 60, 115, 98, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
local FILTER_TABLE_NEG = { 0, 0, -52, -55, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }

-- 37800hz zigzag resample fir tables (7 tables x 29 taps), extracted verbatim
-- from duckstation cdrom.cpp resamplexaadpcm.
local ZIGZAG_TABLES = {
	{ 0, 0, 0, 0, 0, -2, 10, -34, 65, -84, 52, 9, -266, 1024, -2680, 9036, 26516, -6016, 3021, -1571, 848, -365, 107, 10, -16, 17, -8, 3, -1 },
	{ 0, 0, 0, -2, 0, 3, -19, 60, -75, 162, -227, 306, -67, -615, 3229, 29883, -4532, 2488, -1471, 882, -424, 166, -27, 5, 6, -8, 3, -1, 0 },
	{ 0, 0, -1, 3, -2, -5, 31, -74, 179, -402, 689, -926, 1272, -1446, 31033, -1446, 1272, -926, 689, -402, 179, -74, 31, -5, -2, 3, -1, 0, 0 },
	{ 0, -1, 3, -8, 6, 5, -27, 166, -424, 882, -1471, 2488, -4532, 29883, 3229, -615, -67, 306, -227, 162, -75, 60, -19, 3, 0, -2, 0, 0, 0 },
	{ -1, 3, -8, 17, -16, 10, 107, -365, 848, -1571, 3021, -6016, 26516, 9036, -2680, 1024, -266, 9, 52, -84, 65, -34, 10, -1, 0, 1, 0, 0, 0 },
	{ 2, -8, 16, -35, 43, 26, -235, 635, -1352, 2810, -5882, 21472, 15367, -4681, 2062, -839, 347, -68, -23, 70, -35, 17, -5, 0, 0, 0, 0, 0, 0 },
	{ -5, 17, -35, 70, -23, -68, 347, -839, 2062, -4681, 15367, 21472, -5882, 2810, -1352, 635, -235, 26, 43, -35, 16, -8, 2, 0, 0, 0, 0, 0, 0 },
}

-- 18900hz resample fir tables (7 tables x 25 taps), extracted verbatim from
-- duckstation cdrom.cpp resamplexaadpcm18900.
local TABLES_18900 = {
	{ 0, -5, 17, -35, 70, -23, -68, 347, -839, 2062, -4681, 15367, 21472, -5882, 2810, -1352, 635, -235, 26, 43, -35, 16, -8, 2, 0 },
	{ 0, -2, 10, -34, 65, -84, 52, 9, -266, 1024, -2680, 9036, 26516, -6016, 3021, -1571, 848, -365, 107, 10, -16, 17, -8, 3, -1 },
	{ -2, 0, 3, -19, 60, -75, 162, -227, 306, -67, -615, 3229, 29883, -4532, 2488, -1471, 882, -424, 166, -27, 5, 6, -8, 3, -1 },
	{ -1, 3, -2, -5, 31, -74, 179, -402, 689, -926, 1272, -1446, 31033, -1446, 1272, -926, 689, -402, 179, -74, 31, -5, -2, 3, -1 },
	{ -1, 3, -8, 6, 5, -27, 166, -424, 882, -1471, 2488, -4532, 29883, 3229, -615, -67, 306, -227, 162, -75, 60, -19, 3, 0, -2 },
	{ -1, 3, -8, 17, -16, 10, 107, -365, 848, -1571, 3021, -6016, 26516, 9036, -2680, 1024, -266, 9, 52, -84, 65, -34, 10, -2, 0 },
	{ 0, 2, -8, 16, -35, 43, 26, -235, 635, -1352, 2810, -5882, 21472, 15367, -4681, 2062, -839, 347, -68, -23, 70, -35, 17, -5, 0 },
}

local function clamp16(v)
	if v < -32768 then return -32768 end
	if v > 32767 then return 32767 end
	return v
end

-- arithmetic shift right (self-contained; bit32.arshift is not available in
-- all runtimes).
local function arshift(v, n)
	if n <= 0 then return v end
	if v >= 0 then
		return math.floor(v / (2 ^ n))
	end
	return -math.floor((-v - 1) / (2 ^ n)) - 1
end

local function s16(v)
	v = band(v, 0xFFFF)
	return v >= 0x8000 and v - 0x10000 or v
end

local function applyVolume(sample, volume)
	return arshift(sample * band(volume, 0xFF), 7)
end

local function saturateVolume(v)
	if v < -0x8000 then return -0x8000 end
	if v > 0x7FFF then return 0x7FFF end
	return v
end


local Fifo = {}
Fifo.__index = Fifo

function Fifo.new()
	return setmetatable({ data = {}, head = 1, count = 0 }, Fifo)
end

function Fifo:getSize()
	return self.count
end

function Fifo:getSpace()
	return AUDIO_FIFO_SIZE - self.count
end

function Fifo:isEmpty()
	return self.count == 0
end

function Fifo:push(frame)
	if self.count >= AUDIO_FIFO_SIZE then
		-- drop oldest to make room (duckstation queue is fixed-size; the
		-- callers guard against overflow before pushing, so this is a safety net)
		self:pop()
	end
	self.data[self.head + self.count] = frame
	self.count += 1
end

function Fifo:pop()
	if self.count == 0 then return 0 end
	local v = self.data[self.head]
	self.data[self.head] = nil
	self.head += 1
	self.count -= 1
	return v
end

function Fifo:remove(n)
	for _ = 1, n do
		if self.count == 0 then break end
		self.data[self.head] = nil
		self.head += 1
		self.count -= 1
	end
end

function Fifo:clear()
	self.data = {}
	self.head = 1
	self.count = 0
end


function Ref.new()
	local self = setmetatable({
		-- xa filter / current-file state (duckstation xa_filter/current)
		xaFilterFile = 0,
		xaFilterChannel = 0,
		xaCurrentFile = 0,
		xaCurrentChannel = 0,
		xaCurrentSet = false,
		xaCurrentCodinginfo = 0,
		-- xa decoder state
		xaLastSamples = { 0, 0, 0, 0 },
		xaResampleRingBuffer = { table.create(XA_RESAMPLE_RING_BUFFER_SIZE, 0), table.create(XA_RESAMPLE_RING_BUFFER_SIZE, 0) },
		xaResampleP = 0,
		xaResampleSixstep = 6,
		-- audio fifo + volume matrix
		audioFifo = Fifo.new(),
		cdAudioVolumeMatrix = { { 0x80, 0x00 }, { 0x00, 0x80 } },
		nextCdAudioVolumeMatrix = { { 0x80, 0x00 }, { 0x00, 0x80 } },
		-- mutes
		muted = false,
		adpcmMuted = false,
		cddaAutoPausePending = false,
		-- drive/mode bits used by the audio path
		driveState = 0,
		mode = 0x20, -- read_raw_sector reset value
		doubleSpeed = false,
		-- peak volume tracking (report path)
		lastCddaReportFrameNibble = 0xFF,
		cddaReportStartDelay = 0,
	}, Ref)
	return self
end

-- codinginfo decode helpers (duckstation xasubheader::codinginfo).
local function isStereo(coding) return band(coding, 0x01) ~= 0 end
local function isHalfSampleRate(coding) return band(coding, 0x04) ~= 0 end
local function is8BitADPCM(coding) return band(coding, 0x10) ~= 0 end
local function samplesPerSector(coding)
	return is8BitADPCM(coding) and XA_ADPCM_SAMPLES_PER_SECTOR_8BIT or XA_ADPCM_SAMPLES_PER_SECTOR_4BIT
end

-- duckstation cdrom::decodexaadpcmchunks.  `sector` is the raw 2352-byte
-- sector string; data starts at byte 25 (12 sync + 4 header + 8 subheader).
function Ref:decodeXaAdpcmChunks(sector, stereo, is8)
	local samples = {}
	local numBlocks = is8 and NUM_BLOCKS_8BIT or NUM_BLOCKS_4BIT
	local samplesPerChunk = WORDS_PER_CHUNK * (is8 and 4 or 8)
	local chunkStart = 25 -- 0-based offset 24
	for chunk = 0, NUM_CHUNKS - 1 do
		local base = chunkStart + chunk * CHUNK_SIZE_IN_BYTES
		for block = 0, numBlocks - 1 do
			local headerByte = sector:byte(base + 4 + block) or 0
			local shift = band(headerByte, 0x0F)
			if shift > 12 then shift = 9 end
			local filter = rshift(headerByte, 4)
			local filterPos = FILTER_TABLE_POS[filter + 1]
			local filterNeg = FILTER_TABLE_NEG[filter + 1]
			local outOffset
			local outIncrement
			if stereo then
				outOffset = math.floor(block / 2) * (WORDS_PER_BLOCK * 2) + (block % 2)
				outIncrement = 2
			else
				outOffset = block * WORDS_PER_BLOCK
				outIncrement = 1
			end
			local prevBase = stereo and ((block % 2) * 2) or 0
			for word = 0, WORDS_PER_BLOCK - 1 do
				local woff = base + 16 + word * 4
				local wordData = (sector:byte(woff) or 0)
					+ (sector:byte(woff + 1) or 0) * 256
					+ (sector:byte(woff + 2) or 0) * 65536
					+ (sector:byte(woff + 3) or 0) * 16777216
				local nibble
				if is8 then
					nibble = band(rshift(wordData, block * 8), 0xFF)
				else
					nibble = band(rshift(wordData, block * 4), 0x0F)
				end
				local sample = s16(lshift(nibble, is8 and 8 or 12))
				sample = arshift(sample, shift)
				local prev0 = self.xaLastSamples[prevBase + 1]
				local prev1 = self.xaLastSamples[prevBase + 2]
				local interp = clamp16(sample
					+ arshift(prev0 * filterPos, 6)
					+ arshift(prev1 * filterNeg, 6))
				self.xaLastSamples[prevBase + 2] = prev0
				self.xaLastSamples[prevBase + 1] = interp
				local outIndex = chunk * samplesPerChunk + outOffset
				samples[outIndex + 1] = interp
				outOffset += outIncrement
			end
		end
	end
	return samples
end

-- duckstation cdrom::resamplexaadpcm (37800 -> 44100, zigzag fir).
function Ref:resampleXaAdpcm(samples, numFrames, stereo)
	local leftRing = self.xaResampleRingBuffer[1]
	local rightRing = self.xaResampleRingBuffer[2]
	local p = self.xaResampleP
	local sixstep = self.xaResampleSixstep
	local sampleIndex = 0
	for _ = 1, numFrames do
		leftRing[p + 1] = samples[sampleIndex + 1]
		if stereo then rightRing[p + 1] = samples[sampleIndex + 2] end
		p = (p + 1) % XA_RESAMPLE_RING_BUFFER_SIZE
		sixstep -= 1
		if sixstep == 0 then
			sixstep = 6
			for j = 0, 6 do
				local left = self:zigzagInterpolate(leftRing, j, p)
				local right = stereo and self:zigzagInterpolate(rightRing, j, p) or left
				self:addCdAudioFrame(left, right)
			end
		end
		sampleIndex += stereo and 2 or 1
	end
	self.xaResampleP = band(p, 0xFF)
	self.xaResampleSixstep = band(sixstep, 0xFF)
end

function Ref:zigzagInterpolate(ringbuf, tableIndex, p)
	local table = ZIGZAG_TABLES[tableIndex + 1]
	local sum = 0
	for i = 0, 28 do
		sum += arshift(ringbuf[band(p - i, 0x1F) + 1] * table[i + 1], 15)
	end
	return s16(clamp16(sum))
end

-- duckstation cdrom::resamplexaadpcm18900.
function Ref:resampleXaAdpcm18900(samples, numFrames, stereo)
	local leftRing = self.xaResampleRingBuffer[1]
	local rightRing = self.xaResampleRingBuffer[2]
	local p = self.xaResampleP
	local sixstep = self.xaResampleSixstep
	local sampleIndex = 0
	local inSampleIndex = 0
	while inSampleIndex < numFrames do
		if sixstep >= 7 then
			sixstep -= 7
			p = (p + 1) % XA_RESAMPLE_RING_BUFFER_SIZE
			leftRing[p + 1] = samples[sampleIndex + 1]
			if stereo then rightRing[p + 1] = samples[sampleIndex + 2] end
			sampleIndex += stereo and 2 or 1
			inSampleIndex += 1
		end
		local left = self:interpolate18900(leftRing, sixstep, p)
		local right = stereo and self:interpolate18900(rightRing, sixstep, p) or left
		self:addCdAudioFrame(left, right)
		sixstep += 3
	end
	self.xaResampleP = band(p, 0xFF)
	self.xaResampleSixstep = band(sixstep, 0xFF)
end

function Ref:interpolate18900(ringbuf, tableIndex, p)
	local table = TABLES_18900[tableIndex + 1]
	local sum = 0
	for i = 0, 24 do
		sum += ringbuf[band(p + 32 - 25 + i, 0x1F) + 1] * table[i + 1]
	end
	return s16(clamp16(arshift(sum, 15)))
end

function Ref:addCdAudioFrame(left, right)
	self.audioFifo:push(bor(band(left, 0xFFFF), lshift(band(right, 0xFFFF), 16)))
end

-- duckstation cdrom::getaudioframe(): pop fifo, apply volume matrix, saturate.
function Ref:getAudioFrame()
	local frame = self.audioFifo:isEmpty() and 0 or self.audioFifo:pop()
	local left = s16(band(frame, 0xFFFF))
	local right = s16(band(rshift(frame, 16), 0xFFFF))
	local m = self.cdAudioVolumeMatrix
	local leftOut = saturateVolume(applyVolume(left, m[1][1]) + applyVolume(right, m[2][1]))
	local rightOut = saturateVolume(applyVolume(left, m[1][2]) + applyVolume(right, m[2][2]))
	return leftOut, rightOut
end

function Ref:audioFifoSize()
	return self.audioFifo:getSize()
end

function Ref:resetCurrentXaFile()
	self.xaCurrentChannel = 0
	self.xaCurrentFile = 0
	self.xaCurrentSet = false
end

-- duckstation cdrom::resetaudiodecoder.
function Ref:resetAudioDecoder()
	self.cddaAutoPausePending = false
	self:resetCurrentXaFile()
	for i = 1, 4 do self.xaLastSamples[i] = 0 end
	for ch = 1, 2 do
		for i = 1, XA_RESAMPLE_RING_BUFFER_SIZE do self.xaResampleRingBuffer[ch][i] = 0 end
		self.xaResampleP = 0
		self.xaResampleSixstep = 6
	end
	self.audioFifo:clear()
end

-- duckstation cdrom::processxaadpcmsector.  `sector` is the raw 2352-byte sector; the subheader (file, channel, submode, coding) is read from bytes 17..20 (0-based 16..19).
function Ref:processXaAdpcmSector(sector)
	local fileNumber = sector:byte(17) or 0
	local channelNumber = sector:byte(18) or 0
	local submode = sector:byte(19) or 0
	local coding = sector:byte(20) or 0
	local xaFilterEnabled = band(self.mode, 0x08) ~= 0

	-- automatic adpcm filter.
	if xaFilterEnabled and (fileNumber ~= self.xaFilterFile or channelNumber ~= self.xaFilterChannel) then
		return
	end

	-- track the current file being played.
	if not self.xaCurrentSet then
		-- junk audio sectors with channel 255 are skipped unless filtered.
		if channelNumber == 255 and (not xaFilterEnabled or self.xaFilterChannel ~= 255) then
			return
		end
		self.xaCurrentFile = fileNumber
		self.xaCurrentChannel = channelNumber
		self.xaCurrentSet = true
	elseif fileNumber ~= self.xaCurrentFile or channelNumber ~= self.xaCurrentChannel then
		return
	end

	-- reset current file on eof, and play the file in the next sector.
	if band(submode, 0x80) ~= 0 then
		self:resetCurrentXaFile()
	end

	-- the emulator's spu steps before the cdrom in the same cycle batch, so the fifo is always drained to the current cycle (duckstation's generatependingsamples call here).

	local numFrames = arshift(samplesPerSector(coding), isStereo(coding) and 1 or 0)
	if self.audioFifo:getSize() > AUDIO_FIFO_LOW_WATERMARK then
		return
	end

	-- decode always (updates previous samples even when muted).
	local sampleBuffer = self:decodeXaAdpcmChunks(sector, isStereo(coding), is8BitADPCM(coding))
	self.xaCurrentCodinginfo = coding

	if self.muted or self.adpcmMuted then
		return
	end

	local stereo = isStereo(coding)
	if stereo then
		if isHalfSampleRate(coding) then
			self:resampleXaAdpcm18900(sampleBuffer, numFrames, true)
		else
			self:resampleXaAdpcm(sampleBuffer, numFrames, true)
		end
	else
		if isHalfSampleRate(coding) then
			self:resampleXaAdpcm18900(sampleBuffer, numFrames, false)
		else
			self:resampleXaAdpcm(sampleBuffer, numFrames, false)
		end
	end
end

-- duckstation cdrom::processcddasector audio push (reports handled by the
-- emulator's cdrom).  `sector` is the raw 2352-byte sector.
function Ref:processCddaSector(sector)
	if self.muted or self.cddaAutoPausePending then
		return
	end

	-- 2 samples per channel, always stereo.  in 2x mode only half the
	-- samples in a sector get processed.
	local doubleSpeed = self.doubleSpeed
	local numSamples = math.floor(2352 / 2 / (doubleSpeed and 4 or 2))
	local remaining = self.audioFifo:getSpace()
	if remaining < numSamples then
		self.audioFifo:remove(numSamples - remaining)
	end

	local step = doubleSpeed and 8 or 4
	for i = 0, numSamples - 1 do
		local off = 1 + i * step
		local left = s16((sector:byte(off) or 0) + (sector:byte(off + 1) or 0) * 256)
		local right = s16((sector:byte(off + 2) or 0) + (sector:byte(off + 3) or 0) * 256)
		self:addCdAudioFrame(left, right)
	end
end

return Ref
