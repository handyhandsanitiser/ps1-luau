-- pure-luau md5 (rfc 1321) used for bios region identification.
-- operates on byte strings; returns the 32-char lowercase hex digest.
-- the implementation lives in src/shared/PS1/Util.luau (Region.luau uses it
-- directly); this module just exposes it to lune hosts via the shared loader.
local Loader = require("./lib/ps1loader")
local requirePs1 = Loader.createRequire()
local Util = requirePs1("Util")

return {
	digest = function(data)
		return Util.md5(data)
	end,
}