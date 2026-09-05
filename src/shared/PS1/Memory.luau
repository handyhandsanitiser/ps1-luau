local GPU = require(script.Parent.GPU)
local Timers = require(script.Parent.Timers)
local DMA = require(script.Parent.DMA)
local CDROM = require(script.Parent.CDROM)
local SPU = require(script.Parent.SPU)
local MDEC = require(script.Parent.MDEC)

local Memory = {}
Memory.__index = Memory

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift

Memory.RAM_SIZE = 0x200000
Memory.SCRATCHPAD_SIZE = 0x400
Memory.BIOS_SIZE = 0x80000

-- physical bus map; names match tools/mem_ref.luau so refcheck guards the decode windows below.
Memory.RAM_MASK = 0x1FFFFF
Memory.HW_BASE = 0x1F801000
Memory.HW_SIZE = 0x1000
Memory.SCRATCHPAD_ADDR = 0x1F800000
Memory.EXP1_BASE = 0x1F000000
Memory.EXP1_SIZE = 0x800000
Memory.EXP2_BASE = 0x1F802000
Memory.EXP2_SIZE = 0x2000
Memory.EXP3_BASE = 0x1FA00000
Memory.EXP3_SIZE = 0x200000
Memory.BIOS_BASE = 0x1FC00000
Memory.BIOS_MASK = 0x7FFFF
Memory.SIO2_BASE = 0x1F808000
Memory.SIO2_SIZE = 0x1000
Memory.CACHE_CTRL_ADDR = 0xFFFE0130

local JOYPAD_DATA = 0x1F801040
local JOYPAD_STAT = 0x1F801044
local JOYPAD_MODE = 0x1F801048
local JOYPAD_CTRL = 0x1F80104A
local JOYPAD_BAUD = 0x1F80104E

-- sio0 card protocol: 0x01 selects the controller, 0x81 the card; fresh-card flag reply is 08h.
local CARD_FLAG_FORMATTED = 0x08
local MC_FRAME_SIZE = 128
local MC_DATA_SIZE = 131072

local CARD_STATE_IDLE = "idle"
local CARD_STATE_COMMAND = "command"
local CARD_STATE_READ_ID1 = "read_id1"
local CARD_STATE_READ_ID2 = "read_id2"
local CARD_STATE_READ_ADDR_MSB = "read_addr_msb"
local CARD_STATE_READ_ADDR_LSB = "read_addr_lsb"
local CARD_STATE_READ_ACK1 = "read_ack1"
local CARD_STATE_READ_ACK2 = "read_ack2"
local CARD_STATE_READ_CONF_MSB = "read_conf_msb"
local CARD_STATE_READ_CONF_LSB = "read_conf_lsb"
local CARD_STATE_READ_DATA = "read_data"
local CARD_STATE_READ_CHK = "read_chk"
local CARD_STATE_READ_END = "read_end"
local CARD_STATE_WRITE_ID1 = "write_id1"
local CARD_STATE_WRITE_ID2 = "write_id2"
local CARD_STATE_WRITE_ADDR_MSB = "write_addr_msb"
local CARD_STATE_WRITE_ADDR_LSB = "write_addr_lsb"
local CARD_STATE_WRITE_DATA = "write_data"
local CARD_STATE_WRITE_CHK = "write_chk"
local CARD_STATE_WRITE_ACK1 = "write_ack1"
local CARD_STATE_WRITE_ACK2 = "write_ack2"
local CARD_STATE_WRITE_END = "write_end"
local CARD_STATE_GETID_ID1 = "getid_id1"
local CARD_STATE_GETID_ID2 = "getid_id2"
local CARD_STATE_GETID_ACK1 = "getid_ack1"
local CARD_STATE_GETID_ACK2 = "getid_ack2"
local CARD_STATE_GETID_1 = "getid_1"
local CARD_STATE_GETID_2 = "getid_2"
local CARD_STATE_GETID_3 = "getid_3"
local CARD_STATE_GETID_4 = "getid_4"

-- pad response: ff 41 5a <lo buttons> <hi buttons> (all released => ff ff)
local PAD_SELECT_ACK = 0xFF
local PAD_ID_LOW = 0x41
local PAD_ID_HIGH = 0x5A

-- button bits: lo byte = select/l3/r3/start/up/right/down/left (1,2,4,8,16,32,64,128),
-- hi byte = l2/r2/l1/r1/triangle/circle/cross/square; a set bit = pressed = reply 0.
local function padReplyButtons(joypad)
	local buttons = joypad.buttons or 0
	return band(bnot(buttons), 0xFF), band(bnot(rshift(buttons, 8)), 0xFF)
end

local function createJoypadState()
	return {
		mode = 0,
		ctrl = 0,
		baud = 0,
		rxData = 0,
		-- button bitmask (0 = nothing pressed); mutable so host code can drive input
		buttons = 0,
		-- sio0 controller transaction state
		padSelected = false,
		padReply = nil,      -- table of remaining response bytes
		padTxCount = 0,      -- TX bytes observed since select
		padResponseIndex = 0,
		padConfigMode = false, -- config mode active (43h protocol)
		padAnalogMode = false, -- analog mode active (44h protocol)
		padCmdBuf = nil,       -- TX bytes of the current command (for transitions)
		-- 4dh get/set rumble: the six config bytes map motor indices to reply
		-- byte slots (duckstation m_rumble_config, init 0xff = unmapped).
		padRumbleConfig = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
		-- sio0 active-device routing (duckstation activedevice): "none" until
		-- a select byte picks a device, then sticky for the whole transaction.
		activeDevice = "none",
		-- sio0 memory-card transaction state (protocol mirrors the psx card:
		-- 81h select, then 52h read / 57h write / 53h get-id command)
		cardSelected = false,
		cardState = CARD_STATE_IDLE,
		cardAddress = 0,
		cardSectorOffset = 0,
		cardChecksum = 0,
		cardLastIn = 0,
		-- duckstation no_write_yet: flag bit 3 (0x08) until the first write data byte, then 0x00.
		cardNoWriteYet = true,
		txReady = true,
		rxReady = false,
		-- /ack asserted while responding to a tx byte; read as joy_stat bit 7 (dsr).
		ackAsserted = false,
		ackCycle = 0,
		_needsStep = false, -- cycle when /ACK was last asserted (pulse timing)
		-- i_stat.7 pad irq fires ~450 cycles after the tx byte (the driver clears it first, so delay the raise).
		pendingPadIrqCycle = nil,
		-- sticky sio0 irq flag (joy_stat bit 9): latched on /ack with ackinten on, cleared by joy_ctrl ack bit.
		irqFlag = false,
		bufferFull = 0,
		irqEnabled = false,
		readCounts = {
			data = 0,
			stat = 0,
			mode = 0,
			ctrl = 0,
			baud = 0,
		},
		writeCounts = {
			data = 0,
			mode = 0,
			ctrl = 0,
			baud = 0,
		},
		lastTxByte = nil,
	}
end

-- fresh 128kb card image (duckstation memorycardimage::format): 0xff except the "mc" header,
-- 0xa0 free directory frames, broken-sector list, and zeroed spare frames; frame 63 copies the header.
local function createMemoryCardImage()
	local data = table.create(MC_DATA_SIZE, 0xFF)
	local function frameChecksum(frameStart)
		local c = 0
		for i = frameStart, frameStart + MC_FRAME_SIZE - 2 do
			c = bxor(c, data[i])
		end
		return band(c, 0xFF)
	end
	-- block 0, frame 0: header "mc"
	local s0 = 0
	for i = s0, s0 + MC_FRAME_SIZE - 2 do
		data[i] = 0
	end
	data[s0] = 0x4D -- 'M'
	data[s0 + 1] = 0x43 -- 'C'
	data[s0 + MC_FRAME_SIZE - 1] = frameChecksum(s0)
	-- block 0, frames 1..15: directory (all free)
	for frame = 1, 15 do
		local s = frame * MC_FRAME_SIZE
		for i = s, s + MC_FRAME_SIZE - 2 do
			data[i] = 0
		end
		data[s] = 0xA0 -- free
		data[s + 8] = 0xFF -- pointer to next file
		data[s + 9] = 0xFF
		data[s + MC_FRAME_SIZE - 1] = frameChecksum(s)
	end
	-- block 0, frames 16..35: broken sector list
	for frame = 16, 35 do
		local s = frame * MC_FRAME_SIZE
		for i = s, s + MC_FRAME_SIZE - 2 do
			data[i] = 0
		end
		data[s] = 0xFF
		data[s + 1] = 0xFF
		data[s + 2] = 0xFF
		data[s + 3] = 0xFF
		data[s + 8] = 0xFF
		data[s + 9] = 0xFF
		data[s + MC_FRAME_SIZE - 1] = frameChecksum(s)
	end
	-- block 0, frames 36..62: broken-sector replacement data / unused (zeros)
	for frame = 36, 62 do
		local s = frame * MC_FRAME_SIZE
		for i = s, s + MC_FRAME_SIZE - 1 do
			data[i] = 0
		end
	end
	-- block 0, frame 63: write-test frame = copy of header frame
	for i = 0, MC_FRAME_SIZE - 1 do
		data[63 * MC_FRAME_SIZE + i] = data[i]
	end
	return data
end

