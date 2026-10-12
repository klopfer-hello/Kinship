-- Spikes (SPEC-sync §10): measurements on the real client. Everything is written to
-- the log under category "test"; run the same spike on two clients and merge the
-- reports with scripts/kinship-diag.py.

local _, ns = ...

local Test = {}
ns.Test = Test

-- Raw test traffic uses its own prefix so it never touches the real transport.
local TPREFIX = "KinshipT"

local function log(code, data)
	ns.Log("INFO", "test", code, data)
end

local function resultName(res)
	local R = Enum.SendAddonMessageResult
	if R then
		for k, v in pairs(R) do
			if v == res then return k end
		end
	end
	return tostring(res)
end

local function rawSend(text, channel, target)
	local res = C_ChatInfo.SendAddonMessage(TPREFIX, text, channel, target)
	return res, resultName(res)
end

---------------------------------------------------------------------------
-- S1 throttle: burst N full-size frames, or pace them every `interval` seconds.
---------------------------------------------------------------------------
-- Picks where solo-friendly test traffic goes: GUILD when in a guild, otherwise a
-- whisper to yourself; "CHANNEL <name>" uses a custom chat channel you joined.
local function testRoute(channel, target)
	if channel == "CHANNEL" then
		local index = GetChannelName(target or "")
		if index == 0 then return nil, nil, "join the channel first: /join " .. tostring(target) end
		return "CHANNEL", index
	end
	if channel == "WHISPER" or (not channel and not IsInGuild()) then
		return "WHISPER", target or UnitName("player")
	end
	return channel or "GUILD", nil
end

function Test.Throttle(mode, count, interval, channelArg, targetArg)
	count = tonumber(count) or 30
	interval = tonumber(interval) or 1
	local channel, target, err = testRoute(channelArg, targetArg)
	if not channel then
		ns.Print(err)
		return
	end
	local run = ("%x"):format(math.random(0, 0xffff))
	local pad = string.rep("x", 200)
	local counts = {}
	local function one(seq)
		local text = ("S1|%s|%d|%d|%s"):format(run, seq, ns.NowMs(), pad):sub(1, 255)
		local _, name = rawSend(text, channel, target)
		counts[name] = (counts[name] or 0) + 1
		log("S1_TX", { run = run, seq = seq, res = name })
	end
	log("S1_START", { run = run, mode = mode, count = count, interval = interval, ch = channel, to = target })
	if mode == "pace" then
		local seq = 0
		C_Timer.NewTicker(interval, function()
			seq = seq + 1
			one(seq)
			if seq == count then
				log("S1_DONE", { run = run, results = counts })
				ns.Print("throttle pace run %s done: %s", run, ns.LogDataText(counts))
			end
		end, count)
	else
		for seq = 1, count do one(seq) end
		log("S1_DONE", { run = run, results = counts })
		ns.Print("throttle burst run %s: %s", run, ns.LogDataText(counts))
	end
end

---------------------------------------------------------------------------
-- S2 whisper: try several spellings of the target; the receiver answers by
-- whisper to the sender string it saw, and over GUILD as a fallback.
---------------------------------------------------------------------------
local function guildFullName(short)
	if not IsInGuild() then return nil end
	for i = 1, GetNumGuildMembers() do
		local full = GetGuildRosterInfo(i)
		if full and ns.ShortName(full) == short then return full end
	end
end

function Test.Whisper(target)
	target = target or UnitName("player")
	local run = ("%x"):format(math.random(0, 0xffff))
	local short = ns.ShortName(target)
	local variants = {
		typed = target,
		short = short,
		withRealm = short .. "-" .. GetNormalizedRealmName(),
		roster = guildFullName(short),
	}
	for label, name in pairs(variants) do
		local _, resName = rawSend(("S2|%s|%s|%s"):format(run, label, name), "WHISPER", name)
		log("S2_TX", { run = run, variant = label, target = name, res = resName })
	end
	if IsInGuild() then
		rawSend(("S2G|%s|%s"):format(run, short), "GUILD")
	end
	ns.Print("whisper test %s sent to %s (4 spellings + guild). Results arrive within a few seconds; see /kin log 20 test", run, target)
