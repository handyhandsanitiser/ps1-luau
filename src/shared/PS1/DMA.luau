-- dma controller for the ps1 (duckstation dma.cpp port).
-- register semantics: madr masks to 0x00ffffff; chcr masks to 0x71770703 (otc 0x51000000);
-- dpcr kicks every enabled/requested channel ascending; dicr mask 0x00ff807f, write-1-clear 0x7f000000,
-- master flag (bit 31) = bus_error || (master_enable && any flag), irq on its 0->1 edge.
-- transfer modes: manual (sync 0) = whole word count at once; request (sync 1) = per-block with
-- madr/bcr advancing; linked list (sync 2) = header words until next == 0xffffff.
-- simplifications: transfers run synchronously to completion, no tick-budget slicing by default,
-- and device request signals are always satisfied except otc.
local DMA = {}
DMA.__index = DMA

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local lshift = bit32.lshift
local rshift = bit32.rshift

local BASE_ADDRESS_MASK = 0x00FFFFFF
local TRANSFER_ADDRESS_MASK = 0x00FFFFFC
local LINKED_LIST_TERMINATOR = 0x00FFFFFF
local CHCR_WRITE_MASK = 0x71770703
local CHCR_OTC_MASK = 0x51000000
local DICR_WRITE_MASK = 0x00FF807F
local DICR_RESET_MASK = 0x7F000000
local DPCR_RESET = 0x07654321
local MAX_LL_NODES = 100000 -- replaces DuckStation's tick-budget halt for cyclic lists

-- tick-budget slicing (duckstation settings.h): transfers run in slices of max_slice_ticks, then halt for halt_ticks so the cpu can run; chopping delays manual transfers by min(cpu_window * blocks, 500).
local MAX_SLICE_TICKS = 1000
local HALT_TICKS = 100
local CHOP_DELAY_CAP = 500

local function getWordCount(bcr)
	local wc = band(bcr, 0xFFFF)
	return wc == 0 and 0x10000 or wc
end

local function getBlockSize(bcr)
	local bs = band(bcr, 0xFFFF)
	return bs == 0 and 0x10000 or bs
end

local function getBlockCount(bcr)
	local bc = band(rshift(bcr, 16), 0xFFFF)
	return bc == 0 and 0x10000 or bc
end

local function dmaRamTickCount(wordCount)
	return wordCount + (wordCount + 15) // 16
end

local function isMasterEnabled(dpcr, ch)
	return band(dpcr or 0, lshift(1, ch * 4 + 3)) ~= 0
end

function DMA.new()
	local self = setmetatable({}, DMA)
	self.channels = table.create(7)
	for i = 1, 7 do
		self.channels[i] = { madr = 0, bcr = 0, chcr = 0, request = true }
	end
	-- otc (ch 6): request comes from the start-trigger bit (duckstation
	-- setrequest(otc, start_trigger) on chcr write).
	self.channels[7].request = false
	self.dpcr = DPCR_RESET
	self.dicr = 0
	self.ramMappedEnd = 0x200000
	self.handlers = {}
	-- ram read used for linked-list headers/data (duckstation reads the bus
	-- directly; memory wires this).
	self.readRam = nil
	self.interruptCallback = nil
	-- differential hooks (probes only; nil in normal operation).
	self.transferHook = nil
	self.tickCallback = nil
	self.irqFiredCount = 0
	-- channel currently inside executechannel (same-channel re-entry guard;
	-- see setrequest).
	self.executing = nil
	-- tick-budget slicing / chopping state: while haltticksremaining > 0 the dma is halted and only manual transfers run; consumehaltticks is called from memory:advancecycles, resumehalted re-kicks.
	self.haltTicksRemaining = 0
	self.resumePending = false
	-- cached "cpu must tend the dma" flag for the block engine: one field instead of reading both halt fields per instruction.
	self._needsStep = false
	-- true while addticks is dispatching into memory:advancecycles (the dma is
	-- stealing cpu cycles); the resume check must not fire re-entrantly here.
	self.inTickCharge = false
	-- live device request query (function(ch) -> boolean|nil), consulted at every block/node boundary; memory wires ch2 to the gpu fifo.
	self.deviceRequest = nil
	return self
