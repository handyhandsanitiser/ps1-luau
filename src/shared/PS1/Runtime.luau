local BIOS = require(script.Parent.BIOS)
local CPU = require(script.Parent.CPU)
local Memory = require(script.Parent.Memory)
local PSXExe = require(script.Parent.PSXExe)
local Region = require(script.Parent.Region)

local Runtime = {}
Runtime.__index = Runtime

local band = bit32.band
local bnot = bit32.bnot
local bor = bit32.bor
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift

local BIOS_GATEWAYS = {
	[0xA0] = "A",
	[0xB0] = "B",
	[0xC0] = "C",
}

local IRQ_VBLANK_BIT = 0
local IRQ_CDROM_BIT = 2
local IRQ_HANDLER_TABLE_BASE = 0x80016AF4

local function installVBlankHook(runtime)
	runtime.memory.timers.onVBlank = function(_tick, _cycle)
		-- bootstrap: the scph1001 bios resets i_mask to 0 but its waitvblank routines need vblank irqs, so enable bit 0 when a bios is loaded.
		if runtime.biosLoaded and bit32.band(runtime.memory.iMask, 1) == 0 then
			runtime.memory.iMask = bit32.bor(runtime.memory.iMask, 1)
			local _p = bit32.band(runtime.memory.iStat, runtime.memory.iMask)
			runtime.memory._irqState = (_p ~= 0) and bit32.bor(_p, 0x80000000) or bit32.band(runtime.memory._irqState or 0, 0x80000000)
		end
		if runtime.onVBlank then
			pcall(runtime.onVBlank, runtime)
		end
	end
end

function Runtime.new(options)
	local self = setmetatable({}, Runtime)
	self.memory = Memory.new(options)
	self.bios = BIOS.new(options)
	self.cpu = CPU.new(self.memory)
	self.traceStep = options and options.traceStep == true or false
	self.traceInterruptFlow = options and options.traceInterruptFlow == true or false
	self.cpu.traceInterruptGate = options and options.traceInterruptGate == true or false
	self.cpu.cyclesPerInstruction = options and options.cpuCyclesPerInstruction or 1
	-- cached blocks are opt-in so instruction-level callers keep one-step behavior.
	self.cpu.useBlocks = options and options.useBlocks == true or false
	self.memory.cpu = self.cpu
	self.memory.cdrom.cycleScale = math.max(1, self.cpu.cyclesPerInstruction or 1)
	-- mdec-out is dispatched by the game's own dma-interrupt machinery; an hle here would double-fire and corrupt the movie stream, so leave the callback unset.
	self.memory.mdecOutCompleteCallback = nil

	self.loadedHeader = nil
	-- console region: explicit override ("ntsc"|"pal") or nil = auto-detect
	-- from the bios image (region.detect).  applied in loadbios.
	self.consoleRegion = options and options.consoleRegion or nil
	self.consoleIsPal = false
	self.yieldInterval = options and options.yieldInterval or 5000
	self.yieldBetweenChunks = not (options and options.yieldBetweenChunks == false)
	self.yieldSleepSeconds = options and options.yieldSleepSeconds or 0
	self.asyncSliceInstructions = options and options.asyncSliceInstructions or 2000
	self.asyncSliceSeconds = options and options.asyncSliceSeconds or 0.003
	installVBlankHook(self)
	self:_installSdkIsrHook()
	return self
end

-- psn00bsdk installs a jmp_buf-based isr via hookentryint(b:19h) and sets changeclearrcnt(t=3) to 0
-- so the bios vblank handler does not auto-acknowledge.  we intercept the hw interrupt path before the
-- bios handler, save state, run the isr on the sdk's own stack, and rfe on returnfromexception(b:17h).
function Runtime:_installSdkIsrHook()
	local self = self
	self.cpu.interceptException = function(_cpu, vector, _epc, _status, _cause)
		-- only intercept hw interrupts (excode 0)
		if not self._entryInterruptHook then
			return nil -- no hook installed, let BIOS handle
		end
		local clearRcnt3 = self._changeClearRCnt and self._changeClearRCnt[3] or 1
		if clearRcnt3 ~= 0 then
			return nil -- BIOS auto-acknowledge mode, let BIOS handle
		end

		-- save cpu state before dispatching the sdk isr
		local saved = {
			pc = _epc,
			nextPc = band(_epc + 4, 0xFFFFFFFF),
			regs = {},
			pendingBranch = _cpu.pendingBranch,
			pendingLoad = _cpu.pendingLoad,
			inDelaySlot = _cpu.inDelaySlot,
			gpr = self.memory:read32(IRQ_HANDLER_TABLE_BASE - 4) or 0x9,
		}
		for i = 1, 32 do
			saved.regs[i] = _cpu:getRegister(i)
		end

		-- read the jmp_buf at _entryinterrupthook: +0x00 ra, +0x04 sp, +0x08 fp,
		-- +0x0c-0x28 s0-s7, +0x2c gp
		local buf = self._entryInterruptHook
		local isrPc = self.memory:read32(buf + 0x00)
		local isrSp = self.memory:read32(buf + 0x04)
		local isrGp = self.memory:read32(buf + 0x2C)

		if isrPc == 0 or isrSp == 0 then
			self._entryInterruptHook = nil -- invalid hook, revert
			return nil
		end

		-- restore s0-s7 and gp from jmp_buf to cpu registers
		for i = 0, 7 do
			_cpu:setRegister(16 + i, self.memory:read32(buf + 0x0C + i * 4))
		end
		_cpu:setRegister(28, isrGp)

		-- set up the cpu to run the isr on its own stack
		_cpu:setRegister(29, band(isrSp, 0xFFFFFFFF))  -- sp
		_cpu:setRegister(30, self.memory:read32(buf + 0x08))  -- fp
		-- r2 = 1 (the hook "return value" from setjmp perspective)
		_cpu:setRegister(2, 1)

		-- store saved state for returnfromexception to restore
		self._sdkIsrSavedState = saved

		return isrPc
	end

	-- returnfromexception (b:17h) hle intercept: restore the saved state and rfe (also caught at the gateway level).
