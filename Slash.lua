-- /kin command.

local _, ns = ...

local LEVEL_NAMES = ns.LOG_LEVEL_NAMES

local HELP = {
	"/kin status — version, sync and log state",
	"/kin report [hours] — copy a diagnostic report",
	"/kin report send <name> [hours] [guild] — send a report to a player in game",
	"/kin reports [n|clear] — reports you received",
	"/kin log [n] [category] — last log records (window)",
	"/kin debug <category|all> on|off — verbose logging (" .. table.concat(ns.LOG_CATEGORIES, ", ") .. ")",
	"/kin echo <category> on|off — also print a category to chat",
	"/kin test — run every test this setup allows (~2 min), then /reload to save",
	"/kin test watch on|off — keep logging game events + messaging lockdown while playing",
	"/kin test throttle [burst|pace] [count] [interval] [GUILD|WHISPER|CHANNEL] [name]",
	"/kin test whisper [name] · loopback on|off · lockdown on|off · codec · ids · events on|off · calendar",
}

local function formatRecord(r)
	return ("%s.%03d %-5s %-6s %s %s"):format(date("%H:%M:%S", r[1]), r[2] % 1000,
		LEVEL_NAMES[r[3]] or "?", r[4], r[5], ns.LogDataText(r[6]))
end

local function showLog(n, category)
	n = n or 200
	local lines = {}
	local sessions = KinshipLog.sessions
	for si = #sessions, 1, -1 do
		local recs = sessions[si].records
		for i = #recs, 1, -1 do
			local r = recs[i]
			if not category or r[4] == category then
				lines[#lines + 1] = formatRecord(r)
				if #lines >= n then break end
			end
		end
		if #lines >= n then break end
		lines[#lines + 1] = "---- session " .. tostring(sessions[si].header.version) .. " started " ..
			date("%Y-%m-%d %H:%M:%S", sessions[si].header.startServer)
	end
	-- Oldest first reads more naturally.
	for i = 1, math.floor(#lines / 2) do
		lines[i], lines[#lines - i + 1] = lines[#lines - i + 1], lines[i]
	end
	ns.ShowText("Kinship log", ("last %d records%s"):format(n, category and (" · " .. category) or ""),
		table.concat(lines, "\n"), false)
end

local function onOff(word)
	if word == "on" then return true elseif word == "off" then return false end
end

local commands = {}

commands.status = function() ns.PrintStatus() end

commands.report = function(args)
	if args[1] == "send" then
		local target = args[2]
		if not target then
			ns.Print("usage: /kin report send <name> [hours] [guild]")
			return
		end
		local hours = tonumber(args[3])
		local route = (args[3] == "guild" or args[4] == "guild") and "GUILD" or nil
		ns.Report.Send(target, hours, route)
	else
		ns.Report.Show(tonumber(args[1]))
	end
end

commands.reports = function(args)
	if args[1] == "clear" then
		wipe(KinshipLog.inbox)
		ns.Print("received reports deleted.")
	elseif tonumber(args[1]) then
		ns.Report.ShowInbox(tonumber(args[1]))
	else
		ns.Report.ListInbox()
	end
end

commands.log = function(args)
	if args[1] == "clear" then
		StaticPopup_Show("KINSHIP_LOG_CLEAR")
		return
	end
	local n = tonumber(args[1])
	local category = n and args[2] or args[1]
	showLog(n, category)
end

commands.debug = function(args)
	local on = onOff(args[2])
	if not args[1] or on == nil then
		ns.Print("usage: /kin debug <category|all> on|off")
		return
	end
	ns.SetDebug(args[1], on)
	ns.Print("debug %s: %s", args[1], on and "on" or "off")
end

commands.echo = function(args)
	local on = onOff(args[2])
	if not args[1] or on == nil then
		ns.Print("usage: /kin echo <category> on|off")
		return
	end
	ns.SetEcho(args[1], on)
end

commands.test = function(args)
	local T, sub = ns.Test, args[1]
	if not sub or sub == "all" then
		T.All()
	elseif sub == "throttle" then
		T.Throttle(args[2] or "burst", args[3], args[4], args[5] and args[5]:upper(), args[6])
	elseif sub == "whisper" then
		T.Whisper(args[2])
	elseif sub == "lockdown" then
		T.Lockdown(onOff(args[2]) ~= false)
	elseif sub == "codec" then
		T.Codec()
	elseif sub == "ids" then
		T.Ids()
	elseif sub == "events" then
		T.Events(onOff(args[2]) ~= false)
	elseif sub == "calendar" then
		T.Calendar()
	elseif sub == "watch" then
		T.Watch(onOff(args[2]) ~= false)
	elseif sub == "loopback" then
		T.Loopback(onOff(args[2]) ~= false)
	else
		for _, line in ipairs(HELP) do
			if line:find("^/kin test") then ns.Print(line) end
		end
	end
end

StaticPopupDialogs["KINSHIP_LOG_CLEAR"] = {
	text = "Delete the whole Kinship log?",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		wipe(ns.logSession.records)
		KinshipLog.sessions = { ns.logSession }
		ns.Print("log cleared.")
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

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

SLASH_KINSHIP1 = "/kin"
SLASH_KINSHIP2 = "/kinship"
SlashCmdList.KINSHIP = function(msg)
	local args = tokenize(msg or "")
	local cmd = table.remove(args, 1)
	cmd = cmd and cmd:lower()
	local fn = commands[cmd]
	if fn then
		ns.Safe(fn, args)
	else
		for _, line in ipairs(HELP) do ns.Print(line) end
	end
end