end

function DMA:isHalted()
	return self.haltTicksRemaining > 0
end

-- halt the dma for `duration` more ticks.  returns false so callers can return
-- it as the "transfer not yet complete" result (duckstation transferchannel).
function DMA:haltTransfer(duration)
	self.haltTicksRemaining += duration
	self._needsStep = true
	return false
end

-- consume halt ticks as cpu time advances; when the window expires, latch a resume so the next cpu instruction re-kicks.
function DMA:consumeHaltTicks(cycles)
	if self.haltTicksRemaining <= 0 then
		return
	end
	self.haltTicksRemaining -= cycles
	if self.haltTicksRemaining <= 0 then
		self.haltTicksRemaining = 0
		self.resumePending = true
	end
end

-- duckstation unhalttransfer: run every channel that can now transfer, in
-- ascending order, stopping at the first that halts again.
function DMA:resumeHalted()
	self.resumePending = false
	for i = 0, 6 do
		if self:canTransfer(i, false) then
			if not self:executeChannel(i) then
				return
			end
		end
	end
	self.haltTicksRemaining = 0
	self._needsStep = self.haltTicksRemaining > 0 or self.resumePending
end

function DMA:setInterruptCallback(callback)
	self.interruptCallback = callback
end

function DMA:setTransferHook(hook)
	self.transferHook = hook
end

function DMA:setTickCallback(cb)
	self.tickCallback = cb
end

function DMA:addTicks(ticks)
	if ticks and ticks > 0 and self.tickCallback then
		self.inTickCharge = true
		self.tickCallback(ticks)
		self.inTickCharge = false
	end
end

function DMA:setChannelHandler(channelIndex, handler)
	self.handlers[channelIndex] = handler
end

-- updateirq: recompute the master flag; the dma irq fires on its 0->1 transition (i_stat.3).
function DMA:updateIrq()
	local before = band(self.dicr, 0x80000000)
	if band(self.dicr, 0x8000) ~= 0
		or (band(self.dicr, 0x00800000) ~= 0 and band(self.dicr, 0x7F000000) ~= 0) then
		self.dicr = bor(self.dicr, 0x80000000)
	else
		self.dicr = band(self.dicr, bnot(0x80000000))
	end
	-- the dma line follows the master flag: 0->1 on transfer completion, 1->0 when the game clears dicr.
	if self.memory and self.memory.setInterruptLine then
		self.memory:setInterruptLine(3, band(self.dicr, 0x80000000) ~= 0)
	end
	if band(self.dicr, 0x80000000) ~= before and band(self.dicr, 0x80000000) ~= 0 then
		self.irqFiredCount += 1
		if self.interruptCallback then
			self.interruptCallback()
		end
	end
end

-- duckstation shouldsetirqflag: the flag latches only when both the channel's
-- mask (16+ch) and the master enable (bit 23) are set.
function DMA:shouldSetIrqFlag(ch)
	local maskBit = lshift(1, 16 + ch)
	return band(self.dicr, maskBit) ~= 0 and band(self.dicr, 0x00800000) ~= 0
end

-- duckstation completetransfer: clear busy; latch the flag + irq if enabled.
function DMA:completeTransfer(ch)
	self.channels[ch + 1].chcr = band(self.channels[ch + 1].chcr, bnot(0x01000000))
	if self:shouldSetIrqFlag(ch) then
		self.dicr = bor(self.dicr, lshift(1, 24 + ch))
		self:updateIrq()
	end
end

-- duckstation checkforbuserror: (address + size) >= rammappedend, computed in
-- u32 (negative sizes wrap, matching the c++ unsigned arithmetic).
function DMA:checkForBusError(ch, address, size)
	local endAddr = band(address + size, 0xFFFFFFFF)
	if endAddr >= self.ramMappedEnd then
		self.channels[ch + 1].chcr = band(self.channels[ch + 1].chcr, bnot(0x01000000))
		self.dicr = bor(self.dicr, 0x8000)
		self.dicr = bor(self.dicr, lshift(1, 24 + ch))
		self:updateIrq()
		return true
	end
	return false