end

---------------------------------------------------------------------------
-- S3 lockdown watcher: logs every change of the messaging restrictions.
---------------------------------------------------------------------------
local lockTicker
local function lockState()
	local r = C_ChatInfo.AreOutgoingAddonChatMessagesRestricted
	local ok, restricted = false, nil
	if r then ok, restricted = pcall(r) end
	return {
		lockdown = C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() or false,
		restricted = ok and restricted or false,
		combat = InCombatLockdown(),
		encounter = IsEncounterInProgress and IsEncounterInProgress() or false,
		instance = select(2, IsInInstance()),
	}
end

function Test.Lockdown(on)
	if lockTicker then lockTicker:Cancel() lockTicker = nil end
	KinshipDB.settings.testLockdown = on or nil
	if not on then
		ns.Print("lockdown watcher off")
		return
	end
	local last, n = "", 0
	lockTicker = C_Timer.NewTicker(1, function()
		local s = lockState()
		local key = ns.LogDataText(s)
		n = n + 1
		if key ~= last then
			last = key
			log("S3_STATE", s)
		end
		-- Every 5 s, try a real send to see what the restriction does to it.
		if n % 5 == 0 and (s.lockdown or s.restricted or s.encounter) then
			local ch = IsInRaid() and "RAID" or IsInGroup() and "PARTY" or (IsInGuild() and "GUILD")
			if ch then
				local _, name = rawSend("S3|probe", ch)
				log("S3_PROBE", { ch = ch, res = name })
			end
		end
	end)
	ns.Print("lockdown watcher on (stays on after /reload; /kin test lockdown off)")
end

---------------------------------------------------------------------------
-- S4 codec: sizes of typical ledger entries, alone and batched.
---------------------------------------------------------------------------
function Test.Codec()
	local guid = UnitGUID("player"):gsub("^Player%-", "")
	local entries = {}
	for i = 1, 60 do
		entries[i] = { guid, 1000 + i, GetServerTime() - i * 600, "GT", { GetServerTime() - i * 1800, { "4567-0A1B2C3D", "4567-0A1B2C3E" }, 3 }, string.rep("a", 16) }
	end
	local c1, z1, b1 = ns.EncodeSizes(entries[1])
	local cN, zN, bN = ns.EncodeSizes(entries)
	local t0 = ns.NowMs()
	for _ = 1, 100 do ns.Decode(ns.Encode(entries)) end
	local ms = (ns.NowMs() - t0) / 100
	local rt = ns.Decode(ns.Encode(entries))
	local ok = type(rt) == "table" and #rt == 60 and rt[60][2] == entries[60][2]
	local data = { one = { cbor = c1, deflate = z1, b64 = b1 }, batch60 = { cbor = cN, deflate = zN, b64 = bN, perEntry = math.floor(bN / 60) }, roundtripMs = ms, roundtripOk = ok }
	log("S4_CODEC", data)
	ns.Print("codec: 1 entry %d/%d/%d B (cbor/deflate/b64), 60 entries %d B b64 (%d B each), %.2f ms round trip, ok=%s",
		c1, z1, b1, bN, math.floor(bN / 60), ms, tostring(ok))
end

---------------------------------------------------------------------------
-- S5 identities: what the client tells us about names, realms and GUIDs.
---------------------------------------------------------------------------
local function describe(v)
	if issecretvalue and issecretvalue(v) then return "<secret>" end
	return v == nil and "nil" or tostring(v)
end

