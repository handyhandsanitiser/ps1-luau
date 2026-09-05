-- memory-bus model used by the differential checks: wraps a memory instance for device state but
-- keeps its own address decode so the two paths don't share the same mistake.  covers the four
-- address spaces, ram mirrors, scratchpad and bios, expansion areas, mmio partial accesses, cache
-- control, and bus-error latching.  cpu exceptions are left to the caller; this layer only records
-- buserror.  interface: memref.new(world); ref:read8/16/32(addr) and write8/16/32(addr, value)
-- (both set ref.buserror).  hashed state: rammappedend, rammask, memctrlregs, ramsizereg, sio1,
-- cachecontrol, buserror.
local MemRef = {}
MemRef.__index = MemRef

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local lshift = bit32.lshift
local rshift = bit32.rshift

-- duckstation constants (bus.h)
local RAM_SIZE = 0x200000
local RAM_MASK = 0x1FFFFF
local SCRATCHPAD_ADDR = 0x1F800000
local SCRATCHPAD_SIZE = 0x400
local BIOS_BASE = 0x1FC00000
local BIOS_MASK = 0x7FFFF
local EXP1_BASE = 0x1F000000
local EXP1_SIZE = 0x800000
local EXP2_BASE = 0x1F802000
local EXP2_SIZE = 0x2000
local EXP3_BASE = 0x1FA00000
local EXP3_SIZE = 0x200000
local SIO2_BASE = 0x1F808000
local SIO2_SIZE = 0x1000
local HW_BASE = 0x1F801000
local HW_SIZE = 0x1000
local CACHE_CTRL_ADDR = 0xFFFE0130

local MEMDELAY_WRITE_MASK = 0xAF1FFFFF
local COMDELAY_WRITE_MASK = 0x0003FFFF

-- fixup macros (bus.cpp lines 182-192)
local function fixupHalfwordOffset(size, offset)
	return (size >= 2) and offset or band(offset, bnot(1))
end
local function fixupHalfwordReadValue(size, offset, value)
	if size >= 2 then return value end
	return rshift(value, band(offset, 1) * 8)
end
local function fixupHalfwordWriteValue(size, offset, value)
	if size >= 2 then return value end
	return lshift(value, band(offset, 1) * 8)
end
local function fixupWordOffset(size, offset)
	return (size == 4) and offset or band(offset, bnot(3))
end
local function fixupWordReadValue(size, offset, value)
	if size == 4 then return value end
	return rshift(value, band(offset, 3) * 8)
end
local function fixupWordWriteValue(size, offset, value)
	if size == 4 then return value end
	return lshift(value, band(offset, 3) * 8)
end

