-- Measurements on the real client (SPEC-sync §10), run as a pipeline by /kin test.
-- Every detail goes to the log (category "test"); chat only shows one line per step.
-- Single checks stay callable for the developer: /run Kinship.Test.Codec() etc.

local _, ns = ...

local Test = {}
ns.Test = Test

-- Raw test traffic uses its own prefix so it never touches the real transport.
local TPREFIX = "KinshipT"

local quiet = false   -- true while the pipeline runs: single checks stay silent

local function log(code, data)
	ns.Log("INFO", "test", code, data)
end

local function say(...)
	if not quiet then ns.Print(...) end
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

-- Returns the raw result, its enum name and whether it counts as sent.
local function rawSend(text, channel, target)
	local res = C_ChatInfo.SendAddonMessage(TPREFIX, text, channel, target)
	local R = Enum.SendAddonMessageResult
	local ok = res == nil or res == true or (R ~= nil and res == R.Success)
	return res, resultName(res), ok
end

-- This session's records with `code` written after sinceMs (optionally filtered).
local function records(code, sinceMs, match)
	local out = {}
	for _, r in ipairs(ns.logSession.records) do
		if r[5] == code and r[2] >= sinceMs and (not match or match(r[6])) then out[#out + 1] = r end
	end
	return out
end

local function count(code, sinceMs, match)
	return #records(code, sinceMs, match)
end

local function describe(v)
	if issecretvalue and issecretvalue(v) then return "<secret>" end
	return v == nil and "nil" or tostring(v)
end

local function randomId()
	return ("%x"):format(math.random(0, 0xffff))
end

---------------------------------------------------------------------------
-- Chat hygiene during tests: hide the server's "no player named …" replies and
-- the notices of the temporary test channel.
---------------------------------------------------------------------------
local hideUntil = 0
local hiddenChannel

local function notFoundPattern()
	local fmt = ERR_CHAT_PLAYER_NOT_FOUND_S or "No player named '%s' is currently playing."
	return "^" .. fmt:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0"):gsub("%%%%s", "(.+)") .. "$"
end

local notFound
local function systemFilter(_, _, msg)
	if GetTime() >= hideUntil or type(msg) ~= "string" then return false end
	notFound = notFound or notFoundPattern()
	return msg:match(notFound) ~= nil
end

local function channelNoticeFilter(_, _, ...)
	if not hiddenChannel then return false end
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if type(v) == "string" and v:find(hiddenChannel, 1, true) then return true end
	end
	return false
end

local function hideChatNoise(seconds)
	hideUntil = math.max(hideUntil, GetTime() + seconds)
end

---------------------------------------------------------------------------
-- Single checks
---------------------------------------------------------------------------

-- Encoding sizes of typical ledger entries, alone and as a batch of 60.
function Test.Codec()
	local guid = UnitGUID("player"):gsub("^Player%-", "")
	local entries = {}
	for i = 1, 60 do
		entries[i] = { guid, 1000 + i, GetServerTime() - i * 600, "GT",
			{ GetServerTime() - i * 1800, { "4567-0A1B2C3D", "4567-0A1B2C3E" }, 3 }, string.rep("a", 16) }
	end
	local c1, z1, b1 = ns.EncodeSizes(entries[1])
	local cN, zN, bN = ns.EncodeSizes(entries)
	local t0 = ns.NowMs()
	for _ = 1, 100 do ns.Decode(ns.Encode(entries)) end
	local ms = (ns.NowMs() - t0) / 100
	local rt = ns.Decode(ns.Encode(entries))
	local ok = type(rt) == "table" and #rt == 60 and rt[60][2] == entries[60][2]
	log("S4_CODEC", { one = { cbor = c1, deflate = z1, b64 = b1 },
		batch60 = { cbor = cN, deflate = zN, b64 = bN, perEntry = math.floor(bN / 60) },
		roundtripMs = ms, roundtripOk = ok })
	local text = ("1 entry %d B, batch of 60 %d B (%d B each), %.1f ms"):format(b1, bN, math.floor(bN / 60), ms)
	say("codec: %s, round trip %s", text, ok and "ok" or "BROKEN")
	return ok, text
end

-- What the client tells us about names, surnames, realms and GUIDs.
function Test.Ids()
	local name, surname = UnitFullName("player")
	local player = {
		unitName = describe(UnitName("player")), fullName = describe(name), fullRealm = describe(surname),
		normalizedRealm = describe(GetNormalizedRealmName()), realmName = describe(GetRealmName()),
		guid = describe(UnitGUID("player")),
	}
	log("S5_PLAYER", player)
	local rows = 0
	if IsInGuild() then
		C_GuildInfo.GuildRoster()
		for i = 1, math.min(5, GetNumGuildMembers()) do
			local r = { GetGuildRosterInfo(i) }
			local row = { n = select("#", GetGuildRosterInfo(i)) }
			for k = 1, row.n do row["r" .. k] = describe(r[k]) end
			log("S5_ROSTER", row)
			rows = rows + 1
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
	local ok = player.guid ~= "nil" and player.guid ~= "<secret>"
	local text = ("%s-%s, realm %s, GUID %s%s"):format(player.fullName, player.fullRealm, player.normalizedRealm,
		ok and "readable" or player.guid, IsInGuild() and (", %d roster rows"):format(rows) or "")
	say("ids: %s", text)
	return ok, text
end

-- Guild/personal events of the next 14 days (on-time award source, D25).
-- done(ok, text) is called when the calendar has answered (or after 6 s).
function Test.Calendar(done)
	done = done or function(_, text) say("calendar: %s", text) end
	if not C_Calendar then
		log("S7_NO_CALENDAR", nil)
		done(false, "C_Calendar does not exist")
		return
	end
	local f = CreateFrame("Frame")
	local finished = false
	local function dump()
		if finished then return end
		finished = true
		f:UnregisterAllEvents()
		local now = C_DateAndTime.GetCurrentCalendarTime()
		local found, guild = 0, 0
		for d = 0, 13 do
			local t = C_DateAndTime.AdjustTimeByDays(now, d)
			local monthOffset = (t.year - now.year) * 12 + (t.month - now.month)
			for i = 1, C_Calendar.GetNumDayEvents(monthOffset, t.monthDay) do
				local ev = C_Calendar.GetDayEvent(monthOffset, t.monthDay, i)
				if ev then
					found = found + 1
					if tostring(ev.calendarType):find("GUILD") then guild = guild + 1 end
					local st = ev.startTime or {}
					log("S7_EVENT", { title = ev.title, calendarType = ev.calendarType, eventType = ev.eventType,
						eventID = ev.eventID, clubID = ev.clubID, sequenceType = ev.sequenceType,
						start = ("%04d-%02d-%02d %02d:%02d"):format(st.year or 0, st.month or 0, st.monthDay or 0, st.hour or 0, st.minute or 0),
						invite = ev.inviteStatus })
				end
			end
		end
		log("S7_DONE", { found = found, guild = guild })
		done(true, ("readable, %d events in 14 days (%d guild)"):format(found, guild))
	end
	f:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST")
	f:SetScript("OnEvent", function() ns.Safe(dump) end)
	C_Calendar.OpenCalendar()
	C_Timer.After(6, function() ns.Safe(dump) end)
end

-- Joins a private temporary channel; on Forever without a guild this is the only
-- way for one client to receive its own addon messages through the server.
-- done(index or nil, name).
function Test.JoinChannel(done)
	local name = "KinT" .. randomId() .. randomId()
	hiddenChannel = name
	JoinTemporaryChannel(name)
	local tries = 0
	C_Timer.NewTicker(0.5, function(ticker)
		tries = tries + 1
		local index = GetChannelName(name)
		if index and index > 0 then
			ticker:Cancel()
			log("S8_CHANNEL", { name = name, index = index })
			done(index, name)
		elseif tries >= 20 then
			ticker:Cancel()
			log("S8_CHANNEL_FAIL", { name = name })
			done(nil, name)
		end
	end)
end

function Test.LeaveChannel(name)
	if name then LeaveChannelByName(name) end
	C_Timer.After(5, function() hiddenChannel = nil end)
end

-- Whisper spellings. Forever characters have a first name and a surname
-- (UnitFullName returns the surname where other clients return the realm), and
-- the beta server answers whispers with a long delay (~25 s measured). So:
-- 1. whisper a name that cannot exist to measure the server's answer delay,
-- 2. whisper every plausible spelling SPACING s apart,
-- 3. credit each "no player named …" answer to the spelling sent `delay` s earlier.
-- done(ok, text, info) when finished; info = { delay, valid = {names}, delivered }.
local SPACING = 4
local MAX_WAIT = 75

local function guildFullName(short)
	if not IsInGuild() then return nil end
	for i = 1, GetNumGuildMembers() do
		local full = GetGuildRosterInfo(i)
		if full and ns.ShortName(full) == short then return full end
	end
end

function Test.Whisper(target, done, progress)
	done = done or function(_, text) say("whisper: %s", text) end
	local short, surname
	if not target or ns.IsMe(target) then
		short, surname = UnitFullName("player")
	else
		short = ns.ShortName(target)
	end
	local realm = GetNormalizedRealmName()
	local candidates = {}
	if surname and surname ~= "" and surname ~= realm then
		candidates[#candidates + 1] = { "nameDashSurname", short .. "-" .. surname }
		candidates[#candidates + 1] = { "nameSurname", short .. " " .. surname }
	end
	candidates[#candidates + 1] = { "typed", target }
	candidates[#candidates + 1] = { "short", short }
	candidates[#candidates + 1] = { "withRealm", short .. "-" .. realm }
	candidates[#candidates + 1] = { "roster", guildFullName(short) }

	local run = randomId()
	local seen, list = {}, {}
	for _, c in ipairs(candidates) do
		if c[2] and not seen[c[2]] then
			seen[c[2]] = true
			list[#list + 1] = { label = c[1], name = c[2] }
		end
	end
	local probe = { label = "probe", name = "Zq" .. randomId():gsub("%d", "x") .. "kin" }

	local rejections = {}
	local listener = CreateFrame("Frame")
	listener:RegisterEvent("CHAT_MSG_SYSTEM")
	listener:SetScript("OnEvent", function(_, _, msg)
		if type(msg) == "string" and msg:match(notFoundPattern()) then
			rejections[#rejections + 1] = GetTime()
			log("S2_REJECT", { run = run, msg = msg })
		end
	end)
	hideChatNoise(MAX_WAIT + #list * SPACING + 30)

	local function send(c)
		c.at = GetTime()
		local _, resName = rawSend(("S2|%s|%s|%s"):format(run, c.label, c.name), "WHISPER", c.name)
		log("S2_TX", { run = run, variant = c.label, target = c.name, res = resName })
	end
	send(probe)
	for i, c in ipairs(list) do
		C_Timer.After(i * SPACING, function() send(c) end)
	end

	local started, startedMs, lastProgress = GetTime(), ns.NowMs(), 0
	C_Timer.NewTicker(1, function(ticker)
		local elapsed = GetTime() - started
		local delay = rejections[1] and (rejections[1] - probe.at) or nil
		local lastSent = list[#list].at
		local ready = delay and lastSent and GetTime() > lastSent + delay + 5
		if not ready and elapsed < MAX_WAIT + #list * SPACING then
			if progress and elapsed - lastProgress >= 15 then
				lastProgress = elapsed
				progress(delay and ("server answers after %.0f s, collecting…"):format(delay)
					or ("waiting for the server's first answer… %d s"):format(elapsed))
			end
			return
		end
		ticker:Cancel()
		listener:UnregisterAllEvents()

		-- Credit each rejection (after the probe's) to the spelling sent `delay` earlier.
		local rejected = {}
		if delay then
			for k = 2, #rejections do
				for _, c in ipairs(list) do
					if c.at and math.abs(rejections[k] - delay - c.at) < SPACING / 2 then rejected[c.label] = true end
				end
			end
		end
		local delivered = {}
		for _, r in ipairs(records("S2_RX", startedMs, function(d) return d.run == run end)) do
			delivered[r[6].variant] = true
		end
		local valid, names = {}, {}
		for _, c in ipairs(list) do
			if delay and not rejected[c.label] then
				valid[#valid + 1] = c.name
				names[#names + 1] = "'" .. c.name .. "'"
			end
		end
		local info = { delay = delay, valid = valid, delivered = next(delivered) ~= nil }
		log("S2_RESULT", { run = run, delay = delay, valid = table.concat(valid, ","),
			rejected = #rejections - (delay and 1 or 0), delivered = info.delivered })
		if not delay then
			done(false, ("no answer from the server within %d s"):format(MAX_WAIT), info)
		else
			done(#valid > 0, ("server answer delay %.0f s · valid: %s · %d rejected%s"):format(delay,
				#names > 0 and table.concat(names, ", ") or "none", #rejections - 1,
				info.delivered and " · delivered to yourself" or ""), info)
		end
	end)
	say("whisper test %s: %d spellings to %s", run, #list, target or short)
end

-- Sends n full-size frames, all at once ("burst") or every interval s ("pace").
-- Returns the run id; results are S1_TX (with ok) and S1_RX (with sentMs).
function Test.Throttle(mode, n, interval, channel, target)
	n = tonumber(n) or 30
	interval = tonumber(interval) or 1
	channel = channel or (IsInGuild() and "GUILD") or "WHISPER"
	if channel == "WHISPER" then target = target or UnitName("player") end
	local run = randomId()
	local pad = string.rep("x", 200)
	local function one(seq)
		local text = ("S1|%s|%d|%d|%s"):format(run, seq, ns.NowMs(), pad):sub(1, 255)
		local _, name, ok = rawSend(text, channel, target)
		log("S1_TX", { run = run, seq = seq, res = name, ok = ok })
	end
	log("S1_START", { run = run, mode = mode, count = n, interval = interval, ch = channel, to = target })
	if mode == "pace" then
		local seq = 0
		C_Timer.NewTicker(interval, function()
			seq = seq + 1
			one(seq)
		end, n)
	else
		for seq = 1, n do one(seq) end
	end
	return run
end

-- Waits until all accepted frames of a throttle run came back (or timeout), then
-- reports counts and latency. done(ok, text).
local function awaitThrottle(run, since, expected, timeout, done)
	local started = GetTime()
	C_Timer.NewTicker(1, function(ticker)
		local sent = count("S1_TX", since, function(d) return d.run == run and d.ok end)
		local refused = count("S1_TX", since, function(d) return d.run == run and not d.ok end)
		local rx = records("S1_RX", since, function(d) return d.run == run end)
		local sentAll = sent + refused >= expected
		if not (sentAll and #rx >= sent) and GetTime() - started < timeout then return end
		ticker:Cancel()
		local minL, maxL, sum = math.huge, 0, 0
		for _, r in ipairs(rx) do
			local l = (r[2] - r[6].sentMs) / 1000
			minL, maxL, sum = math.min(minL, l), math.max(maxL, l), sum + l
		end
		log("ALL_THROTTLE", { run = run, sent = sent, refused = refused, received = #rx,
			latencyMin = #rx > 0 and minL or nil, latencyMax = #rx > 0 and maxL or nil })
		local latency = #rx > 0 and (" · latency %.1f–%.1f s"):format(minL, maxL) or ""
		done(sent > 0 and #rx > 0, ("%d accepted, %d refused, %d came back%s"):format(sent, refused, #rx, latency))
	end)
end

-- Logs every change of the messaging restrictions (until /reload).
local lockTicker
function Test.Lockdown(on)
	if lockTicker then lockTicker:Cancel() lockTicker = nil end
	if not on then return end
	local last, n = "", 0
	lockTicker = C_Timer.NewTicker(1, function()
		local r = C_ChatInfo.AreOutgoingAddonChatMessagesRestricted
		local ok, restricted = false, nil
		if r then ok, restricted = pcall(r) end
		local s = {
			lockdown = C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() or false,
			restricted = ok and restricted or false,
			combat = InCombatLockdown(),
			encounter = IsEncounterInProgress and IsEncounterInProgress() or false,
			instance = select(2, IsInInstance()),
		}
		local key = ns.LogDataText(s)
		n = n + 1
		if key ~= last then
			last = key
			log("S3_STATE", s)
		end
		-- Every 5 s during real lockdown or an encounter, try a send to see what happens.
		if n % 5 == 0 and (s.lockdown or s.encounter) then
			local ch = IsInRaid() and "RAID" or IsInGroup() and "PARTY" or (IsInGuild() and "GUILD")
			if ch then
				local _, name = rawSend("S3|probe", ch)
				log("S3_PROBE", { ch = ch, res = name })
			end
		end
	end)
end

-- Logs what fires during normal play (dungeons, quests, trades …) until /reload.
local EVENTS = {
	"ENCOUNTER_START", "ENCOUNTER_END", "BOSS_KILL", "PLAYER_XP_UPDATE", "QUEST_TURNED_IN",
	"PLAYER_FLAGS_CHANGED", "ZONE_CHANGED_NEW_AREA", "GROUP_ROSTER_UPDATE", "PLAYER_LEVEL_UP",
	"TRADE_SHOW", "TRADE_ACCEPT_UPDATE", "TRADE_CLOSED", "UI_INFO_MESSAGE",
	"MAIL_SEND_SUCCESS", "MAIL_FAILED", "GUILDBANKBAGSLOTS_CHANGED", "GUILDBANKLOG_UPDATE",
	"RESURRECT_REQUEST", "PLAYER_ALIVE", "PLAYER_UNGHOST",
	"CHAT_MSG_SYSTEM", "CHAT_MSG_LOOT", "CHAT_MSG_COMBAT_XP_GAIN", "CHAT_MSG_SKILL",
	"CALENDAR_UPDATE_EVENT_LIST",
}
local eventFrame

function Test.Events(on)
	if not on then
		if eventFrame then eventFrame:UnregisterAllEvents() end
		return 0, 0
	end
	eventFrame = eventFrame or CreateFrame("Frame")
	eventFrame:UnregisterAllEvents()
	local missing = {}
	for _, ev in ipairs(EVENTS) do
		if not pcall(eventFrame.RegisterEvent, eventFrame, ev) then missing[#missing + 1] = ev end
	end
	-- Own casts only; other units would flood the log.
	pcall(eventFrame.RegisterUnitEvent, eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player")
	eventFrame:SetScript("OnEvent", function(_, event, ...)
		ns.Safe(function(...)
			local data = {}
			for i = 1, math.min(select("#", ...), 8) do data["a" .. i] = describe((select(i, ...))) end
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
	return #EVENTS - #missing, #missing
end

---------------------------------------------------------------------------
-- Pipeline (/kin test)
---------------------------------------------------------------------------
local C_STEP, C_OK, C_FAIL, C_SKIP, C_DIM = "|cff7fbfff", "|cff40ff40", "|cffff4040", "|cff999999", "|cffbbbbbb"
local running = false

local function out(fmt, ...)
	ns.Print(fmt, ...)
end

-- A step: { name, needs = function -> skip reason or nil, timeout = s, run = function(done, progress) }.
-- run calls done(ok, text) exactly once; progress(text) prints an indented status line.
local function buildSteps(ctx)
	local function route()
		if IsInGuild() then return "GUILD", nil, "guild chat" end
		return "CHANNEL", ctx.chanIndex, "test channel"
	end
	local function needRoute()
		if not IsInGuild() and not ctx.chanIndex then return "no guild and no test channel" end
	end
	return {
		{ name = "Encoding", run = function(done) done(Test.Codec()) end },
		{ name = "Identity", run = function(done) done(Test.Ids()) end },
		{ name = "Calendar", timeout = 10, run = function(done) Test.Calendar(done) end },
		{ name = "Private test channel", timeout = 15,
			needs = function() if IsInGuild() then return "in a guild, guild chat is used instead" end end,
			run = function(done)
				Test.JoinChannel(function(index, name)
					ctx.chanIndex, ctx.chanName = index, name
					done(index ~= nil, index and ("joined #%d (left again at the end)"):format(index) or "could not join")
				end)
			end },
		{ name = "Whisper name spellings", timeout = MAX_WAIT + 40, run = function(done, progress)
			Test.Whisper(nil, function(ok, text, info)
				ctx.whisper = info
				done(ok, text)
			end, progress)
		end },
		{ name = "Whisper to another player", needs = function()
			return "needs a second player with Kinship"
		end },
		{ name = "Message burst (30)", timeout = 60, needs = needRoute, run = function(done)
			local channel, target, label = route()
			local since = ns.NowMs()
			local run = Test.Throttle("burst", 30, nil, channel, target)
			awaitThrottle(run, since, 30, 50, function(ok, text) done(ok, label .. ": " .. text) end)
		end },
		{ name = "Message pace (20 every 0.5 s)", timeout = 75, needs = needRoute, run = function(done)
			local channel, target, label = route()
			-- Let the burst allowance refill first.
			C_Timer.After(3, function()
				local since = ns.NowMs()
				local run = Test.Throttle("pace", 20, 0.5, channel, target)
				awaitThrottle(run, since, 20, 60, function(ok, text) done(ok, label .. ": " .. text) end)
			end)
		end },
		{ name = "Report round trip", timeout = 180, needs = needRoute, run = function(done, progress)
			local channel, target, label = route()
			local since = ns.NowMs()
			ns.Report.activeHandle = nil
			ns.Report.Send(UnitName("player"), 1, channel, target)
			local lastQuarter = 0
			local ticker
			ticker = C_Timer.NewTicker(1, function()
				local h = ns.Report.activeHandle
				if h and h.parts > 0 then
					local quarter = math.floor(h.sent / h.parts * 4)
					if quarter > lastQuarter and quarter < 4 then
						lastQuarter = quarter
						progress(("%d%% of %d parts sent"):format(quarter * 25, h.parts))
					end
				end
				if count("REPORT_RECEIVED", since) > 0 then
					ticker:Cancel()
					done(true, ("%s: received (%s parts, %d s)"):format(label, h and h.parts or "?",
						math.floor((ns.NowMs() - since) / 1000)))
				end
			end)
			ctx.cancel[#ctx.cancel + 1] = function() ticker:Cancel() end
		end },
		{ name = "Start gameplay logging", run = function(done)
			local events, missing = Test.Events(true)
			Test.Lockdown(true)
			done(true, ("%d game events%s + messaging lockdown, until /reload"):format(events,
				missing > 0 and (" (%d unknown)"):format(missing) or ""))
		end },
	}
end

function Test.All()
	if running then
		out("a test run is already in progress.")
		return
	end
	running = true
	local startMs = ns.NowMs()
	local ctx = { cancel = {} }
	local steps = buildSteps(ctx)
	local total = #steps
	local passed, failed, skipped = 0, 0, 0
	local hadLoopback = KinshipDB.settings.loopback

	local where = IsInGuild() and ("guild " .. (GetGuildInfo("player") or "?")) or "no guild"
	local group = IsInRaid() and "raid" or IsInGroup() and "group" or "solo"
	out("%s▶ Kinship test|r · v%s · %s · %s · takes 3–5 min on the beta (slow server answers)", C_STEP, ns.version, where, group)
	log("ALL_START", { guild = IsInGuild(), group = group, steps = total })

	quiet = true
	ns.Report.quiet = true
	ns.Report.autoAcceptSelf = true
	-- Loopback: one client processes its own messages like a peer's.
	KinshipDB.settings.loopback = true

	local function finish()
		quiet = false
		ns.Report.quiet = false
		ns.Report.autoAcceptSelf = false
		KinshipDB.settings.loopback = hadLoopback
		Test.LeaveChannel(ctx.chanName)
		running = false
		local secs = math.floor((ns.NowMs() - startMs) / 1000)
		local errors = count("LUA_ERROR", startMs)
		log("ALL_SUMMARY", { passed = passed, failed = failed, skipped = skipped, seconds = secs, errors = errors,
			comm = ns.Comm.stats })
		local color = failed > 0 and C_FAIL or C_OK
		out("%s■ %d passed · %d failed · %d skipped · %dm %02ds%s|r", color, passed, failed, skipped,
			math.floor(secs / 60), secs % 60, errors > 0 and (" · %d errors"):format(errors) or "")
		out("Done. Type |cffffff00/reload|r to save the results — or keep playing first, gameplay is logged until then.")
	end

	local function runStep(i)
		local step = steps[i]
		if not step then
			finish()
			return
		end
		local label = ("%s[%d/%d]|r %s"):format(C_STEP, i, total, step.name)
		local reason = step.needs and step.needs()
		if reason then
			skipped = skipped + 1
			out("%s  %sSKIP|r %s(%s)|r", label, C_SKIP, C_DIM, reason)
			log("ALL_STEP", { n = i, step = step.name, result = "skip", text = reason })
			runStep(i + 1)
			return
		end
		if step.timeout then out("%s  %s… running|r", label, C_DIM) end
		local finished = false
		local function progress(text)
			if not finished then out("      %s%s|r", C_DIM, text) end
		end
		local function done(ok, text)
			if finished then return end
			finished = true
			if ok then passed = passed + 1 else failed = failed + 1 end
			out("%s  %s|r %s%s|r", label, ok and (C_OK .. "OK") or (C_FAIL .. "FAIL"), C_DIM, text or "")
			log("ALL_STEP", { n = i, step = step.name, result = ok and "ok" or "fail", text = text })
			C_Timer.After(0.5, function() runStep(i + 1) end)
		end
		if step.timeout then
			C_Timer.After(step.timeout, function()
				if not finished then
					for _, cancel in ipairs(ctx.cancel) do pcall(cancel) end
					done(false, ("timed out after %d s"):format(step.timeout))
				end
			end)
		end
		local ok, err = ns.Safe(step.run, done, progress)
		if not ok then done(false, "error: " .. tostring(err)) end
	end

	C_Timer.After(0.2, function() runStep(1) end)
end

---------------------------------------------------------------------------
-- Receiver side of the message tests (always active, cheap).
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
		-- Answer only other players; yourself would just whisper yourself again.
		if not ns.IsMe(sender) then
			local _, name = rawSend(("S2R|%s|%s"):format(run, variant), "WHISPER", sender)
			log("S2_REPLY", { run = run, to = sender, res = name })
		end
	elseif kind == "S2R" then
		local run, variant = rest:match("^(%w+)|?(%w*)")
		log("S2_PONG", { run = run, variant = variant, from = sender, ch = channel })
		say("whisper test %s: reply for '%s' from %s", run, variant, sender)
	end
end

ns.OnLoad(function()
	C_ChatInfo.RegisterAddonMessagePrefix(TPREFIX)
	ns.On("CHAT_MSG_ADDON", onTestMessage)
	ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", systemFilter)
	ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE", channelNoticeFilter)
	ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE_USER", channelNoticeFilter)
	-- Loopback is a test-only state; never carry it over a reload.
	KinshipDB.settings.loopback = nil
	KinshipDB.settings.testEvents, KinshipDB.settings.testLockdown = nil, nil
end)