end

function DMA:emitTransfer(ch, mode, wordCount, address, extra)
	if self.transferHook then
		self.transferHook({
			channel = ch,
			mode = mode,
			wordCount = wordCount,
			madr = address,
			bcr = self.channels[ch + 1].bcr,
			chcr = self.channels[ch + 1].chcr,
			direction = band(self.channels[ch + 1].chcr, 0x1),
			extra = extra,
		})
	end
end

-- cantransferchannel: dpcr master enable && busy && request; non-manual modes are blocked while halted (unless the chcr write ignores it).
function DMA:canTransfer(ch, ignoreHalt)
	if not isMasterEnabled(self.dpcr, ch) then
		return false
	end
	local c = self.channels[ch + 1]
	if band(c.chcr, 0x01000000) == 0 then
		return false
	end
	local syncMode = band(rshift(c.chcr, 9), 0x3)
	if syncMode ~= 0 and self:isHalted() and not ignoreHalt then
		return false
	end
	return c.request
end

-- setrequest: device/trigger request line, kicks if enabled.  a request change mid-transfer is latched but not re-kicked -- the loop sees it next iteration, and re-kicking would re-read stale madr/bcr.
function DMA:setRequest(ch, request)
	request = request == true
	local c = self.channels[ch + 1]
	if c.request == request then
		return
	end
	c.request = request
	if self:canTransfer(ch, false) and self.executing ~= ch then
		self:executeChannel(ch)
	end
end

-- run a channel's transfer: memory moves the data (device fifos / ram); the controller owns madr/bcr/chcr and irq state.
function DMA:executeChannel(ch)
	-- same-channel re-entry must not restart from stale madr/bcr; the outer loop's request check resumes it.
	if self.executing == ch then
		return true
	end
	local prevExecuting = self.executing
	self.executing = ch
	local result = self:_executeChannelInner(ch)
	self.executing = prevExecuting
	return result
end