function Test.Ids()
	local name, realm = UnitFullName("player")
	log("S5_PLAYER", {
		unitName = describe(UnitName("player")), fullName = describe(name), fullRealm = describe(realm),
		normalizedRealm = describe(GetNormalizedRealmName()), realmName = describe(GetRealmName()),
		guid = describe(UnitGUID("player")),
	})
	if IsInGuild() then
		C_GuildInfo.GuildRoster()
		for i = 1, math.min(5, GetNumGuildMembers()) do
			local r = { GetGuildRosterInfo(i) }
			local row = { n = select("#", GetGuildRosterInfo(i)) }
			for k = 1, row.n do row["r" .. k] = describe(r[k]) end
			log("S5_ROSTER", row)
		end
	end
	local units = IsInRaid() and "raid" or "party"
	for i = 1, (IsInRaid() and 40 or 4) do
		local u = units .. i
		if UnitExists(u) then
			local n, r = UnitName(u)
			log("S5_UNIT", { unit = u, name = describe(n), realm = describe(r), guid = describe(UnitGUID(u)),
				guildie = describe(UnitIsInMyGuild(u)), connected = describe(UnitIsConnected(u)), level = describe(UnitLevel(u)) })
		end
	end
	ns.Print("identity data logged — /kin log 20 test")
end

---------------------------------------------------------------------------
-- S6 event logger: what fires during normal play (dungeons, quests, trades …).
---------------------------------------------------------------------------
local EVENTS = {
	"ENCOUNTER_START", "ENCOUNTER_END", "BOSS_KILL", "PLAYER_XP_UPDATE", "QUEST_TURNED_IN",
	"PLAYER_FLAGS_CHANGED", "ZONE_CHANGED_NEW_AREA", "GROUP_ROSTER_UPDATE", "PLAYER_LEVEL_UP",
	"TRADE_SHOW", "TRADE_ACCEPT_UPDATE", "TRADE_CLOSED", "UI_INFO_MESSAGE",
	"MAIL_SEND_SUCCESS", "MAIL_FAILED", "GUILDBANKBAGSLOTS_CHANGED", "GUILDBANKLOG_UPDATE",
	"UNIT_SPELLCAST_SUCCEEDED", "RESURRECT_REQUEST", "PLAYER_ALIVE", "PLAYER_UNGHOST",
	"CHAT_MSG_SYSTEM", "CHAT_MSG_LOOT", "CHAT_MSG_COMBAT_XP_GAIN", "CHAT_MSG_SKILL",
	"CALENDAR_UPDATE_EVENT_LIST",
}
local eventFrame

local function plainArgs(...)
	local out = {}
	for i = 1, math.min(select("#", ...), 8) do
		out["a" .. i] = describe((select(i, ...)))
	end
	return out
end

