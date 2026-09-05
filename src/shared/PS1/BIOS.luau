local Util = require(script.Parent.Util)

local BIOS = {}
BIOS.__index = BIOS

local band = bit32.band

local function parseDecimal(text, startIndex)
	local index = startIndex
	while index <= #text and text:sub(index, index):match("%d") do
		index += 1
	end

	if index == startIndex then
		return nil, startIndex
	end

	return tonumber(text:sub(startIndex, index - 1)), index
end

local function parsePrintfSpecifier(formatString, percentIndex)
	local index = percentIndex + 1
	local flags = {
		leftJustify = false,
		zeroPad = false,
	}
	local unsupportedDynamicWidth = false
	local unsupportedDynamicPrecision = false

	while index <= #formatString do
		local character = formatString:sub(index, index)
		if character == "-" then
			flags.leftJustify = true
		elseif character == "0" then
			flags.zeroPad = true
		elseif character == "+" or character == " " or character == "#" then
			-- accepted but currently ignored.
		else
			break
		end
		index += 1
	end

	local width = nil
	if formatString:sub(index, index) == "*" then
		unsupportedDynamicWidth = true
		index += 1
	else
		width, index = parseDecimal(formatString, index)
	end

	if (formatString:sub(index, index) == "-" or formatString:sub(index, index) == "0") and width ~= nil then
		while index <= #formatString do
			local lateFlag = formatString:sub(index, index)
			if lateFlag == "-" then
				flags.leftJustify = true
			elseif lateFlag == "0" then
				flags.zeroPad = true
			else
				break
			end
			index += 1
		end
	end

	local precision = nil
	if formatString:sub(index, index) == "." then
		index += 1
		if formatString:sub(index, index) == "*" then
			unsupportedDynamicPrecision = true
			index += 1
		else
			precision, index = parseDecimal(formatString, index)
			if precision == nil then
				precision = 0
			end
		end
	end

	while index <= #formatString do
		local lengthModifier = formatString:sub(index, index)
		if lengthModifier == "h" or lengthModifier == "l" or lengthModifier == "L" or lengthModifier == "z" or lengthModifier == "t" or lengthModifier == "j" then
			index += 1
		else
			break
		end
	end

	local specifier = formatString:sub(index, index)
	if specifier == "" then
		return nil
	end

	return {
		raw = formatString:sub(percentIndex, index),
		specifier = specifier,
		flags = flags,
		width = width,
		precision = precision,
		nextCursor = index + 1,
		unsupportedDynamicWidth = unsupportedDynamicWidth,
		unsupportedDynamicPrecision = unsupportedDynamicPrecision,
	}
end

