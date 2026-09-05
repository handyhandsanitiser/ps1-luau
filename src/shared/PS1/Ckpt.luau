-- versioned emulator snapshots.  the disc reader and host callbacks are deliberately not serialized; mount the disc before loading.

local Ckpt = {}

local band = bit32.band
local bor = bit32.bor
local rshift = bit32.rshift
local lshift = bit32.lshift

local function signed16(v)
	v = band(v, 0xFFFF)
	return v >= 0x8000 and v - 0x10000 or v
end

local MAGIC = "PS1CKPT1"
local VERSION = 15

-- sio0 memory-card transaction states (string enum in memory.luau,
-- card_state_*); stable index order for serialization.
local CARD_STATES = {
	"idle", "command",
	"read_id1", "read_id2", "read_addr_msb", "read_addr_lsb", "read_ack1", "read_ack2",
	"read_conf_msb", "read_conf_lsb", "read_data", "read_chk", "read_end",
	"write_id1", "write_id2", "write_addr_msb", "write_addr_lsb", "write_data", "write_chk",
	"write_ack1", "write_ack2", "write_end",
	"getid_id1", "getid_id2", "getid_ack1", "getid_ack2", "getid_1", "getid_2", "getid_3", "getid_4",
}


local Writer = {}
Writer.__index = Writer

function Writer.new()
	return setmetatable({ parts = {}, n = 0 }, Writer)
end

