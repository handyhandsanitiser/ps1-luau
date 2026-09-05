-- ps1 timers and the crtc clock bits they depend on.
local Timers = {}
Timers.__index = Timers

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local lshift = bit32.lshift
local rshift = bit32.rshift
local bxor = bit32.bxor

Timers.VBlankCycleInterval = 564480

local NUM_TIMERS = 3
local TIMER_OVERFLOW = 0x10000
local MODE_WRITE_MASK = 0xE3FF -- bits 10-12 (interrupt_request_n, reached_target, reached_overflow) read-only

-- crtc constants per region: ntsc 3413 ticks/line x 263 lines (sysclk 715909/451584), pal 3406 x 314 (709379/451584).
local CRTC = {
	ntsc = { ticksPerLine = 3413, totalLines = 263, hActiveEnd = 3288, vDisplayStart = 0x10, vDisplayEnd = 0x100, sysToGpuNum = 715909, vblankInterval = 564480 },
	pal  = { ticksPerLine = 3406, totalLines = 314, hActiveEnd = 3300, vDisplayStart = 0x14, vDisplayEnd = 0x134, sysToGpuNum = 709379, vblankInterval = 677376 },
}
local CRTC_DEFAULT = CRTC.ntsc
local HORIZONTAL_ACTIVE_START = 488
local SYS_TO_GPU_DEN = 451584
local DOT_CLOCK_DIVIDERS = { 10, 8, 5, 4, 7, 7, 7, 7 }

local DOT_TIMER_INDEX = 0
local HBLANK_TIMER_INDEX = 1

local SYNC = {
	PAUSE_WHILE_GATE_ACTIVE = 0,
	RESET_ON_GATE_END = 1,
	RESET_AND_RUN_ON_GATE_START = 2,
	FREE_RUN_ON_GATE_END = 3,
}

-- bitfield helpers
local function modeBit(mode, bit)
	return band(mode, lshift(1, bit)) ~= 0
end
local function syncEnable(mode) return modeBit(mode, 0) end
local function syncMode(mode) return band(rshift(mode, 1), 3) end
local function resetAtTarget(mode) return modeBit(mode, 3) end
local function irqAtTarget(mode) return modeBit(mode, 4) end
local function irqOnOverflow(mode) return modeBit(mode, 5) end
local function irqRepeat(mode) return modeBit(mode, 6) end
local function irqPulseN(mode) return modeBit(mode, 7) end
local function clockSource(mode) return band(rshift(mode, 8), 3) end

function Timers.new(memory, options)
	local self = setmetatable({}, Timers)
	self.memory = memory
	self.traceVBlank = options and options.traceVBlank == true or false
	self.consoleIsPal = options and options.consoleIsPal == true or false
	self:reset()
	return self
end

-- apply the region's crtc constants (called by reset and setconsoleregion): 677376 cycles/frame (pal), 564480 (ntsc).
local function applyRegion(self)
	local c = CRTC[self.consoleIsPal and "pal" or "ntsc"] or CRTC_DEFAULT
	self.ticksPerLine = c.ticksPerLine
	self.totalLines = c.totalLines
	self.hActiveStart = HORIZONTAL_ACTIVE_START
	self.hActiveEnd = c.hActiveEnd
	self.vDisplayStart = c.vDisplayStart
	self.vDisplayEnd = c.vDisplayEnd
	self.sysToGpuNum = c.sysToGpuNum
	self.sysToGpuDen = SYS_TO_GPU_DEN
	self.vblankInterval = c.vblankInterval
end

function Timers:reset()
	self.timers = {}
	for i = 1, NUM_TIMERS do
		self.timers[i] = {
			mode = 0x0400, -- interrupt_request_n = true
			counter = 0,
			target = 0,
			gate = false,
			useExternalClock = false,
			externalCountingEnabled = false,
			countingEnabled = true,
			irqDone = false,
		}
	end
	self.sysclkDiv8Carry = 0
	self.totalCycles = 0
	self.vblankTick = 0
	applyRegion(self)
	self.nextVBlankCycle = self.vblankInterval
	self.onVBlank = nil
	-- crtc state
	self.crtcTick = 0 -- GPU ticks within the current scanline
	self.currentScanline = 0
	self.inHblank = true
	self.inVblank = true
	self.fractionalTicks = 0 -- sysclk->GPU fractional carry
	self.dotClockDivider = DOT_CLOCK_DIVIDERS[4] -- 320px default (index 3 -> 4)
	self.irqCount = 0 -- IRQ pulses raised (for differential)
	return self
