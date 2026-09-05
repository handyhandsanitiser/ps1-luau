-- cd-rom controller for the ps1.
-- register protocol and drive timing follow the real machine: hc05-style command delay, the drive
-- state machine (seek/read/play/spin-up/speed change), real seek timing with jitter, the 8-sector
-- double-buffered data path with bfrd gating, and the interrupt queue (sync int3/int5 + queued
-- async int1/int2/int4/int5), all on the 33,868,800 hz master clock (225792 cycles per double-speed
-- sector, 451584 single-speed).
-- simplifications: no xa/cd-da audio decode (sectors still routed away from the cpu like duckstation),
-- a synchronous readSector(lba) disc provider, synthesized getlocp sub-q, and no region enforcement.
local CDROM = {}
CDROM.__index = CDROM

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local lshift = bit32.lshift
local rshift = bit32.rshift
local bxor = bit32.bxor

-- cd-rom constants

local MASTER_CLOCK = 33868800
local SINGLE_SPEED_TICKS = math.floor(MASTER_CLOCK / 75)
local DOUBLE_SPEED_TICKS = math.floor(MASTER_CLOCK / 150)
local FRAMES_PER_MINUTE = 4500
local SUBQ_SECTOR_SKEW = 2
local PARAM_FIFO_SIZE = 16
local RESPONSE_FIFO_SIZE = 16
local DATA_FIFO_SIZE = 2340
local NUM_SECTOR_BUFFERS = 8
local SECTOR_SYNC_SIZE = 12
local MODE1_HEADER_SIZE = 4
local MODE2_HEADER_SIZE = 12
local RAW_SECTOR_OUTPUT_SIZE = 2340
local DATA_SECTOR_OUTPUT_SIZE = 2048
local LEAD_OUT_TRACK_NUMBER = 0xAA

