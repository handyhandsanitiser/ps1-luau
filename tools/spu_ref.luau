-- independent spu reference model used by _diff_spu.  every algorithm is transcribed from
-- duckstation spu.cpp with psx-spx as the hardware check; this module never requires the emulator
-- spu, so any mutation in src/shared/ps1/spu.luau is visible to the differential harness.
-- scope: 24 voices (adpcm, gaussian interpolation, adsr, volume sweeps, pitch modulation, noise),
-- master mixing, the 22050 hz reverb processor, capture buffers, cd audio mixing, kon/koff/endx,
-- and the per-frame execute ordering.
local Ref = {}
Ref.__index = Ref

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift
local bnot = bit32.bnot

local BASE = 0x1F801C00
local RAM_MASK = 0x7FFFF
local RAM_HALFWORDS = 0x40000
local MASTER_TO_SAMPLE = 768
local VOICES = 24
local BLOCK_SAMPLES = 28
local CAPTURE_SIZE = 0x400
local MAX16 = 0x7FFF
local MIN16 = -0x8000

local function s16(v)
	v = band(v, 0xFFFF)
	return v >= 0x8000 and v - 0x10000 or v
end

local function u16(v)
	return band(v, 0xFFFF)
end

local function arshift(v, n)
	return math.floor(v / (2 ^ n))
end

local function clamp16(v)
	if v < MIN16 then return MIN16 end
	if v > MAX16 then return MAX16 end
	return math.floor(v)
end

local function applyVolume(sample, volume)
	return arshift(sample * s16(volume), 15)
end

-- neg() from duckstation processreverb: -32768 maps to 0x7fff (not +32768).
local function neg(v)
	return (v == -0x8000) and 0x7FFF or -v
end