function Memory.new(options)
	local self = setmetatable({}, Memory)
	options = options or {}
	self.ram = table.create(Memory.RAM_SIZE, 0)
	-- u32 mirror of ram for the instruction-fetch fast path; kept in sync by write8/write32 and ckpt load.
	self.ram32 = table.create(Memory.RAM_SIZE // 4, 0)
	self.scratchpad = table.create(Memory.SCRATCHPAD_SIZE, 0)
	self.bios = table.create(Memory.BIOS_SIZE, 0)
	self.iStat = 0
	self.iMask = 0
	-- cached band(iStat, iMask) for the block engine's per-instruction interrupt check; refreshed at every iStat/iMask write site.
	self._irqState = 0
	-- device line state (duckstation interruptcontroller s_interrupt_line_state):
	-- the i_stat bit latches only on a 0->1 transition of the device line.
	self.iLineState = 0
	self.traceInterruptRegisters = options.traceInterruptRegisters == true
	self.pressedButtons = band(options.pressedButtons or 0, 0xFFFF)
	self.traceSuspiciousRamWrites = options.traceSuspiciousRamWrites == true
	self.traceWatchedRamWrites = options.traceWatchedRamWrites == true
	self.watchRamStart = band(options.watchRamStart or 0x0005B600, 0x1FFFFFFF)
	self.watchRamEnd = band(options.watchRamEnd or 0x0005B800, 0x1FFFFFFF)
	-- debug-only ram write log; off unless a probe enables options.trackramwrites (shifting on every store is expensive).
	self.trackRamWrites = options.trackRamWrites == true
	self.recentRamWrites = {}
	self.recentRamWriteMax = 256
	self.lastPendingMask = nil
	self.gpu = options.gpu or GPU.new()
	self.dma = options.dma or DMA.new()
	self.dma.memory = self
	self.dma:setInterruptCallback(function()
		self:raiseInterrupt(3)
	end)
	self.mdec = options.mdec or MDEC.new()
	self.cdrom = options.cdrom or CDROM.new(options)
	self.spu   = options.spu   or SPU.new()
	self.spu.memory = self
	self.cdrom.memory = self
	self.cdrom:setInterruptCallback(function()
		self:raiseInterrupt(2)
	end)
	-- dma linked-list reads come straight from ram (duckstation); bus errors are checked by the dma controller, so read the u32 mirror directly.
	local ram32 = self.ram32
	self.dma.readRam = function(addr)
		return ram32[band(addr, Memory.RAM_MASK) // 4 + 1]
	end

	-- dma steals cpu cycles: 1 clk/word + row overhead (duckstation getdmaramtickcount), charged on the kicking instruction.
	self.dma:setTickCallback(function(ticks)
		self:advanceCycles(ticks)
	end)

	self.dma:setChannelHandler(0, function(transfer)
		return self:handleDmaMdecInTransfer(transfer)
	end)
	self.dma:setChannelHandler(1, function(transfer)
		return self:handleDmaMdecOutTransfer(transfer)
	end)
	self.dma:setChannelHandler(2, function(transfer)
		-- linked-list mode: the dma controller reads list headers/data from
		-- ram itself (readram); only the gp0 write is dispatched here.
		if transfer.linkedListGpu then
			self.gpu:writeGp0(transfer.word)
			return nil
		end
		return self:handleDmaGpuTransfer(transfer)
	end)
	self.dma:setChannelHandler(3, function(transfer)
		return self:handleDmaCdromTransfer(transfer)
	end)
	self.dma:setChannelHandler(4, function(transfer)
		return self:handleDmaSpuTransfer(transfer)
	end)
	self.dma:setChannelHandler(6, function(transfer)
		return self:handleDmaOtcTransfer(transfer)
	end)
	self.spu:setInterruptCallback(function()
		self:raiseInterrupt(9)
	end)
	-- spu fifo full/empty drives dma ch4 request (duckstation updatedmarequest), pacing block transfers at 16 ticks/halfword.
	self.spu:setDmaRequestCallback(function(request)
		self.dma:setRequest(4, request)
	end)
	self.timers = Timers.new(self, options)
	self.cycleCount = 0
	self.cacheIsolated = false
	-- bus-error latch (duckstation g_state.bus_error); cpu load/store paths raise dbe (excode 7) on it.
	self.busError = false
	-- memory control registers: exp1/exp2/exp3/bios/spu/cdrom delay-size,
	-- common delay (9 word registers, duckstation memctrl_reg_count).
	self.memCtrlRegs = table.create(9, 0)
	-- 1f801060 ram size register: window 4 = 2mb mirror, 5/7 = 8mb (duckstation updatemappedramsize).
	self.ramSizeReg = 0x00000B88
	self.ramMappedEnd = 0x800000
	self.ramMask = Memory.RAM_MASK
	-- dma bus-error boundary follows the ram map (duckstation checkforbuserror).
	self.dma.ramMappedEnd = self.ramMappedEnd
	-- sio1 (0x1f801050-0x5f) serial register file (duckstation sio.cpp
	-- softreset defaults: txrdy|txdone|cts|dsr set, baud = 0xdc).
	self.sio1 = { stat = 0xC5, mode = 0, ctrl = 0, baud = 0xDC }
	-- kseg2 cache control register (0xfffe0130).
	self.cacheControl = 0
	self.memcard = createMemoryCardImage()
	self.joypad = createJoypadState()
	self.joypad.buttons = self.pressedButtons
	self.joypad.cardData = self.memcard
	-- peripheral batch window (cycles) for gpu/cdrom/timers stepping.
	self.flux = 0
	self._periphBatch = 256
	return self
end

function Memory:readJoypadIO(address)
	local joypad = self.joypad
	if address == JOYPAD_DATA then
		joypad.readCounts.data += 1
		local value = joypad.rxData or 0
		-- rx buffer drained by the read; clear the rx-ready latch.
		joypad.rxReady = false
		joypad.rxData = 0
		return value
	elseif address == JOYPAD_STAT then
		joypad.readCounts.stat += 1
		-- sio0 status: bit0 = tx ready, bit1 = rx ready, bit2 = tx idle,
		-- bit7 = dsr input (= controller /ack asserted).
		local status = 0
		if joypad.txReady then status = status + 0x01 end
		if joypad.rxReady then status = status + 0x02 end
		status = status + 0x04
		if joypad.ackAsserted then status = status + 0x80 end
		if joypad.irqFlag then status = status + 0x200 end
		return status
	elseif address == JOYPAD_MODE then
		joypad.readCounts.mode += 1
		return joypad.mode or 0
	elseif address == JOYPAD_CTRL then
		joypad.readCounts.ctrl += 1
		return joypad.ctrl or 0
	elseif address == JOYPAD_BAUD then
		joypad.readCounts.baud += 1
		return joypad.baud or 0
	end
	return 0
end

-- config-mode pad state machine (duckstation analogcontroller).  games probe 43h/45h and need the 0xf3 config id to finish init.
local PAD_ID_CONFIG = 0xF3 -- config mode: (mode 0xF << 4) | 3 halfwords
local PAD_ID_ANALOG = 0x73 -- analog mode: (mode 0x7 << 4) | 3 halfwords

-- pad reply for the current tx byte: 0x01 -> ff, 0x42 -> 41, then 5a, buttons lo/hi.
local function advancePadReply(joypad, txByte)
	-- reply stream exhausted = transaction over; the next select restarts it (leftover bytes would corrupt the next reply).
	if joypad.padTxCount > 0 and joypad.padReply and #joypad.padReply == 0 then
		joypad.padTxCount = 0
		joypad.padCmdBuf = nil
		joypad.padReply = nil
	end

	-- 0x01 starts a transaction only when idle; a mid-command 0x01 (config-mode bytes) must not reset it.
	if txByte == 0x01 and joypad.padTxCount == 0 then
		-- select: duckstation's idle state acks the controller access
		-- ("ack controller access") and moves to ready.
		joypad.padSelected = true
		joypad.padCmdBuf = nil
		joypad.padReply = nil
		joypad.rxData = PAD_SELECT_ACK
		return true
	end

	if not joypad.padSelected then
		-- not the expected select byte; echo idle, stay unselected, and
		-- nack (duckstation's idle state returns false for non-0x01).
		joypad.rxData = 0xFF
		return false
	end

	joypad.padTxCount += 1
	local idx = joypad.padTxCount
	if idx == 1 then
		-- command byte (first byte following the select ack).
		joypad.padCmdBuf = { txByte }
		if txByte == 0x42 then
			-- 42h read pad: reply id is mode-dependent -- 41h digital (4 bytes), 73h analog / f3h config (8 bytes); the reply length must match the driver's transaction.
			local bLo, bHi = padReplyButtons(joypad)
			if joypad.padConfigMode or joypad.padAnalogMode then
				local id = joypad.padConfigMode and PAD_ID_CONFIG or PAD_ID_ANALOG
				joypad.padReply = { id, PAD_ID_HIGH, bLo, bHi, 0x80, 0x80, 0x80, 0x80 }
			else
				joypad.padReply = { PAD_ID_LOW, PAD_ID_HIGH, bLo, bHi }
			end
		elseif txByte == 0x43 then
			-- 43h enter/leave config mode: mode flips when the command completes ([2]==1 enters).
			if joypad.padConfigMode then
				joypad.padReply = { PAD_ID_CONFIG, PAD_ID_HIGH, 0, 0, 0, 0, 0, 0 }
			else
				local bLo, bHi = padReplyButtons(joypad)
				if joypad.padAnalogMode then
					joypad.padReply = { PAD_ID_ANALOG, PAD_ID_HIGH, bLo, bHi, 0x80, 0x80, 0x80, 0x80 }
				else
					joypad.padReply = { PAD_ID_LOW, PAD_ID_HIGH, bLo, bHi }
				end
			end
		elseif txByte == 0x45 then
			-- 45h get led state: f3 5a typ num led act com 00h (typ=01, num=02, led=mode, act=02, com=01).
			joypad.padReply = { PAD_ID_CONFIG, PAD_ID_HIGH, 1, 2, joypad.padAnalogMode and 1 or 0, 2, 1, 0 }
		elseif txByte == 0x44 then
			-- 44h set led state: f3 5a 00 00 err 00 00 00 (err=0, valid led).
			-- duckstation also resets the rumble config on this command.
			joypad.padReply = { PAD_ID_CONFIG, PAD_ID_HIGH, 0, 0, 0, 0, 0, 0 }
		elseif txByte == 0x46 or txByte == 0x47 or txByte == 0x4C then
			-- 46h padinfoact / 47h padinfocomb / 4ch padinfomode: payload is
			-- filled when the list-index byte arrives (command byte [2]).
			joypad.padReply = { PAD_ID_CONFIG, PAD_ID_HIGH, 0, 0, 0, 0, 0, 0 }
		elseif txByte == 0x4D then
			-- 4dh get/set rumble: echo config slots (init 0xff) at reply bytes 3..7, final byte 0x00; incoming bytes overwrite the config.
			joypad.padReply = { PAD_ID_CONFIG, PAD_ID_HIGH, joypad.padRumbleConfig[1], joypad.padRumbleConfig[2], joypad.padRumbleConfig[3], joypad.padRumbleConfig[4], joypad.padRumbleConfig[5], 0x00 }
		else
			-- unknown command: nack (0xff delivered, no /ack pulse, duckstation's ready-state default).  acking would make the driver read 0xff as a valid id and retry forever.
			joypad.rxData = 0xFF
			joypad.padTxCount = 0
			joypad.padCmdBuf = nil
			joypad.padReply = nil
			return false
		end
		local reply = joypad.padReply
		if reply and #reply > 0 then
			joypad.rxData = table.remove(reply, 1)
		else
			joypad.rxData = 0xFF
		end
		return true
	end

	-- record remaining command bytes for state transitions, then stream the reply.
	-- defensive: re-arm an empty buffer if a pre-v3 checkpoint left padtxcount > 0 without one.
	if not joypad.padCmdBuf then
		joypad.padCmdBuf = {}
	end
	joypad.padCmdBuf[idx] = txByte
	local cmd = joypad.padCmdBuf[1]
	if cmd == 0x43 and joypad.padReply and #joypad.padReply == 1 then
		-- 43h mode byte: [2]==1 enters config, 0 leaves (duckstation flips on the transfer's last byte).
		joypad.padConfigMode = joypad.padCmdBuf[3] == 1
	elseif cmd == 0x44 and idx == 3 then
		-- 44h: [2]=led (0 digital, 1 analog), [3]=key (0-2 unlock, 3 lock); duckstation also resets rumble config here.
		local led = joypad.padCmdBuf[3]
		if led == 0 or led == 1 then
			joypad.padAnalogMode = led == 1
		end
		joypad.padRumbleConfig = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }
	elseif cmd == 0x4D and idx >= 3 and idx <= 7 then
		-- 4dh: echo config slots 0..4 at reply bytes 3..7 and store each incoming byte as the new mapping.
		joypad.padRumbleConfig[idx - 2] = txByte
	elseif (cmd == 0x46 or cmd == 0x47 or cmd == 0x4C or cmd == 0x48) and idx == 3 then
		-- config list-index byte [2] arrived: fill the payload bytes of the
		-- reply (remaining entries 3..6 of the 8-byte frame).
		local reply = joypad.padReply
		if reply then
			local ii = joypad.padCmdBuf[3]
			if cmd == 0x46 then
				-- padinfoact: ii=0 small motor 01 02 00 0a; ii=1 big motor 01 01 01 14; else zeroes
				if ii == 0 then reply[3], reply[4], reply[5], reply[6] = 1, 2, 0, 0x0A
				elseif ii == 1 then reply[3], reply[4], reply[5], reply[6] = 1, 1, 1, 0x14
				else reply[3], reply[4], reply[5], reply[6] = 0, 0, 0, 0 end
			elseif cmd == 0x47 then
				-- padinfocomb: ii=0 -> 02 00 01 00 (two entries: actuators 0 and 1); else zeroes
				if ii == 0 then reply[3], reply[4], reply[5], reply[6] = 2, 0, 1, 0
				else reply[3], reply[4], reply[5], reply[6] = 0, 0, 0, 0 end
			elseif cmd == 0x4C then
				-- padinfomode: ii=0 digital exid 00 04; ii=1 analog exid 00 07; else 00 00
				if ii == 0 then reply[3], reply[4] = 0, 4
				elseif ii == 1 then reply[3], reply[4] = 0, 7
				else reply[3], reply[4] = 0, 0 end
			elseif cmd == 0x48 then
				reply[5] = (ii == 0 or ii == 1) and 1 or 0
			end
		end
	end

	local reply = joypad.padReply
	if reply and #reply > 0 then
		joypad.rxData = table.remove(reply, 1)
		-- final reply byte gets no /ack pulse (dsr = more-data-request), ending the transfer back at idle.
		if #reply == 0 then
			joypad.padReply = nil
			joypad.padCmdBuf = nil
			joypad.padTxCount = 0
			return false
		end
	else
		joypad.rxData = 0xFF
	end
	return true
end

-- memory-card reply stream (duckstation memorycard::transfer): 81h -> flag; read = flag, 5ah, 5dh,
-- addr msb/lsb, 5ch, 5dh, addr, 128 data bytes, checksum, 47h.  returns false for the final byte (no irq7).
local function advanceCardReply(joypad, txByte)
	local st = joypad.cardState
	local data = joypad.cardData
	joypad.rxData = 0xFF
	local raiseIrq = true

	if st == CARD_STATE_IDLE then
		-- card selects on exactly 0x81 (0x82..0x8f are multitap slot selects, rewritten by a multitap only).
		if txByte == 0x81 then
			joypad.rxData = 0xFF
			joypad.cardState = CARD_STATE_COMMAND
		else
			-- non-select byte at idle: 0xff reply, no ack (nothing drives the bus).
			return false, false
		end
	elseif st == CARD_STATE_COMMAND then
		-- flag bit 3 (0x08) clears after the first write data byte (no_write_yet).
		joypad.rxData = joypad.cardNoWriteYet and CARD_FLAG_FORMATTED or 0
		if txByte == 0x52 then
			joypad.cardState = CARD_STATE_READ_ID1
		elseif txByte == 0x57 then
			joypad.cardState = CARD_STATE_WRITE_ID1
		elseif txByte == 0x53 then
			joypad.cardState = CARD_STATE_GETID_ID1
		else
			-- invalid command: flag reply, no ack, back to idle immediately.
			joypad.cardState = CARD_STATE_IDLE
			return false, false
		end
	elseif st == CARD_STATE_READ_ID1 then
		joypad.rxData = 0x5A
		joypad.cardState = CARD_STATE_READ_ID2
	elseif st == CARD_STATE_READ_ID2 then
		joypad.rxData = 0x5D
		joypad.cardState = CARD_STATE_READ_ADDR_MSB
	elseif st == CARD_STATE_READ_ADDR_MSB then
		joypad.rxData = 0x00
		joypad.cardAddress = band(bor(band(joypad.cardAddress, 0x00FF), lshift(band(txByte, 0xFF), 8)), 0x3FF)
		joypad.cardState = CARD_STATE_READ_ADDR_LSB
	elseif st == CARD_STATE_READ_ADDR_LSB then
		joypad.rxData = joypad.cardLastIn
		joypad.cardAddress = band(bor(band(joypad.cardAddress, 0xFF00), band(txByte, 0xFF)), 0x3FF)
		joypad.cardSectorOffset = 0
		joypad.cardState = CARD_STATE_READ_ACK1
	elseif st == CARD_STATE_READ_ACK1 then
		joypad.rxData = 0x5C
		joypad.cardState = CARD_STATE_READ_ACK2
	elseif st == CARD_STATE_READ_ACK2 then
		joypad.rxData = 0x5D
		joypad.cardState = CARD_STATE_READ_CONF_MSB
	elseif st == CARD_STATE_READ_CONF_MSB then
		joypad.rxData = band(rshift(joypad.cardAddress, 8), 0xFF)
		joypad.cardState = CARD_STATE_READ_CONF_LSB
	elseif st == CARD_STATE_READ_CONF_LSB then
		joypad.rxData = band(joypad.cardAddress, 0xFF)
		joypad.cardState = CARD_STATE_READ_DATA
	elseif st == CARD_STATE_READ_DATA then
		local b = data[joypad.cardAddress * MC_FRAME_SIZE + joypad.cardSectorOffset] or 0xFF
		if joypad.cardSectorOffset == 0 then
			joypad.cardChecksum = band(bxor(band(rshift(joypad.cardAddress, 8), 0xFF), band(joypad.cardAddress, 0xFF), b), 0xFF)
		else
			joypad.cardChecksum = band(bxor(joypad.cardChecksum, b), 0xFF)
		end
		joypad.rxData = b
		joypad.cardSectorOffset += 1
		if joypad.cardSectorOffset == MC_FRAME_SIZE then
			joypad.cardSectorOffset = 0
			joypad.cardState = CARD_STATE_READ_CHK
		end
	elseif st == CARD_STATE_READ_CHK then
		joypad.rxData = joypad.cardChecksum
		joypad.cardState = CARD_STATE_READ_END
	elseif st == CARD_STATE_READ_END then
		joypad.rxData = 0x47
		joypad.cardState = CARD_STATE_IDLE
		-- last reply byte (47h end): no /ack pulse, no irq7.
		return false, false
	elseif st == CARD_STATE_WRITE_ID1 then
		joypad.rxData = 0x5A
		joypad.cardState = CARD_STATE_WRITE_ID2
	elseif st == CARD_STATE_WRITE_ID2 then
		joypad.rxData = 0x5D
		joypad.cardState = CARD_STATE_WRITE_ADDR_MSB
	elseif st == CARD_STATE_WRITE_ADDR_MSB then
		joypad.rxData = 0x00
		joypad.cardAddress = band(bor(band(joypad.cardAddress, 0x00FF), lshift(band(txByte, 0xFF), 8)), 0x3FF)
		joypad.cardState = CARD_STATE_WRITE_ADDR_LSB
	elseif st == CARD_STATE_WRITE_ADDR_LSB then
		joypad.rxData = joypad.cardLastIn
		joypad.cardAddress = band(bor(band(joypad.cardAddress, 0xFF00), band(txByte, 0xFF)), 0x3FF)
		joypad.cardSectorOffset = 0
		joypad.cardState = CARD_STATE_WRITE_DATA
	elseif st == CARD_STATE_WRITE_DATA then
		local offset = joypad.cardAddress * MC_FRAME_SIZE + joypad.cardSectorOffset
		if joypad.cardSectorOffset == 0 then
			-- duckstation clears no_write_yet on the first data byte of a
			-- write (not on the write command itself).
			joypad.cardNoWriteYet = false
			joypad.cardChecksum = band(bxor(band(rshift(joypad.cardAddress, 8), 0xFF), band(joypad.cardAddress, 0xFF), txByte), 0xFF)
		else
			joypad.cardChecksum = band(bxor(joypad.cardChecksum, txByte), 0xFF)
		end
		data[offset] = band(txByte, 0xFF)
		joypad.rxData = joypad.cardLastIn
		joypad.cardSectorOffset += 1
		if joypad.cardSectorOffset == MC_FRAME_SIZE then
			joypad.cardSectorOffset = 0
			joypad.cardState = CARD_STATE_WRITE_CHK
		end
	elseif st == CARD_STATE_WRITE_CHK then
		joypad.rxData = joypad.cardLastIn
		joypad.cardState = CARD_STATE_WRITE_ACK1
	elseif st == CARD_STATE_WRITE_ACK1 then
		joypad.rxData = 0x5C
		joypad.cardState = CARD_STATE_WRITE_ACK2
	elseif st == CARD_STATE_WRITE_ACK2 then
		joypad.rxData = 0x5D
		joypad.cardState = CARD_STATE_WRITE_END
	elseif st == CARD_STATE_WRITE_END then
		joypad.rxData = 0x47
		joypad.cardState = CARD_STATE_IDLE
		-- duckstation fixed_reply_state(writeend, 0x47, false, idle).
		return false, false
	elseif st == CARD_STATE_GETID_ID1 then
		joypad.rxData = 0x5A
		joypad.cardState = CARD_STATE_GETID_ID2
	elseif st == CARD_STATE_GETID_ID2 then
		joypad.rxData = 0x5D
		joypad.cardState = CARD_STATE_GETID_ACK1
	elseif st == CARD_STATE_GETID_ACK1 then
		joypad.rxData = 0x5C
		joypad.cardState = CARD_STATE_GETID_ACK2
	elseif st == CARD_STATE_GETID_ACK2 then
		joypad.rxData = 0x5D
		joypad.cardState = CARD_STATE_GETID_1
	elseif st == CARD_STATE_GETID_1 then
		joypad.rxData = 0x04
		joypad.cardState = CARD_STATE_GETID_2
	elseif st == CARD_STATE_GETID_2 then
		joypad.rxData = 0x00
		joypad.cardState = CARD_STATE_GETID_3
	elseif st == CARD_STATE_GETID_3 then
		joypad.rxData = 0x00
		joypad.cardState = CARD_STATE_GETID_4
	elseif st == CARD_STATE_GETID_4 then
		joypad.rxData = 0x80
		joypad.cardState = CARD_STATE_IDLE
		-- duckstation fixed_reply_state(getid4, 0x80, false, idle).
		return false, false
	end
	joypad.cardLastIn = band(txByte, 0xFF)
	-- second return = /ack pulse; every byte acks except the invalid command.
	return raiseIrq, true
end

function Memory:writeJoypadIO(address, value)
	local joypad = self.joypad
	if address == JOYPAD_DATA then
		joypad.writeCounts.data += 1
		local b = band(value, 0xFF)
		joypad.lastTxByte = b
		joypad.rxReady = false
		-- active-device routing (duckstation dotransfer): first byte picks the device, all later bytes follow; must not re-route mid-transaction (card data can contain 0x01..0x0f / 0x80..0x8f).
		if joypad.activeDevice == "none" then
			-- device pick: controller = 0x01, card = 0x81; 0x82..0x8f (multitap slots) reach nothing without a multitap.
			if b == 0x01 then
				joypad.activeDevice = "pad"
				joypad.padSelected = true
				joypad.cardSelected = false
			elseif b == 0x81 then
				joypad.activeDevice = "card"
				joypad.cardSelected = true
				joypad.padSelected = false
				joypad.padReply = nil
				joypad.padTxCount = 0
			end
		end
	local ack = true
	local raiseIrq = true
	if joypad.activeDevice == "card" then
		raiseIrq, ack = advanceCardReply(joypad, b)
	else
		ack = advancePadReply(joypad, b)
	end
	joypad.rxReady = true
	-- /ack pulses low then releases; the driver waits for the release before proceeding, so it must not stay set.  nacked bytes get no pulse.
	if ack then
		joypad.ackAsserted = true
		joypad.ackCycle = self.cycleCount
		joypad._needsStep = true
		-- with dsr irqs enabled the /ack latches joy_stat bit 9; the driver clears it via joy_ctrl ack bit.
		if raiseIrq and band(joypad.ctrl, 0x1000) ~= 0 then
			joypad.irqFlag = true
			-- /ack raises i_stat.7 after a delay: ~170 ticks for the card, ~450 for the pad
			-- (duckstation getackticks).  the driver clears i_stat.7 right after the tx, so the
			-- raise must be delayed to survive that clear.
			joypad.pendingPadIrqCycle = self.cycleCount + (joypad.activeDevice == "card" and 170 or 1600)
		end
	end
	return
	elseif address == JOYPAD_MODE then
		joypad.writeCounts.mode += 1
		joypad.mode = band(value, 0xFFFF)
		return
	elseif address == JOYPAD_CTRL then
		joypad.writeCounts.ctrl += 1
		-- joy_ctrl ack bit (4) clears the sticky sio0 irq flag and drops the pad irq line.
		if band(value, 0x10) ~= 0 then
			joypad.irqFlag = false
			self:setInterruptLine(7, false)
		end
		-- joy_ctrl.select deassert ends the transaction (duckstation resetdevicetransferstate): back to idle, unread reply bytes dropped.
		if band(value, 0x0002) == 0 then
			joypad.padReply = nil
			joypad.padTxCount = 0
			joypad.padCmdBuf = nil
			joypad.cardState = CARD_STATE_IDLE
			joypad.cardAddress = 0
			joypad.cardSectorOffset = 0
			joypad.cardChecksum = 0
			joypad.cardLastIn = 0
			-- duckstation resetdevicetransferstate: select deassert returns the
			-- port to activedevice::none so the next byte picks a device again.
			joypad.activeDevice = "none"
			joypad.padSelected = false
			joypad.cardSelected = false
		end
		-- sio_ctrl bit 6 is the hardware reset (clears most registers); bit 13
		-- is only the port-2 slot select and must not reset the transaction.
		if band(value, 0x40) ~= 0 then
			joypad.padSelected = false
			joypad.padTxCount = 0
			joypad.padReply = nil
			joypad.cardSelected = false
			joypad.padSelected = false
			joypad.cardState = CARD_STATE_IDLE
			joypad.rxData = 0
			joypad.rxReady = false
			joypad.ackAsserted = false
			joypad._needsStep = joypad.pendingPadIrqCycle ~= nil
			-- duckstation memorycard::reset (system reset / card re-insert)
			-- re-arms the no-write-yet flag bit.
			joypad.cardNoWriteYet = true
			joypad.activeDevice = "none"
			joypad.ctrl = band(value, 0x3FFF)
			return
		end
		joypad.ctrl = band(value, 0x3FFF)
		return
	elseif address == JOYPAD_BAUD then
		joypad.writeCounts.baud += 1
		joypad.baud = band(value, 0xFFFF)
		return
	end
end

function Memory:dumpJoypadState()
	local joypad = self.joypad or createJoypadState()
	return {
		mode = joypad.mode,
		ctrl = joypad.ctrl,
		baud = joypad.baud,
		rxData = joypad.rxData,
		lastTxByte = joypad.lastTxByte,
		cardSelected = joypad.cardSelected,
		cardState = joypad.cardState,
		cardAddress = joypad.cardAddress,
		cardSectorOffset = joypad.cardSectorOffset,
		cardChecksum = joypad.cardChecksum,
		cardLastIn = joypad.cardLastIn,
		cardNoWriteYet = joypad.cardNoWriteYet,
		activeDevice = joypad.activeDevice,
		readCounts = {
			data = joypad.readCounts.data,
			stat = joypad.readCounts.stat,
			mode = joypad.readCounts.mode,
			ctrl = joypad.readCounts.ctrl,
			baud = joypad.readCounts.baud,
		},
		writeCounts = {
			data = joypad.writeCounts.data,
			mode = joypad.writeCounts.mode,
			ctrl = joypad.writeCounts.ctrl,
			baud = joypad.writeCounts.baud,
		},
	}
end

function Memory:traceIrqRegisters(source)
	if not self.traceInterruptRegisters then
		return
	end
	local pending = band(self.iStat, self.iMask)
	print(string.format("[ps1-irq] %s istat=%04X imask=%04X pending=%04X", source, self.iStat, self.iMask, pending))
end

function Memory:tracePendingMaskIfChanged(source)
	if not self.traceInterruptRegisters then
		return
	end
	local pending = band(self.iStat, self.iMask)
	if self.lastPendingMask ~= pending then
		print(string.format("[ps1-irq] %s pending %04X -> %04X (istat=%04X imask=%04X)", source, self.lastPendingMask or 0, pending, self.iStat, self.iMask))
		self.lastPendingMask = pending
	end
end

function Memory:traceSuspiciousWordWrite(physical, value)
	if not self.traceSuspiciousRamWrites then
		return
	end
	local b0 = band(value, 0xFF)
	local b1 = band(rshift(value, 8), 0xFF)
	local b2 = band(rshift(value, 16), 0xFF)
	local b3 = band(rshift(value, 24), 0xFF)
	if b0 == b1 and b0 == b2 and b0 == b3 and b0 ~= 0 and b0 ~= 0xFF then
		print(string.format("[ps1-mem] repeated-byte write addr=%08X value=%08X", physical, value))
	end
end

function Memory:isWatchedRamWrite(physical, size)
	if size <= 0 then
		return false
	end
	local startAddr = physical
	local endAddr = physical + size - 1
	return endAddr >= self.watchRamStart and startAddr <= self.watchRamEnd
end

function Memory:recordRamWrite(physical, value, size, kind)
	if size <= 0 then
		return
	end
	if not self.trackRamWrites then
		return
	end
	if #self.recentRamWrites >= self.recentRamWriteMax then
		table.remove(self.recentRamWrites, 1)
	end
	table.insert(self.recentRamWrites, {
		cycle = self.cycleCount,
		pc = self.cpu and self.cpu.pc or 0,
		address = band(physical, 0x1FFFFFFF),
		value = band(value, 0xFFFFFFFF),
		size = size,
		kind = kind,
	})

	if self.traceWatchedRamWrites and self:isWatchedRamWrite(physical, size) then
		print(string.format("[ps1-mem] watch hit kind=%s addr=%08X size=%d value=%08X pc=%08X cycle=%d",
			tostring(kind),
			band(physical, 0x1FFFFFFF),
			size,
			band(value, 0xFFFFFFFF),
			self.cpu and self.cpu.pc or 0,
			self.cycleCount
		))
	end
end

function Memory:dumpRecentRamWrites(startAddr, endAddr, maxCount)
	startAddr = band(startAddr or 0, 0x1FFFFFFF)
	endAddr = band(endAddr or 0x1FFFFFFF, 0x1FFFFFFF)
	maxCount = maxCount or 24
	local emitted = 0
	for index = #self.recentRamWrites, 1, -1 do
		local entry = self.recentRamWrites[index]
		local entryStart = entry.address
		local entryEnd = entry.address + entry.size - 1
		if entryEnd >= startAddr and entryStart <= endAddr then
			print(string.format("[ps1-mem] recent write kind=%s addr=%08X size=%d value=%08X pc=%08X cycle=%d",
				tostring(entry.kind),
				entry.address,
				entry.size,
				entry.value,
				entry.pc,
				entry.cycle
			))
			emitted += 1
			if emitted >= maxCount then
				break
			end
		end
	end
	if emitted == 0 then
		print(string.format("[ps1-mem] recent write dump empty range=%08X-%08X", startAddr, endAddr))
	end
end

function Memory:handleDmaMdecInTransfer(transfer)
	local address = transfer.madr
	local step = band(transfer.chcr or 0, 0x2) ~= 0 and -4 or 4
	local count = transfer.wordCount or 0
	self.mdec:dmaIn(function(offset)
		return self:read32(band(address + offset * step, 0xFFFFFFFF))
	end, count)
	-- return the final address so the dma channel reflects the full transfer; a bus error here must not leak into the next cpu access.
	self.busError = false
	return band(address + count * step, 0xFFFFFFFF)
end

function Memory:handleDmaMdecOutTransfer(transfer)
	local address = transfer.madr
	local step = band(transfer.chcr or 0, 0x2) ~= 0 and -4 or 4
	local words = self.mdec:dmaOut(transfer.wordCount or 0)
	for i = 1, #words do
		self:write32(address, words[i])
		address = band(address + step, 0xFFFFFFFF)
	end
	if self.mdecOutCompleteCallback then
		self.mdecOutCompleteCallback()
	end
	self.busError = false
	return address
end

function Memory:handleDmaGpuTransfer(transfer)
	local address = transfer.madr
	local step = band(transfer.chcr or 0, 0x2) ~= 0 and -4 or 4
	for _ = 1, transfer.wordCount do
		if transfer.direction == 1 then
			local word = self:read32(address)
			self.gpu:write(0x1F801810, word)
		else
			self:write32(address, self.gpu:read(0x1F801810))
		end
		address = band(address + step, 0xFFFFFFFF)
	end
	self.busError = false
	return address
end

function Memory:handleDmaSpuTransfer(transfer)
	local address = transfer.madr
	local step = band(transfer.chcr or 0, 0x2) ~= 0 and -4 or 4
	for _ = 1, transfer.wordCount do
		if transfer.direction == 1 then
			-- ram -> spu: two halfwords per word land at the spu transfer address.
			local word = self:read32(address)
			self.spu:writeDmaWord(word)
		else
			-- spu -> ram
			self:write32(address, self.spu:readDmaWord())
		end
		address = band(address + step, 0xFFFFFFFF)
	end
	self.busError = false
	return address
end

function Memory:handleDmaCdromTransfer(transfer)
	local address = transfer.madr
	local step = band(transfer.chcr or 0, 0x2) ~= 0 and -4 or 4
	for i = 1, transfer.wordCount do
		local word = self.cdrom:popDataWord()
		self:write32(address, word)
		address = band(address + step, 0xFFFFFFFF)
	end
	self.busError = false
	return address
end

function Memory:handleDmaOtcTransfer(transfer)
	local address = band(transfer.madr, 0x1FFFFC)
	for index = 1, transfer.wordCount do
		local nextValue
		if index == transfer.wordCount then
			nextValue = 0x00FFFFFF
		else
			nextValue = band(address - 4, 0x1FFFFC)
		end
		self:write32(address, nextValue)
		address = band(address - 4, 0x1FFFFC)
	end
	self.busError = false
	return address
end

function Memory:loadBiosImage(data)
	local length = math.min(#data, Memory.BIOS_SIZE)
	for index = 1, length do
		self.bios[index] = data:byte(index)
	end
end

function Memory:physicalAddress(address)
	address = band(address, 0xFFFFFFFF)
	local region = band(address, 0xE0000000)
	local physical = address
	if region == 0x80000000 or region == 0xA0000000 then
		physical = band(address, 0x1FFFFFFF)
	end
	-- ram is mirrored across the first 8mb of the kuseg window (psx-spx memory mirrors); window 4 shrinks it to 2mb.
	if physical < self.ramMappedEnd then
		return band(physical, self.ramMask)
	end
	return physical
end

function Memory:read8(address)
	-- inlined kseg0/kseg1 physicaladdress fast path (see write32): one method
	-- call saved per load instruction.
	local physical = address
	local region = band(address, 0xE0000000)
	if region == 0x80000000 or region == 0xA0000000 then
		physical = band(address, 0x1FFFFFFF)
		if physical < self.ramMappedEnd then
			physical = band(physical, self.ramMask)
		end
	else
		physical = self:physicalAddress(address)
	end

	if physical < Memory.RAM_SIZE then
		return self.ram[physical + 1] or 0
	end

	-- scratchpad: only in kuseg/kseg0 (psx-spx memorymap.md), 1kb; the rest
	-- of the 4k page is unknown (open bus + bus error).
	if region ~= 0xA0000000 and physical >= Memory.SCRATCHPAD_ADDR and physical < Memory.SCRATCHPAD_ADDR + Memory.SCRATCHPAD_SIZE then
		return self.scratchpad[(physical - Memory.SCRATCHPAD_ADDR) + 1] or 0
	end
	if region ~= 0xA0000000 and physical >= Memory.SCRATCHPAD_ADDR + Memory.SCRATCHPAD_SIZE and physical < Memory.HW_BASE then
		self.busError = true
		return 0xFF
	end

	-- bios rom: 512k mirrored across the last 4mb of the window (duckstation
	-- bios_mirror_size = 0x400000, mask 0x7ffff).
	if physical >= Memory.BIOS_BASE and physical < 0x20000000 then
		return self.bios[band(physical - Memory.BIOS_BASE, Memory.BIOS_MASK) + 1] or 0
	end

	-- expansion region 1: pio pull-up (no cart = 0xff per byte).
	if physical >= Memory.EXP1_BASE and physical < Memory.EXP1_BASE + Memory.EXP1_SIZE then
		return 0xFF
	end
	-- expansion region 2: tty/status reads (duckstation exp2readhandler).
	if physical >= Memory.EXP2_BASE and physical < Memory.EXP2_BASE + Memory.EXP2_SIZE then
		local offset = band(physical, 0x1FFF)
		if offset == 0x21 then return 0x0C end
		return 0xFF
	end
	-- expansion region 3: open bus.
	if physical >= Memory.EXP3_BASE and physical < Memory.EXP3_BASE + Memory.EXP3_SIZE then
		return 0xFF
	end
	-- sio2: unmapped with a ps1 bios (duckstation sio2readhandler).
	if physical >= Memory.SIO2_BASE and physical < Memory.SIO2_BASE + Memory.SIO2_SIZE then
		self.busError = true
		return 0xFF
	end
	-- kseg2 cache control (exact address only; everything else in kseg2 is unmapped).
	if physical == Memory.CACHE_CTRL_ADDR then
		return band(self.cacheControl, 0xFF)
	end

	if physical == 0x1F801070 then
		return band(self.iStat, 0xFF)
	elseif physical == 0x1F801071 then
		return band(rshift(self.iStat, 8), 0xFF)
	elseif physical == 0x1F801074 then
		return band(self.iMask, 0xFF)
	elseif physical == 0x1F801075 then
		return band(rshift(self.iMask, 8), 0xFF)
	end

	-- byte-granular devices: pass original byte address so device sees correct register offset
	if physical >= 0x1F801800 and physical <= 0x1F80180F then
		return band(self.cdrom:read(physical), 0xFF)
	end
	if physical >= 0x1F801C00 and physical <= 0x1F801FFF then
		return band(self.spu:read(physical), 0xFF)
	end
	if physical >= 0x1F801100 and physical < 0x1F801130 then
		local aligned = physical - (physical % 4)
		local shift = (physical - aligned) * 8
		return band(rshift(self:readTimer(aligned), shift), 0xFF)
	end

	-- pad/sio halfword registers: byte accesses index the even lane and shift by byte offset (fixup_halfword); joy_data/sio_data replicate the byte on all lanes.
	if physical >= 0x1F801040 and physical <= 0x1F80105F then
		if physical < 0x1F801050 then
			local offset = band(physical, 0x0F)
			local reg = band(offset, 0xFFFFFFFE)
			local value
			if reg == 0x00 then
				local b = band(self:readJoypadIO(0x1F801040), 0xFF)
				value = bor(b, lshift(b, 8), lshift(b, 16), lshift(b, 24))
			elseif reg == 0x04 then
				value = self:readJoypadIO(0x1F801044)
			elseif reg == 0x08 then
				value = self:readJoypadIO(0x1F801048)
			elseif reg == 0x0A then
				value = self:readJoypadIO(0x1F80104A)
			elseif reg == 0x0E then
				value = self:readJoypadIO(0x1F80104E)
			else
				return 0xFF
			end
			return band(rshift(value, band(offset, 1) * 8), 0xFF)
		else
			local offset = band(physical, 0x0F)
			local reg = band(offset, 0xFFFFFFFE)
			local value
			if reg == 0x00 then
				value = 0xFFFFFFFF
			elseif reg == 0x04 then value = self.sio1.stat
			elseif reg == 0x08 then value = self.sio1.mode
			elseif reg == 0x0A then value = self.sio1.ctrl
			elseif reg == 0x0E then value = self.sio1.baud
			else
				return 0xFF
			end
			return band(rshift(value, band(offset, 1) * 8), 0xFF)
		end
	end

	-- memctrl2: exact register (no fixup), non-zero offsets read open bus.
	if physical >= 0x1F801060 and physical < 0x1F801070 then
		if physical == 0x1F801060 then return band(self.ramSizeReg, 0xFF) end
		return 0xFF
	end

	if physical >= Memory.HW_BASE and physical < Memory.HW_BASE + Memory.HW_SIZE then
		local aligned = physical - (physical % 4)
		local shift = (physical - aligned) * 8
		return band(rshift(self:readIO(aligned), shift), 0xFF)
	end

	-- unused memory region: open bus + bus error (psx-spx memory exceptions).
	self.busError = true
	return 0xFF
end

function Memory:read16(address)
	-- inlined kseg0/kseg1 physicaladdress fast path (see write32).
	local physical = address
	local region = band(address, 0xE0000000)
	if region == 0x80000000 or region == 0xA0000000 then
		physical = band(address, 0x1FFFFFFF)
		if physical < self.ramMappedEnd then
			physical = band(physical, self.ramMask)
		end
	else
		physical = self:physicalAddress(address)
	end
	-- fast path: ram
	if physical < Memory.RAM_SIZE then
		local p = physical + 1
		local r = self.ram
		return bor(r[p] or 0, lshift(r[p+1] or 0, 8))
	end
	-- fast path: bios (4mb mirror window)
	if physical >= Memory.BIOS_BASE and physical < 0x20000000 then
		local p = band(physical - Memory.BIOS_BASE, Memory.BIOS_MASK) + 1
		local b = self.bios
		return bor(b[p] or 0, lshift(b[p+1] or 0, 8))
	end
	if physical >= Memory.HW_BASE and physical < Memory.HW_BASE + Memory.HW_SIZE then
		-- cd/spu store bytes at their own addresses, so compose them the same way; cd has no wrap, spu wraps within its 1kb block.
		if physical >= 0x1F801800 and physical <= 0x1F80180F then
			local off = physical - 0x1F801800
			local byte0 = self.cdrom:read(0x1F801800 + off)
			local byte1 = self.cdrom:read(0x1F801800 + off + 1)
			return bor(band(byte0, 0xFF), lshift(band(byte1, 0xFF), 8))
		elseif physical >= 0x1F801C00 and physical <= 0x1F801FFF then
			local off = physical - 0x1F801C00
			local byte0 = self:read8(0x1F801C00 + band(off, 0x3FF))
			local byte1 = self:read8(0x1F801C00 + band(off + 1, 0x3FF))
			return bor(byte0, lshift(byte1, 8))
		end
		-- pad/sio halfword register index is the raw offset (0x00/0x04/0x08/0x0a/0x0e); other lanes read open bus.
		if physical >= 0x1F801040 and physical <= 0x1F80105F then
			local offset = band(physical, 0x0F)
			local value
			if physical < 0x1F801050 then
				if offset == 0x00 then
					local b = band(self:readJoypadIO(0x1F801040), 0xFF)
					value = bor(b, lshift(b, 8), lshift(b, 16), lshift(b, 24))
				elseif offset == 0x04 then value = self:readJoypadIO(0x1F801044)
				elseif offset == 0x08 then value = self:readJoypadIO(0x1F801048)
			elseif offset == 0x0A then value = self:readJoypadIO(0x1F80104A)
			elseif offset == 0x0E then value = self:readJoypadIO(0x1F80104E)
			else return 0xFFFF end
		else
			if offset == 0x00 then value = 0xFFFFFFFF
			elseif offset == 0x04 then value = self.sio1.stat
			elseif offset == 0x08 then value = self.sio1.mode
			elseif offset == 0x0A then value = self.sio1.ctrl
			elseif offset == 0x0E then value = self.sio1.baud
			else return 0xFFFF end
		end
		return band(value, 0xFFFF)
	end
	-- memctrl2: exact register (no fixup), non-zero offsets read open bus.
	if physical >= 0x1F801060 and physical < 0x1F801070 then
		if physical == 0x1F801060 then return band(self.ramSizeReg, 0xFFFF) end
		return 0xFFFF
	end
	-- hw gaps: raw open bus, no fixup shift (only the cpu truncates to access size).
	if (physical >= 0x1F801140 and physical < 0x1F801800)
		or (physical >= 0x1F801830 and physical < 0x1F801C00) then
		self:readIO(physical - (physical % 4)) -- latches busError
		return 0xFFFF
	end
	local aligned = physical - (physical % 4)
	local shift = (physical - aligned) * 8
	return band(rshift(self:readIO(aligned), shift), 0xFFFF)
	end
	-- exp2 reads return a size-agnostic constant (0x21); handled explicitly so a byte compose doesn't lose it.
	if physical >= Memory.EXP2_BASE and physical < Memory.EXP2_BASE + Memory.EXP2_SIZE then
		if band(physical, 0x1FFF) == 0x21 then return 0x0C end
		return 0xFFFF
	end
	-- everything else composes two byte reads (scratchpad/exp1/exp3/unmapped
	-- are size-truncated open-bus values, handled by read8).
	local byte0 = self:read8(address)
	local byte1 = self:read8(address + 1)
	return bor(byte0, lshift(byte1, 8))
end

function Memory:read32(address)
	-- inlined kseg0/kseg1 physicaladdress fast path (see write32).
	local physical = address
	local region = band(address, 0xE0000000)
	if region == 0x80000000 or region == 0xA0000000 then
		physical = band(address, 0x1FFFFFFF)
		if physical < self.ramMappedEnd then
			physical = band(physical, self.ramMask)
		end
	else
		physical = self:physicalAddress(address)
	end
	-- fast path: main ram (~90% of accesses) via the ram32 mirror, so a load is one array read instead of a four-byte compose.
	if physical < Memory.RAM_SIZE then
		return self.ram32[physical // 4 + 1]
	end
	-- fast path: bios rom (4mb mirror window)
	if physical >= Memory.BIOS_BASE and physical < 0x20000000 then
		local p = band(physical - Memory.BIOS_BASE, Memory.BIOS_MASK) + 1
		local b = self.bios
		return bor(b[p], lshift(b[p+1], 8), lshift(b[p+2], 16), lshift(b[p+3], 24))
	end
	-- io
	if physical >= Memory.HW_BASE and physical < Memory.HW_BASE + Memory.HW_SIZE then
		if physical >= 0x1F801800 and physical <= 0x1F80180F then
			-- cd: device-internal compose, no wrap (duckstation cdromread).
			local off = physical - 0x1F801800
			return bor(band(self.cdrom:read(0x1F801800 + off), 0xFF),
				lshift(band(self.cdrom:read(0x1F801800 + off + 1), 0xFF), 8),
				lshift(band(self.cdrom:read(0x1F801800 + off + 2), 0xFF), 16),
				lshift(band(self.cdrom:read(0x1F801800 + off + 3), 0xFF), 24))
		elseif physical >= 0x1F801C00 and physical <= 0x1F801FFF then
			-- spu: byte compose wrapped within the 1kb sbus block.
			local off = physical - 0x1F801C00
			local b0 = self:read8(0x1F801C00 + band(off, 0x3FF))
			local b1 = self:read8(0x1F801C00 + band(off + 1, 0x3FF))
			local b2 = self:read8(0x1F801C00 + band(off + 2, 0x3FF))
			local b3 = self:read8(0x1F801C00 + band(off + 3, 0x3FF))
			return bor(b0, lshift(b1, 8), lshift(b2, 16), lshift(b3, 24))
		end
		-- pad / sio0 + sio1 halfword register files: raw block offset is the
		-- register index (0x00/0x04/0x08/0x0a/0x0e); other lanes are open bus.
		if physical >= 0x1F801040 and physical <= 0x1F80105F then
			local offset = band(physical, 0x0F)
			local value
			if physical < 0x1F801050 then
				if offset == 0x00 then
					local b = band(self:readJoypadIO(0x1F801040), 0xFF)
					value = bor(b, lshift(b, 8), lshift(b, 16), lshift(b, 24))
				elseif offset == 0x04 then value = self:readJoypadIO(0x1F801044)
				elseif offset == 0x08 then value = self:readJoypadIO(0x1F801048)
				elseif offset == 0x0A then value = self:readJoypadIO(0x1F80104A)
				elseif offset == 0x0E then value = self:readJoypadIO(0x1F80104E)
				else return 0xFFFFFFFF end
			else
				if offset == 0x00 then value = 0xFFFFFFFF
				elseif offset == 0x04 then value = self.sio1.stat
				elseif offset == 0x08 then value = self.sio1.mode
				elseif offset == 0x0A then value = self.sio1.ctrl
				elseif offset == 0x0E then value = self.sio1.baud
				else return 0xFFFFFFFF end
			end
			return value
		end
		-- dma block (0x1f801080-0x0ff): the boot phase polls ch2 chcr constantly -- dispatch directly instead of walking readio's range chain.
		if physical >= 0x1F801080 and physical <= 0x1F8010FF then
			return self.dma:read(physical)
		end
		-- timer block (0x1f801100-0x12f): same semantics as readio's readtimer branch, without the range walk.
		if physical >= 0x1F801100 and physical < 0x1F801130 then
			local off = physical - 0x1F801100
			return self.timers:read(off // 0x10, off % 0x10)
		end
		-- gpu block (0x1f801810-0x81f): most-polled io region (the menu spins on gpustat) -- dispatch directly instead of readio's range chain.
		if physical >= 0x1F801810 and physical < 0x1F801820 then
			return self.gpu:read(physical - (physical % 4))
		end
		return self:readIO(physical - (physical % 4))
	end
	-- scratchpad (kuseg/kseg0 only; kseg1 falls through to open bus)
	if region ~= 0xA0000000 and physical >= Memory.SCRATCHPAD_ADDR and physical < Memory.SCRATCHPAD_ADDR + Memory.SCRATCHPAD_SIZE then
		local p = (physical - Memory.SCRATCHPAD_ADDR) + 1
		local s = self.scratchpad
		return bor(s[p] or 0, lshift(s[p+1] or 0, 8), lshift(s[p+2] or 0, 16), lshift(s[p+3] or 0, 24))
	end
	-- exp2: size-agnostic constant at its own offset (duckstation).
	if physical >= Memory.EXP2_BASE and physical < Memory.EXP2_BASE + Memory.EXP2_SIZE then
		if band(physical, 0x1FFF) == 0x21 then return 0x0C end
		return 0xFFFFFFFF
	end
	-- everything else composes four byte reads (exp1 0xff / exp3 / unmapped
	-- open-bus, all handled by read8 which also latches buserror).
	local b0 = self:read8(address)
	local b1 = self:read8(address + 1)
	local b2 = self:read8(address + 2)
	local b3 = self:read8(address + 3)
	return bor(b0, lshift(b1, 8), lshift(b2, 16), lshift(b3, 24))
end

function Memory:write8(address, value)
	-- fast path: ram (inlined physicaladdress for kseg0/kseg1; see write32).
	local physical = address
	local region = band(address, 0xE0000000)
	if region == 0x80000000 or region == 0xA0000000 then
		physical = band(address, 0x1FFFFFFF)
		if physical < self.ramMappedEnd then
			physical = band(physical, self.ramMask)
		end
	else
		physical = self:physicalAddress(address)
	end
	-- no truncation: on-die mmio registers latch the full shifted gpr on byte stores (byte enables ignored).

	if physical < Memory.RAM_SIZE then
		local v8 = band(value, 0xFF)
		if not self.cacheIsolated or band(address, 0xE0000000) == 0xA0000000 then
			if self.trackRamWrites then
				self:recordRamWrite(physical, v8, 1, "write8")
			end
			-- only touch page versions that are being used by cached code.
			local cpu = self.cpu
			if cpu then
				local page = physical // 0x10000
				if cpu._hotPages[page] then
					cpu._pageVer[page] = (cpu._pageVer[page] or 0) + 1
				end
			end
			self.ram[physical + 1] = v8
			-- keep the u32 fetch mirror in sync (single byte of the word)
			local w = physical // 4 + 1
			local sh = (physical % 4) * 8
			self.ram32[w] = bor(band(self.ram32[w], bnot(lshift(0xFF, sh))), lshift(v8, sh))
		end
		return
	end

	-- scratchpad (kuseg/kseg0 only; kseg1 falls through to open bus)
	if region ~= 0xA0000000 and physical >= Memory.SCRATCHPAD_ADDR and physical < Memory.SCRATCHPAD_ADDR + Memory.SCRATCHPAD_SIZE then
		if self.onRamWrite then self.onRamWrite(physical) end
		self.scratchpad[(physical - Memory.SCRATCHPAD_ADDR) + 1] = band(value, 0xFF)
		return
	end
	-- bios rom / exp1 / exp2 / exp3: mapped regions, writes ignored
	if (physical >= Memory.BIOS_BASE and physical < 0x20000000)
		or (physical >= Memory.EXP1_BASE and physical < Memory.EXP1_BASE + Memory.EXP1_SIZE)
		or (physical >= Memory.EXP2_BASE and physical < Memory.EXP2_BASE + Memory.EXP2_SIZE)
		or (physical >= Memory.EXP3_BASE and physical < Memory.EXP3_BASE + Memory.EXP3_SIZE) then
		return
	end
	-- sio2: unmapped with a ps1 bios
	if physical >= Memory.SIO2_BASE and physical < Memory.SIO2_BASE + Memory.SIO2_SIZE then
		self.busError = true
		return
	end
	-- kseg2 cache control (exact address only)
	if physical == Memory.CACHE_CTRL_ADDR then
		self.cacheControl = value
		return
	end

	if physical == 0x1F801070 then
		-- i_stat: on-die latch (full word), write-0-to-clear
		self.iStat = band(self.iStat, band(value, 0xFFFF))
		local p = band(self.iStat, self.iMask)
		self._irqState = (p ~= 0) and bor(p, 0x80000000) or band(self._irqState or 0, 0x80000000)
		return
	elseif physical == 0x1F801071 then
		self.iStat = band(self.iStat, band(lshift(value, 8), 0xFFFF))
		local p = band(self.iStat, self.iMask)
		self._irqState = (p ~= 0) and bor(p, 0x80000000) or band(self._irqState or 0, 0x80000000)
		return
	elseif physical == 0x1F801074 then
		self.iMask = band(value, 0xFFFF)
		local p = band(self.iStat, self.iMask)
		self._irqState = (p ~= 0) and bor(p, 0x80000000) or band(self._irqState or 0, 0x80000000)
		return
	elseif physical == 0x1F801075 then
		-- i_mask bits 11-15 are hardwired zero (11 irqs, duckstation
		-- register_write_mask 0x7ff).
		self.iMask = band(lshift(value, 8), 0x7FF)
		local p = band(self.iStat, self.iMask)
		self._irqState = (p ~= 0) and bor(p, 0x80000000) or band(self._irqState or 0, 0x80000000)
		return
	end

	-- joypad regs are 16-bit on-die: byte stores latch the full shifted source (the un-written half stays from the bus).
	if physical >= 0x1F801040 and physical <= 0x1F80104F then
		local reg = physical - (physical % 2)
		local shift = (physical - reg) * 8
		self:writeJoypadIO(reg, lshift(band(value, 0xFFFFFFFF), shift))
		return
	end
	-- sio1 (0x1f801050-0x5f): even lanes latch the shifted source halfword; sio_data/sio_stat writes ignored.
	if physical >= 0x1F801050 and physical <= 0x1F80105F then
		local offset = band(physical, 0x0F)
		local reg = band(offset, 0xFFFFFFFE)
		local shifted = band(lshift(band(value, 0xFFFF), band(offset, 1) * 8), 0xFFFF)
		if reg == 0x08 then
			self.sio1.mode = shifted
		elseif reg == 0x0A then
			self.sio1.ctrl = shifted
			if band(shifted, 0x40) ~= 0 then -- RESET -> soft reset (DuckStation)
				self.sio1.stat = 0xC5
				self.sio1.mode = 0
				self.sio1.baud = 0xDC
				self.sio1.ctrl = 0
			end
		elseif reg == 0x0E then
			self.sio1.baud = shifted
		end
		return
	end

	-- byte-granular devices: pass original byte address directly to avoid word-merge offset errors
	if physical >= 0x1F801800 and physical <= 0x1F80180F then
		self.cdrom:write(physical, band(value, 0xFF))
		return
	end
	if physical >= 0x1F801C00 and physical <= 0x1F801FFF then
		-- sbus 16-bit device: odd byte stores are silent no-ops, even byte
		-- stores latch the full 16-bit bus value (psx-spx partialwordwrites.md).
		if band(physical, 1) == 0 then
			self.spu:write(physical, band(value, 0xFFFF))
		end
		return
	end
	if physical >= 0x1F801100 and physical < 0x1F801130 then
		local aligned = physical - (physical % 4)
		local shift = (physical - aligned) * 8
		self:writeTimer(aligned, lshift(band(value, 0xFFFFFFFF), shift))
		return
	end

	-- memctrl2: exact register (no fixup); only block offset 0x00 (ram_size)
	-- accepts writes, every other offset is an unknown register (bus error).
	if physical >= 0x1F801060 and physical < 0x1F801070 then
		if physical == 0x1F801060 then
			self:writeIO(0x1F801060, band(value, 0xFFFFFFFF))
		else
			self.busError = true
		end
		return
	end

	if physical >= 0x1F801080 and physical <= 0x1F8010FF then
		-- dma regs: shifted write, but dicr write-1-to-clear must stay byte-granular via bytemask (games poke dicr+2 with byte stores).
		local aligned = physical - (physical % 4)
		local shift = (physical - aligned) * 8
		self:writeIO(aligned, lshift(band(value, 0xFFFFFFFF), shift), lshift(1, physical - aligned))
		return
	end

	if physical >= Memory.HW_BASE and physical < Memory.HW_BASE + Memory.HW_SIZE then
		-- on-die 32-bit mmio: full shifted source word latched (no rmw merge).
		local aligned = physical - (physical % 4)
		local shift = (physical - aligned) * 8
		self:writeIO(aligned, lshift(band(value, 0xFFFFFFFF), shift))
		return
	end

	-- unused memory region: bus error (write ignored).
	self.busError = true
end

function Memory:write16(address, value)
	-- inlined kseg0/kseg1 physicaladdress fast path (see write32).
	local physical = address
	local region = band(address, 0xE0000000)
	if region == 0x80000000 or region == 0xA0000000 then
		physical = band(address, 0x1FFFFFFF)
		if physical < self.ramMappedEnd then
			physical = band(physical, self.ramMask)
		end
	else
		physical = self:physicalAddress(address)
	end
	-- fast path: ram (mirror write8/write32; keeps the u32 fetch mirror in sync)
	if physical < Memory.RAM_SIZE then
		if not self.cacheIsolated or band(address, 0xE0000000) == 0xA0000000 then
			if self.trackRamWrites then
				self:recordRamWrite(physical, band(value, 0xFFFF), 2, "write16")
			end
			-- inlined block invalidation (see write8).
			local cpu = self.cpu
			if cpu then
				local page = physical // 0x10000
				if cpu._hotPages[page] then
					cpu._pageVer[page] = (cpu._pageVer[page] or 0) + 1
				end
			end
			local p = physical + 1
			local r = self.ram
			r[p]   = band(value, 0xFF)
			r[p+1] = band(rshift(value, 8), 0xFF)
			local w = physical // 4 + 1
			local sh = (physical % 4) * 8
			self.ram32[w] = bor(band(self.ram32[w], bnot(lshift(0xFFFF, sh))), lshift(band(value, 0xFFFF), sh))
		end
		return
	end
	-- scratchpad (kuseg/kseg0 only)
	if region ~= 0xA0000000 and physical >= Memory.SCRATCHPAD_ADDR and physical < Memory.SCRATCHPAD_ADDR + Memory.SCRATCHPAD_SIZE then
		local p = (physical - Memory.SCRATCHPAD_ADDR) + 1
		self.scratchpad[p] = band(value, 0xFF)
		self.scratchpad[p + 1] = band(rshift(value, 8), 0xFF)
		return
	end
	-- bios rom / exp1 / exp2 / exp3: writes ignored
	if (physical >= Memory.BIOS_BASE and physical < 0x20000000)
		or (physical >= Memory.EXP1_BASE and physical < Memory.EXP1_BASE + Memory.EXP1_SIZE)
		or (physical >= Memory.EXP2_BASE and physical < Memory.EXP2_BASE + Memory.EXP2_SIZE)
		or (physical >= Memory.EXP3_BASE and physical < Memory.EXP3_BASE + Memory.EXP3_SIZE) then
		return
	end
	-- sio2: unmapped
	if physical >= Memory.SIO2_BASE and physical < Memory.SIO2_BASE + Memory.SIO2_SIZE then
		self.busError = true
		return
	end
	-- kseg2 cache control
	if physical == Memory.CACHE_CTRL_ADDR then
		self.cacheControl = value
		return
	end
	-- cd-rom: byte-granular, decompose to preserve per-register semantics
	if physical >= 0x1F801800 and physical <= 0x1F80180F then
		self:write8(address, band(value, 0xFF))
		self:write8(address + 1, band(rshift(value, 8), 0xFF))
		return
	end
	-- spu: sbus halfword write (full 16-bit value latched on /wr0)
	if physical >= 0x1F801C00 and physical <= 0x1F801FFF then
		self.spu:write(physical, band(value, 0xFFFF))
		return
	end
	-- joypad regs are independent 16-bit registers at halfword offsets; dispatch directly so ctrl/baud writes land in the right register (other offsets are silent no-ops).
	if physical >= 0x1F801040 and physical <= 0x1F80104F then
		self:writeJoypadIO(physical, value)
		return
	end
	-- sio1 register file: halfword writes land on the raw register lanes
	-- (0x50/0x58/0x5a/0x5e); sio_data and sio_stat writes are ignored.
	if physical >= 0x1F801050 and physical <= 0x1F80105F then
		local reg = band(physical, 0x0F)
		local v16 = band(value, 0xFFFF)
		if reg == 0x08 then
			self.sio1.mode = v16
		elseif reg == 0x0A then
			self.sio1.ctrl = v16
			if band(v16, 0x40) ~= 0 then -- RESET -> soft reset (DuckStation)
				self.sio1.stat = 0xC5
				self.sio1.mode = 0
				self.sio1.baud = 0xDC
				self.sio1.ctrl = 0
			end
		elseif reg == 0x0E then
			self.sio1.baud = v16
		end
		return
	end

	-- memctrl2: exact register (no fixup); only block offset 0x00 (ram_size)
	-- accepts writes, every other offset is an unknown register (bus error).
	if physical >= 0x1F801060 and physical < 0x1F801070 then
		if physical == 0x1F801060 then
			self:writeIO(0x1F801060, band(value, 0xFFFFFFFF))
		else
			self.busError = true
		end
		return
	end

	if physical >= 0x1F801080 and physical <= 0x1F8010FF then
		-- dma registers: on-die shifted write; halfword-granular dicr flags
		-- preserved via bytemask (see write8).
		local aligned = physical - (physical % 4)
		local shift = (physical - aligned) * 8
		self:writeIO(aligned, lshift(band(value, 0xFFFFFFFF), shift), lshift(3, physical - aligned))
		return
	end

	if physical >= Memory.HW_BASE and physical < Memory.HW_BASE + Memory.HW_SIZE then
		-- on-die 32-bit mmio: full shifted source word latched (no rmw merge).
		local aligned = physical - (physical % 4)
		local shift = (physical - aligned) * 8
		self:writeIO(aligned, lshift(band(value, 0xFFFFFFFF), shift))
		return
	end

	-- unused memory region: bus error (write ignored).
	self.busError = true
end

function Memory:write32(address, value)
	-- fast path: ram (inlined physicaladdress for the common kseg0/kseg1
	-- case; the method call on every write was ~18% of movie wall).
	local physical = address
	local region = band(address, 0xE0000000)
	if region == 0x80000000 or region == 0xA0000000 then
		physical = band(address, 0x1FFFFFFF)
		if physical < self.ramMappedEnd then
			physical = band(physical, self.ramMask)
		end
	else
		physical = self:physicalAddress(address)
	end
	if physical < Memory.RAM_SIZE then
		-- inline the cache-isolation gate (cacheisolated off by default).
		if not self.cacheIsolated or band(address, 0xE0000000) == 0xA0000000 then
			if self.trackRamWrites then
				self:recordRamWrite(physical, value, 4, "write32")
			end
			-- inlined block invalidation (see write8): the closure call + method
			-- call + modulo per write was measurable wall on the dma-heavy paths.
			local cpu = self.cpu
			if cpu then
				local page = physical // 0x10000
				if cpu._hotPages[page] then
					cpu._pageVer[page] = (cpu._pageVer[page] or 0) + 1
				end
			end
			if self.traceSuspiciousRamWrites then
				self:traceSuspiciousWordWrite(physical, value)
			end
			local p = physical + 1
			local r = self.ram
			r[p]   = band(value, 0xFF)
			r[p+1] = band(rshift(value, 8), 0xFF)
			r[p+2] = band(rshift(value, 16), 0xFF)
			r[p+3] = band(rshift(value, 24), 0xFF)
			self.ram32[physical // 4 + 1] = band(value, 0xFFFFFFFF)
		end
		return
	end
	-- cd-rom: byte-granular, word writes decompose into 4 byte writes
	if physical >= 0x1F801800 and physical <= 0x1F80180F then
		self:write8(address, band(value, 0xFF))
		self:write8(address + 1, band(rshift(value, 8), 0xFF))
		self:write8(address + 2, band(rshift(value, 16), 0xFF))
		self:write8(address + 3, band(rshift(value, 24), 0xFF))
		return
	end
	-- spu: sbus 16-bit, word writes hit two consecutive halfwords
	if physical >= 0x1F801C00 and physical <= 0x1F801FFF then
		self.spu:write(physical, band(value, 0xFFFF))
		if band(physical, 0x3FF) < 0x3FE then
			self.spu:write(physical + 2, band(rshift(value, 16), 0xFFFF))
		end
		return
	end
	-- io
	if physical >= Memory.HW_BASE and physical < Memory.HW_BASE + Memory.HW_SIZE then
		-- pad/sio word writes: register index is the raw offset (0x00/0x04/0x08/0x0a/0x0e); other lanes are no-ops.
		if physical >= 0x1F801040 and physical <= 0x1F80105F then
			local offset = band(physical, 0x0F)
			local v16 = band(value, 0xFFFF)
			if physical < 0x1F801050 then
				if offset == 0x00 then self:writeJoypadIO(0x1F801040, v16)
				elseif offset == 0x08 then self:writeJoypadIO(0x1F801048, v16)
				elseif offset == 0x0A then self:writeJoypadIO(0x1F80104A, v16)
				elseif offset == 0x0E then self:writeJoypadIO(0x1F80104E, v16)
				end
			else
				if offset == 0x08 then
					self.sio1.mode = v16
				elseif offset == 0x0A then
					self.sio1.ctrl = v16
					if band(v16, 0x40) ~= 0 then -- RESET -> soft reset
						self.sio1.stat = 0xC5
						self.sio1.mode = 0
						self.sio1.baud = 0xDC
						self.sio1.ctrl = 0
					end
				elseif offset == 0x0E then
					self.sio1.baud = v16
				end
			end
			return
		end
		self:writeIO(physical - (physical % 4), value)
		return
	end
	-- scratchpad (kuseg/kseg0 only)
	if region ~= 0xA0000000 and physical >= Memory.SCRATCHPAD_ADDR and physical < Memory.SCRATCHPAD_ADDR + Memory.SCRATCHPAD_SIZE then
		if self.onRamWrite then self.onRamWrite(physical) end
		local p = (physical - Memory.SCRATCHPAD_ADDR) + 1
		local s = self.scratchpad
		s[p]   = band(value, 0xFF)
		s[p+1] = band(rshift(value, 8), 0xFF)
		s[p+2] = band(rshift(value, 16), 0xFF)
		s[p+3] = band(rshift(value, 24), 0xFF)
		return
	end
	-- bios rom / exp1 / exp2 / exp3: writes ignored
	if (physical >= Memory.BIOS_BASE and physical < 0x20000000)
		or (physical >= Memory.EXP1_BASE and physical < Memory.EXP1_BASE + Memory.EXP1_SIZE)
		or (physical >= Memory.EXP2_BASE and physical < Memory.EXP2_BASE + Memory.EXP2_SIZE)
		or (physical >= Memory.EXP3_BASE and physical < Memory.EXP3_BASE + Memory.EXP3_SIZE) then
		return
	end
	-- sio2: unmapped
	if physical >= Memory.SIO2_BASE and physical < Memory.SIO2_BASE + Memory.SIO2_SIZE then
		self.busError = true
		return
	end
	-- kseg2 cache control
	if physical == Memory.CACHE_CTRL_ADDR then
		self.cacheControl = value
		return
	end
	-- unused memory region: bus error (write ignored).
	self.busError = true
end

function Memory:writeBytes(address, data)
	for index = 1, #data do
		self:write8(address + index - 1, data:byte(index))
	end
end

function Memory:readTimer(address)
	local offset = address - 0x1F801100
	local index = math.floor(offset / 0x10)
	local registerOffset = offset % 0x10
	return self.timers:read(index, registerOffset)
end

function Memory:writeTimer(address, value)
	local offset = address - 0x1F801100
	local index = math.floor(offset / 0x10)
	local registerOffset = offset % 0x10
	self.timers:write(index, registerOffset, value)
end

-- edge-triggered interrupt lines (duckstation setlinestate): i_stat latches only the 0->1 edge; 1->0 never clears it.
function Memory:setInterruptLine(bitIndex, state)
	local bit = lshift(1, bitIndex)
	local prevState = self.iLineState
	if state then
		self.iLineState = bor(self.iLineState, bit)
	else
		self.iLineState = band(self.iLineState, bnot(bit))
	end
	if self.iLineState == prevState then
		return
	end
	if state then
		local edge = band(bxor(prevState, self.iLineState), self.iLineState)
		if edge ~= 0 then
			self.iStat = bor(self.iStat, edge)
		end
	end
	-- keep the block engine's cached pending-irq mask in sync (read per
	-- instruction by runblock; band(iStat, iMask) is identical).
	local p = band(self.iStat, self.iMask)
	self._irqState = (p ~= 0) and bor(p, 0x80000000) or band(self._irqState or 0, 0x80000000)
	self:tracePendingMaskIfChanged(string.format("line bit=%d -> %s", bitIndex, tostring(state)))
end

-- raise = assert the device line (every duckstation device pushes
-- setlinestate(irq, true) on its event; the edge latch decides the status bit).
function Memory:raiseInterrupt(bitIndex)
	self:setInterruptLine(bitIndex, true)
	if self.traceInterruptRegisters then
		local pending = band(self.iStat, self.iMask)
		print(string.format("[ps1-irq] raise bit=%d istat=%04X imask=%04X pending=%04X", bitIndex, self.iStat, self.iMask, pending))
		self.lastPendingMask = pending
	else
		self.lastPendingMask = band(self.iStat, self.iMask)
	end
end

function Memory:clearInterrupt(bitIndex)
	local bit = lshift(1, bitIndex)
	self.iStat = band(self.iStat, bnot(bit))
	local p = band(self.iStat, self.iMask)
	self._irqState = (p ~= 0) and bor(p, 0x80000000) or band(self._irqState or 0, 0x80000000)
	-- interrupt service also drops the device line (the ack was consumed), so
	-- the next device event re-latches on a fresh 0->1 edge.
	self.iLineState = band(self.iLineState, bnot(bit))
	self:tracePendingMaskIfChanged(string.format("clear bit=%d", bitIndex))
end

function Memory:getPendingInterruptMask()
	return band(self.iStat, self.iMask)
end

function Memory:advanceCycles(cycles)
	self.cycleCount += cycles
	-- /ack pulse is short (~450 cycles); the dsr line must actually release -- the driver waits for it.
	local joypad = self.joypad
	-- cached (ackAsserted or pendingPadIrqCycle ~= nil) gate: the block engine
	-- polls this single field per instruction; refreshed at every mutation.
	if joypad._needsStep then
		if joypad.ackAsserted and self.cycleCount - joypad.ackCycle > 450 then
			joypad.ackAsserted = false
			joypad._needsStep = joypad.pendingPadIrqCycle ~= nil
		end
		-- delayed pad irq fire: the /ack edge latches joy_stat bit 9 and re-asserts dsr bit 7 at this instant (the bios isr reads both set).
		if joypad.pendingPadIrqCycle and self.cycleCount >= joypad.pendingPadIrqCycle then
			joypad.pendingPadIrqCycle = nil
			joypad.irqFlag = true
			joypad.ackAsserted = true
			joypad.ackCycle = self.cycleCount
			joypad._needsStep = true
			-- /ack asserts the pad line (duckstation pad::triggerirq); the driver
			-- re-arms it with a joy_ctrl.ack write (line deassert below).
			self:setInterruptLine(7, true)
		end
	end
	-- batch peripheral stepping over a small cycle window: preserves aggregate timing, keeps the per-instruction path cheap.
	self.flux += cycles
	if self.flux >= self._periphBatch then
		local batch = self.flux
		self.flux = 0
		-- spu steps first so it drains the cd audio fifo before the cdrom fills it; batching only changes delivery granularity.
		self.spu:step(batch)
		self.gpu:step(batch)
		self.cdrom:step(batch)
		self.timers:advance(batch)
	end
	-- dma tick-budget slicing: only check when dma is actually active.
	-- the common case (no dma transfer in progress) skips both branches.
	local dma = self.dma
	if dma.haltTicksRemaining > 0 then
		dma:consumeHaltTicks(cycles)
	elseif dma.resumePending and not dma.inTickCharge then
		dma:resumeHalted()
	end
	-- device-originated bus accesses (dma, cd-rom step) must not leave a
	-- latched bus error for the next cpu load/store.
	if self.busError then self.busError = false end
end

function Memory:readIO(address)
	-- memory control registers (0x1f801000-0x1f80103f): 9 word registers
	-- (duckstation memctrl_reg_count); offsets 0x24-0x3f read as 0.
	if address >= 0x1F801000 and address < 0x1F801040 then
		local index = (address - 0x1F801000) // 4
		if index < 9 then return self.memCtrlRegs[index + 1] or 0 end
		return 0
	end
	-- pad/sio0: 32-bit reads of a word spanning two 16-bit registers return the merged pair (mode | ctrl<<16, gap | baud<<16).
	if address >= 0x1F801040 and address < 0x1F801050 then
		if address == 0x1F801048 then
			return bor(self:readJoypadIO(0x1F801048), lshift(self:readJoypadIO(0x1F80104A), 16))
		elseif address == 0x1F80104C then
			return lshift(self:readJoypadIO(0x1F80104E), 16)
		end
		return self:readJoypadIO(address)
	end
	-- sio1 (0x1f801050-0x5f): serial port register file (duckstation sio.cpp).
	if address >= 0x1F801050 and address < 0x1F801060 then
		local offset = address - 0x1F801050
		local reg = offset - (offset % 2)
		if reg == 0x00 then
			return 0xFFFFFFFF -- SIO_DATA always reads 0xFF
		elseif reg == 0x04 then return self.sio1.stat
		elseif reg == 0x08 then return self.sio1.mode
		elseif reg == 0x0A then return self.sio1.ctrl
		elseif reg == 0x0E then return self.sio1.baud
		end
		return 0xFFFFFFFF
	end
	-- memctrl2 (0x1f801060-0x6f): only offset 0 is ram_size; every other offset reads open bus.
	if address >= 0x1F801060 and address < 0x1F801070 then
		if address == 0x1F801060 then return self.ramSizeReg end
		return 0xFFFFFFFF
	end
	if address == 0x1F801070 then
		return self.iStat
	elseif address == 0x1F801074 then
		return self.iMask
	elseif address >= 0x1F801078 and address < 0x1F801080 then
		-- intc block: unknown registers read open bus (no bus error)
		return 0xFFFFFFFF
	elseif address >= 0x1F801080 and address <= 0x1F8010FF then
		return self.dma:read(address)
	elseif address >= 0x1F801100 and address < 0x1F801130 then
		return self:readTimer(address)
	elseif address >= 0x1F801130 and address < 0x1F801140 then
		-- timers block tail: unknown register, open bus (duckstation)
		return 0xFFFFFFFF
	elseif address >= 0x1F801140 and address < 0x1F801800 then
		-- io gap: unmapped, bus error
		self.busError = true
		return 0xFFFFFFFF
	elseif address >= 0x1F801800 and address <= 0x1F80180F then
		return self.cdrom:read(address)
	elseif address >= 0x1F801810 and address < 0x1F801820 then
		return self.gpu:read(address - (address % 4))
	elseif address >= 0x1F801820 and address <= 0x1F80182F then
		if address == 0x1F801820 then
			return self.mdec:readData()
		elseif address == 0x1F801824 then
			return self.mdec:readStatus()
		end
		return 0xFFFFFFFF
	elseif address >= 0x1F801830 and address < 0x1F801C00 then
		-- io gap: unmapped, bus error
		self.busError = true
		return 0xFFFFFFFF
	elseif address >= 0x1F801C00 and address <= 0x1F801FFF then
		return self.spu:read(address)
	end
	self.busError = true
	return 0xFFFFFFFF
end

function Memory:writeIO(address, value, byteMask)
	byteMask = byteMask or 0xF
	value = band(value, 0xFFFFFFFF)
	-- memory control (0x1f801000-0x3f): 9 word registers with per-register write masks; 0x24-0x3f dropped.
	if address >= 0x1F801000 and address < 0x1F801040 then
		local index = (address - 0x1F801000) // 4
		if index < 9 then
			local writeMask = 0xFFFFFFFF
			if index == 8 then
				writeMask = 0x0003FFFF -- COMDELAY
			elseif index >= 2 then
				writeMask = 0xAF1FFFFF -- MEMDELAY
			end
			self.memCtrlRegs[index + 1] = bor(band(self.memCtrlRegs[index + 1] or 0, bnot(writeMask)), band(value, writeMask))
		end
		return
	end
	-- pad / sio0 joypad
	if address >= 0x1F801040 and address < 0x1F801050 then
		self:writeJoypadIO(address, value)
		return
	end
	-- sio1 serial port register file
	if address >= 0x1F801050 and address < 0x1F801060 then
		local offset = address - 0x1F801050
		local reg = offset - (offset % 2)
		local v16 = band(value, 0xFFFF)
		if reg == 0x08 then
			self.sio1.mode = v16
		elseif reg == 0x0A then
			self.sio1.ctrl = v16
			if band(v16, 0x40) ~= 0 then -- RESET -> soft reset (DuckStation)
				self.sio1.stat = 0xC5
				self.sio1.mode = 0
				self.sio1.baud = 0xDC
				self.sio1.ctrl = 0
			end
		elseif reg == 0x0E then
			self.sio1.baud = v16
		end
		return
	end
	-- memctrl2: ram size register; the rest of the block is unknown
	if address >= 0x1F801060 and address < 0x1F801070 then
		if address == 0x1F801060 then
			self.ramSizeReg = value
			-- remap the ram mirror window (duckstation updatemappedramsize):
			-- window 4 = 2mb mapped (6mb unmapped), window 5/7 = 8mb mapped.
			local window = band(rshift(value, 1), 7)
			if window == 4 then
				self.ramMappedEnd = 0x200000
			elseif window == 5 or window == 7 then
				self.ramMappedEnd = 0x800000
			end
			self.dma.ramMappedEnd = self.ramMappedEnd
		else
			self.busError = true
		end
		return
	end
	if address == 0x1F801070 then
		-- ps1: write-0-to-clear (writing 0 clears the bit, 1 leaves unchanged)
		local before = self.iStat
		self.iStat = band(self.iStat, band(value, 0xFFFF))
		local p = band(self.iStat, self.iMask)
		self._irqState = (p ~= 0) and bor(p, 0x80000000) or band(self._irqState or 0, 0x80000000)
		self:traceIrqRegisters(string.format("write I_STAT value=%04X before=%04X", band(value, 0xFFFF), before))
		self:tracePendingMaskIfChanged("write I_STAT")
		return
	elseif address == 0x1F801074 then
		local before = self.iMask
		-- i_mask bits 11-15 hardwired zero (duckstation register_write_mask
		-- 0x7ff: 11 irqs).
		self.iMask = band(value, 0x7FF)
		local p = band(self.iStat, self.iMask)
		self._irqState = (p ~= 0) and bor(p, 0x80000000) or band(self._irqState or 0, 0x80000000)
		self:traceIrqRegisters(string.format("write I_MASK value=%04X before=%04X", self.iMask, before))
		self:tracePendingMaskIfChanged("write I_MASK")
		return
	elseif address >= 0x1F801078 and address < 0x1F801080 then
		-- intc block: unknown registers ignored (duckstation writeregister default)
		return
	elseif address >= 0x1F801080 and address <= 0x1F8010FF then
		self.dma:write(address, value, byteMask)
		return
	elseif address >= 0x1F801100 and address < 0x1F801130 then
		self:writeTimer(address, value)
		return
	elseif address >= 0x1F801130 and address < 0x1F801140 then
		-- timers block tail: ignored (duckstation timerswrite out of range)
		return
	elseif address >= 0x1F801140 and address < 0x1F801800 then
		self.busError = true
		return
	elseif address >= 0x1F801800 and address <= 0x1F80180F then
		self.cdrom:write(address, value)
		return
	elseif address >= 0x1F801810 and address < 0x1F801820 then
		self.gpu:write(address - (address % 4), value)
		return
	elseif address >= 0x1F801820 and address <= 0x1F80182F then
		if address == 0x1F801820 then
			self.mdec:writeData(value)
		elseif address == 0x1F801824 then
			self.mdec:writeControl(value)
		end
		return
	elseif address >= 0x1F801830 and address < 0x1F801C00 then
		self.busError = true
		return
	elseif address >= 0x1F801C00 and address <= 0x1F801FFF then
		self.spu:write(address, band(value, 0xFFFF))
		return
	end

	self.busError = true
	self:tracePendingMaskIfChanged("writeIO other")
end

return Memory