-- the 16-byte-block hw handler table (duckstation gethardwareregisterhandlertable): "memctrl", "pad", "sio", "memctrl2", "intc", "dma", "timers", "cdrom", "gpu", "mdec", "spu", or nil (gap -> unmapped/bus error).
local HW_TABLE = {}
do
	local function set(raddr, rsize, kind)
		for t = raddr, raddr + rsize - 1, 16 do
			HW_TABLE[band(t, 0xFFF) // 16] = kind
		end
	end
	set(0x1F801000, 0x40, "memctrl")
	set(0x1F801040, 0x10, "pad")
	set(0x1F801050, 0x10, "sio")
	set(0x1F801060, 0x10, "memctrl2")
	set(0x1F801070, 0x10, "intc")
	set(0x1F801080, 0x80, "dma")
	set(0x1F801100, 0x40, "timers")
	set(0x1F801800, 0x10, "cdrom")
	set(0x1F801810, 0x10, "gpu")
	set(0x1F801820, 0x10, "mdec")
	set(0x1F801C00, 0x400, "spu")
end

-- unknownreadhandler: registered device, unknown register -> open bus, no error.  unknownwritehandler: -> bus error.  unmapped handlers: unregistered page -> bus error both.
local function unknownRead(self)
	return 0xFFFFFFFF
end

local function unknownWrite(self)
	self.busError = true
	return
end

local function unmappedRead(self)
	self.busError = true
	return 0xFFFFFFFF
end

function MemRef.new(world)
	local self = setmetatable({}, MemRef)
	self.world = world
	self.ram = world.ram
	self.scratchpad = world.scratchpad
	self.bios = world.bios
	self.ramMappedEnd = world.ramMappedEnd or 0x800000
	self.ramMask = world.ramMask or RAM_MASK
	self.memCtrlRegs = table.create(9, 0)
	self.ramSizeReg = 0x00000B88
	self.sio1 = { stat = 0xC5, mode = 0, ctrl = 0, baud = 0xDC }
	self.cacheControl = 0
	self.busError = false
	return self
end

-- reset the reference to a fresh state (before replaying a recorded stream).
function MemRef:reset()
	self.ramMappedEnd = 0x800000
	self.ramMask = RAM_MASK
	self.memCtrlRegs = table.create(9, 0)
	self.ramSizeReg = 0x00000B88
	self.sio1 = { stat = 0xC5, mode = 0, ctrl = 0, baud = 0xDC }
	self.cacheControl = 0
	self.busError = false
end

-- decode a virtual address into (physical, region): "ram", "scratchpad", "bios", "exp1", "exp2", "exp3", "sio2", "hw", "cache", "unmapped".
function MemRef:decode(address)
	address = band(address, 0xFFFFFFFF)
	local region = band(address, 0xE0000000)
	local physical = address
	if region == 0x80000000 or region == 0xA0000000 then
		physical = band(address, 0x1FFFFFFF)
	end
	local seg = region

	-- scratchpad exists only in kuseg/kseg0 (psx-spx memorymap.md).
	if physical >= SCRATCHPAD_ADDR and physical < SCRATCHPAD_ADDR + 0x1000 then
		if seg == 0x80000000 or seg == 0x00000000 or seg == 0x20000000 or seg == 0x40000000 or seg == 0x60000000 then
			if physical < SCRATCHPAD_ADDR + SCRATCHPAD_SIZE then
				return physical, "scratchpad"
			end
			return physical, "unknown"
		end
		return physical, "unmapped"
	end

	if physical < self.ramMappedEnd then
		return band(physical, self.ramMask), "ram"
	end

	if physical >= EXP1_BASE and physical < EXP1_BASE + EXP1_SIZE then
		return physical, "exp1"
	end
	if physical >= BIOS_BASE and physical < BIOS_BASE + 0x400000 then
		return physical, "bios"
	end
	if physical >= HW_BASE and physical < HW_BASE + HW_SIZE then
		return physical, "hw"
	end
	if physical >= EXP2_BASE and physical < EXP2_BASE + EXP2_SIZE then
		return physical, "exp2"
	end
	if physical >= SIO2_BASE and physical < SIO2_BASE + SIO2_SIZE then
		return physical, "sio2"
	end
	if physical >= EXP3_BASE and physical < EXP3_BASE + EXP3_SIZE then
		return physical, "exp3"
	end
	if physical >= 0xFFFE0000 and physical < 0xFFFE1000 then
		return physical, "cache"
	end
	return physical, "unmapped"
end

-- block-relative offset for a hw device (duckstation masks each device by
-- its own region size).
local HW_MASK = {
	memctrl = 0x3F,
	pad = 0x0F,
	sio = 0x0F,
	memctrl2 = 0x0F,
	intc = 0x0F,
	dma = 0x7F,
	timers = 0x3F,
	cdrom = 0x0F,
	gpu = 0x0F,
	mdec = 0x0F,
	spu = 0x3FF,
}

-- hw region handler with fixup semantics. size: 1=byte 2=halfword 4=word.
local function hwRead(self, physical, size)
	local tableIndex = band(rshift(physical, 4), 0xFF)
	local kind = HW_TABLE[tableIndex]
	if kind == nil then
		-- hw gap: unregistered page within the hw region -> unmapped (bus error)
		return unmappedRead(self)
	end
	local offset = band(physical, HW_MASK[kind])

	if kind == "memctrl" then
		local index = fixupWordOffset(size, offset) // 4
		if index >= 9 then return 0 end
		local value = self.memCtrlRegs[index + 1] or 0
		return fixupWordReadValue(size, offset, value)
	elseif kind == "pad" then
		local reg = fixupHalfwordOffset(size, offset)
		local value
		if reg == 0x00 then
			-- joy_data: the byte is replicated across all lanes (pad.cpp
			-- readregister returns the byte on all four byte lanes).
			local b = band(self.world:readJoypadIO(0x1F801040), 0xFF)
			value = bor(b, lshift(b, 8), lshift(b, 16), lshift(b, 24))
		elseif reg == 0x04 then
			value = self.world:readJoypadIO(0x1F801044)
		elseif reg == 0x08 then
			value = self.world:readJoypadIO(0x1F801048)
		elseif reg == 0x0A then
			value = self.world:readJoypadIO(0x1F80104A)
		elseif reg == 0x0E then
			value = self.world:readJoypadIO(0x1F80104E)
		else
			return 0xFFFFFFFF
		end
		return fixupHalfwordReadValue(size, offset, value)
	elseif kind == "sio" then
		local reg = fixupHalfwordOffset(size, offset)
		local value
		if reg == 0x00 then
			-- sio_data always reads 0xff on all four byte lanes (sio.cpp)
			value = 0xFFFFFFFF
		elseif reg == 0x04 then
			value = self.sio1.stat
		elseif reg == 0x08 then
			value = self.sio1.mode
		elseif reg == 0x0A then
			value = self.sio1.ctrl
		elseif reg == 0x0E then
			value = self.sio1.baud
		else
			return 0xFFFFFFFF
		end
		return fixupHalfwordReadValue(size, offset, value)
	elseif kind == "memctrl2" then
		-- exact register (duckstation memctrl2read/write: no fixup -- the raw
		-- block offset must be 0x00; any other offset is an unknown register).
		if offset == 0x00 then
			return self.ramSizeReg
		end
		return unknownRead(self)
	elseif kind == "intc" then
		local wordOffset = fixupWordOffset(size, offset)
		local value
		if wordOffset == 0x00 then
			value = self.world.iStat or 0
		elseif wordOffset == 0x04 then
			value = self.world.iMask or 0
		else
			-- duckstation applies fixup_word_read_value to whatever
			-- readregister returns, including its 0xffffffff default.
			return fixupWordReadValue(size, offset, 0xFFFFFFFF)
		end
		return fixupWordReadValue(size, offset, value)
	elseif kind == "dma" then
		local value = self.world.dma:read(0x1F801080 + fixupWordOffset(size, offset))
		return fixupWordReadValue(size, offset, value)
	elseif kind == "timers" then
		local aligned = fixupWordOffset(size, offset)
		local timerIndex = aligned // 0x10
		local regOffset = band(aligned, 0x0F)
		if timerIndex >= 3 then return fixupWordReadValue(size, offset, 0xFFFFFFFF) end
		local value = self.world.timers:read(timerIndex, regOffset)
		return fixupWordReadValue(size, offset, value)
	elseif kind == "cdrom" then
		-- byte-granular: compose consecutive byte register reads with no wrap (duckstation cdromread calls readregister(offset+i); unknown offsets return 0).
		local value = 0
		for i = 0, size - 1 do
			value = bor(value, lshift(band(self.world.cdrom:read(0x1F801800 + offset + i), 0xFF), i * 8))
		end
		return value
	elseif kind == "gpu" then
		local aligned = fixupWordOffset(size, offset)
		if aligned == 0x00 or aligned == 0x04 then
			local value = self.world.gpu:read(0x1F801810 + aligned)
			return fixupWordReadValue(size, offset, value)
		end
		return fixupWordReadValue(size, offset, 0xFFFFFFFF)
	elseif kind == "mdec" then
		local aligned = fixupWordOffset(size, offset)
		if aligned == 0x00 then
			return fixupWordReadValue(size, offset, self.world.mdec:readData())
		elseif aligned == 0x04 then
			return fixupWordReadValue(size, offset, self.world.mdec:readStatus())
		end
		return fixupWordReadValue(size, offset, 0xFFFFFFFF)
	elseif kind == "spu" then
		local base = 0x1F801C00
		if size == 4 then
			local b0 = self.world.spu:read(base + band(offset, 0x3FF))
			local b1 = self.world.spu:read(base + band(offset + 1, 0x3FF))
			local b2 = self.world.spu:read(base + band(offset + 2, 0x3FF))
			local b3 = self.world.spu:read(base + band(offset + 3, 0x3FF))
			return bor(band(b0, 0xFF), lshift(band(b1, 0xFF), 8), lshift(band(b2, 0xFF), 16), lshift(band(b3, 0xFF), 24))
		elseif size == 2 then
			local lo = self.world.spu:read(base + band(offset, 0x3FF))
			local hi = self.world.spu:read(base + band(offset + 1, 0x3FF))
			return bor(band(lo, 0xFF), lshift(band(hi, 0xFF), 8))
		else
			return band(self.world.spu:read(base + band(offset, 0x3FF)), 0xFF)
		end
	end
	return unknownRead(self)
end

local function hwWrite(self, physical, size, value)
	local tableIndex = band(rshift(physical, 4), 0xFF)
	local kind = HW_TABLE[tableIndex]
	if kind == nil then
		return unknownWrite(self)
	end
	local offset = band(physical, HW_MASK[kind])

	if kind == "memctrl" then
		local index = fixupWordOffset(size, offset) // 4
		if index >= 9 then return end
		local shifted = fixupWordWriteValue(size, offset, value)
		local writeMask = (index < 2) and 0xFFFFFFFF or ((index == 8) and COMDELAY_WRITE_MASK or MEMDELAY_WRITE_MASK)
		local newValue = bor(band(self.memCtrlRegs[index + 1] or 0, bnot(writeMask)), band(shifted, writeMask))
		self.memCtrlRegs[index + 1] = newValue
		return
	elseif kind == "pad" then
		local reg = fixupHalfwordOffset(size, offset)
		local shifted = band(fixupHalfwordWriteValue(size, offset, value), 0xFFFF)
		if reg == 0x00 then
			self.world:writeJoypadIO(0x1F801040, shifted)
		elseif reg == 0x04 then
			-- joy_stat is read-only
		elseif reg == 0x08 then
			self.world:writeJoypadIO(0x1F801048, shifted)
		elseif reg == 0x0A then
			self.world:writeJoypadIO(0x1F80104A, shifted)
		elseif reg == 0x0E then
			self.world:writeJoypadIO(0x1F80104E, shifted)
		end
		return
	elseif kind == "sio" then
		local reg = fixupHalfwordOffset(size, offset)
		local shifted = band(fixupHalfwordWriteValue(size, offset, value), 0xFFFF)
		if reg == 0x00 then
			-- sio_data: no state
		elseif reg == 0x04 then
			-- stat read-only
		elseif reg == 0x08 then
			self.sio1.mode = shifted
		elseif reg == 0x0A then
			self.sio1.ctrl = shifted
			if band(shifted, 0x40) ~= 0 then -- RESET -> soft reset
				self.sio1.stat = 0xC5
				self.sio1.mode = 0
				self.sio1.baud = 0xDC
				self.sio1.ctrl = 0
			end
		elseif reg == 0x0E then
			self.sio1.baud = shifted
		end
		return
	elseif kind == "memctrl2" then
		if offset == 0x00 then
			self.ramSizeReg = band(value, 0xFFFFFFFF)
			local window = band(rshift(self.ramSizeReg, 1), 7)
			if window == 4 then
				self.ramMappedEnd = 0x200000
				self.world.ramMappedEnd = 0x200000
			elseif window == 5 or window == 7 then
				self.ramMappedEnd = 0x800000
				self.world.ramMappedEnd = 0x800000
			end
		else
			return unknownWrite(self)
		end
		return
	elseif kind == "intc" then
		local wordOffset = fixupWordOffset(size, offset)
		local shifted = fixupWordWriteValue(size, offset, value)
		if wordOffset == 0x00 then
			-- i_stat: write-0-to-clear (only the low 16 bits)
			self.world.iStat = band(self.world.iStat or 0, band(shifted, 0xFFFF))
		elseif wordOffset == 0x04 then
			-- i_mask bits 11-15 hardwired zero (duckstation register_write_mask 0x7ff)
			self.world.iMask = band(shifted, 0x7FF)
		end
		return
	elseif kind == "dma" then
		local aligned = fixupWordOffset(size, offset)
		local shifted = fixupWordWriteValue(size, offset, value)
		local byteMask = 0xF
		if size == 1 then byteMask = lshift(1, band(offset, 3)) end
		if size == 2 then byteMask = lshift(3, band(offset, 3)) end
		self.world.dma:write(0x1F801080 + aligned, shifted, byteMask)
		return
	elseif kind == "timers" then
		local aligned = fixupWordOffset(size, offset)
		local timerIndex = band(aligned // 0x10, 3)
		local regOffset = band(aligned, 0x0F)
		if timerIndex >= 3 then return end
		local shifted = fixupWordWriteValue(size, offset, value)
		self.world.timers:write(timerIndex, regOffset, shifted)
		return
	elseif kind == "cdrom" then
		-- byte-granular: decompose into byte register writes
		for i = 0, size - 1 do
			self.world.cdrom:write(0x1F801800 + band(offset + i, 0xF), band(rshift(value, i * 8), 0xFF))
		end
		return
	elseif kind == "gpu" then
		local aligned = fixupWordOffset(size, offset)
		local shifted = fixupWordWriteValue(size, offset, value)
		if aligned == 0x00 or aligned == 0x04 then
			self.world.gpu:write(0x1F801810 + aligned, shifted)
		end
		return
	elseif kind == "mdec" then
		local aligned = fixupWordOffset(size, offset)
		local shifted = fixupWordWriteValue(size, offset, value)
		if aligned == 0x00 then
			self.world.mdec:writeData(shifted)
		elseif aligned == 0x04 then
			self.world.mdec:writeControl(shifted)
		end
		return
	elseif kind == "spu" then
		if size == 4 then
			-- two consecutive halfword writes (sbus 16-bit device)
			self.world.spu:write(0x1F801C00 + band(offset, 0x3FF), band(value, 0xFFFF))
			if band(offset, 0x3FF) < 0x3FE then
				self.world.spu:write(0x1F801C00 + band(offset + 2, 0x3FF), band(rshift(value, 16), 0xFFFF))
			end
		elseif size == 2 then
			self.world.spu:write(0x1F801C00 + band(offset, 0x3FF), band(value, 0xFFFF))
		else
			-- sbus byte rules (psx-spx partialwordwrites.md): odd byte drops,
			-- even byte latches the full 16-bit bus value on /wr0
			if band(offset, 1) ~= 0 then return end
			self.world.spu:write(0x1F801C00 + band(offset, 0x3FF), band(value, 0xFFFF))
		end
		return
	end
	return unknownWrite(self)
end

function MemRef:read8(address)
	self.busError = false
	local physical, region = self:decode(address)
	if region == "ram" then
		return band(self.ram[physical + 1] or 0, 0xFF)
	elseif region == "scratchpad" then
		return band(self.scratchpad[(physical - SCRATCHPAD_ADDR) + 1] or 0, 0xFF)
	elseif region == "bios" then
		return band(self.bios[band(physical - BIOS_BASE, BIOS_MASK) + 1] or 0, 0xFF)
	elseif region == "exp1" then
		return 0xFF
	elseif region == "exp2" then
		local offset = band(physical, 0x1FFF)
		if offset == 0x21 then return 0x0C end
		return 0xFF
	elseif region == "exp3" then
		return 0xFF
	elseif region == "sio2" then
		return band(unmappedRead(self), 0xFF)
	elseif region == "hw" then
		return band(hwRead(self, physical, 1), 0xFF)
	elseif region == "cache" then
		if physical == CACHE_CTRL_ADDR then return band(self.cacheControl, 0xFF) end
		return band(unknownRead(self), 0xFF)
	end
	return band(unmappedRead(self), 0xFF)
end

function MemRef:read16(address)
	self.busError = false
	local physical, region = self:decode(address)
	if region == "ram" then
		local p = physical + 1
		local r = self.ram
		return bor(r[p] or 0, lshift(r[p + 1] or 0, 8))
	elseif region == "scratchpad" then
		local p = (physical - SCRATCHPAD_ADDR) + 1
		local s = self.scratchpad
		return bor(s[p] or 0, lshift(s[p + 1] or 0, 8))
	elseif region == "bios" then
		local p = band(physical - BIOS_BASE, BIOS_MASK) + 1
		local b = self.bios
		return bor(b[p] or 0, lshift(b[p + 1] or 0, 8))
	elseif region == "exp1" then
		return 0xFFFF
	elseif region == "exp2" then
		local offset = band(physical, 0x1FFF)
		if offset == 0x21 then return 0x0C end
		return 0xFFFF
	elseif region == "exp3" then
		return 0xFFFF
	elseif region == "sio2" then
		return band(unmappedRead(self), 0xFFFF)
	elseif region == "hw" then
		return band(hwRead(self, physical, 2), 0xFFFF)
	elseif region == "cache" then
		if physical == CACHE_CTRL_ADDR then return band(self.cacheControl, 0xFFFF) end
		return band(unknownRead(self), 0xFFFF)
	end
	return band(unmappedRead(self), 0xFFFF)
end

function MemRef:read32(address)
	self.busError = false
	local physical, region = self:decode(address)
	if region == "ram" then
		local p = physical + 1
		local r = self.ram
		return bor(r[p] or 0, lshift(r[p + 1] or 0, 8), lshift(r[p + 2] or 0, 16), lshift(r[p + 3] or 0, 24))
	elseif region == "scratchpad" then
		local p = (physical - SCRATCHPAD_ADDR) + 1
		local s = self.scratchpad
		return bor(s[p] or 0, lshift(s[p + 1] or 0, 8), lshift(s[p + 2] or 0, 16), lshift(s[p + 3] or 0, 24))
	elseif region == "bios" then
		local p = band(physical - BIOS_BASE, BIOS_MASK) + 1
		local b = self.bios
		return bor(b[p] or 0, lshift(b[p + 1] or 0, 8), lshift(b[p + 2] or 0, 16), lshift(b[p + 3] or 0, 24))
	elseif region == "exp1" then
		return 0xFFFFFFFF
	elseif region == "exp2" then
		local offset = band(physical, 0x1FFF)
		if offset == 0x21 then return 0x0C end
		return 0xFFFFFFFF
	elseif region == "exp3" then
		return 0xFFFFFFFF
	elseif region == "sio2" then
		return unmappedRead(self)
	elseif region == "hw" then
		return hwRead(self, physical, 4)
	elseif region == "cache" then
		if physical == CACHE_CTRL_ADDR then return self.cacheControl end
		return unknownRead(self)
	end
	return unmappedRead(self)
end

function MemRef:write8(address, value)
	self.busError = false
	local physical, region = self:decode(address)
	if region == "ram" then
		self.ram[physical + 1] = band(value, 0xFF)
	elseif region == "scratchpad" then
		self.scratchpad[(physical - SCRATCHPAD_ADDR) + 1] = band(value, 0xFF)
	elseif region == "bios" or region == "exp1" or region == "exp2" or region == "exp3" then
		-- ignored (bios rom writes ignored, exp devices no-op)
	elseif region == "sio2" then
		unknownWrite(self)
	elseif region == "hw" then
		hwWrite(self, physical, 1, value)
	elseif region == "cache" then
		if physical == CACHE_CTRL_ADDR then
			self.cacheControl = value
		else
			unknownWrite(self)
		end
	else
		unknownWrite(self)
	end
end

function MemRef:write16(address, value)
	self.busError = false
	local physical, region = self:decode(address)
	if region == "ram" then
		local p = physical + 1
		self.ram[p] = band(value, 0xFF)
		self.ram[p + 1] = band(rshift(value, 8), 0xFF)
	elseif region == "scratchpad" then
		local p = (physical - SCRATCHPAD_ADDR) + 1
		self.scratchpad[p] = band(value, 0xFF)
		self.scratchpad[p + 1] = band(rshift(value, 8), 0xFF)
	elseif region == "bios" or region == "exp1" or region == "exp2" or region == "exp3" then
	elseif region == "sio2" then
		unknownWrite(self)
	elseif region == "hw" then
		hwWrite(self, physical, 2, value)
	elseif region == "cache" then
		if physical == CACHE_CTRL_ADDR then
			self.cacheControl = value
		else
			unknownWrite(self)
		end
	else
		unknownWrite(self)
	end
end

function MemRef:write32(address, value)
	self.busError = false
	local physical, region = self:decode(address)
	if region == "ram" then
		local p = physical + 1
		self.ram[p] = band(value, 0xFF)
		self.ram[p + 1] = band(rshift(value, 8), 0xFF)
		self.ram[p + 2] = band(rshift(value, 16), 0xFF)
		self.ram[p + 3] = band(rshift(value, 24), 0xFF)
	elseif region == "scratchpad" then
		local p = (physical - SCRATCHPAD_ADDR) + 1
		self.scratchpad[p] = band(value, 0xFF)
		self.scratchpad[p + 1] = band(rshift(value, 8), 0xFF)
		self.scratchpad[p + 2] = band(rshift(value, 16), 0xFF)
		self.scratchpad[p + 3] = band(rshift(value, 24), 0xFF)
	elseif region == "bios" or region == "exp1" or region == "exp2" or region == "exp3" then
	elseif region == "sio2" then
		unknownWrite(self)
	elseif region == "hw" then
		hwWrite(self, physical, 4, value)
	elseif region == "cache" then
		if physical == CACHE_CTRL_ADDR then
			self.cacheControl = value
		else
			unknownWrite(self)
		end
	else
		unknownWrite(self)
	end
end

return MemRef
