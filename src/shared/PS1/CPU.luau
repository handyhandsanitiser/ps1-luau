local Util = require(script.Parent.Util)
local GTE = require(script.Parent.GTE)

local CPU = {}
CPU.__index = CPU

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift
local arshift = bit32.arshift

local function signed(value)
	return Util.toSigned32(value)
end

-- exact 32x32 -> 64-bit multiply via 16-bit halves (lua doubles lose precision above 2^53).  returns hi32, lo32.
local function mult64(a, b)
	-- intermediates stay below 2^48, so plain arithmetic is exact; only the final words are masked.
	local aLo = band(a, 0xFFFF)
	local aHi = band(rshift(a, 16), 0xFFFF)
	local bLo = band(b, 0xFFFF)
	local bHi = band(rshift(b, 16), 0xFFFF)
	local lo = aLo * bLo
	local mid = aHi * bLo + aLo * bHi
	local hi = aHi * bHi
	local loAccum = lo + (mid % 0x10000) * 0x10000
	local lo32 = band(loAccum, 0xFFFFFFFF)
	local carry = math.floor(loAccum / 0x100000000)
	local hi32 = band(hi + math.floor(mid / 0x10000) + carry, 0xFFFFFFFF)
	return hi32, lo32
end

-- mips div truncates toward zero (c++ semantics), not lua's floor division; the product stays exact in doubles.
local function divModTrunc(dividend, divisor)
	local q = dividend / divisor
	local lo
	if q >= 0 then
		lo = math.floor(q)
	else
		lo = math.ceil(q)
	end
	local hi = dividend - lo * divisor
	return band(lo, 0xFFFFFFFF), band(hi, 0xFFFFFFFF)
end