end

-- switch the console region at runtime (after bios region detection).
function Timers:setConsoleRegion(isPal)
	local changed = self.consoleIsPal ~= (isPal == true)
	self.consoleIsPal = isPal == true
	applyRegion(self)
	if changed then
		-- rebase the next vblank boundary to a full interval from now.
		self.nextVBlankCycle = self.totalCycles + self.vblankInterval
	end
end


function Timers:updateCountingEnabled(index, cs)
	if index ~= 2 then
		if syncEnable(cs.mode) then
			local sm = syncMode(cs.mode)
			if sm == SYNC.PAUSE_WHILE_GATE_ACTIVE then
				cs.countingEnabled = not cs.gate
			elseif sm == SYNC.RESET_ON_GATE_END then
				cs.countingEnabled = true
			else
				cs.countingEnabled = cs.gate
			end
		else
			cs.countingEnabled = true
		end
	else
		-- timer 2 has no gate: modes 0/3 stop, 1/2 free-run
		cs.countingEnabled = (not syncEnable(cs.mode) or syncMode(cs.mode) == SYNC.RESET_ON_GATE_END
			or syncMode(cs.mode) == SYNC.RESET_AND_RUN_ON_GATE_START)
	end
	cs.externalCountingEnabled = cs.useExternalClock and cs.countingEnabled
end


function Timers:setGate(index, state)
	local cs = self.timers[index + 1]
	if cs.gate == state then
		return
	end
	cs.gate = state
	if not syncEnable(cs.mode) then
		return
	end
	local sm = syncMode(cs.mode)
	if sm == SYNC.RESET_ON_GATE_END then
		cs.counter = state and cs.counter or 0
	elseif sm == SYNC.RESET_AND_RUN_ON_GATE_START then
		cs.counter = state and 0 or cs.counter
	elseif sm == SYNC.FREE_RUN_ON_GATE_END then
		cs.mode = band(cs.mode, bnot(1)) -- sync_enable &= state (state must be true to keep)
	end
	self:updateCountingEnabled(index, cs)
end


function Timers:checkForIRQ(index, oldCounter)
	local cs = self.timers[index + 1]

	local wrappedOverflow = false
	if cs.counter >= TIMER_OVERFLOW then
		wrappedOverflow = (not resetAtTarget(cs.mode) or oldCounter >= cs.target)
		oldCounter = 0
	end

	local interruptRequest = false
	if cs.counter >= cs.target and (oldCounter < cs.target or cs.target == 0) then
		interruptRequest = interruptRequest or irqAtTarget(cs.mode)
		cs.mode = bor(cs.mode, 0x0800) -- reached_target
		if resetAtTarget(cs.mode) and cs.target > 0 and cs.target ~= 0xFFFF then
			cs.counter = cs.counter % cs.target
		end
	end
	if cs.counter >= TIMER_OVERFLOW or wrappedOverflow then
		interruptRequest = interruptRequest or irqOnOverflow(cs.mode)
		cs.mode = bor(cs.mode, 0x1000) -- reached_overflow
		cs.counter = band(cs.counter, 0xFFFF)
	end

	if interruptRequest then
		local irqBit = index + 4 -- I_STAT: TMR0=4, TMR1=5, TMR2=6
		if not irqPulseN(cs.mode) then
			if not cs.irqDone or irqRepeat(cs.mode) then
				-- pulse: line low for a few cycles, then high (duckstation
				-- setlinestate(false); setlinestate(true) manufactures the edge)
				self.irqCount += 1
				if self.memory then
					if self.memory.setInterruptLine then
						self.memory:setInterruptLine(irqBit, false)
						self.memory:setInterruptLine(irqBit, true)
					else
						self.memory:raiseInterrupt(irqBit)
					end
				end
			end
			cs.irqDone = true
			cs.mode = bor(band(cs.mode, bnot(0x0400)), 0x0400) -- interrupt_request_n = true
		else
			-- toggle mode: flip interrupt_request_n; the line follows
			-- !interrupt_request_n (duckstation setlinestate(irq, !request_n))
			cs.mode = bxor(cs.mode, 0x0400)
			local requestLow = not modeBit(cs.mode, 10)
			if requestLow then
				self.irqCount += 1
			end
			if self.memory then
				if self.memory.setInterruptLine then
					self.memory:setInterruptLine(irqBit, requestLow)
				elseif requestLow then
					self.memory:raiseInterrupt(irqBit)
				end
			end
		end
	end
