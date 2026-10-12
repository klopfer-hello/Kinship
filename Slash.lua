-- /kin command. Deliberately small: everything else happens automatically.

local _, ns = ...

local LEVEL_NAMES = ns.LOG_LEVEL_NAMES

local HELP = "|cffffff00/kin test|r run all tests · |cffffff00/kin report [name]|r copy or send a report · |cffffff00/kin log|r show the log"

local function formatRecord(r)
	return ("%s.%03d %-5s %-6s %s %s"):format(date("%H:%M:%S", r[1]), r[2] % 1000,
		LEVEL_NAMES[r[3]] or "?", r[4], r[5], ns.LogDataText(r[6]))
end

local function showLog(n)
	local lines = {}
	local sessions = KinshipLog.sessions
	for si = #sessions, 1, -1 do
		local recs = sessions[si].records
		for i = #recs, math.max(1, #recs - (n - #lines) + 1), -1 do
			lines[#lines + 1] = formatRecord(recs[i])
		end
		if #lines >= n then break end
		lines[#lines + 1] = "---- session " .. tostring(sessions[si].header.version) .. " started " ..
			date("%Y-%m-%d %H:%M:%S", sessions[si].header.startServer)
	end
	-- Oldest first reads more naturally.
	for i = 1, math.floor(#lines / 2) do
		lines[i], lines[#lines - i + 1] = lines[#lines - i + 1], lines[i]
	end
	ns.ShowText("Kinship log", ("last %d records"):format(n), table.concat(lines, "\n"), false)
end

-- Splits on spaces; "quoted text" stays one argument (names like "First Surname").
local function tokenize(msg)
	local args, i = {}, 1
	while true do
		i = msg:match("^%s*()", i)
		if i > #msg then break end
		local stop
		if msg:sub(i, i) == '"' then
			stop = msg:find('"', i + 1, true) or #msg + 1
			args[#args + 1] = msg:sub(i + 1, stop - 1)
			i = stop + 1
		else
			stop = msg:find("%s", i) or #msg + 1
			args[#args + 1] = msg:sub(i, stop - 1)
			i = stop
		end
	end
	return args
end

local commands = {
	test = function() ns.Test.All() end,
	report = function(args)
		-- Names may contain a space (first name + surname) even without quotes.
		local name = #args > 0 and table.concat(args, " ") or nil
		if name then ns.Report.Send(name) else ns.Report.Show() end
	end,
	log = function(args) showLog(tonumber(args[1]) or 300) end,
}

SLASH_KINSHIP1 = "/kin"
SLASH_KINSHIP2 = "/kinship"
SlashCmdList.KINSHIP = function(msg)
	local args = tokenize(msg or "")
	local cmd = table.remove(args, 1)
	local fn = commands[cmd and cmd:lower()]
	if fn then
		ns.Safe(fn, args)
	else
		ns.PrintStatus()
		ns.Print(HELP)
	end
end
