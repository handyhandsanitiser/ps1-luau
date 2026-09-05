-- mips disassembly helpers for the command-line tools.
local Disasm = {}

local REG_NAMES = { "zero", "at", "v0", "v1", "a0", "a1", "a2", "a3", "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "t8", "t9", "k0", "k1", "gp", "sp", "fp", "ra" }

local function signed16(value)
	value = bit32.band(value, 0xFFFF)
	if value >= 0x8000 then return value - 0x10000 end
	return value
end

local FUNCT_NAMES = {
	[0x00] = "sll", [0x02] = "srl", [0x03] = "sra", [0x04] = "sllv", [0x06] = "srlv", [0x07] = "srav",
	[0x08] = "jr", [0x09] = "jalr", [0x0C] = "syscall", [0x0D] = "break",
	[0x10] = "mfhi", [0x11] = "mthi", [0x12] = "mflo", [0x13] = "mtlo",
	[0x18] = "mult", [0x19] = "multu", [0x1A] = "div", [0x1B] = "divu",
	[0x20] = "add", [0x21] = "addu", [0x22] = "sub", [0x23] = "subu",
	[0x24] = "and", [0x25] = "or", [0x26] = "xor", [0x27] = "nor",
	[0x2A] = "slt", [0x2B] = "sltu",
}

-- disassemble one mips instruction.
function Disasm.disassemble(word, address)
	local opcode = bit32.band(bit32.rshift(word, 26), 0x3F)
	local rs = bit32.band(bit32.rshift(word, 21), 0x1F)
	local rt = bit32.band(bit32.rshift(word, 16), 0x1F)
	local rd = bit32.band(bit32.rshift(word, 11), 0x1F)
	local funct = bit32.band(word, 0x3F)
	local imm = signed16(word)
	local target = bit32.band(address + 4 + (imm * 4), 0xFFFFFFFF)
	local fmt
	if opcode == 0x00 then
		local functName = FUNCT_NAMES[funct]
		if funct == 0x08 then
			fmt = string.format("jr %s", REG_NAMES[rs + 1])
		elseif funct == 0x09 then
			fmt = string.format("jalr %s, %s", REG_NAMES[rd + 1], REG_NAMES[rs + 1])
		elseif funct == 0x0C then
			fmt = string.format("syscall %d", bit32.band(word, 0xFFFFF))
		elseif funct == 0x0D then
			fmt = string.format("break %d", bit32.band(word, 0xFFFFF))
		elseif funct == 0x00 or funct == 0x02 or funct == 0x03 then
			fmt = string.format("%s %s, %s, %d", functName, REG_NAMES[rd + 1], REG_NAMES[rt + 1], bit32.band(bit32.rshift(word, 6), 0x1F))
		elseif funct == 0x04 or funct == 0x06 or funct == 0x07 then
			fmt = string.format("%s %s, %s, %s", functName, REG_NAMES[rd + 1], REG_NAMES[rt + 1], REG_NAMES[rs + 1])
		elseif funct == 0x18 or funct == 0x19 or funct == 0x1A or funct == 0x1B then
			fmt = string.format("%s %s, %s", functName, REG_NAMES[rs + 1], REG_NAMES[rt + 1])
		elseif funct == 0x10 or funct == 0x12 then
			fmt = string.format("%s %s", functName, REG_NAMES[rd + 1])
		elseif funct == 0x11 or funct == 0x13 then
			fmt = string.format("%s %s", functName, REG_NAMES[rs + 1])
		elseif functName then
			fmt = string.format("%s %s, %s, %s", functName, REG_NAMES[rd + 1], REG_NAMES[rs + 1], REG_NAMES[rt + 1])
		else
			fmt = string.format("??? funct=%02X", funct)
		end
	elseif opcode == 0x01 then
		local rName = ({ [0x00] = "bltz", [0x01] = "bgez", [0x10] = "bltzal", [0x11] = "bgezal" })[rt]
		if rName then fmt = string.format("%s %s, %08X", rName, REG_NAMES[rs + 1], target) else fmt = string.format("bcond ? rt=%d", rt) end
	elseif opcode == 0x02 then
		fmt = string.format("j %08X", bit32.band(bit32.band(word, 0x3FFFFFF) * 4, 0x0FFFFFFF) + bit32.band(address, 0xF0000000))
	elseif opcode == 0x03 then
		fmt = string.format("jal %08X", bit32.band(bit32.band(word, 0x3FFFFFF) * 4, 0x0FFFFFFF) + bit32.band(address, 0xF0000000))
	elseif opcode == 0x04 then
		fmt = string.format("beq %s, %s, %08X", REG_NAMES[rs + 1], REG_NAMES[rt + 1], target)
	elseif opcode == 0x05 then
		fmt = string.format("bne %s, %s, %08X", REG_NAMES[rs + 1], REG_NAMES[rt + 1], target)
	elseif opcode == 0x06 then
		fmt = string.format("blez %s, %08X", REG_NAMES[rs + 1], target)
	elseif opcode == 0x07 then
		fmt = string.format("bgtz %s, %08X", REG_NAMES[rs + 1], target)
	elseif opcode == 0x08 then
		fmt = string.format("addi %s, %s, %d", REG_NAMES[rt + 1], REG_NAMES[rs + 1], imm)
	elseif opcode == 0x09 then
		fmt = string.format("addiu %s, %s, %d", REG_NAMES[rt + 1], REG_NAMES[rs + 1], imm)
	elseif opcode == 0x0A then
		fmt = string.format("slti %s, %s, %d", REG_NAMES[rt + 1], REG_NAMES[rs + 1], imm)
	elseif opcode == 0x0B then
		fmt = string.format("sltiu %s, %s, %d", REG_NAMES[rt + 1], REG_NAMES[rs + 1], imm)
	elseif opcode == 0x0C then
		fmt = string.format("andi %s, %s, %04X", REG_NAMES[rt + 1], REG_NAMES[rs + 1], bit32.band(word, 0xFFFF))
	elseif opcode == 0x0D then
		fmt = string.format("ori %s, %s, %04X", REG_NAMES[rt + 1], REG_NAMES[rs + 1], bit32.band(word, 0xFFFF))
	elseif opcode == 0x0E then
		fmt = string.format("xori %s, %s, %04X", REG_NAMES[rt + 1], REG_NAMES[rs + 1], bit32.band(word, 0xFFFF))
	elseif opcode == 0x0F then
		fmt = string.format("lui %s, %04X", REG_NAMES[rt + 1], bit32.band(word, 0xFFFF))
	elseif opcode == 0x20 then
		fmt = string.format("lb %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x21 then
		fmt = string.format("lh %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x22 then
		fmt = string.format("lwl %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x23 then
		fmt = string.format("lw %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x24 then
		fmt = string.format("lbu %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x25 then
		fmt = string.format("lhu %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x26 then
		fmt = string.format("lwr %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x28 then
		fmt = string.format("sb %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x29 then
		fmt = string.format("sh %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x2A then
		fmt = string.format("swl %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x2B then
		fmt = string.format("sw %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x2E then
		fmt = string.format("swr %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x30 then
		fmt = string.format("lwc0 %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x31 then
		fmt = string.format("lwc1 %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x32 then
		fmt = string.format("lwc2 %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x38 then
		fmt = string.format("swc0 %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x39 then
		fmt = string.format("swc1 %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	elseif opcode == 0x3B then
		fmt = string.format("swc2 %s, %d(%s)", REG_NAMES[rt + 1], imm, REG_NAMES[rs + 1])
	else
		fmt = string.format("??? opcode=%02X", opcode)
	end
	return fmt
end

-- disassemble `count` words starting at `address`.
function Disasm.disasmRegion(u32, address, count)
	local out = {}
	for i = 0, count - 1 do
		local a = address + i * 4
		out[#out + 1] = string.format("%08X: %08X  %s", a, u32(a), Disasm.disassemble(u32(a), a))
	end
	return out
end

local callable = setmetatable({}, {
	__index = Disasm,
	__call = function(_, word, address) return Disasm.disassemble(word, address) end,
})
return callable