-- duckstation's adpcm predictor tables (16 entries; unsupported filters -> 0).
local POS = { 0, 60, 115, 98, 122, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
local NEG = { 0, 0, -52, -55, -60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }

-- duckstation reverb 39-tap fir, zeros removed.  the 0x4000 center tap is
-- handled separately in the downsample stage (sample offset 19).
local REVERB_COEFF = { -1, 2, -10, 35, -103, 266, -616, 1332, -2960, 10246, 10246, -2960, 1332, -616, 266, -103, 35, -10, 2, -1 }

-- duckstation noise frequency add table (index 5 is the 0x10000 boundary).
local NOISE_FREQ_ADD = { 0, 84, 140, 180, 210 }
-- duckstation noise wave add table (dr hell waveform, 64 entries).
local NOISE_WAVE_ADD = {
	1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0,
	1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0,
	0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1,
	0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1,
}

-- gaussian interpolation table (512 q15 entries, 1-based).
local GAUSS = {
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 3, 3,
	3, 4, 4, 5, 5, 6, 7, 7, 8, 9, 9, 10, 11, 12, 13, 14,
	15, 16, 17, 18, 19, 21, 22, 24, 25, 27, 28, 30, 32, 33, 35, 37,
	39, 41, 44, 46, 48, 51, 53, 56, 58, 61, 64, 67, 70, 73, 77, 80,
	84, 87, 91, 95, 99, 103, 107, 111, 116, 120, 125, 130, 135, 140, 145, 150,
	156, 161, 167, 173, 179, 186, 192, 199, 205, 212, 219, 227, 234, 242, 250, 257,
	266, 274, 283, 291, 300, 309, 319, 328, 338, 348, 358, 369, 379, 390, 401, 412,
	424, 436, 448, 460, 473, 485, 498, 512, 525, 539, 553, 567, 582, 597, 612, 627,
	643, 659, 675, 692, 708, 726, 743, 761, 779, 797, 816, 835, 854, 874, 894, 914,
	935, 956, 977, 999, 1020, 1043, 1066, 1089, 1112, 1136, 1160, 1184, 1209, 1234, 1260, 1286,
	1312, 1339, 1366, 1394, 1422, 1450, 1479, 1508, 1537, 1567, 1598, 1628, 1660, 1691, 1723, 1756,
	1789, 1822, 1856, 1890, 1924, 1959, 1995, 2031, 2067, 2104, 2141, 2179, 2217, 2256, 2295, 2334,
	2374, 2415, 2456, 2497, 2539, 2582, 2624, 2668, 2712, 2756, 2801, 2846, 2892, 2938, 2985, 3032,
	3079, 3128, 3176, 3225, 3275, 3325, 3376, 3427, 3479, 3531, 3584, 3637, 3691, 3745, 3799, 3855,
	3910, 3967, 4023, 4081, 4138, 4197, 4255, 4315, 4374, 4435, 4495, 4557, 4619, 4681, 4744, 4807,
	4871, 4935, 5000, 5065, 5131, 5197, 5264, 5332, 5399, 5468, 5536, 5606, 5676, 5746, 5817, 5888,
	5959, 6032, 6104, 6177, 6251, 6325, 6400, 6475, 6550, 6626, 6702, 6779, 6856, 6934, 7012, 7091,
	7170, 7249, 7329, 7409, 7490, 7571, 7653, 7735, 7817, 7900, 7983, 8066, 8150, 8234, 8319, 8404,
	8489, 8575, 8661, 8748, 8834, 8922, 9009, 9097, 9185, 9273, 9362, 9451, 9541, 9630, 9720, 9811,
	9901, 9992, 10083, 10174, 10266, 10358, 10450, 10542, 10635, 10727, 10820, 10913, 11007, 11100, 11194, 11288,
	11382, 11476, 11571, 11665, 11760, 11855, 11950, 12045, 12140, 12236, 12331, 12427, 12522, 12618, 12714, 12809,
	12905, 13001, 13097, 13193, 13289, 13385, 13481, 13577, 13673, 13769, 13865, 13961, 14056, 14152, 14248, 14343,
	14439, 14534, 14630, 14725, 14820, 14915, 15010, 15104, 15199, 15293, 15387, 15481, 15575, 15669, 15762, 15855,
	15948, 16041, 16133, 16226, 16317, 16409, 16500, 16592, 16682, 16773, 16863, 16953, 17042, 17131, 17220, 17308,
	17396, 17484, 17571, 17658, 17744, 17830, 17916, 18001, 18086, 18170, 18254, 18337, 18420, 18502, 18584, 18665,
	18746, 18826, 18905, 18985, 19063, 19141, 19219, 19295, 19372, 19447, 19522, 19597, 19671, 19744, 19816, 19888,
	19959, 20030, 20100, 20169, 20238, 20306, 20373, 20439, 20505, 20570, 20634, 20698, 20760, 20822, 20884, 20944,
	21004, 21063, 21121, 21178, 21235, 21290, 21345, 21399, 21452, 21505, 21556, 21607, 21657, 21706, 21754, 21801,
	21848, 21893, 21938, 21982, 22025, 22066, 22107, 22148, 22187, 22225, 22262, 22299, 22334, 22369, 22402, 22435,
	22467, 22498, 22527, 22556, 22584, 22611, 22637, 22662, 22686, 22709, 22731, 22752, 22772, 22791, 22809, 22826,
	22842, 22857, 22872, 22885, 22897, 22908, 22918, 22927, 22935, 22942, 22948, 22953, 22957, 22960, 22962, 22963,
}

-- duckstation volumeenvelope.reset (rate/rate_mask/decreasing/exponential/phase_invert).
local function envelopeReset(env, rate, rateMask, decreasing, exponential, phaseInvert)
	env.rate = rate
	env.decreasing = decreasing
	env.exponential = exponential
	env.phaseInvert = phaseInvert and not (decreasing and exponential)
	env.counter = 0
	env.counterIncrement = 0x8000
	local baseStep = 7 - band(rate, 3)
	local step = ((decreasing ~= env.phaseInvert) or (decreasing and exponential)) and bnot(baseStep) or baseStep
	step = s16(step)
	if rate < 44 then
		step = step * (2 ^ (11 - rshift(rate, 2)))
	elseif rate >= 48 then
		env.counterIncrement = arshift(env.counterIncrement, rshift(rate, 2) - 11)
		if band(rate, rateMask) ~= rateMask then
			env.counterIncrement = math.max(env.counterIncrement, 1)
		end
	end
	env.step = step
end

-- duckstation volumeenvelope.tick; returns (level, still_active).
local function envelopeTick(env, level)
	local inc = env.counterIncrement
	local step = env.step
	if env.exponential then
		if env.decreasing then
			step = arshift(step * level, 15)
		elseif level >= 0x6000 then
			if env.rate < 40 then
				step = arshift(step, 2)
			elseif env.rate >= 44 then
				inc = arshift(inc, 2)
			else
				step = arshift(step, 1)
				inc = arshift(inc, 1)
			end
		end
	end
	env.counter += inc
	if band(env.counter, 0x8000) == 0 then return level, true end
	env.counter = 0
	local nextLevel = level + step
	if not env.decreasing then
		nextLevel = clamp16(math.max(MIN16, math.min(MAX16, nextLevel)))
		return nextLevel, nextLevel ~= (step < 0 and MIN16 or MAX16)
	elseif env.phaseInvert then
		nextLevel = clamp16(math.max(MIN16, math.min(0, nextLevel)))
		return nextLevel, nextLevel < 0
	end
	nextLevel = math.max(nextLevel, 0)
	return nextLevel, nextLevel > 0
end

-- duckstation volumesweep.reset / tick.
local function sweepReset(sweep, reg)
	if band(reg, 0x8000) == 0 then
		sweep.level = s16(band(reg, 0x7FFF) * 2)
		sweep.active = false
		return
	end
	envelopeReset(sweep.env, band(reg, 0x7F), 0x7F, band(reg, 0x2000) ~= 0, band(reg, 0x4000) ~= 0, band(reg, 0x1000) ~= 0)
	sweep.active = sweep.env.counterIncrement > 0
end

local function sweepTick(sweep)
	if sweep.active then sweep.level, sweep.active = envelopeTick(sweep.env, sweep.level) end
end

local function newSweep()
	return { level = 0, active = false, env = {} }
end

local function newVoice()
	return {
		regs = { 0, 0, 0, 0, 0, 0, 0, 0 },
		currentAddress = 0,
		counter = 0,
		flags = 0,
		firstBlock = false,
		hasSamples = false,
		samples = table.create(31, 0),
		lastSamples = { 0, 0 },
		lastVolume = 0,
		left = newSweep(),
		right = newSweep(),
		adsr = { level = 0, phase = 0, target = 0, env = {} },
		ignoreLoopAddress = false,
	}
end

function Ref.new()
	local self = setmetatable({}, Ref)
	self.reg = {}
	self.ram = table.create(RAM_HALFWORDS, 0)
	self.transferAddressReg = 0
	self.transferAddress = 0
	self.irqAddressReg = 0
	self.spustat = 0
	self.spucnt = 0
	self.transferControl = 0
	self.voices = {}
	for i = 1, VOICES do self.voices[i] = newVoice() end
	self.mainLeft = newSweep()
	self.mainRight = newSweep()
	self.cdLeft, self.cdRight = 0, 0
	self.extLeft, self.extRight = 0, 0
	self.keyOn, self.keyOff, self.endx = 0, 0, 0
	self.pmon, self.non, self.eon = 0, 0, 0
	self.noiseCount, self.noiseLevel = 0, 1
	self.reverb = table.create(32, 0)
	self.reverbOutLeft, self.reverbOutRight = 0, 0
	self.reverbBase, self.reverbCurrent = 0, 0
	self.reverbPos = 0
	self.reverbDown = { table.create(128, 0), table.create(128, 0) }
	self.reverbUp = { table.create(64, 0), table.create(64, 0) }
	self.lastReverbInput = { 0, 0 }
	self.lastReverbOutput = { 0, 0 }
	self.capturePos = 0
	-- injectable cd audio frame (s16 pair).  xa/cd-da decode lives in the
	-- cdrom subsystem; this seam lets the mixing math be tested in isolation.
	self.cdAudioFrame = { 0, 0 }
	self.pendingCycles = 0
	self.sampleCount = 0
	self.outputSamples = {}
	self.outputStart = 1
	self.queuedSamples = 0
	self.maxOutputSamples = 8192
	return self
end

function Ref:setCdAudioFrame(left, right)
	self.cdAudioFrame[1], self.cdAudioFrame[2] = left, right
end

-- voices

function Ref:voiceAdsrUpdate(v)
	local phase = v.adsr.phase
	if phase == 0 then
		envelopeReset(v.adsr.env, 0, 0, false, false, false)
		v.adsr.target = 0
	elseif phase == 1 then
		v.adsr.target = MAX16
		envelopeReset(v.adsr.env, band(rshift(v.regs[5], 8), 0x7F), 0x7F, false, band(v.regs[5], 0x8000) ~= 0, false)
	elseif phase == 2 then
		v.adsr.target = math.min((band(v.regs[5], 0xF) + 1) * 0x800, MAX16)
		envelopeReset(v.adsr.env, lshift(band(rshift(v.regs[5], 4), 0xF), 2), 0x7C, true, true, false)
	elseif phase == 3 then
		v.adsr.target = 0
		local hi = v.regs[6]
		envelopeReset(v.adsr.env, band(rshift(hi, 6), 0x7F), 0x7F, band(hi, 0x4000) ~= 0, band(hi, 0x8000) ~= 0, false)
	elseif phase == 4 then
		v.adsr.target = 0
		envelopeReset(v.adsr.env, lshift(band(v.regs[6], 0x1F), 2), 0x7C, true, band(v.regs[6], 0x20) ~= 0, false)
	end
end

function Ref:keyOnVoice(v)
	v.currentAddress = band(v.regs[4], 0xFFFE)
	v.counter = 0
	v.regs[7] = 0
	v.lastSamples[1], v.lastSamples[2] = 0, 0
	v.samples[1], v.samples[2], v.samples[3] = 0, 0, 0
	v.hasSamples = false
	v.firstBlock = true
	v.ignoreLoopAddress = false
	v.adsr.level, v.adsr.phase = 0, 1
	self:voiceAdsrUpdate(v)
end

function Ref:keyOffVoice(v)
	if v.adsr.phase == 0 or v.adsr.phase == 4 then return end
	v.adsr.phase = 4
	self:voiceAdsrUpdate(v)
end

function Ref:forceOffVoice(v)
	v.regs[7] = 0
	v.adsr.level, v.adsr.phase = 0, 0
end

function Ref:decodeBlock(v)
	local a = band(v.currentAddress * 8, RAM_MASK)
	local header, flags = self:readRamByte(a), self:readRamByte(a + 1)
	local shift = band(header, 0xF)
	if shift > 12 then shift = 9 end
	local filter = rshift(header, 4)
	local p, n = POS[filter + 1] or 0, NEG[filter + 1] or 0
	v.samples[3], v.samples[2], v.samples[1] = v.samples[31], v.samples[30], v.samples[29]
	local p0, p1 = v.lastSamples[1], v.lastSamples[2]
	for i = 0, BLOCK_SAMPLES - 1 do
		local b = self:readRamByte(a + 2 + math.floor(i / 2))
		local nibble = band(rshift(b, (i % 2) * 4), 0xF)
		if nibble >= 8 then nibble -= 16 end
		local sample = arshift(nibble * 4096, shift) + arshift(p0 * p, 6) + arshift(p1 * n, 6)
		p1, p0 = p0, clamp16(sample)
		v.samples[4 + i] = p0
	end
	v.lastSamples[1], v.lastSamples[2] = p0, p1
	v.flags = flags
	v.hasSamples = true
	if band(flags, 4) ~= 0 and not v.ignoreLoopAddress then v.regs[8] = v.currentAddress end
end

function Ref:interpolate(v)
	local i = band(math.floor(v.counter / 16), 0xFF)
	local sample = band(math.floor(v.counter / 4096), 0x1F) + 4
	return arshift(
		GAUSS[0x100 - i] * (v.samples[sample - 3] or 0) +
			GAUSS[0x200 - i] * (v.samples[sample - 2] or 0) +
			GAUSS[0x101 + i] * (v.samples[sample - 1] or 0) +
			GAUSS[1 + i] * (v.samples[sample] or 0), 15)
end

-- getnextadsrphase from duckstation: attack->decay, decay->sustain,
-- sustain->sustain, release->off.
local function nextAdsrPhase(phase)
	if phase == 1 then return 2 end
	if phase == 2 then return 3 end
	if phase == 3 then return 3 end
	return 0
end

function Ref:sampleVoice(index)
	local v = self.voices[index]
	if v.adsr.phase == 0 and band(self.spucnt, 0x0040) == 0 then
		v.lastVolume = 0
		return 0, 0
	end
	if not v.hasSamples then self:decodeBlock(v) end
	local value = 0
	if v.adsr.level ~= 0 then
		local sample
		if band(self.non, lshift(1, index - 1)) ~= 0 then
			sample = s16(self.noiseLevel)
		else
			sample = self:interpolate(v)
		end
		value = applyVolume(sample, v.adsr.level)
	end
	v.lastVolume = value
	if v.adsr.phase ~= 0 then
		if v.adsr.env.counterIncrement > 0 then
			v.adsr.level, _ = envelopeTick(v.adsr.env, v.adsr.level)
		end
		if v.adsr.phase ~= 3 then
			local reached = v.adsr.env.decreasing and v.adsr.level <= v.adsr.target or (not v.adsr.env.decreasing and v.adsr.level >= v.adsr.target)
			if reached then
				v.adsr.phase = nextAdsrPhase(v.adsr.phase)
				self:voiceAdsrUpdate(v)
			end
		end
	end
	local step = v.regs[3]
	if index > 1 and band(self.pmon, lshift(1, index - 1)) ~= 0 then
		local factor = math.max(-0x8000, math.min(0x7FFF, self.voices[index - 1].lastVolume)) + 0x8000
		step = band(arshift(s16(step) * factor, 15), 0xFFFF)
	end
	step = math.min(step, 0x3FFF)
	v.counter += step
	if math.floor(v.counter / 4096) >= BLOCK_SAMPLES then
		v.counter -= BLOCK_SAMPLES * 4096
		v.hasSamples = false
		v.firstBlock = false
		v.currentAddress = band(v.currentAddress + 2, 0xFFFF)
		if band(v.flags, 1) ~= 0 then
			self.endx = bor(self.endx, lshift(1, index - 1))
			v.currentAddress = band(v.regs[8], 0xFFFE)
			if band(v.flags, 2) == 0 and band(self.non, lshift(1, index - 1)) == 0 then self:forceOffVoice(v) end
		end
	end
	local left, right = applyVolume(value, v.left.level), applyVolume(value, v.right.level)
	sweepTick(v.left)
	sweepTick(v.right)
	return left, right
end

-- noise

function Ref:updateNoise()
	local noiseClock = band(rshift(self.spucnt, 8), 0x3F)
	local level = lshift(rshift(0x8000, rshift(noiseClock, 2)), 16)
	self.noiseCount = band(self.noiseCount + 0x10000 + NOISE_FREQ_ADD[band(noiseClock, 3) + 1], 0xFFFFFFFF)
	if band(self.noiseCount, 0xFFFF) >= NOISE_FREQ_ADD[5] then
		self.noiseCount = band(self.noiseCount + 0x10000 - NOISE_FREQ_ADD[band(noiseClock, 3) + 1], 0xFFFFFFFF)
	end
	if self.noiseCount < level then return end
	if level == 0 then return end
	self.noiseCount = self.noiseCount % level
	self.noiseLevel = bor(band(lshift(self.noiseLevel, 1), 0xFFFFFFFF), NOISE_WAVE_ADD[band(rshift(self.noiseLevel, 10), 0x3F) + 1])
end

-- reverb

function Ref:reverbAddress(address, offset)
	-- duckstation reverbmemoryaddress: offset = current + (addr & 0x3ffff); add base when bit 18 set; return (offset & 0x3ffff) * 2
	local a = band(address * 4 + (offset or 0), 0x3FFFF)
	local p = self.reverbCurrent + a
	if band(p, 0x40000) ~= 0 then p = p + self.reverbBase end
	return band(p, 0x3FFFF) * 2
end

function Ref:reverbRead(address, offset)
	local a = self:reverbAddress(address, offset)
	return s16(self.ram[math.floor(a / 2) + 1] or 0)
end

function Ref:reverbWrite(address, value)
	local a = self:reverbAddress(address, 0)
	self.ram[math.floor(a / 2) + 1] = u16(clamp16(value))
end

-- duckstation processreverb, transliterated without vectorization.
function Ref:processReverb(leftIn, rightIn)
	leftIn = clamp16(leftIn)
	rightIn = clamp16(rightIn)
	self.lastReverbInput[1], self.lastReverbInput[2] = leftIn, rightIn
	local pos = self.reverbPos
	self.reverbDown[1][pos + 1], self.reverbDown[1][pos + 65] = leftIn, leftIn
	self.reverbDown[2][pos + 1], self.reverbDown[2][pos + 65] = rightIn, rightIn
	local outL, outR = 0, 0
	if band(pos, 1) ~= 0 then
		-- downsample fir: 20 nonzero taps at even offsets, center 0x4000 at +19.
		local downsampled = { 0, 0 }
		for channel = 1, 2 do
			local src = band(pos - 38, 0x3F)
			local acc = 0
			for k = 0, 19 do
				local si = band(src + math.floor(k / 4) * 8 + (k % 4) * 2, 0x3F)
				acc += REVERB_COEFF[k + 1] * self.reverbDown[channel][si + 1]
			end
			acc += 0x4000 * self.reverbDown[channel][band(src + 19, 0x3F) + 1]
			downsampled[channel] = clamp16(arshift(acc, 15))
		end
		for channel = 1, 2 do
			if band(self.spucnt, 0x80) ~= 0 then
				local alpha = s16(self.reverb[3])
				local coef = s16(self.reverb[8])
				local iiasm
				if alpha == -0x8000 then
					iiasm = function(sample) return (sample == -0x8000) and 0 or (sample * -0x10000) end
				else
					iiasm = function(sample) return sample * (0x8000 - alpha) end
				end
				local inputA = clamp16(arshift(arshift(self:reverbRead(self.reverb[17 + channel - 1], 0) * coef, 14) + arshift(downsampled[channel] * s16(self.reverb[30 + channel]), 14), 1))
				local inputB = clamp16(arshift(arshift(self:reverbRead(self.reverb[27 - channel], 0) * coef, 14) + arshift(downsampled[channel] * s16(self.reverb[30 + channel]), 14), 1))
				local destA = self.reverb[10 + channel]
				local destB = self.reverb[18 + channel]
				local iirA = clamp16(arshift(arshift(inputA * alpha, 14) + arshift(iiasm(self:reverbRead(destA, -1)), 14), 1))
				local iirB = clamp16(arshift(arshift(inputB * alpha, 14) + arshift(iiasm(self:reverbRead(destB, -1)), 14), 1))
				self:reverbWrite(destA, iirA)
				self:reverbWrite(destB, iirB)
			end
			local accv = 0
			local accSources = { 13, 15, 21, 23 }
			for j = 0, 3 do
				accv += arshift(self:reverbRead(self.reverb[accSources[j + 1] + channel - 1], 0) * s16(self.reverb[4 + j]), 14)
			end
			local fbA = self:reverbRead(self.reverb[27 + channel - 1] - self.reverb[1], 0)
			local fbB = self:reverbRead(self.reverb[29 + channel - 1] - self.reverb[2], 0)
			local mda = clamp16(arshift(accv + arshift(fbA * neg(s16(self.reverb[9])), 14), 1))
			local mdb = clamp16(fbA + arshift(arshift(mda * s16(self.reverb[9]), 14) + arshift(fbB * neg(s16(self.reverb[10])), 14), 1))
			local echo = clamp16(fbB + arshift(mdb * s16(self.reverb[10]), 15))
			local up = math.floor(pos / 2) % 32
			self.reverbUp[channel][up + 1], self.reverbUp[channel][up + 33] = echo, echo
			if band(self.spucnt, 0x80) ~= 0 then
				self:reverbWrite(self.reverb[27 + channel - 1], mda)
				self:reverbWrite(self.reverb[29 + channel - 1], mdb)
			end
		end
		self.reverbCurrent = band(self.reverbCurrent + 1, 0x3FFFF)
		if self.reverbCurrent == 0 then self.reverbCurrent = self.reverbBase end
	end
	local up = band(math.floor(pos / 2) - 19, 0x1F)
	if band(pos, 1) ~= 0 then
		-- upsample fir: 20 consecutive taps, >>14.
		for channel = 1, 2 do
			local acc = 0
			for k = 0, 19 do
				local si = band(up + k, 0x1F)
				acc += REVERB_COEFF[k + 1] * self.reverbUp[channel][si + 1]
			end
			if channel == 1 then outL = clamp16(arshift(acc, 14)) else outR = clamp16(arshift(acc, 14)) end
		end
	else
		-- even position: reuse the value computed on the previous odd step.
		local idx = up + 9
		outL = self.reverbUp[1][idx + 1] or 0
		outR = self.reverbUp[2][idx + 1] or 0
	end
	self.reverbPos = band(pos + 1, 0x3F)
	self.lastReverbOutput[1] = applyVolume(outL, self.reverbOutLeft)
	self.lastReverbOutput[2] = applyVolume(outR, self.reverbOutRight)
	return self.lastReverbOutput[1], self.lastReverbOutput[2]
end

-- capture buffers

function Ref:writeToCaptureBuffer(index, value)
	local addr = band(index * CAPTURE_SIZE + self.capturePos, RAM_MASK)
	self.ram[math.floor(addr / 2) + 1] = u16(value)
end

function Ref:incrementCapturePosition()
	self.capturePos = band(self.capturePos + 2, CAPTURE_SIZE - 1)
	if self.capturePos >= CAPTURE_SIZE / 2 then
		self.spustat = bor(self.spustat, 0x800)
	else
		self.spustat = band(self.spustat, bnot(0x800))
	end
end

-- frame generation (duckstation execute loop)

function Ref:applyPendingKeys()
	for i = 1, VOICES do
		local bit = lshift(1, i - 1)
		if band(self.keyOff, bit) ~= 0 then self:keyOffVoice(self.voices[i]) end
		if band(self.keyOn, bit) ~= 0 then
			self.endx = band(self.endx, bnot(bit))
			self:keyOnVoice(self.voices[i])
		end
	end
	self.keyOff, self.keyOn = 0, 0
end

function Ref:generateFrame()
	local left, right, revL, revR = 0, 0, 0, 0
	for i = 1, VOICES do
		local l, r = self:sampleVoice(i)
		left += l
		right += r
		if band(self.eon, lshift(1, i - 1)) ~= 0 then
			revL += l
			revR += r
		end
	end
	if band(self.spucnt, 0x4000) == 0 then left, right, revL, revR = 0, 0, 0, 0 end
	self:updateNoise()
	-- cd audio mix.
	local cdL, cdR = self.cdAudioFrame[1], self.cdAudioFrame[2]
	if band(self.spucnt, 0x0001) ~= 0 then
		local vL = applyVolume(cdL, self.cdLeft)
		local vR = applyVolume(cdR, self.cdRight)
		left += vL
		right += vR
		if band(self.spucnt, 0x0004) ~= 0 then
			revL += vL
			revR += vR
		end
	end
	local reL, reR = self:processReverb(revL, revR)
	left, right = clamp16(left + reL), clamp16(right + reR)
	left = applyVolume(left, self.mainLeft.level)
	right = applyVolume(right, self.mainRight.level)
	local output = self.outputSamples
	output[#output + 1], output[#output + 2] = s16(left), s16(right)
	self.queuedSamples += 2
	if self.queuedSamples > self.maxOutputSamples then
		self.outputStart += 2
		self.queuedSamples -= 2
	end
	sweepTick(self.mainLeft)
	sweepTick(self.mainRight)
	self.sampleCount += 1
	-- capture buffers (duckstation: after main volume; raw cd frame for ch 0/1,
	-- voices 1 and 3 (0-based) after adsr for ch 2/3).
	self:writeToCaptureBuffer(0, cdL)
	self:writeToCaptureBuffer(1, cdR)
	self:writeToCaptureBuffer(2, clamp16(self.voices[2].lastVolume))
	self:writeToCaptureBuffer(3, clamp16(self.voices[4].lastVolume))
	self:incrementCapturePosition()
	self:applyPendingKeys()
end

-- transfer-ram access (mirrors the emulator's writeramhalf/readramhalf incl. the transfer-done irq flag in spustat); no host interrupt callback in the reference.
function Ref:writeTransferHalf(value)
	self.ram[math.floor(self.transferAddress / 2) + 1] = u16(value)
	self.transferAddress = band(self.transferAddress + 2, RAM_MASK)
	if band(self.spucnt, 0x8040) == 0x8040 and band(self.spustat, 0x40) == 0 then
		if self.transferAddress == band(self.irqAddressReg * 8, RAM_MASK) then
			self.spustat = bor(self.spustat, 0x40)
		end
	end
end

function Ref:writeDmaWord(word)
	self:writeTransferHalf(word)
	self:writeTransferHalf(bit32.rshift(word, 16))
end

function Ref:readTransferHalf()
	local address = self.transferAddress
	local value = self.ram[math.floor(address / 2) + 1] or 0
	self.transferAddress = band(address + 2, RAM_MASK)
	if band(self.spucnt, 0x8040) == 0x8040 and band(self.spustat, 0x40) == 0 then
		if self.transferAddress == band(self.irqAddressReg * 8, RAM_MASK) then
			self.spustat = bor(self.spustat, 0x40)
		end
	end
	return value
end

function Ref:readDmaWord()
	local lo, hi = self:readTransferHalf(), self:readTransferHalf()
	return bor(lo, bit32.lshift(hi, 16))
end

function Ref:step(cycles)
	if cycles <= 0 then return end
	self.pendingCycles += cycles
	local frames = math.floor(self.pendingCycles / MASTER_TO_SAMPLE)
	self.pendingCycles = self.pendingCycles % MASTER_TO_SAMPLE
	for _ = 1, frames do self:generateFrame() end
end

function Ref:drainOutputSamples()
	local out = {}
	for i = self.outputStart, #self.outputSamples do out[#out + 1] = self.outputSamples[i] end
	self.outputSamples = {}
	self.outputStart = 1
	self.queuedSamples = 0
	return out
end

-- registers

function Ref:readRamByte(address)
	local word = self.ram[math.floor(band(address, RAM_MASK) / 2) + 1] or 0
	return band(rshift(word, band(address, 1) * 8), 0xFF)
end

local function voiceForAddress(address)
	local off = address - BASE
	if off >= 0 and off < 0x180 then
		local index = math.floor(off / 0x10) + 1
		local reg = off % 0x10
		if index <= VOICES and reg % 2 == 0 then return index, reg end
	end
	return nil
end

function Ref:write(address, value)
	if band(address, 1) ~= 0 then return end
	value = u16(value)
	local voice, reg = voiceForAddress(address)
	if voice then
		local v = self.voices[voice]
		v.regs[reg / 2 + 1] = value
		if reg == 0 then
			sweepReset(v.left, value)
		elseif reg == 2 then
			sweepReset(v.right, value)
		elseif reg == 8 or reg == 10 then
			if v.adsr.phase ~= 0 then self:voiceAdsrUpdate(v) end
		elseif reg == 12 then
			v.adsr.level = s16(value)
		elseif reg == 14 then
			local ignore = v.adsr.phase == 0 or not v.firstBlock
			v.ignoreLoopAddress = v.ignoreLoopAddress or ignore
		end
		self.reg[address] = value
		return
	end
	if address == 0x1F801D80 then
		self.reg[address] = value
		sweepReset(self.mainLeft, value)
	elseif address == 0x1F801D82 then
		self.reg[address] = value
		sweepReset(self.mainRight, value)
	elseif address == 0x1F801D84 then
		self.reg[address] = value
		self.reverbOutLeft = s16(value)
	elseif address == 0x1F801D86 then
		self.reg[address] = value
		self.reverbOutRight = s16(value)
	elseif address == 0x1F801D88 then self.keyOn = bor(band(self.keyOn, 0xFFFF0000), value)
	elseif address == 0x1F801D8A then self.keyOn = bor(band(self.keyOn, 0xFFFF), lshift(value, 16))
	elseif address == 0x1F801D8C then self.keyOff = bor(band(self.keyOff, 0xFFFF0000), value)
	elseif address == 0x1F801D8E then self.keyOff = bor(band(self.keyOff, 0xFFFF), lshift(value, 16))
	elseif address == 0x1F801D90 then self.pmon = bor(band(self.pmon, 0xFFFF0000), value)
	elseif address == 0x1F801D92 then self.pmon = bor(band(self.pmon, 0xFFFF), lshift(value, 16))
	elseif address == 0x1F801D94 then self.non = bor(band(self.non, 0xFFFF0000), value)
	elseif address == 0x1F801D96 then self.non = bor(band(self.non, 0xFFFF), lshift(value, 16))
	elseif address == 0x1F801D98 then self.eon = bor(band(self.eon, 0xFFFF0000), value)
	elseif address == 0x1F801D9A then self.eon = bor(band(self.eon, 0xFFFF), lshift(value, 16))
	elseif address == 0x1F801DA2 then
		-- mbase lives outside the 0x1f801dc0..df register file (index 0).
		self.reverb[0] = value
		self.reverbBase = band(lshift(value, 2), 0x3FFFF)
		self.reverbCurrent = self.reverbBase
	elseif address == 0x1F801DA4 then self.irqAddressReg = value
	elseif address == 0x1F801DA6 then
		self.transferAddressReg = value
		self.transferAddress = band(value * 8, RAM_MASK)
	elseif address == 0x1F801DA8 then
		self:writeTransferHalf(value)
	elseif address == 0x1F801DAA then
		if band(value, 0x0040) == 0 then self.spustat = band(self.spustat, bnot(0x40)) end
		if band(value, 0x8000) == 0 and band(self.spucnt, 0x8000) ~= 0 then
			for i = 1, VOICES do self:forceOffVoice(self.voices[i]) end
		end
		self.spucnt = value
		self.spustat = bor(band(self.spustat, 0xFFC0), band(value, 0x3F))
	elseif address == 0x1F801DAC then self.transferControl = value
	elseif address == 0x1F801DB0 then self.cdLeft = s16(value)
	elseif address == 0x1F801DB2 then self.cdRight = s16(value)
	elseif address == 0x1F801DB4 then self.extLeft = s16(value)
	elseif address == 0x1F801DB6 then self.extRight = s16(value)
	elseif address == 0x1F801DB8 then self.mainLeft.level = s16(value)
	elseif address == 0x1F801DBA then self.mainRight.level = s16(value)
	elseif address >= 0x1F801DC0 and address < 0x1F801E00 then
		self.reverb[math.floor((address - 0x1F801DC0) / 2) + 1] = value
	else
		self.reg[address] = value
	end
end

function Ref:readRegister16(address)
	local v, voice, reg = 0, voiceForAddress(address)
	if voice then
		v = (reg == 12) and self.voices[voice].adsr.level or self.voices[voice].regs[reg / 2 + 1] or 0
	elseif address == 0x1F801D80 then v = self.reg[address] or 0
	elseif address == 0x1F801D82 then v = self.reg[address] or 0
	elseif address == 0x1F801D84 then v = self.reverbOutLeft
	elseif address == 0x1F801D86 then v = self.reverbOutRight
	elseif address == 0x1F801D88 then v = band(self.keyOn, 0xFFFF)
	elseif address == 0x1F801D8A then v = band(rshift(self.keyOn, 16), 0xFFFF)
	elseif address == 0x1F801D8C then v = band(self.keyOff, 0xFFFF)
	elseif address == 0x1F801D8E then v = band(rshift(self.keyOff, 16), 0xFFFF)
	elseif address == 0x1F801D90 then v = band(self.pmon, 0xFFFF)
	elseif address == 0x1F801D92 then v = band(rshift(self.pmon, 16), 0xFFFF)
	elseif address == 0x1F801D94 then v = band(self.non, 0xFFFF)
	elseif address == 0x1F801D96 then v = band(rshift(self.non, 16), 0xFFFF)
	elseif address == 0x1F801D98 then v = band(self.eon, 0xFFFF)
	elseif address == 0x1F801D9A then v = band(rshift(self.eon, 16), 0xFFFF)
	elseif address == 0x1F801D9C then v = band(self.endx, 0xFFFF)
	elseif address == 0x1F801D9E then v = band(rshift(self.endx, 16), 0xFFFF)
	elseif address == 0x1F801DA2 then v = self.reverb[0]
	elseif address == 0x1F801DA4 then v = self.irqAddressReg
	elseif address == 0x1F801DA6 then v = self.transferAddressReg
	elseif address == 0x1F801DA8 then v = 0xFFFF
	elseif address == 0x1F801DAA then v = self.spucnt
	elseif address == 0x1F801DAC then v = self.transferControl
	elseif address == 0x1F801DAE then v = bor(band(self.spustat, 0xFFC0), band(self.spucnt, 0x3F))
	elseif address == 0x1F801DB0 then v = self.cdLeft
	elseif address == 0x1F801DB2 then v = self.cdRight
	elseif address == 0x1F801DB4 then v = self.extLeft
	elseif address == 0x1F801DB6 then v = self.extRight
	elseif address == 0x1F801DB8 then v = self.mainLeft.level
	elseif address == 0x1F801DBA then v = self.mainRight.level
	elseif address >= 0x1F801DC0 and address < 0x1F801E00 then v = self.reverb[math.floor((address - 0x1F801DC0) / 2) + 1] or 0
	elseif address >= 0x1F801E00 and address < 0x1F801E60 then
		local i = math.floor((address - 0x1F801E00) / 4) + 1
		v = (band(address, 2) == 0) and self.voices[i].left.level or self.voices[i].right.level
	else v = self.reg[address] or 0xFFFF end
	return u16(v)
end

-- standalone helpers used by the diff harness for primitive comparisons.
function Ref.envelopeReset(rate, rateMask, decreasing, exponential, phaseInvert)
	local env = {}
	envelopeReset(env, rate, rateMask, decreasing, exponential, phaseInvert)
	return env
end

return Ref
