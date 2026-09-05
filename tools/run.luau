-- run one of the command-line tools.
local process = require("@lune/process")

local TOOLS = {
	boot = "tools/lune_boot_ps1.luau",
	play = "tools/play.luau",
	md5 = "tools/md5.luau",
	refcheck = "tools/refcheck.luau",
	cpudiff = "tools/cpu_diff.luau",
	gtediff = "tools/gte_diff.luau",
	gpudiff = "tools/gpu_diff.luau",
}

local args = process.args or {}
local command = args[1]
if command == "list" or command == nil then
	print("usage: lune run tools/run.luau <boot|play|md5|refcheck|cpudiff|gtediff|gpudiff> [args...]")
	print("  boot     headless BIOS/disc boot gate")
	print("  play     browser frontend")
	print("  md5      checksum utility")
	print("  refcheck core vs reference-model constant drift check")
	print("  cpudiff  deep cpu differential: core vs reference model per instruction")
	print("  gtediff  gte execution differential: core vs reference model per command")
	print("  gpudiff  gpu state-machine differential: core vs reference per command + vram")
	if command == nil then
		process.exit(1)
	end
	return
end

local path = TOOLS[command]
if not path then
	print("unknown tool: " .. command)
	process.exit(1)
end

local childArgs = { "run", path }
for index = 2, #args do
	childArgs[#childArgs + 1] = args[index]
end
local result = process.exec("lune", childArgs)
if result.stdout and #result.stdout > 0 then
	print(result.stdout:sub(1, -2))
end
if result.stderr and #result.stderr > 0 then
	print(result.stderr:sub(1, -2))
end
-- process.exec reports { ok, code, ... }; there is no result.success.
process.exit(result.ok == true and result.code == 0 and 0 or 1)