-- xa-adpcm / cd-da audio (duckstation cdrom.cpp)
local XA_ADPCM_SAMPLES_PER_SECTOR_4BIT = 4032
local XA_ADPCM_SAMPLES_PER_SECTOR_8BIT = 2016
local XA_RESAMPLE_RING_BUFFER_SIZE = 32
local AUDIO_FIFO_SIZE = 44100 * 2
local AUDIO_FIFO_LOW_WATERMARK = 10
local NUM_CHUNKS = 18
local CHUNK_SIZE_IN_BYTES = 128
local WORDS_PER_CHUNK = 28
local WORDS_PER_BLOCK = 28
local NUM_BLOCKS_4BIT = 8
local NUM_BLOCKS_8BIT = 4
local XA_FILTER_TABLE_POS = { 0, 60, 115, 98, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
local XA_FILTER_TABLE_NEG = { 0, 0, -52, -55, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }

-- 37800hz zigzag resample fir (duckstation resamplexaadpcm, extracted verbatim).
local XA_ZIGZAG_TABLES = {
	{ 0, 0, 0, 0, 0, -2, 10, -34, 65, -84, 52, 9, -266, 1024, -2680, 9036, 26516, -6016, 3021, -1571, 848, -365, 107, 10, -16, 17, -8, 3, -1 },
	{ 0, 0, 0, -2, 0, 3, -19, 60, -75, 162, -227, 306, -67, -615, 3229, 29883, -4532, 2488, -1471, 882, -424, 166, -27, 5, 6, -8, 3, -1, 0 },
	{ 0, 0, -1, 3, -2, -5, 31, -74, 179, -402, 689, -926, 1272, -1446, 31033, -1446, 1272, -926, 689, -402, 179, -74, 31, -5, -2, 3, -1, 0, 0 },
	{ 0, -1, 3, -8, 6, 5, -27, 166, -424, 882, -1471, 2488, -4532, 29883, 3229, -615, -67, 306, -227, 162, -75, 60, -19, 3, 0, -2, 0, 0, 0 },
	{ -1, 3, -8, 17, -16, 10, 107, -365, 848, -1571, 3021, -6016, 26516, 9036, -2680, 1024, -266, 9, 52, -84, 65, -34, 10, -1, 0, 1, 0, 0, 0 },
	{ 2, -8, 16, -35, 43, 26, -235, 635, -1352, 2810, -5882, 21472, 15367, -4681, 2062, -839, 347, -68, -23, 70, -35, 17, -5, 0, 0, 0, 0, 0, 0 },
	{ -5, 17, -35, 70, -23, -68, 347, -839, 2062, -4681, 15367, 21472, -5882, 2810, -1352, 635, -235, 26, 43, -35, 16, -8, 2, 0, 0, 0, 0, 0, 0 },
}

-- 18900hz resample fir (duckstation resamplexaadpcm18900, extracted verbatim).
local XA_TABLES_18900 = {
	{ 0, -5, 17, -35, 70, -23, -68, 347, -839, 2062, -4681, 15367, 21472, -5882, 2810, -1352, 635, -235, 26, 43, -35, 16, -8, 2, 0 },
	{ 0, -2, 10, -34, 65, -84, 52, 9, -266, 1024, -2680, 9036, 26516, -6016, 3021, -1571, 848, -365, 107, 10, -16, 17, -8, 3, -1 },
	{ -2, 0, 3, -19, 60, -75, 162, -227, 306, -67, -615, 3229, 29883, -4532, 2488, -1471, 882, -424, 166, -27, 5, 6, -8, 3, -1 },
	{ -1, 3, -2, -5, 31, -74, 179, -402, 689, -926, 1272, -1446, 31033, -1446, 1272, -926, 689, -402, 179, -74, 31, -5, -2, 3, -1 },
	{ -1, 3, -8, 6, 5, -27, 166, -424, 882, -1471, 2488, -4532, 29883, 3229, -615, -67, 306, -227, 162, -75, 60, -19, 3, 0, -2 },
	{ -1, 3, -8, 17, -16, 10, 107, -365, 848, -1571, 3021, -6016, 26516, 9036, -2680, 1024, -266, 9, 52, -84, 65, -34, 10, -2, 0 },
	{ 0, 2, -8, 16, -35, 43, 26, -235, 635, -1352, 2810, -5882, 21472, 15367, -4681, 2062, -839, 347, -68, -23, 70, -35, 17, -5, 0 },
}

local INIT_TICKS = 4000000
local ID_READ_TICKS = 33868
local MOTOR_ON_RESPONSE_TICKS = 400000
local CDDA_REPORT_START_DELAY = 60
local MINIMUM_INTERRUPT_DELAY = 1000
local INTERRUPT_DELAY_CYCLES = 500
local MISSED_INT1_DELAY_CYCLES = 5000
local MIN_SEEK_TICKS = 30000
local SINGLE_SPEED_SECTORS_PER_SECOND = 75
local DOUBLE_SPEED_SECTORS_PER_SECOND = 150

local INTERRUPT_REGISTER_MASK = 0x1F
local PRNG_SEED = 0x4B435544 -- "DUCK"

-- interrupt codes
local INT_DATA_READY = 0x01
local INT_COMPLETE = 0x02
local INT_ACK = 0x03
local INT_DATA_END = 0x04
local INT_ERROR = 0x05

-- secondary status bits
local STAT_ERROR = 0x01
local STAT_MOTOR_ON = 0x02
local STAT_SEEK_ERROR = 0x04
local STAT_ID_ERROR = 0x08
local STAT_SHELL_OPEN = 0x10
local STAT_READING = 0x20
local STAT_SEEKING = 0x40
local STAT_PLAYING_CDDA = 0x80

-- error reasons
local ERROR_REASON_SHELL_OPEN = 0x08
local ERROR_REASON_INVALID_ARGUMENT = 0x10
local ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS = 0x20
local ERROR_REASON_INVALID_COMMAND = 0x40
local ERROR_REASON_NOT_READY = 0x80

-- drive states (duckstation drivestate, unused legacy states dropped)
local DRIVE_IDLE = 0
local DRIVE_SHELL_OPENING = 1
local DRIVE_SEEKING_PHYSICAL = 2
local DRIVE_SEEKING_LOGICAL = 3
local DRIVE_SEEKING_IMPLICIT = 4
local DRIVE_READING = 5
local DRIVE_PLAYING = 6
local DRIVE_CHANGING_SESSION = 7
local DRIVE_SPINNING_UP = 8
local DRIVE_CHANGING_SPEED_OR_TOC = 9

-- command info table (duckstation s_command_info): name, min params, max params
local COMMAND_INFO = {
	{ "Sync", 0, 0 },     { "Getstat", 0, 0 },   { "Setloc", 3, 3 },    { "Play", 0, 1 },
	{ "Forward", 0, 0 },  { "Backward", 0, 0 },  { "ReadN", 0, 0 },     { "Standby", 0, 0 },
	{ "Stop", 0, 0 },     { "Pause", 0, 0 },     { "Init", 0, 0 },      { "Mute", 0, 0 },
	{ "Demute", 0, 0 },   { "Setfilter", 2, 2 }, { "Setmode", 1, 1 },   { "Getmode", 0, 0 },
	{ "GetlocL", 0, 0 },  { "GetlocP", 0, 0 },   { "ReadT", 1, 1 },     { "GetTN", 0, 0 },
	{ "GetTD", 1, 1 },    { "SeekL", 0, 0 },     { "SeekP", 0, 0 },     { "SetClock", 0, 0 },
	{ "GetClock", 0, 0 }, { "Test", 1, 16 },     { "GetID", 0, 0 },     { "ReadS", 0, 0 },
	{ "Reset", 0, 0 },    { "GetQ", 2, 2 },      { "ReadTOC", 0, 0 },   { "VideoCD", 6, 16 },
}
local VALID_COMMAND_COUNT = #COMMAND_INFO -- 32

-- mechacon version table (duckstation executetestcommand 0x20); index 9 =
-- psx (pu-18) us/eur 10 jan 1997 vc2(a), duckstation's default mechacon.
local MECHACON_VERSION_TABLE = {
	{ 0x94, 0x09, 0x19, 0xC0 }, -- 0 PU-7              19 Sep 1994 vC0(a)
	{ 0x94, 0x11, 0x18, 0xC0 }, -- 1 PU-7              18 Nov 1994 vC0(b)
	{ 0x95, 0x05, 0x16, 0xC1 }, -- 2 EARLY-PU-8        16 May 1995 vC1(a)
	{ 0x95, 0x07, 0x24, 0xC1 }, -- 3 LATE-PU-8         24 Jul 1995 vC1(b)
	{ 0x95, 0x07, 0x24, 0xD1 }, -- 4 LATE-PU-8 debug   24 Jul 1995 vD1
	{ 0x96, 0x08, 0x15, 0xC2 }, -- 5 PU-16 VideoCD     15 Aug 1996 vC2(VCD)
	{ 0x96, 0x08, 0x18, 0xC1 }, -- 6 LATE-PU-8 yaroze  18 Aug 1996 vC1
	{ 0x96, 0x09, 0x12, 0xC2 }, -- 7 PU-18 japan       12 Sep 1996 vC2(a.jap)
	{ 0x97, 0x01, 0x10, 0xC2 }, -- 8 PU-18 us/eur      10 Jan 1997 vC2(a)
	{ 0x97, 0x08, 0x14, 0xC2 }, -- 9 PU-20             14 Aug 1997 vC2(b)
	{ 0x98, 0x06, 0x10, 0xC3 }, -- 10 PU-22            10 Jun 1998 vC3(a)
	{ 0x99, 0x02, 0x01, 0xC3 }, -- 11 PU-23/PM-41      01 Feb 1999 vC3(b)
	{ 0xA1, 0x03, 0x06, 0xC3 }, -- 12 PSone/late PM-41 06 Jun 2001 vC3(c)
}

-- 64-bit helpers for the drive prng

local U32 = 0x100000000

local function u64add(a, b)
	local lo = a.lo + b.lo
	local carry = 0
	if lo >= U32 then
		lo -= U32
		carry = 1
	end
	return { hi = a.hi + b.hi + carry, lo = lo }
end

local function u64xor(a, b)
	return { hi = bxor(a.hi, b.hi), lo = bxor(a.lo, b.lo) }
end

-- 32x32 -> 64-bit product (exact via 16-bit splits; all intermediates < 2^53)
local function mul32x32(x, y)
	local x0 = rshift(x, 16)
	local x1 = band(x, 0xFFFF)
	local y0 = rshift(y, 16)
	local y1 = band(y, 0xFFFF)
	local p11 = x1 * y1
	local mid = x0 * y1 + x1 * y0 -- <= 2^33, exact
	local lo = band(p11 + lshift(mid, 16), 0xFFFFFFFF)
	local hi = band(x0 * y0 + rshift(mid, 16) + rshift(p11, 32), 0xFFFFFFFF)
	return { hi = hi, lo = lo }
end

-- 64x64 -> low 64 bits of product
local function u64mul(a, b)
	local aloBlo = mul32x32(a.lo, b.lo)
	local aloBhi = mul32x32(a.lo, b.hi)
	local ahiBlo = mul32x32(a.hi, b.lo)
	local lo = aloBlo.lo
	local hi = band(aloBlo.hi + aloBhi.lo + ahiBlo.lo, 0xFFFFFFFF)
	return { hi = hi, lo = lo }
end

local function u64shl(a, k)
	-- k in 1..31
	return { hi = band(lshift(a.hi, k) + rshift(a.lo, 32 - k), 0xFFFFFFFF), lo = band(lshift(a.lo, k), 0xFFFFFFFF) }
end

local function u64shr(a, k)
	-- k in 1..31
	return { hi = rshift(a.hi, k), lo = bor(rshift(a.lo, k), lshift(band(a.hi, lshift(1, k) - 1), 32 - k)) }
end

local function u64rotl(a, k)
	-- k in 1..63
	if k < 32 then
		local hi = band(lshift(a.hi, k), 0xFFFFFFFF)
		local lo = band(lshift(a.lo, k), 0xFFFFFFFF)
		local hiCarry = rshift(a.lo, 32 - k)
		local loCarry = rshift(a.hi, 32 - k)
		return { hi = bor(hi, hiCarry), lo = bor(lo, loCarry) }
	end
	local k2 = k - 32
	local hi = band(lshift(a.lo, k2), 0xFFFFFFFF)
	local lo = band(lshift(a.hi, k2), 0xFFFFFFFF)
	local hiCarry = rshift(a.hi, 32 - k2)
	local loCarry = rshift(a.lo, 32 - k2)
	return { hi = bor(hi, hiCarry), lo = bor(lo, loCarry) }
end

-- x % n for a 64-bit x and a small (< 2^30) positive n
local function u64mod(a, n)
	local hiMod = a.hi % n
	local loMod = a.lo % n
	-- 2^32 mod n
	local p = (2 ^ 32) % n
	return ((hiMod * p) % n + loMod) % n
end

-- splitmix64 (duckstation xorshift_prng.h)
local function splitmix64(x)
	local z = u64add(x, { hi = 0x9E3779B9, lo = 0x7F4A7C15 })
	z = u64mul(u64xor(z, u64shr(z, 30)), { hi = 0xBF58476D, lo = 0x1CE4E5B9 })
	z = u64mul(u64xor(z, u64shr(z, 27)), { hi = 0x94D049BB, lo = 0x133111EB })
	return u64xor(z, u64shr(z, 31))
end

-- xoroshiro128++ (duckstation xorshift128plusplus)
local PRNG = {}
PRNG.__index = PRNG

function PRNG.new(seed)
	local self = setmetatable({}, PRNG)
	local x = { hi = 0, lo = seed }
	self.s0 = splitmix64(x)
	self.s1 = splitmix64(x)
	return self
end

function PRNG:next()
	local s0 = self.s0
	local s1 = self.s1
	local result = u64add(u64rotl(u64add(s0, s1), 17), s0)
	local newS1 = u64xor(s1, s0)
	self.s0 = u64xor(u64xor(u64rotl(s0, 49), newS1), u64shl(newS1, 21))
	self.s1 = u64rotl(newS1, 28)
	return result
end

-- nextrange(n) = next() % n; duckstation's rejection sampling is statistically identical (rejection probability ~n/2^64).
function PRNG:nextRange(n)
	return u64mod(self:next(), n)
end

function PRNG:nextRangeLowHigh(low, high)
	return low + self:nextRange(high - low)
end

-- bcd and minute/second/frame helpers

local function bcdToInt(value)
	value = band(value, 0xFF)
	return (rshift(value, 4) * 10) + band(value, 0xF)
end

local function intToBcd(value)
	value = math.max(0, math.floor(value or 0))
	-- decimal-to-bcd (duckstation binarytobcd: 12 -> 0x12): a plain hex mask is wrong when the low decimal digit != low hex nibble (15 -> 0x1f).
	return lshift(math.floor(value / 10), 4) + (value % 10)
end

local function isPackedBcd(value)
	value = band(value, 0xFF)
	return band(value, 0x0F) <= 0x09 and band(value, 0xF0) <= 0x90
end

local function msfToLba(minute, second, frame)
	local m = bcdToInt(minute)
	local s = bcdToInt(second)
	local f = bcdToInt(frame)
	return ((m * 60) + s) * 75 + f - 150
end

local function lbaToMsf(lba)
	lba = math.max(0, math.floor(lba or 0)) + 150
	local minute = math.floor(lba / (60 * 75))
	lba -= minute * 60 * 75
	local second = math.floor(lba / 75)
	local frame = lba - second * 75
	return minute, second, frame
end

local function lbaToMsfBcd(lba)
	local m, s, f = lbaToMsf(lba)
	return intToBcd(m), intToBcd(s), intToBcd(f)
end

local function copyArray(values)
	local result = {}
	for index = 1, #values do
		result[index] = values[index]
	end
	return result
end

-- sectors per track table (duckstation getsectorspertrack, rama's mech data).
local SPT_TABLE = {}
do
	local spt = SPT_TABLE
	for mm = 0, 79 do
		if mm == 0 then
			spt[mm] = 8
		elseif mm <= 4 then
			spt[mm] = 9
		elseif mm <= 7 then
			spt[mm] = 10
		elseif mm <= 11 then
			spt[mm] = 11
		elseif mm <= 16 then
			spt[mm] = 12
		elseif mm <= 23 then
			spt[mm] = 13
		elseif mm <= 27 then
			spt[mm] = 14
		elseif mm <= 32 then
			spt[mm] = 15
		elseif mm <= 39 then
			spt[mm] = 16
		elseif mm <= 44 then
			spt[mm] = 17
		elseif mm <= 52 then
			spt[mm] = 18
		elseif mm <= 60 then
			spt[mm] = 19
		elseif mm <= 67 then
			spt[mm] = 20
		elseif mm <= 74 then
			spt[mm] = 21
		else
			spt[mm] = 22
		end
	end
end

local function createDebugState()
	return {
		readCounts = { status = 0, response = 0, data = 0, irqFlags = 0, irqEnable = 0 },
		writeCounts = { index = 0, command = 0, param = 0, irqEnable = 0, irqAck = 0, fifoControl = 0 },
		commandCount = 0,
		parameterByteCount = 0,
		irqCount = 0,
		irqCallbackCount = 0,
		sectorReadCount = 0,
		lastCommand = nil,
		lastCommandParams = {},
		lastIrqReason = nil,
		lastIrqPendingMask = 0,
		lastIrqAckValue = nil,
	}
end

local function newSectorBuffer()
	return { data = {}, position = 0, size = 0 }
end

-- construction

function CDROM.new(options)
	options = options or {}
	local self = setmetatable({}, CDROM)
	self.index = 0
	-- secondary status byte (drive status bits; duckstation secondary_status).
	self.status = 0
	self.mode = 0
	self.requestRegister = 0 -- BFRD = bit 7 (live: cleared on buffer drain)
	self.irqEnable = INTERRUPT_REGISTER_MASK
	self.irqFlags = 0
	self.pendingInterrupt = nil
	self.asyncDeliveryRemaining = nil
	self.paramFifo = {}
	self.responseFifo = {}
	self.asyncResponseFifo = {}
	self.sectorBuffers = {}
	for _ = 1, NUM_SECTOR_BUFFERS do
		table.insert(self.sectorBuffers, newSectorBuffer())
	end
	self.currentReadBuffer = 0
	self.currentWriteBuffer = 0
	-- command queue
	self.command = nil
	self.commandEventRemaining = nil
	self.commandEventInterval = nil
	self.commandSecondResponse = nil
	self.commandSecondResponseRemaining = nil
	-- drive state machine
	self.driveState = DRIVE_IDLE
	self.driveEventRemaining = nil
	self.driveEventInterval = 0
	-- position / subq state
	self.setlocPosition = { minute = 0, second = 2, frame = 0 }
	self.setlocLba = 0
	self.setlocPending = false
	self.readAfterSeek = false
	self.playAfterSeek = false
	self.requestedLba = 0
	self.currentLba = 0
	self.currentSubqLba = 0
	self.lastReadSector = 0
	self.seekStartLba = 0
	self.seekEndLba = 0
	self.subqLbaUpdateTick = 0
	self.subqLbaUpdateCarry = 0
	self.lastSubqNeedsUpdate = false
	self.lastSubq = { track = 0x01, index = 0x01, relM = 0, relS = 2, relF = 0, absM = 0, absS = 2, absF = 0, crcValid = true, isData = true }
	self.lastSectorHeader = { minute = 0, second = 0, frame = 0, mode = 0 }
	self.lastSectorSubheader = { 0, 0, 0, 0, 0, 0, 0, 0 }
	self.lastSectorHeaderValid = false
	-- cd audio state (routing/volume only; no audible output)
	self.muted = false
	self.adpcmMuted = false
	self.xaFilterFile = 0
	self.xaFilterChannel = 0
	self.xaCurrentFile = 0
	self.xaCurrentChannel = 0
	self.xaCurrentSet = false
	self.cddaAutoPausePending = false
	self.cddaReportStartDelay = 0
	self.lastCddaReportFrameNibble = 0xFF
	self.playTrackNumberBcd = 0xFF
	self.fastForwardRate = 0
	self.asyncCommandParameter = 0
	self.cdAudioVolumeMatrix = { { 0x80, 0x00 }, { 0x00, 0x80 } }
	self.nextCdAudioVolumeMatrix = { { 0x80, 0x00 }, { 0x00, 0x80 } }
	self.lastSectorReadTicks = 0
	-- xa-adpcm decoder state (duckstation cdrom state)
	self.xaCurrentCodinginfo = 0
	self.xaLastSamples = { 0, 0, 0, 0 }
	self.xaResampleRingBuffer = { table.create(XA_RESAMPLE_RING_BUFFER_SIZE, 0), table.create(XA_RESAMPLE_RING_BUFFER_SIZE, 0) }
	self.xaResampleP = 0
	self.xaResampleSixstep = 6
	self.audioFifo = { data = {}, head = 1, count = 0 }
	-- timing
	self.totalCycles = 0
	self.lastInterruptTime = 0
	self.prng = PRNG.new(PRNG_SEED)
	-- host integration
	self.disc = nil
	self.interruptCallback = options.interruptCallback or nil
	self.licenseRegion = options.licenseRegion or "SCEI"
	self.mechaconVersion = options.mechaconVersion or 2 -- DuckStation default CDROMMechaconVersion::VC1A
	self.traceCdrom = options.traceCdrom == true
	self.cycleScale = 1
	-- debug counters (kept for dumpstate/probes)
	self.sectorsDelivered = 0
	self.debug = createDebugState()
	self:resetState()
	return self
end

-- disc interface

function CDROM:setInterruptCallback(callback)
	self.interruptCallback = callback
end

function CDROM:getPc()
	local mem = self.memory
	if mem and mem.cpu and mem.cpu.pc then
		return mem.cpu.pc
	end
	return 0
end

function CDROM:hasDisc()
	return self.disc ~= nil
end

function CDROM:readSector(lba)
	if not self.disc then
		return nil
	end
	if type(self.disc.readSector) == "function" then
		return self.disc.readSector(lba)
	end
	if type(self.disc.sectors) == "table" then
		return self.disc.sectors[lba]
	end
	return nil
end

function CDROM:trace(message)
	if not self.traceCdrom then
		return
	end
	print(string.format("[ps1-cdrom] %s", message))
end

-- disc metadata

function CDROM:getDiscLbaCount()
	if self.disc and type(self.disc.getLbaCount) == "function" then
		return self.disc.getLbaCount() or 0
	end
	return 0
end

function CDROM:getTrackCount()
	if self.disc and type(self.disc.getTrackCount) == "function" then
		return self.disc.getTrackCount() or 1
	end
	return 1
end

function CDROM:getFirstTrackNumber()
	if self.disc and type(self.disc.getFirstTrackNumber) == "function" then
		return self.disc.getFirstTrackNumber() or 1
	end
	return 1
end

function CDROM:getLastTrackNumber()
	if self.disc and type(self.disc.getLastTrackNumber) == "function" then
		return self.disc.getLastTrackNumber() or 1
	end
	return 1
end

function CDROM:getTrackStartPosition(track)
	if self.disc and type(self.disc.getTrackStartPosition) == "function" then
		return self.disc.getTrackStartPosition(track)
	end
	return 0
end

function CDROM:getTrackMode(track)
	if self.disc and type(self.disc.getTrackMode) == "function" then
		return self.disc.getTrackMode(track)
	end
	return "data"
end

function CDROM:isMediaAudioCd()
	if not self.disc then
		return false
	end
	return self:getTrackMode(1) == "audio"
end

function CDROM:getTrackNumberAtLba(lba)
	if self.disc and type(self.disc.getTrackNumber) == "function" then
		return self.disc.getTrackNumber(lba)
	end
	return 1
end

function CDROM:getSubqForLba(lba)
	if self.disc and type(self.disc.getSubq) == "function" then
		local s = self.disc.getSubq(lba)
		if s then
			return s
		end
	end
	-- synthesize: single data track, relative == absolute
	local bcdM, bcdS, bcdF = lbaToMsfBcd(lba)
	return {
		control = 0x04, -- data
		isData = true,
		track = 0x01,
		index = 0x01,
		trackNumberBcd = 0x01,
		indexNumberBcd = 0x01,
		relM = bcdM, relS = bcdS, relF = bcdF,
		absM = bcdM, absS = bcdS, absF = bcdF,
		crcValid = true,
	}
end

-- state predicates

function CDROM:canReadMedia()
	return self.driveState ~= DRIVE_SHELL_OPENING and self.disc ~= nil
end

function CDROM:isSeeking()
	return self.driveState == DRIVE_SEEKING_LOGICAL or self.driveState == DRIVE_SEEKING_PHYSICAL
		or self.driveState == DRIVE_SEEKING_IMPLICIT
end

function CDROM:isReading()
	return self.driveState == DRIVE_READING
end

function CDROM:isReadingOrPlaying()
	return self.driveState == DRIVE_READING or self.driveState == DRIVE_PLAYING
end

function CDROM:hasPendingCommand()
	return self.command ~= nil
end

function CDROM:hasPendingInterrupt()
	return self.irqFlags ~= 0
end

function CDROM:hasPendingAsyncInterrupt()
	return self.pendingInterrupt ~= nil
end

function CDROM:isMotorOn()
	return band(self.status, STAT_MOTOR_ON) ~= 0
end

-- mode register helpers

function CDROM:modeCdda() return band(self.mode, 0x01) ~= 0 end
function CDROM:modeAutoPause() return band(self.mode, 0x02) ~= 0 end
function CDROM:modeReportAudio() return band(self.mode, 0x04) ~= 0 end
function CDROM:modeXaFilter() return band(self.mode, 0x08) ~= 0 end
function CDROM:modeIgnoreBit() return band(self.mode, 0x10) ~= 0 end
function CDROM:modeReadRawSector() return band(self.mode, 0x20) ~= 0 end
function CDROM:modeXaEnable() return band(self.mode, 0x40) ~= 0 end
function CDROM:modeDoubleSpeed() return band(self.mode, 0x80) ~= 0 end

-- status helpers

function CDROM:getDriveStatus()
	return band(self.status or 0, 0xFF)
end

function CDROM:clearActiveBits()
	self.status = band(self.status, bnot(bor(STAT_SEEKING, STAT_READING, STAT_PLAYING_CDDA)))
end

function CDROM:setSeeking()
	self.status = band(self.status, bnot(bor(STAT_READING, STAT_PLAYING_CDDA)))
	self.status = bor(self.status, bor(STAT_MOTOR_ON, STAT_SEEKING))
end

function CDROM:setReadingBits(audio)
	self.status = band(self.status, bnot(bor(STAT_SEEKING, STAT_READING, STAT_PLAYING_CDDA)))
	if audio then
		self.status = bor(self.status, bor(STAT_MOTOR_ON, STAT_PLAYING_CDDA))
	else
		self.status = bor(self.status, bor(STAT_MOTOR_ON, STAT_READING))
	end
end

-- hsts register port value (duckstation updatestatusregister)
function CDROM:getStatusPortValue()
	local value = band(self.index, 0x3)
	if #self.paramFifo == 0 then
		value = bor(value, 0x08) -- PRMEMPTY
	end
	if #self.paramFifo < PARAM_FIFO_SIZE then
		value = bor(value, 0x10) -- PRMWRDY
	end
	if #self.responseFifo > 0 then
		value = bor(value, 0x20) -- RSLRRDY
	end
	if band(self.requestRegister, 0x80) ~= 0 then
		value = bor(value, 0x40) -- DRQSTS = BFRD
	end
	if self.command ~= nil then
		value = bor(value, 0x80) -- BUSYSTS
	end
	return value
end

function CDROM:updateStatusRegister()
	-- the status port is computed on read (getstatusportvalue); this mirrors
	-- duckstation's updatestatusregister for the internal drqsts invariant.
end

-- interrupt model

function CDROM:updateInterruptRequest()
	-- cd-rom irq line = (flag & enable), asserted on a new interrupt, dropped when the game acks the flag to 0.
	local pending = band(self.irqFlags, self.irqEnable)
	if self.memory and self.memory.setInterruptLine then
		self.memory:setInterruptLine(2, pending ~= 0)
	end
	if self.interruptCallback and pending ~= 0 then
		self.debug.irqCallbackCount += 1
		self:trace("interrupt callback raised")
		self.interruptCallback()
	end
end

-- setinterrupt: synchronous interrupt (command ack/error).  overwrites the
-- visible flag; raises the cpu line when (flag & enable) != 0.
function CDROM:setInterrupt(reason)
	self.irqFlags = band(reason, 0x1F)
	self.debug.irqCount += 1
	self.debug.lastIrqReason = self.irqFlags
	self.debug.lastIrqPendingMask = band(self.irqEnable, self.irqFlags)
	self:trace(string.format("irq(sync) reason=%02X flags=%02X enable=%02X pending=%02X", reason, self.irqFlags, self.irqEnable, self.debug.lastIrqPendingMask))
	self:updateInterruptRequest()
end

-- setasyncinterrupt: queue an async interrupt (dataready/complete/error); a short delay applies if one was delivered recently.
function CDROM:setAsyncInterrupt(reason)
	reason = band(reason, 0x1F)
	if self.irqFlags == reason then
		-- same interrupt already unacknowledged; drop the new response bytes.
		self.asyncResponseFifo = {}
		return
	end
	if self.pendingInterrupt ~= nil then
		-- duckstation asserts pending == 0 here; keep the first pending cause.
		return
	end
	self.pendingInterrupt = reason
	if self.irqFlags == 0 then
		if not self:hasPendingCommand() then
			self:queueDeliverAsyncInterrupt()
		else
			self:trace(string.format("delaying async interrupt %02X because of pending command", reason))
		end
	end
end

function CDROM:clearAsyncInterrupt()
	self.pendingInterrupt = nil
	self.asyncDeliveryRemaining = nil
	self.asyncResponseFifo = {}
end

-- queuedeliverasyncinterrupt: deliver now if enough cycles passed, else delay by interrupt_delay_cycles (lets software drain the response fifo after an int3).
function CDROM:queueDeliverAsyncInterrupt()
	if self.pendingInterrupt == nil then
		return
	end
	local diff = band(self.totalCycles - self.lastInterruptTime, 0xFFFFFFFF)
	if diff >= MINIMUM_INTERRUPT_DELAY then
		self:deliverAsyncInterrupt()
	else
		self.asyncDeliveryRemaining = INTERRUPT_DELAY_CYCLES
	end
end

function CDROM:deliverAsyncInterrupt()
	if self.pendingInterrupt == nil then
		return
	end
	if self.irqFlags ~= 0 then
		-- blocked by a visible interrupt; retry after a short delay.
		self.asyncDeliveryRemaining = INTERRUPT_DELAY_CYCLES
		return
	end
	local reason = self.pendingInterrupt
	self.pendingInterrupt = nil
	self.asyncDeliveryRemaining = nil
	-- the hc05 setting the read position from the decoder on dataready.
	if reason == INT_DATA_READY then
		self.currentReadBuffer = self.currentWriteBuffer
	end
	self.responseFifo = {}
	for _, b in ipairs(self.asyncResponseFifo) do
		table.insert(self.responseFifo, band(b, 0xFF))
	end
	self.asyncResponseFifo = {}
	self.irqFlags = reason
	self.lastInterruptTime = self.totalCycles
	self.debug.irqCount += 1
	self.debug.lastIrqReason = reason
	self.debug.lastIrqPendingMask = band(self.irqEnable, self.irqFlags)
	self:trace(string.format("irq(async) reason=%02X flags=%02X enable=%02X pending=%02X", reason, self.irqFlags, self.irqEnable, self.debug.lastIrqPendingMask))
	self:updateInterruptRequest()
	self:updateCommandEvent()
end

-- duckstation sendackandstat / senderrorresponse / sendasyncerrorresponse
function CDROM:sendAckAndStat()
	table.insert(self.responseFifo, band(self.status, 0xFF))
	self:setInterrupt(INT_ACK)
end

function CDROM:sendErrorResponse(statBits, reason)
	table.insert(self.responseFifo, band(bor(self.status, statBits), 0xFF))
	table.insert(self.responseFifo, band(reason, 0xFF))
	self:setInterrupt(INT_ERROR)
end

function CDROM:sendAsyncErrorResponse(statBits, reason)
	table.insert(self.asyncResponseFifo, band(bor(self.status, statBits), 0xFF))
	table.insert(self.asyncResponseFifo, band(reason, 0xFF))
	self:setAsyncInterrupt(INT_ERROR)
end

-- command queue

function CDROM:getAckDelayForCommand(command)
	if command == 0x0A then
		-- init takes longer.
		return 80000
	end
	if self:canReadMedia() then
		return 25000
	end
	return 15000
end

function CDROM:beginCommand(command)
	command = band(command, 0xFF)
	local ackDelay = self:getAckDelayForCommand(command)
	if self.command ~= nil then
		-- pending-command heuristic (duckstation): if the pending command needs more params than the new one, empty the fifo (it errors on execute); otherwise replace it, subtracting elapsed ack time.
		local oldInfo = COMMAND_INFO[self.command + 1]
		local newInfo = COMMAND_INFO[command + 1]
		if oldInfo and newInfo and oldInfo[2] > newInfo[2] then
			self:trace(string.format("ignoring command %02X and emptying FIFO; %02X still pending", command, self.command))
			self.paramFifo = {}
			return
		end
		self:trace(string.format("cancelling pending command %02X for new command %02X", self.command, command))
		if self.commandEventRemaining ~= nil then
			local elapsed = math.max(0, (self.commandEventInterval or 0) - self.commandEventRemaining)
			ackDelay = math.max(ackDelay - elapsed, 1)
			self.commandEventRemaining = nil
			if self.pendingInterrupt ~= nil then
				-- deliver the async now that the blocking command is gone
				-- (street fighter alpha 3 spams pause over a scheduled int1).
				self:queueDeliverAsyncInterrupt()
			end
		end
	end
	self.command = command
	self.commandEventRemaining = ackDelay
	self.commandEventInterval = ackDelay
	self:updateCommandEvent()
	self:updateStatusRegister()
end

function CDROM:endCommand()
	self.paramFifo = {}
	self.command = nil
	self.commandEventRemaining = nil
	self.commandEventInterval = nil
	self:updateStatusRegister()
end

-- command execution is blocked while an interrupt (sync or async) is visible;
-- the ack path re-activates it.
function CDROM:updateCommandEvent()
	if self.command == nil or self.irqFlags ~= 0 or self.pendingInterrupt ~= nil then
		return
	end
	if self.commandEventRemaining == nil then
		self.commandEventRemaining = self:getAckDelayForCommand(self.command)
		self.commandEventInterval = self.commandEventRemaining
	end
end

-- drive timing

function CDROM:getTicksForSpinUp()
	return MASTER_CLOCK
end

function CDROM:getTicksForRead()
	if self:modeDoubleSpeed() then
		return DOUBLE_SPEED_TICKS
	end
	return SINGLE_SPEED_TICKS
end

function CDROM:getTicksForTocRead()
	if not self.disc then
		return 0
	end
	return math.floor(MASTER_CLOCK / 2)
end

function CDROM:getTicksForIdRead()
	local ticks = ID_READ_TICKS
	if self.driveState == DRIVE_SPINNING_UP then
		ticks += self.driveEventRemaining or 0
	end
	return ticks
end

function CDROM:getTicksForStop(motorWasOn)
	if motorWasOn then
		return self:modeDoubleSpeed() and 25000000 or 13000000
	end
	return 7000
end

function CDROM:getTicksForSpeedChange()
	-- called after mode has been updated; double_speed set means single->double.
	if self:modeDoubleSpeed() then
		return math.floor(0.6 * MASTER_CLOCK)
	end
	return math.floor(0.7 * MASTER_CLOCK)
end

function CDROM:getTicksForPause()
	if not self:isReadingOrPlaying() then
		return 27000
	end
	local sectorsPerTrack = self:getSectorsPerTrack(self.currentLba)
	local ticksPerRead = self:getTicksForRead()
	local elapsed = 0
	if self.driveEventRemaining ~= nil then
		elapsed = math.max(0, self.driveEventInterval - self.driveEventRemaining)
	end
	local ticksToReachTarget = ((sectorsPerTrack - (self:isReading() and 2 or 0)) * ticksPerRead) - elapsed
	local minTicks = self:modeDoubleSpeed() and 1000000 or 2000000
	return math.max(ticksToReachTarget, minTicks)
end

function CDROM:getSectorsPerTrack(lba)
	local mm = math.floor(lba / FRAMES_PER_MINUTE)
	return SPT_TABLE[math.min(mm, #SPT_TABLE - 1)]
end

function CDROM:getTicksForSeek(newLba, ignoreSpeedChange)
	if self:isSeeking() then
		self:updateSubQPositionWhileSeeking()
	else
		self:updateSubQPosition(false)
	end

	local currentLba
	if self:isMotorOn() then
		currentLba = self:isSeeking() and self.seekEndLba or self.currentSubqLba
	else
		currentLba = 0
	end
	local lbaDiff = newLba > currentLba and (newLba - currentLba) or (currentLba - newLba)

	local ticks = 0
	-- motor spin-up time.
	if not self:isMotorOn() then
		if self.driveState == DRIVE_SPINNING_UP then
			ticks += self.driveEventRemaining or 0
		else
			ticks += self:getTicksForSpinUp()
		end
		if self.driveState == DRIVE_SHELL_OPENING or self.driveState == DRIVE_SPINNING_UP then
			self:clearDriveState()
		end
	end

	local ticksPerSector = self:modeDoubleSpeed() and DOUBLE_SPEED_TICKS or SINGLE_SPEED_TICKS
	local sectorsPerTrack = self:getSectorsPerTrack(currentLba)
	local tjumpPosition = (currentLba >= sectorsPerTrack) and (currentLba - sectorsPerTrack) or 0
	if currentLba < newLba and lbaDiff <= sectorsPerTrack then
		-- forward within one track: the mech waits for the sector to come up.
		ticks += ticksPerSector * math.max(lbaDiff, 2)
	elseif currentLba >= newLba and tjumpPosition <= newLba then
		-- track jump back, capped at 8 sectors (~53ms).
		ticks += ticksPerSector * math.max(newLba - tjumpPosition, 1)
	elseif lbaDiff < 7200 then
		-- medium seek (not sled); logarithmic switch point between fast/slow.
		local clamped = math.max(1, math.min(currentLba / FRAMES_PER_MINUTE, 72))
		local switchPoint = math.floor(330.0 + (-63.1333 * math.log(clamped)))
		local seconds = (lbaDiff < switchPoint) and 0.05 or 0.1
		ticks += math.floor(seconds * MASTER_CLOCK)
	else
		-- sled seek: fixed + log + linear component.
		local SLED_FIXED_COST = 0.05
		local SLED_VARIABLE_COST = 0.9 - SLED_FIXED_COST
		local LOG_WEIGHT = 0.4
		local MAX_SLED_LBA = 72 * FRAMES_PER_MINUTE
		local seconds = SLED_FIXED_COST
			+ ((SLED_VARIABLE_COST * (math.log(lbaDiff) / math.log(MAX_SLED_LBA))) * LOG_WEIGHT)
			+ ((SLED_VARIABLE_COST * (lbaDiff / MAX_SLED_LBA)) * (1.0 - LOG_WEIGHT))
		ticks += math.floor(seconds * MASTER_CLOCK)
	end

	-- deterministic jitter (real hardware adds 0.5-1ms per seek; games like
	-- resident evil/dino crisis lock up if seeks are identical every time).
	ticks += self.prng:nextRangeLowHigh(math.floor(MASTER_CLOCK / 2000), math.floor(MASTER_CLOCK / 1000))

	if self.driveState == DRIVE_CHANGING_SPEED_OR_TOC and not ignoreSpeedChange then
		-- still reading the toc; add the remaining change time in.
		ticks += self.driveEventRemaining or 0
	end

	return ticks
end

-- drive state machine

function CDROM:clearDriveState()
	self.driveState = DRIVE_IDLE
	self.driveEventRemaining = nil
end

function CDROM:setHoldPosition(lba, subqLba)
	self.lastSubqNeedsUpdate = self.lastSubqNeedsUpdate or (self.currentSubqLba ~= subqLba)
	self.currentLba = lba
	self.currentSubqLba = subqLba
	self.subqLbaUpdateTick = self.totalCycles
	self.subqLbaUpdateCarry = 0
end

function CDROM:updateSubQPositionWhileSeeking()
	if not self:isSeeking() then
		return
	end
	local interval = self.driveEventInterval or 1
	local remaining = self.driveEventRemaining or 0
	local completedFrac = 1.0 - math.min(remaining / interval, 1.0)
	local currentLba
	if self.seekEndLba > self.seekStartLba then
		currentLba = self.seekStartLba + math.max(math.floor((self.seekEndLba - self.seekStartLba) * completedFrac), 1)
	elseif self.seekEndLba < self.seekStartLba then
		currentLba = self.seekStartLba - math.max(math.floor((self.seekStartLba - self.seekEndLba) * completedFrac), 1)
	else
		return
	end
	self.lastSubqNeedsUpdate = self.currentSubqLba ~= currentLba
	self.currentSubqLba = currentLba
	self.subqLbaUpdateTick = self.totalCycles
	self.subqLbaUpdateCarry = 0
end

function CDROM:updateSubQPosition(updateLogical)
	if self:isSeeking() or self:isReadingOrPlaying() or not self:isMotorOn() then
		-- seeking+reading the first sector: return the hold position, not the stale subq lba (mad panic coaster depends on this).
		if band(self.status, bor(STAT_READING, STAT_PLAYING_CDDA, STAT_MOTOR_ON)) == STAT_MOTOR_ON
			and self.currentLba ~= self.currentSubqLba then
			self:setHoldPosition(self.currentLba, self.currentLba)
		end
		return
	end

	local ticksPerRead = self:getTicksForRead()
	local diff = (band(self.totalCycles - self.subqLbaUpdateTick, 0xFFFFFFFF)) + self.subqLbaUpdateCarry
	local sectorDiff = math.floor(diff / ticksPerRead)
	local carry = diff % ticksPerRead
	if sectorDiff <= 0 then
		return
	end
	local holdOffset = self.lastSectorHeaderValid and 2 or 0
	local sectorsPerTrack = self:getSectorsPerTrack(self.currentLba)
	local holdPosition = self.currentLba + holdOffset
	local tjumpPosition = (holdPosition >= sectorsPerTrack) and (holdPosition - sectorsPerTrack) or 0
	local oldOffset = self.currentSubqLba - tjumpPosition
	local newOffset = (oldOffset + sectorDiff) % sectorsPerTrack
	local newSubqLba = tjumpPosition + newOffset
	if self.currentSubqLba ~= newSubqLba then
		self.currentSubqLba = newSubqLba
		self.lastSubqNeedsUpdate = true
		self.subqLbaUpdateTick = self.totalCycles
		self.subqLbaUpdateCarry = carry
		if updateLogical then
			local subq = self:getSubqForLba(newSubqLba)
			if subq and subq.crcValid then
				self.lastSubq = subq
			end
			self.lastSubqNeedsUpdate = false
			local sector = self:readSector(newSubqLba)
			if sector then
				self:processDataSectorHeader(sector)
			end
		end
	end
end

function CDROM:ensureLastSubqValid()
	if not self.lastSubqNeedsUpdate then
		return
	end
	self.lastSubqNeedsUpdate = false
	local subq = self:getSubqForLba(self.currentSubqLba)
	if subq and subq.crcValid then
		self.lastSubq = subq
	end
end

function CDROM:beginSeeking(logical, readAfterSeek, playAfterSeek)
	self.readAfterSeek = readAfterSeek
	self.playAfterSeek = playAfterSeek
	self.setlocPending = false

	local seekLba = self.setlocLba
	local seekTime
	-- repeated seekl to the same target before a new read completes nearly instantly (the mech looks for target -2).
	if logical and not readAfterSeek and self.currentSubqLba == (seekLba - SUBQ_SECTOR_SKEW)
		and self.seekEndLba == seekLba
		and band(self.totalCycles - self.subqLbaUpdateTick, 0xFFFFFFFF) < self:getTicksForRead() then
		seekTime = MIN_SEEK_TICKS
	else
		seekTime = self:getTicksForSeek(seekLba, playAfterSeek)
	end

	self:clearCommandSecondResponse()
	self:clearAsyncInterrupt()
	self:clearSectorBuffers()
	self:resetAudioDecoder()

	self:setSeeking()
	self.lastSectorHeaderValid = false

	self.driveState = logical and DRIVE_SEEKING_LOGICAL or DRIVE_SEEKING_PHYSICAL
	self.driveEventInterval = seekTime
	self.driveEventRemaining = seekTime

	self.seekStartLba = self.currentLba
	self.seekEndLba = seekLba
	self.requestedLba = seekLba
	self:trace(string.format("begin seeking to %d (logical=%s readAfter=%s playAfter=%s time=%d)", seekLba, tostring(logical), tostring(readAfterSeek), tostring(playAfterSeek), seekTime))
end

function CDROM:completeSeek()
	local logical = self.driveState == DRIVE_SEEKING_LOGICAL
	self:clearDriveState()

	local sector = self:readSector(self.requestedLba)
	local seekOkay = sector ~= nil
	local lastReadSector = self.requestedLba
	if seekOkay then
		self.currentSubqLba = lastReadSector
		self.lastSubqNeedsUpdate = false
		self.subqLbaUpdateTick = self.totalCycles
		self.subqLbaUpdateCarry = 0

		self.lastReadSector = lastReadSector
		self.currentLba = lastReadSector

		local subq = self:getSubqForLba(lastReadSector)
		if subq and subq.crcValid then
			self.lastSubq = subq
			self.lastSubqNeedsUpdate = false
			local seekM, seekS, seekF = lbaToMsfBcd(lastReadSector)
			seekOkay = subq.absM == seekM and subq.absS == seekS and subq.absF == seekF
			if seekOkay then
				if subq.isData then
					if logical then
						self:processDataSectorHeader(sector)
						seekOkay = self.lastSectorHeader.minute == seekM and self.lastSectorHeader.second == seekS
							and self.lastSectorHeader.frame == seekF
						if seekOkay and not self.playAfterSeek and not self.readAfterSeek then
							-- the mech completes the seek 2 sectors early; hack
							-- the subq back so following seeks read forward.
							self.currentSubqLba = (self.currentLba >= SUBQ_SECTOR_SKEW) and (self.currentLba - SUBQ_SECTOR_SKEW) or 0
							self.lastSubqNeedsUpdate = true
						end
					end
				else
					if logical and self.readAfterSeek then
						-- reading an audio sector requires cdda mode (vib-ribbon).
						seekOkay = self:modeCdda()
					end
				end
				if subq.trackNumberBcd == LEAD_OUT_TRACK_NUMBER then
					seekOkay = false
				end
			end
		end
	end
	return seekOkay
end

function CDROM:doSeekComplete()
	local logical = self.driveState == DRIVE_SEEKING_LOGICAL
	local seekOkay = self:completeSeek()
	if seekOkay then
		if self.readAfterSeek then
			self:beginReading(true)
		elseif self.playAfterSeek then
			self:beginPlaying(0, true)
		else
			self:clearActiveBits()
			table.insert(self.asyncResponseFifo, band(self.status, 0xFF))
			self:setAsyncInterrupt(INT_COMPLETE)
		end
	else
		self:clearActiveBits()
		self:sendAsyncErrorResponse(STAT_SEEK_ERROR, 0x04)
		self.lastSectorHeaderValid = false
	end
	self.setlocPending = false
	self.readAfterSeek = false
	self.playAfterSeek = false
	self:updateStatusRegister()
end

function CDROM:beginReading(afterSeek)
	if not afterSeek and self.setlocPending then
		self:beginSeeking(true, true, false)
		return
	end

	-- read command while seeking: schedule the read after the seek finishes.
	if self:isSeeking() then
		if self.driveState == DRIVE_SEEKING_IMPLICIT then
			self.driveState = DRIVE_SEEKING_LOGICAL
		end
		self.readAfterSeek = true
		self.playAfterSeek = false
		return
	end

	local ticks = self:getTicksForRead()
	local firstSectorTicks = ticks + (afterSeek and 0 or self:getTicksForSeek(self.currentLba))

	self:clearCommandSecondResponse()
	self:clearAsyncInterrupt()
	self:clearSectorBuffers()
	self:resetAudioDecoder()

	-- not officially a seek, but the head still travels unless we're right after one; the seeking bit clears after the first sector.
	if not afterSeek then
		self:setSeeking()
	end

	self.driveState = DRIVE_READING
	self.driveEventInterval = ticks
	self.driveEventRemaining = firstSectorTicks
	self.lastSectorReadTicks = ticks

	self.requestedLba = self.currentLba
	self.seekStartLba = 0
	self.seekEndLba = 0
	self:trace(string.format("begin reading @ lba=%d firstSectorIn=%d interval=%d", self.requestedLba, firstSectorTicks, ticks))
end

function CDROM:beginPlaying(track, afterSeek)
	self.playTrackNumberBcd = track
	self.fastForwardRate = 0

	if track ~= 0 then
		local trackCount = self:getTrackCount()
		if track > trackCount then
			-- restart current track
			track = self:getTrackNumberAtLba(self.currentLba)
		end
		self.setlocPosition.minute, self.setlocPosition.second, self.setlocPosition.frame = lbaToMsfBcd(self:getTrackStartPosition(track))
		self.setlocLba = self:getTrackStartPosition(track)
		self.setlocPending = true
	end

	if self.setlocPending then
		self:beginSeeking(false, false, true)
		return
	end

	local ticks = self:getTicksForRead()
	local firstSectorTicks = ticks + (afterSeek and 0 or self:getTicksForSeek(self.currentLba, true))

	self:clearCommandSecondResponse()
	self:clearAsyncInterrupt()
	self:clearSectorBuffers()
	self:resetAudioDecoder()

	self.cddaReportStartDelay = CDDA_REPORT_START_DELAY
	self.lastCddaReportFrameNibble = 0xFF

	self.driveState = DRIVE_PLAYING
	self.driveEventInterval = ticks
	self.driveEventRemaining = firstSectorTicks

	self.requestedLba = self.currentLba
	self:trace(string.format("begin playing @ lba=%d firstSectorIn=%d", self.requestedLba, firstSectorTicks))
end

function CDROM:startMotor()
	if self.driveState == DRIVE_SPINNING_UP then
		return
	end
	self.driveState = DRIVE_SPINNING_UP
	self.driveEventInterval = self:getTicksForSpinUp()
	self.driveEventRemaining = self.driveEventInterval
end

function CDROM:stopMotor()
	self:clearActiveBits()
	self.status = band(self.status, bnot(STAT_MOTOR_ON))
	self:clearDriveState()
	self:setHoldPosition(0, 0)
	self.lastSectorHeaderValid = false
end

-- sector reads and the data path

function CDROM:processDataSectorHeader(sector)
	local header = sector:sub(13, 16)
	local subheader = sector:sub(17, 24)
	self.lastSectorHeader.minute = header:byte(1) or 0
	self.lastSectorHeader.second = header:byte(2) or 0
	self.lastSectorHeader.frame = header:byte(3) or 0
	self.lastSectorHeader.mode = header:byte(4) or 0
	self.lastSectorSubheader = {}
	for i = 1, 8 do
		self.lastSectorSubheader[i] = subheader:byte(i) or 0
	end
	self.lastSectorHeaderValid = true
end

function CDROM:clearSectorBuffers()
	self.currentReadBuffer = 0
	self.currentWriteBuffer = 0
	for _, sb in ipairs(self.sectorBuffers) do
		sb.position = 0
		sb.size = 0
		sb.data = {}
	end
	self.requestRegister = band(self.requestRegister, bnot(0x80)) -- BFRD = false
end

function CDROM:resetAudioDecoder()
	self.cddaAutoPausePending = false
	self.xaCurrentFile = 0
	self.xaCurrentChannel = 0
	self.xaCurrentSet = false
	self.xaCurrentCodinginfo = 0
	for i = 1, 4 do self.xaLastSamples[i] = 0 end
	for ch = 1, 2 do
		for i = 1, XA_RESAMPLE_RING_BUFFER_SIZE do self.xaResampleRingBuffer[ch][i] = 0 end
		self.xaResampleP = 0
		self.xaResampleSixstep = 6
	end
	self.audioFifo = { data = {}, head = 1, count = 0 }
end

-- cd audio fifo

function CDROM:audioFifoSize()
	return self.audioFifo.count or 0
end

function CDROM:audioFifoSpace()
	return AUDIO_FIFO_SIZE - (self.audioFifo.count or 0)
end

function CDROM:audioFifoPush(frame)
	local fifo = self.audioFifo
	if fifo.count >= AUDIO_FIFO_SIZE then
		-- safety net: drop oldest
		fifo.data[fifo.head] = nil
		fifo.head += 1
		fifo.count -= 1
	end
	fifo.data[fifo.head + fifo.count] = frame
	fifo.count += 1
end

function CDROM:audioFifoPop()
	local fifo = self.audioFifo
	if fifo.count == 0 then return 0 end
	local v = fifo.data[fifo.head]
	fifo.data[fifo.head] = nil
	fifo.head += 1
	fifo.count -= 1
	return v
end

function CDROM:audioFifoRemove(n)
	for _ = 1, n do
		if self.audioFifo.count == 0 then break end
		self.audioFifo.data[self.audioFifo.head] = nil
		self.audioFifo.head += 1
		self.audioFifo.count -= 1
	end
end

function CDROM:addCdAudioFrame(left, right)
	self:audioFifoPush(bor(band(left, 0xFFFF), lshift(band(right, 0xFFFF), 16)))
end

local function xaClamp16(v)
	if v < -32768 then return -32768 end
	if v > 32767 then return 32767 end
	return v
end

local function xaS16(v)
	v = band(v, 0xFFFF)
	return v >= 0x8000 and v - 0x10000 or v
end

-- arithmetic shift right (luau bit32.arshift is not available in all
-- runtimes; emulate with a signed-right-shift).
local function arshift(v, n)
	if n <= 0 then return v end
	if v >= 0 then
		return math.floor(v / (2 ^ n))
	end
	return -math.floor((-v - 1) / (2 ^ n)) - 1
end

-- duckstation cdrom::getaudioframe: pop, apply volume matrix, saturate.
function CDROM:getAudioFrame()
	local frame = self:audioFifoPop()
	local left = xaS16(band(frame, 0xFFFF))
	local right = xaS16(band(rshift(frame, 16), 0xFFFF))
	local m = self.cdAudioVolumeMatrix
	local leftOut = self:saturateVolume(self:applyVolume(left, m[1][1]) + self:applyVolume(right, m[2][1]))
	local rightOut = self:saturateVolume(self:applyVolume(left, m[1][2]) + self:applyVolume(right, m[2][2]))
	return leftOut, rightOut
end

function CDROM:applyVolume(sample, volume)
	return arshift(sample * band(volume, 0xFF), 7)
end

function CDROM:saturateVolume(v)
	if v < -0x8000 then return -0x8000 end
	if v > 0x7FFF then return 0x7FFF end
	return v
end

-- xa-adpcm decoding

-- decode one xa sector's 18 chunks into s16 samples (4032 for 4-bit, 2016 for 8-bit); adpcm data starts at byte 25.
function CDROM:decodeXaAdpcmChunks(sector, stereo, is8)
	local samples = {}
	local numBlocks = is8 and NUM_BLOCKS_8BIT or NUM_BLOCKS_4BIT
	local samplesPerChunk = WORDS_PER_CHUNK * (is8 and 4 or 8)
	for chunk = 0, NUM_CHUNKS - 1 do
		local base = 25 + chunk * CHUNK_SIZE_IN_BYTES
		for block = 0, numBlocks - 1 do
			local headerByte = sector:byte(base + 4 + block) or 0
			local shift = band(headerByte, 0x0F)
			if shift > 12 then shift = 9 end
			local filter = rshift(headerByte, 4)
			local filterPos = XA_FILTER_TABLE_POS[filter + 1]
			local filterNeg = XA_FILTER_TABLE_NEG[filter + 1]
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
				local sample = xaS16(lshift(nibble, is8 and 8 or 12))
				sample = arshift(sample, shift)
				local prev0 = self.xaLastSamples[prevBase + 1]
				local prev1 = self.xaLastSamples[prevBase + 2]
				local interp = xaClamp16(sample
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

-- duckstation cdrom::resamplexaadpcm (37800 -> 44100 zigzag fir).
function CDROM:zigzagInterpolate(ringbuf, tableIndex, p)
	local table = XA_ZIGZAG_TABLES[tableIndex + 1]
	local sum = 0
	for i = 0, 28 do
		sum += arshift(ringbuf[band(p - i, 0x1F) + 1] * table[i + 1], 15)
	end
	return xaS16(xaClamp16(sum))
end

function CDROM:resampleXaAdpcm(samples, numFrames, stereo)
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

-- duckstation cdrom::resamplexaadpcm18900.
function CDROM:interpolate18900(ringbuf, tableIndex, p)
	local table = XA_TABLES_18900[tableIndex + 1]
	local sum = 0
	for i = 0, 24 do
		sum += ringbuf[band(p + 32 - 25 + i, 0x1F) + 1] * table[i + 1]
	end
	return xaS16(xaClamp16(arshift(sum, 15)))
end

function CDROM:resampleXaAdpcm18900(samples, numFrames, stereo)
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

local function xaIsStereo(coding) return band(coding, 0x01) ~= 0 end
local function xaIsHalfSampleRate(coding) return band(coding, 0x04) ~= 0 end
local function xaIs8BitADPCM(coding) return band(coding, 0x10) ~= 0 end
local function xaSamplesPerSector(coding)
	return xaIs8BitADPCM(coding) and XA_ADPCM_SAMPLES_PER_SECTOR_8BIT or XA_ADPCM_SAMPLES_PER_SECTOR_4BIT
end

-- fill the write sector buffer from a raw 2352-byte sector and raise the
-- dataready async interrupt (duckstation processdatasector).
function CDROM:processDataSector(sector, subq)
	-- audio+realtime mode2 sectors go to the spu, not the cpu (duckstation).
	if self:modeXaEnable() and self.lastSectorHeader.mode == 2 then
		local submode = self.lastSectorSubheader[3]
		if band(submode, 0x40) ~= 0 and band(submode, 0x04) ~= 0 then
			self:trace("xa audio sector routed to spu (not delivered to cpu)")
			self:processXaAdpcmSector(sector, subq)
			return
		end
	end

	local sbNum = (self.currentWriteBuffer + 1) % NUM_SECTOR_BUFFERS
	local sb = self.sectorBuffers[sbNum + 1]
	sb.data = {}
	if self:modeReadRawSector() then
		if self.lastSectorHeader.mode == 1 then
			-- raw reads in mode1 fill in a mode2-style header: 4-byte header,
			-- 8 zero bytes, then the 2048 data bytes (2060 total).
			for i = 0, 3 do
				sb.data[i + 1] = sector:byte(13 + i) or 0
			end
			for i = 4, 11 do
				sb.data[i + 1] = 0
			end
			for i = 12, 2059 do
				sb.data[i + 1] = sector:byte(17 + (i - 12)) or 0
			end
			sb.size = MODE2_HEADER_SIZE + DATA_SECTOR_OUTPUT_SIZE
		else
			-- mode2 raw: sync-removed sector (2340 bytes).
			for i = 0, RAW_SECTOR_OUTPUT_SIZE - 1 do
				sb.data[i + 1] = sector:byte(13 + i) or 0
			end
			sb.size = RAW_SECTOR_OUTPUT_SIZE
		end
	else
		if self.lastSectorHeader.mode ~= 1 and self.lastSectorHeader.mode ~= 2 then
			return
		end
		local offset = self.lastSectorHeader.mode == 1 and 17 or 25
		for i = 0, DATA_SECTOR_OUTPUT_SIZE - 1 do
			sb.data[i + 1] = sector:byte(offset + i) or 0
		end
		sb.size = DATA_SECTOR_OUTPUT_SIZE
	end
	sb.position = 0
	self.currentWriteBuffer = sbNum

	-- a pending (undelivered) data interrupt means the previous sector was
	-- never delivered; duckstation clears it.
	if self.pendingInterrupt ~= nil then
		self:clearAsyncInterrupt()
	end

	table.insert(self.asyncResponseFifo, band(self.status, 0xFF))
	self:setAsyncInterrupt(INT_DATA_READY)
end

-- xa-adpcm sector: decode + resample into the audio fifo (duckstation processxaadpcmsector); never delivered to the cpu.
function CDROM:processXaAdpcmSector(sector, subq)
	local sub = self.lastSectorSubheader
	local fileNumber = sub[1] or 0
	local channelNumber = sub[2] or 0
	local submode = sub[3] or 0
	local coding = sub[4] or 0

	-- automatic adpcm filter (setfilter).
	if self:modeXaFilter() and (fileNumber ~= self.xaFilterFile or channelNumber ~= self.xaFilterChannel) then
		return
	end

	-- track the current file being played.  if this is not set by the filter,
	-- it'll be set by the first file/sector which is read.
	if not self.xaCurrentSet then
		-- junk audio sectors with channel 255 are skipped (taxi 2 / blues clues)
		-- unless the filter explicitly selects channel 255.
		if channelNumber == 255 and (not self:modeXaFilter() or self.xaFilterChannel ~= 255) then
			return
		end
		self.xaCurrentFile = fileNumber
		self.xaCurrentChannel = channelNumber
		self.xaCurrentSet = true
	elseif fileNumber ~= self.xaCurrentFile or channelNumber ~= self.xaCurrentChannel then
		return
	end

	-- reset current file on eof; the next sector establishes a new file.
	if band(submode, 0x80) ~= 0 then
		self.xaCurrentChannel = 0
		self.xaCurrentFile = 0
		self.xaCurrentSet = false
	end

	-- the spu steps before the cdrom, so the audio fifo is already drained to the current cycle (duckstation generatependingsamples).

	local stereo = xaIsStereo(coding)
	local numFrames = arshift(xaSamplesPerSector(coding), stereo and 1 or 0)
	if self:audioFifoSize() > AUDIO_FIFO_LOW_WATERMARK then
		-- spu is behind; drop the sector (duckstation low-watermark guard).
		return
	end

	-- decode always (updates previous samples even when muted).
	local sampleBuffer = self:decodeXaAdpcmChunks(sector, stereo, xaIs8BitADPCM(coding))
	self.xaCurrentCodinginfo = coding

	if self.muted or self.adpcmMuted then
		return
	end

	if stereo then
		if xaIsHalfSampleRate(coding) then
			self:resampleXaAdpcm18900(sampleBuffer, numFrames, true)
		else
			self:resampleXaAdpcm(sampleBuffer, numFrames, true)
		end
	else
		if xaIsHalfSampleRate(coding) then
			self:resampleXaAdpcm18900(sampleBuffer, numFrames, false)
		else
			self:resampleXaAdpcm(sampleBuffer, numFrames, false)
		end
	end
end

-- cd-da sector: report interrupts (setmode bit 2) with track/position/peak, and push the raw audio into the fifo (duckstation processcddasector).
function CDROM:processCddaSector(sector, subq)
	if self.driveState == DRIVE_PLAYING and self:modeReportAudio() and subq and subq.crcValid then
		if self.cddaReportStartDelay == 0 then
			local frameNibble = rshift(subq.absF, 4)
			if self.lastCddaReportFrameNibble ~= frameNibble then
				self.lastCddaReportFrameNibble = frameNibble
				self:clearAsyncInterrupt()
				table.insert(self.asyncResponseFifo, band(self.status, 0xFF))
				table.insert(self.asyncResponseFifo, band(subq.track, 0xFF))
				table.insert(self.asyncResponseFifo, band(subq.index, 0xFF))
				if band(subq.absF, 0x10) ~= 0 then
					table.insert(self.asyncResponseFifo, band(subq.relM, 0xFF))
					table.insert(self.asyncResponseFifo, bor(0x80, band(subq.relS, 0x7F)))
					table.insert(self.asyncResponseFifo, band(subq.relF, 0xFF))
				else
					table.insert(self.asyncResponseFifo, band(subq.absM, 0xFF))
					table.insert(self.asyncResponseFifo, band(subq.absS, 0xFF))
					table.insert(self.asyncResponseFifo, band(subq.absF, 0xFF))
				end
				local channel = band(subq.absS, 1)
				local peakVolume = self:getPeakVolume(sector)
				local peakValue = bor(lshift(channel, 15), band(peakVolume, 0x7FFF))
				table.insert(self.asyncResponseFifo, band(peakValue, 0xFF))
				table.insert(self.asyncResponseFifo, band(rshift(peakValue, 8), 0xFF))
				self:setAsyncInterrupt(INT_DATA_READY)
			end
		else
			self.cddaReportStartDelay -= 1
		end
	end

	-- push cd audio into the fifo (volume applied later at getaudioframe); the spu is already caught up when this runs.
	if self.muted or self.cddaAutoPausePending then
		return
	end

	-- 2 samples per channel, always stereo.  in 2x mode only half the samples
	-- in a sector get processed.
	local doubleSpeed = self:modeDoubleSpeed()
	local numSamples = math.floor(2352 / 2 / (doubleSpeed and 4 or 2))
	local remaining = self:audioFifoSpace()
	if remaining < numSamples then
		self:audioFifoRemove(numSamples - remaining)
	end
	local step = doubleSpeed and 8 or 4
	for i = 0, numSamples - 1 do
		local off = 1 + i * step
		local left = xaS16((sector:byte(off) or 0) + (sector:byte(off + 1) or 0) * 256)
		local right = xaS16((sector:byte(off + 2) or 0) + (sector:byte(off + 3) or 0) * 256)
		self:addCdAudioFrame(left, right)
	end
end

-- peak volume of a raw sector (max absolute s16 sample, both channels).
function CDROM:getPeakVolume(sector)
	local peak = 0
	local n = math.min(2352, #sector)
	for i = 1, n, 2 do
		local lo = sector:byte(i) or 0
		local hi = sector:byte(i + 1) or 0
		local sample = lo + hi * 256
		if sample >= 0x8000 then
			sample -= 0x10000
		end
		local abs = sample < 0 and -sample or sample
		if abs > peak then
			peak = abs
		end
	end
	return peak
end

function CDROM:doSectorRead()
	if not self:canReadMedia() then
		self:stopReadingWithError(ERROR_REASON_NOT_READY)
		return
	end

	local lba = self.requestedLba
	local sector = self:readSector(lba)
	if not sector then
		self:stopReadingWithError(ERROR_REASON_NOT_READY)
		return
	end

	self.sectorsDelivered += 1
	self.debug.sectorReadCount += 1
	self.lastReadSector = lba
	self.currentLba = lba
	self.currentSubqLba = lba
	self.lastSubqNeedsUpdate = false
	self.subqLbaUpdateTick = self.totalCycles
	self.subqLbaUpdateCarry = 0

	self:setReadingBits(self.driveState == DRIVE_PLAYING)

	local subq = self:getSubqForLba(lba)
	self.lastSubq = subq

	local isData = subq.isData
	if isData then
		self:processDataSectorHeader(sector)
	elseif self:modeAutoPause() then
		if self.cddaAutoPausePending then
			self.cddaAutoPausePending = false
			self:stopReadingWithDataEnd()
			return
		end
		if self.playTrackNumberBcd == 0 then
			self.playTrackNumberBcd = subq.trackNumberBcd
		elseif self.playTrackNumberBcd ~= subq.trackNumberBcd then
			self.cddaAutoPausePending = true
		end
	end

	local nextSector = lba + 1
	if isData and self.driveState == DRIVE_READING then
		self:processDataSector(sector, subq)
	elseif not isData and (self.driveState == DRIVE_PLAYING or (self.driveState == DRIVE_READING and self:modeCdda())) then
		self:processCddaSector(sector, subq)
		if self.fastForwardRate ~= 0 then
			nextSector = lba + self.fastForwardRate
		end
	else
		self:trace(string.format("skipping sector %d: %s sector and we're not %s", lba, isData and "data" or "audio", isData and "reading" or "playing"))
	end

	self.requestedLba = nextSector
	self:trace(string.format("read sector lba=%d subq=%02X:%02X:%02X mode=%d", lba, subq.absM, subq.absS, subq.absF, self.lastSectorHeader.mode))
end

function CDROM:stopReadingWithDataEnd()
	self:clearAsyncInterrupt()
	table.insert(self.asyncResponseFifo, band(self.status, 0xFF))
	self:setAsyncInterrupt(INT_DATA_END)
	self:clearActiveBits()
	self:clearDriveState()
end

function CDROM:stopReadingWithError(reason)
	self:clearAsyncInterrupt()
	self:sendAsyncErrorResponse(STAT_ERROR, reason)
	self:clearActiveBits()
	self:clearDriveState()
end


function CDROM:doDriveEvent()
	local state = self.driveState
	if state == DRIVE_SEEKING_PHYSICAL or state == DRIVE_SEEKING_LOGICAL then
		self:doSeekComplete()
	elseif state == DRIVE_SEEKING_IMPLICIT then
		self:completeSeek()
	elseif state == DRIVE_READING or state == DRIVE_PLAYING then
		self:doSectorRead()
		-- reschedule at the read cadence
		if self.driveState == DRIVE_READING or self.driveState == DRIVE_PLAYING then
			self.driveEventInterval = self:getTicksForRead()
			self.driveEventRemaining = self.driveEventInterval
		end
	elseif state == DRIVE_CHANGING_SESSION then
		self:doChangeSessionComplete()
	elseif state == DRIVE_SPINNING_UP then
		self.driveState = DRIVE_IDLE
		self.driveEventRemaining = nil
		self:clearActiveBits()
		self.status = bor(self.status, STAT_MOTOR_ON)
	elseif state == DRIVE_CHANGING_SPEED_OR_TOC then
		self.driveState = DRIVE_IDLE
		self.driveEventRemaining = nil
	end
end

function CDROM:doChangeSessionComplete()
	self:clearDriveState()
	self:clearActiveBits()
	self.status = bor(self.status, STAT_MOTOR_ON)
	self.asyncResponseFifo = {}
	if self.asyncCommandParameter == 0x01 then
		table.insert(self.asyncResponseFifo, band(self.status, 0xFF))
		self:setAsyncInterrupt(INT_COMPLETE)
	else
		self:sendAsyncErrorResponse(STAT_SEEK_ERROR, 0x40)
	end
end

function CDROM:doStatSecondResponse()
	if not self:canReadMedia() then
		self:sendAsyncErrorResponse(STAT_ERROR, 0x08)
		return
	end
	self.asyncResponseFifo = {}
	table.insert(self.asyncResponseFifo, band(self.status, 0xFF))
	self:setAsyncInterrupt(INT_COMPLETE)
end

function CDROM:doIdRead()
	self:clearActiveBits()
	if self:canReadMedia() then
		self.status = bor(self.status, STAT_MOTOR_ON)
	end

	local statByte = band(self.status, 0xFF)
	local flagsByte = 0
	if not self:canReadMedia() then
		statByte = bor(statByte, STAT_ID_ERROR)
		flagsByte = bor(flagsByte, 0x40) -- Disc missing
	elseif self:isMediaAudioCd() then
		statByte = bor(statByte, STAT_ID_ERROR)
		flagsByte = bor(flagsByte, 0x90) -- Unlicensed + audio CD
	elseif self.disc and self.disc.discRegion == "NonPS1" then
		statByte = bor(statByte, STAT_ID_ERROR)
		flagsByte = bor(flagsByte, 0x80) -- Unlicensed
	end

	self.asyncResponseFifo = {}
	table.insert(self.asyncResponseFifo, band(statByte, 0xFF))
	table.insert(self.asyncResponseFifo, band(flagsByte, 0xFF))
	table.insert(self.asyncResponseFifo, 0x20) -- disc type
	table.insert(self.asyncResponseFifo, 0x00) -- session info
	local region = self.licenseRegion or "SCEI"
	for i = 1, 4 do
		table.insert(self.asyncResponseFifo, string.byte(region, i) or 0x53)
	end
	self:setAsyncInterrupt(flagsByte ~= 0 and INT_ERROR or INT_COMPLETE)
end

-- delayed command responses

function CDROM:clearCommandSecondResponse()
	self.commandSecondResponse = nil
	self.commandSecondResponseRemaining = nil
end

function CDROM:queueCommandSecondResponse(command, ticks)
	self:clearCommandSecondResponse()
	self.commandSecondResponse = command
	self.commandSecondResponseRemaining = math.max(1, ticks or 1)
end

function CDROM:executeCommandSecondResponse()
	local cmd = self.commandSecondResponse
	if cmd == 0x1A then
		-- getid
		self:doIdRead()
	elseif cmd == 0x0A then
		-- init: cancel any pending command so the completion gets through
		-- (openbios spams init).
		if self:hasPendingCommand() then
			self:endCommand()
		end
		self:doStatSecondResponse()
	elseif cmd == 0x1E or cmd == 0x09 or cmd == 0x07 then
		-- readtoc / pause / motoron
		self:doStatSecondResponse()
	elseif cmd == 0x08 then
		-- stop
		self:doStatSecondResponse()
	end
	self:clearCommandSecondResponse()
end

-- command execution

function CDROM:executeCommand(command)
	command = band(command, 0xFF)
	self.debug.commandCount += 1
	self.debug.lastCommand = command
	self.debug.lastCommandParams = copyArray(self.paramFifo)
	self:trace(string.format("command %02X (%s) params=%d pc=%08X", command, (COMMAND_INFO[command + 1] or { "Unknown", 0, 0 })[1], #self.paramFifo, self:getPc()))

	if command >= VALID_COMMAND_COUNT then
		self:sendErrorResponse(STAT_ERROR, ERROR_REASON_INVALID_COMMAND)
		self:endCommand()
		return
	end

	local info = COMMAND_INFO[command + 1]
	local n = #self.paramFifo
	if n < info[2] or n > info[3] then
		self:sendErrorResponse(STAT_ERROR, ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS)
		self:endCommand()
		return
	end

	-- clear stale response bytes (duckstation executecommand).
	self.responseFifo = {}

	local function peek(i)
		return self.paramFifo[i] or 0
	end

	if command == 0x01 then
		-- getstat
		self:sendAckAndStat()
		-- shell-open bit cleared after sending the status when the door is closed.
		if self:canReadMedia() then
			self.status = band(self.status, bnot(STAT_SHELL_OPEN))
		end
		self:endCommand()
		return
	end

	if command == 0x02 then
		-- setloc
		local mm, ss, ff = peek(1), peek(2), peek(3)
		if (band(mm, 0x0F) > 0x09) or (mm > 0x99) or (band(ss, 0x0F) > 0x09) or (ss >= 0x60) or
			(band(ff, 0x0F) > 0x09) or (ff >= 0x75) then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_INVALID_ARGUMENT)
		else
			self:sendAckAndStat()
			self.setlocPosition.minute = bcdToInt(mm)
			self.setlocPosition.second = bcdToInt(ss)
			self.setlocPosition.frame = bcdToInt(ff)
			self.setlocLba = math.max(0, msfToLba(mm, ss, ff))
			self.setlocPending = true
			self:trace(string.format("Setloc %02X:%02X:%02X lba=%d", mm, ss, ff, self.setlocLba))
		end
		self:endCommand()
		return
	end

	if command == 0x03 then
		-- play
		local track = n == 0 and 0 or bcdToInt(peek(1))
		if not self:canReadMedia() then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_NOT_READY)
		else
			self:sendAckAndStat()
			local nextSector = self:getNextSectorToBeRead()
			if track == 0 and (not self.setlocPending or self.setlocLba == nextSector)
				and (self.driveState == DRIVE_PLAYING or (self:isSeeking() and self.playAfterSeek)) then
				self.fastForwardRate = 0
				self.setlocPending = false
			else
				self:beginPlaying(track, false)
			end
		end
		self:endCommand()
		return
	end

	if command == 0x04 or command == 0x05 then
		-- forward / backward (cdda scan, playing only)
		if self.driveState ~= DRIVE_PLAYING or not self:canReadMedia() then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_NOT_READY)
		else
			self:sendAckAndStat()
			if command == 0x04 then
				if self.fastForwardRate < 0 then
					self.fastForwardRate = 0
				end
				self.fastForwardRate = math.min(self.fastForwardRate + 4, 12)
			else
				if self.fastForwardRate > 0 then
					self.fastForwardRate = 0
				end
				self.fastForwardRate = math.max(self.fastForwardRate - 4, -12)
			end
		end
		self:endCommand()
		return
	end

	if command == 0x06 or command == 0x1B then
		-- readn / reads
		if not self:canReadMedia() then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_NOT_READY)
		elseif (self:isMediaAudioCd() or self:isRegionMismatched()) and not self:modeCdda() then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_INVALID_COMMAND)
		else
			self:sendAckAndStat()
			local nextSector = self:getNextSectorToBeRead()
			if (not self.setlocPending or self.setlocLba == nextSector)
				and (self.driveState == DRIVE_READING or (self:isSeeking() and self.readAfterSeek)) then
				self:trace(string.format("ignoring %s (already reading %d)", command == 0x06 and "ReadN" or "ReadS", nextSector))
				self.setlocPending = false
			else
				self:beginReading(false)
			end
		end
		self:endCommand()
		return
	end

	if command == 0x07 then
		-- standby / motoron
		if self:isMotorOn() then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS)
		elseif not self:canReadMedia() then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_NOT_READY)
		else
			self:sendAckAndStat()
			if self.commandSecondResponse == 0x07 then
				self:endCommand()
				return
			end
			self.status = bor(self.status, STAT_MOTOR_ON)
			self:startMotor()
			self:queueCommandSecondResponse(0x07, MOTOR_ON_RESPONSE_TICKS)
		end
		self:endCommand()
		return
	end

	if command == 0x08 then
		-- stop
		local stopTime = self:getTicksForStop(self:isMotorOn())
		self:clearAsyncInterrupt()
		self:clearCommandSecondResponse()
		self:sendAckAndStat()
		self:stopMotor()
		self:queueCommandSecondResponse(0x08, stopTime)
		self:endCommand()
		return
	end

	if command == 0x09 then
		-- pause
		local pauseTime = self:getTicksForPause()
		if self:isReading() and self.lastSubq and self.lastSubq.isData then
			local spt = self:getSectorsPerTrack(self.currentLba)
			self:setHoldPosition(self.currentLba, (spt <= self.currentLba) and (self.currentLba - spt) or 0)
		end
		self:clearCommandSecondResponse()
		self:sendAckAndStat()

		if self.driveState == DRIVE_SEEKING_LOGICAL or self.driveState == DRIVE_SEEKING_PHYSICAL
			or ((self.driveState == DRIVE_READING or self.driveState == DRIVE_PLAYING) and band(self.status, STAT_SEEKING) ~= 0) then
			-- hardware-verified: pause fails with 80h while the mech is still
			-- seeking/processing the first sector.
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_NOT_READY)
			self:endCommand()
			return
		end

		self:clearAsyncInterrupt()
		self.driveState = DRIVE_IDLE
		self.driveEventRemaining = nil
		self:clearActiveBits()
		self:resetAudioDecoder()
		self:queueCommandSecondResponse(0x09, pauseTime)
		self:endCommand()
		self:trace(string.format("Pause (idle, INT2 in %d cycles)", pauseTime))
		return
	end

	if command == 0x0A then
		-- init
		if self.commandSecondResponse == 0x0A then
			-- an init is already in progress; silently drop this one.
			self:endCommand()
			return
		end
		self:sendAckAndStat()
		local resetTicks = self:softReset()
		self:queueCommandSecondResponse(0x0A, resetTicks)
		self:endCommand()
		return
	end

	if command == 0x0B then
		self.muted = true
		self:sendAckAndStat()
		self:endCommand()
		return
	end

	if command == 0x0C then
		self.muted = false
		self:sendAckAndStat()
		self:endCommand()
		return
	end

	if command == 0x0D then
		-- setfilter
		self.xaFilterFile = peek(1)
		self.xaFilterChannel = peek(2)
		self.xaCurrentSet = false
		self:sendAckAndStat()
		self:endCommand()
		return
	end

	if command == 0x0E then
		-- setmode
		local mode = peek(1)
		local speedChange = (band(mode, 0x80) ~= 0) ~= (band(self.mode, 0x80) ~= 0)
		self.mode = mode
		self:trace(string.format("Setmode mode=%02X", self.mode))
		self:sendAckAndStat()
		self:endCommand()
		if speedChange then
			if self.driveState == DRIVE_CHANGING_SPEED_OR_TOC then
				if (self.driveEventRemaining or 0) >= math.floor(self:getTicksForSpeedChange() / 4) then
					self:clearDriveState()
				end
			elseif self.driveState ~= DRIVE_SEEKING_IMPLICIT and self.driveState ~= DRIVE_SHELL_OPENING then
				local changeTicks = self:getTicksForSpeedChange()
				if self.driveState ~= DRIVE_IDLE then
					self.driveEventRemaining = (self.driveEventRemaining or 0) + changeTicks
					if self:isReadingOrPlaying() then
						self.driveEventInterval = self:getTicksForRead()
					end
				else
					self.driveState = DRIVE_CHANGING_SPEED_OR_TOC
					self.driveEventInterval = changeTicks
					self.driveEventRemaining = changeTicks
				end
			end
		end
		return
	end

	if command == 0x0F then
		-- getmode: stat, mode, 0, file, channel (5 bytes)
		self:pushResponse({ band(self.status, 0xFF), self.mode, 0, self.xaFilterFile, self.xaFilterChannel })
		self:setInterrupt(INT_ACK)
		self:endCommand()
		return
	end

	if command == 0x10 then
		-- getlocl: last data-sector header (4) + subheader (8)
		if not self.lastSectorHeaderValid then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_NOT_READY)
		else
			self:updateSubQPosition(true)
			local h = self.lastSectorHeader
			local s = self.lastSectorSubheader
			self:pushResponse({ h.minute, h.second, h.frame, h.mode, s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8] })
			self:setInterrupt(INT_ACK)
		end
		self:endCommand()
		return
	end

	if command == 0x11 then
		-- getlocp: track, index, rel m/s/f, abs m/s/f (8 bytes)
		if not self:canReadMedia() then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_NOT_READY)
		else
			if self:isSeeking() then
				self:updateSubQPositionWhileSeeking()
			else
				self:updateSubQPosition(false)
			end
			self:ensureLastSubqValid()
			local q = self.lastSubq
			self:pushResponse({ q.track, q.index, q.relM, q.relS, q.relF, q.absM, q.absS, q.absF })
			self:setInterrupt(INT_ACK)
		end
		self:endCommand()
		return
	end

	if command == 0x12 then
		-- readt (setsession)
		local session = peek(1)
		if not self:canReadMedia() or self.driveState == DRIVE_READING or self.driveState == DRIVE_PLAYING then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_NOT_READY)
		elseif session == 0 then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_INVALID_ARGUMENT)
		else
			self:clearCommandSecondResponse()
			self:sendAckAndStat()
			self.asyncCommandParameter = session
			self.driveState = DRIVE_CHANGING_SESSION
			self.driveEventInterval = self:getTicksForTocRead()
			self.driveEventRemaining = self.driveEventInterval
		end
		self:endCommand()
		return
	end

	if command == 0x13 then
		-- gettn: stat, first track, last track (bcd)
		if self:canReadMedia() then
			self:pushResponse({ band(self.status, 0xFF), intToBcd(self:getFirstTrackNumber()), intToBcd(self:getLastTrackNumber()) })
			self:setInterrupt(INT_ACK)
		else
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_NOT_READY)
		end
		self:endCommand()
		return
	end

	if command == 0x14 then
		-- gettd: stat, mm, ss (3 bytes)
		local trackBcd = peek(1)
		if not self:canReadMedia() then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_NOT_READY)
		elseif not isPackedBcd(trackBcd) then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_INVALID_ARGUMENT)
		else
			local track = bcdToInt(trackBcd)
			if track > self:getTrackCount() then
				self:sendErrorResponse(STAT_ERROR, ERROR_REASON_INVALID_ARGUMENT)
			else
				local m, s
				if track == 0 then
					local lbaCount = self:getDiscLbaCount()
					local lm, ls = lbaToMsf(lbaCount)
					m, s = lm, ls
				else
					local lm, ls = lbaToMsf(self:getTrackStartPosition(track))
					m, s = lm, ls
				end
				self:pushResponse({ band(self.status, 0xFF), intToBcd(m), intToBcd(s) })
				self:setInterrupt(INT_ACK)
			end
		end
		self:endCommand()
		return
	end

	if command == 0x15 or command == 0x16 then
		-- seekl / seekp
		local logical = command == 0x15
		if not self:canReadMedia() then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_NOT_READY)
		else
			self:sendAckAndStat()
			self:beginSeeking(logical, false, false)
		end
		self:endCommand()
		return
	end

	if command == 0x17 or command == 0x18 or command == 0x1D or command == 0x00 then
		-- setclock / getclock / getq / sync: invalid
		self:sendErrorResponse(STAT_ERROR, ERROR_REASON_INVALID_COMMAND)
		self:endCommand()
		return
	end

	if command == 0x19 then
		-- test
		local sub = peek(1)
		self.paramFifo = {}
		if sub == 0x04 then
			self.status = bor(self.status, STAT_MOTOR_ON)
			self:pushResponse({ band(self.status, 0xFF) })
			self:setInterrupt(INT_ACK)
			self:endCommand()
		elseif sub == 0x05 then
			self:pushResponse({ 0x00, 0x00 })
			self:setInterrupt(INT_ACK)
			self:endCommand()
		elseif sub == 0x20 then
			-- duckstation version_table indexed by cdrommechaconversion (0-based)
			local version = MECHACON_VERSION_TABLE[math.max(1, math.min((self.mechaconVersion or 0) + 1, #MECHACON_VERSION_TABLE))]
			self:pushResponse(copyArray(version or { 0x95, 0x05, 0x16, 0xC1 }))
			self:setInterrupt(INT_ACK)
			self:endCommand()
		elseif sub == 0x22 then
			-- region id string (ntsc-u default: "for u/c")
			local region = { 0x66, 0x6F, 0x72, 0x20, 0x55, 0x2F, 0x43 }
			self:pushResponse(region)
			self:setInterrupt(INT_ACK)
			self:endCommand()
		elseif sub == 0x60 then
			if n < 2 then
				self:sendErrorResponse(STAT_ERROR, ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS)
			else
				self:pushResponse({ 0x00 })
				self:setInterrupt(INT_ACK)
			end
			self:endCommand()
		else
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_INVALID_COMMAND)
			self:endCommand()
		end
		return
	end

	if command == 0x1A then
		-- getid: ack then int2/int5 with stat/flags/type/region (8 bytes)
		self:clearCommandSecondResponse()
		if not self:canReadMedia() then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_NOT_READY)
		else
			self:sendAckAndStat()
			self:queueCommandSecondResponse(0x1A, self:getTicksForIdRead())
		end
		self:endCommand()
		return
	end

	if command == 0x1C then
		-- reset (undocumented): soft reset + ack
		self:softReset()
		self:sendAckAndStat()
		self:endCommand()
		return
	end

	if command == 0x1E then
		-- readtoc
		self:clearCommandSecondResponse()
		if not self:canReadMedia() then
			self:sendErrorResponse(STAT_ERROR, ERROR_REASON_NOT_READY)
		else
			self:sendAckAndStat()
			self:setHoldPosition(0, 0)
			self:queueCommandSecondResponse(0x1E, self:getTicksForTocRead())
		end
		self:endCommand()
		return
	end

	if command == 0x1F then
		-- videocd: invalid command; does not clear the parameter fifo.
		self:sendErrorResponse(STAT_ERROR, ERROR_REASON_INVALID_COMMAND)
		self.command = nil
		self.commandEventRemaining = nil
		self.commandEventInterval = nil
		self:updateStatusRegister()
		return
	end

	-- unknown commands are rejected in the command >= valid_command_count path.
	self:sendErrorResponse(STAT_ERROR, ERROR_REASON_INVALID_COMMAND)
	self:endCommand()
end

function CDROM:isRegionMismatched()
	return false
end

function CDROM:getNextSectorToBeRead()
	if not (self:isReadingOrPlaying() or self:isSeeking()) then
		return self.currentLba
	end
	return self.lastReadSector
end

function CDROM:pushResponse(bytes)
	for _, value in ipairs(bytes) do
		table.insert(self.responseFifo, band(value, 0xFF))
	end
end

-- reset and mounting

-- duckstation softreset: used by init and reset.
function CDROM:softReset()
	local wasDoubleSpeed = band(self.mode, 0x80) ~= 0

	self:clearCommandSecondResponse()
	self:clearDriveState()
	self.status = 0
	if self:canReadMedia() then
		self.status = bor(self.status, STAT_MOTOR_ON)
	else
		self.status = bor(self.status, STAT_SHELL_OPEN)
	end
	self.mode = 0
	self.mode = bor(self.mode, 0x20) -- read_raw_sector = true
	self.requestRegister = 0
	self:clearAsyncInterrupt()
	self.setlocPosition = { minute = 0, second = 2, frame = 0 }
	self.setlocLba = 0
	self.setlocPending = false
	self.readAfterSeek = false
	self.playAfterSeek = false
	self.muted = false
	self.adpcmMuted = false
	self.cddaAutoPausePending = false
	self.cddaReportStartDelay = 0
	self.lastCddaReportFrameNibble = 0xFF
	self:clearSectorBuffers()
	self:resetAudioDecoder()
	self.paramFifo = {}
	self.asyncResponseFifo = {}
	self:updateStatusRegister()

	local totalTicks
	if self.disc then
		if self:isSeeking() then
			self:updateSubQPositionWhileSeeking()
		else
			self:updateSubQPosition(false)
		end
		local speedChangeTicks = wasDoubleSpeed and self:getTicksForSpeedChange() or 0
		local seekTicks = (self.currentLba ~= 0) and self:getTicksForSeek(0) or 0
		totalTicks = math.max(speedChangeTicks + seekTicks, INIT_TICKS)
		if self.currentLba ~= 0 then
			self.driveState = DRIVE_SEEKING_IMPLICIT
			self.driveEventInterval = totalTicks
			self.driveEventRemaining = totalTicks
			self.requestedLba = 0
			self.seekStartLba = self.currentLba
			self.seekEndLba = 0
		else
			self.driveState = DRIVE_CHANGING_SPEED_OR_TOC
			self.driveEventInterval = totalTicks
			self.driveEventRemaining = totalTicks
		end
	else
		totalTicks = INIT_TICKS
	end
	self:trace(string.format("softReset totalTicks=%d driveState=%d", totalTicks, self.driveState))
	return totalTicks
end

-- duckstation reset() (power-on / mount resets the controller to this state).
function CDROM:resetState()
	self.command = nil
	self.commandEventRemaining = nil
	self.commandEventInterval = nil
	self:clearCommandSecondResponse()
	self:clearDriveState()
	self.index = 0
	self.status = 0
	if self:canReadMedia() then
		self.status = bor(self.status, STAT_MOTOR_ON)
	else
		self.status = bor(self.status, STAT_SHELL_OPEN)
	end
	self.mode = 0
	self.mode = bor(self.mode, 0x20) -- read_raw_sector = true (hardware reset value)
	self.irqEnable = INTERRUPT_REGISTER_MASK
	self.irqFlags = 0
	self.lastInterruptTime = 0
	self:clearAsyncInterrupt()
	self.setlocPosition = { minute = 0, second = 2, frame = 0 }
	self.setlocLba = 0
	self.setlocPending = false
	self.readAfterSeek = false
	self.playAfterSeek = false
	self.muted = false
	self.adpcmMuted = false
	self.xaFilterFile = 0
	self.xaFilterChannel = 0
	self.xaCurrentFile = 0
	self.xaCurrentChannel = 0
	self.xaCurrentSet = false
	self.lastSectorHeader = { minute = 0, second = 0, frame = 0, mode = 0 }
	self.lastSectorSubheader = { 0, 0, 0, 0, 0, 0, 0, 0 }
	self.lastSectorHeaderValid = false
	self.lastSubq = { track = 0x01, index = 0x01, relM = 0, relS = 2, relF = 0, absM = 0, absS = 2, absF = 0, crcValid = true, isData = true }
	self.cddaReportStartDelay = 0
	self.lastCddaReportFrameNibble = 0xFF
	self.cdAudioVolumeMatrix = { { 0x80, 0x00 }, { 0x00, 0x80 } }
	self.nextCdAudioVolumeMatrix = { { 0x80, 0x00 }, { 0x00, 0x80 } }
	self:clearSectorBuffers()
	self:resetAudioDecoder()
	self.paramFifo = {}
	self.responseFifo = {}
	self.asyncResponseFifo = {}
	self.prng = PRNG.new(PRNG_SEED)
	self:updateStatusRegister()
	self:setHoldPosition(0, 0)
end

function CDROM:mount(disc)
	self.disc = disc
	self.totalCycles = 0
	self.lastInterruptTime = 0
	self.sectorsDelivered = 0
	self.lastReadSector = 0
	self.debug = createDebugState()
	self:resetState()
end

-- register interface

function CDROM:read(address)
	address = band(address, 0xFFFFFFFF)
	local offset = address - 0x1F801800
	if offset == 0 then
		self.debug.readCounts.status += 1
		local value = self:getStatusPortValue()
		return value
	elseif offset == 1 then
		self.debug.readCounts.response += 1
		if #self.responseFifo == 0 then
			self:trace("read response FIFO empty -> 00")
			return 0
		end
		return table.remove(self.responseFifo, 1)
	elseif offset == 2 then
		self.debug.readCounts.data += 1
		return self:popDataByte()
	elseif offset == 3 then
		if band(self.index, 1) ~= 0 then
			self.debug.readCounts.irqFlags += 1
			return bor(band(self.irqFlags, 0xFF), bnot(INTERRUPT_REGISTER_MASK))
		end
		self.debug.readCounts.irqEnable += 1
		return bor(band(self.irqEnable, 0xFF), bnot(INTERRUPT_REGISTER_MASK))
	end
	return 0
end

function CDROM:write(address, value)
	address = band(address, 0xFFFFFFFF)
	value = band(value, 0xFF)
	local offset = address - 0x1F801800
	if offset == 0 then
		self.debug.writeCounts.index += 1
		self.index = band(value, 0x3)
		return
	end

	if offset == 1 or offset == 2 or offset == 3 then
		local reg = (self.index * 3) + (offset - 1)
		if reg == 0 then
			self.debug.writeCounts.command += 1
			self:trace(string.format("command write value=%02X params=%d pc=%08X", value, #self.paramFifo, self:getPc()))
			self:beginCommand(value)
		elseif reg == 1 then
			self.debug.writeCounts.param += 1
			self.debug.parameterByteCount += 1
			if #self.paramFifo >= PARAM_FIFO_SIZE then
				table.remove(self.paramFifo, 1)
			end
			table.insert(self.paramFifo, value)
			self:trace(string.format("param push value=%02X count=%d", value, #self.paramFifo))
		elseif reg == 2 then
			-- request register: bfrd = bit 7 (data-read gate).
			self.debug.writeCounts.fifoControl += 1
			self.requestRegister = value
			if band(value, 0x80) == 0 then
				-- clearing bfrd resets the read buffer position (mgs: special missions clears it between two dmas).
				self.sectorBuffers[self.currentReadBuffer + 1].position = 0
			end
			self:trace(string.format("request register=%02X (bfrd=%d)", self.requestRegister, band(self.requestRegister, 0x80) ~= 0 and 1 or 0))
		elseif reg == 3 then
			-- sound map data out: no-op
		elseif reg == 4 then
			self.debug.writeCounts.irqEnable += 1
			self.irqEnable = band(value, INTERRUPT_REGISTER_MASK)
			self:trace(string.format("irqEnable=%02X", self.irqEnable))
			self:updateInterruptRequest()
		elseif reg == 5 then
			self.debug.writeCounts.irqAck += 1
			self.debug.lastIrqAckValue = value
			local prevFlags = self.irqFlags
			self.irqFlags = band(self.irqFlags, bnot(band(value, INTERRUPT_REGISTER_MASK)))
			if self.irqFlags == 0 then
				if prevFlags ~= 0 then
					self.lastInterruptTime = self.totalCycles
				end
				if self.pendingInterrupt ~= nil then
					if not self:hasPendingCommand() then
						self:queueDeliverAsyncInterrupt()
					else
						self:updateCommandEvent()
					end
				else
					self:updateCommandEvent()
				end
			end
			-- bit 6 clears the parameter fifo (duckstation); bit 7 has no effect.
			if band(value, 0x40) ~= 0 then
				self.debug.writeCounts.fifoControl += 1
				self.paramFifo = {}
			end
			self:trace(string.format("irqFlags ack value=%02X old=%02X new=%02X", band(value, 0x1F), prevFlags, self.irqFlags))
		elseif reg == 6 then
			-- sound map coding info: no-op
		elseif reg == 7 then
			self.nextCdAudioVolumeMatrix[1][1] = value
		elseif reg == 8 then
			self.nextCdAudioVolumeMatrix[1][2] = value
		elseif reg == 9 then
			self.nextCdAudioVolumeMatrix[2][2] = value
		elseif reg == 10 then
			self.nextCdAudioVolumeMatrix[2][1] = value
		elseif reg == 11 then
			-- audio volume apply: bit 0 = mute xa, bit 5 = apply volumes.
			local adpcmMuted = band(value, 0x01) ~= 0
			self.adpcmMuted = adpcmMuted
			if band(value, 0x20) ~= 0 then
				self.cdAudioVolumeMatrix = {
					{ self.nextCdAudioVolumeMatrix[1][1], self.nextCdAudioVolumeMatrix[1][2] },
					{ self.nextCdAudioVolumeMatrix[2][1], self.nextCdAudioVolumeMatrix[2][2] },
				}
			end
		end
	end
end


function CDROM:checkForSectorBufferReadComplete()
	local sb = self.sectorBuffers[self.currentReadBuffer + 1]

	-- bfrd gets cleared on dma/buffer completion.
	self.requestRegister = band(self.requestRegister, 0x7F)
	if sb.position < sb.size then
		self.requestRegister = bor(self.requestRegister, 0x80)
	end

	-- buffer complete?
	if sb.position >= sb.size then
		sb.position = 0
		sb.size = 0
	end

	-- redeliver a missed sector: if the next buffer holds one and no int1 is pending, re-raise it after a short delay (or split transfers get the wrong sector).
	local nextSb = self.sectorBuffers[self.currentWriteBuffer + 1]
	if nextSb.position == 0 and nextSb.size > 0 and not self:hasPendingAsyncInterrupt() and self:isReading() then
		local delay = math.min(self.driveEventRemaining or MISSED_INT1_DELAY_CYCLES, MISSED_INT1_DELAY_CYCLES)
		table.insert(self.asyncResponseFifo, band(self.status, 0xFF))
		self.pendingInterrupt = INT_DATA_READY
		self.asyncDeliveryRemaining = math.max(1, delay)
	end
end

function CDROM:popDataByte()
	if band(self.requestRegister, 0x80) == 0 then
		-- bfrd not set: data reads are gated off (duckstation returns 0)
		return 0
	end
	local sb = self.sectorBuffers[self.currentReadBuffer + 1]
	if sb.position >= sb.size then
		return 0
	end
	sb.position += 1
	local value = sb.data[sb.position] or 0
	self:checkForSectorBufferReadComplete()
	return value
end

function CDROM:popDataWord()
	local b0 = self:popDataByte()
	local b1 = self:popDataByte()
	local b2 = self:popDataByte()
	local b3 = self:popDataByte()
	return bor(b0, lshift(b1, 8), lshift(b2, 16), lshift(b3, 24))
end

-- current readable data length (bytes remaining in the active read buffer).
function CDROM:getReadBufferRemaining()
	local sb = self.sectorBuffers[self.currentReadBuffer + 1]
	if band(self.requestRegister, 0x80) == 0 then
		return 0
	end
	return math.max(0, sb.size - sb.position)
end

-- legacy view: the readable bytes of the current buffer (for probes).
function CDROM:getDataFifoView()
	local sb = self.sectorBuffers[self.currentReadBuffer + 1]
	local out = {}
	for i = sb.position + 1, sb.size do
		out[#out + 1] = sb.data[i] or 0
	end
	return out
end

-- cycle driver

-- process all due events for a cycle batch.  order (fixed, deterministic):
-- command second response, drive event, command event, async delivery.
function CDROM:step(cycles)
	if cycles <= 0 then
		return
	end
	self.totalCycles = band(self.totalCycles + cycles, 0xFFFFFFFF)

	-- 1. command second response (int2 for init/pause/stop/motoron/getid/...)
	if self.commandSecondResponseRemaining ~= nil then
		self.commandSecondResponseRemaining -= cycles
		if self.commandSecondResponseRemaining <= 0 then
			self:executeCommandSecondResponse()
		end
	end

	-- 2. drive event (seek/read/play/spin-up/speed-change)
	if self.driveEventRemaining ~= nil then
		self.driveEventRemaining -= cycles
		if self.driveEventRemaining <= 0 then
			self.driveEventRemaining = nil
			self:doDriveEvent()
		end
	end

	-- 3. command event: runs to completion even if an async interrupt arrives during the ack window -- the ack still fires and the async is delivered after (freezing the countdown wedged silent hill's init).
	if self.commandEventRemaining ~= nil and self.irqFlags == 0 then
		self.commandEventRemaining -= cycles
		if self.commandEventRemaining <= 0 then
			local command = self.command
			self.command = nil
			self.commandEventRemaining = nil
			self.commandEventInterval = nil
			if command ~= nil then
				self:executeCommand(command)
			end
		end
	-- (a visible interrupt still pauses the countdown; the ack path
	-- re-activates execution, matching duckstation's deactivated event)
	end

	-- 4. async interrupt delivery
	if self.asyncDeliveryRemaining ~= nil then
		self.asyncDeliveryRemaining -= cycles
		if self.asyncDeliveryRemaining <= 0 then
			self.asyncDeliveryRemaining = nil
			self:deliverAsyncInterrupt()
		end
	end
end

-- state dump

function CDROM:dumpState()
	local debug = self.debug or createDebugState()
	return {
		index = self.index,
		status = self.status,
		mode = self.mode,
		irqEnable = self.irqEnable,
		irqFlags = self.irqFlags,
		requestRegister = self.requestRegister,
		driveState = self.driveState,
		readActive = self.driveState == DRIVE_READING,
		currentLba = self.currentLba,
		currentSubqLba = self.currentSubqLba,
		targetLba = self.setlocLba,
		command = self.command,
		commandEventRemaining = self.commandEventRemaining,
		commandSecondResponse = self.commandSecondResponse,
		commandSecondResponseRemaining = self.commandSecondResponseRemaining,
		driveEventRemaining = self.driveEventRemaining,
		driveEventInterval = self.driveEventInterval,
		pendingInterrupt = self.pendingInterrupt,
		asyncDeliveryRemaining = self.asyncDeliveryRemaining,
		dataFifoCount = self.sectorBuffers[self.currentReadBuffer + 1].size,
		dataPosition = self.sectorBuffers[self.currentReadBuffer + 1].position,
		responseFifoCount = #self.responseFifo,
		paramFifoCount = #self.paramFifo,
		readCounts = {
			status = debug.readCounts.status,
			response = debug.readCounts.response,
			data = debug.readCounts.data,
			irqFlags = debug.readCounts.irqFlags,
			irqEnable = debug.readCounts.irqEnable,
		},
		writeCounts = {
			index = debug.writeCounts.index,
			command = debug.writeCounts.command,
			param = debug.writeCounts.param,
			irqEnable = debug.writeCounts.irqEnable,
			irqAck = debug.writeCounts.irqAck,
			fifoControl = debug.writeCounts.fifoControl,
		},
		commandCount = debug.commandCount,
		parameterByteCount = debug.parameterByteCount,
		irqCount = debug.irqCount,
		irqCallbackCount = debug.irqCallbackCount,
		sectorReadCount = debug.sectorReadCount,
		lastCommand = debug.lastCommand,
		lastCommandParams = copyArray(debug.lastCommandParams),
		lastIrqReason = debug.lastIrqReason,
		lastIrqPendingMask = debug.lastIrqPendingMask,
		lastIrqAckValue = debug.lastIrqAckValue,
	}
end

return CDROM