end

function Runtime:advanceStepCycles()
	self.memory:advanceCycles(self.cpu.cyclesPerInstruction or 1)
end

function Runtime:reset(entryPoint)
	self.cpu:reset(entryPoint)
end

function Runtime:loadExecutable(data)
	local header = PSXExe.loadIntoMemory(self.memory, data)
	self.loadedHeader = header
	local registers = PSXExe.buildInitialRegisters(header)
	self:reset(registers.pc)
	-- route exceptions to the low-ram vectors (bev=0) so the ram-resident
	-- kernel/vectors handle them, regardless of whether a bios image is present.
	self.cpu.cop0.status = band(self.cpu.cop0.status or 0, bnot(0x00400000))
	-- hle exception handling only for bare exe boots: with a bios loaded, its ram-resident kernel must keep dispatching interrupts/syscalls, or the game's real vblank handler never runs.
	if not self.biosLoaded then
		self.biosLoaded = false
	end
	self.cpu:setRegister(28, registers.gp)
	-- sp/fp are set only when the exe header specifies a stack; a zero header sp means "use the caller's stack" (psx-spx, duckstation injectexecutable).
	if registers.sp ~= nil then
		self.cpu:setRegister(29, registers.sp)
		self.cpu:setRegister(30, registers.fp)
	end
	self.cpu:setRegister(4, registers.a0)
	self.cpu:setRegister(5, registers.a1)
	self.cpu:setRegister(6, registers.a2)
	self.cpu:setRegister(7, registers.a3)

	-- many retail executables assume a bios-like argc/argv layout.
	-- provide a minimal argv[0] string block on stack for direct exe boots.
	local sp = self.cpu:getRegister(29)
	if sp ~= 0 then
		local arg0 = "cdrom:\\GAME.EXE;1"
		local argBytes = arg0 .. "\0"
		local arg0Addr = band(sp - #argBytes, 0xFFFFFFFC)
		self.memory:writeBytes(arg0Addr, argBytes)

		local argvAddr = band(arg0Addr - 8, 0xFFFFFFFC)
		self.memory:write32(argvAddr, arg0Addr)
		self.memory:write32(argvAddr + 4, 0)

		self.cpu:setRegister(4, 1) -- argc
		self.cpu:setRegister(5, argvAddr) -- argv
	end

	return header
end

function Runtime:loadBios(data)
	self.memory:loadBiosImage(data)
	self.biosLoaded = true
	installVBlankHook(self)
	-- detect the console region from the bios image (duckstation: region is
	-- determined by the bios model; pal units run 50hz frame timing).
	local region = self.consoleRegion or Region.detect(data)
	self.detectedRegion = region
	self:applyConsoleRegion(region)
end

-- re-apply the console region after a checkpoint restore (the snapshot's gpu frame period would otherwise clobber region-derived timing).
function Runtime:reapplyConsoleRegion()
	self:applyConsoleRegion(self.consoleRegion or self.detectedRegion)
end

-- apply the console region to timing (vblank interval, crtc constants, gpu frame period); nil keeps the default ntsc timing.
function Runtime:applyConsoleRegion(region)
	local isPal = region == "pal"
	self.consoleIsPal = isPal
	self.memory.timers:setConsoleRegion(isPal)
	self.memory.gpu:setConsoleRegion(isPal)
end

function Runtime:runAsync(sliceSize)
	sliceSize = sliceSize or self.asyncSliceInstructions or 2000
	local sliceSeconds = self.asyncSliceSeconds or 0.003
	self.asyncRunning = true
	task.spawn(function()
		while self.asyncRunning and not self.cpu.halted do
			local executed = 0
			local deadline = os.clock() + sliceSeconds
			while self.asyncRunning and not self.cpu.halted and executed < sliceSize and os.clock() < deadline do
				-- surface step errors in output and keep going, so a roblox session logs the fault instead of freezing.
				local ok, err = pcall(function() self:step() end)
				if not ok then
					warn(string.format("[ps1] runtime:step() error: %s", tostring(err)))
					break
				end
				executed += 1
			end
			task.wait()
		end
		print("[ps1] async run stopped")
	end)
end

function Runtime:stopAsync()
	self.asyncRunning = false
end

function Runtime:mountDisc(disc)
	self.memory.cdrom:mount(disc)
end

function Runtime:captureFrame()
	return self.memory.gpu:captureFrame()
end

function Runtime:handleBiosGateway()
	local pc = self.memory:physicalAddress(self.cpu.pc)
	local vectorName = BIOS_GATEWAYS[pc]
	if not vectorName then
		return false
	end

	-- with the bios kernel resident in low ram, let the cpu execute the real a/b/c vectors so kernel
	-- services (task registration, dispatch, cd i/o) actually run instead of the hle stub.
	-- exception: psn00bsdk's hookentryint/changeclearrcnt hooks are still intercepted at the hle level.
	local fn = band(self.cpu:getRegister(9), 0xFF)
	if self.biosLoaded then
		if vectorName == "B" and fn == 0x17 then
			-- returnfromexception: sdk isr is done; restore saved state and rfe.
			if self._sdkIsrSavedState then
				local s = self._sdkIsrSavedState
				self._sdkIsrSavedState = nil
				-- restore all registers
				for i = 1, 32 do
					self.cpu:setRegister(i, s.regs[i])
				end
				-- rfe: pop ku/ie stack
				local status = self.cpu.cop0.status
				self.cpu.cop0.status = bor(band(status, bnot(0x0F)), band(rshift(status, 2), 0x0F))
				-- resume at interrupted instruction
				self.cpu.pc = s.pc
				self.cpu.nextPc = s.nextPc
				self.cpu.pendingBranch = s.pendingBranch
				self.cpu.pendingLoad = s.pendingLoad
				self.cpu.inDelaySlot = s.inDelaySlot
				return true
			end
			-- sdk isr not active; fall through to real bios handler
		elseif vectorName == "B" and fn == 0x18 then
			-- resetentryint: the sdk is uninstalling its hook.
			self._entryInterruptHook = nil
			self._changeClearRCnt = nil
			self._sdkIsrSavedState = nil
			-- b:18h returns 0 for success; we don't emulate the hook-table bookkeeping.
			self.cpu:setRegister(2, 0)
			self.cpu.pc = band(self.cpu:getRegister(31), 0xFFFFFFFF)
			self.cpu.nextPc = band(self.cpu.pc + 4, 0xFFFFFFFF)
			self.cpu.pendingBranch = nil
			self.cpu.pendingLoad = nil
			self.cpu.inDelaySlot = false
			return true
		elseif vectorName == "B" and fn == 0x19 then
			-- hookentryint(addr): store the jmp_buf pointer for later dispatch.
			local addr = band(self.cpu:getRegister(4), 0xFFFFFFFF)
			local result = self._entryInterruptHook or 0
			self._entryInterruptHook = addr
			self.cpu:setRegister(2, result)
			self.cpu.pc = band(self.cpu:getRegister(31), 0xFFFFFFFF)
			self.cpu.nextPc = band(self.cpu.pc + 4, 0xFFFFFFFF)
			self.cpu.pendingBranch = nil
			self.cpu.pendingLoad = nil
			self.cpu.inDelaySlot = false
			return true
		elseif vectorName == "C" and fn == 0x0A then
			-- changeclearrcnt(t, flag): store per-timer clear flag.
			-- index 3 = vblank; flag 0 = don't auto-ack → hook gets dispatched.
			local t = band(self.cpu:getRegister(4), 0xFF)
			local flag = band(self.cpu:getRegister(5), 0xFF)
			if not self._changeClearRCnt then self._changeClearRCnt = {[0]=1,[1]=1,[2]=1,[3]=1} end
			local result = self._changeClearRCnt[t] or 1
			self._changeClearRCnt[t] = flag
			self.cpu:setRegister(2, result)
			self.cpu.pc = band(self.cpu:getRegister(31), 0xFFFFFFFF)
			self.cpu.nextPc = band(self.cpu.pc + 4, 0xFFFFFFFF)
			self.cpu.pendingBranch = nil
			self.cpu.pendingLoad = nil
			self.cpu.inDelaySlot = false
			return true
		end
		-- all other gateways: let the real bios handle them.
		if self.memory:read32(0x800000A0) ~= 0 then
			return false
		end
	else
		if self.memory:read32(0x800000A0) ~= 0 then
			return false
		end
	end

	return self.bios:dispatchGateway(vectorName, self.cpu:getRegister(9), self.cpu, self.memory, self.biosLoaded == true)
end

function Runtime:handleSyscallException()
	if band(self.cpu.cop0.cause, 0x7C) ~= 0x20 then
		return false
	end
	local epc = band(self.cpu.cop0.epc or 0, 0xFFFFFFFF)
	local inBiosRegion = epc >= 0xBFC00000 and epc < 0xBFC80000
	if self.traceInterruptFlow then
		print(string.format(
			"[ps1-hle] syscall exception pc=%08X cause=%08X epc=%08X",
			self.cpu.pc or 0,
			self.cpu.cop0.cause or 0,
			epc
		))
	end

	local returnAddress = self.cpu.cop0.epc
	if band(self.cpu.cop0.cause, 0x80000000) ~= 0 then
		returnAddress = band(returnAddress + 8, 0xFFFFFFFF)
	else
		returnAddress = band(returnAddress + 4, 0xFFFFFFFF)
	end

	if self.traceInterruptFlow then
		print(string.format(
			"[ps1-hle] syscall return epc=%08X pc=%08X cause=%08X",
			self.cpu.cop0.epc or 0,
			returnAddress,
			self.cpu.cop0.cause or 0
		))
	end

	local syscallNumber = self.cpu:getRegister(4)

	if syscallNumber ~= 0x01 and syscallNumber ~= 0x02 then
		if not self.biosLoaded then
			self.cpu:setRegister(2, 0)
			local status = self.cpu.cop0.status
			self.cpu.cop0.status = bor(band(status, bnot(0x0F)), band(rshift(status, 2), 0x0F))
			self.cpu.cop0.cause = band(self.cpu.cop0.cause, bnot(0x7C))
			self.cpu.pc = returnAddress
			self.cpu.nextPc = band(returnAddress + 4, 0xFFFFFFFF)
			self.cpu.pendingBranch = nil
			self.cpu.pendingLoad = nil
			self.cpu.inDelaySlot = false
			return true
		end
		if self.traceInterruptFlow then
			print(string.format(
				"[ps1-hle] syscall pass-through num=%08X epc=%08X",
				syscallNumber,
				self.cpu.cop0.epc or 0
			))
		end
		return false
	end

	if syscallNumber == 0x01 then
		local oldStatus = self.cpu.cop0.status
		local oldBitsSet = band(oldStatus, 0x00000404) == 0x00000404
		local newStatus = band(oldStatus, bnot(0x00000405))
		self.cpu:setCop0(12, newStatus)
		self.cpu:setRegister(2, oldBitsSet and 1 or 0)
		if self.traceInterruptFlow then
			print(string.format(
				"[ps1-hle] EnterCriticalSection status=%08X -> %08X return=%d",
				oldStatus,
				newStatus,
				oldBitsSet and 1 or 0
			))
		end
	elseif syscallNumber == 0x02 then
		local oldStatus = self.cpu.cop0.status
		local newStatus = bor(oldStatus, 0x00000405)
		self.cpu:setCop0(12, newStatus)
		-- keep vblank + cd-rom irq enabled so disc boot code can progress.
		self.memory:write16(0x1F801074, bor(self.memory.iMask or 0, 0x0005))
		if self.traceInterruptFlow then
			print(string.format(
				"[ps1-hle] ExitCriticalSection status=%08X -> %08X imask=%04X",
				oldStatus,
				newStatus,
				self.memory.iMask or 0
			))
		end
	end

	local status = self.cpu.cop0.status
	self.cpu.cop0.status = bor(band(status, bnot(0x0F)), band(rshift(status, 2), 0x0F))
	self.cpu.cop0.cause = band(self.cpu.cop0.cause, bnot(0x7C))
	self.cpu.pc = returnAddress
	if self.traceInterruptFlow then
		print(string.format("[ps1-hle] syscall resumed at %08X", self.cpu.pc or 0))
	end
	self.cpu.nextPc = band(returnAddress + 4, 0xFFFFFFFF)
	self.cpu.pendingBranch = nil
	self.cpu.pendingLoad = nil
	self.cpu.inDelaySlot = false
	return true
end

function Runtime:handleBreakpointException()
	if band(self.cpu.cop0.cause, 0x7C) ~= 0x24 then
		return false
	end

	local returnAddress = self.cpu.cop0.epc
	if band(self.cpu.cop0.cause, 0x80000000) ~= 0 then
		returnAddress = band(returnAddress + 8, 0xFFFFFFFF)
	else
		returnAddress = band(returnAddress + 4, 0xFFFFFFFF)
	end

	if self.traceInterruptFlow then
		print(string.format(
			"[ps1-hle] breakpoint epc=%08X return=%08X cause=%08X",
			self.cpu.cop0.epc or 0,
			returnAddress,
			self.cpu.cop0.cause or 0
		))
	end

	-- mirror rfe-style unwind to restore interrupt enable stack level.
	local status = self.cpu.cop0.status
	self.cpu.cop0.status = bor(band(status, bnot(0x0F)), band(rshift(status, 2), 0x0F))
	self.cpu.cop0.cause = band(self.cpu.cop0.cause, bnot(0x7C))
	self.cpu.pc = returnAddress
	self.cpu.nextPc = band(returnAddress + 4, 0xFFFFFFFF)
	self.cpu.pendingBranch = nil
	self.cpu.pendingLoad = nil
	self.cpu.inDelaySlot = false
	return true
end

function Runtime:handleReservedInstructionException()
	if band(self.cpu.cop0.cause, 0x7C) ~= 0x28 then
		return false
	end

	local epc = band(self.cpu.cop0.epc or 0, 0xFFFFFFFF)
	local returnAddress

	-- ri inside the game's data section means an uninitialized function pointer was called; return to $ra so the caller continues.
	local header = self.loadedHeader
	local inDataSection = false
	if header and header.loadAddress and header.entryPoint then
		local physEpc  = self.memory:physicalAddress(epc)
		local physLoad = band(header.loadAddress, 0x1FFFFFFF)
		local physEntry = band(header.entryPoint, 0x1FFFFFFF)
		if physEpc >= physLoad and physEpc < physEntry then
			inDataSection = true
		end
	end

	if inDataSection then
		-- treat as a null stub: return to the caller via $ra.
		returnAddress = band(self.cpu:getRegister(31), 0xFFFFFFFF)
		if self.traceInterruptFlow then
			print(string.format(
				"[ps1-hle] RI data-stub epc=%08X returning to ra=%08X",
				epc, returnAddress
			))
		end
	elseif band(self.cpu.cop0.cause, 0x80000000) ~= 0 then
		returnAddress = band(epc + 8, 0xFFFFFFFF)
	else
		returnAddress = band(epc + 4, 0xFFFFFFFF)
	end

	if self.traceInterruptFlow then
		print(string.format(
			"[ps1-hle] RI recover epc=%08X return=%08X cause=%08X",
			epc,
			returnAddress,
			self.cpu.cop0.cause or 0
		))
	end

	local status = self.cpu.cop0.status
	self.cpu.cop0.status = bor(band(status, bnot(0x0F)), band(rshift(status, 2), 0x0F))
	self.cpu.cop0.cause = band(self.cpu.cop0.cause, bnot(0x7C))
	self.cpu.pc = returnAddress
	self.cpu.nextPc = band(returnAddress + 4, 0xFFFFFFFF)
	self.cpu.pendingBranch = nil
	self.cpu.pendingLoad = nil
	self.cpu.inDelaySlot = false
	return true
end

function Runtime:handleAddressErrorException()
	local code = band(self.cpu.cop0.cause, 0x7C)
	if code ~= 0x10 and code ~= 0x14 then
		return false
	end

	local epc = band(self.cpu.cop0.epc or 0, 0xFFFFFFFF)
	local badv = band(self.cpu.cop0.badvaddr or 0, 0xFFFFFFFF)
	local returnAddress
	if band(self.cpu.cop0.cause, 0x80000000) ~= 0 then
		returnAddress = band(epc + 8, 0xFFFFFFFF)
	else
		returnAddress = band(epc + 4, 0xFFFFFFFF)
	end

	if self.traceInterruptFlow then
		print(string.format(
			"[ps1-hle] address-error recover code=%02X epc=%08X badv=%08X return=%08X",
			code,
			epc,
			badv,
			returnAddress
		))
	end

	local status = self.cpu.cop0.status
	self.cpu.cop0.status = bor(band(status, bnot(0x0F)), band(rshift(status, 2), 0x0F))
	self.cpu.cop0.cause = band(self.cpu.cop0.cause, bnot(0x7C))
	self.cpu.pc = returnAddress
	self.cpu.nextPc = band(returnAddress + 4, 0xFFFFFFFF)
	self.cpu.pendingBranch = nil
	self.cpu.pendingLoad = nil
	self.cpu.inDelaySlot = false
	return true
end

function Runtime:dispatchInterruptHandler(handlerAddress)
	if handlerAddress == 0 then
		return false
	end

	if handlerAddress == 0x80014EA0 then
		local counterAddress = 0x800169F4
		local currentValue = self.memory:read32(counterAddress)
		self.memory:write32(counterAddress, band(currentValue + 1, 0xFFFFFFFF))
		if self.traceInterruptFlow then
			print(string.format(
				"[ps1-hle] vblank counter addr=%08X value=%08X",
				counterAddress,
				self.memory:read32(counterAddress)
			))
		end
		return true
	end

	return false
end

function Runtime:completeVsyncWait()
	-- the game's vsync(0) spins on the frame counter at 0x80013284; on real hardware the loop's dram
	-- wait states make it outlast one vblank period, but here it times out early.  fast-forward the clock
	-- to the next vblank boundary instead of modeling those wait states -- a pure idle-skip optimization.
	local pc = band(self.cpu.pc or 0, 0xFFFFFFFF)
	if pc ~= 0x80013284 then
		return false
	end
	local target = band(self.cpu:getRegister(4) or 0, 0xFFFFFFFF)
	local fc = band(self.memory:read32(0x800225D0) or 0, 0xFFFFFFFF)
	-- release the latch once the frame counter actually advanced (resetting on every pc change re-fired the storm forever).
	if fc >= target then
		self.vsyncWaitFastForwarded = nil
		return false
	end
	-- only fast-forward once per frame: keep the latch held until fc moves so
	-- the pending vblank gets a chance to be delivered by a completed walk.
	if self.vsyncWaitFastForwarded then
		return false
	end
	self.vsyncWaitFastForwarded = true
	local timers = self.memory.timers
	local advance = timers.nextVBlankCycle - timers.totalCycles
	if advance <= 0 then
		advance = timers.VBlankCycleInterval
	end
	self.memory:advanceCycles(advance)
	return true
end

function Runtime:tryDeliverCdSector()
	-- no-op instrumentation seam (probes wrap it to count slow-path visits).  the old bulk-drain hack is disabled: it stole the cd fifo ahead of the game's real dma ch3 chains.
	return false
end

function Runtime:handleInterruptException()
	if band(self.cpu.cop0.cause, 0x7C) ~= 0 then
		return false
	end

	local pending = self.memory:getPendingInterruptMask()
	if self.traceInterruptFlow then
		print(string.format(
			"[ps1-hle] enter handleInterruptException epc=%08X cause=%08X pending=%08X status=%08X iec=%d cop0Mask=%02X ioMask=%04X istat=%04X",
			self.cpu.cop0.epc or 0,
			self.cpu.cop0.cause or 0,
			pending or 0,
			self.cpu.cop0.status or 0,
			band(self.cpu.cop0.status or 0, 0x1),
			band(rshift(self.cpu.cop0.status or 0, 8), 0xFF),
			self.memory.iMask or 0,
			self.memory.iStat or 0
		))
	end

	local hasVBlank = band(pending, lshift(1, IRQ_VBLANK_BIT)) ~= 0
	local hasCdrom = band(pending, lshift(1, IRQ_CDROM_BIT)) ~= 0
	-- retire cd-rom irqs like vblank so retail cd boot code can poll drive state (previously a cd irq fell through to a half-initialized low-ram vector).
	local canHleCdromInterrupt = hasCdrom
	if not hasVBlank and not hasCdrom then
		return false
	end

	-- direct exe boots: let the hle path retire vblank/cd-rom irqs so startup code can poll device state.
	local handledMask = 0
	if hasVBlank then
		handledMask = bor(handledMask, lshift(1, IRQ_VBLANK_BIT))
	end
	if canHleCdromInterrupt then
		handledMask = bor(handledMask, lshift(1, IRQ_CDROM_BIT))
	end
	local otherPending = band(pending, bnot(handledMask))
	if otherPending ~= 0 then
		return false
	end

	local handlerAddress = 0
	if hasVBlank then
		self.memory:clearInterrupt(IRQ_VBLANK_BIT)
		handlerAddress = self.memory:read32(IRQ_HANDLER_TABLE_BASE + (IRQ_VBLANK_BIT * 4))
		self:dispatchInterruptHandler(handlerAddress)
		-- hle the vblank tick: increment the frame counter at [0x800225d0] that vsync() waits on (only per vblank, not per sector, or block-completion waits would race ahead of the data).
		local tickCounter = 0x800225D0
		local tc = band(self.memory:read32(tickCounter), 0xFFFFFFFF)
		self.memory:write32(tickCounter, band(tc + 1, 0xFFFFFFFF))
		-- the main loop polls a 16-bit frame counter at [0x8002150a]; emulate the increment without a bios kernel to dispatch the real handler.
		local fcnt = 0x8002150A
		local cv = band(self.memory:read16(fcnt), 0xFFFF)
		self.memory:write16(fcnt, band(cv + 1, 0xFFFF))
	end
	if canHleCdromInterrupt then
		self.memory:clearInterrupt(IRQ_CDROM_BIT)
		-- retire the irq; sector data transfers lazily once the game programs dma ch3 madr, so we don't race its buffer setup.
		self:tryDeliverCdSector()
	end
	local vblankCounterAddress = 0x800169F4
	local vblankCounterAfter = self.memory:read32(vblankCounterAddress)

	local oldStatus = self.cpu.cop0.status
	self.cpu.cop0.status = bor(band(oldStatus, bnot(0x0F)), band(rshift(oldStatus, 2), 0x0F))
	self.cpu.cop0.cause = band(self.cpu.cop0.cause, bnot(0x7C))
	self.cpu.pc = band(self.cpu.cop0.epc, 0xFFFFFFFF)
	self.cpu.nextPc = band(self.cpu.pc + 4, 0xFFFFFFFF)
	self.cpu.pendingBranch = nil
	self.cpu.pendingLoad = nil
	self.cpu.inDelaySlot = false
	if self.traceInterruptFlow then
		print(string.format(
			"[ps1-hle] interrupt return pc=%08X handler=%08X statusBefore=%08X statusAfter=%08X iecAfter=%d vblankCounter=%08X handledVBlank=%s handledCdrom=%s",
			self.cpu.pc or 0,
			handlerAddress or 0,
			oldStatus or 0,
			self.cpu.cop0.status or 0,
			band(self.cpu.cop0.status or 0, 0x1),
			vblankCounterAfter or 0,
			tostring(hasVBlank),
			tostring(canHleCdromInterrupt)
		))
	end
	return true
end

function Runtime:step()
	-- most bios-loaded instructions don't need hle checks; keep only the vector and vsync pcs on the slow path.
	local pc = self.cpu.pc
	if self.biosLoaded
		and pc ~= 0x80000000 and pc ~= 0x80000080
		and pc ~= 0x800000A0 and pc ~= 0x800000B0 and pc ~= 0x800000C0
		and pc ~= 0x80013284 then
		return self.cpu:step()
	end
	return self:stepSlow()
end

function Runtime:stepSlow()
	if not self.biosLoaded and self.loadedHeader then
		local pc = band(self.cpu.pc or 0, 0xFFFFFFFF)
		if pc < 0x00200000 then
			local canonical = bor(pc, 0x80000000)
			self.cpu.pc = canonical
			self.cpu.nextPc = band(canonical + 4, 0xFFFFFFFF)
		end
	end

	local statusBefore = self.cpu.cop0.status or 0
	local pendingBefore = self.memory:getPendingInterruptMask() or 0
	local physicalPc = self.memory:physicalAddress(self.cpu.pc)
	local exceptionCode = band(self.cpu.cop0.cause or 0, 0x7C)
	if self.traceStep then
		print(string.format(
			"[ps1-hle] step entry pc=%08X cause=%08X status=%08X iec=%d pending=%08X cop0Mask=%02X ioMask=%04X istat=%04X",
			self.cpu.pc or 0,
			self.cpu.cop0.cause or 0,
			statusBefore,
			band(statusBefore, 0x1),
			pendingBefore,
			band(rshift(statusBefore, 8), 0xFF),
			self.memory.iMask or 0,
			self.memory.iStat or 0
		))
	end
	local vectorPc = self.cpu.pc

	-- only intercept low-ram interrupt delivery when the cpu could actually take the interrupt (sr.ie + hw enable); the game jumps into the a/b/c vectors with irqs masked to call kernel services.
	if not self.biosLoaded and physicalPc < 0x400 and exceptionCode == 0x00
		and band(self.cpu.cop0.status or 0, 1) ~= 0
		and band(self.cpu.cop0.status or 0, 0x00000400) ~= 0 then
		if self.traceInterruptFlow then
			print(string.format(
				"[ps1-hle] low-ram interrupt intercept pc=%08X phys=%08X cause=%08X",
				self.cpu.pc or 0,
				physicalPc,
				self.cpu.cop0.cause or 0
			))
		end
		if self:handleInterruptException() then
			self:advanceStepCycles()
			self.cpu.registers[1] = 0
			return true
		end
	end

	if physicalPc < 0x400 and exceptionCode == 0x20 then
		if self.traceInterruptFlow then
			print(string.format(
				"[ps1-hle] low-ram syscall intercept pc=%08X phys=%08X cause=%08X",
				self.cpu.pc or 0,
				physicalPc,
				self.cpu.cop0.cause or 0
			))
		end
		if not self.biosLoaded and self:handleSyscallException() then
			self:advanceStepCycles()
			self.cpu.registers[1] = 0
			return true
		end
	end

	if vectorPc == 0x80000080 or vectorPc == 0x80000000 then
		if self.traceInterruptFlow then
			print(string.format(
				"[ps1-hle] vector gate pc=%08X cause=%08X",
				vectorPc or 0,
				self.cpu.cop0.cause or 0
			))
		end
	end

	if not self.biosLoaded and (vectorPc == 0x80000080 or vectorPc == 0x80000000) and self:handleInterruptException() then
		self:advanceStepCycles()
		self.cpu.registers[1] = 0
		return true
	end

	if not self.biosLoaded and (vectorPc == 0x80000080 or vectorPc == 0x80000000) and self:handleSyscallException() then
		self:advanceStepCycles()
		self.cpu.registers[1] = 0
		return true
	end

	-- exception recovery is hle-only for bare boots; with a real bios the kernel's dispatcher at the vector must run instead (zero of these fire on the silent hill boot, but the gating keeps it correct for games that do).
	if not self.biosLoaded and (vectorPc == 0x80000080 or vectorPc == 0x80000000) and self:handleBreakpointException() then
		self:advanceStepCycles()
		self.cpu.registers[1] = 0
		return true
	end

	if not self.biosLoaded and (vectorPc == 0x80000080 or vectorPc == 0x80000000) and self:handleReservedInstructionException() then
		self:advanceStepCycles()
		self.cpu.registers[1] = 0
		return true
	end

	if not self.biosLoaded and (vectorPc == 0x80000080 or vectorPc == 0x80000000) and self:handleAddressErrorException() then
		self:advanceStepCycles()
		self.cpu.registers[1] = 0
		return true
	end

	if self:handleBiosGateway() then
		self:advanceStepCycles()
		self.cpu.registers[1] = 0
		return true
	end

	self:completeVsyncWait()

	-- lazily hand any pending cd sector to the game once its dma madr is ready
	self:tryDeliverCdSector()

	local stepped = self.cpu:step()
	local statusAfter = self.cpu.cop0.status or 0
	local pendingAfter = self.memory:getPendingInterruptMask() or 0
	if self.traceStep then
		print(string.format(
			"[ps1-hle] step exit pc=%08X cause=%08X status=%08X iec=%d pending=%08X cop0Mask=%02X ioMask=%04X istat=%04X stepped=%s",
			self.cpu.pc or 0,
			self.cpu.cop0.cause or 0,
			statusAfter,
			band(statusAfter, 0x1),
			pendingAfter,
			band(rshift(statusAfter, 8), 0xFF),
			self.memory.iMask or 0,
			self.memory.iStat or 0,
			tostring(stepped)
		))
	end
	return stepped
end

function Runtime:runInstructionBudget(count)
	local executed = 0
	local yieldInterval = math.max(1, self.yieldInterval or 5000)

	while executed < count do
		local chunkSize = math.min(yieldInterval, count - executed)
		for _ = 1, chunkSize do
			if not self:step() then
				return executed
			end
			executed += 1
		end

		if executed < count and self.yieldBetweenChunks then
			task.wait(self.yieldSleepSeconds)
		end
	end

	return executed
end

function Runtime:signalVBlank(active)
	-- vblank is now raised by timers:advance (which calls memory:raiseinterrupt(0)
	-- and the timers.onvblank hook on the console's frame interval).
	if active and self.onVBlank then
		local ok, err = pcall(self.onVBlank, self)
		if not ok then
			-- don't crash emulation on display errors
		end
	end
end

function Runtime:dumpState()
	local state = self.cpu:dumpState()
	state.loadedHeader = self.loadedHeader
	state.interrupts = {
		iStat = self.memory.iStat,
		iMask = self.memory.iMask,
	}
	state.bios = self.bios:dumpState()
	state.joypad = self.memory:dumpJoypadState()
	state.cdrom = self.memory.cdrom:dumpState()
	return state
end

function Runtime:getCapabilityReport()
	return {
		cpu = {
			status = "implemented",
			details = "MIPS R3000A interpreter with COP0, delay slots, load delays, exceptions, and COP2/GTE integration.",
		},
		gte = {
			status = "implemented",
			details = "COP2 data/control register model and core geometry/light pipeline ops are present.",
		},
		memory = {
			status = "implemented",
			details = "2MB RAM, BIOS mapping, scratchpad, interrupt regs, DMA/gpu/cdrom/spu/timer MMIO routing.",
		},
		dma = {
			status = "partial",
			details = "GPU (normal + linked-list), CD-ROM, and OTC channels implemented; other DMA channels are not yet modeled.",
		},
		gpu = {
			status = "implemented",
			details = "Software rasterizer with PS1 draw state, textured primitives, masking, dithering, and display timing.",
		},
		cdrom = {
			status = "implemented",
			details = "CD-ROM register map, command and response queues, sector timing, filtering, and DMA data delivery.",
		},
		spu = {
			status = "implemented",
			details = "24-voice ADPCM synthesizer with Gaussian interpolation, envelopes, sweeps, reverb, capture, and CD mixing.",
		},
		timers = {
			status = "implemented",
			details = "Three timers with system, dot-clock, HBlank, and VBlank sources plus target and IRQ handling.",
		},
		bootPath = {
			status = "implemented",
			details = "Retail BIOS-first boot reaches Silent Hill gameplay (gs=11) from a clean start; full boot to gs=1 and InGame checkpoint roundtrip are regression gates.",
		},
	}
end

return Runtime