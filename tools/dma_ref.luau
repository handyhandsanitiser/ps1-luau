-- dma controller model used by the differential checks; device data movement stays outside this
-- file (transfers are reported as descriptors; otc is the exception).  the important behavior here:
-- register masks (madr 0x00ffffff, chcr 0x71770703, otc 0x51000000, dicr 0x00ff807f with
-- write-1-clear 0x7f000000), request modes, chopping, halt/resume, bus errors, and irq flags.
-- manual (sync 0): whole word count at once, madr unchanged; request (sync 1): per-block, sliced
-- by max_slice_ticks with halt/resume; linked list (sync 2): header words until next == 0xffffff,
-- also sliced.  transfer ticks: getdmaramtickcount(wc) = wc + (wc+15)/16; ll setup 8 (header) /
-- 13 (header + block).  the harness forwards consumehaltticks/resumehalted from the emulator
-- controller so both sides stay in lockstep; the ref never drives them on its own.
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
local MAX_LL_NODES = 100000 -- cyclic-list safety cap (stands in for a halt)

-- duckstation settings.h defaults: max_slice_ticks = 1000, halt_ticks = 100; the chopping delay cap is the hardcoded 500 in the chcr write path.
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
	self.readRam = nil
	self.interruptCallback = nil
	self.transferHook = nil
	self.tickCallback = nil
	self.irqFiredCount = 0
	self.executing = nil
	self.haltTicksRemaining = 0
	self.resumePending = false
	self.inTickCharge = false
	self.deviceRequest = nil
	return self
end

function DMA:isHalted()
	return self.haltTicksRemaining > 0
end

function DMA:haltTransfer(duration)
	self.haltTicksRemaining += duration
	return false
end

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
end

function DMA:setInterruptCallback(cb)
	self.interruptCallback = cb
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

-- duckstation updateirq: recompute master flag; fire on 0->1 transition.
function DMA:updateIrq()
	local before = band(self.dicr, 0x80000000)
	local master =
		band(self.dicr, 0x8000) ~= 0 or
		(band(self.dicr, 0x00800000) ~= 0 and band(self.dicr, 0x7F000000) ~= 0)
	if master then
		self.dicr = bor(self.dicr, 0x80000000)
	else
		self.dicr = band(self.dicr, bnot(0x80000000))
	end
	if band(self.dicr, 0x80000000) ~= before and band(self.dicr, 0x80000000) ~= 0 then
		self.irqFiredCount += 1
		if self.interruptCallback then
			self.interruptCallback()
		end
	end
end

-- duckstation shouldsetirqflag: mask bit (16+ch) and master enable (bit 23).
function DMA:shouldSetIrqFlag(ch)
	local maskBit = lshift(1, 16 + ch)
	return band(self.dicr, maskBit) ~= 0 and band(self.dicr, 0x00800000) ~= 0
end

-- duckstation completetransfer: clear busy, set flag if shouldsetirqflag.
function DMA:completeTransfer(ch)
	self.channels[ch + 1].chcr = band(self.channels[ch + 1].chcr, bnot(0x01000000))
	if self:shouldSetIrqFlag(ch) then
		self.dicr = bor(self.dicr, lshift(1, 24 + ch))
		self:updateIrq()
	end
end

-- duckstation checkforbuserror: (address + size) >= rammappedend (u32 wrap).
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

function DMA:emitTransfer(ch, mode, wordCount, address, descriptor)
	if self.transferHook then
		self.transferHook({
			channel = ch,
			mode = mode,
			wordCount = wordCount,
			madr = address,
			bcr = self.channels[ch + 1].bcr,
			chcr = self.channels[ch + 1].chcr,
			direction = band(self.channels[ch + 1].chcr, 0x1),
			extra = descriptor,
		})
	end
end

-- duckstation cantransferchannel: dpcr master enable && busy && request;
-- non-manual sync modes are blocked while halted (unless ignorehalt).
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

-- duckstation setrequest: latches the line; kicks only if it can transfer
-- right now and the same channel isn't already mid-transfer (re-entrancy).
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