-- duckstation getmultticks(s32) / getmultticks(u32): 5/8/12 extra ticks by
-- |rs| magnitude (the instruction's own cycle is already excluded).
local function multTicksSigned(lhs)
	if lhs < 0 then
		if lhs >= -2048 then return 5 elseif lhs >= -1048576 then return 8 else return 12 end
	else
		if lhs < 0x800 then return 5 elseif lhs < 0x100000 then return 8 else return 12 end
	end
end
local function multTicksUnsigned(lhs)
	if lhs < 0x800 then return 5 elseif lhs < 0x100000 then return 8 else return 12 end
end

-- block-cache interpreter: caches short straight-line runs for tight loops, but still checks
-- interrupts, delay slots, exceptions, and device time per instruction.
-- blocks stop before the runtime hle pcs; ram writes bump page versions so stale code can't survive.

local OP_SLL = 1
local OP_SRL = 2
local OP_SRA = 3
local OP_SLLV = 4
local OP_SRLV = 5
local OP_SRAV = 6
local OP_MULT = 7
local OP_MULTU = 8
local OP_DIV = 9
local OP_DIVU = 10
local OP_MFHI = 11
local OP_MTHI = 12
local OP_MFLO = 13
local OP_MTLO = 14
local OP_ADD = 15
local OP_ADDU = 16
local OP_SUB = 17
local OP_SUBU = 18
local OP_AND = 19
local OP_OR = 20
local OP_XOR = 21
local OP_NOR = 22
local OP_SLT = 23
local OP_SLTU = 24
local OP_JR = 25
local OP_JALR = 26
local OP_SYSCALL = 27
local OP_BREAK = 28
local OP_ADDI = 29
local OP_ADDIU = 30
local OP_SLTI = 31
local OP_SLTIU = 32
local OP_ANDI = 33
local OP_ORI = 34
local OP_XORI = 35
local OP_LUI = 36
local OP_LB = 37
local OP_LH = 38
local OP_LWL = 39
local OP_LW = 40
local OP_LBU = 41
local OP_LHU = 42
local OP_LWR = 43
local OP_SB = 44
local OP_SH = 45
local OP_SWL = 46
local OP_SW = 47
local OP_SWR = 48
local OP_LWC2 = 49
local OP_SWC2 = 50
local OP_BEQ = 51
local OP_BNE = 52
local OP_BLEZ = 53
local OP_BGTZ = 54
local OP_BLTZ = 55
local OP_BGEZ = 56
local OP_BLTZAL = 57
local OP_BGEZAL = 58
local OP_J = 63
local OP_JAL = 64
local OP_MFC0 = 65
local OP_MTC0 = 66
local OP_RFE = 67
local OP_COP0_NOP = 68
local OP_COP0_INVALID = 69
local OP_MFC2 = 70
local OP_CFC2 = 71
local OP_MTC2 = 72
local OP_CTC2 = 73
local OP_GTE = 74
local OP_COP2_INVALID = 75
local OP_LWC013 = 76
local OP_SWC013 = 77
local OP_COP13_NOP = 78
local OP_RI = 79

-- runtime hle intercept pcs: blocks end before these so the caller re-dispatches.
local SPECIAL_PCS = {
	[0x80000000] = true,
	[0x80000080] = true,
	[0x800000A0] = true,
	[0x800000B0] = true,
	[0x800000C0] = true,
	[0x80013284] = true,
}
local function isSpecialPc(pc)
	return SPECIAL_PCS[pc] == true
end

-- decode one word. register operands are stored as 1-based cpu slots; branch
-- targets are calculated here because the instruction pc is known.
local function decodeWord(word, pc)
	local opcode = band(rshift(word, 26), 0x3F)
	local rs = band(rshift(word, 21), 0x1F)
	local rt = band(rshift(word, 16), 0x1F)
	local rd = band(rshift(word, 11), 0x1F)
	local sa = band(rshift(word, 6), 0x1F)
	local funct = band(word, 0x3F)
	local imm = band(word, 0xFFFF)
	local simm = imm >= 0x8000 and imm - 0x10000 or imm
	local rsSlot = rs + 1
	local rtSlot = rt + 1
	local rdSlot = rd + 1

	if opcode == 0x00 then
		if funct == 0x00 then return { OP_SLL, rtSlot, sa, rdSlot }
		elseif funct == 0x02 then return { OP_SRL, rtSlot, sa, rdSlot }
		elseif funct == 0x03 then return { OP_SRA, rtSlot, sa, rdSlot }
		elseif funct == 0x04 then return { OP_SLLV, rsSlot, rtSlot, rdSlot }
		elseif funct == 0x06 then return { OP_SRLV, rsSlot, rtSlot, rdSlot }
		elseif funct == 0x07 then return { OP_SRAV, rsSlot, rtSlot, rdSlot }
		elseif funct == 0x08 then return { OP_JR, rsSlot, 0, 0 }
		elseif funct == 0x09 then return { OP_JALR, rsSlot, 0, rdSlot }
		elseif funct == 0x0C then return { OP_SYSCALL, 0, 0, 0 }
		elseif funct == 0x0D then return { OP_BREAK, 0, 0, 0 }
		elseif funct == 0x10 then return { OP_MFHI, 0, 0, rdSlot }
		elseif funct == 0x11 then return { OP_MTHI, rsSlot, 0, 0 }
		elseif funct == 0x12 then return { OP_MFLO, 0, 0, rdSlot }
		elseif funct == 0x13 then return { OP_MTLO, rsSlot, 0, 0 }
		elseif funct == 0x18 then return { OP_MULT, rsSlot, rtSlot, 0 }
		elseif funct == 0x19 then return { OP_MULTU, rsSlot, rtSlot, 0 }
		elseif funct == 0x1A then return { OP_DIV, rsSlot, rtSlot, 0 }
		elseif funct == 0x1B then return { OP_DIVU, rsSlot, rtSlot, 0 }
		elseif funct == 0x20 then return { OP_ADD, rsSlot, rtSlot, rdSlot }
		elseif funct == 0x21 then return { OP_ADDU, rsSlot, rtSlot, rdSlot }
		elseif funct == 0x22 then return { OP_SUB, rsSlot, rtSlot, rdSlot }
		elseif funct == 0x23 then return { OP_SUBU, rsSlot, rtSlot, rdSlot }
		elseif funct == 0x24 then return { OP_AND, rsSlot, rtSlot, rdSlot }
		elseif funct == 0x25 then return { OP_OR, rsSlot, rtSlot, rdSlot }
		elseif funct == 0x26 then return { OP_XOR, rsSlot, rtSlot, rdSlot }
		elseif funct == 0x27 then return { OP_NOR, rsSlot, rtSlot, rdSlot }
		elseif funct == 0x2A then return { OP_SLT, rsSlot, rtSlot, rdSlot }
		elseif funct == 0x2B then return { OP_SLTU, rsSlot, rtSlot, rdSlot }
		end
		return { OP_RI, 0, 0, word }
	elseif opcode == 0x01 then
		-- regimm: bit 0 selects bltz/bgez; the link is written iff (rt & 0x1e) == 0x10 (bltzal/bgezal).
		local target = band(pc + 4 + simm * 4, 0xFFFFFFFF)
		if rt == 0x00 then return { OP_BLTZ, rsSlot, 0, target }
		elseif rt == 0x01 then return { OP_BGEZ, rsSlot, 0, target }
		elseif rt == 0x10 then return { OP_BLTZAL, rsSlot, 0, target }
		elseif rt == 0x11 then return { OP_BGEZAL, rsSlot, 0, target }
		elseif band(rt, 1) == 0 then return { OP_BLTZ, rsSlot, 0, target }
		end
		return { OP_BGEZ, rsSlot, 0, target }
	elseif opcode == 0x02 then
		return { OP_J, 0, 0, bor(band(pc + 4, 0xF0000000), lshift(band(word, 0x03FFFFFF), 2)) }
	elseif opcode == 0x03 then
		return { OP_JAL, 0, 0, bor(band(pc + 4, 0xF0000000), lshift(band(word, 0x03FFFFFF), 2)) }
	elseif opcode == 0x04 then return { OP_BEQ, rsSlot, rtSlot, band(pc + 4 + simm * 4, 0xFFFFFFFF) }
	elseif opcode == 0x05 then return { OP_BNE, rsSlot, rtSlot, band(pc + 4 + simm * 4, 0xFFFFFFFF) }
	elseif opcode == 0x06 then return { OP_BLEZ, rsSlot, 0, band(pc + 4 + simm * 4, 0xFFFFFFFF) }
	elseif opcode == 0x07 then return { OP_BGTZ, rsSlot, 0, band(pc + 4 + simm * 4, 0xFFFFFFFF) }
	elseif opcode == 0x08 then return { OP_ADDI, rsSlot, rtSlot, simm }
	elseif opcode == 0x09 then return { OP_ADDIU, rsSlot, rtSlot, simm }
	elseif opcode == 0x0A then return { OP_SLTI, rsSlot, rtSlot, simm }
	elseif opcode == 0x0B then return { OP_SLTIU, rsSlot, rtSlot, imm }
	elseif opcode == 0x0C then return { OP_ANDI, rsSlot, rtSlot, imm }
	elseif opcode == 0x0D then return { OP_ORI, rsSlot, rtSlot, imm }
	elseif opcode == 0x0E then return { OP_XORI, rsSlot, rtSlot, imm }
	elseif opcode == 0x0F then return { OP_LUI, rtSlot, 0, imm }
	elseif opcode == 0x10 then
		-- cop0: cfc0/ctc0 no-op; rs=0x10 dispatches by funct (rfe, tlb -> ri); every other rs no-ops -- ps1-tests prove duckstation's "else -> ri" is wrong for the ps1.
		if rs == 0x00 then return { OP_MFC0, rd, rtSlot, 0 }
		elseif rs == 0x04 then return { OP_MTC0, rd, rtSlot, 0 }
		elseif rs == 0x02 or rs == 0x06 then return { OP_COP0_NOP, 0, 0, 0 }
		elseif rs == 0x10 then
			if funct == 0x10 then return { OP_RFE, 0, 0, 0 }
			elseif funct == 0x01 or funct == 0x02 or funct == 0x06 or funct == 0x08 then return { OP_COP0_INVALID, 0, 0, word }
			end
			return { OP_COP0_NOP, 0, 0, 0 }
		end
		return { OP_COP0_NOP, 0, 0, 0 }
	elseif opcode == 0x11 or opcode == 0x13 then
		-- cop1/cop3: absent fpu raises cpu (ce = 1/3) when its cu bit is clear; no-op with the bit set.
		return { OP_COP13_NOP, 0, 0, opcode == 0x11 and 1 or 3 }
	elseif opcode == 0x12 then
		if band(word, 0x02000000) ~= 0 then return { OP_GTE, 0, 0, word }
		elseif rs == 0x00 then return { OP_MFC2, rd, rtSlot, 0 }
		elseif rs == 0x02 then return { OP_CFC2, rd, rtSlot, 0 }
		elseif rs == 0x04 then return { OP_MTC2, rd, rtSlot, 0 }
		elseif rs == 0x06 then return { OP_CTC2, rd, rtSlot, 0 }
		end
		return { OP_COP2_INVALID, 0, 0, word }
	elseif opcode == 0x20 then return { OP_LB, rsSlot, rtSlot, simm }
	elseif opcode == 0x21 then return { OP_LH, rsSlot, rtSlot, simm }
	elseif opcode == 0x22 then return { OP_LWL, rsSlot, rtSlot, simm }
	elseif opcode == 0x23 then return { OP_LW, rsSlot, rtSlot, simm }
	elseif opcode == 0x24 then return { OP_LBU, rsSlot, rtSlot, simm }
	elseif opcode == 0x25 then return { OP_LHU, rsSlot, rtSlot, simm }
	elseif opcode == 0x26 then return { OP_LWR, rsSlot, rtSlot, simm }
	elseif opcode == 0x28 then return { OP_SB, rsSlot, rtSlot, simm }
	elseif opcode == 0x29 then return { OP_SH, rsSlot, rtSlot, simm }
	elseif opcode == 0x2A then return { OP_SWL, rsSlot, rtSlot, simm }
	elseif opcode == 0x2B then return { OP_SW, rsSlot, rtSlot, simm }
	elseif opcode == 0x2E then return { OP_SWR, rsSlot, rtSlot, simm }
	elseif opcode == 0x30 or opcode == 0x31 or opcode == 0x33 then return { OP_LWC013, rsSlot, simm, opcode == 0x30 and 0 or (opcode == 0x31 and 1 or 3) }
	elseif opcode == 0x32 then return { OP_LWC2, rsSlot, rt, simm }
	elseif opcode == 0x34 or opcode == 0x35 or opcode == 0x36 or opcode == 0x37 then return { OP_RI, 0, 0, word }
	elseif opcode == 0x38 or opcode == 0x39 or opcode == 0x3B then return { OP_SWC013, rsSlot, simm, opcode == 0x38 and 0 or (opcode == 0x39 and 1 or 3) }
	elseif opcode == 0x3A then return { OP_SWC2, rsSlot, rt, simm }
	elseif opcode == 0x3C or opcode == 0x3D or opcode == 0x3E or opcode == 0x3F then return { OP_RI, 0, 0, word }
	end
	return { OP_RI, 0, 0, word }
end

-- dump the recent-write window around pc for exception diagnostics (no-op when write tracking is off).
local function dumpRamWritesAround(self, pc)
	local mem = self.memory
	if mem and mem.dumpRecentRamWrites then
		local physicalPc = mem:physicalAddress(pc or 0)
		mem:dumpRecentRamWrites(band(physicalPc - 0x200, 0x1FFFFFFF), band(physicalPc + 0x200, 0x1FFFFFFF), 40)
	end
end

-- execute a cached block while keeping the same per-instruction bookkeeping as
-- stepbaseline.
local function runBlock(self, blk)
	local ops = blk.ops
	local as = blk.as
	local bs = blk.bs
	local cs = blk.cs
	local n = blk.n
	local reg = self.registers
	local mem = self.memory
	local cop0 = self.cop0
	local cpi = self.cyclesPerInstruction or 1
	local diffHook = self._diffHook
	local startPc = blk.startPc
	local endPc = startPc + n * 4
	-- instructioncount has no mid-block readers, so it accumulates in a local and flushes at block exit.
	local periphBatch = mem._periphBatch
	-- flux accumulates in a register and flushes at every exit (one fewer hash-part read/write per instruction in the hot loop).
	local flux = mem.flux or 0
	local insCount = self.instructionCount or 0
	local joypad = mem.joypad
	local dma = mem.dma
	-- the menu spins on gpustat (0x1f801814); alias the gpu so the poll
	-- fast path in op_lw is two field reads instead of a bus dispatch.
	local gpu = mem.gpu
	local ver = self._pageVer
	-- stable aliases for the ram load fast path (the mirror windows refresh on every slow-path write).
	local ram32 = mem.ram32
	local ramMappedEnd = mem.ramMappedEnd
	local ramMask = mem.ramMask
	-- trace-loop budget: re-enter the block body on back-edges (step() re-entry dominates tight loops), bounded per step and
	-- version-checked so smc/dma breaks out.  4096 amortizes dispatch best (~1.7x on boot); front-ends override per run.
	local traceBudget = self._traceBudget or 4096
	local entryCount = insCount
	local first = 1

	repeat
		local currentPc = startPc + (first - 1) * 4
		for i = first, n do
		-- capture the delay-slot branch state before the interrupt check, folded into _delayslottarget (nil/false/target).
		local pb = self.pendingBranch
		local delaySlotTarget
		if pb then
			delaySlotTarget = pb.delay == 1 and pb.target or nil
			self._delaySlotTarget = delaySlotTarget
		else
			delaySlotTarget = self._delaySlotTarget
			if delaySlotTarget ~= nil and delaySlotTarget ~= false then
				self._delaySlotTarget = nil
			end
		end

		local op = ops[i]
		local a = as[i]
		local b = bs[i]
		local c = cs[i]

		-- inlined checkinterrupts via the _irqstate cache: band(iStat, iMask) plus bit 31 = dirty (pending, or mtc0 wrote cause bits 8-9).  the common case is one field read.
		do
			local irqState = mem._irqState
			if irqState ~= 0 then
				local pending = band(irqState, 0x7FFFFFFF)
				if pending ~= 0 then
					local newCause = bor(band(cop0.cause, 0xFFFF00FF), 0x00000400)
					if newCause ~= cop0.cause then
						cop0.cause = newCause
					end
					local status = cop0.status
					if band(status, 1) ~= 0 and band(status, 0x00000400) ~= 0 then
					-- a pending cop2 gte command still executes while the interrupt is serviced (duckstation dispatchinterrupt).
					if op == OP_GTE then
						self:gteStallForOp(c)
						self.gte:execute(c)
					end
					self:raiseException(0, nil)
					-- interrupt taken: the current instruction is skipped; yield the block with the same accounting as stepbaseline's interrupt return.
					mem.flux = flux
					mem:advanceCycles(cpi)
					self.inDelaySlot = false
					reg[1] = 0
					insCount += 1
					self.instructionCount = insCount
					if diffHook then
						diffHook(self, currentPc)
					end
					return true
				end
			else
				-- dirty bit set with nothing pending: drop the ip bits so cause matches what checkinterrupts always produced.
				mem._irqState = 0
				cop0.cause = band(cop0.cause, 0xFFFF00FF)
			end
		end
		end

		-- sequential next-pc is implicit: nextpc is only written on a taken-branch commit or exception, so the common path skips the write.
		local oldBranch = pb
		local oldLoad = self.pendingLoad
		-- the clears are conditional: nothing pending in the common case, so the hot path does zero pending-state writes.
		if oldBranch then self.pendingBranch = nil end
		if oldLoad then self.pendingLoad = nil end
		local notTakenDelay = delaySlotTarget == false
		if notTakenDelay then self._delaySlotTarget = nil end
		-- indelayslot is a hash-part write true only during a delay-slot instruction; write it only then (always false at block entry).
		if oldBranch ~= nil and oldBranch.delay == 1 or notTakenDelay then
			self.inDelaySlot = true
		end

		local newBranch = nil
		local newLoad = nil

		if op <= OP_SLTU then
			-- alu register group (bit32 results are already 32-bit; the redundant band is dropped)
			if op == OP_SLL then
				if c ~= 1 then reg[c] = lshift(reg[a], b) end
			elseif op == OP_ADDU then
				if c ~= 1 then reg[c] = band(reg[a] + reg[b], 0xFFFFFFFF) end
			elseif op == OP_SUBU then
				if c ~= 1 then reg[c] = band(reg[a] - reg[b], 0xFFFFFFFF) end
			elseif op == OP_XOR then
				if c ~= 1 then reg[c] = bxor(reg[a], reg[b]) end
			elseif op == OP_AND then
				if c ~= 1 then reg[c] = band(reg[a], reg[b]) end
			elseif op == OP_SLT then
				if c ~= 1 then
					reg[c] = ((reg[a] >= 0x80000000 and reg[a] - 0x100000000 or reg[a]) < (reg[b] >= 0x80000000 and reg[b] - 0x100000000 or reg[b])) and 1 or 0
				end
			elseif op == OP_SRL then
				if c ~= 1 then reg[c] = rshift(reg[a], b) end
			elseif op == OP_SRA then
				local value = reg[a]
				if band(value, 0x80000000) ~= 0 then
					if c ~= 1 then reg[c] = arshift(value, b) end
				else
					if c ~= 1 then reg[c] = rshift(value, b) end
				end
			elseif op == OP_SLLV then
				local shift = band(reg[a], 0x1F)
				if c ~= 1 then reg[c] = lshift(reg[b], shift) end
			elseif op == OP_SRLV then
				local shift = band(reg[a], 0x1F)
				if c ~= 1 then reg[c] = rshift(reg[b], shift) end
			elseif op == OP_SRAV then
				local shift = band(reg[a], 0x1F)
				local value = reg[b]
				if band(value, 0x80000000) ~= 0 then
					if c ~= 1 then reg[c] = arshift(value, shift) end
				else
					if c ~= 1 then reg[c] = rshift(value, shift) end
				end
			elseif op == OP_MULT then
				local aU = reg[a]
				local bU = reg[b]
				self:stallMulDiv()
				self.hi, self.lo = mult64(aU, bU)
				if aU >= 0x80000000 then self.hi = band(self.hi - bU, 0xFFFFFFFF) end
				if bU >= 0x80000000 then self.hi = band(self.hi - aU, 0xFFFFFFFF) end
				self:armMulDiv(multTicksSigned(signed(aU)))
			elseif op == OP_MULTU then
				self:stallMulDiv()
				self.hi, self.lo = mult64(reg[a], reg[b])
				self:armMulDiv(multTicksUnsigned(reg[a]))
			elseif op == OP_DIV then
				local divisor = signed(reg[b])
				local dividend = signed(reg[a])
				self:stallMulDiv()
				if divisor == 0 then
					-- divide by zero: lo = (num >= 0) ? 0xffffffff : 1; hi = num
					self.lo = (dividend >= 0) and 0xFFFFFFFF or 1
					self.hi = band(dividend, 0xFFFFFFFF)
				elseif reg[a] == 0x80000000 and divisor == -1 then
					-- unrepresentable overflow: lo = 0x80000000; hi = 0
					self.lo = 0x80000000
					self.hi = 0
				else
					self.lo, self.hi = divModTrunc(dividend, divisor)
				end
				self:armMulDiv(35)
			elseif op == OP_DIVU then
				local divisor = reg[b]
				local dividend = reg[a]
				self:stallMulDiv()
				if divisor == 0 then
					-- divide by zero: lo = 0xffffffff; hi = num
					self.lo = 0xFFFFFFFF
					self.hi = band(dividend, 0xFFFFFFFF)
				else
					self.lo = band(math.floor(dividend / divisor), 0xFFFFFFFF)
					self.hi = band(dividend % divisor, 0xFFFFFFFF)
				end
				self:armMulDiv(35)
			elseif op == OP_MFHI then
				self:stallMulDiv()
				if c ~= 1 then reg[c] = self.hi end
			elseif op == OP_MTHI then
				self:stallMulDiv()
				self.hi = reg[a]
			elseif op == OP_MFLO then
				self:stallMulDiv()
				if c ~= 1 then reg[c] = self.lo end
			elseif op == OP_MTLO then
				self:stallMulDiv()
				self.lo = reg[a]
			elseif op == OP_ADD then
				local av = reg[a]
				local bv = reg[b]
				local result = (av >= 0x80000000 and av - 0x100000000 or av) + (bv >= 0x80000000 and bv - 0x100000000 or bv)
				if result < -0x80000000 or result > 0x7FFFFFFF then
					self:raiseException(12, nil)
				else
					if c ~= 1 then reg[c] = band(result, 0xFFFFFFFF) end
				end
			elseif op == OP_SUB then
				local av = reg[a]
				local bv = reg[b]
				local result = (av >= 0x80000000 and av - 0x100000000 or av) - (bv >= 0x80000000 and bv - 0x100000000 or bv)
				if result < -0x80000000 or result > 0x7FFFFFFF then
					self:raiseException(12, nil)
				else
					if c ~= 1 then reg[c] = band(result, 0xFFFFFFFF) end
				end
			elseif op == OP_OR then
				if c ~= 1 then reg[c] = bor(reg[a], reg[b]) end
			elseif op == OP_NOR then
				if c ~= 1 then reg[c] = bnot(bor(reg[a], reg[b])) end
			elseif op == OP_SLTU then
				if c ~= 1 then reg[c] = (reg[a] < reg[b]) and 1 or 0 end
			end
		elseif op <= OP_BREAK then
			-- control
			if op == OP_JR then
				local target = reg[a]
				if band(target, 3) ~= 0 then
					-- unaligned jump target: adel, badvaddr = target, epc = target
					self:raiseException(4, target, target)
				else
					newBranch = self:requestBranch(target)
				end
			elseif op == OP_JALR then
				local target = reg[a]
				if c ~= 1 then reg[c] = band(currentPc + 8, 0xFFFFFFFF) end
				if band(target, 3) ~= 0 then
					self:raiseException(4, target, target)
				else
					newBranch = self:requestBranch(target)
				end
			elseif op == OP_SYSCALL then
				self:raiseException(8, nil)
			elseif op == OP_BREAK then
				self:raiseException(9, nil)
			end
		elseif op <= OP_LUI then
			-- alu immediate group (ordered by execution frequency: addiu 9.3%,
			-- lui 5.8%; the rare add-overflow/slti checks are last)
			if op == OP_ADDIU then
				if b ~= 1 then reg[b] = band(reg[a] + c, 0xFFFFFFFF) end
			elseif op == OP_LUI then
				if a ~= 1 then reg[a] = lshift(c, 16) end
			elseif op == OP_ANDI then
				if b ~= 1 then reg[b] = band(reg[a], c) end
			elseif op == OP_ORI then
				if b ~= 1 then reg[b] = bor(reg[a], c) end
			elseif op == OP_XORI then
				if b ~= 1 then reg[b] = bxor(reg[a], c) end
			elseif op == OP_ADDI then
				local av = reg[a]
				local result = (av >= 0x80000000 and av - 0x100000000 or av) + c
				if result < -0x80000000 or result > 0x7FFFFFFF then
					self:raiseException(12, nil)
				else
					if b ~= 1 then reg[b] = band(result, 0xFFFFFFFF) end
				end
			elseif op == OP_SLTI then
				if b ~= 1 then
					reg[b] = ((reg[a] >= 0x80000000 and reg[a] - 0x100000000 or reg[a]) < c) and 1 or 0
				end
			elseif op == OP_SLTIU then
				if b ~= 1 then reg[b] = (reg[a] < c) and 1 or 0 end
			end
		elseif op <= OP_SWC2 then
			-- loads/stores: ram fast paths inlined (mirroring memory:read8/16/32 and write8/16/32 exactly, incl. block invalidation), so lw/sw is one table access.
			if op == OP_LW then
				local addr = reg[a] + c
				local loaded
				if band(addr, 3) ~= 0 then
					self:raiseException(4, addr)
					loaded = 0
				else
					local region = band(addr, 0xE0000000)
					if region == 0x80000000 or region == 0xA0000000 then
						local physical = band(addr, 0x1FFFFFFF)
						if physical < ramMappedEnd then
							loaded = ram32[band(physical, ramMask) // 4 + 1]
						else
							loaded = mem:read32(addr)
							if mem.busError then
								mem.busError = false
								self:raiseException(7)
								loaded = 0
							end
						end
					else
						-- gpustat poll fast path: the gpu caches the composed value, so a hit is one field read; a miss falls through to the bus path.
						if addr == 0x1F801814 then
							loaded = gpu._statusCache
							if loaded == nil then
								loaded = mem:read32(addr)
								if mem.busError then
									mem.busError = false
									self:raiseException(7)
									loaded = 0
								end
							end
						else
							loaded = mem:read32(addr)
							if mem.busError then
								mem.busError = false
								self:raiseException(7)
								loaded = 0
							end
						end
					end
				end
				local lcells = self._loadCells
				local lidx = self._loadCellIdx
				local lcell = lcells[lidx]
				self._loadCellIdx = lidx == 1 and 2 or 1
				lcell.register = b - 1
				lcell.value = band(loaded, 0xFFFFFFFF)
				lcell.delay = 1
				newLoad = lcell
			elseif op == OP_SW then
				local addr = reg[a] + c
				if band(addr, 3) ~= 0 then
					self:raiseException(5, addr)
				else
					mem:write32(addr, reg[b])
					if mem.busError then
						mem.busError = false
						self:raiseException(7)
					end
				end
			elseif op == OP_LH then
				local addr = reg[a] + c
				local loaded
				if band(addr, 1) ~= 0 then
					self:raiseException(4, addr)
					loaded = 0
				else
					local v = mem:read16(addr)
					if mem.busError then
						mem.busError = false
						self:raiseException(7)
						loaded = 0
					else
						loaded = v >= 0x8000 and v - 0x10000 or v
					end
				end
				local lcells = self._loadCells
				local lidx = self._loadCellIdx
				local lcell = lcells[lidx]
				self._loadCellIdx = lidx == 1 and 2 or 1
				lcell.register = b - 1
				lcell.value = band(loaded, 0xFFFFFFFF)
				lcell.delay = 1
				newLoad = lcell
			elseif op == OP_SH then
				local addr = reg[a] + c
				if band(addr, 1) ~= 0 then
					self:raiseException(5, addr)
				else
					mem:write16(addr, reg[b])
					if mem.busError then
						mem.busError = false
						self:raiseException(7)
					end
				end
			elseif op == OP_LBU then
				local v = mem:read8(reg[a] + c)
				if mem.busError then
					mem.busError = false
					self:raiseException(7)
					v = 0
				end
				local lcells = self._loadCells
				local lidx = self._loadCellIdx
				local lcell = lcells[lidx]
				self._loadCellIdx = lidx == 1 and 2 or 1
				lcell.register = b - 1
				lcell.value = band(v, 0xFFFFFFFF)
				lcell.delay = 1
				newLoad = lcell
			elseif op == OP_LHU then
				local addr = reg[a] + c
				local loaded
				if band(addr, 1) ~= 0 then
					self:raiseException(4, addr)
					loaded = 0
				else
					loaded = mem:read16(addr)
					if mem.busError then
						mem.busError = false
						self:raiseException(7)
						loaded = 0
					end
				end
				local lcells = self._loadCells
				local lidx = self._loadCellIdx
				local lcell = lcells[lidx]
				self._loadCellIdx = lidx == 1 and 2 or 1
				lcell.register = b - 1
				lcell.value = band(loaded, 0xFFFFFFFF)
				lcell.delay = 1
				newLoad = lcell
			elseif op == OP_SB then
				mem:write8(reg[a] + c, reg[b])
				if mem.busError then
					mem.busError = false
					self:raiseException(7)
				end
			elseif op == OP_LB then
				local v = mem:read8(reg[a] + c)
				if mem.busError then
					mem.busError = false
					self:raiseException(7)
					v = 0
				elseif v >= 0x80 then v = v - 0x100 end
				newLoad = self:requestLoad(b - 1, v)
			elseif op == OP_LWL then
				newLoad = self:requestLoad(b - 1, self:readWordLeft(reg[a] + c, reg[b]))
			elseif op == OP_LWR then
				newLoad = self:requestLoad(b - 1, self:readWordRight(reg[a] + c, reg[b]))
			elseif op == OP_SWL then
				self:writeWordLeft(reg[a] + c, reg[b])
			elseif op == OP_SWR then
				self:writeWordRight(reg[a] + c, reg[b])
			elseif op == OP_LWC2 then
				-- ce2 gate before the memory access (duckstation order)
				if band(self.cop0.status, 0x40000000) == 0 then
					self:raiseException(11, nil, nil, 2)
				else
					self.gte:writeData(b, self:loadWord(reg[a] + c))
				end
			elseif op == OP_SWC2 then
				if band(self.cop0.status, 0x40000000) == 0 then
					self:raiseException(11, nil, nil, 2)
				else
				self:gteStallForRead()
				self:storeWord(reg[a] + c, self.gte:readData(b))
				end
			end
		elseif op <= OP_JAL then
			-- branches + jumps (ordered by execution frequency: beq 6.5%, bne
			-- 5.2%, jal 2.1%, bltz 0.8%; the signed-register + link forms are rare)
			if op == OP_BEQ then
				if reg[a] == reg[b] then newBranch = self:requestBranch(c) else self._delaySlotTarget = false end
			elseif op == OP_BNE then
				if reg[a] ~= reg[b] then newBranch = self:requestBranch(c) else self._delaySlotTarget = false end
			elseif op == OP_JAL then
				reg[32] = band(currentPc + 8, 0xFFFFFFFF)
				newBranch = self:requestBranch(c)
			elseif op == OP_J then
				newBranch = self:requestBranch(c)
			elseif op == OP_BLTZ then
				if (reg[a] >= 0x80000000 and reg[a] - 0x100000000 or reg[a]) < 0 then newBranch = self:requestBranch(c) else self._delaySlotTarget = false end
			elseif op == OP_BGEZ then
				if (reg[a] >= 0x80000000 and reg[a] - 0x100000000 or reg[a]) >= 0 then newBranch = self:requestBranch(c) else self._delaySlotTarget = false end
			elseif op == OP_BLEZ then
				if (reg[a] >= 0x80000000 and reg[a] - 0x100000000 or reg[a]) <= 0 then newBranch = self:requestBranch(c) else self._delaySlotTarget = false end
			elseif op == OP_BGTZ then
				if (reg[a] >= 0x80000000 and reg[a] - 0x100000000 or reg[a]) > 0 then newBranch = self:requestBranch(c) else self._delaySlotTarget = false end
			elseif op == OP_BLTZAL then
				-- the link is written even when the branch is not taken
				reg[32] = band(currentPc + 8, 0xFFFFFFFF)
				if (reg[a] >= 0x80000000 and reg[a] - 0x100000000 or reg[a]) < 0 then newBranch = self:requestBranch(c) else self._delaySlotTarget = false end
			elseif op == OP_BGEZAL then
				reg[32] = band(currentPc + 8, 0xFFFFFFFF)
				if (reg[a] >= 0x80000000 and reg[a] - 0x100000000 or reg[a]) >= 0 then newBranch = self:requestBranch(c) else self._delaySlotTarget = false end
			end
		elseif op <= OP_COP0_NOP then
			-- cop0
			if band(self.cop0.status, 0x2) ~= 0 and band(self.cop0.status, 0x10000000) == 0 then
				-- user mode (kuc) without cu0: cpu, ce=0
				self:raiseException(11, nil, nil, 0)
			elseif op == OP_MFC0 then
				local value = self:getCop0(a)
				if value == nil then
					self:raiseException(10, nil)
				else
					newLoad = self:requestLoad(b - 1, value)
				end
			elseif op == OP_MTC0 then
				if not self:setCop0(a, self:getRegister(b - 1)) then
					self:raiseException(10, nil)
				end
			elseif op == OP_RFE then
				local oldStatus = self.cop0.status
				self.cop0.status = bor(band(oldStatus, bnot(0x0F)), band(rshift(oldStatus, 2), 0x0F))
				if self.traceInterruptGate then
					print(string.format("[ps1-hle] rfe status old=%08X new=%08X iecOld=%d iecNew=%d pc=%08X", oldStatus or 0, self.cop0.status or 0, band(oldStatus or 0, 0x1), band(self.cop0.status or 0, 0x1), self.pc or 0))
				end
			elseif op == OP_COP0_NOP then
				-- cfc0/ctc0 and unknown cop0 commands: no-op
			end
		elseif op >= OP_MFC2 and op <= OP_GTE then
			-- cop2
			if band(self.cop0.status, 0x40000000) == 0 then
				-- ce2 clear: cpu, ce=2
				self:raiseException(11, nil, nil, 2)
			elseif op == OP_MFC2 then
				self:gteStallForRead()
				newLoad = self:requestLoad(b - 1, self.gte:readData(a))
			elseif op == OP_CFC2 then
				self:gteStallForRead()
				newLoad = self:requestLoad(b - 1, self.gte:readCtrl(a))
			elseif op == OP_MTC2 then
				self.gte:writeData(a, self:getRegister(b - 1))
			elseif op == OP_CTC2 then
				self.gte:writeCtrl(a, self:getRegister(b - 1))
			elseif op == OP_GTE then
				self:gteStallForOp(c)
				self.gte:execute(c)
			end
		elseif op == OP_COP0_INVALID then
			-- unknown cop0 rs / tlb opcodes: cu0 gate first (duckstation
			-- begin_instruction(cop0) checks the gate before any dispatch), then ri
			if band(self.cop0.status, 0x2) ~= 0 and band(self.cop0.status, 0x10000000) == 0 then
				self:raiseException(11, nil, nil, 0)
			else
				self:raiseException(10, nil)
			end
		elseif op == OP_COP2_INVALID then
			-- unknown cop2 common-op rs: ce2 gate first (duckstation
			-- begin_instruction(cop2) checks ce2 before dispatch), then ri
			if band(self.cop0.status, 0x40000000) == 0 then
				self:raiseException(11, nil, nil, 2)
			else
				self:raiseException(10, nil)
			end
		elseif op == OP_LWC013 or op == OP_SWC013 or op == OP_COP13_NOP then
			-- lwc0/1/3 read and discard, swc0/1/3 write 0 -- but every absent coprocessor raises cpu (ce = its number) when its cu bit is clear, even in kernel mode.  the cu gate runs before the memory access.
			local ce = c
			local cuBit = ce == 0 and 0x10000000 or (ce == 1 and 0x20000000 or 0x80000000)
			if band(self.cop0.status, cuBit) == 0 then
				self:raiseException(11, nil, nil, ce)
			elseif op == OP_LWC013 then
				self:loadWord(reg[a] + b)
			elseif op == OP_SWC013 then
				self:storeWord(reg[a] + b, 0)
			end
		elseif op == OP_RI then
			print(string.format("[ps1-hle] RI opcode=%02X instruction=%08X pc=%08X", bit32.rshift(c, 26), c or 0, currentPc or 0))
			dumpRamWritesAround(self, currentPc)
			self:raiseException(10, nil)
		end

		if self.pc ~= currentPc then
			-- an exception redirected pc to the vector: abort the block like stepbaseline's vector special-case.
			self.pendingBranch = nil
			self.pendingLoad = nil			mem.flux = flux
			mem:advanceCycles(cpi)
			self.inDelaySlot = false
			reg[1] = 0
			insCount += 1
			self.instructionCount = insCount
			if diffHook then
				diffHook(self, currentPc)
			end
			return true
		end

		-- load-delay hazard detection: record which gpr the delay-slot instruction wrote; only needed when a pending load exists.
		if oldLoad then
			local wroteReg = nil
			if op <= OP_SLTU then
				if op ~= OP_MULT and op ~= OP_MULTU and op ~= OP_DIV and op ~= OP_DIVU and op ~= OP_MTHI and op ~= OP_MTLO then
					wroteReg = c - 1
				end
			elseif op >= OP_ADDI and op <= OP_LUI then
				wroteReg = b - 1
			elseif op == OP_JALR then
				wroteReg = c - 1
			elseif op == OP_JAL then
				wroteReg = 31
			elseif op == OP_BLTZAL or op == OP_BGEZAL then
				wroteReg = 31
			end
			self._delaySlotWroteReg = wroteReg
		end

		if oldBranch or oldLoad then
			self:commitPendingState(oldBranch, oldLoad)
		end
		if newBranch then
			self.pendingBranch = newBranch
		end
		if newLoad then
			self.pendingLoad = newLoad
		end

		-- advance pc: delay-slot iteration takes pc from nextpc (a taken branch committed there); sequential steps never wrap past 2^32, so no masking needed.
		if pb then
			self.pc = self.nextPc
		else
			self.pc = currentPc + 4
		end
		-- indelayslot is cleared here for the next instruction; the write only happens when it can change.
		if oldBranch or notTakenDelay then
			self.inDelaySlot = false
		end
		-- inline memory:advancecycles (identical logic incl. joypad + dma): avoids a method dispatch per instruction.
		mem.cycleCount += cpi
		-- single cached gate (ackAsserted or pendingPadIrqCycle ~= nil) instead of two field reads per instruction.
		if joypad._needsStep then
			if joypad.ackAsserted and mem.cycleCount - joypad.ackCycle > 450 then
				joypad.ackAsserted = false
				joypad._needsStep = joypad.pendingPadIrqCycle ~= nil
			end
			if joypad.pendingPadIrqCycle and mem.cycleCount >= joypad.pendingPadIrqCycle then
				joypad.pendingPadIrqCycle = nil
				joypad.irqFlag = true
				joypad.ackAsserted = true
				joypad.ackCycle = mem.cycleCount
				joypad._needsStep = true
				mem:setInterruptLine(7, true)
			end
		end
		flux += cpi
		if flux >= periphBatch then
			local batch = flux
			flux = 0
			mem.spu:step(batch)
			mem.gpu:step(batch)
			mem.cdrom:step(batch)
			mem.timers:advance(batch)
		end
		if dma._needsStep then
			-- exact conditions inside the gate (the dma is idle ~always, so the
			-- single cached field replaces two field reads per instruction).
			if dma.haltTicksRemaining > 0 then
				dma:consumeHaltTicks(cpi)
			elseif dma.resumePending and not dma.inTickCharge then
				dma:resumeHalted()
			end
		end
		-- buserror is consumed by the latching instruction except the unchecked trailing write32 in swl/swr, so the defensive clear only runs after those two.
		if op == OP_SWL or op == OP_SWR then
			mem.busError = false
		end
		insCount += 1

		if diffHook then
			self.instructionCount = insCount
			diffHook(self, currentPc)
		end

		currentPc += 4
	end

		-- trace-loop exit: hop internally on back-edges and cross-block chaining (call/return dispatch) while the budget allows;
		-- break out for hle pcs, pending delay-slot/load state, stale or uncached targets, or an exhausted budget.  every hop re-validates page versions.
		local tracePc = self.pc
		if insCount - entryCount >= traceBudget then
			break
		end
		if tracePc >= startPc and tracePc < endPc then
			if blk.v1 == (ver[blk.p1] or 0)
				and (not blk.p2 or blk.v2 == (ver[blk.p2] or 0)) then
				first = (tracePc - startPc) // 4 + 1
			else
				break
			end
		elseif not isSpecialPc(tracePc) and not self.pendingBranch and not self.pendingLoad then
			local blk2 = self._blocks[tracePc]
			if blk2
				and blk2.v1 == (ver[blk2.p1] or 0)
				and (not blk2.p2 or blk2.v2 == (ver[blk2.p2] or 0)) then
				-- hop into the target block and keep running internally.
				blk = blk2
				ops = blk.ops
				as = blk.as
				bs = blk.bs
				cs = blk.cs
				n = blk.n
				startPc = blk.startPc
				endPc = startPc + n * 4
				first = 1
			else
				break
			end
		else
			break
		end
	until false

	-- natural loop exit: flush the accumulated instruction count and restore the sequential nextpc.
	self.nextPc = self.pc + 4
	self.instructionCount = insCount
	mem.flux = flux
	return true
end

local COP0_STATUS_BEV = 0x00400000

local SR_WRITE_MASK = 0xF27FFF3F
local CAUSE_WRITE_MASK = 0x00000300
local DCIC_WRITE_MASK = 0xFF80F03F
local COPO_REGISTERED = {
	[3] = true, [5] = true, [6] = true, [7] = true, [8] = true, [9] = true,
	[11] = true, [12] = true, [13] = true, [14] = true, [15] = true,
}

function CPU.new(memory)
	local self = setmetatable({}, CPU)
	self.memory = memory
	self.registers = table.create(32, 0)
	self.cop0 = {
		status = COP0_STATUS_BEV,
		cause = 0,
		epc = 0,
		badvaddr = 0,
		prid = 0x00000002,
		bpc = 0,
		bpcm = 0,
		bda = 0,
		bdam = 0,
		dcic = 0,
		tar = 0,
	}
	self.hi = 0
	self.lo = 0
	self.pc = 0xBFC00000
	self.nextPc = 0xBFC00004
	self.pendingBranch = nil
	self.pendingLoad = nil
	-- per-step delay-slot bookkeeping: branch capture folded into one field (nil/false/target), plus the register the delay-slot instruction wrote.
	self._delaySlotTarget = nil
	self._delaySlotWroteReg = nil
	-- two reusable cells per pending state: a new branch/load fills the cell the previous one left free, so the step-entry snapshot survives.
	self._branchCells = { { target = 0, delay = 0, sourcePc = 0 }, { target = 0, delay = 0, sourcePc = 0 } }
	self._loadCells = { { register = 0, value = 0, delay = 0 }, { register = 0, value = 0, delay = 0 } }
	self._branchCellIdx = 1
	self._loadCellIdx = 1
	self.inDelaySlot = false
	self.halted = false
	self.cyclesPerInstruction = 1
	self.traceInterruptGate = false
	self.traceExceptions = false
	self._interruptExceptionLogCounter = 0
	self.gte = GTE.new()
	-- gte busy deadline (cpu cycle at which the in-flight gte op completes);
	-- 0 = idle.  transient pipeline state, not checkpointed.
	self.gteBusyUntil = 0
	self.mulDivBusyUntil = 0
	-- block-cache interpreter state (see the block engine above).  off by
	-- default; runtime enables it via cpu.useblocks = true.
	self.useBlocks = false
	self._blocks = {}
	self._pageVer = {}
	self._hotPages = {}
	self.instructionCount = 0
	-- ram/scratchpad writes invalidate decoded blocks (overlay loads and decompression write code); no-op unless the page holds blocks.
	self.memory.onRamWrite = function(physical)
		self:onRamWrite(physical)
	end
	-- wire the reverse link too: memory's ram-write paths invalidate blocks through memory.cpu, so any memory + cpu pair is smc-safe.  runtime re-wires it; harmless.
	self.memory.cpu = self
	return self
end

function CPU:reset(entryPoint)
	for index = 1, 32 do
		self.registers[index] = 0
	end
	self:setRegister(9, 0x1F801000)
	self.hi = 0
	self.lo = 0
	self.cop0.status = COP0_STATUS_BEV
	self.cop0.cause = 0
	self.cop0.epc = 0
	self.cop0.badvaddr = 0
	self.pc = entryPoint or 0xBFC00000
	self.nextPc = band(self.pc + 4, 0xFFFFFFFF)
	self.pendingBranch = nil
	self.pendingLoad = nil
	self.inDelaySlot = false
	self.halted = false
	self.gteBusyUntil = 0
	self.mulDivBusyUntil = 0
	self:invalidateAllBlocks()
	self.instructionCount = 0
end

function CPU:setRegister(index, value)
	if index == 0 then
		return
	end
	self.registers[index + 1] = band(value, 0xFFFFFFFF)
end

function CPU:getRegister(index)
	if index == 0 then
		return 0
	end
	return self.registers[index + 1] or 0
end

function CPU:setCop0(index, value)
	-- false for an unimplemented register (mtc0 -> ri).  write masks match duckstation's s_cop0_table: sr 0xf27fff3f, cause 0x00000300, dcic 0xff80f03f; tar/badvaddr/epc/prid read-only.
	value = band(value, 0xFFFFFFFF)
	if index == 3 then
		self.cop0.bpc = value
	elseif index == 5 then
		self.cop0.bda = value
	elseif index == 6 then
		-- tar: write ignored
	elseif index == 7 then
		self.cop0.dcic = bor(band(self.cop0.dcic or 0, bnot(DCIC_WRITE_MASK)), band(value, DCIC_WRITE_MASK))
	elseif index == 8 then
		-- badvaddr: write ignored
	elseif index == 9 then
		self.cop0.bdam = value
	elseif index == 11 then
		self.cop0.bpcm = value
	elseif index == 12 then
		local oldStatus = self.cop0.status or 0
		self.cop0.status = bor(band(oldStatus, bnot(SR_WRITE_MASK)), band(value, SR_WRITE_MASK))
		-- cache isolation: bit 16 (isc)
		if self.memory then
			self.memory.cacheIsolated = band(self.cop0.status, 0x00010000) ~= 0
		end
	elseif index == 13 then
		self.cop0.cause = bor(band(self.cop0.cause or 0, bnot(CAUSE_WRITE_MASK)), band(value, CAUSE_WRITE_MASK))
		-- an mtc0 can write cause ip bits (8-9): mark the irq-state cache dirty so the block loop's drop path clears them.
		if band(self.cop0.cause, 0x0000FF00) ~= 0 then
			self.memory._irqState = bor(self.memory._irqState or 0, 0x80000000)
		end

	elseif index == 14 then
		-- epc: write ignored (read-only)
	else
		-- prid (15) and all unimplemented registers: reserved instruction
		return false
	end
	return true
end

function CPU:getCop0(index)
	-- returns nil for an unimplemented register (mfc0 -> ri); the full
	-- duckstation register set (r3/5/6/7/8/9/11/12/13/14/15).
	if not COPO_REGISTERED[index] then
		return nil
	end
	local c = self.cop0
	if index == 3 then return c.bpc
	elseif index == 5 then return c.bda
	elseif index == 6 then return c.tar
	elseif index == 7 then return c.dcic
	elseif index == 8 then return c.badvaddr
	elseif index == 9 then return c.bdam
	elseif index == 11 then return c.bpcm
	elseif index == 12 then return c.status
	elseif index == 13 then return c.cause
	elseif index == 14 then return c.epc
	elseif index == 15 then return c.prid
	end
	return 0
end

function CPU:raiseException(code, badAddress, epcOverride, ce)
	-- exception write mask 0xf000007c: only excode (2-6), ce (28-29), bd (31), bt (30); everything else (incl. ip bits) is preserved.
	local cause = band(self.cop0.cause, bnot(0xF000007C))
	local exceptionCode = lshift(band(code, 0x1F), 2)
	local faultPc = self.pc
	-- checkinterrupts() runs before indelayslot refreshes, so the previous instruction's branch is visible through the step-top capture.
	local delaySlotTarget = self._delaySlotTarget
	local inBranchDelay = self.inDelaySlot == true or delaySlotTarget ~= nil
	local inLoadDelay = self.pendingLoad ~= nil and self.pendingLoad.delay == 1
	if inBranchDelay then
		cause = bor(cause, 0x80000000)
		if delaySlotTarget then
			-- bt (bit 30): the branch was taken.  tar is only updated for a
			-- taken branch (psx-spx cop0r6) and holds the branch target.
			cause = bor(cause, 0x40000000)
			self.cop0.tar = delaySlotTarget
		end
		self.cop0.epc = band(self.pc - 4, 0xFFFFFFFF)
	elseif inLoadDelay then
		-- r3000 load delay slot: point epc at the load so it re-executes instead of resuming with the load lost.
		self.cop0.epc = band(self.pc - 4, 0xFFFFFFFF)
	elseif epcOverride ~= nil then
		self.cop0.epc = band(epcOverride, 0xFFFFFFFF)
	else
		self.cop0.epc = band(self.pc, 0xFFFFFFFF)
	end
	if badAddress ~= nil then
		self.cop0.badvaddr = band(badAddress, 0xFFFFFFFF)
	end
	local newCause = band(bor(cause, exceptionCode), 0xFFFFFFFF)
	if ce ~= nil then
		newCause = bor(newCause, lshift(band(ce, 3), 28))
	end
	self.cop0.cause = newCause
	local statusLow = band(self.cop0.status, 0x3F)
	self.cop0.status = bor(band(self.cop0.status, bnot(0x3F)), band(lshift(statusLow, 2), 0x3F))
	self.pendingBranch = nil
	self.pendingLoad = nil
	local exceptionVector = 0x80000080
	if band(self.cop0.status, COP0_STATUS_BEV) ~= 0 then
		exceptionVector = 0xBFC00180
	end
	self.pc = exceptionVector
	self.nextPc = band(exceptionVector + 4, 0xFFFFFFFF)
	self.inDelaySlot = false

	-- sdk isr hook interception: runtime may redirect interrupt handling
	-- to a custom isr instead of the bios exception handler.
	if code == 0 and self.interceptException then
		local newPc = self.interceptException(self, exceptionVector, self.cop0.epc, self.cop0.status, self.cop0.cause)
		if newPc then
			self.pc = band(newPc, 0xFFFFFFFF)
			self.nextPc = band(newPc + 4, 0xFFFFFFFF)
			return
		end
	end

	if code == 0 then
		self._interruptExceptionLogCounter = (self._interruptExceptionLogCounter or 0) + 1
		if self.traceExceptions and (self._interruptExceptionLogCounter % 120 == 1) then
			print(string.format(
				"[ps1-hle] raiseException code=%d epc=%08X cause=%08X pc=%08X nextPc=%08X count=%d",
				code,
				self.cop0.epc or 0,
				self.cop0.cause or 0,
				self.pc or 0,
				self.nextPc or 0,
				self._interruptExceptionLogCounter
			))
		end
	else
		print(string.format(
			"[ps1-hle] raiseException code=%d epc=%08X cause=%08X pc=%08X nextPc=%08X delay=%s bad=%s",
			code,
			self.cop0.epc or 0,
			self.cop0.cause or 0,
			self.pc or 0,
			self.nextPc or 0,
			tostring(self.inDelaySlot == true),
			tostring(badAddress)
		))
	end

	if code == 10 and self.memory then
		local epc = band(self.cop0.epc or faultPc or 0, 0xFFFFFFFF)
		if epc >= 0x8005B600 and epc <= 0x8005B800 then
			local instruction = self.memory:read32(epc)
			print(string.format(
				"[ps1-hle] RI table-region epc=%08X instr=%08X r9(fn)=%08X a0=%08X a1=%08X a2=%08X a3=%08X ra=%08X sp=%08X",
				epc,
				instruction,
				self:getRegister(9),
				self:getRegister(4),
				self:getRegister(5),
				self:getRegister(6),
				self:getRegister(7),
				self:getRegister(31),
				self:getRegister(29)
			))
			if self.memory.dumpRecentRamWrites then
				self.memory:dumpRecentRamWrites(0x0005B600, 0x0005B800, 64)
			end
		end
	end
end

function CPU:requestBranch(target)
	-- reuse the cell not in use by a pending branch from the previous step.
	local cells = self._branchCells
	local idx = self._branchCellIdx
	local cell = cells[idx]
	self._branchCellIdx = idx == 1 and 2 or 1
	cell.target = band(target, 0xFFFFFFFF)
	cell.delay = 1
	cell.sourcePc = band(self.pc, 0xFFFFFFFF)
	return cell
end

function CPU:requestLoad(registerIndex, value)
	local cells = self._loadCells
	local idx = self._loadCellIdx
	local cell = cells[idx]
	self._loadCellIdx = idx == 1 and 2 or 1
	cell.register = registerIndex
	cell.value = band(value, 0xFFFFFFFF)
	cell.delay = 1
	return cell
end

function CPU:commitPendingState(oldBranch, oldLoad)
	if oldBranch then
		oldBranch.delay -= 1
		if oldBranch.delay <= 0 then
			self.nextPc = oldBranch.target
		else
			self.pendingBranch = oldBranch
		end
	end

	if oldLoad then
		oldLoad.delay -= 1
		if oldLoad.delay <= 0 then
			-- r3000 load delay hazard: a delay-slot write to the load's destination register overrides and discards the load (duckstation writereg clears the pending delay).  silent hill's kernel printf relies on this.
			if self._delaySlotWroteReg ~= oldLoad.register then
				self:setRegister(oldLoad.register, oldLoad.value)
			end
		else
			self.pendingLoad = oldLoad
		end
	end
end

function CPU:checkInterrupts()
	local pending = band(self.memory.iStat, self.memory.iMask)
	self.cop0.cause = band(self.cop0.cause, 0xFFFF00FF)
	if pending ~= 0 then
		self.cop0.cause = bor(self.cop0.cause, 0x00000400)
	end

	local status = self.cop0.status
	local globalEnabled = band(status, 1) ~= 0
	local hardwareInterruptEnabled = band(status, 0x00000400) ~= 0
	if self.traceInterruptGate then
		print(string.format(
			"[ps1-hle] interrupt gate pc=%08X status=%08X iec=%d pending=%08X cause=%08X cop0Mask=%02X hwMask=%d ioMask=%04X global=%s mask=%s take=%s",
			self.pc or 0,
			status or 0,
			band(status or 0, 0x1),
			pending or 0,
			self.cop0.cause or 0,
			band(rshift(status or 0, 8), 0xFF),
			band(rshift(status or 0, 10), 0x1),
			self.memory.iMask or 0,
			tostring(globalEnabled),
			tostring(hardwareInterruptEnabled),
			tostring(pending ~= 0 and globalEnabled and hardwareInterruptEnabled)
		))
	end
	if pending ~= 0 and globalEnabled and hardwareInterruptEnabled then
		self:raiseException(0, nil)
	end
end

-- a latched bus error raises dbe (excode 7) after the memory access; the load is not completed, so rt stays untouched (psx-spx).
local function raiseBusError(self)
	self.memory.busError = false
	self:raiseException(7)
end

function CPU:loadByte(address, unsignedByte)
	local value = self.memory:read8(address)
	if self.memory.busError then
		raiseBusError(self)
		return 0
	end
	if unsignedByte then
		return value
	end
	return Util.signExtend8(value)
end

function CPU:loadHalf(address, unsignedHalf)
	if band(address, 1) ~= 0 then
		self:raiseException(4, address)
		return 0
	end
	local value = self.memory:read16(address)
	if self.memory.busError then
		raiseBusError(self)
		return 0
	end
	if unsignedHalf then
		return value
	end
	return Util.signExtend16(value)
end

function CPU:loadWord(address)
	if band(address, 3) ~= 0 then
		self:raiseException(4, address)
		return 0
	end
	local value = self.memory:read32(address)
	if self.memory.busError then
		raiseBusError(self)
		return 0
	end
	return value
end

function CPU:storeByte(address, value)
	self.memory:write8(address, value)
	if self.memory.busError then
		raiseBusError(self)
	end
end

function CPU:storeHalf(address, value)
	if band(address, 1) ~= 0 then
		self:raiseException(5, address)
		return
	end
	self.memory:write16(address, value)
	if self.memory.busError then
		raiseBusError(self)
	end
end

function CPU:storeWord(address, value)
	if band(address, 3) ~= 0 then
		self:raiseException(5, address)
		return
	end
	self.memory:write32(address, value)
	if self.memory.busError then
		raiseBusError(self)
	end
end

function CPU:readWordLeft(address, currentValue)
	local shift = band(address, 3)
	local aligned = band(address, bnot(3))
	local word = self.memory:read32(aligned)
	if self.memory.busError then
		raiseBusError(self)
		return 0
	end
	if shift == 0 then
		return bor(band(currentValue, 0x00FFFFFF), band(lshift(word, 24), 0xFFFFFFFF))
	elseif shift == 1 then
		return bor(band(currentValue, 0x0000FFFF), band(lshift(word, 16), 0xFFFFFFFF))
	elseif shift == 2 then
		return bor(band(currentValue, 0x000000FF), band(lshift(word, 8), 0xFFFFFFFF))
	end
	return word
end

function CPU:readWordRight(address, currentValue)
	local shift = band(address, 3)
	local aligned = band(address, bnot(3))
	local word = self.memory:read32(aligned)
	if self.memory.busError then
		raiseBusError(self)
		return 0
	end
	if shift == 0 then
		return word
	elseif shift == 1 then
		return bor(band(currentValue, 0xFF000000), band(rshift(word, 8), 0x00FFFFFF))
	elseif shift == 2 then
		return bor(band(currentValue, 0xFFFF0000), band(rshift(word, 16), 0x0000FFFF))
	end
	return bor(band(currentValue, 0xFFFFFF00), band(rshift(word, 24), 0x000000FF))
end

function CPU:writeWordLeft(address, value)
	local shift = band(address, 3)
	local aligned = band(address, bnot(3))
	local current = self.memory:read32(aligned)
	if self.memory.busError then
		raiseBusError(self)
		return
	end
	if shift == 0 then
		self.memory:write32(aligned, bor(band(current, 0xFFFFFF00), band(rshift(value, 24), 0x000000FF)))
	elseif shift == 1 then
		self.memory:write32(aligned, bor(band(current, 0xFFFF0000), band(rshift(value, 16), 0x0000FFFF)))
	elseif shift == 2 then
		self.memory:write32(aligned, bor(band(current, 0xFF000000), band(rshift(value, 8), 0x00FFFFFF)))
	else
		self.memory:write32(aligned, value)
	end
end

function CPU:writeWordRight(address, value)
	local shift = band(address, 3)
	local aligned = band(address, bnot(3))
	local current = self.memory:read32(aligned)
	if self.memory.busError then
		raiseBusError(self)
		return
	end
	if shift == 0 then
		self.memory:write32(aligned, value)
	elseif shift == 1 then
		self.memory:write32(aligned, bor(band(current, 0x000000FF), band(lshift(value, 8), 0xFFFFFF00)))
	elseif shift == 2 then
		self.memory:write32(aligned, bor(band(current, 0x0000FFFF), band(lshift(value, 16), 0xFFFF0000)))
	else
		self.memory:write32(aligned, bor(band(current, 0x00FFFFFF), band(lshift(value, 24), 0xFF000000)))
	end
end

-- functs that write rd (for load-delay hazard detection); add/sub are included though they abort on overflow (an abort clears pending state anyway).
local SPECIAL_WRITES_RD = {
	[0x00] = true, [0x02] = true, [0x03] = true, [0x04] = true, [0x06] = true, [0x07] = true,
	[0x09] = true, [0x10] = true, [0x12] = true, [0x20] = true, [0x21] = true, [0x22] = true,
	[0x23] = true, [0x24] = true, [0x25] = true, [0x26] = true, [0x27] = true, [0x2A] = true, [0x2B] = true,
}

function CPU:executeSpecial(instruction, pc)
	local reg = self.registers
	local rs = band(rshift(instruction, 21), 0x1F)
	local rt = band(rshift(instruction, 16), 0x1F)
	local rd = band(rshift(instruction, 11), 0x1F)
	local sa = band(rshift(instruction, 6), 0x1F)
	local funct = band(instruction, 0x3F)

	if funct == 0x00 then
		if rd ~= 0 then reg[rd + 1] = band(lshift(reg[rt + 1], sa), 0xFFFFFFFF) end
	elseif funct == 0x02 then
		if rd ~= 0 then reg[rd + 1] = band(rshift(reg[rt + 1], sa), 0xFFFFFFFF) end
	elseif funct == 0x03 then
		local value = reg[rt + 1]
		if band(value, 0x80000000) ~= 0 then
			if rd ~= 0 then reg[rd + 1] = band(arshift(value, sa), 0xFFFFFFFF) end
		else
			if rd ~= 0 then reg[rd + 1] = band(rshift(value, sa), 0xFFFFFFFF) end
		end
	elseif funct == 0x04 then
		local shift = band(reg[rs + 1], 0x1F)
		if rd ~= 0 then reg[rd + 1] = band(lshift(reg[rt + 1], shift), 0xFFFFFFFF) end
	elseif funct == 0x06 then
		local shift = band(reg[rs + 1], 0x1F)
		if rd ~= 0 then reg[rd + 1] = band(rshift(reg[rt + 1], shift), 0xFFFFFFFF) end
	elseif funct == 0x07 then
		local shift = band(reg[rs + 1], 0x1F)
		local value = reg[rt + 1]
		if band(value, 0x80000000) ~= 0 then
			if rd ~= 0 then reg[rd + 1] = band(arshift(value, shift), 0xFFFFFFFF) end
		else
			if rd ~= 0 then reg[rd + 1] = band(rshift(value, shift), 0xFFFFFFFF) end
		end
	elseif funct == 0x08 then
		-- unaligned jump target: adel, badvaddr = target, epc = target
		local jrTarget = reg[rs + 1]
		if band(jrTarget, 3) ~= 0 then
			self:raiseException(4, jrTarget, jrTarget)
		else
			return { target = jrTarget, delay = 1, sourcePc = pc }
		end
	elseif funct == 0x09 then
		-- jalr: the link is written to the rd field (not hardcoded $31)
		local jrTarget = reg[rs + 1]
		reg[rd + 1] = band(pc + 8, 0xFFFFFFFF)
		if band(jrTarget, 3) ~= 0 then
			self:raiseException(4, jrTarget, jrTarget)
		else
			return { target = jrTarget, delay = 1, sourcePc = pc }
		end
	elseif funct == 0x0C then
		self:raiseException(8, nil)
	elseif funct == 0x0D then
		self:raiseException(9, nil)
	elseif funct == 0x10 then
		self:stallMulDiv()
		if rd ~= 0 then reg[rd + 1] = self.hi end
	elseif funct == 0x11 then
		self:stallMulDiv()
		self.hi = reg[rs + 1]
	elseif funct == 0x12 then
		self:stallMulDiv()
		if rd ~= 0 then reg[rd + 1] = self.lo end
	elseif funct == 0x13 then
		self:stallMulDiv()
		self.lo = reg[rs + 1]
	elseif funct == 0x18 then
		-- signed mult: 32x32 -> 64-bit product.
		local aU = band(reg[rs + 1], 0xFFFFFFFF)
		local bU = band(reg[rt + 1], 0xFFFFFFFF)
		self:stallMulDiv()
		self.hi, self.lo = mult64(aU, bU)
		if reg[rs + 1] >= 0x80000000 then
			self.hi = band(self.hi - bU, 0xFFFFFFFF)
		end
		if reg[rt + 1] >= 0x80000000 then
			self.hi = band(self.hi - aU, 0xFFFFFFFF)
		end
		self:armMulDiv(multTicksSigned(signed(reg[rs + 1])))
	elseif funct == 0x19 then
		local aU = band(reg[rs + 1], 0xFFFFFFFF)
		local bU = band(reg[rt + 1], 0xFFFFFFFF)
		self:stallMulDiv()
		self.hi, self.lo = mult64(aU, bU)
		self:armMulDiv(multTicksUnsigned(reg[rs + 1]))
	elseif funct == 0x1A then
			local divisor = signed(reg[rt + 1])
			local dividend = signed(reg[rs + 1])
			self:stallMulDiv()
			if divisor == 0 then
				self.lo = (dividend >= 0) and 0xFFFFFFFF or 1
				self.hi = band(dividend, 0xFFFFFFFF)
			elseif reg[rs + 1] == 0x80000000 and divisor == -1 then
				self.lo = 0x80000000
				self.hi = 0
			else
				self.lo, self.hi = divModTrunc(dividend, divisor)
			end
			self:armMulDiv(35)
	elseif funct == 0x1B then
		local divisor = reg[rt + 1]
		local dividend = reg[rs + 1]
		self:stallMulDiv()
		if divisor == 0 then
			self.lo = 0xFFFFFFFF
			self.hi = band(dividend, 0xFFFFFFFF)
		else
			self.lo = band(math.floor(dividend / divisor), 0xFFFFFFFF)
			self.hi = band(dividend % divisor, 0xFFFFFFFF)
		end
		self:armMulDiv(35)
	elseif funct == 0x20 then
		local a = signed(reg[rs + 1])
		local b = signed(reg[rt + 1])
		local result = a + b
		if result < -0x80000000 or result > 0x7FFFFFFF then
			self:raiseException(12, nil)
		else
			if rd ~= 0 then reg[rd + 1] = band(result, 0xFFFFFFFF) end
		end
	elseif funct == 0x21 then
		if rd ~= 0 then reg[rd + 1] = band(reg[rs + 1] + reg[rt + 1], 0xFFFFFFFF) end
	elseif funct == 0x22 then
		local a = signed(reg[rs + 1])
		local b = signed(reg[rt + 1])
		local result = a - b
		if result < -0x80000000 or result > 0x7FFFFFFF then
			self:raiseException(12, nil)
		else
			if rd ~= 0 then reg[rd + 1] = band(result, 0xFFFFFFFF) end
		end
	elseif funct == 0x23 then
		if rd ~= 0 then reg[rd + 1] = band(reg[rs + 1] - reg[rt + 1], 0xFFFFFFFF) end
	elseif funct == 0x24 then
		if rd ~= 0 then reg[rd + 1] = band(reg[rs + 1], reg[rt + 1]) end
	elseif funct == 0x25 then
		if rd ~= 0 then reg[rd + 1] = bor(reg[rs + 1], reg[rt + 1]) end
	elseif funct == 0x26 then
		if rd ~= 0 then reg[rd + 1] = bxor(reg[rs + 1], reg[rt + 1]) end
	elseif funct == 0x27 then
		if rd ~= 0 then reg[rd + 1] = bnot(bor(reg[rs + 1], reg[rt + 1])) end
	elseif funct == 0x2A then
		if rd ~= 0 then reg[rd + 1] = signed(reg[rs + 1]) < signed(reg[rt + 1]) and 1 or 0 end
	elseif funct == 0x2B then
		if rd ~= 0 then reg[rd + 1] = reg[rs + 1] < reg[rt + 1] and 1 or 0 end
	else
		self:raiseException(10, nil)
	end
	if SPECIAL_WRITES_RD[funct] then
		return nil, rd
	end
	return nil, nil
end

function CPU:executeRegImm(instruction, pc)
	-- regimm: bit 0 selects bltz(0)/bgez(1); the link is written iff (rt & 0x1e) == 0x10 (bltzal/bgezal), even when not taken; other rt values are plain bltz/bgez.
	local reg = self.registers
	local rs = band(rshift(instruction, 21), 0x1F)
	local rt = band(rshift(instruction, 16), 0x1F)
	local immediate = band(instruction, 0xFFFF)
	local offset = Util.signExtend16(immediate) * 4
	local value = signed(reg[rs + 1])

	local bgez = band(rt, 1) == 1
	local condition = value < 0
	if bgez then condition = not condition end
	local wroteReg = nil
	if band(rt, 0x1E) == 0x10 then
		reg[32] = band(pc + 8, 0xFFFFFFFF)
		wroteReg = 31
	end
	if condition then
		return { target = band(pc + 4 + offset, 0xFFFFFFFF), delay = 1, sourcePc = pc }, wroteReg
	end
	self._delaySlotTarget = false
	return nil, wroteReg
end

function CPU:executeCop0(instruction)
	local rs = band(rshift(instruction, 21), 0x1F)
	local rt = band(rshift(instruction, 16), 0x1F)
	local rd = band(rshift(instruction, 11), 0x1F)
	local funct = band(instruction, 0x3F)

	-- user mode (kuc) without cu0: cpu, ce=0 (duckstation order: the gate is
	-- checked before any cop0 dispatch).
	if band(self.cop0.status, 0x2) ~= 0 and band(self.cop0.status, 0x10000000) == 0 then
		self:raiseException(11, nil, nil, 0)
		return nil
	end
	if rs == 0x00 then
		-- mfc0: 1-cycle load delay; unimplemented registers raise ri
		local value = self:getCop0(rd)
		if value == nil then
			self:raiseException(10, nil)
		else
			return self:requestLoad(rt, value)
		end
	elseif rs == 0x04 then
		-- mtc0
		if not self:setCop0(rd, self:getRegister(rt)) then
			self:raiseException(10, nil)
		end
	elseif rs == 0x10 and funct == 0x10 then
		local oldStatus = self.cop0.status
		-- rfe pops ie/ku stack levels into the low 4 mode bits.
		-- keep bits 4..5 unchanged; only replace bits 0..3 from prior 2..5.
		self.cop0.status = bor(band(oldStatus, bnot(0x0F)), band(rshift(oldStatus, 2), 0x0F))
		if self.traceInterruptGate then
			print(string.format(
				"[ps1-hle] rfe status old=%08X new=%08X iecOld=%d iecNew=%d pc=%08X",
				oldStatus or 0,
				self.cop0.status or 0,
				band(oldStatus or 0, 0x1),
				band(self.cop0.status or 0, 0x1),
				self.pc or 0
			))
		end
	elseif rs == 0x10 and (funct == 0x01 or funct == 0x02 or funct == 0x06 or funct == 0x08) then
		-- tlb opcodes: reserved instruction
		self:raiseException(10, nil)
	elseif rs == 0x02 or rs == 0x06 then
		-- cfc0 / ctc0: no-op (duckstation common-op default)
	elseif rs == 0x10 then
		-- other cop0 commands (incl. 0x18): no-op (duckstation error_log)
	else
		-- any other cop0 rs: no-op, not ri -- ps1-tests prove duckstation's "else -> ri" is wrong for the ps1.
	end
	return nil
end

-- gte runs in the background with per-op latency: output reads (mfc2/cfc2/swc2) stall behind the in-flight op, input writes never do.
-- completion = pending + ticks + 1 (duckstation addgteticks).
function CPU:gteStallForOp(instruction)
	local mem = self.memory
	local stall = self.gteBusyUntil - mem.cycleCount
	if stall > 0 then
		mem:advanceCycles(stall)
	end
	self.gteBusyUntil = mem.cycleCount + self.gte:opTicks(instruction) + 1
end

function CPU:gteStallForRead()
	local mem = self.memory
	local stall = self.gteBusyUntil - mem.cycleCount
	if stall > 0 then
		mem:advanceCycles(stall)
	end
end

function CPU:stallMulDiv()
	local mem = self.memory
	local stall = self.mulDivBusyUntil - mem.cycleCount
	if stall > 0 then
		mem:advanceCycles(stall)
	end
end

function CPU:armMulDiv(ticks)
	self.mulDivBusyUntil = self.memory.cycleCount + ticks
end

function CPU:executeCop2(instruction)
	local rs    = band(rshift(instruction, 21), 0x1F)
	local rt    = band(rshift(instruction, 16), 0x1F)
	local rd    = band(rshift(instruction, 11), 0x1F)
	-- every cop2 instruction requires sr.ce2 (bit 30): cpu, ce=2
	if band(self.cop0.status, 0x40000000) == 0 then
		self:raiseException(11, nil, nil, 2)
		return nil
	end
	if band(instruction, 0x02000000) ~= 0 then
		self:gteStallForOp(instruction)
		self.gte:execute(instruction)
	elseif rs == 0x00 then
		-- mfc2 / cfc2: 1-cycle load delay; stalls behind an in-flight gte op
		self:gteStallForRead()
		return self:requestLoad(rt, self.gte:readData(rd))
	elseif rs == 0x02 then
		self:gteStallForRead()
		return self:requestLoad(rt, self.gte:readCtrl(rd))
	elseif rs == 0x04 then
		self.gte:writeData(rd, self:getRegister(rt))
	elseif rs == 0x06 then
		self.gte:writeCtrl(rd, self:getRegister(rt))
	else
		-- unknown cop2 common-op rs: reserved instruction (duckstation)
		self:raiseException(10, nil)
	end
	return nil
end

function CPU:executeInstruction(instruction, pc)
	local reg = self.registers
	local opcode = band(rshift(instruction, 26), 0x3F)
	local rs = band(rshift(instruction, 21), 0x1F)
	local rt = band(rshift(instruction, 16), 0x1F)
	local immediate = band(instruction, 0xFFFF)
	-- sign-extend 16-bit immediate inline (was util.signextend16: a function
	-- call on every instruction; only i-type opcodes below actually use it)
	local signedImmediate = immediate >= 0x8000 and immediate - 0x10000 or immediate
	local newBranch = nil
	local newLoad = nil
	local wroteReg = nil

	if opcode == 0x00 then
		newBranch, wroteReg = self:executeSpecial(instruction, pc)
	elseif opcode == 0x01 then
		newBranch, wroteReg = self:executeRegImm(instruction, pc)
	elseif opcode == 0x02 then
		newBranch = {
			target = bor(band(pc + 4, 0xF0000000), lshift(band(instruction, 0x03FFFFFF), 2)),
			delay = 1,
			sourcePc = pc,
		}
	elseif opcode == 0x03 then
		reg[32] = band(pc + 8, 0xFFFFFFFF)
		wroteReg = 31
		newBranch = {
			target = bor(band(pc + 4, 0xF0000000), lshift(band(instruction, 0x03FFFFFF), 2)),
			delay = 1,
			sourcePc = pc,
		}
	elseif opcode == 0x04 then
		if reg[rs + 1] == reg[rt + 1] then
			newBranch = {
				target = band(pc + 4 + (signedImmediate * 4), 0xFFFFFFFF),
				delay = 1,
				sourcePc = pc,
			}
		else
			self._delaySlotTarget = false
		end
	elseif opcode == 0x05 then
		if reg[rs + 1] ~= reg[rt + 1] then
			newBranch = {
				target = band(pc + 4 + (signedImmediate * 4), 0xFFFFFFFF),
				delay = 1,
				sourcePc = pc,
			}
		else
			self._delaySlotTarget = false
		end
	elseif opcode == 0x06 then
		if signed(reg[rs + 1]) <= 0 then
			newBranch = {
				target = band(pc + 4 + (signedImmediate * 4), 0xFFFFFFFF),
				delay = 1,
				sourcePc = pc,
			}
		else
			self._delaySlotTarget = false
		end
	elseif opcode == 0x07 then
		if signed(reg[rs + 1]) > 0 then
			newBranch = {
				target = band(pc + 4 + (signedImmediate * 4), 0xFFFFFFFF),
				delay = 1,
				sourcePc = pc,
			}
		else
			self._delaySlotTarget = false
		end
	elseif opcode == 0x08 then
		local a = signed(reg[rs + 1])
		local b = signedImmediate
		local result = a + b
		if result < -0x80000000 or result > 0x7FFFFFFF then
			self:raiseException(12, nil)
		else
			if rt ~= 0 then reg[rt + 1] = band(result, 0xFFFFFFFF) end
			wroteReg = rt
		end
	elseif opcode == 0x09 then
		if rt ~= 0 then reg[rt + 1] = band(reg[rs + 1] + signedImmediate, 0xFFFFFFFF) end
		wroteReg = rt
	elseif opcode == 0x0A then
		if rt ~= 0 then reg[rt + 1] = signed(reg[rs + 1]) < signedImmediate and 1 or 0 end
		wroteReg = rt
	elseif opcode == 0x0B then
		if rt ~= 0 then reg[rt + 1] = reg[rs + 1] < band(immediate, 0xFFFF) and 1 or 0 end
		wroteReg = rt
	elseif opcode == 0x0C then
		if rt ~= 0 then reg[rt + 1] = band(reg[rs + 1], band(immediate, 0xFFFF)) end
		wroteReg = rt
	elseif opcode == 0x0D then
		if rt ~= 0 then reg[rt + 1] = bor(reg[rs + 1], band(immediate, 0xFFFF)) end
		wroteReg = rt
	elseif opcode == 0x0E then
		if rt ~= 0 then reg[rt + 1] = bxor(reg[rs + 1], band(immediate, 0xFFFF)) end
		wroteReg = rt
	elseif opcode == 0x0F then
		if rt ~= 0 then reg[rt + 1] = band(lshift(immediate, 16), 0xFFFFFFFF) end
		wroteReg = rt
	elseif opcode == 0x10 then
		newLoad = self:executeCop0(instruction)
	elseif opcode == 0x11 or opcode == 0x13 then
		-- cop1/cop3: absent fpu raises cpu (ce=1/3) when its cu bit is clear, even in kernel mode; no-op with the bit set.
		if opcode == 0x11 and band(self.cop0.status, 0x20000000) == 0 then
			self:raiseException(11, nil, nil, 1)
		elseif opcode == 0x13 and band(self.cop0.status, 0x80000000) == 0 then
			self:raiseException(11, nil, nil, 3)
		end
	elseif opcode == 0x12 then
		newLoad = self:executeCop2(instruction)
	elseif opcode == 0x20 then
		local loaded = self:loadByte(reg[rs + 1] + signedImmediate, false)
		newLoad = self:requestLoad(rt, loaded)
	elseif opcode == 0x21 then
		local loaded = self:loadHalf(reg[rs + 1] + signedImmediate, false)
		newLoad = self:requestLoad(rt, loaded)
	elseif opcode == 0x22 then
		local address = reg[rs + 1] + signedImmediate
		local current = reg[rt + 1]
		newLoad = self:requestLoad(rt, self:readWordLeft(address, current))
	elseif opcode == 0x23 then
		local loaded = self:loadWord(reg[rs + 1] + signedImmediate)
		newLoad = self:requestLoad(rt, loaded)
	elseif opcode == 0x24 then
		local loaded = self:loadByte(reg[rs + 1] + signedImmediate, true)
		newLoad = self:requestLoad(rt, loaded)
	elseif opcode == 0x25 then
		local loaded = self:loadHalf(reg[rs + 1] + signedImmediate, true)
		newLoad = self:requestLoad(rt, loaded)
	elseif opcode == 0x26 then
		local address = reg[rs + 1] + signedImmediate
		local current = reg[rt + 1]
		newLoad = self:requestLoad(rt, self:readWordRight(address, current))
	elseif opcode == 0x30 or opcode == 0x31 or opcode == 0x33 then
		-- lwc0/1/3: cu gate runs before the memory access (absent coprocessors raise cpu with ce = their number); otherwise read and discard.
		if band(self.cop0.status, opcode == 0x30 and 0x10000000 or (opcode == 0x31 and 0x20000000 or 0x80000000)) == 0 then
			self:raiseException(11, nil, nil, opcode == 0x30 and 0 or (opcode == 0x31 and 1 or 3))
		else
			local address = reg[rs + 1] + signedImmediate
			self:loadWord(address)
		end
	elseif opcode == 0x32 then
		-- lwc2: ce2 gate before the memory access (duckstation order)
		local address = reg[rs + 1] + signedImmediate
		if band(self.cop0.status, 0x40000000) == 0 then
			self:raiseException(11, nil, nil, 2)
		else
			self.gte:writeData(rt, self:loadWord(address))
		end
	elseif opcode == 0x34 or opcode == 0x35 or opcode == 0x36 or opcode == 0x37 then
		-- ldc0-3: reserved/invalid
		self:raiseException(10, nil)
	elseif opcode == 0x38 or opcode == 0x39 or opcode == 0x3B then
		-- swc0/1/3: the cu gate runs before the memory write (see lwc0/1/3);
		-- otherwise perform the memory write with value 0.
		if band(self.cop0.status, opcode == 0x38 and 0x10000000 or (opcode == 0x39 and 0x20000000 or 0x80000000)) == 0 then
			self:raiseException(11, nil, nil, opcode == 0x38 and 0 or (opcode == 0x39 and 1 or 3))
		else
			local address = reg[rs + 1] + signedImmediate
			self:storeWord(address, 0)
		end
	elseif opcode == 0x3A then
		-- swc2: ce2 gate before the memory access (duckstation order); the store
		-- reads gte state, so it stalls behind an in-flight gte op (tf_gte_stall)
		local address = reg[rs + 1] + signedImmediate
		if band(self.cop0.status, 0x40000000) == 0 then
			self:raiseException(11, nil, nil, 2)
		else
			self:gteStallForRead()
			self:storeWord(address, self.gte:readData(rt))
		end
	elseif opcode == 0x3C or opcode == 0x3D or opcode == 0x3E or opcode == 0x3F then
		-- sdc0-3: reserved/invalid
		self:raiseException(10, nil)
	elseif opcode == 0x28 then
		self:storeByte(reg[rs + 1] + signedImmediate, reg[rt + 1])
	elseif opcode == 0x29 then
		self:storeHalf(reg[rs + 1] + signedImmediate, reg[rt + 1])
	elseif opcode == 0x2A then
		self:writeWordLeft(reg[rs + 1] + signedImmediate, reg[rt + 1])
	elseif opcode == 0x2B then
		self:storeWord(reg[rs + 1] + signedImmediate, reg[rt + 1])
	elseif opcode == 0x2E then
		self:writeWordRight(reg[rs + 1] + signedImmediate, reg[rt + 1])
	else
		print(string.format("[ps1-hle] RI opcode=%02X instruction=%08X pc=%08X",
			bit32.rshift(instruction, 26), instruction or 0, pc or 0))
		dumpRamWritesAround(self, pc)
		self:raiseException(10, nil)
	end

	self._delaySlotWroteReg = wroteReg
	return newBranch, newLoad
end

function CPU:step()
	-- run a cached block when there is no pending delay-slot state and runtime
	-- does not need to inspect this pc first.
	if self.useBlocks then
		if self.halted then
			return false
		end
		if self.pendingBranch or self.pendingLoad then
			return self:stepBaseline()
		end
		local pc = band(self.pc, 0xFFFFFFFF)
		if isSpecialPc(pc) then
			return self:stepBaseline()
		end
		local blk = self._blocks[pc]
		if blk then
			-- validate against the page-version stamps (o(1)); a ram write to
			-- the block's page since it was decoded forces a re-decode.
			local ver = self._pageVer
			if blk.v1 == (ver[blk.p1] or 0) and (not blk.p2 or blk.v2 == (ver[blk.p2] or 0)) then
				return runBlock(self, blk)
			end
			self._blocks[pc] = nil
		end
		blk = self:_buildBlock(pc)
		self._blocks[pc] = blk
		self:_registerBlock(pc, blk)
		return runBlock(self, blk)
	end
	return self:stepBaseline()
end

-- exception paths use this small copy of memory:advancecycles. the regular
-- instruction loop keeps the same work inline to avoid a call per instruction.
local function inlineAdvance(mem, cyc)
	mem.cycleCount += cyc
	mem.flux += cyc
	if mem.flux >= mem._periphBatch then
		local batch = mem.flux
		mem.flux = 0
		mem.spu:step(batch)
		mem.gpu:step(batch)
		mem.cdrom:step(batch)
		mem.timers:advance(batch)
	end
	local dma = mem.dma
	if dma.haltTicksRemaining > 0 then
		dma:consumeHaltTicks(cyc)
	elseif dma.resumePending and not dma.inTickCharge then
		dma:resumeHalted()
	end
	if mem.busError then mem.busError = false end
end

function CPU:stepBaseline()
	if self.halted then
		return false
	end

	local currentPc = band(self.pc, 0xFFFFFFFF)

	-- capture the delay-slot branch state before the interrupt check (the interrupt path runs before pendingbranch clears, so it must happen here); merged into _delayslottarget (nil/false/target).
	if self.pendingBranch ~= nil then
		local pb = self.pendingBranch
		self._delaySlotTarget = pb.delay == 1 and pb.target or nil
	elseif self._delaySlotTarget ~= nil and self._delaySlotTarget ~= false then
		self._delaySlotTarget = nil
	end

	-- check pending interrupts before executing the instruction.
	do
		local cop0 = self.cop0
		local pending = band(self.memory.iStat, self.memory.iMask)
		-- keep the interrupt-pending bits in cause in step with i_stat/i_mask.
		if pending ~= 0 then
			local newCause = bor(band(cop0.cause, 0xFFFF00FF), 0x00000400)
			if newCause ~= cop0.cause then
				cop0.cause = newCause
			end
			local status = cop0.status
			if band(status, 1) ~= 0 and band(status, 0x00000400) ~= 0 then
					-- a pending cop2 gte command still executes while the interrupt is serviced (duckstation dispatchinterrupt).
					local nextIns = self.memory:read32(currentPc)
					if band(nextIns, 0xFC000000) == 0x48000000 and band(nextIns, 0x02000000) ~= 0 then
						self.gte:execute(nextIns)
					end
					self:raiseException(0, nil)
					-- interrupt taken: the current instruction is skipped (only a pending cop2 op runs); finish the step like the exception-vector early return.
					self.inDelaySlot = false
					self.registers[1] = 0
					inlineAdvance(self.memory, self.cyclesPerInstruction or 1)
					self.instructionCount = (self.instructionCount or 0) + 1
					if self._diffHook then
						self._diffHook(self, currentPc)
					end
					return true
				end
		elseif band(cop0.cause, 0x0000FF00) ~= 0 then
			-- pending cleared: drop the ip bits (bit10 and any mtc0-written
			-- bits 8-9) so cause matches what checkinterrupts always produced.
			cop0.cause = band(cop0.cause, 0xFFFF00FF)
		end
	end

	local mem = self.memory
	-- most instructions come from ram. keep that fetch cheap, but use the bus
	-- reader for bios, i/o, and unmapped addresses.
	local instruction
	local region = band(currentPc, 0xE0000000)
	if region == 0x80000000 or region == 0xA0000000 then
		local physical = band(currentPc, 0x1FFFFFFF)
		if physical < mem.ramMappedEnd then
			physical = band(physical, mem.ramMask)
		end
		if physical < 0x00200000 then
			instruction = mem.ram32[physical // 4 + 1]
		else
			instruction = mem:read32(currentPc)
		end
	else
		instruction = mem:read32(currentPc)
	end
	-- instruction-fetch bus errors (ibe) are not modeled; clear the latch so
	-- a fetch from an unmapped pc cannot corrupt the next data access.
	mem.busError = false
	if instruction == 0xEEEEEE11 and mem and mem.dumpRecentRamWrites then
		print(string.format("[ps1-hle] suspicious instruction stream pc=%08X phys=%08X", currentPc, mem:physicalAddress(currentPc)))
		dumpRamWritesAround(self, currentPc)
	end
	self.nextPc = band(currentPc + 4, 0xFFFFFFFF)

	local oldBranch = self.pendingBranch
	local oldLoad = self.pendingLoad
	self.pendingBranch = nil
	self.pendingLoad = nil
	-- consume the not-taken-branch marker: the instruction after a not-taken branch is still a delay slot (bd flag on exceptions there).  only the marker clears here; a taken target must survive mid-execute.
	local notTakenDelay = self._delaySlotTarget == false
	if notTakenDelay then self._delaySlotTarget = nil end
	self.inDelaySlot = (oldBranch ~= nil and oldBranch.delay == 1) or notTakenDelay
	self._delaySlotWroteReg = nil

	local newBranch, newLoad = self:executeInstruction(instruction, currentPc)

	if currentPc ~= self.pc and (
		self.pc == 0x80000080
		or self.pc == 0x80000000
		or self.pc == 0xBFC00180
		or self.pc == 0xBFC00100
	) then
		self.pendingBranch = nil
		self.pendingLoad = nil
		inlineAdvance(self.memory, self.cyclesPerInstruction or 1)
		self.inDelaySlot = false
		self.registers[1] = 0
		self.instructionCount = (self.instructionCount or 0) + 1
		if self._diffHook then
			self._diffHook(self, currentPc)
		end
		return true
	end

	if oldBranch or oldLoad then
		self:commitPendingState(oldBranch, oldLoad)
	end

	if newBranch then
		self.pendingBranch = newBranch
	end
	if newLoad then
		self.pendingLoad = newLoad
	end

	self.pc = self.nextPc
	self.inDelaySlot = false
	-- advance devices for an exception or interrupt step.
	local mem2 = self.memory
	local cyc = self.cyclesPerInstruction or 1
	mem2.cycleCount += cyc
	-- flux batch: only 4 subsystem steps when batch fires
	mem2.flux += cyc
	if mem2.flux >= mem2._periphBatch then
		local batch = mem2.flux
		mem2.flux = 0
		mem2.spu:step(batch)
		mem2.gpu:step(batch)
		mem2.cdrom:step(batch)
		mem2.timers:advance(batch)
	end
	-- dma halt (only when active)
	local dma2 = mem2.dma
	if dma2.haltTicksRemaining > 0 then
		dma2:consumeHaltTicks(cyc)
	end
	if dma2.resumePending and not dma2.inTickCharge then
		dma2:resumeHalted()
	end
	mem2.busError = false
	self.registers[1] = 0
	self.instructionCount = (self.instructionCount or 0) + 1
	if self._diffHook then
		self._diffHook(self, currentPc)
	end
	return true
end

function CPU:runInstructionBudget(count)
	for _ = 1, count do
		if not self:step() then
			break
		end
	end
end

-- block-cache helpers

function CPU:_isSpecialPc(pc)
	return isSpecialPc(band(pc, 0xFFFFFFFF))
end

-- build a decoded block at `pc`: straight-line instructions until a control transfer (incl. its delay slot); stops before special pcs and caps length.
function CPU:_buildBlock(pc)
	-- decoded instructions live in four parallel arrays (op/a/b/c): four array reads beat a tuple dereference in the hot loop.
	local ops = table.create(64)
	local as = table.create(64)
	local bs = table.create(64)
	local cs = table.create(64)
	local n = 0
	local cur = pc
	local maxLen = 64
	while n < maxLen do
		if isSpecialPc(band(cur, 0xFFFFFFFF)) then
			break
		end
		local word = self.memory:read32(cur)
		local d = decodeWord(word, cur)
		n += 1
		ops[n], as[n], bs[n], cs[n] = d[1], d[2], d[3], d[4]
		local op = d[1]
		cur += 4
		if op == OP_JR or op == OP_JALR or (op >= OP_BEQ and op <= OP_JAL) then
			-- control transfer: include the delay slot, then end the block (syscall/break/ri abort at runtime via the pc-change check).
			if n < maxLen and not isSpecialPc(band(cur, 0xFFFFFFFF)) then
				local slotWord = self.memory:read32(cur)
				local sd = decodeWord(slotWord, cur)
				n += 1
				ops[n], as[n], bs[n], cs[n] = sd[1], sd[2], sd[3], sd[4]
			end
			break
		end
	end
	return { startPc = pc, n = n, ops = ops, as = as, bs = bs, cs = cs }
end

-- stamp the versions of the pages a block spans (at most two); a block is valid only while every stamped version still matches.
function CPU:_registerBlock(pc, blk)
	local physStart = self.memory:physicalAddress(pc)
	local physEnd = physStart + blk.n * 4 - 1
	local page = physStart // 0x10000
	local lastPage = physEnd // 0x10000
	local ver = self._pageVer
	blk.p1 = page
	blk.v1 = ver[page] or 0
	self._hotPages[page] = true
	if lastPage ~= page then
		blk.p2 = lastPage
		blk.v2 = ver[lastPage] or 0
		self._hotPages[lastPage] = true
	else
		blk.p2 = nil
		blk.v2 = nil
	end
end

-- o(1) write-side invalidation: only pages holding cached blocks get a version bump; a block re-decodes when its stamped versions no longer match.
function CPU:onRamWrite(physical)
	local page = (physical % 0x100000000) // 0x10000
	if self._hotPages[page] then
		self._pageVer[page] = (self._pageVer[page] or 0) + 1
	end
end

-- drop every cached block (checkpoint restore, reset, code region rewrites).
function CPU:invalidateAllBlocks()
	self._blocks = {}
	self._pageVer = {}
	self._hotPages = {}
end

function CPU:dumpState()
	local registers = table.create(32, 0)
	for index = 0, 31 do
		registers[index + 1] = self:getRegister(index)
	end

	return {
		pc = self.pc,
		nextPc = self.nextPc,
		registers = registers,
		cop0 = {
			status = self.cop0.status,
			cause = self.cop0.cause,
			epc = self.cop0.epc,
			badvaddr = self.cop0.badvaddr,
			prid = self.cop0.prid,
		},
		hi = self.hi,
		lo = self.lo,
	}
end

return CPU