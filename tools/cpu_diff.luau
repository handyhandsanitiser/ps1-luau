-- cpu differential: core CPU (src/shared/PS1/CPU.luau) vs tools/cpu_ref.luau, instruction by
-- instruction.  runs a curated corpus on three engines -- stepBaseline, the block interpreter,
-- and the ref -- each on a fresh ram-only shim, comparing full cpu state plus per-instruction
-- stores after every instruction; an underrun is a failure.  an encoding self-test runs first (a
-- shared mis-encoding is invisible to the differential), then a decoder fuzz over words the
-- assembler can't emit.
-- scope: ram + a minimal interrupt-controller lane, with a harness-side device line delivering
-- interrupts at instruction boundaries.
-- usage: lune run tools/cpu_diff.luau   (or via tools/run.luau cpudiff)

local Loader = require("./lib/ps1loader")
local requirePs1 = Loader.createRequire()
local CPU = requirePs1("CPU")
local CPURef = require("./cpu_ref")

local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift
local function bnot32(v)
	return band(bit32.bnot(v), 0xFFFFFFFF)
end

-- ---------------------------------------------------------------------------
-- ram-only memory shim handed to both engines (a shared bus): only the ram kseg window plus the
-- interrupt-controller halfword lane is mapped.  every write-side access also appends to
-- shim:_logWrite so runengine can compare the stores themselves -- the shared bytes cannot
-- (one side's store overwrites the other's before any read sees them).

local RAM_SIZE = 0x200000 -- 2 MB