function DMA:executeChannel(ch)
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

	if syncMode == 0 then
		-- manual
		local wordCount = getWordCount(c.bcr)
		local transferAddr = band(c.madr, TRANSFER_ADDRESS_MASK)
		if self:checkForBusError(ch, transferAddr, (wordCount - 1) * increment) then
			return true
		end
		self:emitTransfer(ch, 0, wordCount, transferAddr)
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
		-- linkedlist (copy to device only; reads are a duckstation panic)
		if not copyToDevice then
			return true
		end
		local currentAddress = c.madr
		local nodes = 0
		local ticksRemaining = MAX_SLICE_TICKS
		while requestActive() and ticksRemaining > 0 do
			nodes += 1
			if nodes > MAX_LL_NODES then
				c.madr = currentAddress
				return true -- cyclic-list safety cap
			end
			local transferAddr = band(currentAddress, TRANSFER_ADDRESS_MASK)
			if self:checkForBusError(ch, transferAddr, 4) then
				c.madr = currentAddress
				return true
			end
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
				local blockTicks = dmaRamTickCount(wordCount)
				self:addTicks(blockTicks)
				ticksRemaining -= blockTicks
			end
			currentAddress = nextAddress
			if currentAddress == LINKED_LIST_TERMINATOR then
				c.madr = LINKED_LIST_TERMINATOR
				self:completeTransfer(ch)
				return true
			end
		end
		c.madr = currentAddress
		if requestActive() then
			if not self:isHalted() then
				self:haltTransfer(HALT_TICKS)
			end
			return false
		end
		return true
	end

	-- request (sliced to the tick budget like duckstation)
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
	local channelIndex = math.floor((address - 0x1F801080) / 0x10)
	if channelIndex < 7 then
		local reg = (address - 0x1F801080) % 0x10
		local c = self.channels[channelIndex + 1]
		if reg == 0x0 then
			return c.madr
		elseif reg == 0x4 then
			return c.bcr
		elseif reg == 0x8 then
			if channelIndex == 6 then
				return bor(c.chcr, 0x2)
			end
			return c.chcr
		end
		return 0xFFFFFFFF
	end
	if address == 0x1F8010F0 then
		return self.dpcr
	elseif address == 0x1F8010F4 then
		return self.dicr
	end
	return 0xFFFFFFFF
end

function DMA:write(address, value, byteMask)
	value = band(value, 0xFFFFFFFF)
	local channelIndex = math.floor((address - 0x1F801080) / 0x10)
	if channelIndex < 7 then
		local reg = (address - 0x1F801080) % 0x10
		local c = self.channels[channelIndex + 1]
		if reg == 0x0 then
			c.madr = band(value, BASE_ADDRESS_MASK)
			return
		elseif reg == 0x4 then
			c.bcr = value
			return
		elseif reg == 0x8 then
			local ignoreHalt = band(c.chcr, 0x01000000) == 0 and band(value, 0x01000000) ~= 0
			c.chcr = bor(band(c.chcr, bnot(CHCR_WRITE_MASK)), band(value, CHCR_WRITE_MASK))
			if channelIndex == 6 then
				c.chcr = band(c.chcr, CHCR_OTC_MASK)
				self:setRequest(6, band(c.chcr, 0x10000000) ~= 0)
			end
			if self:canTransfer(channelIndex, ignoreHalt) then
				local syncMode = band(rshift(c.chcr, 9), 0x3)
				local choppingEnable = band(c.chcr, 0x100) ~= 0
				if channelIndex ~= 6 and syncMode == 0 and choppingEnable then
					local dmaWindowSize = band(rshift(c.chcr, 16), 0x7)
					local cpuWindowSize = band(rshift(c.chcr, 20), 0x7)
					local rawWordCount = band(c.bcr, 0xFFFF)
					local cpuCyclesPerBlock = lshift(1, cpuWindowSize)
					local blocks = rshift(rawWordCount, dmaWindowSize)
					local delayCycles = math.min(cpuCyclesPerBlock * blocks, CHOP_DELAY_CAP)
					if rawWordCount > 4 and delayCycles > 1 then
						self:haltTransfer(delayCycles)
						return
					end
				end
				self:executeChannel(channelIndex)
			end
			return
		end
		return
	end
	if address == 0x1F8010F0 then
		self.dpcr = value
		for i = 0, 6 do
			if self:canTransfer(i, false) then
				if not self:executeChannel(i) then
					break
				end
			end
		end
		return
	elseif address == 0x1F8010F4 then
		self.dicr = bor(band(self.dicr, bnot(DICR_WRITE_MASK)), band(value, DICR_WRITE_MASK))
		self.dicr = band(self.dicr, bnot(band(value, DICR_RESET_MASK)))
		self:updateIrq()
		return
	end
end

return DMA
