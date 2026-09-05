-- interrupt controller model used by the register checks.  stuff the game can actually see:
-- i_stat latches rising edges (writes clear bits with zeroes), i_mask only has eleven usable
-- bits, bad reads return 0xffffffff.

local Interrupts = {}
Interrupts.__index = Interrupts

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local bxor = bit32.bxor
local lshift = bit32.lshift

local NUM_IRQS = 11
local REGISTER_WRITE_MASK = lshift(1, NUM_IRQS) - 1 -- 0x7FF

function Interrupts.new()
	local self = setmetatable({}, Interrupts)
	self:reset()
	return self
end

function Interrupts:reset()
	self.status = 0
	self.mask = 0
	self.lineState = 0
	self.request = false
end

-- a device line latches i_stat on its rising edge. dropping the line does not
-- clear the latched bit.
function Interrupts:setLineState(irq, state)
	local bit = lshift(1, irq)
	local prevState = self.lineState
	self.lineState = state and bor(self.lineState, bit) or band(self.lineState, bnot(bit))
	if self.lineState == prevState then
		return
	end
	-- s_interrupt_status_register |= (state ? (prev ^ line) : 0) & line
	if state then
		local edge = band(bxor(prevState, self.lineState), self.lineState)
		if edge ~= 0 then
			self.status = bor(self.status, edge)
		end
	end
	self:updateRequest()
end

-- i_stat and i_mask occupy offsets 0 and 4. unmapped reads return all ones.
function Interrupts:readRegister(offset)
	if offset == 0x00 then
		return self.status
	elseif offset == 0x04 then
		return self.mask
	end
	return 0xFFFFFFFF
end

-- i_stat uses write-zero-to-clear semantics. i_mask stores only the eleven irq
-- bits; other offsets do nothing.
function Interrupts:writeRegister(offset, value)
	if offset == 0x00 then
		self.status = band(self.status, band(value, REGISTER_WRITE_MASK))
		self:updateRequest()
	elseif offset == 0x04 then
		self.mask = band(value, REGISTER_WRITE_MASK)
		self:updateRequest()
	end
end

-- the cpu request is asserted whenever an enabled status bit is pending.
function Interrupts:updateRequest()
	self.request = band(self.status, self.mask) ~= 0
end

-- pending bits are what the cpu sees after applying the mask.
function Interrupts:getPending()
	return band(self.status, self.mask)
end

return Interrupts