local function newShim()
	local shim = {}
	-- lazy ram: a hash-backed table with `or 0` reads is byte-identical to dense zeros but skips the per-instance fill (436 streams x 2 engines were allocating ~457M cells).
	shim.ram32 = {}
	shim.ramMappedEnd = RAM_SIZE
	shim.ramMask = RAM_SIZE - 1
	shim.iStat = 0
	shim.iMask = 0
	-- block-engine pending-irq cache (mirrors band(iStat, iMask); refreshed at
	-- every shim write site below so both engines observe identical pendings).
	shim._irqState = 0
	shim.cacheIsolated = false
	shim.cycleCount = 0
	shim.flux = 0
	shim._periphBatch = 0x40000000 -- device stepping never fires in cpu-only runs
	shim.busError = false
	shim.joypad = { ackAsserted = false, pendingPadIrqCycle = nil, irqFlag = false, ackCycle = 0, _needsStep = false }
	shim.dma = { haltTicksRemaining = 0, resumePending = false, inTickCharge = false }
	local noop = function() end
	shim.spu = { step = noop }
	shim.gpu = { step = noop }
	shim.cdrom = { step = noop }
	shim.timers = { advance = noop }

	-- the core stalls on mfhi/mflo/mthi/mtlo while a mult/div is in flight
	-- (mulDivBusyUntil) and advances the bus clock to the completion point.
	function shim:advanceCycles(cyc)
		self.cycleCount += cyc
	end

	-- block-engine page stamps call memory:physicalAddress on every block
	-- build; the shim maps the kseg0/kseg1 windows to their physical page.
	function shim:physicalAddress(vaddr)
		local region = band(vaddr, 0xE0000000)
		if region == 0x80000000 or region == 0xA0000000 then
			return band(vaddr, 0x1FFFFFFF)
		end
		return band(vaddr, 0xFFFFFFFF)
	end

	function shim:physical(vaddr)
		local region = band(vaddr, 0xE0000000)
		if region == 0x80000000 or region == 0xA0000000 then
			local phys = band(vaddr, 0x1FFFFFFF)
			if phys < self.ramMappedEnd then
				phys = band(phys, self.ramMask)
			end
			if phys < RAM_SIZE then
				return phys
			end
		end
		return nil
	end

	function shim:read32(vaddr)
		local phys = self:physical(vaddr)
		if not phys then
			return 0
		end
		return self.ram32[phys // 4 + 1] or 0
	end

	-- write-side block invalidation: the shim must bump page-version stamps like real Memory, or cached blocks survive stores forever (the smc_patch program demonstrated a stale block re-running its old jump).
	function shim:bumpPages(phys)
		if self.onRamWrite then
			self.onRamWrite(phys)
		end
	end

	-- shared-bus blind spot: a divergent store is overwritten by the other side's before anything reads it, so cpu-state agreement never sees it -- the write log is the only witness.
	function shim:_logWrite(vaddr, width, value)
		local log = self._writeLog
		if log then
			log[#log + 1] = {
				vaddr,
				width,
				band(value, width == 8 and 0xFF or (width == 16 and 0xFFFF or 0xFFFFFFFF)),
			}
		end
	end

	function shim:write32(vaddr, value)
		local phys = self:physical(vaddr)
		if not phys then
			return
		end
		self:_logWrite(vaddr, 32, value)
		self.ram32[phys // 4 + 1] = band(value, 0xFFFFFFFF)
		self:bumpPages(phys)
	end

	function shim:read16(vaddr)
		local phys = self:physical(vaddr)
		if not phys then
			return 0
		end
		local word = self.ram32[phys // 4 + 1] or 0
		return band(rshift(word, band(phys, 3) * 8), 0xFFFF)
	end

	function shim:write16(vaddr, value)
		-- interrupt controller: the only mmio lane the corpus needs (i_stat write-0-to-clear, i_mask accepts the value).
		if vaddr == 0x1F801070 then
			self:_logWrite(vaddr, 16, value)
			self.iStat = band(self.iStat, band(value, 0xFFFF))
			local p = band(self.iStat, self.iMask)
			self._irqState = (p ~= 0) and bor(p, 0x80000000) or band(self._irqState or 0, 0x80000000)
			return
		elseif vaddr == 0x1F801074 then
			self:_logWrite(vaddr, 16, value)
			self.iMask = band(value, 0xFFFF)
			local p = band(self.iStat, self.iMask)
			self._irqState = (p ~= 0) and bor(p, 0x80000000) or band(self._irqState or 0, 0x80000000)
			return
		end
		local phys = self:physical(vaddr)
		if not phys then
			return
		end
		self:_logWrite(vaddr, 16, value)
		local index = phys // 4 + 1
		local shift = band(phys, 3) * 8
		local word = self.ram32[index] or 0
		local keep = bnot32(lshift(0xFFFF, shift))
		self.ram32[index] = bor(band(word, keep), band(lshift(band(value, 0xFFFF), shift), 0xFFFFFFFF))
		self:bumpPages(phys)
	end

	function shim:read8(vaddr)
		local phys = self:physical(vaddr)
		if not phys then
			return 0
		end
		local word = self.ram32[phys // 4 + 1] or 0
		return band(rshift(word, band(phys, 3) * 8), 0xFF)
	end

	function shim:write8(vaddr, value)
		local phys = self:physical(vaddr)
		if not phys then
			return
		end
		self:_logWrite(vaddr, 8, value)
		local index = phys // 4 + 1
		local shift = band(phys, 3) * 8
		local word = self.ram32[index] or 0
		local keep = bnot32(lshift(0xFF, shift))
		self.ram32[index] = bor(band(word, keep), band(lshift(band(value, 0xFF), shift), 0xFFFFFFFF))
		self:bumpPages(phys)
	end

	function shim:setInterruptLine() end

	return shim
end

-- ---------------------------------------------------------------------------
-- assembler: rows are { mnemonic, arg... }; a label is { "label", name } binding to the next
-- instruction.  labels consume no slot, so instruction index == word index.

local function rtype(funct, rs, rt, rd, sa)
	return bor(lshift(funct, 0), lshift(rs, 21), lshift(rt, 16), lshift(rd, 11), lshift(sa, 6))
end
local function itype(op, rs, rt, imm)
	return bor(lshift(op, 26), lshift(rs, 21), lshift(rt, 16), band(imm, 0xFFFF))
end

local A = {}
-- register group (funct)
A.addu = function(rd, rs, rt) return rtype(0x21, rs, rt, rd, 0) end
A.subu = function(rd, rs, rt) return rtype(0x23, rs, rt, rd, 0) end
A.add = function(rd, rs, rt) return rtype(0x20, rs, rt, rd, 0) end
A.sub = function(rd, rs, rt) return rtype(0x22, rs, rt, rd, 0) end
A.slt = function(rd, rs, rt) return rtype(0x2A, rs, rt, rd, 0) end
A.sltu = function(rd, rs, rt) return rtype(0x2B, rs, rt, rd, 0) end
A.and_ = function(rd, rs, rt) return rtype(0x24, rs, rt, rd, 0) end
A.or_ = function(rd, rs, rt) return rtype(0x25, rs, rt, rd, 0) end
A.xor_ = function(rd, rs, rt) return rtype(0x26, rs, rt, rd, 0) end
A.nor_ = function(rd, rs, rt) return rtype(0x27, rs, rt, rd, 0) end
A.sll = function(rd, rt, sa) return rtype(0x00, 0, rt, rd, sa) end
A.srl = function(rd, rt, sa) return rtype(0x02, 0, rt, rd, sa) end
A.sra = function(rd, rt, sa) return rtype(0x03, 0, rt, rd, sa) end
A.sllv = function(rd, rt, rs) return rtype(0x04, rs, rt, rd, 0) end
A.srlv = function(rd, rt, rs) return rtype(0x06, rs, rt, rd, 0) end
A.srav = function(rd, rt, rs) return rtype(0x07, rs, rt, rd, 0) end
A.mult = function(rs, rt) return rtype(0x18, rs, rt, 0, 0) end
A.multu = function(rs, rt) return rtype(0x19, rs, rt, 0, 0) end
A.div = function(rs, rt) return rtype(0x1A, rs, rt, 0, 0) end
A.divu = function(rs, rt) return rtype(0x1B, rs, rt, 0, 0) end
A.mfhi = function(rd) return rtype(0x10, 0, 0, rd, 0) end
A.mflo = function(rd) return rtype(0x12, 0, 0, rd, 0) end
A.mthi = function(rs) return rtype(0x11, rs, 0, 0, 0) end
A.mtlo = function(rs) return rtype(0x13, rs, 0, 0, 0) end
A.jr = function(rs) return rtype(0x08, rs, 0, 0, 0) end
A.jalr = function(rd, rs) return rtype(0x09, rs, 0, rd, 0) end
A.syscall = function() return rtype(0x0C, 0, 0, 0, 0) end
A.break_ = function() return rtype(0x0D, 0, 0, 0, 0) end
-- rfe is a cop0 op word: opcode 0x10, rs 0x10, funct 0x10 (0x42000010) -- NOT rtype (the old 0x02000010 form decoded as mfhi $0 in every engine).
A.rfe = function() return itype(0x10, 0x10, 0, 0x10) end
-- immediate group
A.addiu = function(rt, rs, imm) return itype(0x09, rs, rt, imm) end
A.addi = function(rt, rs, imm) return itype(0x08, rs, rt, imm) end
A.slti = function(rt, rs, imm) return itype(0x0A, rs, rt, imm) end
A.sltiu = function(rt, rs, imm) return itype(0x0B, rs, rt, imm) end
A.andi = function(rt, rs, imm) return itype(0x0C, rs, rt, imm) end
A.ori = function(rt, rs, imm) return itype(0x0D, rs, rt, imm) end
A.xori = function(rt, rs, imm) return itype(0x0E, rs, rt, imm) end
A.lui = function(rt, imm) return itype(0x0F, 0, rt, imm) end
-- load/store group
A.lb = function(rt, rs, imm) return itype(0x20, rs, rt, imm) end
A.lbu = function(rt, rs, imm) return itype(0x24, rs, rt, imm) end
A.lh = function(rt, rs, imm) return itype(0x21, rs, rt, imm) end
A.lhu = function(rt, rs, imm) return itype(0x25, rs, rt, imm) end
A.lw = function(rt, rs, imm) return itype(0x23, rs, rt, imm) end
A.lwl = function(rt, rs, imm) return itype(0x22, rs, rt, imm) end
A.lwr = function(rt, rs, imm) return itype(0x26, rs, rt, imm) end
A.sb = function(rt, rs, imm) return itype(0x28, rs, rt, imm) end
A.sh = function(rt, rs, imm) return itype(0x29, rs, rt, imm) end
A.sw = function(rt, rs, imm) return itype(0x2B, rs, rt, imm) end
A.swl = function(rt, rs, imm) return itype(0x2A, rs, rt, imm) end
A.swr = function(rt, rs, imm) return itype(0x2E, rs, rt, imm) end
-- cop0 (rs selects the operation; the cop0 register field is bits 15-11,
-- i.e. the imm slot shifted by 11: rd << 11, not rd << 8)
A.mfc0 = function(rt, rd) return itype(0x10, 0x00, rt, rd * 0x800) end
A.mtc0 = function(rt, rd) return itype(0x10, 0x04, rt, rd * 0x800) end
-- control flow (labels resolved at assembly)
A.beq = function(rs, rt, tgt) return { kind = "branch", op = 0x04, rs = rs, rt = rt, tgt = tgt } end
A.bne = function(rs, rt, tgt) return { kind = "branch", op = 0x05, rs = rs, rt = rt, tgt = tgt } end
A.blez = function(rs, tgt) return { kind = "branch", op = 0x06, rs = rs, rt = 0, tgt = tgt } end
A.bgtz = function(rs, tgt) return { kind = "branch", op = 0x07, rs = rs, rt = 0, tgt = tgt } end
A.bltz = function(rs, tgt) return { kind = "branch", op = 0x01, rs = rs, rt = 0x00, tgt = tgt } end
A.bgez = function(rs, tgt) return { kind = "branch", op = 0x01, rs = rs, rt = 0x01, tgt = tgt } end
A.bltzal = function(rs, tgt) return { kind = "branch", op = 0x01, rs = rs, rt = 0x10, tgt = tgt } end
A.bgezal = function(rs, tgt) return { kind = "branch", op = 0x01, rs = rs, rt = 0x11, tgt = tgt } end
A.j = function(tgt) return { kind = "jump", link = false, tgt = tgt } end
A.jal = function(tgt) return { kind = "jump", link = true, tgt = tgt } end

local function assemble(code, basePc)
	local labelIndex = {}
	local instRows = {}
	local pending = nil
	for _, row in ipairs(code) do
		if row[1] == "label" then
			pending = row[2]
		else
			if pending then
				labelIndex[pending] = #instRows
				pending = nil
			end
			instRows[#instRows + 1] = row
		end
	end
	-- a trailing label (nothing follows it) binds one word past the last
	-- instruction: the natural "fall off the end" landing address.
	if pending then
		labelIndex[pending] = #instRows
	end
	local words = {}
	for idx, row in ipairs(instRows) do
		local fn = A[row[1]]
		if not fn then
			error("unknown mnemonic: " .. tostring(row[1]))
		end
		local word = fn(row[2], row[3], row[4])
		if type(word) == "table" then
			local target = labelIndex[word.tgt]
			if target == nil then
				error("unknown label: " .. tostring(word.tgt))
			end
			if word.kind == "branch" then
				-- delay slot is one word past the branch
				local imm = target - idx
				word = itype(word.op, word.rs, word.rt, imm)
			else
				local targetAddr = basePc + target * 4
				local op = word.link and 3 or 2
				word = bor(lshift(op, 26), band(targetAddr // 4, 0x03FFFFFF))
			end
		end
		words[idx] = word
	end
	return words
end

-- code and data live at fixed addresses in the shared 2 MB ram window.
local CODE_BASE = 0x80020000
local DATA_BASE = 0x80030000

-- ---------------------------------------------------------------------------
-- golden-instruction self-test: pins the word each mnemonic must assemble to (a mis-encoding is
-- shared by all three engines and passes the differential -- exactly how the cop0 rd << 8 bug
-- survived a round), plus label/branch/jump resolution of whole programs.

local GOLDEN = {
	{ "addiu", 8, 4, 1, 0x24880001 },
	{ "addiu", 8, 4, -1, 0x2488FFFF },
	{ "addi", 8, 4, -3, 0x2088FFFD },
	{ "slti", 14, 4, -1, 0x288EFFFF },
	{ "sltiu", 15, 5, 1, 0x2CAF0001 },
	{ "andi", 16, 6, 0xFF00, 0x30D0FF00 },
	{ "ori", 16, 16, 0x00FF, 0x361000FF },
	{ "xori", 17, 6, 0xFFFF, 0x38D1FFFF },
	{ "lui", 18, 0xDEAD, 0x3C12DEAD },
	{ "lb", 10, 4, 0, 0x808A0000 },
	{ "lbu", 11, 4, 3, 0x908B0003 },
	{ "lh", 12, 4, 2, 0x848C0002 },
	{ "lhu", 13, 4, 2, 0x948D0002 },
	{ "lw", 5, 4, 0, 0x8C850000 },
	{ "lwl", 18, 4, 5, 0x88920005 },
	{ "lwr", 18, 4, 5, 0x98920005 },
	{ "sb", 8, 4, 1, 0xA0880001 },
	{ "sh", 14, 4, 10, 0xA48E000A },
	{ "sw", 16, 4, 12, 0xAC90000C },
	{ "swl", 16, 4, 5, 0xA8900005 },
	{ "swr", 16, 4, 5, 0xB8900005 },
	{ "addu", 9, 4, 5, 0x00854821 },
	{ "subu", 10, 4, 5, 0x00855023 },
	{ "add", 8, 4, 6, 0x00864020 },
	{ "sub", 8, 4, 5, 0x00854022 },
	{ "slt", 12, 4, 5, 0x0085602A },
	{ "sltu", 13, 4, 5, 0x0085682B },
	{ "and_", 8, 4, 5, 0x00854024 },
	{ "or_", 9, 4, 5, 0x00854825 },
	{ "xor_", 10, 4, 5, 0x00855026 },
	{ "nor_", 11, 6, 0, 0x00C05827 },
	{ "sll", 19, 6, 4, 0x00069900 },
	{ "srl", 19, 6, 4, 0x00069902 },
	{ "sra", 19, 4, 4, 0x00049903 },
	{ "sllv", 20, 6, 7, 0x00E6A004 },
	{ "srlv", 20, 6, 7, 0x00E6A006 },
	{ "srav", 20, 4, 7, 0x00E4A007 },
	{ "mult", 4, 5, 0x00850018 },
	{ "multu", 4, 5, 0x00850019 },
	{ "div", 4, 6, 0x0086001A },
	{ "divu", 4, 0, 0x0080001B },
	{ "mfhi", 8, 0x00004010 },
	{ "mflo", 9, 0x00004812 },
	{ "mthi", 4, 0x00800011 },
	{ "mtlo", 5, 0x00A00013 },
	{ "jr", 4, 0x00800008 },
	{ "jalr", 15, 4, 0x00807809 },
	{ "syscall", 0x0000000C },
	{ "break_", 0x0000000D },
	{ "rfe", 0x42000010 },
	{ "mfc0", 7, 12, 0x40076000 },
	{ "mfc0", 8, 0, 0x40080000 },
	{ "mtc0", 4, 12, 0x40846000 },
	{ "mtc0", 4, 15, 0x40847800 },
}

-- whole-program pins: forward branch to the next instruction encodes imm = 1, trailing labels bind one word past the end, jump targets resolve against code_base.
local GOLDEN_PROGRAM = {
	name = "golden_branches",
	code = {
		{ "beq", 4, 5, "T1" }, { "sll", 0, 0, 0 }, { "label", "T1" },
		{ "j", "END1" }, { "sll", 0, 0, 0 }, { "label", "END1" },
		{ "addiu", 9, 0, 1 },
	},
	words = {
		-- beq lands on word 2 (0-based); j lands on word 4 (code_base + 16)
		0x10850001, 0x00000000, 0x08008004, 0x00000000, 0x24090001,
	},
}

local GOLDEN_PROGRAM2 = {
	name = "golden_regimm",
	code = {
		{ "bne", 4, 5, "A" }, { "sll", 0, 0, 0 }, { "label", "A" },
		{ "blez", 4, "B" }, { "sll", 0, 0, 0 }, { "label", "B" },
		{ "bgtz", 5, "C" }, { "sll", 0, 0, 0 }, { "label", "C" },
		{ "bltz", 6, "D" }, { "sll", 0, 0, 0 }, { "label", "D" },
		{ "bgez", 4, "E" }, { "sll", 0, 0, 0 }, { "label", "E" },
		{ "bltzal", 6, "F" }, { "sll", 0, 0, 0 }, { "label", "F" },
		{ "bgezal", 4, "G" }, { "sll", 0, 0, 0 }, { "label", "G" },
		{ "jal", "H" }, { "sll", 0, 0, 0 }, { "label", "H" },
		{ "addiu", 10, 0, 2 },
	},
	words = {
		0x14850001, 0x00000000, -- bne to A (word 2)
		0x18800001, 0x00000000, -- blez to B (word 4)
		0x1CA00001, 0x00000000, -- bgtz to C (word 6)
		0x04C00001, 0x00000000, -- bltz to D (word 8)
		0x04810001, 0x00000000, -- bgez to E (word 10)
		0x04D00001, 0x00000000, -- bltzal to F (word 12)
		0x04910001, 0x00000000, -- bgezal to G (word 14)
		0x0C008010, 0x00000000, -- jal to H (word 16 = code_base + 64)
		0x240A0002,
	},
}

local function runSelfTest()
	local failures = 0
	for _, row in ipairs(GOLDEN) do
		local mnemonic = row[1]
		local expected = row[#row]
		local fn = A[mnemonic]
		local word
		if mnemonic == "syscall" or mnemonic == "break_" or mnemonic == "rfe" then
			word = fn()
		elseif mnemonic == "jr" then
			word = fn(row[2])
		elseif mnemonic == "mfhi" or mnemonic == "mflo" then
			word = fn(row[2])
		elseif mnemonic == "mthi" or mnemonic == "mtlo" then
			word = fn(row[2])
		elseif mnemonic == "mult" or mnemonic == "multu" or mnemonic == "div" or mnemonic == "divu" then
			word = fn(row[2], row[3])
		elseif mnemonic == "jalr" then
			word = fn(row[2], row[3])
		else
			word = fn(row[2], row[3], row[4])
		end
		if word ~= expected then
			failures += 1
			print(string.format(
				"SELF_TEST FAIL %s: assembled %08X expected %08X",
				mnemonic, word or 0, expected
			))
		end
	end
	for _, prog in ipairs({ GOLDEN_PROGRAM, GOLDEN_PROGRAM2 }) do
		local words = assemble(prog.code, CODE_BASE)
		if #words ~= #prog.words then
			failures += 1
			print(string.format(
				"SELF_TEST FAIL %s: %d words assembled, %d expected",
				prog.name, #words, #prog.words
			))
		else
			for index = 1, #words do
				if words[index] ~= prog.words[index] then
					failures += 1
					print(string.format(
						"SELF_TEST FAIL %s word %d: assembled %08X expected %08X",
						prog.name, index, words[index], prog.words[index]
					))
				end
			end
		end
	end
	if failures == 0 then
		print(string.format("SELF_TEST PASS: %d instruction pins + 2 label programs", #GOLDEN))
	end
	return failures == 0
end

-- ---------------------------------------------------------------------------
-- comparator

local COPO_FIELDS = {
	"status", "cause", "epc", "badvaddr", "prid",
	"bpc", "bpcm", "bda", "bdam", "dcic", "tar",
}

local function describe(value)
	if type(value) == "number" then
		return string.format("%08X", band(value, 0xFFFFFFFF))
	end
	return tostring(value)
end

-- per-instruction write agreement: both sides must perform byte-identical stores (same count, addresses, widths, values); only stores are compared, never the shared bytes ({ vaddr, width, masked value }).

local function writeRowKey(row)
	return string.format("%08X:%d:%X", row[1], row[2], row[3])
end

local function summarizeRows(rows)
	local keys = {}
	for i = 1, #rows do
		keys[i] = writeRowKey(rows[i])
	end
	table.sort(keys)
	if #keys > 6 then
		keys[7] = string.format("... (%d stores)", #keys)
	end
	return table.concat(keys, " ")
end

-- run fn with the shim's write log open, then return and close it
local function captureWrites(shim, fn)
	shim._writeLog = {}
	fn()
	local rows = shim._writeLog
	shim._writeLog = nil
	return rows
end

-- returns nil when both sides wrote byte-identically, else a description
local function compareWrites(refRows, coreRows)
	-- fast path: most instructions store nothing, so skip the key building and
	-- both sorts entirely (two empty logs trivially agree).
	if #refRows == 0 and #coreRows == 0 then
		return nil
	end
	if #refRows ~= #coreRows then
		return string.format(
			"ref wrote %d store(s) [%s] but core wrote %d [%s]",
			#refRows, summarizeRows(refRows), #coreRows, summarizeRows(coreRows)
		)
	end
	local a, b = {}, {}
	for i = 1, #refRows do
		a[i] = writeRowKey(refRows[i])
		b[i] = writeRowKey(coreRows[i])
	end
	table.sort(a)
	table.sort(b)
	for i = 1, #a do
		if a[i] ~= b[i] then
			return string.format(
				"stores diverge: ref [%s] vs core [%s]",
				summarizeRows(refRows), summarizeRows(coreRows)
			)
		end
	end
	return nil
end

-- returns nil when equal, else a description of the first difference
local function compareState(cpu, ref)
	for slot = 1, 32 do
		local a = cpu.registers[slot] or 0
		local b = ref.registers[slot] or 0
		if a ~= b then
			return string.format("gpr[%d] core=%s ref=%s", slot - 1, describe(a), describe(b))
		end
	end
	if (cpu.hi or 0) ~= (ref.hi or 0) then
		return string.format("hi core=%s ref=%s", describe(cpu.hi), describe(ref.hi))
	end
	if (cpu.lo or 0) ~= (ref.lo or 0) then
		return string.format("lo core=%s ref=%s", describe(cpu.lo), describe(ref.lo))
	end
	for _, name in ipairs(COPO_FIELDS) do
		local a = (cpu.cop0 and cpu.cop0[name]) or 0
		local b = (ref.cop0 and ref.cop0[name]) or 0
		if a ~= b then
			return string.format("cop0.%s core=%s ref=%s", name, describe(a), describe(b))
		end
	end
	if (cpu.pc or 0) ~= (ref.pc or 0) then
		return string.format("pc core=%s ref=%s", describe(cpu.pc), describe(ref.pc))
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- corpus

local PROGRAMS = {}

local function seedRegister(cpu, ref, reg, value)
	if reg ~= 0 then
		cpu:setRegister(reg, value)
	end
	ref.registers[reg + 1] = band(value, 0xFFFFFFFF)
end

-- 1: integer alu basics, signs, shifts, logic
PROGRAMS[#PROGRAMS + 1] = {
	name = "alu",
	regs = { { 4, 0x80000000 }, { 5, 0x7FFFFFFF }, { 6, 0x12345678 }, { 7, 17 } },
	code = {
		{ "addiu", 8, 4, 1 },     -- r8 = 0x80000001
		{ "addiu", 8, 4, -1 },    -- r8 = 0x7FFFFFFF
		{ "addu", 9, 4, 5 },      -- r9 = 0xFFFFFFFF
		{ "subu", 10, 4, 5 },     -- r10 = 1
		{ "subu", 10, 5, 4 },     -- r10 = 0xFFFFFFFF
		{ "slt", 12, 4, 5 },      -- signed: 1
		{ "slt", 12, 5, 4 },      -- signed: 0
		{ "sltu", 13, 4, 5 },     -- unsigned: 0
		{ "sltu", 13, 5, 4 },     -- unsigned: 1
		{ "slti", 14, 4, -1 },    -- 0x80000000 < -1: 1
		{ "slti", 14, 5, -1 },    -- 0x7FFFFFFF < -1: 0
		{ "sltiu", 15, 5, 1 },    -- 0x7FFFFFFF < 1 unsigned: 0
		{ "andi", 16, 6, 0xFF00 },
		{ "ori", 16, 16, 0x00FF },
		{ "xori", 17, 6, 0xFFFF },
		{ "lui", 18, 0xDEAD },
		{ "and_", 8, 4, 5 },      -- 0
		{ "or_", 9, 4, 5 },       -- 0xFFFFFFFF
		{ "xor_", 10, 4, 5 },     -- 0xFFFFFFFF
		{ "nor_", 11, 6, 0 },     -- bnot(0x12345678)
		{ "sll", 19, 6, 4 },
		{ "srl", 19, 6, 4 },
		{ "sra", 19, 4, 4 },      -- 0xF8000000
		{ "sllv", 20, 6, 7 },
		{ "srlv", 20, 6, 7 },
		{ "srav", 20, 4, 7 },     -- 0x80000000 >>> 17
	},
}

-- 2: signed overflow exceptions (each ends the program)
PROGRAMS[#PROGRAMS + 1] = {
	name = "ov_add",
	raises = true, -- program ends by raising to the exception vector
	regs = { { 4, 0x7FFFFFFF }, { 5, 0x80000000 }, { 6, 1 } },
	code = {
		{ "add", 8, 4, 6 }, -- overflow -> exception
	},
}
PROGRAMS[#PROGRAMS + 1] = {
	name = "ov_sub",
	raises = true,
	regs = { { 4, 0x80000000 }, { 5, 1 } },
	code = {
		{ "sub", 8, 4, 5 }, -- 0x80000000 - 1 overflows
	},
}
PROGRAMS[#PROGRAMS + 1] = {
	name = "ov_addi",
	raises = true,
	regs = { { 4, 0x7FFFFFFF } },
	code = {
		{ "addi", 8, 4, 1 },
	},
}

-- 3: multiply / divide, including the special cases
PROGRAMS[#PROGRAMS + 1] = {
	name = "multdiv",
	regs = { { 4, 0x80000000 }, { 5, 0xFFFFFFFF }, { 6, 3 } },
	code = {
		{ "mult", 4, 5 },
		{ "sll", 0, 0, 0 }, { "sll", 0, 0, 0 }, -- mul/div latency slack
		{ "mfhi", 8 },
		{ "mflo", 9 },
		{ "multu", 4, 5 },
		{ "sll", 0, 0, 0 }, { "sll", 0, 0, 0 },
		{ "mfhi", 10 },
		{ "mflo", 11 },
		{ "div", 4, 6 },
		{ "sll", 0, 0, 0 }, { "sll", 0, 0, 0 },
		{ "mflo", 12 }, -- 0x80000000 / 3
		{ "mfhi", 13 },
		{ "div", 4, 5 }, -- -2^31 / -1 special
		{ "sll", 0, 0, 0 }, { "sll", 0, 0, 0 },
		{ "mflo", 14 }, -- 0x80000000
		{ "mfhi", 15 }, -- 0
		{ "div", 4, 0 }, -- signed divide by zero
		{ "sll", 0, 0, 0 }, { "sll", 0, 0, 0 },
		{ "mflo", 16 }, -- 1 (negative numerator)
		{ "mfhi", 17 }, -- numerator
		{ "divu", 4, 0 }, -- unsigned divide by zero
		{ "sll", 0, 0, 0 }, { "sll", 0, 0, 0 },
		{ "mflo", 18 }, -- 0xFFFFFFFF
		{ "mfhi", 19 }, -- numerator
		{ "mthi", 4 },
		{ "mtlo", 5 },
		{ "mfhi", 20 },
		{ "mflo", 21 },
		{ "divu", 4, 6 },
		{ "sll", 0, 0, 0 }, { "sll", 0, 0, 0 },
		{ "mflo", 22 },
		{ "mfhi", 23 },
	},
}

-- 4: branches with delay slots, both directions
PROGRAMS[#PROGRAMS + 1] = {
	name = "branches",
	regs = { { 4, 0 }, { 5, 1 }, { 6, 0xFFFFFFFF }, { 7, 0x80000000 } },
	code = {
		{ "beq", 4, 0, "L1" }, { "addiu", 8, 0, 10 },
		{ "label", "L1" },
		{ "bne", 5, 4, "L2" }, { "addiu", 9, 0, 20 },
		{ "label", "L2" },
		{ "blez", 4, "L3" }, { "addiu", 10, 0, 30 },
		{ "label", "L3" },
		{ "bgtz", 5, "L4" }, { "addiu", 11, 0, 40 },
		{ "label", "L4" },
		{ "bltz", 7, "L5" }, { "addiu", 12, 0, 50 },
		{ "label", "L5" },
		{ "bgez", 4, "L6" }, { "addiu", 13, 0, 60 },
		{ "label", "L6" },
		{ "bltzal", 7, "L7" }, { "addiu", 14, 0, 70 },
		{ "label", "L7" },
		{ "bgezal", 4, "L8" }, { "addiu", 15, 0, 80 },
		{ "label", "L8" },
		{ "beq", 4, 5, "L9" }, { "addiu", 16, 0, 90 }, -- not taken
		{ "label", "L9" },
	},
}

-- 5: jal and jalr (link to rd); the code jumps back into itself and loops
-- (stopped by the engine cap), so every word executes repeatedly.
PROGRAMS[#PROGRAMS + 1] = {
	name = "jal_jalr",
	regs = {},
	code = {
		{ "lui", 4, 0x8002 },         -- r4 = CODE_BASE (0x80020000)
		{ "ori", 4, 4, 0x0000 },
		{ "jal", "RETURN_HERE_JAL" }, -- link r31
		{ "addiu", 8, 0, 0x99 },      -- delay slot, then jump
		{ "label", "RETURN_HERE_JAL" },
		{ "addiu", 9, 0, 0x11 },
		{ "jalr", 15, 4 },            -- link to r15, jump to CODE_BASE
		{ "addiu", 10, 0, 0x22 },     -- delay slot
		{ "label", "AFTER_LOOP" },    -- never reached (loops at CODE_BASE)
		{ "addiu", 11, 0, 0x33 },
	},
}

-- 5b: jr (unlinked jump-register, funct 0x08).  no jr word ever executed in the corpus, so this program calls a subroutine via jal and returns via jr $ra, with the absolute oracle pinning registers and the link value.
PROGRAMS[#PROGRAMS + 1] = {
	name = "jr_return",
	regs = {},
	code = {
		{ "jal", "SUB" },           -- r31 = addr of BACK; jump to SUB
		{ "sll", 0, 0, 0 },          -- delay slot
		{ "label", "BACK" },
		{ "addiu", 8, 0, 0x41 },     -- runs only after the jr returns
		{ "j", "DONE" },             -- skip the subroutine body
		{ "sll", 0, 0, 0 },
		{ "label", "SUB" },
		{ "addiu", 9, 0, 0x42 },     -- subroutine body
		{ "jr", 31 },                -- return via the jal link (r31)
		{ "sll", 0, 0, 0 },          -- jr delay slot
		{ "label", "DONE" },
		{ "addiu", 10, 0, 0x43 },
		{ "addiu", 11, 0, 0x44 },
	},
	after = function(cpu, ref)
		-- expected: every word once, r8-r11 carry the body markers, r31 holds the jal link (BACK = code_base + 8).
		local expect = {
			{ "r8", cpu.registers[9] or 0, 0x41 },
			{ "r9", cpu.registers[10] or 0, 0x42 },
			{ "r10", cpu.registers[11] or 0, 0x43 },
			{ "r11", cpu.registers[12] or 0, 0x44 },
			{ "r31", cpu.registers[32] or 0, CODE_BASE + 8 },
		}
		for _, row in ipairs(expect) do
			local value = band(row[2], 0xFFFFFFFF)
			if value ~= row[3] then
				return string.format("core %s=%08X expected %08X", row[1], value, row[3])
			end
		end
		local refExpect = {
			{ "r8", ref.registers[9] or 0, 0x41 },
			{ "r9", ref.registers[10] or 0, 0x42 },
			{ "r10", ref.registers[11] or 0, 0x43 },
			{ "r11", ref.registers[12] or 0, 0x44 },
			{ "r31", ref.registers[32] or 0, CODE_BASE + 8 },
		}
		for _, row in ipairs(refExpect) do
			local value = band(row[2], 0xFFFFFFFF)
			if value ~= row[3] then
				return string.format("ref %s=%08X expected %08X", row[1], value, row[3])
			end
		end
		return nil
	end,
}

-- 6: cop0 register access and write masks
PROGRAMS[#PROGRAMS + 1] = {
	name = "cop0_access",
	regs = { { 4, 0xFFFFFFFF }, { 5, 0x0000FF00 }, { 6, 0xDEADBEEF }, { 20, 0x1000002D } },
	code = {
		{ "mtc0", 4, 12 },  -- sr, masked 0xF27FFF3F
		{ "mtc0", 5, 13 },  -- cause, masked 0x00000300
		{ "mtc0", 6, 7 },   -- dcic, masked
		{ "mfc0", 7, 12 },
		{ "mfc0", 8, 13 },
		{ "mfc0", 9, 7 },
		{ "mtc0", 4, 6 },   -- tar: write ignored
		{ "mfc0", 10, 6 },
		{ "mtc0", 4, 8 },   -- badvaddr: write ignored
		{ "mfc0", 11, 8 },
		{ "mtc0", 4, 14 },  -- epc: write ignored
		{ "mfc0", 12, 14 },
		{ "mfc0", 13, 15 }, -- prid
		{ "mtc0", 4, 3 },   -- bpc full write
		{ "mfc0", 14, 3 },
		{ "mtc0", 4, 9 },   -- bdam
		{ "mfc0", 15, 9 },
		{ "mtc0", 4, 11 },  -- bpcm
		{ "mfc0", 16, 11 },
		{ "mtc0", 4, 5 },   -- bda
		{ "mfc0", 17, 5 },
		-- rfe pop with a non-uniform mode stack (0b101101) and cu0 held: an all-ones stack or a cu0-less readback raised identically in all engines, so both passed as "agreed".
		{ "mtc0", 20, 12 },
		{ "rfe" },          -- status mode bits shift
		{ "mfc0", 18, 12 },  -- mfc0 has a 1-cycle load delay; the trailing nop
		{ "sll", 0, 0, 0 },  -- below is where the readback actually lands
	},
	after = function(cpu, ref)
		-- absolute pin: sr 0x1000002D, rfe pops bits 5-2 into bits 3-0 -> 0x1000002B, read back via mfc0 into r18.
		for _, pair in ipairs({ { "core", cpu }, { "ref", ref } }) do
			local which = pair[1]
			local m = pair[2]
			local status = (m.cop0 and m.cop0.status) or 0
			if band(status, 0xFFFFFFFF) ~= 0x1000002B then
				return string.format("%s sr=%08X expected 1000002B after rfe", which, status)
			end
			local r18 = m.registers[19] or 0
			if band(r18, 0xFFFFFFFF) ~= 0x1000002B then
				return string.format("%s r18=%08X expected 1000002B (post-rfe sr readback)", which, r18)
			end
		end
		return nil
	end,
}

-- 7: exceptions (each ends the program at the first raise)
PROGRAMS[#PROGRAMS + 1] = {
	name = "ex_syscall",
	raises = true,
	regs = { { 4, 0xABCDEF01 } },
	code = { { "syscall" } },
}
PROGRAMS[#PROGRAMS + 1] = {
	name = "ex_break",
	raises = true,
	regs = { { 4, 0xABCDEF01 } },
	code = { { "break_" } },
}
PROGRAMS[#PROGRAMS + 1] = {
	name = "ex_adel_loadword",
	raises = true,
	regs = { { 4, DATA_BASE + 1 } },
	code = { { "lw", 8, 4, 0 } }, -- unaligned load -> AdEL
}
PROGRAMS[#PROGRAMS + 1] = {
	name = "ex_adel_halfword",
	raises = true,
	regs = { { 4, DATA_BASE + 1 } },
	code = { { "lh", 8, 4, 0 } },
}
PROGRAMS[#PROGRAMS + 1] = {
	name = "ex_adel_store",
	raises = true,
	regs = { { 4, DATA_BASE + 2 }, { 5, 0x12345678 } },
	code = { { "sw", 5, 4, 0 } }, -- unaligned store -> AdES
}
PROGRAMS[#PROGRAMS + 1] = {
	name = "ex_ri_mfc0_unimpl",
	raises = true,
	regs = {},
	code = { { "mfc0", 8, 0 } }, -- rd 0 is unimplemented -> RI
}
PROGRAMS[#PROGRAMS + 1] = {
	name = "ex_ri_mtc0_prid",
	raises = true,
	regs = { { 4, 1 } },
	code = { { "mtc0", 4, 15 } }, -- prid is read-only -> RI
}

-- 8: loads and stores, unaligned word ops, load-delay hazard
PROGRAMS[#PROGRAMS + 1] = {
	name = "loadstore",
	data = { 0x01020304, 0x05060708, 0x0A0B0C0D, 0x10203040 },
	regs = { { 4, DATA_BASE } },
	code = {
		{ "lw", 5, 4, 0 },    -- 0x01020304
		{ "lw", 6, 4, 4 },    -- 0x05060708
		{ "ori", 5, 5, 0x1 }, -- load-delay hazard: write in the slot discards the load
		{ "addiu", 9, 0, 0 }, -- settle
		{ "lb", 10, 4, 0 },   -- 0x01 sign
		{ "lbu", 11, 4, 3 },  -- 0x04
		{ "lh", 12, 4, 2 },   -- 0x0304 sign -> 0x00000304
		{ "lhu", 13, 4, 2 },  -- 0x0304
		{ "sb", 14, 4, 8 },   -- 0x77 into word 2 byte 0
		{ "sh", 14, 4, 10 },
		{ "sw", 14, 4, 12 },
		{ "lw", 15, 4, 8 },
		{ "lui", 16, 0x1122 },
		{ "ori", 16, 16, 0x3344 },
		{ "swl", 16, 4, 5 },  -- unaligned partial store
		{ "swr", 16, 4, 5 },
		{ "lw", 17, 4, 4 },
		{ "lwl", 18, 4, 5 },  -- unaligned partial load
		{ "lwr", 18, 4, 5 },
		{ "lw", 19, 4, 4 },
		{ "sw", 16, 4, 0 },   -- rewrite and verify
		{ "lw", 20, 4, 0 },
		{ "addiu", 8, 0, 0x77 },
		{ "sb", 8, 4, 1 },    -- byte store mid-word
		{ "lw", 21, 4, 0 },
	},
}

-- 18: self-modifying code.  every other program runs blocks cold, so the write-invalidation lifecycle is dead code here; this one patches word 0 (j patcher -> addiu r12 = 0x77) and jumps back into it, so a stale cache re-runs the old jump and diverges from the reference.
PROGRAMS[#PROGRAMS + 1] = {
	name = "smc_patch",
	regs = {},
	code = {
		{ "label", "WORD0" },
		{ "j", "PATCHER" },        -- pass 1: word 0 is a jump (patched below)
		{ "addiu", 8, 0, 0x11 },   -- delay slot; also runs plain on pass 2
		{ "addiu", 9, 0, 0x22 },   -- pass 2 only
		{ "addiu", 10, 0, 0x33 },  -- pass 2 only
		{ "addiu", 11, 0, 0x44 },  -- pass 2 only
		{ "j", "FAR_END" },        -- pass 2: leave before the patcher region
		{ "sll", 0, 0, 0 },
		{ "label", "PATCHER" },
		{ "lui", 13, 0x8002 },     -- r13 = code_base
		{ "lui", 14, 0x240C },     -- r14 = hi(addiu r12, r0, 0x77)
		{ "ori", 14, 14, 0x0077 }, -- r14 = the patched word
		{ "sw", 14, 13, 0 },       -- write the patch over word 0
		{ "j", "WORD0" },          -- back into the (now stale) block
		{ "sll", 0, 0, 0 },
		{ "label", "FAR_END" },
		{ "sll", 0, 0, 0 },
		{ "sll", 0, 0, 0 },
		{ "sll", 0, 0, 0 },
	},
	after = function(cpu, ref)
		-- r12 is written only by the patched instruction, proving the block was rebuilt; r8-r11 prove the pass-2 tail ran in order.
		local expect = {
			{ 9, 0x11 },  -- r8
			{ 10, 0x22 }, -- r9
			{ 11, 0x33 }, -- r10
			{ 12, 0x44 }, -- r11
			{ 13, 0x77 }, -- r12: only the patched instruction writes this
		}
		for _, pair in ipairs({ { "core", cpu }, { "ref", ref } }) do
			local which = pair[1]
			local m = pair[2]
			for _, row in ipairs(expect) do
				local value = band(m.registers[row[1]] or 0, 0xFFFFFFFF)
				if value ~= row[2] then
					return string.format("%s r%d=%08X expected %08X", which, row[1] - 1, value, row[2])
				end
			end
		end
		return nil
	end,
}

-- 19: interrupt dispatch.  the corpus never asserted an irq line, so dispatch was dead code; this program enables irq 0 in i_mask and arms a mailbox the harness polls after every instruction.  the trailing nop is preempted: epc points at it, cause keeps ip2 with excode 0.
PROGRAMS[#PROGRAMS + 1] = {
	name = "irq_take",
	raises = true,
	regs = { { 4, 0x00400401 } },
	code = {
		{ "mtc0", 4, 12 },         -- sr: iec + master ie (0x400) + bev, kernel
		{ "lui", 5, 0x8003 },      -- mailbox base high (data area)
		{ "ori", 5, 5, 0x8000 },   -- r5 = data_base + 0x8000
		{ "addiu", 6, 0, 1 },      -- i_mask value: enable irq line 0
		{ "addiu", 7, 0, 1 },      -- arm sentinel
		{ "lui", 8, 0x1F80 },      -- interrupt controller base high
		{ "ori", 8, 8, 0x1074 },   -- r8 = 0x1F801074 (i_mask)
		{ "sh", 6, 8, 0 },         -- enable line 0 in i_mask
		{ "sw", 7, 5, 0 },         -- arm: harness asserts the line after this
		{ "sll", 0, 0, 0 },        -- preempted here (epc = this instruction)
	},
	after = function(cpu, ref)
		-- absolute pins: sr 0x00400401 pushes the mode bits up by two (0x01 -> 0x04); epc points at the preempted nop; cause keeps ip2 with excode 0.
		local expectEpc = CODE_BASE + 9 * 4
		for _, pair in ipairs({ { "core", cpu }, { "ref", ref } }) do
			local which = pair[1]
			local m = pair[2]
			local epc = (m.cop0 and m.cop0.epc) or 0
			if band(epc, 0xFFFFFFFF) ~= expectEpc then
				return string.format("%s epc=%08X expected %08X (preempted nop)", which, epc, expectEpc)
			end
			local status = (m.cop0 and m.cop0.status) or 0
			if band(status, 0xFFFFFFFF) ~= 0x00400404 then
				return string.format("%s sr=%08X expected 00400404 after interrupt push", which, status)
			end
			local cause = (m.cop0 and m.cop0.cause) or 0
			if band(cause, 0x7C) ~= 0 or band(cause, 0x400) == 0 then
				return string.format("%s cause=%08X expected ip2 set, excode 0", which, cause)
			end
		end
		return nil
	end,
}

-- 20: the interrupt gate.  the line goes high while iec is clear, so the pending instruction still runs (r10 = 0x55) and cause keeps ip2; enabling iec dispatches at the next boundary.
PROGRAMS[#PROGRAMS + 1] = {
	name = "irq_gate",
	raises = true,
	regs = { { 4, 0x00400401 }, { 9, 0x00400400 } },
	code = {
		{ "mtc0", 9, 12 },         -- sr: master ie, no iec (gate closed)
		{ "lui", 5, 0x8003 },      -- mailbox base high (data area)
		{ "ori", 5, 5, 0x8000 },   -- r5 = data_base + 0x8000
		{ "addiu", 6, 0, 1 },      -- i_mask value: enable irq line 0
		{ "addiu", 7, 0, 1 },      -- arm sentinel
		{ "lui", 8, 0x1F80 },      -- interrupt controller base high
		{ "ori", 8, 8, 0x1074 },   -- r8 = 0x1F801074 (i_mask)
		{ "sh", 6, 8, 0 },         -- enable line 0 in i_mask
		{ "sw", 7, 5, 0 },         -- arm: line asserts after this instruction
		{ "addiu", 10, 0, 0x55 },  -- runs despite the pending line (iec off)
		{ "mtc0", 4, 12 },         -- sr: iec on, gate opens
		{ "sll", 0, 0, 0 },        -- preempted here (epc = this instruction)
	},
	after = function(cpu, ref)
		local expectEpc = CODE_BASE + 11 * 4
		for _, pair in ipairs({ { "core", cpu }, { "ref", ref } }) do
			local which = pair[1]
			local m = pair[2]
			local r10 = m.registers[11] or 0
			if band(r10, 0xFFFFFFFF) ~= 0x55 then
				return string.format("%s r10=%08X expected 00000055 (gated instruction ran)", which, r10)
			end
			local epc = (m.cop0 and m.cop0.epc) or 0
			if band(epc, 0xFFFFFFFF) ~= expectEpc then
				return string.format("%s epc=%08X expected %08X (nop after gate opened)", which, epc, expectEpc)
			end
			local status = (m.cop0 and m.cop0.status) or 0
			if band(status, 0xFFFFFFFF) ~= 0x00400404 then
				return string.format("%s sr=%08X expected 00400404 after interrupt push", which, status)
			end
			local cause = (m.cop0 and m.cop0.cause) or 0
			if band(cause, 0x7C) ~= 0 or band(cause, 0x400) == 0 then
				return string.format("%s cause=%08X expected ip2 set, excode 0", which, cause)
			end
		end
		return nil
	end,
}

-- ---------------------------------------------------------------------------
-- runner: every program runs twice -- once per core engine (stepBaseline, then the block-cache
-- interpreter) -- each against a fresh reference over a fresh shim.  the reference steps one
-- instruction per core instruction, driven by the per-instruction diffhook in block mode.

local function writeData(shim, base, values)
	for index, value in ipairs(values) do
		shim:write32(base + (index - 1) * 4, value)
	end
end

local function seedProgram(cpu, ref, prog)
	for _, seed in ipairs(prog.regs or {}) do
		seedRegister(cpu, ref, seed[1], seed[2])
	end
end

-- interrupt delivery: the harness plays the device -- a program stores a sentinel to a mailbox word, and right after that instruction the harness asserts irq line 0, so the interrupt dispatches at the following instruction boundary.  the poll must translate the mailbox address kseg0 -> phys like write32 does.
local IRQ_MAILBOX_PHYS = band(DATA_BASE, 0x1FFFFFFF) + 0x8000
local IRQ_MAILBOX_IDX = IRQ_MAILBOX_PHYS // 4 + 1
local IRQ_ARM_SENTINEL = 0x1
local function pollIrqRequest(shim)
	if shim.iStat == 0 and (shim.ram32[IRQ_MAILBOX_IDX] or 0) == IRQ_ARM_SENTINEL then
		shim.iStat = 1
		local p = band(shim.iStat, shim.iMask)
		shim._irqState = (p ~= 0) and bor(p, 0x80000000) or band(shim._irqState or 0, 0x80000000)
		shim.ram32[IRQ_MAILBOX_IDX] = 0
	end
end

-- runs one engine over the program; returns (true, steps) or (false) with
-- the failure already printed.
local function runEngine(prog, words, useBlocks)
	local tag = useBlocks and "block" or "baseline"
	local shim = newShim()
	local codeEnd = CODE_BASE + (#words + 1) * 4
	writeData(shim, DATA_BASE, prog.data or {})
	for index, word in ipairs(words) do
		shim:write32(CODE_BASE + (index - 1) * 4, word)
	end

	local cpu = CPU.new(shim)
	cpu:reset(CODE_BASE)
	cpu.useBlocks = useBlocks
	local ref = CPURef.new()
	ref.pc = CODE_BASE
	-- mirror the core's reset pre-state: t1 seeds the mmio base 0x1f801000 (ps1 boot convention), which the ref model doesn't assume.
	ref.registers[10] = 0x1F801000
	seedProgram(cpu, ref, prog)

	local function inWindow(pc)
		return pc >= CODE_BASE and pc < codeEnd
	end

	local steps = 0
	if useBlocks then
		-- block engine: one step runs a whole block, so the reference steps inside the per-instruction diffhook; the engine runs to its natural end or an instruction cap.
		local failure = nil
		local hooks = 0
		cpu._diffHook = function(self, pc)
			hooks += 1
			if failure then
				return
			end
			local word = shim:read32(pc)
			local pendingIrq = band(shim.iStat, shim.iMask)
			-- the core ran this cell before the hook fired: drain its writes since the previous cell (the log stays open across the block run), then step the ref on the same word and compare stores.
			local coreRows = shim._writeLog or {}
			shim._writeLog = nil
			local refRows = captureWrites(shim, function() ref:step(word, shim, pendingIrq) end)
			local diff = compareState(cpu, ref)
			if not diff then
				diff = compareWrites(refRows, coreRows)
			end
			if diff then
				failure = string.format(
					"DIFF %s [%s] pc=%08X ins=%08X: %s",
					prog.name, tag, pc, word, diff
				)
			end
			pollIrqRequest(shim)
			-- reopen the log so the core's remaining cells in this block log
			-- their stores for the next hook to drain
			shim._writeLog = {}
		end
		local cap = #words * 4
		local guard = 0
		shim._writeLog = {}
		while not failure and inWindow(cpu.pc) and (cpu.instructionCount or 0) < cap do
			cpu:step()
			guard += 1
			if guard > 100000 then
				failure = string.format(
					"RUNWAY %s [%s]: did not terminate after %d block steps (pc=%08X)",
					prog.name, tag, guard, cpu.pc or 0
				)
			end
		end
		cpu._diffHook = nil
		if failure then
			print(failure)
			return false
		end
		steps = cpu.instructionCount or 0
		if hooks ~= steps then
			print(string.format(
				"HOOKMISMATCH %s [%s]: diffHook fired %d times for %d executed instructions",
				prog.name, tag, hooks, steps
			))
			return false
		end
	else
		-- baseline: one step per instruction; the ref runs first on pristine memory, then the core (identical writes, so order doesn't change shared state).
		while steps < #words and inWindow(cpu.pc) do
			local pc = cpu.pc
			local word = shim:read32(pc)
			local pendingIrq = band(shim.iStat, shim.iMask)
			-- one store log per side per instruction; the stores must agree byte for byte (the shared bytes can't be the comparison).
			local refRows = captureWrites(shim, function() ref:step(word, shim, pendingIrq) end)
			local coreRows = captureWrites(shim, function() cpu:step() end)
			local diff = compareState(cpu, ref)
			if not diff then
				diff = compareWrites(refRows, coreRows)
			end
			if diff then
				print(string.format(
					"DIFF %s [%s] step %d pc=%08X ins=%08X: %s",
					prog.name, tag, steps, pc, word, diff
				))
				return false
			end
			steps += 1
			pollIrqRequest(shim)
		end
	end

	-- completion invariants: the per-instruction comparison only sees instructions that actually ran, so a control-flow defect that exits the window early would report a silent pass -- a raising program must end at the exception vector, outside the code window.  fuzz streams opt out (random code raises legitimately).
	if prog.noCompletion then
		-- skip the invariants below
	elseif prog.raises then
		if inWindow(cpu.pc) then
			print(string.format(
				"UNDERRAN %s [%s]: raising program fell through without raising (pc=%08X)",
				prog.name, tag, cpu.pc or 0
			))
			return false
		end
	elseif steps < #words and (not useBlocks or not inWindow(cpu.pc)) then
		-- non-raising programs must execute every word; an under-run is a failure either way (baseline stops one word past the code, the block engine when pc leaves the window or hits the cap).
		print(string.format(
			"UNDERRAN %s [%s]: %s after %d of %d %s (pc=%08X)",
			prog.name,
			tag,
			useBlocks and "left the code window" or "ended early",
			steps,
			#words,				useBlocks and "instructions" or "steps",
				cpu.pc or 0
			))
			return false
		end
	-- absolute oracle: a bug implemented identically in all three engines is invisible to the differential, so a program may declare after(cpu, ref) to pin concrete final values per engine.
	if prog.after then
		local problem = prog.after(cpu, ref)
		if problem then
			print(string.format("AFTER %s [%s]: %s", prog.name, tag, problem))
			return false
		end
	end
	return true, steps
end

local function runProgram(prog, verbose)
	local words = assemble(prog.code, CODE_BASE)
	local baselineOk, baselineSteps = runEngine(prog, words, false)
	if not baselineOk then
		return false
	end
	local blockOk, blockSteps = runEngine(prog, words, true)
	if not blockOk then
		return false
	end
	if verbose then
		print(string.format(
			"ok   %s (baseline %d, block %d of %d words)",
			prog.name, baselineSteps, blockSteps, #words
		))
	else
		print(string.format("ok   %s", prog.name))
	end
	return true
end

-- ---------------------------------------------------------------------------
-- decoder fuzz.  the corpus only executes words the assembler can emit, so any other word (a
-- reserved funct, an undocumented cop0 rs, a regimm combination) is invisible to it.  two
-- deterministic sweeps run every generated word through all three engines:
--   * structured: exhaustive over the small decode fields (all special functs 0-63, regimm rt
--     0-31, cop0 rs 0-31, cop1/2/3 sub-ops) with pseudo-random operands;
--   * random: uniform random word streams, so multi-instruction interactions count too.
-- streams opt out of the completion invariants (random code raises legitimately); the step bound
-- and per-instruction comparison are the gate.

local FUZZ_RANDOM_STREAMS = 150
local FUZZ_WORDS = 48

local newFuzzRng = require("./lib/xorshift")

local function runFuzz(verbose)
	local rng = newFuzzRng(0xC0FFEE)
	local streams = {}
	local function add(name, words)
		streams[#streams + 1] = { name = name, words = words }
	end

	-- structured: exhaust the small decode fields one word at a time
	for funct = 0, 63 do
		add(string.format("fz_special_%02X", funct), {
			rtype(funct, rng() % 32, rng() % 32, rng() % 32, rng() % 32),
		})
	end
	for rt = 0, 31 do
		add(string.format("fz_regimm_%02X", rt), {
			itype(0x01, rng() % 32, rt, rng() % 0x10000),
		})
	end
	-- cop0: mfc0/mtc0 sweep the register field (unimplemented registers raise ri); rs=0x10 sweeps all 64 funct lanes; every other rs gets one word.
	for rd = 0, 31 do
		add(string.format("fz_mfc0_rd%02X", rd), { itype(0x10, 0x00, rng() % 32, rd * 0x800) })
		add(string.format("fz_mtc0_rd%02X", rd), { itype(0x10, 0x04, rng() % 32, rd * 0x800) })
	end
	for funct = 0, 63 do
		add(string.format("fz_cop0_f%02X", funct), { bor(itype(0x10, 0x10, rng() % 32, 0), funct) })
	end
	for rs = 0, 31 do
		if rs ~= 0x00 and rs ~= 0x04 and rs ~= 0x10 then
			add(string.format("fz_cop0_%02X", rs), { itype(0x10, rs, rng() % 32, rng() % 0x10000) })
		end
	end
	for _, op in ipairs({ 0x11, 0x12, 0x13 }) do
		for rs = 0, 31, 3 do
			add(string.format("fz_cop%X_%02X", op - 0x10, rs), {
				itype(op, rs, rng() % 32, rng() % 0x10000),
			})
		end
	end

	-- random: uniform words in longer streams
	for s = 1, FUZZ_RANDOM_STREAMS do
		local words = {}
		for i = 1, FUZZ_WORDS do
			words[i] = rng()
		end
		add(string.format("fz_rand_%03d", s), words)
	end

	local total = 0
	for _, stream in ipairs(streams) do
		local prog = { name = stream.name, noCompletion = true }
		local baselineOk, baselineSteps = runEngine(prog, stream.words, false)
		if not baselineOk then
			print(string.format("FUZZ FAIL: stream %s under the baseline engine", stream.name))
			return false
		end
		total += baselineSteps or 0
		local blockOk, blockSteps = runEngine(prog, stream.words, true)
		if not blockOk then
			print(string.format("FUZZ FAIL: stream %s under the block engine", stream.name))
			return false
		end
		total += blockSteps or 0
	end
	print(string.format(
		"FUZZ PASS: %d streams (%d executed instructions compared)",
		#streams, total
	))
	return true
end

local verbose = false
local ok = true
-- the encoding self-test runs first: the differential can't see a shared mis-encoding, so an encoding regression must fail before the corpus starts.
if runSelfTest() then
	for _, prog in ipairs(PROGRAMS) do
		if not runProgram(prog, verbose) then
			ok = false
			break
		end
	end
else
	ok = false
end

local fuzzOk = runFuzz(verbose)
if ok and fuzzOk then
	print(string.format("CPU_DIFF PASS: %d programs in agreement", #PROGRAMS))
else
	print("CPU_DIFF FAIL")
end

require("@lune/process").exit(ok and fuzzOk and 0 or 1)
