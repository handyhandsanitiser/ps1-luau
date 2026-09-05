-- cd-rom model used by the differential checks.  it keeps the controller state self-contained while matching the emulator's public fields and timing model.  the batch order matters: command responses, drive events, commands, then asynchronous interrupts.

local CDROMRef = {}
CDROMRef.__index = CDROMRef

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local lshift = bit32.lshift
local rshift = bit32.rshift
local bxor = bit32.bxor


local MASTER_CLOCK = 33868800
local SINGLE_SPEED_TICKS = math.floor(MASTER_CLOCK / 75)
local DOUBLE_SPEED_TICKS = math.floor(MASTER_CLOCK / 150)
local FRAMES_PER_MINUTE = 4500
local SUBQ_SECTOR_SKEW = 2
local PARAM_FIFO_SIZE = 16
local NUM_SECTOR_BUFFERS = 8
local MODE1_HEADER_SIZE = 4
local MODE2_HEADER_SIZE = 12
local RAW_SECTOR_OUTPUT_SIZE = 2340
local DATA_SECTOR_OUTPUT_SIZE = 2048
local LEAD_OUT_TRACK_NUMBER = 0xAA

local INIT_TICKS = 4000000
local ID_READ_TICKS = 33868
local MOTOR_ON_RESPONSE_TICKS = 400000
local CDDA_REPORT_START_DELAY = 60
local MINIMUM_INTERRUPT_DELAY = 1000
local INTERRUPT_DELAY_CYCLES = 500
local MIN_SEEK_TICKS = 30000

local INTERRUPT_REGISTER_MASK = 0x1F
local PRNG_SEED = 0x4B435544 -- "DUCK"

local INT_DATA_READY = 0x01
local INT_COMPLETE = 0x02
local INT_ACK = 0x03
local INT_DATA_END = 0x04
local INT_ERROR = 0x05

local STAT_ERROR = 0x01
local STAT_MOTOR_ON = 0x02
local STAT_SEEK_ERROR = 0x04
local STAT_ID_ERROR = 0x08
local STAT_SHELL_OPEN = 0x10
local STAT_READING = 0x20
local STAT_SEEKING = 0x40
local STAT_PLAYING_CDDA = 0x80

local ERROR_REASON_SHELL_OPEN = 0x08
local ERROR_REASON_INVALID_ARGUMENT = 0x10
local ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS = 0x20
local ERROR_REASON_INVALID_COMMAND = 0x40
local ERROR_REASON_NOT_READY = 0x80

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

-- name, min params, max params
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
local VALID_COMMAND_COUNT = #COMMAND_INFO

local MECHACON_VERSION_TABLE = {
	{ 0x94, 0x09, 0x19, 0xC0 },
	{ 0x94, 0x11, 0x18, 0xC0 },
	{ 0x95, 0x05, 0x16, 0xC1 },
	{ 0x95, 0x07, 0x24, 0xC1 },
	{ 0x95, 0x07, 0x24, 0xD1 },
	{ 0x96, 0x08, 0x15, 0xC2 },
	{ 0x96, 0x08, 0x18, 0xC1 },
	{ 0x96, 0x09, 0x12, 0xC2 },
	{ 0x97, 0x01, 0x10, 0xC2 },
	{ 0x97, 0x08, 0x14, 0xC2 },
	{ 0x98, 0x06, 0x10, 0xC3 },
	{ 0x99, 0x02, 0x01, 0xC3 },
	{ 0xA1, 0x03, 0x06, 0xC3 },
}


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

local function mul32x32(x, y)
	local x0 = rshift(x, 16)
	local x1 = band(x, 0xFFFF)
	local y0 = rshift(y, 16)
	local y1 = band(y, 0xFFFF)
	local p11 = x1 * y1
	local mid = x0 * y1 + x1 * y0
	local lo = band(p11 + lshift(mid, 16), 0xFFFFFFFF)
	local hi = band(x0 * y0 + rshift(mid, 16) + rshift(p11, 32), 0xFFFFFFFF)
	return { hi = hi, lo = lo }
end

local function u64mul(a, b)
	local aloBlo = mul32x32(a.lo, b.lo)
	local aloBhi = mul32x32(a.lo, b.hi)
	local ahiBlo = mul32x32(a.hi, b.lo)
	local lo = aloBlo.lo
	local hi = band(aloBlo.hi + aloBhi.lo + ahiBlo.lo, 0xFFFFFFFF)
	return { hi = hi, lo = lo }
