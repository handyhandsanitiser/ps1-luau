-- cpu model used by the differential checks; it follows the same step order as the emulator so a
-- mismatch points at an instruction boundary.  the cases worth keeping visible: div/divu by zero,
-- jalr linking to the rd field, regimm decodes by rt bit 0, unaligned branch/jump -> adel,
-- the 1-cycle load delay on mfc0/mfc2/cfc2, the ce2 gate on cop2, ri on unimplemented cop0
-- registers, sr/cause write masks (sr 0xf27fff3f, cause bits 8-9), every branch marking a delay
-- slot, and the load-delay hazard (a delay-slot write to the load's register wins).
-- interface: cpuref.new(), then ref:step(instruction, memory, pendingirq).
local CPURef = {}
CPURef.__index = CPURef

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift
local arshift = bit32.arshift

local SR_WRITE_MASK = 0xF27FFF3F
local CAUSE_WRITE_MASK = 0x00000300
local DCIC_WRITE_MASK = 0xFF80F03F
local SR_BEV = 0x00400000
local SR_ISC = 0x00010000
local SR_CE2 = 0x40000000
local SR_CU0 = 0x10000000
local SR_CU1 = 0x20000000
local SR_CU3 = 0x80000000

local function s32(v) v = band(v, 0xFFFFFFFF); if v >= 0x80000000 then return v - 0x100000000 end return v end

-- exact unsigned 32x32 -> hi32, lo32
local function mult64(a, b)
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

function CPURef.new()
	local self = setmetatable({}, CPURef)
	self.registers = table.create(32, 0)
	self.hi = 0
	self.lo = 0
	self.cop0 = {
		status = SR_BEV, cause = 0, epc = 0, badvaddr = 0, prid = 0x00000002,
		bpc = 0, bpcm = 0, bda = 0, bdam = 0, dcic = 0, tar = 0,
	}
	self.pc = 0xBFC00000
	self.pendingBranch = nil
	self.pendingLoad = nil
	self.inDelaySlot = false
	self.halted = false
	self._notTakenDelaySlot = false
	-- bookkeeping for exact load-delay write detection
	self._delaySlotWroteReg = nil -- 0-based reg the delay-slot instruction wrote
	return self
end

local function getReg(self, i)
	if i == 0 then return 0 end
	return self.registers[i + 1] or 0
end
local function setReg(self, i, v)
	if i ~= 0 then self.registers[i + 1] = band(v, 0xFFFFFFFF) end
end

-- exception handling

local EXCODE = { AdEL = 4, AdES = 5, Syscall = 8, BP = 9, RI = 10, CpU = 11, Ov = 12, INT = 0 }

function CPURef:raiseException(code, badAddress, epcOverride, ce)
	-- exception write mask 0xf000007c: only excode (2-6), ce (28-29), bd (31), bt (30); everything else (incl. ip bits) is preserved.
	local cause = band(self.cop0.cause, bnot(0xF000007C))
	local exceptionCode = lshift(band(code, 0x1F), 2)
	local pc = self.pc
	local inBranchDelay = self.inDelaySlot == true
		or (self.pendingBranch ~= nil and self.pendingBranch.delay == 1)
		or self._notTakenDelaySlot == true
	local inLoadDelay = self.pendingLoad ~= nil and self.pendingLoad.delay == 1
	if inBranchDelay then
		cause = bor(cause, 0x80000000)
		-- bt (bit 30): branch was taken (captured at step top; nil during execute-time exceptions in the delay slot).  tar is only updated for a taken branch (psx-spx cop0r6).
		if self._stepBranchTaken == true then
			cause = bor(cause, 0x40000000)
			self.cop0.tar = self._stepBranchTarget or 0
		end
		self.cop0.epc = band(pc - 4, 0xFFFFFFFF)
	elseif inLoadDelay then
		self.cop0.epc = band(pc - 4, 0xFFFFFFFF)
	elseif epcOverride ~= nil then
		self.cop0.epc = band(epcOverride, 0xFFFFFFFF)
	else
		self.cop0.epc = band(pc, 0xFFFFFFFF)
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
	self._notTakenDelaySlot = false
	local vector = 0x80000080
	if band(self.cop0.status, SR_BEV) ~= 0 then
		vector = 0xBFC00180
	end
	self.pc = vector
	self.nextPc = band(vector + 4, 0xFFFFFFFF)
	self.inDelaySlot = false
end

-- instruction execution

-- returns newbranch {target, delay=1} | nil, newload {register, value, delay=1} | nil
function CPURef:execute(ins, mem)
	local reg = self.registers
	local opcode = band(rshift(ins, 26), 0x3F)
	local rs = band(rshift(ins, 21), 0x1F)
	local rt = band(rshift(ins, 16), 0x1F)
	local rd = band(rshift(ins, 11), 0x1F)
	local sa = band(rshift(ins, 6), 0x1F)
	local funct = band(ins, 0x3F)
	local imm = band(ins, 0xFFFF)
	local simm = imm >= 0x8000 and imm - 0x10000 or imm
	local newBranch = nil
	local newLoad = nil
	local wroteReg = nil -- 0-based register written directly by this instruction

	local function branch(target)
		target = band(target, 0xFFFFFFFF)
		if band(target, 3) ~= 0 then
			-- unaligned branch/jump target: adel with badvaddr = target (psx-spx: raised on the next fetch; duckstation: raiseexception(adel, target)).
			self:raiseException(EXCODE.AdEL, target, target)
			return
		end
		newBranch = { target = target, delay = 1 }
	end
	if opcode == 0x00 then
		-- special
		if funct == 0x00 then if rd ~= 0 then setReg(self, rd, band(lshift(getReg(self, rt), sa), 0xFFFFFFFF)) end wroteReg = rd
		elseif funct == 0x02 then if rd ~= 0 then setReg(self, rd, band(rshift(getReg(self, rt), sa), 0xFFFFFFFF)) end wroteReg = rd
		elseif funct == 0x03 then if rd ~= 0 then setReg(self, rd, band(arshift(getReg(self, rt), sa), 0xFFFFFFFF)) end wroteReg = rd
		elseif funct == 0x04 then if rd ~= 0 then setReg(self, rd, band(lshift(getReg(self, rt), band(getReg(self, rs), 0x1F)), 0xFFFFFFFF)) end wroteReg = rd
		elseif funct == 0x06 then if rd ~= 0 then setReg(self, rd, band(rshift(getReg(self, rt), band(getReg(self, rs), 0x1F)), 0xFFFFFFFF)) end wroteReg = rd
		elseif funct == 0x07 then if rd ~= 0 then setReg(self, rd, band(arshift(getReg(self, rt), band(getReg(self, rs), 0x1F)), 0xFFFFFFFF)) end wroteReg = rd
		elseif funct == 0x08 then
			branch(getReg(self, rs))
		elseif funct == 0x09 then
			-- jalr: link to rd (not hardcoded $31)
			local target = getReg(self, rs)
			setReg(self, rd, band(self.pc + 8, 0xFFFFFFFF))
			wroteReg = rd
			branch(target)
		elseif funct == 0x0C then self:raiseException(EXCODE.Syscall)
		elseif funct == 0x0D then self:raiseException(EXCODE.BP)
		elseif funct == 0x10 then if rd ~= 0 then setReg(self, rd, self.hi) end wroteReg = rd
		elseif funct == 0x11 then self.hi = getReg(self, rs)
		elseif funct == 0x12 then if rd ~= 0 then setReg(self, rd, self.lo) end wroteReg = rd
		elseif funct == 0x13 then self.lo = getReg(self, rs)
		elseif funct == 0x18 then
			local aU = band(getReg(self, rs), 0xFFFFFFFF)
			local bU = band(getReg(self, rt), 0xFFFFFFFF)
			self.hi, self.lo = mult64(aU, bU)
			if aU >= 0x80000000 then self.hi = band(self.hi - bU, 0xFFFFFFFF) end
			if bU >= 0x80000000 then self.hi = band(self.hi - aU, 0xFFFFFFFF) end
		elseif funct == 0x19 then
			self.hi, self.lo = mult64(getReg(self, rs), getReg(self, rt))
		elseif funct == 0x1A then
			-- div
			local num = s32(getReg(self, rs))
			local denom = s32(getReg(self, rt))
			if denom == 0 then
				self.lo = (num >= 0) and 0xFFFFFFFF or 1
				self.hi = band(num, 0xFFFFFFFF)
			elseif band(num, 0xFFFFFFFF) == 0x80000000 and denom == -1 then
				self.lo = 0x80000000
				self.hi = 0
			else
				-- truncation toward zero (c++ semantics), not lua floor division
				local q = num / denom
				local lo
				if q >= 0 then lo = math.floor(q) else lo = math.ceil(q) end
				self.lo = band(lo, 0xFFFFFFFF)
				self.hi = band(num - lo * denom, 0xFFFFFFFF)
			end
		elseif funct == 0x1B then
			-- divu
			local num = getReg(self, rs)
			local denom = getReg(self, rt)
			if denom == 0 then
				self.lo = 0xFFFFFFFF
				self.hi = band(num, 0xFFFFFFFF)
			else
				self.lo = band(math.floor(num / denom), 0xFFFFFFFF)
				self.hi = band(num % denom, 0xFFFFFFFF)
			end
		elseif funct == 0x20 then
			local result = s32(getReg(self, rs)) + s32(getReg(self, rt))
			if result < -0x80000000 or result > 0x7FFFFFFF then
				self:raiseException(EXCODE.Ov)
			else
				if rd ~= 0 then setReg(self, rd, result) end
				wroteReg = rd
			end
		elseif funct == 0x21 then if rd ~= 0 then setReg(self, rd, band(getReg(self, rs) + getReg(self, rt), 0xFFFFFFFF)) end wroteReg = rd
		elseif funct == 0x22 then
			local result = s32(getReg(self, rs)) - s32(getReg(self, rt))
			if result < -0x80000000 or result > 0x7FFFFFFF then
				self:raiseException(EXCODE.Ov)
			else
				if rd ~= 0 then setReg(self, rd, result) end
				wroteReg = rd
			end
		elseif funct == 0x23 then if rd ~= 0 then setReg(self, rd, band(getReg(self, rs) - getReg(self, rt), 0xFFFFFFFF)) end wroteReg = rd
		elseif funct == 0x24 then if rd ~= 0 then setReg(self, rd, band(getReg(self, rs), getReg(self, rt))) end wroteReg = rd
		elseif funct == 0x25 then if rd ~= 0 then setReg(self, rd, bor(getReg(self, rs), getReg(self, rt))) end wroteReg = rd
		elseif funct == 0x26 then if rd ~= 0 then setReg(self, rd, bxor(getReg(self, rs), getReg(self, rt))) end wroteReg = rd
		elseif funct == 0x27 then if rd ~= 0 then setReg(self, rd, bnot(bor(getReg(self, rs), getReg(self, rt)))) end wroteReg = rd
		elseif funct == 0x2A then if rd ~= 0 then setReg(self, rd, s32(getReg(self, rs)) < s32(getReg(self, rt)) and 1 or 0) end wroteReg = rd
		elseif funct == 0x2B then if rd ~= 0 then setReg(self, rd, getReg(self, rs) < getReg(self, rt) and 1 or 0) end wroteReg = rd
		else
			self:raiseException(EXCODE.RI)
		end
	elseif opcode == 0x01 then
		-- regimm: bit 0 selects bgez(1)/bltz(0); link iff (rt & 0x1e) == 0x10 (rt 0x10/0x11)
		local bgez = band(rt, 1) == 1
		local link = band(rt, 0x1E) == 0x10
		local condition = s32(getReg(self, rs)) < 0
		if bgez then condition = not condition end
		if link then setReg(self, 31, band(self.pc + 8, 0xFFFFFFFF)) wroteReg = 31 end
		if condition then
			branch(self.pc + 4 + simm * 4)
		else
			self._notTakenDelaySlot = true
		end
	elseif opcode == 0x02 then
		branch(bor(band(self.pc + 4, 0xF0000000), lshift(band(ins, 0x03FFFFFF), 2)))
	elseif opcode == 0x03 then
		setReg(self, 31, band(self.pc + 8, 0xFFFFFFFF)) wroteReg = 31
		branch(bor(band(self.pc + 4, 0xF0000000), lshift(band(ins, 0x03FFFFFF), 2)))
	elseif opcode == 0x04 then
		if getReg(self, rs) == getReg(self, rt) then branch(self.pc + 4 + simm * 4) else self._notTakenDelaySlot = true end
	elseif opcode == 0x05 then
		if getReg(self, rs) ~= getReg(self, rt) then branch(self.pc + 4 + simm * 4) else self._notTakenDelaySlot = true end
	elseif opcode == 0x06 then
		if s32(getReg(self, rs)) <= 0 then branch(self.pc + 4 + simm * 4) else self._notTakenDelaySlot = true end
	elseif opcode == 0x07 then
		if s32(getReg(self, rs)) > 0 then branch(self.pc + 4 + simm * 4) else self._notTakenDelaySlot = true end
	elseif opcode == 0x08 then
		local result = s32(getReg(self, rs)) + simm
		if result < -0x80000000 or result > 0x7FFFFFFF then
			self:raiseException(EXCODE.Ov)
		else
			if rt ~= 0 then setReg(self, rt, result) end
			wroteReg = rt
		end
	elseif opcode == 0x09 then if rt ~= 0 then setReg(self, rt, band(getReg(self, rs) + simm, 0xFFFFFFFF)) end wroteReg = rt
	elseif opcode == 0x0A then if rt ~= 0 then setReg(self, rt, s32(getReg(self, rs)) < simm and 1 or 0) end wroteReg = rt
	elseif opcode == 0x0B then if rt ~= 0 then setReg(self, rt, getReg(self, rs) < imm and 1 or 0) end wroteReg = rt
	elseif opcode == 0x0C then if rt ~= 0 then setReg(self, rt, band(getReg(self, rs), imm)) end wroteReg = rt
	elseif opcode == 0x0D then if rt ~= 0 then setReg(self, rt, bor(getReg(self, rs), imm)) end wroteReg = rt
	elseif opcode == 0x0E then if rt ~= 0 then setReg(self, rt, bxor(getReg(self, rs), imm)) end wroteReg = rt
	elseif opcode == 0x0F then if rt ~= 0 then setReg(self, rt, band(lshift(imm, 16), 0xFFFFFFFF)) end wroteReg = rt
	elseif opcode == 0x10 then
		-- cop0
		if band(self.cop0.status, 0x2) ~= 0 and band(self.cop0.status, 0x10000000) == 0 then
			-- user mode (kuc) without cu0: cpu, ce=0
			self:raiseException(EXCODE.CpU, nil, nil, 0)
		elseif rs == 0x00 then
			-- mfc0: 1-cycle load delay; unimplemented regs raise ri
			local value = self:getCop0(rd)
			if value == nil then
				self:raiseException(EXCODE.RI)
			else
				newLoad = { register = rt, value = value, delay = 1 }
			end
		elseif rs == 0x04 then
			if not self:setCop0(rd, getReg(self, rt)) then
				self:raiseException(EXCODE.RI)
			elseif rd == 12 and mem and mem.cacheIsolated ~= nil then
				-- keep the memory's cache-isolation flag in sync (mirrors cpu:setcop0)
				mem.cacheIsolated = band(self.cop0.status, SR_ISC) ~= 0
			end
	elseif rs == 0x10 and funct == 0x10 then
		-- rfe
		local oldStatus = self.cop0.status
		self.cop0.status = bor(band(oldStatus, bnot(0x0F)), band(rshift(oldStatus, 2), 0x0F))
	elseif rs == 0x10 and (funct == 0x01 or funct == 0x02 or funct == 0x06 or funct == 0x08) then
		-- tlb opcodes: reserved instruction (psx-spx)
		self:raiseException(EXCODE.RI)
	elseif rs == 0x02 or rs == 0x06 then
		-- cfc0 / ctc0: no-op (duckstation common-op default)
	elseif rs == 0x10 then
		-- other cop0 commands (incl. 0x18): no-op (duckstation error_log)
	else
		-- any other cop0 rs (cfc0/ctc0 and unknown commands like 0x1f): no-op
		-- (duckstation cop0 default; ps1-tests cop suite hardware-verifies).
	end
	elseif opcode == 0x11 or opcode == 0x13 then
		-- cop1 / cop3: the absent fpu raises cpu (ce=1/3) when its cu bit is
		-- clear (ps1-tests cop suite), else the instruction is a no-op.
		if opcode == 0x11 and band(self.cop0.status, SR_CU1) == 0 then
			self:raiseException(EXCODE.CpU, nil, nil, 1)
		elseif opcode == 0x13 and band(self.cop0.status, SR_CU3) == 0 then
			self:raiseException(EXCODE.CpU, nil, nil, 3)
		end
	elseif opcode == 0x12 then
		-- cop2: check sr.ce2 before any dispatch (duckstation begin_instruction), then gte ops / common ops / unknown-rs ri.
		if band(self.cop0.status, SR_CE2) == 0 then
			self:raiseException(EXCODE.CpU, nil, nil, 2)
		elseif band(ins, 0x02000000) ~= 0 then
			self:gteExecute(ins)
		elseif rs == 0x00 then
			newLoad = { register = rt, value = self:gteReadData(rd), delay = 1 }
		elseif rs == 0x02 then
			newLoad = { register = rt, value = self:gteReadCtrl(rd), delay = 1 }
		elseif rs == 0x04 then
			self:gteWriteData(rd, getReg(self, rt))
		elseif rs == 0x06 then
			self:gteWriteCtrl(rd, getReg(self, rt))
		else
			-- unknown cop2 common-op rs with ce2 set: no-op (duckstation
			-- error_log + break; hardware-verified by testcop2invalidopcode)
		end
	elseif opcode == 0x20 then
		local v = mem:read8(reg[rs + 1] + simm)
		if v >= 0x80 then v = v - 0x100 end
		newLoad = { register = rt, value = v, delay = 1 }
	elseif opcode == 0x24 then
		newLoad = { register = rt, value = mem:read8(reg[rs + 1] + simm), delay = 1 }
	elseif opcode == 0x21 then
		local addr = reg[rs + 1] + simm
		if band(addr, 1) ~= 0 then
			self:raiseException(EXCODE.AdEL, addr)
		else
			local v = mem:read16(addr)
			newLoad = { register = rt, value = v >= 0x8000 and v - 0x10000 or v, delay = 1 }
		end
	elseif opcode == 0x25 then
		local addr = reg[rs + 1] + simm
		if band(addr, 1) ~= 0 then
			self:raiseException(EXCODE.AdEL, addr)
		else
			newLoad = { register = rt, value = mem:read16(addr), delay = 1 }
		end
	elseif opcode == 0x23 then
		local addr = reg[rs + 1] + simm
		if band(addr, 3) ~= 0 then
			self:raiseException(EXCODE.AdEL, addr)
		else
			newLoad = { register = rt, value = mem:read32(addr), delay = 1 }
		end
	elseif opcode == 0x22 or opcode == 0x26 then
		-- lwl / lwr (psx-spx tables; the aligned variant transfers the whole word)
		local addr = reg[rs + 1] + simm
		local aligned = band(addr, bnot(3))
		local word = mem:read32(aligned)
		-- existing value: the pending load's value if rt is the load-delay reg
		local existing
		if self.pendingLoad ~= nil and self.pendingLoad.delay == 1 and self.pendingLoad.register == rt then
			existing = self.pendingLoad.value
		else
			existing = getReg(self, rt)
		end
		local shift = band(addr, 3)
		local newValue
		if opcode == 0x22 then
			-- lwl: mem << (24-8s) | existing & mask_keep
			local keep = { 0x00FFFFFF, 0x0000FFFF, 0x000000FF, 0x00000000 }
			newValue = bor(band(existing, keep[shift + 1]), band(lshift(word, 24 - shift * 8), 0xFFFFFFFF))
		else
			-- lwr: mem >> 8s | existing & mask_keep
			local keep = { 0x00000000, 0xFF000000, 0xFFFF0000, 0xFFFFFF00 }
			newValue = bor(band(existing, keep[shift + 1]), band(rshift(word, shift * 8), 0xFFFFFFFF))
		end
		newLoad = { register = rt, value = newValue, delay = 1 }
	elseif opcode == 0x30 or opcode == 0x31 or opcode == 0x33 then
		-- lwc0/1/3: perform the read, discard the result.  every absent coprocessor raises cpu (ce = its number) when its cu bit is clear, regardless of mode.
		local addr = reg[rs + 1] + simm
		local ce = opcode == 0x30 and 0 or (opcode == 0x31 and 1 or 3)
		local cu = opcode == 0x30 and SR_CU0 or (opcode == 0x31 and SR_CU1 or SR_CU3)
		if band(self.cop0.status, cu) == 0 then
			self:raiseException(EXCODE.CpU, nil, nil, ce)
		elseif band(addr, 3) ~= 0 then
			self:raiseException(EXCODE.AdEL, addr)
		else
			mem:read32(addr)
		end
	elseif opcode == 0x32 then
		-- lwc2: ce2 gate before the memory access (duckstation order)
		local addr = reg[rs + 1] + simm
		if band(self.cop0.status, SR_CE2) == 0 then
			self:raiseException(EXCODE.CpU, nil, nil, 2)
		elseif band(addr, 3) ~= 0 then
			self:raiseException(EXCODE.AdEL, addr)
		else
			self:gteWriteData(rt, mem:read32(addr))
		end
	elseif opcode == 0x38 or opcode == 0x39 or opcode == 0x3B then
		-- swc0/1/3: perform the write with value 0.  every absent coprocessor raises cpu (ce = its number) when its cu bit is clear, regardless of mode (duckstation leaves a "todo" and never raises).
		local addr = reg[rs + 1] + simm
		local ce = opcode == 0x38 and 0 or (opcode == 0x39 and 1 or 3)
		local cu = opcode == 0x38 and SR_CU0 or (opcode == 0x39 and SR_CU1 or SR_CU3)
		if band(self.cop0.status, cu) == 0 then
			self:raiseException(EXCODE.CpU, nil, nil, ce)
		elseif band(addr, 3) ~= 0 then
			self:raiseException(EXCODE.AdES, addr)
		else
			mem:write32(addr, 0)
		end
	elseif opcode == 0x3A then
		-- swc2: ce2 gate before the memory access (duckstation order)
		local addr = reg[rs + 1] + simm
		if band(self.cop0.status, SR_CE2) == 0 then
			self:raiseException(EXCODE.CpU, nil, nil, 2)
		elseif band(addr, 3) ~= 0 then
			self:raiseException(EXCODE.AdES, addr)
		else
			mem:write32(addr, self:gteReadData(rt))
		end
	elseif opcode == 0x28 then
		mem:write8(reg[rs + 1] + simm, reg[rt + 1])
	elseif opcode == 0x29 then
		local addr = reg[rs + 1] + simm
		if band(addr, 1) ~= 0 then
			self:raiseException(EXCODE.AdES, addr)
		else
			mem:write16(addr, reg[rt + 1])
		end
	elseif opcode == 0x2B then
		local addr = reg[rs + 1] + simm
		if band(addr, 3) ~= 0 then
			self:raiseException(EXCODE.AdES, addr)
		else
			mem:write32(addr, reg[rt + 1])
		end
	elseif opcode == 0x2A or opcode == 0x2E then
		-- swl / swr (psx-spx tables)
		local addr = reg[rs + 1] + simm
		local aligned = band(addr, bnot(3))
		local current = mem:read32(aligned)
		local shift = band(addr, 3)
		local v = reg[rt + 1]
		local newValue
		if opcode == 0x2A then
			-- swl: mem & keep | value >> (24-8s)
			local keep = { 0xFFFFFF00, 0xFFFF0000, 0xFF000000, 0x00000000 }
			newValue = bor(band(current, keep[shift + 1]), band(rshift(v, 24 - shift * 8), 0xFFFFFFFF))
		else
			-- swr: mem & keep | value << 8s
			local keep = { 0x00000000, 0x000000FF, 0x0000FFFF, 0x00FFFFFF }
			newValue = bor(band(current, keep[shift + 1]), band(lshift(v, shift * 8), 0xFFFFFFFF))
		end
		mem:write32(aligned, newValue)
	else
		self:raiseException(EXCODE.RI)
	end

	self._delaySlotWroteReg = wroteReg
	return newBranch, newLoad
end

-- cop0 register access (with hardware write masks / ri for unimplemented)

local COPO_REGISTERED = {
	[3] = true, [5] = true, [6] = true, [7] = true, [8] = true, [9] = true,
	[11] = true, [12] = true, [13] = true, [14] = true, [15] = true,
}

function CPURef:getCop0(index)
	-- returns nil for unimplemented registers (mfc0 -> ri)
	if not COPO_REGISTERED[index] then return nil end
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

function CPURef:setCop0(index, value)
	value = band(value, 0xFFFFFFFF)
	local c = self.cop0
	if index == 3 then c.bpc = value
	elseif index == 5 then c.bda = value
	elseif index == 6 then
		-- tar: write ignored
	elseif index == 7 then c.dcic = bor(band(c.dcic, bnot(DCIC_WRITE_MASK)), band(value, DCIC_WRITE_MASK))
	elseif index == 8 then
		-- badvaddr: write ignored
	elseif index == 9 then c.bdam = value
	elseif index == 11 then c.bpcm = value
	elseif index == 12 then
		c.status = bor(band(c.status, bnot(SR_WRITE_MASK)), band(value, SR_WRITE_MASK))
	elseif index == 13 then
		c.cause = bor(band(c.cause, bnot(CAUSE_WRITE_MASK)), band(value, CAUSE_WRITE_MASK))
	elseif index == 14 then
		-- epc: write ignored (read-only per psx-spx / duckstation)
	elseif index == 15 then
		-- prid: mtc0 raises ri (duckstation's mtc0 switch has no case for it)
		return false
	else
		-- unimplemented register: raise ri (return false)
		return false
	end
	return true
end

-- gte passthroughs (the harness wires these to the emulator's gte for fuzz;
-- for the game shadow they call the real gte)

function CPURef:gteExecute(ins)
	if self._gte then self._gte:execute(ins) end
end
function CPURef:gteReadData(reg)
	if self._gte then return self._gte:readData(reg) end
	return 0
end
function CPURef:gteReadCtrl(reg)
	if self._gte then return self._gte:readCtrl(reg) end
	return 0
end
function CPURef:gteWriteData(reg, v)
	if self._gte then self._gte:writeData(reg, v) end
end
function CPURef:gteWriteCtrl(reg, v)
	if self._gte then self._gte:writeCtrl(reg, v) end
end

-- one instruction.

function CPURef:step(ins, mem, pendingIrq)
	if self.halted then
		return
	end		-- capture the taken-branch state BEFORE the interrupt check (it drives
		-- the bt flag and tar on an exception in a taken-branch delay slot)
		self._stepBranchTaken = self.pendingBranch ~= nil and self.pendingBranch.delay == 1
		self._stepBranchTarget = self._stepBranchTaken and self.pendingBranch.target or nil

		-- 1. interrupt check (mirror of checkinterrupts)
		local cop0 = self.cop0
		cop0.cause = band(cop0.cause, 0xFFFF00FF)
		if pendingIrq ~= 0 then
			cop0.cause = bor(cop0.cause, 0x00000400)
			local status = cop0.status
			if band(status, 1) ~= 0 and band(status, 0x00000400) ~= 0 then
				-- a pending gte command still executes while the interrupt is serviced (duckstation dispatchinterrupt: op==cop2 && !iscommoninstruction(), no ce2 check).
				if band(ins, 0xFC000000) == 0x48000000 and band(ins, 0x02000000) ~= 0 then						self:gteExecute(ins)
					end
					self:raiseException(EXCODE.INT)
				return
			end
		end

		local currentPc = band(self.pc, 0xFFFFFFFF)
		self.nextPc = band(currentPc + 4, 0xFFFFFFFF)

		local oldBranch = self.pendingBranch
		local oldLoad = self.pendingLoad
		local oldLoadRegBefore = nil
		if oldLoad and oldLoad.register ~= 0 then
			oldLoadRegBefore = self.registers[oldLoad.register + 1]
		end
		self.pendingBranch = nil
		self.pendingLoad = nil
		self.inDelaySlot = (oldBranch ~= nil and oldBranch.delay == 1) or self._notTakenDelaySlot == true
		self._notTakenDelaySlot = false
		self._delaySlotWroteReg = nil

		local newBranch, newLoad = self:execute(ins, mem)

	-- 2. exception abort (raiseexception already redirected pc + cleared pending)
	if self.pc ~= currentPc then
		self.inDelaySlot = false
		self.registers[1] = 0
		return
	end

	-- 3. commit old pending state
	if oldBranch or oldLoad then
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
				-- exact index-based load-delay hazard: the delay-slot instruction
				-- writing the load's register discards the load
				if self._delaySlotWroteReg ~= oldLoad.register then
					setReg(self, oldLoad.register, oldLoad.value)
				end
			else
				self.pendingLoad = oldLoad
			end
		end
	end

	if newBranch then
		self.pendingBranch = newBranch
	end
	if newLoad then
		self.pendingLoad = newLoad
	end

	self.pc = band(self.nextPc, 0xFFFFFFFF)
	self.inDelaySlot = false
	self.registers[1] = 0
end

return CPURef