function Writer:u8(v)
	self.parts[#self.parts + 1] = string.char(band(v, 0xFF))
	self.n += 1
end

function Writer:u16(v)
	self.parts[#self.parts + 1] = string.char(band(v, 0xFF), band(rshift(v, 8), 0xFF))
	self.n += 2
end

function Writer:u32(v)
	self.parts[#self.parts + 1] = string.char(
		band(v, 0xFF),
		band(rshift(v, 8), 0xFF),
		band(rshift(v, 16), 0xFF),
		band(rshift(v, 24), 0xFF)
	)
	self.n += 4
end

-- serialize a byte array (values 0..255) in 512-byte chunks; pass `capacity` explicitly for arrays with nil holes (# is unreliable on sparse tables).
function Writer:bytes(array, capacity)
	array = array or {}
	local n = capacity ~= nil and capacity or #array
	self:u32(n)
	for i = 1, n, 512 do
		local last = math.min(i + 511, n)
		local chunk = {}
		for j = i, last do
			chunk[#chunk + 1] = array[j] or 0
		end
		self.parts[#self.parts + 1] = string.char(table.unpack(chunk))
	end
end

-- serialize a 16-bit array (values 0..0xffff) little-endian; pass `capacity` explicitly for sparse tables (e.g. lazily-filled spu ram).
function Writer:words16(array, capacity)
	local n = capacity or #array
	self:u32(n)
	local parts = self.parts
	for i = 1, n do
		local v = array[i] or 0
		parts[#parts + 1] = string.char(band(v, 0xFF), band(rshift(v, 8), 0xFF))
	end
end

-- sparse u32->u32 map (e.g. spu.reg): count + (addr, value) pairs.
function Writer:sparseMap(map)
	local keys = {}
	for k in pairs(map) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	self:u32(#keys)
	for _, k in ipairs(keys) do
		self:u32(k)
		self:u32(map[k] or 0)
	end
end

function Writer:str(s)
	s = s or ""
	self:u32(#s)
	self.parts[#self.parts + 1] = s
end

function Writer:finish()
	return table.concat(self.parts)
end


local Reader = {}
Reader.__index = Reader

function Reader.new(data)
	return setmetatable({ data = data, pos = 1 }, Reader)
end

function Reader:u8()
	local v = self.data:byte(self.pos) or 0
	self.pos += 1
	return v
end

function Reader:u16()
	local a = self.data:byte(self.pos) or 0
	local b = self.data:byte(self.pos + 1) or 0
	self.pos += 2
	return bor(a, lshift(b, 8))
end

function Reader:u32()
	local a = self.data:byte(self.pos) or 0
	local b = self.data:byte(self.pos + 1) or 0
	local c = self.data:byte(self.pos + 2) or 0
	local d = self.data:byte(self.pos + 3) or 0
	self.pos += 4
	return bor(a, lshift(b, 8), lshift(c, 16), lshift(d, 24))
end

function Reader:bytes(dest, capacity)
	local n = self:u32()
	local cap = capacity or n
	for i = 1, cap do
		dest[i] = i <= n and (self.data:byte(self.pos + i - 1) or 0) or 0
	end
	self.pos += n
	return n
end

function Reader:words16(dest, capacity)
	local n = self:u32()
	local cap = capacity or n
	for i = 1, cap do
		if i <= n then
			local a = self.data:byte(self.pos) or 0
			local b = self.data:byte(self.pos + 1) or 0
			dest[i] = bor(a, lshift(b, 8))
			self.pos += 2
		else
			dest[i] = 0
		end
	end
	return n
end

function Reader:sparseMap(dest)
	local n = self:u32()
	for _ = 1, n do
		local k = self:u32()
		dest[k] = self:u32()
	end
	return n
end

function Reader:str()
	local n = self:u32()
	local s = self.data:sub(self.pos, self.pos + n - 1)
	self.pos += n
	return s
end


local function saveCpu(w, runtime)
	local cpu = runtime.cpu
	local gte = cpu.gte
	w:u32(cpu.pc or 0)
	w:u32(cpu.nextPc or 0)
	for i = 0, 31 do
		w:u32(cpu:getRegister(i))
	end
	w:u32(cpu.cop0.status or 0)
	w:u32(cpu.cop0.cause or 0)
	w:u32(cpu.cop0.epc or 0)
	w:u32(cpu.cop0.badvaddr or 0)
	w:u32(cpu.cop0.prid or 0)
	w:u32(cpu.hi or 0)
	w:u32(cpu.lo or 0)
	w:u8(cpu.inDelaySlot and 1 or 0)
	w:u8(cpu.halted and 1 or 0)
	-- pendingbranch { target, delay, sourcepc } or nil
	if cpu.pendingBranch then
		w:u8(1)
		w:u32(cpu.pendingBranch.target or 0)
		w:u8(cpu.pendingBranch.delay or 0)
		w:u32(cpu.pendingBranch.sourcePc or 0)
	else
		w:u8(0)
	end
	-- pendingload { register, value, delay } or nil
	if cpu.pendingLoad then
		w:u8(1)
		w:u32(cpu.pendingLoad.register or 0)
		w:u32(cpu.pendingLoad.value or 0)
		w:u8(cpu.pendingLoad.delay or 0)
	else
		w:u8(0)
	end
	-- gte
	for i = 0, 31 do
		w:u32(gte.dr[i] or 0)
	end
	for i = 0, 31 do
		w:u32(gte.cr[i] or 0)
	end
	for i = 0, 3 do
		w:u32(gte.mac[i] or 0)
	end
end

local function saveMemory(w, memory)
	w:u32(memory.iStat or 0)
	w:u32(memory.iMask or 0)
	w:u32(memory.iLineState or 0)
	w:u32(memory.cycleCount or 0)
	w:u32(memory.flux or 0)
	w:bytes(memory.ram)
	w:bytes(memory.scratchpad)
	-- joypad
	local joypad = memory.joypad
	w:u16(joypad.buttons or 0)
	w:u16(joypad.mode or 0)
	w:u16(joypad.ctrl or 0)
	w:u16(joypad.baud or 0)
	w:u16(joypad.rxData or 0)
	w:u8(joypad.padSelected and 1 or 0)
	w:u16(joypad.padTxCount or 0)
	w:u8(joypad.txReady and 1 or 0)
	w:u8(joypad.rxReady and 1 or 0)
	w:u8(joypad.lastTxByte and 1 or 0)
	if joypad.lastTxByte then
		w:u16(joypad.lastTxByte)
	end
	if joypad.padReply then
		w:u8(1)
		w:bytes(joypad.padReply)
	else
		w:u8(0)
	end
	-- v2: config-mode pad state
	w:u8(joypad.padConfigMode and 1 or 0)
	w:u8(joypad.padAnalogMode and 1 or 0)
	-- v3: in-flight command bytes (a mid-transaction checkpoint must restore the exact buffer or the pad machine sees padtxcount > 0 with a nil buffer).
	if joypad.padCmdBuf then
		w:u8(#joypad.padCmdBuf)
		w:bytes(joypad.padCmdBuf)
	else
		w:u8(0)
	end
	-- v9: 4dh get/set rumble config (older files default to all 0xff =
	-- unmapped, matching createjoypadstate's initial value).
	local rc = joypad.padRumbleConfig
	if rc then
		w:u8(1)
		w:u8(rc[1] or 0xFF)
		w:u8(rc[2] or 0xFF)
		w:u8(rc[3] or 0xFF)
		w:u8(rc[4] or 0xFF)
		w:u8(rc[5] or 0xFF)
		w:u8(rc[6] or 0xFF)
	else
		w:u8(0)
	end
	-- v9: sio0 memory-card transaction state + ack/irq lines (a mid-card-transfer checkpoint must restore these or the driver loses the reply stream).
	w:u8(joypad.cardSelected and 1 or 0)
	-- cardstate is a string enum in memory.luau ("idle", "command", ...);
	-- serialize it as a stable numeric index.
	local cardStateIndex = 0
	for i, st in ipairs(CARD_STATES) do
		if st == joypad.cardState then
			cardStateIndex = i
			break
		end
	end
	w:u8(cardStateIndex)
	w:u16(joypad.cardAddress or 0)
	w:u16(joypad.cardSectorOffset or 0)
	w:u8(joypad.cardChecksum or 0)
	w:u8(joypad.cardLastIn or 0)
	w:u8(joypad.ackAsserted and 1 or 0)
	if joypad.ackAsserted then
		w:u32(joypad.ackCycle or 0)
	end
	w:u8(joypad.irqFlag and 1 or 0)
	w:u8(joypad.pendingPadIrqCycle and 1 or 0)
	if joypad.pendingPadIrqCycle then
		w:u32(joypad.pendingPadIrqCycle)
	end
	-- v14: duckstation no_write_yet flag bit (0x08 until first write data
	-- byte, then 0x00) + active-device routing state (0=none,1=pad,2=card).
	w:u8(joypad.cardNoWriteYet and 1 or 0)
	local activeDeviceIndex = joypad.activeDevice == "card" and 2 or (joypad.activeDevice == "pad" and 1 or 0)
	w:u8(activeDeviceIndex)
end

local function saveGpu(w, gpu)
	w:words16(gpu.vram, 1024 * 512)
	w:u32(gpu.status or 0)
	w:u32(gpu.frameCycleCounter or 0)
	w:u32(gpu.cyclesPerFrame or 0)
	w:u32(gpu.dmaDirection or 0)
	w:u32(gpu.gpuread or 0)
	w:u16(gpu.displayStartX or 0)
	w:u16(gpu.displayStartY or 0)
	w:u16(gpu.displayWidth or 0)
	w:u16(gpu.displayHeight or 0)
	w:u8(gpu.displayDisabled and 1 or 0)
	w:u8(gpu.interlaced and 1 or 0)
	w:u16(gpu.drawLeft or 0)
	w:u16(gpu.drawTop or 0)
	w:u16(gpu.drawRight or 0)
	w:u16(gpu.drawBottom or 0)
	w:u16(gpu.drawOffX or 0)
	w:u16(gpu.drawOffY or 0)
	w:u16(gpu.tpX or 0)
	w:u16(gpu.tpY or 0)
	w:u8(gpu.tpMode or 0)
	w:u16(gpu.rawTP or 0)
	w:u16(gpu.clutX or 0)
	w:u16(gpu.clutY or 0)
	w:u16(gpu.texWindowMaskX or 0)
	w:u16(gpu.texWindowMaskY or 0)
	w:u16(gpu.texWindowOffX or 0)
	w:u16(gpu.texWindowOffY or 0)
	w:u8(gpu.dither and 1 or 0)
	w:u8(gpu.drawToDisplay and 1 or 0)
	w:u8(gpu.texDisable and 1 or 0)
	w:u8(gpu.maskSet and 1 or 0)
	w:u8(gpu.maskCheck and 1 or 0)
	w:u8(gpu.semiTrans or 0)
	-- duckstation draw-state registers (v4)
	w:u16(gpu.drawModeReg or 0)
	w:u16(gpu.texturePaletteReg or 0)
	w:u8(gpu.setTextureDisableMask and 1 or 0)
	w:u8(gpu.textureEnableMask and 1 or 0)
	-- gp0 state machine
	w:u8(#gpu.gp0buf)
	for _, word in ipairs(gpu.gp0buf) do
		w:u32(word)
	end
	w:u32(gpu.gp0needed or 0)
	w:str(gpu.gp0mode or "cmd")
	w:u16(gpu.cvX or 0)
	w:u16(gpu.cvY or 0)
	w:u16(gpu.cvW or 0)
	w:u16(gpu.cvH or 0)
	w:u16(gpu.cvPX or 0)
	w:u16(gpu.cvPY or 0)
	w:u8(gpu.cvHalf and 1 or 0)
	if gpu.cvHalf then
		w:u16(gpu.cvHalf)
	end
	w:u16(gpu.vcX or 0)
	w:u16(gpu.vcY or 0)
	w:u16(gpu.vcW or 0)
	w:u16(gpu.vcH or 0)
	w:u16(gpu.vcPX or 0)
	w:u16(gpu.vcPY or 0)
end

-- v6: full duckstation cd-rom state (command/drive event countdowns, sector
-- double-buffers, sub-q, audio routing, prng).  replaces the v5 legacy fields.
local function saveCdrom(w, cd)
	-- registers
	w:u8(cd.index or 0)
	w:u8(cd.status or 0)
	w:u8(cd.mode or 0)
	w:u8(cd.irqEnable or 0)
	w:u8(cd.irqFlags or 0)
	w:u8(cd.requestRegister or 0)
	-- command queue
	if cd.command then
		w:u8(1)
		w:u8(cd.command)
	else
		w:u8(0)
	end
	if cd.commandEventRemaining then
		w:u8(1)
		w:u32(cd.commandEventRemaining)
	else
		w:u8(0)
	end
	if cd.commandSecondResponse then
		w:u8(1)
		w:u8(cd.commandSecondResponse)
	else
		w:u8(0)
	end
	if cd.commandSecondResponseRemaining then
		w:u8(1)
		w:u32(cd.commandSecondResponseRemaining)
	else
		w:u8(0)
	end
	-- drive state machine
	w:u8(cd.driveState or 0)
	if cd.driveEventRemaining then
		w:u8(1)
		w:u32(cd.driveEventRemaining)
	else
		w:u8(0)
	end
	w:u32(cd.driveEventInterval or 0)
	-- position / subq
	local sl = cd.setlocPosition or {}
	w:u8(sl.minute or 0)
	w:u8(sl.second or 0)
	w:u8(sl.frame or 0)
	w:u32(cd.setlocLba or 0)
	w:u8(cd.setlocPending and 1 or 0)
	w:u8(cd.readAfterSeek and 1 or 0)
	w:u8(cd.playAfterSeek and 1 or 0)
	w:u32(cd.requestedLba or 0)
	w:u32(cd.currentLba or 0)
	w:u32(cd.currentSubqLba or 0)
	w:u32(cd.lastReadSector or 0)
	w:u32(cd.seekStartLba or 0)
	w:u32(cd.seekEndLba or 0)
	w:u32(cd.subqLbaUpdateTick or 0)
	w:u32(cd.subqLbaUpdateCarry or 0)
	w:u8(cd.lastSubqNeedsUpdate and 1 or 0)
	local q = cd.lastSubq or {}
	w:u8(q.track or 0)
	w:u8(q.index or 0)
	w:u8(q.relM or 0)
	w:u8(q.relS or 0)
	w:u8(q.relF or 0)
	w:u8(q.absM or 0)
	w:u8(q.absS or 0)
	w:u8(q.absF or 0)
	w:u8(q.crcValid and 1 or 0)
	w:u8(q.isData and 1 or 0)
	local h = cd.lastSectorHeader or {}
	w:u8(h.minute or 0)
	w:u8(h.second or 0)
	w:u8(h.frame or 0)
	w:u8(h.mode or 0)
	w:u8(cd.lastSectorHeaderValid and 1 or 0)
	for i = 1, 8 do
		w:u8((cd.lastSectorSubheader or {})[i] or 0)
	end
	-- cd audio routing state
	w:u8(cd.muted and 1 or 0)
	w:u8(cd.adpcmMuted and 1 or 0)
	w:u8(cd.xaFilterFile or 0)
	w:u8(cd.xaFilterChannel or 0)
	w:u8(cd.xaCurrentFile or 0)
	w:u8(cd.xaCurrentChannel or 0)
	w:u8(cd.xaCurrentSet and 1 or 0)
	w:u8(cd.cddaAutoPausePending and 1 or 0)
	w:u8(cd.cddaReportStartDelay or 0)
	w:u8(cd.lastCddaReportFrameNibble or 0)
	w:u8(cd.playTrackNumberBcd or 0)
	w:u8(band(cd.fastForwardRate or 0, 0xFF)) -- signed -12..12
	w:u8(cd.asyncCommandParameter or 0)
	local cm = cd.cdAudioVolumeMatrix or { { 0, 0 }, { 0, 0 } }
	local nm = cd.nextCdAudioVolumeMatrix or { { 0, 0 }, { 0, 0 } }
	w:u8(cm[1][1] or 0)
	w:u8(cm[1][2] or 0)
	w:u8(cm[2][2] or 0)
	w:u8(cm[2][1] or 0)
	w:u8(nm[1][1] or 0)
	w:u8(nm[1][2] or 0)
	w:u8(nm[2][2] or 0)
	w:u8(nm[2][1] or 0)
	w:u32(cd.lastSectorReadTicks or 0)
	-- xa-adpcm decoder + audio fifo state (v13)
	w:u8(cd.xaCurrentCodinginfo or 0)
	w:u8(cd.xaResampleP or 0)
	w:u8(cd.xaResampleSixstep or 0)
	local xal = cd.xaLastSamples or { 0, 0, 0, 0 }
	for i = 1, 4 do w:u32(band(xal[i] or 0, 0xFFFFFFFF)) end
	local ring = cd.xaResampleRingBuffer or {}
	for ch = 1, 2 do
		for i = 1, 32 do
			w:u16(band((ring[ch] or {})[i] or 0, 0xFFFF))
		end
	end
	local fifo = cd.audioFifo or { count = 0 }
	w:u32(band(fifo.count or 0, 0xFFFFFFFF))
	for i = 0, (fifo.count or 0) - 1 do
		w:u32(band((fifo.data or {})[fifo.head + i] or 0, 0xFFFFFFFF))
	end
	-- timing
	w:u32(cd.totalCycles or 0)
	w:u32(cd.lastInterruptTime or 0)
	-- async interrupt queue
	if cd.pendingInterrupt then
		w:u8(1)
		w:u8(cd.pendingInterrupt)
	else
		w:u8(0)
	end
	if cd.asyncDeliveryRemaining then
		w:u8(1)
		w:u32(cd.asyncDeliveryRemaining)
	else
		w:u8(0)
	end
	-- fifos (byte arrays)
	w:bytes(cd.paramFifo)
	w:bytes(cd.responseFifo)
	w:bytes(cd.asyncResponseFifo)
	-- sector double-buffers (8 x data+pos+size)
	w:u8(cd.currentReadBuffer or 0)
	w:u8(cd.currentWriteBuffer or 0)
	for i = 1, 8 do
		local sb = (cd.sectorBuffers or {})[i] or { data = {}, position = 0, size = 0 }
		w:bytes(sb.data, sb.size or 0)
		w:u32(sb.position or 0)
		w:u32(sb.size or 0)
	end
	w:u32(cd.sectorsDelivered or 0)
	-- seek-jitter prng (xoroshiro128++ state)
	local p = cd.prng or {}
	w:u32((p.s0 and p.s0.hi) or 0)
	w:u32((p.s0 and p.s0.lo) or 0)
	w:u32((p.s1 and p.s1.hi) or 0)
	w:u32((p.s1 and p.s1.lo) or 0)
end

local function saveSpuEnvelope(w, env)
	w:u32(env.counter or 0)
	w:u32(env.counterIncrement or 0)
	w:u16(env.step or 0)
	w:u8(env.rate or 0)
	w:u8(env.decreasing and 1 or 0)
	w:u8(env.exponential and 1 or 0)
	w:u8(env.phaseInvert and 1 or 0)
end

local function saveSpuSweep(w, sweep)
	w:u16(sweep.level or 0)
	w:u8(sweep.active and 1 or 0)
	saveSpuEnvelope(w, sweep.env or {})
end

local function saveSpu(w, spu)
	w:sparseMap(spu.reg)
	w:words16(spu.ram, 0x40000)
	w:u16(spu.transferAddressReg or 0)
	w:u32(spu.transferAddress or 0)
	w:u16(spu.irqAddressReg or 0)
	w:u16(spu.spustat or 0)
	if spu.pendingFifoLo then w:u8(1); w:u16(spu.pendingFifoLo) else w:u8(0) end
	-- v10: complete synthesizer state. register/ram state alone is not enough
	-- to resume an in-flight adpcm block, envelope, or reverb delay line.
	w:u16(spu.spucnt or 0)
	w:u16(spu.transferControl or 0)
	w:u32(spu.keyOn or 0); w:u32(spu.keyOff or 0); w:u32(spu.endx or 0)
	w:u32(spu.pmon or 0); w:u32(spu.non or 0); w:u32(spu.eon or 0)
	w:u32(spu.noiseCount or 0); w:u32(spu.noiseLevel or 0)
	w:u16(spu.reverbBase or 0); w:u32(spu.reverbCurrent or 0); w:u8(spu.reverbPos or 0)
	w:u16(spu.reverbOutLeft or 0); w:u16(spu.reverbOutRight or 0)
	for i = 1, 32 do w:u16((spu.reverb or {})[i] or 0) end
	for channel = 1, 2 do for i = 1, 128 do w:u16(spu.reverbDown[channel][i] or 0) end end
	for channel = 1, 2 do for i = 1, 64 do w:u16(spu.reverbUp[channel][i] or 0) end end
	w:u16(spu.mainLeft.level or 0); w:u16(spu.mainRight.level or 0)
	saveSpuSweep(w, spu.mainLeft); saveSpuSweep(w, spu.mainRight)
	w:u32(spu.pendingCycles or 0); w:u32(spu.sampleCount or 0); w:u32(spu.lastMemoryCycle or 0)
	-- v11: capture-buffer position (advances every frame; affects future ram writes
	-- and the spustat second-half bit).
	w:u16(spu.capturePos or 0)
	-- v12: cd/external input volume registers (cached fields, not in the
	-- sparse reg map; they gate the cd mix on every frame).
	w:u16(spu.cdLeft or 0); w:u16(spu.cdRight or 0)
	w:u16(spu.extLeft or 0); w:u16(spu.extRight or 0)
	-- v15: dma transfer fifo (halfwords in order) + drain/fill accumulator.
	w:u8(spu.transferFifoCount or 0)
	for i = 1, 32 do w:u16((spu.transferFifo or {})[i] or 0) end
	w:u32(spu.transferAccum or 0)
	for i = 1, 24 do
		local v = spu.voices[i]
		for j = 1, 8 do w:u16(v.regs[j] or 0) end
		w:u16(v.currentAddress or 0); w:u32(v.counter or 0); w:u8(v.flags or 0)
		w:u8(v.firstBlock and 1 or 0); w:u8(v.hasSamples and 1 or 0); w:u8(v.ignoreLoopAddress and 1 or 0)
		for j = 1, 31 do w:u16(v.samples[j] or 0) end
		w:u16(v.lastSamples[1] or 0); w:u16(v.lastSamples[2] or 0); w:u16(v.lastVolume or 0)
		saveSpuSweep(w, v.left); saveSpuSweep(w, v.right)
		w:u16(v.adsr.level or 0); w:u8(v.adsr.phase or 0); w:u16(v.adsr.target or 0)
		saveSpuEnvelope(w, v.adsr.env or {})
	end
end

local function saveTimers(w, timers)
	-- v7: duckstation timer state (gate, counting flags, irq_done, sysclk/8
	-- carry) plus the crtc clock-generator state.
	for i = 1, 3 do
		local t = timers.timers[i]
		w:u16(t.counter or 0)
		w:u16(t.mode or 0)
		w:u16(t.target or 0)
		w:u8(t.gate and 1 or 0)
		w:u8(t.useExternalClock and 1 or 0)
		w:u8(t.externalCountingEnabled and 1 or 0)
		w:u8(t.countingEnabled and 1 or 0)
		w:u8(t.irqDone and 1 or 0)
	end
	w:u32(timers.sysclkDiv8Carry or 0)
	w:u32(timers.crtcTick or 0)
	w:u32(timers.currentScanline or 0)
	w:u8(timers.inHblank and 1 or 0)
	w:u8(timers.inVblank and 1 or 0)
	w:u32(timers.fractionalTicks or 0)
	w:u32(timers.dotClockDivider or 10)
	w:u32(timers.dotTickCarry or 0)
	w:u32(timers.vblankTick or 0)
	w:u32(band(timers.totalCycles or 0, 0xFFFFFFFF))
	w:u32(rshift(timers.totalCycles or 0, 32))
	w:u32(band(timers.nextVBlankCycle or 0, 0xFFFFFFFF))
	w:u32(rshift(timers.nextVBlankCycle or 0, 32))
end

local function saveDma(w, dma)
	w:u32(dma.dpcr or 0)
	w:u32(dma.dicr or 0)
	for i = 1, 7 do
		local ch = dma.channels[i]
		w:u32(ch.madr or 0)
		w:u32(ch.bcr or 0)
		w:u32(ch.chcr or 0)
	end
end


local function loadCpu(r, runtime)
	local cpu = runtime.cpu
	cpu.pc = r:u32()
	cpu.nextPc = r:u32()
	for i = 0, 31 do
		cpu:setRegister(i, r:u32())
	end
	cpu.cop0.status = r:u32()
	cpu.cop0.cause = r:u32()
	cpu.cop0.epc = r:u32()
	cpu.cop0.badvaddr = r:u32()
	cpu.cop0.prid = r:u32()
	cpu.hi = r:u32()
	cpu.lo = r:u32()
	cpu.inDelaySlot = r:u8() == 1
	cpu.halted = r:u8() == 1
	if r:u8() == 1 then
		cpu.pendingBranch = { target = r:u32(), delay = r:u8(), sourcePc = r:u32() }
	else
		cpu.pendingBranch = nil
	end
	if r:u8() == 1 then
		cpu.pendingLoad = { register = r:u32(), value = r:u32(), delay = r:u8() }
	else
		cpu.pendingLoad = nil
	end
	local gte = cpu.gte
	for i = 0, 31 do
		gte.dr[i] = r:u32()
	end
	for i = 0, 31 do
		gte.cr[i] = r:u32()
	end
	for i = 0, 3 do
		gte.mac[i] = r:u32()
	end
end

local function loadMemory(r, memory, loadVersion)
	memory.iStat = r:u32()
	memory.iMask = r:u32()
	local _p = band(memory.iStat, memory.iMask)
	memory._irqState = (_p ~= 0 or band(memory.cop0.cause, 0x0000FF00) ~= 0) and bor(_p, 0x80000000) or 0
	-- v8: device line state (pre-v8 files resume with all lines low; devices
	-- re-assert on their next events, which self-corrects the edge latch).
	if loadVersion >= 8 then
		memory.iLineState = r:u32()
	else
		memory.iLineState = 0
	end
	memory.cycleCount = r:u32()
	memory.flux = r:u32()
	r:bytes(memory.ram)
	-- rebuild the u32 instruction-fetch mirror (ram bytes were restored directly)
	local ram32 = memory.ram32
	if ram32 then
		local ram = memory.ram
		for i = 1, #ram32 do
			local p = (i - 1) * 4 + 1
			ram32[i] = bor(ram[p], lshift(ram[p + 1], 8), lshift(ram[p + 2], 16), lshift(ram[p + 3], 24))
		end
	end
	r:bytes(memory.scratchpad)
	local joypad = memory.joypad
	joypad.buttons = r:u16()
	joypad.mode = r:u16()
	joypad.ctrl = r:u16()
	joypad.baud = r:u16()
	joypad.rxData = r:u16()
	joypad.padSelected = r:u8() == 1
	joypad.padTxCount = r:u16()
	joypad.txReady = r:u8() == 1
	joypad.rxReady = r:u8() == 1
	if r:u8() == 1 then
		joypad.lastTxByte = r:u16()
	else
		joypad.lastTxByte = nil
	end
	if r:u8() == 1 then
		joypad.padReply = {}
		r:bytes(joypad.padReply)
	else
		joypad.padReply = nil
	end
	-- v2: config-mode pad state (v1 files default to off)
	if loadVersion >= 2 then
		joypad.padConfigMode = r:u8() == 1
		joypad.padAnalogMode = r:u8() == 1
	else
		joypad.padConfigMode = false
		joypad.padAnalogMode = false
	end
	-- v3: in-flight command bytes (older files default to nil -> treated as
	-- a fresh transaction by the pad state machine).
	if loadVersion >= 3 then
		local n = r:u8()
		if n > 0 then
			joypad.padCmdBuf = {}
			r:bytes(joypad.padCmdBuf)
		else
			joypad.padCmdBuf = nil
		end
	else
		joypad.padCmdBuf = nil
	end
	-- v9: 4dh get/set rumble config (older files default to all 0xff).
	if loadVersion >= 9 then
		if r:u8() == 1 then
			joypad.padRumbleConfig = { r:u8(), r:u8(), r:u8(), r:u8(), r:u8(), r:u8() }
		else
			joypad.padRumbleConfig = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }
		end
	else
		joypad.padRumbleConfig = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }
	end
	-- v9: sio0 memory-card transaction state + ack/irq line state.
	if loadVersion >= 9 then
		joypad.cardSelected = r:u8() == 1
		joypad.cardState = CARD_STATES[r:u8()] or "idle"
		joypad.cardAddress = r:u16()
		joypad.cardSectorOffset = r:u16()
		joypad.cardChecksum = r:u8()
		joypad.cardLastIn = r:u8()
		joypad.ackAsserted = r:u8() == 1
		if joypad.ackAsserted then
			joypad.ackCycle = r:u32()
		else
			joypad.ackCycle = 0
		end
		joypad.irqFlag = r:u8() == 1
		if r:u8() == 1 then
			joypad.pendingPadIrqCycle = r:u32()
		else
			joypad.pendingPadIrqCycle = nil
		end
		joypad._needsStep = joypad.ackAsserted or joypad.pendingPadIrqCycle ~= nil
		if (loadVersion or 0) >= 14 then
			joypad.cardNoWriteYet = r:u8() == 1
			local adi = r:u8()
			joypad.activeDevice = adi == 2 and "card" or (adi == 1 and "pad" or "none")
		else
			joypad.cardNoWriteYet = true
			-- derive from the v9-era selected flags
			joypad.activeDevice = joypad.cardSelected and "card" or (joypad.padSelected and "pad" or "none")
		end
	else
		joypad.cardSelected = false
		joypad.cardState = 0
		joypad.cardAddress = 0
		joypad.cardSectorOffset = 0
		joypad.cardChecksum = 0
		joypad.cardLastIn = 0
		joypad.ackAsserted = false
		joypad.ackCycle = 0
		joypad.irqFlag = false
		joypad.pendingPadIrqCycle = nil
		joypad.cardNoWriteYet = true
		joypad.activeDevice = "none"
	end
	joypad._needsStep = joypad.ackAsserted or joypad.pendingPadIrqCycle ~= nil
end

local function loadGpu(r, gpu, version)
	r:words16(gpu.vram, 1024 * 512)
	gpu.status = r:u32()
	gpu.frameCycleCounter = r:u32()
	gpu.cyclesPerFrame = r:u32()
	gpu.dmaDirection = r:u32()
	gpu.gpuread = r:u32()
	gpu.displayStartX = r:u16()
	gpu.displayStartY = r:u16()
	gpu.displayWidth = r:u16()
	gpu.displayHeight = r:u16()
	gpu.displayDisabled = r:u8() == 1
	gpu.interlaced = r:u8() == 1
	gpu.drawLeft = r:u16()
	gpu.drawTop = r:u16()
	gpu.drawRight = r:u16()
	gpu.drawBottom = r:u16()
	gpu.drawOffX = r:u16()
	gpu.drawOffY = r:u16()
	gpu.tpX = r:u16()
	gpu.tpY = r:u16()
	gpu.tpMode = r:u8()
	gpu.rawTP = r:u16()
	gpu.clutX = r:u16()
	gpu.clutY = r:u16()
	gpu.texWindowMaskX = r:u16()
	gpu.texWindowMaskY = r:u16()
	gpu.texWindowOffX = r:u16()
	gpu.texWindowOffY = r:u16()
	gpu.dither = r:u8() == 1
	gpu.drawToDisplay = r:u8() == 1
	gpu.texDisable = r:u8() == 1
	gpu.maskSet = r:u8() == 1
	gpu.maskCheck = r:u8() == 1
	gpu.semiTrans = r:u8()
	if version >= 4 then
		gpu.drawModeReg = r:u16()
		gpu.texturePaletteReg = r:u16()
		gpu.setTextureDisableMask = r:u8() == 1
		gpu.textureEnableMask = r:u8() == 1
	else
		-- v3 and older: reconstruct the duckstation registers from the legacy
		-- fields (mirror of the differential harness's seed logic).
		local dm = 0
		dm = bor(dm, math.floor((gpu.tpX or 0) / 64))
		dm = bor(dm, lshift(math.floor((gpu.tpY or 0) / 256), 4))
		dm = bor(dm, lshift(gpu.semiTrans or 0, 5))
		dm = bor(dm, lshift(gpu.tpMode or 0, 7))
		dm = bor(dm, lshift(gpu.dither and 1 or 0, 9))
		dm = bor(dm, lshift(gpu.drawToDisplay and 1 or 0, 10))
		dm = bor(dm, lshift(gpu.texDisable and 1 or 0, 11))
		gpu.drawModeReg = dm
		gpu.texturePaletteReg = bor(band(math.floor((gpu.clutX or 0) / 16), 0x3F), lshift(band(gpu.clutY or 0, 0x1FF), 6))
		gpu.setTextureDisableMask = false
		gpu.textureEnableMask = true
	end
	-- the clut cache always reloads from the restored vram on the next textured
	-- draw (the cache itself is not serialized).
	gpu.currentClutRegBits = nil
	gpu.currentClutIs8bit = false
	gpu.gp0buf = {}
	local gp0count = r:u8()
	for _ = 1, gp0count do
		gpu.gp0buf[#gpu.gp0buf + 1] = r:u32()
	end
	gpu.gp0needed = r:u32()
	gpu.gp0mode = r:str()
	gpu.cvX = r:u16()
	gpu.cvY = r:u16()
	gpu.cvW = r:u16()
	gpu.cvH = r:u16()
	gpu.cvPX = r:u16()
	gpu.cvPY = r:u16()
	if r:u8() == 1 then
		gpu.cvHalf = r:u16()
	else
		gpu.cvHalf = nil
	end
	gpu.vcX = r:u16()
	gpu.vcY = r:u16()
	gpu.vcW = r:u16()
	gpu.vcH = r:u16()
	gpu.vcPX = r:u16()
	gpu.vcPY = r:u16()

	-- a cpu<->vram transfer in progress can't be resumed: its remaining words were already consumed by the game, so drop the stale transfer and return the gpu to command mode.
	if gpu.gp0mode == "cpuToVram" or gpu.gp0mode == "vramToCpu" then
		gpu.gp0mode = "cmd"
		gpu.gp0buf = {}
		gpu.gp0needed = 0
		gpu.gp0handler = nil
	end
	-- the gpustat cache is not serialized: force a recompute on the next poll after restore.
	gpu._statusCache = nil
end

-- v6 loader: full duckstation cd-rom state.
local function loadCdrom(r, cd, version)
	if (version or 0) >= 6 then
		cd.index = r:u8()
		cd.status = r:u8()
		cd.mode = r:u8()
		cd.irqEnable = r:u8()
		cd.irqFlags = r:u8()
		cd.requestRegister = r:u8()
		if r:u8() == 1 then
			cd.command = r:u8()
		else
			cd.command = nil
		end
		if r:u8() == 1 then
			cd.commandEventRemaining = r:u32()
		else
			cd.commandEventRemaining = nil
		end
		if r:u8() == 1 then
			cd.commandSecondResponse = r:u8()
		else
			cd.commandSecondResponse = nil
		end
		if r:u8() == 1 then
			cd.commandSecondResponseRemaining = r:u32()
		else
			cd.commandSecondResponseRemaining = nil
		end
		cd.driveState = r:u8()
		if r:u8() == 1 then
			cd.driveEventRemaining = r:u32()
		else
			cd.driveEventRemaining = nil
		end
		cd.driveEventInterval = r:u32()
		cd.setlocPosition = { minute = r:u8(), second = r:u8(), frame = r:u8() }
		cd.setlocLba = r:u32()
		cd.setlocPending = r:u8() == 1
		cd.readAfterSeek = r:u8() == 1
		cd.playAfterSeek = r:u8() == 1
		cd.requestedLba = r:u32()
		cd.currentLba = r:u32()
		cd.currentSubqLba = r:u32()
		cd.lastReadSector = r:u32()
		cd.seekStartLba = r:u32()
		cd.seekEndLba = r:u32()
		cd.subqLbaUpdateTick = r:u32()
		cd.subqLbaUpdateCarry = r:u32()
		cd.lastSubqNeedsUpdate = r:u8() == 1
		cd.lastSubq = {
			track = r:u8(), index = r:u8(),
			relM = r:u8(), relS = r:u8(), relF = r:u8(),
			absM = r:u8(), absS = r:u8(), absF = r:u8(),
			crcValid = r:u8() == 1,
			isData = r:u8() == 1,
		}
		cd.lastSectorHeader = { minute = r:u8(), second = r:u8(), frame = r:u8(), mode = r:u8() }
		cd.lastSectorHeaderValid = r:u8() == 1
		cd.lastSectorSubheader = {}
		for i = 1, 8 do
			cd.lastSectorSubheader[i] = r:u8()
		end
		cd.muted = r:u8() == 1
		cd.adpcmMuted = r:u8() == 1
		cd.xaFilterFile = r:u8()
		cd.xaFilterChannel = r:u8()
		cd.xaCurrentFile = r:u8()
		cd.xaCurrentChannel = r:u8()
		cd.xaCurrentSet = r:u8() == 1
		cd.cddaAutoPausePending = r:u8() == 1
		cd.cddaReportStartDelay = r:u8()
		cd.lastCddaReportFrameNibble = r:u8()
		cd.playTrackNumberBcd = r:u8()
		local ffr = r:u8()
		if ffr >= 128 then
			ffr -= 256
		end
		cd.fastForwardRate = ffr
		cd.asyncCommandParameter = r:u8()
		cd.cdAudioVolumeMatrix = { { r:u8(), r:u8() }, { r:u8(), r:u8() } }
		cd.nextCdAudioVolumeMatrix = { { r:u8(), r:u8() }, { r:u8(), r:u8() } }
		cd.lastSectorReadTicks = r:u32()
		if (version or 0) >= 13 then
			cd.xaCurrentCodinginfo = r:u8()
			cd.xaResampleP = r:u8()
			cd.xaResampleSixstep = r:u8()
			cd.xaLastSamples = {}
			for i = 1, 4 do
				local v = r:u32()
				if v >= 0x80000000 then v -= 0x100000000 end
				cd.xaLastSamples[i] = v
			end
			cd.xaResampleRingBuffer = { {}, {} }
			for ch = 1, 2 do
				for i = 1, 32 do
					local v = r:u16()
					if v >= 0x8000 then v -= 0x10000 end
					cd.xaResampleRingBuffer[ch][i] = v
				end
			end
			local count = r:u32()
			cd.audioFifo = { data = {}, head = 1, count = count }
			for i = 0, count - 1 do
				cd.audioFifo.data[cd.audioFifo.head + i] = r:u32()
			end
		end
		cd.totalCycles = r:u32()
		cd.lastInterruptTime = r:u32()
		if r:u8() == 1 then
			cd.pendingInterrupt = r:u8()
		else
			cd.pendingInterrupt = nil
		end
		if r:u8() == 1 then
			cd.asyncDeliveryRemaining = r:u32()
		else
			cd.asyncDeliveryRemaining = nil
		end
		cd.paramFifo = {}
		r:bytes(cd.paramFifo)
		cd.responseFifo = {}
		r:bytes(cd.responseFifo)
		cd.asyncResponseFifo = {}
		r:bytes(cd.asyncResponseFifo)
		cd.currentReadBuffer = r:u8()
		cd.currentWriteBuffer = r:u8()
		for i = 1, 8 do
			local sb = cd.sectorBuffers[i] or { data = {}, position = 0, size = 0 }
			sb.data = {}
			r:bytes(sb.data, 2340)
			sb.position = r:u32()
			sb.size = r:u32()
			cd.sectorBuffers[i] = sb
		end
		cd.sectorsDelivered = r:u32()
		local p = cd.prng or {}
		p.s0 = { hi = r:u32(), lo = r:u32() }
		p.s1 = { hi = r:u32(), lo = r:u32() }
		cd.prng = p
		-- legacy-only fields are gone in v6
		cd.pendingCommandAck = nil
		cd.firstSectorTimer = nil
		cd.readStartLba = nil
		cd.readActive = nil
		cd.lastDrainedMadr = nil
		cd.readCycleAccumulator = nil
		cd.filterFile = nil
		cd.filterChannel = nil
		cd.audioMuted = nil
		cd.motorOn = nil
		cd.readWholeSector = nil
		cd.dataFifo = nil
		cd.delayedResponse = nil
		cd.locMinute = nil
		cd.locSecond = nil
		cd.locFrame = nil
		cd.targetLba = nil
		return
	end

	cd.index = r:u8()
	cd.status = r:u8()
	cd.mode = r:u8()
	cd.irqEnable = r:u8()
	cd.irqFlags = r:u8()
	local hadPending = r:u8() == 1
	cd.pendingInterrupt = r:u8()
	if not hadPending then
		cd.pendingInterrupt = nil
	end
	if r:u8() == 1 then
		cd.pendingCommandAck = r:u8()
	else
		cd.pendingCommandAck = nil
	end
	if r:u8() == 1 then
		cd.firstSectorTimer = r:u32()
	else
		cd.firstSectorTimer = nil
	end
	cd.locMinute = r:u8()
	cd.locSecond = r:u8()
	cd.locFrame = r:u8()
	cd.targetLba = r:u32()
	cd.currentLba = r:u32()
	if r:u8() == 1 then
		cd.readStartLba = r:u32()
	else
		cd.readStartLba = nil
	end
	cd.sectorsDelivered = r:u32()
	cd.readActive = r:u8() == 1
	if r:u8() == 1 then
		cd.lastDrainedMadr = r:u32()
	else
		cd.lastDrainedMadr = nil
	end
	cd.readCycleAccumulator = r:u32()
	cd.cycleScale = r:u32()
	cd.filterFile = r:u8()
	cd.filterChannel = r:u8()
	cd.audioMuted = r:u8() == 1
	cd.motorOn = r:u8() == 1
	cd.readWholeSector = r:u8() == 1
	cd.paramFifo = {}
	r:bytes(cd.paramFifo)
	cd.responseFifo = {}
	r:bytes(cd.responseFifo)
	cd.dataFifo = {}
	r:bytes(cd.dataFifo)
	if r:u8() == 1 then
		cd.delayedResponse = {
			reason = r:u8(),
			remaining = r:u32(),
			response = {},
		}
		r:bytes(cd.delayedResponse.response)
	else
		cd.delayedResponse = nil
	end
	cd.requestRegister = 0
	cd.dataPosition = 0
	cd.asyncResponseFifo = {}
	cd.asyncDeliveryRemaining = nil
	cd.lastInterruptTime = -1000
	if (version or 0) >= 5 then
		cd.requestRegister = r:u8()
		cd.dataPosition = r:u32()
		cd.asyncResponseFifo = {}
		r:bytes(cd.asyncResponseFifo)
		if r:u8() == 1 then
			cd.asyncDeliveryRemaining = r:u32()
		else
			cd.asyncDeliveryRemaining = nil
		end
		cd.lastInterruptTime = r:u32() - 1000
	else
		-- legacy checkpoints defaulted the cd interrupt enable to 0, but hardware resets it to 0x1f; correct the stale 0 so the first command ack can raise the irq.
		if cd.irqEnable == 0 then
			cd.irqEnable = 0x1F
		end
	end

	-- map the legacy state onto the duckstation state machine (lossy: countdowns/sector buffers can't be reconstructed, so the drive resumes idle).
	cd.command = nil
	cd.commandEventRemaining = nil
	cd.commandEventInterval = nil
	cd.commandSecondResponse = nil
	cd.commandSecondResponseRemaining = nil
	cd.driveState = cd.readActive and 5 or 0 -- DRIVE_READING or DRIVE_IDLE
	cd.driveEventRemaining = nil
	cd.driveEventInterval = 0
	cd.setlocPosition = { minute = cd.locMinute or 0, second = cd.locSecond or 0, frame = cd.locFrame or 0 }
	cd.setlocLba = cd.targetLba or 0
	cd.setlocPending = false
	cd.readAfterSeek = false
	cd.playAfterSeek = false
	cd.requestedLba = cd.readStartLba or cd.currentLba or 0
	cd.currentSubqLba = cd.currentLba or 0
	cd.lastReadSector = cd.readStartLba or cd.currentLba or 0
	cd.seekStartLba = 0
	cd.seekEndLba = 0
	cd.subqLbaUpdateTick = 0
	cd.subqLbaUpdateCarry = 0
	cd.lastSubqNeedsUpdate = false
	cd.lastSubq = { track = 0x01, index = 0x01, relM = 0, relS = 2, relF = 0, absM = 0, absS = 2, absF = 0, crcValid = true, isData = true }
	cd.lastSectorHeader = { minute = 0, second = 0, frame = 0, mode = 0 }
	cd.lastSectorSubheader = { 0, 0, 0, 0, 0, 0, 0, 0 }
	cd.lastSectorHeaderValid = false
	cd.muted = cd.audioMuted == true
	cd.adpcmMuted = false
	cd.xaFilterFile = cd.filterFile or 0
	cd.xaFilterChannel = cd.filterChannel or 0
	cd.xaCurrentFile = 0
	cd.xaCurrentChannel = 0
	cd.xaCurrentSet = false
	cd.cddaAutoPausePending = false
	cd.cddaReportStartDelay = 0
	cd.lastCddaReportFrameNibble = 0xFF
	cd.playTrackNumberBcd = 0xFF
	cd.fastForwardRate = 0
	cd.asyncCommandParameter = 0
	cd.cdAudioVolumeMatrix = { { 0x80, 0x00 }, { 0x00, 0x80 } }
	cd.nextCdAudioVolumeMatrix = { { 0x80, 0x00 }, { 0x00, 0x80 } }
	cd.lastSectorReadTicks = 0
	cd.currentReadBuffer = 0
	cd.currentWriteBuffer = 0
	for i = 1, 8 do
		local sb = cd.sectorBuffers[i]
		sb.data = {}
		sb.position = 0
		sb.size = 0
	end
	if #(cd.dataFifo or {}) > 0 then
		-- datafifo is a byte array of remaining bytes; put it in buffer 0.
		local sb = cd.sectorBuffers[1]
		sb.data = cd.dataFifo
		sb.size = #cd.dataFifo
		sb.position = cd.dataPosition or 0
	end
	cd.dataFifo = nil
	cd.delayedResponse = nil
	cd.pendingCommandAck = nil
	cd.firstSectorTimer = nil
	cd.readStartLba = nil
	cd.readActive = nil
	cd.lastDrainedMadr = nil
	cd.readCycleAccumulator = nil
	cd.filterFile = nil
	cd.filterChannel = nil
	cd.audioMuted = nil
	cd.motorOn = nil
	cd.readWholeSector = nil
	cd.locMinute = nil
	cd.locSecond = nil
	cd.locFrame = nil
	cd.targetLba = nil
end

local function loadSpuEnvelope(r, env)
	env.counter = r:u32(); env.counterIncrement = r:u32(); env.step = signed16(r:u16())
	env.rate = r:u8(); env.decreasing = r:u8() == 1; env.exponential = r:u8() == 1; env.phaseInvert = r:u8() == 1
end

local function loadSpuSweep(r, sweep)
	sweep.level = signed16(r:u16()); sweep.active = r:u8() == 1; loadSpuEnvelope(r, sweep.env)
end

local function loadSpu(r, spu, version)
	spu.reg = {}
	r:sparseMap(spu.reg)
	r:words16(spu.ram, 0x40000)
	spu.transferAddressReg = r:u16(); spu.transferAddress = r:u32(); spu.irqAddressReg = r:u16(); spu.spustat = r:u16()
	if r:u8() == 1 then spu.pendingFifoLo = r:u16() else spu.pendingFifoLo = nil end
	if (version or 0) < 10 then
		spu.spucnt = spu.reg[0x1F801DAA] or 0
		spu.transferControl = spu.reg[0x1F801DAC] or 0
		spu.mainLeft.level = 0; spu.mainRight.level = 0
		return
	end
	spu.spucnt = r:u16(); spu.transferControl = r:u16()
	spu.keyOn = r:u32(); spu.keyOff = r:u32(); spu.endx = r:u32()
	spu.pmon = r:u32(); spu.non = r:u32(); spu.eon = r:u32()
	spu.noiseCount = r:u32(); spu.noiseLevel = r:u32()
	spu.reverbBase = r:u16(); spu.reverbCurrent = r:u32(); spu.reverbPos = r:u8()
	spu.reverbOutLeft = signed16(r:u16()); spu.reverbOutRight = signed16(r:u16())
	for i = 1, 32 do spu.reverb[i] = r:u16() end
	for channel = 1, 2 do for i = 1, 128 do spu.reverbDown[channel][i] = signed16(r:u16()) end end
	for channel = 1, 2 do for i = 1, 64 do spu.reverbUp[channel][i] = signed16(r:u16()) end end
	spu.mainLeft.level = signed16(r:u16()); spu.mainRight.level = signed16(r:u16())
	loadSpuSweep(r, spu.mainLeft); loadSpuSweep(r, spu.mainRight)
	spu.pendingCycles = r:u32(); spu.sampleCount = r:u32(); spu.lastMemoryCycle = r:u32()
	if (version or 0) >= 11 then
		spu.capturePos = r:u16()
	else
		spu.capturePos = 0
	end
	if (version or 0) >= 12 then
		spu.cdLeft = signed16(r:u16()); spu.cdRight = signed16(r:u16())
		spu.extLeft = signed16(r:u16()); spu.extRight = signed16(r:u16())
	else
		spu.cdLeft, spu.cdRight = 0, 0
		spu.extLeft, spu.extRight = 0, 0
	end
	if (version or 0) >= 15 then
		local count = r:u8()
		spu.transferFifo = {}
		for i = 1, 32 do
			local v = r:u16()
			if i <= count then spu.transferFifo[i] = v end
		end
		spu.transferFifoCount = count
		spu.transferAccum = r:u32()
	else
		spu.transferFifo = {}
		spu.transferFifoCount = 0
		spu.transferAccum = 0
	end
	if not spu.cdAudioFrame then spu.cdAudioFrame = { 0, 0 } end
	for i = 1, 24 do
		local v = spu.voices[i]
		for j = 1, 8 do v.regs[j] = r:u16() end
		v.currentAddress = r:u16(); v.counter = r:u32(); v.flags = r:u8()
		v.firstBlock = r:u8() == 1; v.hasSamples = r:u8() == 1; v.ignoreLoopAddress = r:u8() == 1
		for j = 1, 31 do v.samples[j] = signed16(r:u16()) end
		v.lastSamples[1] = signed16(r:u16()); v.lastSamples[2] = signed16(r:u16()); v.lastVolume = signed16(r:u16())
		loadSpuSweep(r, v.left); loadSpuSweep(r, v.right)
		v.adsr.level = signed16(r:u16()); v.adsr.phase = r:u8(); v.adsr.target = signed16(r:u16()); loadSpuEnvelope(r, v.adsr.env)
	end
end

local function loadTimers(r, timers, version)
	if (version or 0) >= 7 then
		for i = 1, 3 do
			local t = timers.timers[i]
			t.counter = r:u16()
			t.mode = r:u16()
			t.target = r:u16()
			t.gate = r:u8() == 1
			t.useExternalClock = r:u8() == 1
			t.externalCountingEnabled = r:u8() == 1
			t.countingEnabled = r:u8() == 1
			t.irqDone = r:u8() == 1
		end
		timers.sysclkDiv8Carry = r:u32()
		timers.crtcTick = r:u32()
		timers.currentScanline = r:u32()
		timers.inHblank = r:u8() == 1
		timers.inVblank = r:u8() == 1
		timers.fractionalTicks = r:u32()
		timers.dotClockDivider = r:u32()
		timers.dotTickCarry = r:u32()
	else
		-- v6 and earlier: derive the new timer flags from the restored mode so an external-clock timer resumes its real clock instead of raw sysclk.
		for i = 1, 3 do
			local t = timers.timers[i]
			t.counter = r:u16()
			t.mode = r:u16()
			t.target = r:u16()
			t.irq = r:u8() == 1
			t.irqDone = t.irq
			t._accum = r:u32()
			t.gate = false
			-- duckstation: use_external_clock = (clock_source & (timer==2 ? 2 : 1)) != 0
			local clk = band(rshift(t.mode, 8), 3)
			t.useExternalClock = band(clk, (i == 3 and 2 or 1)) ~= 0
			t.countingEnabled = true
			t.externalCountingEnabled = t.useExternalClock
		end
		timers.sysclkDiv8Carry = 0
		timers.crtcTick = 0
		timers.currentScanline = 0
		timers.inHblank = true
		timers.inVblank = true
		timers.fractionalTicks = 0
		timers.dotClockDivider = 10
		timers.dotTickCarry = 0
	end
	timers.vblankTick = r:u32()
	timers.totalCycles = r:u32() + r:u32() * 0x100000000
	timers.nextVBlankCycle = r:u32() + r:u32() * 0x100000000
end

local function loadDma(r, dma)
	dma.dpcr = r:u32()
	dma.dicr = r:u32()
	for i = 1, 7 do
		local ch = dma.channels[i]
		-- madr is 24 bits wide on hardware; legacy checkpoints may hold an
		-- unmasked kseg0 address (the old controller stored writes raw).
		ch.madr = band(r:u32(), 0x00FFFFFF)
		ch.bcr = r:u32()
		ch.chcr = r:u32()
	end
end


function Ckpt.save(runtime, path, writeFile)
	local w = Writer.new()
	w:str(MAGIC)
	w:u32(VERSION)
	saveCpu(w, runtime)
	saveMemory(w, runtime.memory)
	saveGpu(w, runtime.memory.gpu)
	saveCdrom(w, runtime.memory.cdrom)
	saveSpu(w, runtime.memory.spu)
	saveTimers(w, runtime.memory.timers)
	saveDma(w, runtime.memory.dma)
	-- runtime-level flags
	w:u8(runtime.biosLoaded and 1 or 0)
	w:u8(runtime.vsyncWaitFastForwarded and 1 or 0)
	-- loadedheader: only loadaddress/entrypoint matter post-boot (ri heuristic)
	local header = runtime.loadedHeader
	if header then
		w:u8(1)
		w:u32(header.loadAddress or 0)
		w:u32(header.entryPoint or 0)
	else
		w:u8(0)
	end
	local data = w:finish()
	if writeFile then
		writeFile(path, data)
	else
		error("Ckpt.save: no writeFile provided (Roblox build; use the Lune tools or inject a writer)")
	end
	return #data
end

-- core loader: takes the raw checkpoint bytes (read from a file by lune
-- tools, or delivered base64-encoded over http to the roblox server).
function Ckpt.loadData(runtime, data)
	local r = Reader.new(data)
	local magic = r:str()
	if magic ~= MAGIC then
		error("checkpoint: bad magic " .. magic)
	end
	local version = r:u32()
	if version > VERSION then
		error("checkpoint: unsupported version " .. version)
	end
	loadCpu(r, runtime)
	loadMemory(r, runtime.memory, version)
	loadGpu(r, runtime.memory.gpu, version)
	loadCdrom(r, runtime.memory.cdrom, version)
	loadSpu(r, runtime.memory.spu, version)
	loadTimers(r, runtime.memory.timers, version)
	loadDma(r, runtime.memory.dma)
	runtime.biosLoaded = r:u8() == 1
	runtime.vsyncWaitFastForwarded = r:u8() == 1
	-- ram/pc state changed wholesale: any decoded blocks are stale.
	runtime.cpu:invalidateAllBlocks()
	if r:u8() == 1 then
		runtime.loadedHeader = {
			loadAddress = r:u32(),
			entryPoint = r:u32(),
		}
	else
		runtime.loadedHeader = nil
	end
	if r.pos ~= #data + 1 then
		error(string.format("checkpoint: %d trailing bytes", #data + 1 - r.pos))
	end
	return true
end

-- path-based convenience for lune tools (readfile is injected, e.g.
-- fs.readfile from @lune/fs).  roblox scripts call loaddata directly.
function Ckpt.load(runtime, path, readFile)
	if not readFile then
		error("Ckpt.load: no readFile provided")
	end
	return Ckpt.loadData(runtime, readFile(path))
end

return Ckpt