function Test.Events(on)
	KinshipDB.settings.testEvents = on or nil
	if not on then
		if eventFrame then eventFrame:UnregisterAllEvents() end
		ns.Print("event logger off")
		return
	end
	eventFrame = eventFrame or CreateFrame("Frame")
	eventFrame:UnregisterAllEvents()
	local missing = {}
	for _, ev in ipairs(EVENTS) do
		if not pcall(eventFrame.RegisterEvent, eventFrame, ev) then missing[#missing + 1] = ev end
	end
	-- Own casts only; other units would flood the log.
	pcall(eventFrame.UnregisterEvent, eventFrame, "UNIT_SPELLCAST_SUCCEEDED")
	pcall(eventFrame.RegisterUnitEvent, eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player")
	eventFrame:SetScript("OnEvent", function(_, event, ...)
		ns.Safe(function(...)
			local data = plainArgs(...)
			if event == "PLAYER_XP_UPDATE" then
				data.xp, data.xpMax = describe(UnitXP("player")), describe(UnitXPMax("player"))
			elseif event == "ZONE_CHANGED_NEW_AREA" or event == "ENCOUNTER_END" then
				local iname, itype, diff, _, _, _, _, instanceId = GetInstanceInfo()
				data.instance, data.itype, data.diff, data.instanceId = iname, itype, diff, instanceId
			elseif event == "GROUP_ROSTER_UPDATE" then
				data.members = GetNumGroupMembers()
			end
			log("S6_" .. event, data)
		end, ...)
	end)
	if #missing > 0 then log("S6_MISSING", { events = table.concat(missing, ",") }) end
	ns.Print("event logger on (%d events, %d unknown; stays on after /reload; /kin test events off)",
		#EVENTS - #missing, #missing)
end

---------------------------------------------------------------------------
-- S7 calendar: guild events of the next 14 days (on-time award source, D25).
---------------------------------------------------------------------------
function Test.Calendar()
	if not C_Calendar then
		log("S7_NO_CALENDAR", nil)
		ns.Print("C_Calendar does not exist on this client")
		return
	end
	local f = CreateFrame("Frame")
	local done = false
	local function dump()
		if done then return end
		done = true
		f:UnregisterAllEvents()
		local now = C_DateAndTime.GetCurrentCalendarTime()
		local found = 0
		for d = 0, 13 do
			local t = C_DateAndTime.AdjustTimeByDays(now, d)
			local monthOffset = (t.year - now.year) * 12 + (t.month - now.month)
			for i = 1, C_Calendar.GetNumDayEvents(monthOffset, t.monthDay) do
				local ev = C_Calendar.GetDayEvent(monthOffset, t.monthDay, i)
				if ev then
					found = found + 1
					local st = ev.startTime or {}
					log("S7_EVENT", { title = ev.title, calendarType = ev.calendarType, eventType = ev.eventType,
						eventID = ev.eventID, clubID = ev.clubID, sequenceType = ev.sequenceType,
						start = ("%04d-%02d-%02d %02d:%02d"):format(st.year or 0, st.month or 0, st.monthDay or 0, st.hour or 0, st.minute or 0),
						invite = ev.inviteStatus })
				end
			end
		end
		ns.Print("calendar: %d events in the next 14 days logged — /kin log 30 test", found)
	end
	f:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST")
	f:SetScript("OnEvent", function() ns.Safe(dump) end)
	C_Calendar.OpenCalendar()
	C_Timer.After(5, function() ns.Safe(dump) end)
end

function Test.Loopback(on)
	KinshipDB.settings.loopback = on or nil
	ns.Print("loopback %s — own messages are %s", on and "on" or "off", on and "processed like a peer's (solo testing)" or "ignored")
	ns.Log("INFO", "test", "LOOPBACK", { on = on })
end

---------------------------------------------------------------------------
-- /kin test all: every spike this setup allows, in sequence, then a summary.
-- Results stay in the log (SavedVariables, written on /reload or logout).
---------------------------------------------------------------------------
local running = false

local function countCodes(sinceMs)
	local counts = {}
	for _, r in ipairs(ns.logSession.records) do
		if r[2] >= sinceMs and (r[4] == "test" or r[4] == "report") then
			counts[r[5]] = (counts[r[5]] or 0) + 1
		end
	end
	return counts
end

function Test.All()
	if running then
		ns.Print("test run already in progress")
		return
	end
	running = true
	local startMs = ns.NowMs()
	local hadLoopback = KinshipDB.settings.loopback
	local solo = not IsInGuild() and not IsInGroup()
	log("ALL_START", { guild = IsInGuild(), group = IsInGroup(), raid = IsInRaid(), solo = solo })
	ns.Print("running all tests (~2 min). Keep playing normally; don't /reload until it says done.")

	-- Loopback lets a single client receive its own whispers and reports.
	Test.Loopback(true)
	ns.Report.autoAcceptSelf = true

	local steps = {
		{ 0, "codec", Test.Codec },
		{ 1, "ids", Test.Ids },
		{ 2, "calendar", Test.Calendar },
		{ 3, "whisper", function() Test.Whisper(UnitName("player")) end },
		{ 12, "throttle burst", function() Test.Throttle("burst", 30) end },
		{ 30, "throttle pace", function() Test.Throttle("pace", 20, 0.5) end },
		{ 45, "report to self", function() ns.Report.Send(UnitName("player"), 1) end },
		{ 46, "watchers", function()
			Test.Events(true)
			Test.Lockdown(true)
		end },
	}
	for i, step in ipairs(steps) do
		C_Timer.After(step[1], function()
			log("ALL_STEP", { n = i, step = step[2] })
			ns.Safe(step[3])
		end)
	end

	C_Timer.After(110, function()
		ns.Safe(function()
			local c = countCodes(startMs)
			local summary = {
				codec = (c.S4_CODEC or 0) > 0,
				selfWhisperReplies = c.S2_PONG or 0,
				throttleSent = c.S1_TX or 0,
				throttleReceived = c.S1_RX or 0,
				calendarEvents = c.S7_EVENT or 0,
				reportReceived = (c.REPORT_RECEIVED or 0) > 0,
				errors = 0,
				commStats = ns.Comm.stats,
			}
			for _, r in ipairs(ns.logSession.records) do
				if r[2] >= startMs and r[3] == 1 then summary.errors = summary.errors + 1 end
			end
			log("ALL_SUMMARY", summary)
			KinshipDB.settings.loopback = hadLoopback
			ns.Report.autoAcceptSelf = false
			running = false
			ns.Print("tests done: self-whisper replies %d · throttle %d sent / %d received · calendar events %d · report %s · errors %d",
				summary.selfWhisperReplies, summary.throttleSent, summary.throttleReceived,
				summary.calendarEvents, summary.reportReceived and "ok" or "|cffff6060missing|r", summary.errors)
			ns.Print("Now |cffffff00/reload|r to save the results. The event + lockdown watchers stay on while you play (/kin test watch off).")
		end)
	end)
end

function Test.Watch(on)
	Test.Events(on)
	Test.Lockdown(on)
end

---------------------------------------------------------------------------
-- Receiver side of S1/S2 (always active, cheap).
---------------------------------------------------------------------------
local function onTestMessage(_, prefix, text, channel, sender)
	if prefix ~= TPREFIX or not ns.AcceptFrom(sender) then return end
	local kind, rest = text:match("^(%w+)|(.*)$")
	if kind == "S1" then
		local run, seq, sentMs = rest:match("^(%w+)|(%d+)|(%d+)|")
		log("S1_RX", { run = run, seq = tonumber(seq), sentMs = tonumber(sentMs), from = sender, ch = channel })
	elseif kind == "S2" then
		local run, variant = rest:match("^(%w+)|(%w+)|")
		log("S2_RX", { run = run, variant = variant, from = sender, ch = channel })
		local _, name = rawSend(("S2R|%s|%s"):format(run, variant), "WHISPER", sender)
		log("S2_REPLY", { run = run, to = sender, res = name })
	elseif kind == "S2G" then
		local run, target = rest:match("^(%w+)|(.*)$")
		if target == UnitName("player") then
			log("S2_RX", { run = run, variant = "guild", from = sender, ch = channel })
			rawSend(("S2GR|%s"):format(run), "GUILD")
		end
	elseif kind == "S2R" or kind == "S2GR" then
		local run, variant = rest:match("^(%w+)|?(%w*)")
		log("S2_PONG", { run = run, variant = variant, via = kind, from = sender, ch = channel })
		ns.Print("whisper test %s: reply via %s for '%s' from %s", run, channel, variant ~= "" and variant or "guild", sender)
	end
end

ns.OnLoad(function()
	C_ChatInfo.RegisterAddonMessagePrefix(TPREFIX)
	ns.On("CHAT_MSG_ADDON", onTestMessage)
end)

ns.OnLogin(function()
	local s = KinshipDB.settings
	if s.testLockdown then Test.Lockdown(true) end
	if s.testEvents then Test.Events(true) end
end)