function DMA:_executeChannelInner(ch)
	local c = self.channels[ch + 1]
	-- start/trigger bit cleared on beginning of transfer
	c.chcr = band(c.chcr, bnot(0x10000000))
	local copyToDevice = band(c.chcr, 0x1) ~= 0
	local reverse = band(c.chcr, 0x2) ~= 0
	local increment = reverse and -4 or 4
	local syncMode = band(rshift(c.chcr, 9), 0x3)
	local handler = self.handlers[ch]

	local function runHandler(wordCount, madr)
		if handler then
			handler({
				channel = ch,
				madr = madr,
				bcr = c.bcr,
				chcr = c.chcr,
				wordCount = wordCount,
				direction = copyToDevice and 1 or 0,
				syncMode = syncMode,
			})
		end
	end

	if syncMode == 0 then
		-- manual: whole word count; madr/bcr unchanged (psx-spx: syncmode=0
		-- does not update madr).
		local wordCount = getWordCount(c.bcr)
		local transferAddr = band(c.madr, TRANSFER_ADDRESS_MASK)
		if self:checkForBusError(ch, transferAddr, (wordCount - 1) * increment) then
			return true
		end
		self:emitTransfer(ch, 0, wordCount, transferAddr)
		runHandler(wordCount, transferAddr)
		self:addTicks(dmaRamTickCount(wordCount))
		self:completeTransfer(ch)
		return true
	end

	-- at transfer boundaries the live device query wins when present, else the latched request (duckstation reads cs.request each iteration).
	local function requestActive()
		if self.deviceRequest then
			local r = self.deviceRequest(ch)
			if r ~= nil then
				c.request = r
				return r
			end
		end
		return c.request
	end

	if syncMode == 2 then
		-- linked-list mode (used by gpu channel 2 for command lists).
		if not copyToDevice then
			-- duckstation panics on ll reads; no state change.
			return true
		end
		local currentAddress = c.madr
		local nodes = 0
		local ticksRemaining = MAX_SLICE_TICKS
		while requestActive() and ticksRemaining > 0 do
			nodes += 1
			if nodes > MAX_LL_NODES then
				-- cyclic list: halt substitute, keep busy for a later resume
				c.madr = currentAddress
				return true
			end
			local transferAddr = band(currentAddress, TRANSFER_ADDRESS_MASK)
			if self:checkForBusError(ch, transferAddr, 4) then
				c.madr = currentAddress
				return true
			end
			-- duckstation reads the list header directly from ram.
			local header = self.readRam and self.readRam(transferAddr) or 0
			local wordCount = rshift(header, 24)
			local nextAddress = band(header, 0x00FFFFFF)
			local setupTicks = wordCount > 0 and 13 or 8
			self:addTicks(setupTicks)
			ticksRemaining -= setupTicks
			if wordCount > 0 then
				if self:checkForBusError(ch, transferAddr, (wordCount - 1) * increment) then
					c.madr = currentAddress
					return true
				end
				self:emitTransfer(ch, 2, wordCount, transferAddr + 4)
				-- one reusable transfer cell: handlers consume it synchronously, so per-word allocation is pure garbage for long command lists.
				local llTransfer = { linkedListGpu = true, word = 0 }
				for i = 1, wordCount do
					local word = self.readRam and self.readRam(transferAddr + i * 4) or 0
					if handler then
						llTransfer.word = word
						handler(llTransfer)
					end
				end
				local blockTicks = dmaRamTickCount(wordCount)
				self:addTicks(blockTicks)
				ticksRemaining -= blockTicks
			end
			currentAddress = nextAddress
			if currentAddress == LINKED_LIST_TERMINATOR then
				-- terminator reached: madr holds the end marker
				c.madr = LINKED_LIST_TERMINATOR
				self:completeTransfer(ch)
				return true
			end
		end
		c.madr = currentAddress
		if requestActive() then
			-- ran for too long: stall the transfer for a bit (duckstation
			-- only re-halts if a halt isn't already pending)
			if not self:isHalted() then
				self:haltTransfer(HALT_TICKS)
			end
			return false
		end
		return true
	end

	-- request mode (sync 1): per-block transfers with madr/bcr updates,
	-- sliced to a tick budget so the cpu can interleave during long transfers.
	local blockSize = getBlockSize(c.bcr)
	local blocksRemaining = getBlockCount(c.bcr)
	local currentAddress = c.madr
	local ticksRemaining = MAX_SLICE_TICKS
	while requestActive() and blocksRemaining > 0 and ticksRemaining > 0 do
		local transferAddr = band(currentAddress, TRANSFER_ADDRESS_MASK)
		if self:checkForBusError(ch, transferAddr, (blockSize - 1) * increment) then
			c.madr = currentAddress
			c.bcr = bor(band(c.bcr, 0xFFFF), lshift(blocksRemaining, 16))
			return true
		end
		self:emitTransfer(ch, 1, blockSize, transferAddr)
		runHandler(blockSize, transferAddr)
		local ticks = dmaRamTickCount(blockSize)
		self:addTicks(ticks)
		ticksRemaining -= ticks
		blocksRemaining -= 1
		currentAddress = transferAddr + increment * blockSize
	end
	c.madr = currentAddress
	c.bcr = bor(band(c.bcr, 0xFFFF), lshift(blocksRemaining, 16))
	if blocksRemaining > 0 then
		if requestActive() then
			-- sliced: halt unless a halt is already pending (duckstation)
			if not self:isHalted() then
				self:haltTransfer(HALT_TICKS)
			end
			return false
		end
		return true
	end
	self:completeTransfer(ch)
	return true
end

function DMA:read(address)
	if address >= 0x1F801080 and address < 0x1F8010F0 then
		local channelIndex = math.floor((address - 0x1F801080) / 0x10)
		local registerOffset = (address - 0x1F801080) % 0x10
		local channel = self.channels[channelIndex + 1]
		if not channel then
			return 0xFFFFFFFF
		end
		if registerOffset == 0x0 then
			return channel.madr
		elseif registerOffset == 0x4 then
			return channel.bcr
		elseif registerOffset == 0x8 then
			-- otc (ch 6): the memory-address step bit is hardwired to 1 -- it always walks the ordering table backwards (ps1-tests); the transfer path hardcodes decrement anyway.
			if channelIndex == 6 then
				return bor(channel.chcr, 0x2)
			end
			return channel.chcr
		end
		-- unused register lanes (incl. the +0xc gap) read open bus
		return 0xFFFFFFFF
	end

	if address == 0x1F8010F0 then
		return self.dpcr
	elseif address == 0x1F8010F4 then
		return self.dicr
	end

	-- 0x1f8010f8/0xfc and beyond: open bus
	return 0xFFFFFFFF
end

function DMA:write(address, value, byteMask)
	value = band(value, 0xFFFFFFFF)

	if address >= 0x1F801080 and address < 0x1F8010F0 then
		local channelIndex = math.floor((address - 0x1F801080) / 0x10)
		local registerOffset = (address - 0x1F801080) % 0x10
		local channel = self.channels[channelIndex + 1]
		if not channel then
			return nil
		end

		if registerOffset == 0x0 then
			-- duckstation: madr is 24 bits wide (address bits 24-31 zero).
			channel.madr = band(value, BASE_ADDRESS_MASK)
		elseif registerOffset == 0x4 then
			channel.bcr = value
		elseif registerOffset == 0x8 then
			-- chcr write mask (duckstation); otc masks further and uses the trigger bit as its request.  a write that raises busy ignores an in-progress halt (ff8 kicks spu mid-halt).
			local ignoreHalt = band(channel.chcr, 0x01000000) == 0 and band(value, 0x01000000) ~= 0
			channel.chcr = bor(band(channel.chcr, bnot(CHCR_WRITE_MASK)), band(value, CHCR_WRITE_MASK))
			if channelIndex == 6 then
				channel.chcr = band(channel.chcr, CHCR_OTC_MASK)
				self:setRequest(6, band(channel.chcr, 0x10000000) ~= 0)
			end
			-- chopping (duckstation): manual transfers with the chop bit are delayed min(cpu_window * blocks, 500) cycles before starting (lagnacure legend needs it; the cap keeps tiny transfers immediate).
			if self:canTransfer(channelIndex, ignoreHalt) then
				local syncMode = band(rshift(channel.chcr, 9), 0x3)
				local choppingEnable = band(channel.chcr, 0x100) ~= 0
				if channelIndex ~= 6 and syncMode == 0 and choppingEnable then
					local dmaWindowSize = band(rshift(channel.chcr, 16), 0x7)
					local cpuWindowSize = band(rshift(channel.chcr, 20), 0x7)
					local rawWordCount = band(channel.bcr, 0xFFFF)
					local cpuCyclesPerBlock = lshift(1, cpuWindowSize)
					local blocks = rshift(rawWordCount, dmaWindowSize)
					local delayCycles = math.min(cpuCyclesPerBlock * blocks, CHOP_DELAY_CAP)
					if rawWordCount > 4 and delayCycles > 1 then
						-- delay the transfer; the unhalt will re-kick it.
						self:haltTransfer(delayCycles)
						return nil
					end
				end
				self:executeChannel(channelIndex)
			end
		end
		return nil
	end

	if address == 0x1F8010F0 then
		self.dpcr = value
		-- duckstation: dpcr write kicks any channel that can transfer.
		for i = 0, 6 do
			if self:canTransfer(i, false) then
				if not self:executeChannel(i) then
					break
				end
			end
		end
		return nil
	elseif address == 0x1F8010F4 then
		-- dicr: r/w mask 0x00ff807f, flags 24-30 clear on write-1, master flag recomputed.  byte-granular access is handled by the bus fixup shift before this point.
		self.dicr = bor(band(self.dicr, bnot(DICR_WRITE_MASK)), band(value, DICR_WRITE_MASK))
		self.dicr = band(self.dicr, bnot(band(value, DICR_RESET_MASK)))
		self:updateIrq()
		return nil
	end

	return nil
end

return DMA
