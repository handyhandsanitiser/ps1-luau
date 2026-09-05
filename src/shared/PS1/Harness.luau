local Harness = {}

Harness.CpuTestPriority = {
	"access-time",
	"code-in-io",
	"cop",
	"io-access-bitwidth",
}

local function isNonEmptyString(value)
	return type(value) == "string" and value ~= ""
end

local function readExecutableDataFromEntry(entry)
	if type(entry) == "string" then
		return entry
	end

	if type(entry) == "table" then
		if isNonEmptyString(entry.data) then
			return entry.data
		end

		if isNonEmptyString(entry.binary) then
			return entry.binary
		end

		if isNonEmptyString(entry.bytes) then
			return entry.bytes
		end

		if isNonEmptyString(entry.base64) then
			local httpService = game:GetService("HttpService")
			return httpService:Base64Decode(entry.base64)
		end
	end

	return nil
end

local function pickPreferredTestName(requestedName, availableTests)
	if isNonEmptyString(requestedName) and availableTests and availableTests[requestedName] ~= nil then
		return requestedName
	end

	for _, testName in ipairs(Harness.CpuTestPriority) do
		if availableTests and availableTests[testName] ~= nil then
			return testName
		end
	end

	if isNonEmptyString(requestedName) then
		return requestedName
	end

	if availableTests then
		for testName in pairs(availableTests) do
			return testName
		end
	end

	return nil
end

function Harness.resolveExecutable(config)
	local selectedName = pickPreferredTestName(config and config.testName, config and config.tests)

	if isNonEmptyString(config and config.executableData) then
		return config.executableData, selectedName
	end

	if config and config.tests and selectedName then
		local entry = config.tests[selectedName]
		local executableData = readExecutableDataFromEntry(entry)
		if executableData then
			return executableData, selectedName
		end
	end

	return nil, selectedName
end

function Harness.run(runtime, config)
	config = config or {}

	local executableData, selectedName = Harness.resolveExecutable(config)
	if not executableData then
		return nil, string.format("missing executable data for %s", selectedName or "cpu test")
	end

	local log = config.log or function(message)
		print(message)
	end

	if selectedName then
		log(string.format("[ps1-harness] loading %s", selectedName))
	else
		log("[ps1-harness] loading executable")
	end

	runtime:loadExecutable(executableData)

	local instructionBudget = config.instructionBudget or 20000000
	local sliceSize = config.sliceSize or 10000
	local executed = 0
	local previousPc = nil
	local lastPc = nil
	local stagnantSlices = 0
	local stagnationLimit = config.stagnationLimit or 10

	while executed < instructionBudget and not runtime.cpu.halted do
		local remaining = instructionBudget - executed
		local budgetSlice = math.min(sliceSize, remaining)
		local executedSlice = runtime:runInstructionBudget(budgetSlice)
		executed += executedSlice or budgetSlice

		if config.onSample then
			config.onSample(runtime:dumpState())
		end

		local state = runtime:dumpState()
		local repeatsPrevious = state.pc == lastPc
		local repeatsAlternating = previousPc ~= nil and state.pc == previousPc and lastPc ~= state.pc
		if repeatsPrevious or repeatsAlternating then
			stagnantSlices += 1
			if stagnantSlices == 1 then
				log(string.format(
					"[ps1-harness] repeating pc sample current=%08X previous=%08X previous2=%08X",
					state.pc or 0,
					lastPc or 0,
					previousPc or 0
				))
			end
		else
			stagnantSlices = 0
		end

		previousPc = lastPc
		lastPc = state.pc

		if stagnantSlices >= stagnationLimit then
			break
		end

		if config.shouldStop and config.shouldStop(runtime, state) then
			break
		end
	end

	local finalState = runtime:dumpState()
	finalState.executedInstructions = executed
	finalState.testName = selectedName
	finalState.budgetExhausted = executed >= instructionBudget and not runtime.cpu.halted
	finalState.stagnantSlices = stagnantSlices
	finalState.halted = runtime.cpu.halted
	if finalState.halted then
		finalState.status = "pass"
	elseif finalState.budgetExhausted then
		finalState.status = "budget-exhausted"
	else
		finalState.status = "stopped"
	end

	if runtime.cpu.halted then
		log(string.format("[ps1-harness] halted at %08X", finalState.pc))
	elseif finalState.budgetExhausted then
		log(string.format("[ps1-harness] budget exhausted at %08X", finalState.pc))
	else
		log(string.format("[ps1-harness] stopped at %08X", finalState.pc))
	end

	return finalState
end

return Harness