local function applyPrecision(text, precision)
	if precision == nil or #text >= precision then
		return text
	end
	return string.rep("0", precision - #text) .. text
end

local function applyWidth(text, flags, width, allowZeroPad)
	if not width or #text >= width then
		return text
	end

	local padCount = width - #text
	if flags.leftJustify then
		return text .. string.rep(" ", padCount)
	end

	local padCharacter = (flags.zeroPad and allowZeroPad) and "0" or " "
	if padCharacter == "0" and text:sub(1, 1) == "-" then
		return "-" .. string.rep("0", padCount) .. text:sub(2)
	end

	return string.rep(padCharacter, padCount) .. text
end

local function formatUnsigned(value, base, uppercase)
	value = band(value, 0xFFFFFFFF)
	if value == 0 then
		return "0"
	end

	local digits = uppercase and "0123456789ABCDEF" or "0123456789abcdef"
	local output = {}
	while value > 0 do
		local digit = (value % base) + 1
		output[#output + 1] = digits:sub(digit, digit)
		value = math.floor(value / base)
	end

	for left = 1, math.floor(#output / 2) do
		local right = #output - left + 1
		output[left], output[right] = output[right], output[left]
	end

	return table.concat(output)
end

local function formatSignedDecimal(value)
	return tostring(Util.toSigned32(value))
end

local function formatUnsignedDecimal(value)
	return tostring(band(value, 0xFFFFFFFF))
end

BIOS.DefaultStackPointer = 0x801FFF00

local function sanitizeStackPointer(value, fallback)
	value = band(value or 0, 0xFFFFFFFF)
	fallback = band(fallback or BIOS.DefaultStackPointer, 0xFFFFFFFF)

	local inKseg0Ram = value >= 0x80000000 and value < 0x80200000
	local inKseg1Ram = value >= 0xA0000000 and value < 0xA0200000
	if not inKseg0Ram and not inKseg1Ram then
		value = fallback
	end

	return band(value, 0xFFFFFFFC)
end

function BIOS.new(options)
	local self = setmetatable({}, BIOS)
	self.log = options and options.log or print
	self.traceBios = options and options.traceBios == true or false
	self.defaultStackPointer = options and options.defaultStackPointer or BIOS.DefaultStackPointer
	self.consoleBuffer = ""
	self.gatewayCallCounts = {
		bios = {},
		hle = {},
	}
	self.changeClearPad = 0
	self.changeClearRootCounter = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
	self.entryInterruptHook = 0
	return self
end

function BIOS:recordGatewayCall(vectorName, functionNumber, biosMode)
	local modeKey = biosMode and "bios" or "hle"
	local counts = self.gatewayCallCounts[modeKey]
	local gatewayKey = string.format("%s:%02X", tostring(vectorName), band(functionNumber or 0, 0xFF))
	counts[gatewayKey] = (counts[gatewayKey] or 0) + 1
end

function BIOS:dumpState()
	return {
		changeClearPad = self.changeClearPad,
		changeClearRootCounter = self.changeClearRootCounter,
		entryInterruptHook = self.entryInterruptHook,
		gatewayCallCounts = self.gatewayCallCounts,
	}
end

function BIOS:normalizeStackPointer(header)
	local stackBase = header and header.stackBase or 0
	local stackOffset = header and header.stackOffset or 0
	local fallback = band(self.defaultStackPointer or BIOS.DefaultStackPointer, 0xFFFFFFFF)
	if stackBase == 0 then
		return sanitizeStackPointer(fallback + stackOffset, fallback)
	end
	return sanitizeStackPointer(stackBase + stackOffset, fallback)
end

function BIOS:buildInitialRegisters(header)
	local stackPointer = self:normalizeStackPointer(header)

	return {
		pc = header.entryPoint or 0,
		gp = header.initialGp or 0,
		sp = stackPointer,
		fp = stackPointer,
		a0 = 1,
		a1 = 0,
		a2 = 0,
		a3 = 0,
	}
end

function BIOS:logString(text)
	if self.traceBios then
		print(string.format("[ps1-hle] enter logString text=%s", tostring(text)))
	end
	self.log(text)
end

function BIOS:writeConsoleCharacter(characterCode)
	if self.traceBios then
		print(string.format("[ps1-hle] enter writeConsoleCharacter char=%d", band(characterCode, 0xFF)))
	end
	characterCode = band(characterCode, 0xFF)
	self.consoleBuffer = self.consoleBuffer .. string.char(characterCode)

	while true do
		local newlineIndex = self.consoleBuffer:find("\n", 1, true)
		if not newlineIndex then
			break
		end

		local line = self.consoleBuffer:sub(1, newlineIndex - 1)
		self.log(line)
		self.consoleBuffer = self.consoleBuffer:sub(newlineIndex + 1)
	end
end

function BIOS:flushConsole()
	if self.traceBios then
		print(string.format("[ps1-hle] enter flushConsole buffer_len=%d", #self.consoleBuffer))
	end
	if self.consoleBuffer ~= "" then
		self.log(self.consoleBuffer)
		self.consoleBuffer = ""
	end
end

function BIOS:readCString(memory, address)
	if self.traceBios then
		print(string.format("[ps1-hle] enter readCString address=%08X", address or 0))
	end
	local characters = {}
	local count = 0

	while count < 0x1000 do
		local byte = memory:read8(address)
		if byte == 0 then
			break
		end

		characters[#characters + 1] = string.char(byte)
		address += 1
		count += 1
	end

	return table.concat(characters)
end

function BIOS:readPrintfStackArgument(cpu, memory, argumentIndex)
	if self.traceBios then
		print(string.format("[ps1-hle] enter readPrintfStackArgument argument=%d", argumentIndex))
	end
	if argumentIndex <= 3 then
		local registerIndex = argumentIndex + 4
		if self.traceBios then
			print(string.format("[ps1-hle] printf arg %d from r%d", argumentIndex, registerIndex))
		end
		return cpu:getRegister(registerIndex)
	end

	local stackPointer = cpu:getRegister(29)
	local stackOffset = 0x10 + ((argumentIndex - 4) * 4)
	if self.traceBios then
		print(string.format("[ps1-hle] printf arg %d from stack+%02X", argumentIndex, stackOffset))
	end
	return memory:read32(stackPointer + stackOffset)
end

function BIOS:formatPrintf(memory, cpu, formatAddress)
	if self.traceBios then
		print(string.format("[ps1-hle] enter formatPrintf format=%08X", formatAddress or 0))
	end
	local formatString = self:readCString(memory, formatAddress)
	local output = {}
	local argumentIndex = 1
	local cursor = 1
	local outputLength = 0

	local function appendText(text)
		output[#output + 1] = text
		outputLength += #text
	end

	local function warnUnsupported(spec, reason)
		warn(string.format("[ps1-hle] unsupported printf specifier '%s' (%s)", spec.raw, reason))
	end

	local function formatValue(spec, value)
		if spec.unsupportedDynamicWidth or spec.unsupportedDynamicPrecision then
			warnUnsupported(spec, "dynamic width/precision")
			return tostring(value)
		end

		if spec.specifier == "s" then
			local text = type(value) == "number" and self:readCString(memory, value) or tostring(value)
			if spec.precision ~= nil then
				text = text:sub(1, spec.precision)
			end
			return applyWidth(text, spec.flags, spec.width, false)
		elseif spec.specifier == "c" then
			local text = string.char(band(value, 0xFF))
			return applyWidth(text, spec.flags, spec.width, false)
		elseif spec.specifier == "d" or spec.specifier == "i" then
			local numeric = formatSignedDecimal(value)
			local negative = numeric:sub(1, 1) == "-"
			local digits = negative and numeric:sub(2) or numeric
			digits = applyPrecision(digits, spec.precision)
			if spec.precision == 0 and digits == "0" then
				digits = ""
			end
			local text = negative and ("-" .. digits) or digits
			return applyWidth(text, spec.flags, spec.width, spec.precision == nil)
		elseif spec.specifier == "u" then
			local text = formatUnsignedDecimal(value)
			text = applyPrecision(text, spec.precision)
			if spec.precision == 0 and text == "0" then
				text = ""
			end
			return applyWidth(text, spec.flags, spec.width, spec.precision == nil)
		elseif spec.specifier == "x" or spec.specifier == "X" then
			local text = formatUnsigned(value, 16, spec.specifier == "X")
			text = applyPrecision(text, spec.precision)
			if spec.precision == 0 and text == "0" then
				text = ""
			end
			return applyWidth(text, spec.flags, spec.width, spec.precision == nil)
		elseif spec.specifier == "o" then
			local text = formatUnsigned(value, 8, false)
			text = applyPrecision(text, spec.precision)
			if spec.precision == 0 and text == "0" then
				text = ""
			end
			return applyWidth(text, spec.flags, spec.width, spec.precision == nil)
		end

		warnUnsupported(spec, "conversion not implemented")
		return tostring(value)
	end

	while cursor <= #formatString do
		local character = formatString:sub(cursor, cursor)
		if character ~= "%" then
			appendText(character)
			cursor += 1
		else
			local nextCharacter = formatString:sub(cursor + 1, cursor + 1)
			if nextCharacter == "" then
				appendText("%")
				cursor += 1
			elseif nextCharacter == "%" then
				appendText("%")
				cursor += 2
			else
				local spec = parsePrintfSpecifier(formatString, cursor)
				if not spec then
					appendText(formatString:sub(cursor))
					break
				end

				local specifier = spec.specifier
				local value = self:readPrintfStackArgument(cpu, memory, argumentIndex)
				argumentIndex += 1

				if specifier == "n" then
					if type(value) == "number" then
						memory:write32(value, outputLength)
					end
				else
					appendText(formatValue(spec, value))
				end

				cursor = spec.nextCursor
			end
		end
	end

	return table.concat(output)
end

function BIOS:dispatchGateway(vectorName, functionNumber, cpu, memory, biosMode)
	if self.traceBios then
		print(string.format("[ps1-hle] enter dispatchGateway vector=%s fn=%02X pc=%08X biosMode=%s", tostring(vectorName), functionNumber or 0, cpu.pc or 0, tostring(biosMode == true)))
	end
	self:recordGatewayCall(vectorName, functionNumber, biosMode)
	local function unsupported()
		if self.traceBios then
			warn(string.format("[ps1-hle] unsupported bios gateway vector=%s fn=%02X pc=%08X", tostring(vectorName), functionNumber or 0, cpu.pc or 0))
		end
		-- hle-only mode must preserve call/return flow for unimplemented functions, or execution falls through unmapped gateway addresses.
		local fallbackReturn = cpu:getRegister(31)
		cpu:setRegister(2, 0)
		cpu.pc = fallbackReturn
		cpu.nextPc = band(fallbackReturn + 4, 0xFFFFFFFF)
		cpu.pendingBranch = nil
		cpu.pendingLoad = nil
		cpu.inDelaySlot = false
		return true
	end
	local upperVector = string.upper(vectorName)
	local returnAddress = cpu:getRegister(31)
	local result = 0

	-- with a real bios rom, only intercept console output so the rom handles all calls consistently (mixing partial hle with rom gateway code desyncs bios state).
	if biosMode then
		return false -- always let real BIOS ROM handle gateways when loaded
	end

	if upperVector == "A" or upperVector == "B" then
		if functionNumber == 0x3C and upperVector == "A" then
			self:writeConsoleCharacter(cpu:getRegister(4))
			result = 1
		elseif functionNumber == 0x13 and upperVector == "A" then
			local bufferAddress = cpu:getRegister(4)
			memory:write32(bufferAddress + 0x00, cpu:getRegister(31))
			memory:write32(bufferAddress + 0x04, cpu:getRegister(29))
			memory:write32(bufferAddress + 0x08, cpu:getRegister(30))
			for offset = 0, 7 do
				memory:write32(bufferAddress + 0x0C + (offset * 4), cpu:getRegister(16 + offset))
			end
			memory:write32(bufferAddress + 0x2C, cpu:getRegister(28))
			result = 0
		elseif functionNumber == 0x3D and upperVector == "B" then
			self:writeConsoleCharacter(cpu:getRegister(4))
			result = 1
		elseif functionNumber == 0x3E and upperVector == "A" then
			self:flushConsole()
			self:logString(self:readCString(memory, cpu:getRegister(4)))
			result = cpu:getRegister(4)
		elseif functionNumber == 0x3F and upperVector == "B" then
			self:flushConsole()
			self:logString(self:readCString(memory, cpu:getRegister(4)))
			result = cpu:getRegister(4)
		elseif functionNumber == 0x3F and upperVector == "A" then
			self:flushConsole()
			local message = self:formatPrintf(memory, cpu, cpu:getRegister(4))
			self:logString(message)
			result = #message
		elseif functionNumber == 0x06 or functionNumber == 0x38 then
			self:flushConsole()
			self:logString(string.format("exit(%d)", Util.toSigned32(cpu:getRegister(4))))
			cpu.halted = true
			result = cpu:getRegister(4)
		elseif functionNumber == 0x44 then
			result = 0
		elseif functionNumber == 0x39 then
			result = cpu:getRegister(4)
		elseif functionNumber == 0x9F then
			result = cpu:getRegister(4)
		elseif functionNumber == 0x2F then
			result = 0x1337
		elseif functionNumber == 0x30 then
			result = 0
		elseif functionNumber == 0x3B and upperVector == "A" then
			result = 0xFFFFFFFF
		elseif functionNumber == 0x3C and upperVector == "B" then
			result = 0xFFFFFFFF
		elseif functionNumber == 0x3D and upperVector == "A" then
			result = cpu:getRegister(4)
		elseif functionNumber == 0x3E and upperVector == "B" then
			result = cpu:getRegister(4)
		elseif functionNumber == 0x17 and upperVector == "B" then
			result = 0
		elseif functionNumber == 0x72 and upperVector == "A" then
			result = 0
		elseif functionNumber == 0x19 and upperVector == "B" then
			result = self.entryInterruptHook
			self.entryInterruptHook = cpu:getRegister(4)
		elseif functionNumber == 0x5B and upperVector == "B" then
			result = self.changeClearPad
			self.changeClearPad = cpu:getRegister(4)
		else
			return unsupported()
		end

		cpu:setRegister(2, result)
		cpu.pc = returnAddress
		cpu.nextPc = band(returnAddress + 4, 0xFFFFFFFF)
		cpu.pendingBranch = nil
		cpu.pendingLoad = nil
		cpu.inDelaySlot = false
		return true
	end

	if upperVector == "C" then
		if functionNumber == 0x13 then
			self:flushConsole()
			result = 0
		elseif functionNumber == 0x0A then
			local counterIndex = band(cpu:getRegister(4), 0xFF)
			result = self.changeClearRootCounter[counterIndex] or 0
			self.changeClearRootCounter[counterIndex] = cpu:getRegister(5)
		elseif functionNumber == 0x19 then
			self:flushConsole()
			self:logString(self:readCString(memory, cpu:getRegister(4)))
			result = 1
		else
			return unsupported()
		end

		cpu:setRegister(2, result)
		cpu.pc = returnAddress
		cpu.nextPc = band(returnAddress + 4, 0xFFFFFFFF)
		cpu.pendingBranch = nil
		cpu.pendingLoad = nil
		cpu.inDelaySlot = false
		return true
	end

	return unsupported()
end

return BIOS