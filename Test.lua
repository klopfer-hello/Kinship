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

-- Counts this session's test/report records with `code` written after sinceMs.
local function count(code, sinceMs, match)
	local n = 0
	for _, r in ipairs(ns.logSession.records) do
		if r[5] == code and r[2] >= sinceMs and (not match or match(r[6])) then n = n + 1 end
	end
	return n
end

local function describe(v)
	if issecretvalue and issecretvalue(v) then return "<secret>" end
	return v == nil and "nil" or tostring(v)
end

---------------------------------------------------------------------------
-- Single checks. Each logs its details and returns a short result.
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
	local data = { one = { cbor = c1, deflate = z1, b64 = b1 },
		batch60 = { cbor = cN, deflate = zN, b64 = bN, perEntry = math.floor(bN / 60) },
		roundtripMs = ms, roundtripOk = ok }
	log("S4_CODEC", data)
	local text = ("1 entry %d B, batch of 60 %d B (%d B each), %.1f ms"):format(b1, bN, math.floor(bN / 60), ms)
	say("codec: %s, round trip %s", text, ok and "ok" or "BROKEN")
	return ok, text
end

-- What the client tells us about names, realms and GUIDs.
function Test.Ids()
	local name, realm = UnitFullName("player")
	local player = {
		unitName = describe(UnitName("player")), fullName = describe(name), fullRealm = describe(realm),
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
	local text = ("name %s, realm %s, GUID %s%s"):format(player.fullName, player.normalizedRealm,
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

-- Sends a whisper test to several spellings of target (default: yourself).
-- The receiver answers; replies are logged as S2_PONG.
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
	local sent = 0
	for label, name in pairs(variants) do
		local _, resName = rawSend(("S2|%s|%s|%s"):format(run, label, name), "WHISPER", name)
		log("S2_TX", { run = run, variant = label, target = name, res = resName })
		sent = sent + 1
	end
	if IsInGuild() and not ns.IsMe(target) then
		rawSend(("S2G|%s|%s"):format(run, short), "GUILD")
	end
	say("whisper test %s sent to %s (%d spellings)", run, target, sent)
	return run, sent
end

-- Where solo-friendly traffic goes: GUILD when in a guild, otherwise a whisper to
-- yourself; "CHANNEL" + name uses a custom chat channel you joined.
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

-- Sends count full-size frames, all at once ("burst") or every interval s ("pace").
-- Returns the run id; results are S1_TX (with res) and S1_RX records.
function Test.Throttle(mode, count_, interval, channelArg, targetArg)
	local n = tonumber(count_) or 30
	interval = tonumber(interval) or 1
	local channel, target, err = testRoute(channelArg, targetArg)
	if not channel then
		say(err)
		return nil
	end
	local run = ("%x"):format(math.random(0, 0xffff))
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
	return run, channel
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
		-- Every 5 s while restricted, try a real send to see what happens to it.
		if n % 5 == 0 and (s.lockdown or s.restricted or s.encounter) then
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

-- Step: { name, needs = optional function -> nil or skip reason, run = function(done) }
-- run calls done(ok, text) exactly once; a step that does not finish within
-- `timeout` seconds fails.
local function buildSteps(ctx)
	return {
		{ name = "Encoding", run = function(done) done(Test.Codec()) end },
		{ name = "Identity", run = function(done) done(Test.Ids()) end },
		{ name = "Calendar", timeout = 10, run = function(done) Test.Calendar(done) end },
		{ name = "Whisper to yourself", timeout = 10, run = function(done)
			local since = ns.NowMs()
			local run, sent = Test.Whisper(UnitName("player"))
			C_Timer.After(6, function()
				local got = count("S2_PONG", since, function(d) return d and d.run == run end)
				done(got > 0, ("%d of %d spellings answered"):format(got, sent))
			end)
		end },
		{ name = "Whisper delivery to others", needs = function()
			return "needs a second player with Kinship (run /kin test on both)"
		end },
		{ name = "Message burst (30)", timeout = 15, run = function(done)
			local since = ns.NowMs()
			local run, channel = Test.Throttle("burst", 30)
			C_Timer.After(6, function()
				local okSent = count("S1_TX", since, function(d) return d.run == run and d.ok end)
				local throttled = count("S1_TX", since, function(d) return d.run == run and not d.ok end)
				local got = count("S1_RX", since, function(d) return d.run == run end)
				log("ALL_BURST", { run = run, ch = channel, ok = okSent, throttled = throttled, received = got })
				done(okSent > 0, ("%s: %d accepted, %d refused, %d received"):format(channel, okSent, throttled, got))
			end)
		end },
		{ name = "Message pace (20 × 0.5 s)", timeout = 20, run = function(done)
			-- Let the burst allowance refill first.
			C_Timer.After(3, function()
				local since = ns.NowMs()
				local run, channel = Test.Throttle("pace", 20, 0.5)
				C_Timer.After(13, function()
					local okSent = count("S1_TX", since, function(d) return d.run == run and d.ok end)
					local got = count("S1_RX", since, function(d) return d.run == run end)
					log("ALL_PACE", { run = run, ch = channel, ok = okSent, received = got })
					done(okSent == 20, ("%s: %d of 20 accepted, %d received"):format(channel, okSent, got))
				end)
			end)
		end },
		{ name = "Report round trip", timeout = 180, run = function(done)
			local since = ns.NowMs()
			ns.Report.activeHandle = nil
			ns.Report.Send(UnitName("player"), 1)
			local lastQuarter = 0
			local ticker
			ticker = C_Timer.NewTicker(1, function()
				local h = ns.Report.activeHandle
				if h and h.parts > 0 then
					local quarter = math.floor(h.sent / h.parts * 4)
					if quarter > lastQuarter and quarter < 4 then
						lastQuarter = quarter
						out("      %s… %d%% of %d parts sent|r", C_DIM, quarter * 25, h.parts)
					end
				end
				if count("REPORT_RECEIVED", since) > 0 then
					ticker:Cancel()
					local secs = math.floor((ns.NowMs() - since) / 1000)
					done(true, ("received (%s parts, %d s)"):format(h and h.parts or "?", secs))
				elseif count("OFFER_TIMEOUT", since) > 0 and not IsInGuild() then
					ticker:Cancel()
					done(false, "offer not answered (self-whisper did not arrive)")
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

	-- Plan: who is around decides what can run.
	local where = IsInGuild() and ("guild " .. (GetGuildInfo("player") or "?")) or "no guild"
	local group = IsInRaid() and "raid" or IsInGroup() and "group" or "solo"
	out("%s▶ Kinship test|r · v%s · %s · %s", C_STEP, ns.version, where, group)
	log("ALL_START", { guild = IsInGuild(), group = group, steps = total })

	quiet = true
	ns.Report.quiet = true
	ns.Report.autoAcceptSelf = true
	-- Loopback lets one client receive its own whispers and report.
	KinshipDB.settings.loopback = true

	local function finish()
		quiet = false
		ns.Report.quiet = false
		ns.Report.autoAcceptSelf = false
		KinshipDB.settings.loopback = hadLoopback
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
		local ok, err = ns.Safe(step.run, done)
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
		say("whisper test %s: reply via %s for '%s' from %s", run, channel, variant ~= "" and variant or "guild", sender)
	end
end

ns.OnLoad(function()
	C_ChatInfo.RegisterAddonMessagePrefix(TPREFIX)
	ns.On("CHAT_MSG_ADDON", onTestMessage)
	-- Loopback is a test-only state; never carry it over a reload.
	KinshipDB.settings.loopback = nil
	KinshipDB.settings.testEvents, KinshipDB.settings.testLockdown = nil, nil
end)