end


function Timers:addTicks(index, count)
	local cs = self.timers[index + 1]
	if irqPulseN(cs.mode) then
		-- slow path: stop at the reset boundary so one-shot/toggle irqs are exact
		local remaining = count
		while remaining > 0 do
			local resetAt = TIMER_OVERFLOW
			if resetAtTarget(cs.mode) and cs.counter < cs.target then
				resetAt = cs.target
			end
			local add = math.min(resetAt - cs.counter, remaining)
			local oldCounter = cs.counter
			cs.counter += add
			remaining -= add
			self:checkForIRQ(index, oldCounter)
		end
	else
		local oldCounter = cs.counter
		cs.counter += count
		self:checkForIRQ(index, oldCounter)
	end
end


function Timers:addSysClkTicks(sysclkTicks)
	local t0 = self.timers[1]
	if not t0.externalCountingEnabled and t0.countingEnabled then
		self:addTicks(0, sysclkTicks)
	end
	local t1 = self.timers[2]
	if not t1.externalCountingEnabled and t1.countingEnabled then
		self:addTicks(1, sysclkTicks)
	end
	local t2 = self.timers[3]
	if t2.externalCountingEnabled then
		local carry = self.sysclkDiv8Carry
		local div8 = (sysclkTicks + carry) // 8
		self.sysclkDiv8Carry = (sysclkTicks + carry) % 8
		self:addTicks(2, div8)
	elseif t2.countingEnabled then
		self:addTicks(2, sysclkTicks)
	end
end


function Timers:crtcStep(cycles)
	-- convert sysclk to gpu ticks with fractional carry
	local mul = cycles * self.sysToGpuNum + self.fractionalTicks
	local gpuTicks = math.floor(mul / self.sysToGpuDen)
	self.fractionalTicks = mul % self.sysToGpuDen
	if gpuTicks <= 0 then
		return
	end

	local prevTick = self.crtcTick
	self.crtcTick += gpuTicks

	-- timer 0 (dot): external clock feeds dots = gpu_ticks / dot_clock_divider
	-- with a fractional accumulator (duckstation fractional_dot_ticks)
	local t0 = self.timers[1]
	if t0.externalCountingEnabled then
		self.dotTickCarry = (self.dotTickCarry or 0) + gpuTicks
		local dots = math.floor(self.dotTickCarry / self.dotClockDivider)
		self.dotTickCarry = self.dotTickCarry % self.dotClockDivider
		if dots > 0 then
			self:addTicks(0, dots)
		end
	end

	local linesToDraw = math.floor(self.crtcTick / self.ticksPerLine)
	self.crtcTick = self.crtcTick % self.ticksPerLine

	-- hblank ticks: duckstation counts one tick per full line crossed plus the
	-- boundary adjustment for partial lines at the start/end of the batch
	local cur = self.crtcTick
	local prev = prevTick
	local fullLines = linesToDraw
	local hblankTicks = fullLines - (prev >= self.hActiveEnd and 1 or 0) + (cur >= self.hActiveEnd and 1 or 0)
	local t1 = self.timers[2]
	if t1.externalCountingEnabled and hblankTicks > 0 then
		self:addTicks(1, hblankTicks)
	end

	-- gate updates (duckstation calls setgate on every crtc event)
	self.inHblank = (self.crtcTick < self.hActiveStart or self.crtcTick >= self.hActiveEnd)
	self:setGate(0, self.inHblank)

	-- advance scanlines for vblank gating
	local linesToDraw2 = linesToDraw
	while linesToDraw2 > 0 do
		local toLoop = math.min(linesToDraw2, self.totalLines - self.currentScanline)
		self.currentScanline = self.currentScanline + toLoop
		linesToDraw2 -= toLoop
		if self.currentScanline == self.totalLines then
			self.currentScanline = 0
		end
	end
	-- the vblank irq itself is raised on the emulator's frame interval in advance(); the crtc scanline only drives the timer gates here.
	local newVblank = self.currentScanline < self.vDisplayStart or self.currentScanline >= self.vDisplayEnd
	if newVblank ~= self.inVblank then
		self.inVblank = newVblank
		self:setGate(1, self.inVblank)
	end