end

local function u64shl(a, k)
	return { hi = band(lshift(a.hi, k) + rshift(a.lo, 32 - k), 0xFFFFFFFF), lo = band(lshift(a.lo, k), 0xFFFFFFFF) }
end

local function u64shr(a, k)
	return { hi = rshift(a.hi, k), lo = bor(rshift(a.lo, k), lshift(band(a.hi, lshift(1, k) - 1), 32 - k)) }
end

local function u64rotl(a, k)
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

local function u64mod(a, n)
	local hiMod = a.hi % n
	local loMod = a.lo % n
	local p = (2 ^ 32) % n
	return ((hiMod * p) % n + loMod) % n
end

local function splitmix64(x)
	local z = u64add(x, { hi = 0x9E3779B9, lo = 0x7F4A7C15 })
	z = u64mul(u64xor(z, u64shr(z, 30)), { hi = 0xBF58476D, lo = 0x1CE4E5B9 })
	z = u64mul(u64xor(z, u64shr(z, 27)), { hi = 0x94D049BB, lo = 0x133111EB })
	return u64xor(z, u64shr(z, 31))
end

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

function PRNG:nextRange(n)
	return u64mod(self:next(), n)
end

function PRNG:nextRangeLowHigh(low, high)
	return low + self:nextRange(high - low)
end


local function bcdToInt(value)
	value = band(value, 0xFF)
	return (rshift(value, 4) * 10) + band(value, 0xF)
end

local function intToBcd(value)
	value = math.max(0, math.floor(value or 0))
	-- decimal-to-bcd: low nibble is the low decimal digit (duckstation binarytobcd: 12 -> 0x12, 99 -> 0x99); band(value, 0xf) is wrong when the low decimal digit != low hex nibble.
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


function CDROMRef.new(options)
	options = options or {}
	local self = setmetatable({}, CDROMRef)
	self.index = 0
	self.status = 0
	self.mode = 0
	self.requestRegister = 0
	self.irqEnable = INTERRUPT_REGISTER_MASK
	self.irqFlags = 0
	self.pendingInterrupt = nil
	self.asyncDeliveryRemaining = nil
	self.paramFifo = {}
	self.responseFifo = {}
	self.asyncResponseFifo = {}
	self.sectorBuffers = {}
	for _ = 1, NUM_SECTOR_BUFFERS do
		table.insert(self.sectorBuffers, { data = {}, position = 0, size = 0 })
	end
	self.currentReadBuffer = 0
	self.currentWriteBuffer = 0
	self.command = nil
	self.commandEventRemaining = nil
	self.commandEventInterval = nil
	self.commandSecondResponse = nil
	self.commandSecondResponseRemaining = nil
	self.driveState = DRIVE_IDLE
	self.driveEventRemaining = nil
	self.driveEventInterval = 0
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
	self.totalCycles = 0
	self.lastInterruptTime = 0
	self.prng = PRNG.new(PRNG_SEED)
	self.disc = nil
	self.interruptCallback = nil
	self.licenseRegion = options.licenseRegion or "SCEI"
	self.mechaconVersion = options.mechaconVersion or 2
	self.cycleScale = 1
	self.sectorsDelivered = 0
	self:resetState()
	return self
end


function CDROMRef:hasDisc()
	return self.disc ~= nil
end

function CDROMRef:readSector(lba)
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

function CDROMRef:getDiscLbaCount()
	if self.disc and type(self.disc.getLbaCount) == "function" then
		return self.disc.getLbaCount() or 0
	end
	return 0
end

function CDROMRef:getTrackCount()
	if self.disc and type(self.disc.getTrackCount) == "function" then
		return self.disc.getTrackCount() or 1
	end
	return 1
end

function CDROMRef:getFirstTrackNumber()
	if self.disc and type(self.disc.getFirstTrackNumber) == "function" then
		return self.disc.getFirstTrackNumber() or 1
	end
	return 1
end

function CDROMRef:getLastTrackNumber()
	if self.disc and type(self.disc.getLastTrackNumber) == "function" then
		return self.disc.getLastTrackNumber() or 1
	end
	return 1
end

function CDROMRef:getTrackStartPosition(track)
	if self.disc and type(self.disc.getTrackStartPosition) == "function" then
		return self.disc.getTrackStartPosition(track)
	end
	return 0
