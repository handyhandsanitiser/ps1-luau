-- loads the roblox-style modules under src/shared/PS1 from a lune host.  the emulator core is
-- written for the roblox engine: each file references `script` and requires siblings with
-- require(script.Parent.<Name>).  a lune host can't use that resolution, so this module rebuilds
-- the folder as an in-memory instance tree and executes each file in an environment that mimics it.
-- this is the single source of truth for the module name list used by the lune front-ends (the
-- copies used to drift); keep NAMES in sync with the files under src/shared/PS1.
-- hosts call Loader.createRequire() once and use the returned requireModule, e.g.
-- local Runtime = requireModule("Runtime").

local fs = require("@lune/fs")

local NAMES = {
	"Util",
	"BIOS",
	"CPU",
	"CDROM",
	"Ckpt",
	"Disc",
	"DMA",
	"FrameOut",
	"GPU",
	"GTE",
	"MDEC",
	"Memory",
	"PSXExe",
	"Region",
	"Runtime",
	"SPU",
	"Timers",
	"Harness",
	"Hud",
}

local function norm(path)
	return (path:gsub("\\", "/"))
end

local Loader = {}

-- returns requireModule(name): loads (once) and returns the named module.
function Loader.createRequire()
	local root = {}
	local byPath = {}
	for _, name in ipairs(NAMES) do
		local modulePath = norm("src/shared/PS1/" .. name .. ".luau")
		local node = {
			__name = name,
			__modulePath = modulePath,
			Parent = root,
		}
		root[name] = node
		byPath[modulePath] = node
	end

	local cache = {}
	local globals = getfenv(0)

	local function loadNode(node)
		if cache[node] ~= nil then
			return cache[node]
		end

		local source = fs.readFile(node.__modulePath)
		local chunk, compileError = loadstring(source, "@" .. node.__modulePath)
		if not chunk then
			error(string.format("failed to compile %s: %s", node.__modulePath, tostring(compileError)))
		end

		local env = {
			script = node,
		}

		local function ps1Require(target)
			if type(target) == "table" and target.__modulePath then
				return loadNode(target)
			end
			if type(target) == "string" then
				local mapped = byPath[norm(target)]
				if mapped then
					return loadNode(mapped)
				end
			end
			-- shared modules require each other only through the graph above; anything else is a bug -- error loudly instead of falling back to lune's require, which would silently load the wrong file.
			error(string.format("cannot require %s from %s", tostring(target), tostring(node.__modulePath)))
		end

		env.require = ps1Require
		setmetatable(env, { __index = globals })
		setfenv(chunk, env)

		local exports = chunk()
		if exports == nil then
			exports = true
		end
		cache[node] = exports
		return exports
	end

	local function requireModule(name)
		local node = root[name]
		if not node then
			error("unknown PS1 module: " .. tostring(name))
		end
		return loadNode(node)
	end

	return requireModule
end

return Loader