end


function Timers:read(index, offset)
	local cs = self.timers[index + 1]
	if offset == 0 then
		return cs.counter
	elseif offset == 4 then
		local bits = cs.mode
		cs.mode = band(cs.mode, bnot(0x1800)) -- clear reached_target + reached_overflow
		return bits
	elseif offset == 8 then
		return cs.target
	end
	return 0
end

function Timers:write(index, offset, value)
	local cs = self.timers[index + 1]
	value = band(value, 0xFFFFFFFF)
	if offset == 0 then
		cs.counter = band(value, 0xFFFF)
	elseif offset == 4 then
		-- writing the mode register: updates writable bits (0-9, 13-15), clears reached_target/overflow (11-12), and forces interrupt_request (bit 10); checkforirq below may re-set them.
		local writable = band(value, MODE_WRITE_MASK)
		-- preserve non-mode bits (bits 16-31) from the old mode, but
		-- do not preserve the read-only status bits (10-12).
		cs.mode = bor(writable, band(cs.mode, 0xFFFF0000))
		cs.mode = bor(band(cs.mode, bnot(0x1C00)), 0x0400) -- clear reached_target/overflow, set interrupt_request_n
		-- duckstation: use_external_clock = (clock_source & (timer==2 ? 2 : 1)) != 0
		local clk = clockSource(cs.mode)
		cs.useExternalClock = band(clk, (index == 2 and 2 or 1)) ~= 0
		cs.counter = 0
		cs.irqDone = false
		-- the mode write drops the timer's irq line before re-evaluation, so a pending irq re-arms on a fresh 0->1 edge (duckstation).
		if self.memory and self.memory.setInterruptLine then
			self.memory:setInterruptLine(index + 4, false)
		end
		self:updateCountingEnabled(index, cs)
		self:checkForIRQ(index, cs.counter)
	elseif offset == 8 then
		cs.target = band(value, 0xFFFF)
	end
end


function Timers:advance(cycles)
	if cycles <= 0 then
		return
	end
	self.totalCycles += cycles
	self:addSysClkTicks(cycles)
	self:crtcStep(cycles)
	-- vblank frame interval (emulator-established 564480), kept for the runtime
	-- hook in addition to the crtc-driven vblank irq above.
	while self.totalCycles >= self.nextVBlankCycle do
		self.vblankTick += 1
		local fireCycle = self.nextVBlankCycle
		if self.traceVBlank and (self.vblankTick == 1 or self.vblankTick % 60 == 0) then
			print(string.format("[ps1-timer] vblank tick=%d cycle=%d", self.vblankTick, fireCycle))
		end
		if self.memory then
			-- one 0->1 edge per frame (the line is low between frames), so the
			-- edge-triggered intc re-latches even if the game cleared i_stat.
			if self.memory.setInterruptLine then
				self.memory:setInterruptLine(0, false)
				self.memory:setInterruptLine(0, true)
			else
				self.memory:raiseInterrupt(0)
			end
		end
		if self.onVBlank then
			self.onVBlank(self.vblankTick, fireCycle)
		end
		self.nextVBlankCycle += self.vblankInterval
	end
end

return Timers