end

function CDROMRef:getTrackMode(track)
	if self.disc and type(self.disc.getTrackMode) == "function" then
		return self.disc.getTrackMode(track)
	end
	return "data"
end

function CDROMRef:isMediaAudioCd()
	if not self.disc then
		return false
	end
	return self:getTrackMode(1) == "audio"
end

function CDROMRef:getTrackNumberAtLba(lba)
	if self.disc and type(self.disc.getTrackNumber) == "function" then
		return self.disc.getTrackNumber(lba)
	end
	return 1
end

function CDROMRef:getSubqForLba(lba)
	if self.disc and type(self.disc.getSubq) == "function" then
		local s = self.disc.getSubq(lba)
		if s then
			return s
		end
	end
	local bcdM, bcdS, bcdF = lbaToMsfBcd(lba)
	return {
		control = 0x04,
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


function CDROMRef:canReadMedia()
	return self.driveState ~= DRIVE_SHELL_OPENING and self.disc ~= nil
end

function CDROMRef:isSeeking()
	return self.driveState == DRIVE_SEEKING_LOGICAL or self.driveState == DRIVE_SEEKING_PHYSICAL
		or self.driveState == DRIVE_SEEKING_IMPLICIT
end

function CDROMRef:isReading()
	return self.driveState == DRIVE_READING
end

function CDROMRef:isReadingOrPlaying()
	return self.driveState == DRIVE_READING or self.driveState == DRIVE_PLAYING
end

function CDROMRef:hasPendingCommand()
	return self.command ~= nil
end

function CDROMRef:isMotorOn()
	return band(self.status, STAT_MOTOR_ON) ~= 0
end

function CDROMRef:modeCdda() return band(self.mode, 0x01) ~= 0 end
function CDROMRef:modeAutoPause() return band(self.mode, 0x02) ~= 0 end
function CDROMRef:modeReportAudio() return band(self.mode, 0x04) ~= 0 end
function CDROMRef:modeXaFilter() return band(self.mode, 0x08) ~= 0 end
function CDROMRef:modeIgnoreBit() return band(self.mode, 0x10) ~= 0 end
function CDROMRef:modeReadRawSector() return band(self.mode, 0x20) ~= 0 end
function CDROMRef:modeXaEnable() return band(self.mode, 0x40) ~= 0 end
function CDROMRef:modeDoubleSpeed() return band(self.mode, 0x80) ~= 0 end

function CDROMRef:clearActiveBits()
	self.status = band(self.status, bnot(bor(STAT_SEEKING, STAT_READING, STAT_PLAYING_CDDA)))
end

function CDROMRef:setSeeking()
	self.status = band(self.status, bnot(bor(STAT_READING, STAT_PLAYING_CDDA)))
	self.status = bor(self.status, bor(STAT_MOTOR_ON, STAT_SEEKING))
end

function CDROMRef:setReadingBits(audio)
	self.status = band(self.status, bnot(bor(STAT_SEEKING, STAT_READING, STAT_PLAYING_CDDA)))
	if audio then
		self.status = bor(self.status, bor(STAT_MOTOR_ON, STAT_PLAYING_CDDA))
	else
		self.status = bor(self.status, bor(STAT_MOTOR_ON, STAT_READING))
	end
end

function CDROMRef:getStatusPortValue()
	local value = band(self.index, 0x3)
	if #self.paramFifo == 0 then
		value = bor(value, 0x08)
	end
	if #self.paramFifo < PARAM_FIFO_SIZE then
		value = bor(value, 0x10)
	end
	if #self.responseFifo > 0 then
		value = bor(value, 0x20)
	end
	if band(self.requestRegister, 0x80) ~= 0 then
		value = bor(value, 0x40)
	end
	if self.command ~= nil then
		value = bor(value, 0x80)
	end
	return value
end


function CDROMRef:updateInterruptRequest()
	if self.interruptCallback and band(self.irqFlags, self.irqEnable) ~= 0 then
		self.interruptCallback()
	end
end

function CDROMRef:setInterrupt(reason)
	self.irqFlags = band(reason, 0x1F)
	self:updateInterruptRequest()
end

function CDROMRef:setAsyncInterrupt(reason)
	reason = band(reason, 0x1F)
	if self.irqFlags == reason then
		self.asyncResponseFifo = {}
		return
	end
	if self.pendingInterrupt ~= nil then
		return
	end
	self.pendingInterrupt = reason
	if self.irqFlags == 0 then
		if not self:hasPendingCommand() then
			self:queueDeliverAsyncInterrupt()
		end
	end
end

function CDROMRef:clearAsyncInterrupt()
	self.pendingInterrupt = nil
	self.asyncDeliveryRemaining = nil
	self.asyncResponseFifo = {}
end

function CDROMRef:queueDeliverAsyncInterrupt()
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

function CDROMRef:deliverAsyncInterrupt()
	if self.pendingInterrupt == nil then
		return
	end
	if self.irqFlags ~= 0 then
		self.asyncDeliveryRemaining = INTERRUPT_DELAY_CYCLES
		return
	end
	local reason = self.pendingInterrupt
	self.pendingInterrupt = nil
	self.asyncDeliveryRemaining = nil
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
	self:updateInterruptRequest()
	self:updateCommandEvent()
end

function CDROMRef:sendAckAndStat()
	table.insert(self.responseFifo, band(self.status, 0xFF))
	self:setInterrupt(INT_ACK)
end

function CDROMRef:sendErrorResponse(statBits, reason)
	table.insert(self.responseFifo, band(bor(self.status, statBits), 0xFF))
	table.insert(self.responseFifo, band(reason, 0xFF))
	self:setInterrupt(INT_ERROR)
end

function CDROMRef:sendAsyncErrorResponse(statBits, reason)
	table.insert(self.asyncResponseFifo, band(bor(self.status, statBits), 0xFF))
	table.insert(self.asyncResponseFifo, band(reason, 0xFF))
	self:setAsyncInterrupt(INT_ERROR)
end


function CDROMRef:getAckDelayForCommand(command)
	if command == 0x0A then
		return 80000
	end
	if self:canReadMedia() then
		return 25000
	end
	return 15000
end

function CDROMRef:beginCommand(command)
	command = band(command, 0xFF)
	local ackDelay = self:getAckDelayForCommand(command)
	if self.command ~= nil then
		local oldInfo = COMMAND_INFO[self.command + 1]
		local newInfo = COMMAND_INFO[command + 1]
		if oldInfo and newInfo and oldInfo[2] > newInfo[2] then
			self.paramFifo = {}
			return
		end
		if self.commandEventRemaining ~= nil then
			local elapsed = math.max(0, (self.commandEventInterval or 0) - self.commandEventRemaining)
			ackDelay = math.max(ackDelay - elapsed, 1)
			self.commandEventRemaining = nil
			if self.pendingInterrupt ~= nil then
				self:queueDeliverAsyncInterrupt()
			end
		end
	end
	self.command = command
	self.commandEventRemaining = ackDelay
	self.commandEventInterval = ackDelay
	self:updateCommandEvent()
end

function CDROMRef:endCommand()
	self.paramFifo = {}
	self.command = nil
	self.commandEventRemaining = nil
	self.commandEventInterval = nil
end

function CDROMRef:updateCommandEvent()
	if self.command == nil or self.irqFlags ~= 0 or self.pendingInterrupt ~= nil then
		return
	end
	if self.commandEventRemaining == nil then
		self.commandEventRemaining = self:getAckDelayForCommand(self.command)
		self.commandEventInterval = self.commandEventRemaining
	end
end


function CDROMRef:getTicksForSpinUp()
	return MASTER_CLOCK
end

function CDROMRef:getTicksForRead()
	if self:modeDoubleSpeed() then
		return DOUBLE_SPEED_TICKS
	end
	return SINGLE_SPEED_TICKS
end

function CDROMRef:getTicksForTocRead()
	if not self.disc then
		return 0
	end
	return math.floor(MASTER_CLOCK / 2)
end

function CDROMRef:getTicksForIdRead()
	local ticks = ID_READ_TICKS
	if self.driveState == DRIVE_SPINNING_UP then
		ticks += self.driveEventRemaining or 0
	end
	return ticks
end

function CDROMRef:getTicksForStop(motorWasOn)
	if motorWasOn then
		return self:modeDoubleSpeed() and 25000000 or 13000000
	end
	return 7000
end

function CDROMRef:getTicksForSpeedChange()
	if self:modeDoubleSpeed() then
		return math.floor(0.6 * MASTER_CLOCK)
	end
	return math.floor(0.7 * MASTER_CLOCK)
end

function CDROMRef:getTicksForPause()
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

function CDROMRef:getSectorsPerTrack(lba)
	local mm = math.floor(lba / FRAMES_PER_MINUTE)
	return SPT_TABLE[math.min(mm, #SPT_TABLE - 1)]
end

function CDROMRef:getTicksForSeek(newLba, ignoreSpeedChange)
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
		ticks += ticksPerSector * math.max(lbaDiff, 2)
	elseif currentLba >= newLba and tjumpPosition <= newLba then
		ticks += ticksPerSector * math.max(newLba - tjumpPosition, 1)
	elseif lbaDiff < 7200 then
		local clamped = math.max(1, math.min(currentLba / FRAMES_PER_MINUTE, 72))
		local switchPoint = math.floor(330.0 + (-63.1333 * math.log(clamped)))
		local seconds = (lbaDiff < switchPoint) and 0.05 or 0.1
		ticks += math.floor(seconds * MASTER_CLOCK)
	else
		local SLED_FIXED_COST = 0.05
		local SLED_VARIABLE_COST = 0.9 - SLED_FIXED_COST
		local LOG_WEIGHT = 0.4
		local MAX_SLED_LBA = 72 * FRAMES_PER_MINUTE
		local seconds = SLED_FIXED_COST
			+ ((SLED_VARIABLE_COST * (math.log(lbaDiff) / math.log(MAX_SLED_LBA))) * LOG_WEIGHT)
			+ ((SLED_VARIABLE_COST * (lbaDiff / MAX_SLED_LBA)) * (1.0 - LOG_WEIGHT))
		ticks += math.floor(seconds * MASTER_CLOCK)
	end

	ticks += self.prng:nextRangeLowHigh(math.floor(MASTER_CLOCK / 2000), math.floor(MASTER_CLOCK / 1000))

	if self.driveState == DRIVE_CHANGING_SPEED_OR_TOC and not ignoreSpeedChange then
		ticks += self.driveEventRemaining or 0
	end

	return ticks
end


function CDROMRef:clearDriveState()
	self.driveState = DRIVE_IDLE
	self.driveEventRemaining = nil
end

function CDROMRef:setHoldPosition(lba, subqLba)
	self.lastSubqNeedsUpdate = self.lastSubqNeedsUpdate or (self.currentSubqLba ~= subqLba)
	self.currentLba = lba
	self.currentSubqLba = subqLba
	self.subqLbaUpdateTick = self.totalCycles
	self.subqLbaUpdateCarry = 0
end

function CDROMRef:updateSubQPositionWhileSeeking()
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

function CDROMRef:updateSubQPosition(updateLogical)
	if self:isSeeking() or self:isReadingOrPlaying() or not self:isMotorOn() then
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

function CDROMRef:ensureLastSubqValid()
	if not self.lastSubqNeedsUpdate then
		return
	end
	self.lastSubqNeedsUpdate = false
	local subq = self:getSubqForLba(self.currentSubqLba)
	if subq and subq.crcValid then
		self.lastSubq = subq
	end
end

function CDROMRef:beginSeeking(logical, readAfterSeek, playAfterSeek)
	self.readAfterSeek = readAfterSeek
	self.playAfterSeek = playAfterSeek
	self.setlocPending = false

	local seekLba = self.setlocLba
	local seekTime
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
end

function CDROMRef:completeSeek()
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
							self.currentSubqLba = (self.currentLba >= SUBQ_SECTOR_SKEW) and (self.currentLba - SUBQ_SECTOR_SKEW) or 0
							self.lastSubqNeedsUpdate = true
						end
					end
				else
					if logical and self.readAfterSeek then
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

function CDROMRef:doSeekComplete()
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
end

function CDROMRef:beginReading(afterSeek)
	if not afterSeek and self.setlocPending then
		self:beginSeeking(true, true, false)
		return
	end

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
end

function CDROMRef:beginPlaying(track, afterSeek)
	self.playTrackNumberBcd = track
	self.fastForwardRate = 0

	if track ~= 0 then
		local trackCount = self:getTrackCount()
		if track > trackCount then
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
end

function CDROMRef:startMotor()
	if self.driveState == DRIVE_SPINNING_UP then
		return
	end
	self.driveState = DRIVE_SPINNING_UP
	self.driveEventInterval = self:getTicksForSpinUp()
	self.driveEventRemaining = self.driveEventInterval
end

function CDROMRef:stopMotor()
	self:clearActiveBits()
	self.status = band(self.status, bnot(STAT_MOTOR_ON))
	self:clearDriveState()
	self:setHoldPosition(0, 0)
	self.lastSectorHeaderValid = false
end


function CDROMRef:processDataSectorHeader(sector)
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

function CDROMRef:clearSectorBuffers()
	self.currentReadBuffer = 0
	self.currentWriteBuffer = 0
	for _, sb in ipairs(self.sectorBuffers) do
		sb.position = 0
		sb.size = 0
		sb.data = {}
	end
	self.requestRegister = band(self.requestRegister, bnot(0x80))
end

function CDROMRef:resetAudioDecoder()
	self.cddaAutoPausePending = false
	self.xaCurrentFile = 0
	self.xaCurrentChannel = 0
	self.xaCurrentSet = false
end

function CDROMRef:processDataSector(sector)
	if self:modeXaEnable() and self.lastSectorHeader.mode == 2 then
		local submode = self.lastSectorSubheader[3]
		if band(submode, 0x40) ~= 0 and band(submode, 0x04) ~= 0 then
			self:processXaAdpcmSector(sector)
			return
		end
	end

	local sbNum = (self.currentWriteBuffer + 1) % NUM_SECTOR_BUFFERS
	local sb = self.sectorBuffers[sbNum + 1]
	sb.data = {}
	if self:modeReadRawSector() then
		if self.lastSectorHeader.mode == 1 then
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

	if self.pendingInterrupt ~= nil then
		self:clearAsyncInterrupt()
	end

	table.insert(self.asyncResponseFifo, band(self.status, 0xFF))
	self:setAsyncInterrupt(INT_DATA_READY)
end

function CDROMRef:processXaAdpcmSector(sector)
end

function CDROMRef:getPeakVolume(sector)
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

function CDROMRef:processCddaSector(sector, subq)
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
end

function CDROMRef:doSectorRead()
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

	-- duckstation always advances the request to the next sector after a
	-- read (dosectorread: requested_lba = next_sector; queuereadsector(...))
	self.requestedLba = nextSector
end

function CDROMRef:stopReadingWithDataEnd()
	self:clearAsyncInterrupt()
	table.insert(self.asyncResponseFifo, band(self.status, 0xFF))
	self:setAsyncInterrupt(INT_DATA_END)
	self:clearActiveBits()
	self:clearDriveState()
end

function CDROMRef:stopReadingWithError(reason)
	self:clearAsyncInterrupt()
	self:sendAsyncErrorResponse(STAT_ERROR, reason)
	self:clearActiveBits()
	self:clearDriveState()
end


function CDROMRef:doDriveEvent()
	local state = self.driveState
	if state == DRIVE_SEEKING_PHYSICAL or state == DRIVE_SEEKING_LOGICAL then
		self:doSeekComplete()
	elseif state == DRIVE_SEEKING_IMPLICIT then
		self:completeSeek()
	elseif state == DRIVE_READING or state == DRIVE_PLAYING then
		self:doSectorRead()
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

function CDROMRef:doChangeSessionComplete()
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

function CDROMRef:doStatSecondResponse()
	if not self:canReadMedia() then
		self:sendAsyncErrorResponse(STAT_ERROR, 0x08)
		return
	end
	self.asyncResponseFifo = {}
	table.insert(self.asyncResponseFifo, band(self.status, 0xFF))
	self:setAsyncInterrupt(INT_COMPLETE)
end

function CDROMRef:doIdRead()
	self:clearActiveBits()
	if self:canReadMedia() then
		self.status = bor(self.status, STAT_MOTOR_ON)
	end

	local statByte = band(self.status, 0xFF)
	local flagsByte = 0
	if not self:canReadMedia() then
		statByte = bor(statByte, STAT_ID_ERROR)
		flagsByte = bor(flagsByte, 0x40)
	elseif self:isMediaAudioCd() then
		statByte = bor(statByte, STAT_ID_ERROR)
		flagsByte = bor(flagsByte, 0x90)
	elseif self.disc and self.disc.discRegion == "NonPS1" then
		statByte = bor(statByte, STAT_ID_ERROR)
		flagsByte = bor(flagsByte, 0x80)
	end

	self.asyncResponseFifo = {}
	table.insert(self.asyncResponseFifo, band(statByte, 0xFF))
	table.insert(self.asyncResponseFifo, band(flagsByte, 0xFF))
	table.insert(self.asyncResponseFifo, 0x20)
	table.insert(self.asyncResponseFifo, 0x00)
	local region = self.licenseRegion or "SCEI"
	for i = 1, 4 do
		table.insert(self.asyncResponseFifo, string.byte(region, i) or 0x53)
	end
	self:setAsyncInterrupt(flagsByte ~= 0 and INT_ERROR or INT_COMPLETE)
end


function CDROMRef:clearCommandSecondResponse()
	self.commandSecondResponse = nil
	self.commandSecondResponseRemaining = nil
end

function CDROMRef:queueCommandSecondResponse(command, ticks)
	self:clearCommandSecondResponse()
	self.commandSecondResponse = command
	self.commandSecondResponseRemaining = math.max(1, ticks or 1)
end

function CDROMRef:executeCommandSecondResponse()
	local cmd = self.commandSecondResponse
	if cmd == 0x1A then
		self:doIdRead()
	elseif cmd == 0x0A then
		if self:hasPendingCommand() then
			self:endCommand()
		end
		self:doStatSecondResponse()
	elseif cmd == 0x1E or cmd == 0x09 or cmd == 0x07 then
		self:doStatSecondResponse()
	elseif cmd == 0x08 then
		self:doStatSecondResponse()
	end
	self:clearCommandSecondResponse()
end


function CDROMRef:pushResponse(bytes)
	for _, value in ipairs(bytes) do
		table.insert(self.responseFifo, band(value, 0xFF))
	end
end

function CDROMRef:getNextSectorToBeRead()
	if not (self:isReadingOrPlaying() or self:isSeeking()) then
		return self.currentLba
	end
	return self.lastReadSector
end

function CDROMRef:isRegionMismatched()
	return false
end

function CDROMRef:executeCommand(command)
	command = band(command, 0xFF)

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

	self.responseFifo = {}

	local function peek(i)
		return self.paramFifo[i] or 0
	end

	if command == 0x01 then
		-- getstat
		self:sendAckAndStat()
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
		-- forward / backward
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
		return
	end

	if command == 0x0A then
		-- init
		if self.commandSecondResponse == 0x0A then
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
		-- getmode
		self:pushResponse({ band(self.status, 0xFF), self.mode, 0, self.xaFilterFile, self.xaFilterChannel })
		self:setInterrupt(INT_ACK)
		self:endCommand()
		return
	end

	if command == 0x10 then
		-- getlocl
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
		-- getlocp
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
		-- gettn
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
		-- gettd
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
					local lm, ls = lbaToMsf(self:getDiscLbaCount())
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
			local version = MECHACON_VERSION_TABLE[math.max(1, math.min((self.mechaconVersion or 0) + 1, #MECHACON_VERSION_TABLE))]
			self:pushResponse(copyArray(version or { 0x95, 0x05, 0x16, 0xC1 }))
			self:setInterrupt(INT_ACK)
			self:endCommand()
		elseif sub == 0x22 then
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
		-- getid
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
		-- reset
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
		-- videocd: invalid; does not clear the parameter fifo.
		self:sendErrorResponse(STAT_ERROR, ERROR_REASON_INVALID_COMMAND)
		self.command = nil
		self.commandEventRemaining = nil
		self.commandEventInterval = nil
		return
	end

	self:sendErrorResponse(STAT_ERROR, ERROR_REASON_INVALID_COMMAND)
	self:endCommand()
end


function CDROMRef:softReset()
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
	self.mode = bor(self.mode, 0x20)
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
	return totalTicks
end

function CDROMRef:resetState()
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
	self.mode = bor(self.mode, 0x20)
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
	self:setHoldPosition(0, 0)
end

function CDROMRef:mount(disc)
	self.disc = disc
	self.totalCycles = 0
	self.lastInterruptTime = 0
	self.sectorsDelivered = 0
	self.lastReadSector = 0
	self:resetState()
end


function CDROMRef:read(address)
	address = band(address, 0xFFFFFFFF)
	local offset = address - 0x1F801800
	if offset == 0 then
		return self:getStatusPortValue()
	elseif offset == 1 then
		if #self.responseFifo == 0 then
			return 0
		end
		return table.remove(self.responseFifo, 1)
	elseif offset == 2 then
		return self:popDataByte()
	elseif offset == 3 then
		if band(self.index, 1) ~= 0 then
			return bor(band(self.irqFlags, 0xFF), bnot(INTERRUPT_REGISTER_MASK))
		end
		return bor(band(self.irqEnable, 0xFF), bnot(INTERRUPT_REGISTER_MASK))
	end
	return 0
end

function CDROMRef:write(address, value)
	address = band(address, 0xFFFFFFFF)
	value = band(value, 0xFF)
	local offset = address - 0x1F801800
	if offset == 0 then
		self.index = band(value, 0x3)
		return
	end

	if offset == 1 or offset == 2 or offset == 3 then
		local reg = (self.index * 3) + (offset - 1)
		if reg == 0 then
			self:beginCommand(value)
		elseif reg == 1 then
			if #self.paramFifo >= PARAM_FIFO_SIZE then
				table.remove(self.paramFifo, 1)
			end
			table.insert(self.paramFifo, value)
		elseif reg == 2 then
			self.requestRegister = value
			if band(value, 0x80) == 0 then
				self.sectorBuffers[self.currentReadBuffer + 1].position = 0
			end
		elseif reg == 3 then
			-- sound map data out: no-op
		elseif reg == 4 then
			self.irqEnable = band(value, INTERRUPT_REGISTER_MASK)
			self:updateInterruptRequest()
		elseif reg == 5 then
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
			if band(value, 0x40) ~= 0 then
				self.paramFifo = {}
			end
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
			self.adpcmMuted = band(value, 0x01) ~= 0
			if band(value, 0x20) ~= 0 then
				self.cdAudioVolumeMatrix = {
					{ self.nextCdAudioVolumeMatrix[1][1], self.nextCdAudioVolumeMatrix[1][2] },
					{ self.nextCdAudioVolumeMatrix[2][1], self.nextCdAudioVolumeMatrix[2][2] },
				}
			end
		end
	end
end


function CDROMRef:checkForSectorBufferReadComplete()
	local sb = self.sectorBuffers[self.currentReadBuffer + 1]

	self.requestRegister = band(self.requestRegister, 0x7F)
	if sb.position < sb.size then
		self.requestRegister = bor(self.requestRegister, 0x80)
	end

	if sb.position >= sb.size then
		sb.position = 0
		sb.size = 0
	end

	local nextSb = self.sectorBuffers[self.currentWriteBuffer + 1]
	if nextSb.position == 0 and nextSb.size > 0 and self.pendingInterrupt == nil and self:isReading() then
		local delay = math.min(self.driveEventRemaining or 5000, 5000)
		table.insert(self.asyncResponseFifo, band(self.status, 0xFF))
		self.pendingInterrupt = INT_DATA_READY
		self.asyncDeliveryRemaining = math.max(1, delay)
	end
end

function CDROMRef:popDataByte()
	if band(self.requestRegister, 0x80) == 0 then
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

function CDROMRef:popDataWord()
	local b0 = self:popDataByte()
	local b1 = self:popDataByte()
	local b2 = self:popDataByte()
	local b3 = self:popDataByte()
	return bor(b0, lshift(b1, 8), lshift(b2, 16), lshift(b3, 24))
end


function CDROMRef:step(cycles)
	if cycles <= 0 then
		return
	end
	self.totalCycles = band(self.totalCycles + cycles, 0xFFFFFFFF)

	if self.commandSecondResponseRemaining ~= nil then
		self.commandSecondResponseRemaining -= cycles
		if self.commandSecondResponseRemaining <= 0 then
			self:executeCommandSecondResponse()
		end
	end

	if self.driveEventRemaining ~= nil then
		self.driveEventRemaining -= cycles
		if self.driveEventRemaining <= 0 then
			self.driveEventRemaining = nil
			self:doDriveEvent()
		end
	end

	if self.commandEventRemaining ~= nil and self.irqFlags == 0 and self.pendingInterrupt == nil then
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
	end

	if self.asyncDeliveryRemaining ~= nil then
		self.asyncDeliveryRemaining -= cycles
		if self.asyncDeliveryRemaining <= 0 then
			self.asyncDeliveryRemaining = nil
			self:deliverAsyncInterrupt()
		end
	end
end

return CDROMRef
