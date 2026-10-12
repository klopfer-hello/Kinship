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

-- Whisper spellings. Forever characters have a first name and a surname, and the
-- beta server delivers whispers and channel messages about a minute late
-- (measured 2026-10-12). So the test only sends here; Test.WhisperResult()
-- evaluates whatever has come back so far:
-- 1. a name that cannot exist measures the server's "no player named" delay,
-- 2. every plausible spelling is sent SPACING s apart,
-- 3. each rejection is credited to the spelling sent `delay` s earlier,
-- 4. spellings that reach yourself (loopback) count as delivered, with latency.
local SPACING = 4

local function guildFullName(short)
	if not IsInGuild() then return nil end
	for i = 1, GetNumGuildMembers() do
		local full = GetGuildRosterInfo(i)
		if full and ns.SameName(full, short) then return full end
	end
end

function Test.WhisperSend(target)
	local first, surname = ns.NameParts(target or ns.MyName())
	local candidates = {}
	if surname then
		candidates[#candidates + 1] = { "nameDashSurname", first .. "-" .. surname }
		candidates[#candidates + 1] = { "nameSurname", first .. " " .. surname }
	end
	candidates[#candidates + 1] = { "typed", target }
	candidates[#candidates + 1] = { "first", first }
	candidates[#candidates + 1] = { "withRealm", first .. "-" .. GetNormalizedRealmName() }
	candidates[#candidates + 1] = { "roster", guildFullName(first) }

	local st = { run = randomId(), list = {}, rejections = {}, startedMs = ns.NowMs() }
	local seen = {}
	for _, c in ipairs(candidates) do
		if c[2] and not seen[c[2]] then
			seen[c[2]] = true
			st.list[#st.list + 1] = { label = c[1], name = c[2] }
		end
	end
	st.probe = { label = "probe", name = "Zq" .. randomId():gsub("%d", "x") .. "kin" }

	local listener = CreateFrame("Frame")
	listener:RegisterEvent("CHAT_MSG_SYSTEM")
	listener:SetScript("OnEvent", function(_, _, msg)
		if type(msg) == "string" and msg:match(notFoundPattern()) then
			st.rejections[#st.rejections + 1] = GetTime()
			log("S2_REJECT", { run = st.run, msg = msg })
		end
	end)
	st.listener = listener
	hideChatNoise(300)

	local function send(c)
		c.at, c.atMs = GetTime(), ns.NowMs()
		local _, resName = rawSend(("S2|%s|%s|%s"):format(st.run, c.label, c.name), "WHISPER", c.name)
		log("S2_TX", { run = st.run, variant = c.label, target = c.name, res = resName })
	end
	send(st.probe)
	for i, c in ipairs(st.list) do
		C_Timer.After(i * SPACING, function() send(c) end)
	end
	st.sendSeconds = #st.list * SPACING
	return st
end

-- Evaluates a whisper test. final = stop listening and report what is known.
-- Returns complete (bool), ok (bool), text.
function Test.WhisperResult(st, final)
	local delay = st.rejections[1] and st.probe.at and (st.rejections[1] - st.probe.at) or nil
	local rejected = {}
	if delay then
		for k = 2, #st.rejections do
			for _, c in ipairs(st.list) do
				if c.at and math.abs(st.rejections[k] - delay - c.at) < SPACING / 2 then rejected[c.label] = true end
			end
		end
	end
	local latency = {}
	for _, r in ipairs(records("S2_RX", st.startedMs, function(d) return d.run == st.run end)) do
		for _, c in ipairs(st.list) do
			if c.label == r[6].variant and c.atMs then latency[c.label] = (r[2] - c.atMs) / 1000 end
		end
	end
	local delivered, refused, open = {}, {}, {}
	for _, c in ipairs(st.list) do
		if latency[c.label] then
			delivered[#delivered + 1] = ("'%s' (%.0f s)"):format(c.name, latency[c.label])
		elseif rejected[c.label] then
			refused[#refused + 1] = "'" .. c.name .. "'"
		else
			open[#open + 1] = "'" .. c.name .. "'"
		end
	end
	local complete = #open == 0
	if not complete and not final then return false end
	st.listener:UnregisterAllEvents()
	log("S2_RESULT", { run = st.run, delay = delay, delivered = table.concat(delivered, ","),
		rejected = table.concat(refused, ","), unanswered = table.concat(open, ",") })
	local parts = {}
	if #delivered > 0 then parts[#parts + 1] = "delivered " .. table.concat(delivered, ", ") end
	if #refused > 0 then parts[#parts + 1] = "rejected " .. table.concat(refused, ", ") end
	if #open > 0 then parts[#parts + 1] = "no answer " .. table.concat(open, ", ") end
	return true, #delivered > 0, table.concat(parts, " · ")
end

-- Sends n full-size frames, all at once ("burst") or every interval s ("pace").
-- Returns the run id; results are S1_TX (with ok) and S1_RX (with sentMs).
function Test.Throttle(mode, n, interval, channel, target)
	n = tonumber(n) or 30
	interval = tonumber(interval) or 1
	channel = channel or (IsInGuild() and "GUILD") or "WHISPER"
	if channel == "WHISPER" then target = ns.WhisperName(target or ns.MyName()) end
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

-- Send-side counts of a throttle run: accepted, refused, refusal codes.
local function throttleSent(run, since)
	local ok, refused, codes = 0, 0, {}
	for _, r in ipairs(records("S1_TX", since, function(d) return d.run == run end)) do
		if r[6].ok then
			ok = ok + 1
		else
			refused = refused + 1
			codes[r[6].res] = true
		end
	end
	local names = {}
	for code in pairs(codes) do names[#names + 1] = code end
	table.sort(names)
	return ok, refused, table.concat(names, ", ")
end

-- Receive side: complete (bool), ok (bool), text. final = report what is known.
local function throttleResult(run, since, final)
	local sent = throttleSent(run, since)
	local rx = records("S1_RX", since, function(d) return d.run == run end)
	local complete = #rx >= sent and sent > 0
	if not complete and not final then return false end
	local minL, maxL = math.huge, 0
	for _, r in ipairs(rx) do
		local l = (r[2] - r[6].sentMs) / 1000
		minL, maxL = math.min(minL, l), math.max(maxL, l)
	end
	log("ALL_THROTTLE_RX", { run = run, sent = sent, received = #rx,
		latencyMin = #rx > 0 and minL or nil, latencyMax = #rx > 0 and maxL or nil })
	return true, #rx > 0 and #rx >= sent, ("%d of %d came back%s"):format(#rx, sent,
		#rx > 0 and (" after %.0f–%.0f s"):format(minL, maxL) or "")
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
-- Tests with other players. Every Kinship client answers these automatically
-- (no popup, rate-limited, test data only), whether or not it runs a test itself.
-- Messages go through the real transport (ns.Comm):
--   XD discover (broadcast)     -> XH hello (to sender, same channel)
--   XW whisper ping             -> XV whisper pong
--   XQ receipt query            -> XR which test frames arrived
--   XT 4 KB transfer (whisper)  -> XA size + checksum confirmation
---------------------------------------------------------------------------
local MAX_PEERS = 2
local TRANSFER_SIZE = 4000
local activeRun          -- run id of the /kin test in progress (requester side)
local answered = {}      -- sender|type -> GetTime() of the last automatic answer

local function checksum(s)
	local h = 0
	for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
	return h
end

-- Automatic answers are limited to one per sender and type every `gap` seconds.
local function mayAnswer(sender, msgType, gap)
	local key, now = sender .. "|" .. msgType, GetTime()
	if answered[key] and now - answered[key] < gap then return false end
	answered[key] = now
	return true
end

local function discoveryChannels()
	local chans = {}
	if IsInGuild() then chans[#chans + 1] = "GUILD" end
	if IsInRaid() then chans[#chans + 1] = "RAID" elseif IsInGroup() then chans[#chans + 1] = "PARTY" end
	return chans
end

function Test.Discover(run)
	local chans = discoveryChannels()
	for _, ch in ipairs(chans) do
		ns.Comm.Send("XD", { run = run, v = ns.version }, ch, nil, ns.Comm.PRIO.ALERT)
	end
	log("PEER_DISCOVER", { run = run, channels = table.concat(chans, ",") })
	return chans
end

-- Players that answered the discovery of `run` (first answer per player).
local function peersOf(run)
	local peers = {}
	for _, r in ipairs(records("PEER_HELLO", 0, function(d) return d.run == run end)) do
		local d, known = r[6], false
		for _, p in ipairs(peers) do
			if ns.SameName(p.name, d.name) then known = true end
		end
		if not known then
			peers[#peers + 1] = { name = d.name, v = d.v, build = d.build, ch = d.ch, at = r[2] }
		end
	end
	return peers
end

-- Starts the three checks with one peer; results arrive as PEER_* log records.
function Test.PeerStart(run, peer, runs)
	local Comm = ns.Comm
	for seq = 1, 3 do
		C_Timer.After((seq - 1) * 2, function()
			Comm.Send("XW", { run = run, seq = seq, t = ns.NowMs() }, "WHISPER", peer.name, Comm.PRIO.ALERT)
		end)
	end
	Comm.Send("XQ", { run = run, runs = runs }, peer.ch, peer.name, Comm.PRIO.NORMAL)
	local chars = {}
	for i = 1, TRANSFER_SIZE do chars[i] = string.char(math.random(33, 126)) end
	local data = table.concat(chars)
	peer.transferMs = ns.NowMs()
	Comm.Send("XT", { run = run, data = data, sum = checksum(data) }, "WHISPER", peer.name, Comm.PRIO.BULK)
	log("PEER_START", { run = run, peer = peer.name, ch = peer.ch })
end

-- complete, ok, text for one peer's checks; final = report what is known.
local function peerResult(run, peer, final)
	local function mine(d) return d.run == run and ns.SameName(d.name, peer.name) end
	local pongs = records("PEER_PONG", 0, mine)
	local receipt = records("PEER_RECEIPT", 0, mine)[1]
	local ack = records("PEER_TRANSFER", 0, mine)[1]
	if not final and not (#pongs > 0 and receipt and ack) then return false end
	local parts, ok = {}, true
	if #pongs > 0 then
		local best = math.huge
		for _, r in ipairs(pongs) do best = math.min(best, r[6].rttMs) end
		parts[#parts + 1] = ("whisper round trip %.0f s (%d/3)"):format(best / 1000, #pongs)
	else
		ok = false
		parts[#parts + 1] = "no whisper answer"
	end
	if receipt then
		local d = receipt[6]
		local function fmt(key, label)
			local c = d.counts and d.counts[key]
			if c then parts[#parts + 1] = ("%s %d/%d arrived"):format(label, c.n, c.of or 0) end
		end
		fmt("burst", "burst")
		fmt("pace", "paced")
	else
		ok = false
		parts[#parts + 1] = "no receipt"
	end
	if ack then
		local d = ack[6]
		parts[#parts + 1] = ("%d B transfer %s in %.0f s"):format(d.bytes or 0, d.ok and "intact" or "CORRUPT",
			(ack[2] - (peer.transferMs or ack[2])) / 1000)
		ok = ok and d.ok
	else
		ok = false
		parts[#parts + 1] = "transfer not confirmed"
	end
	return true, ok, table.concat(parts, " · ")
end

function Test.RegisterPeerHandlers()
	local Comm = ns.Comm
	local PRIO = Comm.PRIO

	-- Responder: answer a discovery after a short random delay (spreads replies).
	Comm.Register("XD", function(p, sender, channel)
		if type(p) ~= "table" or not p.run or ns.IsMe(sender) or not mayAnswer(sender, "XD", 30) then return end
		log("PEER_ASKED", { run = p.run, from = sender, ch = channel })
		C_Timer.After(math.random() * 4, function()
			Comm.Send("XH", { run = p.run, v = ns.version, build = select(2, GetBuildInfo()), name = ns.MyName() },
				channel, sender, PRIO.ALERT)
		end)
	end)
	Comm.Register("XW", function(p, sender)
		if type(p) ~= "table" or not mayAnswer(sender, "XW" .. tostring(p.seq), 5) then return end
		Comm.Send("XV", p, "WHISPER", sender, PRIO.ALERT)
	end)
	Comm.Register("XQ", function(p, sender, channel)
		if type(p) ~= "table" or type(p.runs) ~= "table" or not mayAnswer(sender, "XQ", 30) then return end
		local counts = {}
		for key, info in pairs(p.runs) do
			if type(info) == "table" and info.run then
				local rx = records("S1_RX", 0, function(d) return d.run == info.run end)
				counts[key] = { n = #rx, of = info.sent }
			end
		end
		Comm.Send("XR", { run = p.run, counts = counts }, channel, sender, PRIO.NORMAL)
	end)
	Comm.Register("XT", function(p, sender)
		if type(p) ~= "table" or type(p.data) ~= "string" or #p.data > 16000 or not mayAnswer(sender, "XT", 60) then return end
		Comm.Send("XA", { run = p.run, bytes = #p.data, ok = checksum(p.data) == p.sum }, "WHISPER", sender, PRIO.ALERT)
	end)

	-- Requester: record answers that belong to the running test.
	local function forMe(p) return type(p) == "table" and activeRun and p.run == activeRun end
	Comm.Register("XH", function(p, sender, channel)
		if forMe(p) then log("PEER_HELLO", { run = p.run, name = sender, v = p.v, build = p.build, ch = channel }) end
	end)
	Comm.Register("XV", function(p, sender)
		if forMe(p) then log("PEER_PONG", { run = p.run, name = sender, seq = p.seq, rttMs = ns.NowMs() - p.t }) end
	end)
	Comm.Register("XR", function(p, sender)
		if forMe(p) then log("PEER_RECEIPT", { run = p.run, name = sender, counts = p.counts }) end
	end)
	Comm.Register("XA", function(p, sender)
		if forMe(p) then log("PEER_TRANSFER", { run = p.run, name = sender, bytes = p.bytes, ok = p.ok }) end
	end)
end

---------------------------------------------------------------------------
-- Pipeline (/kin test)
---------------------------------------------------------------------------
local C_STEP, C_OK, C_FAIL, C_SKIP, C_DIM = "|cff7fbfff", "|cff40ff40", "|cffff4040", "|cff999999", "|cffbbbbbb"
local running = false
local COLLECT_TIMEOUT = 360
local DISCOVERY_WAIT = 150   -- seconds after the discovery before "nobody answered"
local PEER_TIMEOUT = 300

local function out(fmt, ...)
	ns.Print(fmt, ...)
end

-- What this run can test, decided once at the start.
local function situation()
	local s = { guild = IsInGuild(), raid = IsInRaid(), group = IsInGroup() }
	s.groupChannel = s.raid and "RAID" or s.group and "PARTY" or nil
	-- Where own round trips go: guild chat, else group chat, else a private channel.
	if s.guild then
		s.route, s.routeLabel = "GUILD", "guild chat"
	elseif s.groupChannel then
		s.route, s.routeLabel = s.groupChannel, s.raid and "raid chat" or "party chat"
	else
		s.route, s.routeLabel = "CHANNEL", "test channel"
	end
	s.canDiscover = s.guild or s.group
	return s
end

-- A step: { name, needs = function -> skip reason or nil, timeout = s, run = function(done, progress, sub) }.
-- run calls done(ok, text) exactly once (ok == nil: neutral); progress(text) prints a
-- status line; sub(name, ok, text) prints and counts one check inside the step.
-- Message checks are split into quick "send" steps and one step that collects all
-- answers in parallel (the beta server delivers about a minute late).
local function buildSteps(ctx, sit)
	local function route()
		if sit.route == "CHANNEL" then return "CHANNEL", ctx.chanIndex, sit.routeLabel end
		return sit.route, nil, sit.routeLabel
	end
	local function needRoute()
		if sit.route == "CHANNEL" and not ctx.chanIndex then return "no guild, no group and no test channel" end
	end
	return {
		{ name = "Look for other Kinship players", needs = function()
			if not sit.canDiscover then return "not in a guild or group" end
		end, run = function(done)
			ctx.discoverMs = ns.NowMs()
			local chans = Test.Discover(ctx.run)
			done(true, ("asked %s; answers are collected later"):format(table.concat(chans, " + "):lower()))
		end },
		{ name = "Encoding", run = function(done) done(Test.Codec()) end },
		{ name = "Identity", run = function(done) done(Test.Ids()) end },
		{ name = "Calendar", timeout = 10, run = function(done) Test.Calendar(done) end },
		{ name = "Private test channel", timeout = 15, needs = function()
			if sit.route ~= "CHANNEL" then return sit.routeLabel .. " is used instead" end
		end, run = function(done)
			Test.JoinChannel(function(index, name)
				ctx.chanIndex, ctx.chanName = index, name
				done(index ~= nil, index and ("joined #%d (left again at the end)"):format(index) or "could not join")
			end)
		end },
		{ name = "Send whispers to yourself (name spellings)", timeout = 40, run = function(done)
			ctx.whisper = Test.WhisperSend(nil)
			C_Timer.After(ctx.whisper.sendSeconds + 0.5, function()
				done(true, ("%d spellings + 1 probe sent"):format(#ctx.whisper.list))
			end)
		end },
		{ name = "Send burst (30 at once)", needs = needRoute, run = function(done)
			local channel, target, label = route()
			ctx.burstSince = ns.NowMs()
			ctx.burst = Test.Throttle("burst", 30, nil, channel, target)
			local ok, refused, codes = throttleSent(ctx.burst, ctx.burstSince)
			ctx.burstSent = ok
			done(ok > 0, ("%s: %d accepted, %d refused%s"):format(label, ok, refused,
				refused > 0 and (" (" .. codes .. ")") or ""))
		end },
		{ name = "Send paced (15, one per second)", timeout = 40, needs = needRoute, run = function(done)
			local channel, target, label = route()
			-- Let the client allowance refill after the burst.
			C_Timer.After(10, function()
				ctx.paceSince = ns.NowMs()
				ctx.pace = Test.Throttle("pace", 15, 1, channel, target)
				C_Timer.After(16, function()
					local ok, refused, codes = throttleSent(ctx.pace, ctx.paceSince)
					ctx.paceSent = ok
					done(refused == 0, ("%s: %d accepted, %d refused%s"):format(label, ok, refused,
						refused > 0 and (" (" .. codes .. ")") or ""))
				end)
			end)
		end },
		{ name = "Send group echo (3)", needs = function()
			if not sit.groupChannel then return "not in a group" end
			if sit.route == sit.groupChannel then return "group chat is already the main route" end
		end, run = function(done)
			ctx.groupSince = ns.NowMs()
			ctx.groupRun = Test.Throttle("burst", 3, nil, sit.groupChannel)
			local ok = throttleSent(ctx.groupRun, ctx.groupSince)
			done(ok > 0, ("%s: %d of 3 accepted"):format(sit.groupChannel:lower(), ok))
		end },
		{ name = "Send report offer to yourself", needs = needRoute, run = function(done)
			local channel, target, label = route()
			ctx.reportSince = ns.NowMs()
			ns.Report.activeHandle = nil
			-- A small report (last 3 min) is enough to prove the transfer.
			ns.Report.Send(ns.MyName(), 0.05, channel, target)
			done(true, label .. ": offer sent (accept, transfer and receipt follow)")
		end },
		{ name = "Collect server answers", timeout = COLLECT_TIMEOUT + 10, run = function(done, progress, sub)
			local started, lastProgress = GetTime(), 0
			local results = {}
			local checks = {
				{ key = "whisper", label = "whispers to yourself", eval = function(final)
					return Test.WhisperResult(ctx.whisper, final)
				end },
				{ key = "burst", label = "burst", eval = function(final)
					if not ctx.burst then return true, nil, "not sent" end
					return throttleResult(ctx.burst, ctx.burstSince, final)
				end },
				{ key = "pace", label = "paced", eval = function(final)
					if not ctx.pace then return true, nil, "not sent" end
					return throttleResult(ctx.pace, ctx.paceSince, final)
				end },
				{ key = "group", label = "group echo", eval = function(final)
					if not ctx.groupRun then return true, nil, "not sent" end
					return throttleResult(ctx.groupRun, ctx.groupSince, final)
				end },
				{ key = "report", label = "report to yourself", eval = function(final)
					if not ctx.reportSince then return true, nil, "not sent" end
					if count("REPORT_RECEIVED", ctx.reportSince) > 0 then
						local h = ns.Report.activeHandle
						return true, true, ("round trip complete (%s parts, %d s)"):format(h and h.parts or "?",
							math.floor((ns.NowMs() - ctx.reportSince) / 1000))
					end
					if not final then return false end
					local stage = count("OFFER_ACCEPTED", ctx.reportSince) > 0 and "accepted, data not complete"
						or count("OFFER_RECEIVED", ctx.reportSince) > 0 and "offer arrived, acceptance did not come back"
						or "offer never arrived"
					return true, false, stage
				end },
				{ key = "peers", label = "other Kinship players", eval = function(final)
					if not ctx.discoverMs then return true, nil, "not searched" end
					local peers = peersOf(ctx.run)
					local waited = (ns.NowMs() - ctx.discoverMs) / 1000
					-- Done when someone answered and 15 s passed without a new answer, or after the wait.
					local settled = #peers > 0 and (ns.NowMs() - peers[#peers].at) / 1000 > 15
					if not (settled or waited >= DISCOVERY_WAIT or final) then return false end
					ctx.peers = peers
					if #peers == 0 then return true, nil, ("nobody answered within %d s"):format(waited) end
					local names = {}
					for _, p in ipairs(peers) do names[#names + 1] = ("%s (v%s)"):format(ns.ShortName(p.name), p.v or "?") end
					return true, true, ("%d found: %s"):format(#peers, table.concat(names, ", "))
				end },
			}
			local ticker
			ticker = C_Timer.NewTicker(1, function()
				local elapsed = GetTime() - started
				local final = elapsed >= COLLECT_TIMEOUT
				local open = {}
				for _, c in ipairs(checks) do
					if not results[c.key] then
						local complete, ok, text = c.eval(final)
						if complete then
							results[c.key] = true
							sub(c.label, ok, text)
						else
							open[#open + 1] = c.label
						end
					end
				end
				if #open == 0 then
					ticker:Cancel()
					done(nil, ("%d s"):format(elapsed))
				elseif elapsed - lastProgress >= 20 then
					lastProgress = elapsed
					progress(("%d s · still waiting for: %s"):format(elapsed, table.concat(open, ", ")))
				end
			end)
			ctx.cancel[#ctx.cancel + 1] = function() ticker:Cancel() end
		end },
		{ name = "Tests with other players", timeout = PEER_TIMEOUT + 10, needs = function()
			if not sit.canDiscover then return "not in a guild or group" end
			if not ctx.peers or #ctx.peers == 0 then return "nobody with Kinship answered" end
		end, run = function(done, progress, sub)
			local runs = {}
			if ctx.burst and sit.route ~= "CHANNEL" then runs.burst = { run = ctx.burst, sent = ctx.burstSent } end
			if ctx.pace and sit.route ~= "CHANNEL" then runs.pace = { run = ctx.pace, sent = ctx.paceSent } end
			local peers = {}
			for i = 1, math.min(MAX_PEERS, #ctx.peers) do peers[i] = ctx.peers[i] end
			for i, peer in ipairs(peers) do
				-- Stagger peers so their transfers don't share the send allowance.
				C_Timer.After((i - 1) * 20, function() Test.PeerStart(ctx.run, peer, runs) end)
			end
			local started, lastProgress, results = GetTime(), 0, {}
			local ticker
			ticker = C_Timer.NewTicker(1, function()
				local elapsed = GetTime() - started
				local final = elapsed >= PEER_TIMEOUT
				local open = {}
				for _, peer in ipairs(peers) do
					if not results[peer.name] then
						local complete, ok, text = peerResult(ctx.run, peer, final)
						if complete then
							results[peer.name] = true
							sub(ns.ShortName(peer.name), ok, text)
						else
							open[#open + 1] = ns.ShortName(peer.name)
						end
					end
				end
				if #open == 0 then
					ticker:Cancel()
					done(nil, ("%d player%s, %d s"):format(#peers, #peers == 1 and "" or "s", elapsed))
				elseif elapsed - lastProgress >= 20 then
					lastProgress = elapsed
					progress(("%d s · still waiting for: %s"):format(elapsed, table.concat(open, ", ")))
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
	local sit = situation()
	local ctx = { cancel = {}, run = randomId() .. randomId() }
	activeRun = ctx.run
	local steps = buildSteps(ctx, sit)
	local total = #steps
	local passed, failed, skipped = 0, 0, 0
	local hadLoopback = KinshipDB.settings.loopback

	local where = sit.guild and ("guild " .. (GetGuildInfo("player") or "?")) or "no guild"
	local group = sit.raid and "raid" or sit.group and "group" or "solo"
	local minutes = sit.canDiscover and "5–10" or "about 5"
	out("%s▶ Kinship test|r · v%s · %s · %s · round trips via %s · %s min (the beta delivers messages ~1 min late)",
		C_STEP, ns.version, where, group, sit.routeLabel, minutes)
	log("ALL_START", { run = ctx.run, guild = sit.guild, group = group, route = sit.route, steps = total })

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
		activeRun = nil
		running = false
		local secs = math.floor((ns.NowMs() - startMs) / 1000)
		local errors = count("LUA_ERROR", startMs)
		log("ALL_SUMMARY", { run = ctx.run, passed = passed, failed = failed, skipped = skipped, seconds = secs,
			errors = errors, comm = ns.Comm.stats })
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
		local function verdict(ok)
			if ok == nil then return C_SKIP .. "DONE" end
			return ok and (C_OK .. "OK") or (C_FAIL .. "FAIL")
		end
		-- Result line of one check inside a step (counted like a step).
		local function sub(name, ok, text)
			if ok == true then passed = passed + 1 elseif ok == false then failed = failed + 1 else skipped = skipped + 1 end
			out("      %s|r %s: %s%s|r", ok == nil and (C_SKIP .. "SKIP") or verdict(ok), name, C_DIM, text or "")
			log("ALL_CHECK", { n = i, check = name, result = ok == nil and "skip" or ok and "ok" or "fail", text = text })
		end
		local function done(ok, text)
			if finished then return end
			finished = true
			if ok == true then passed = passed + 1 elseif ok == false then failed = failed + 1 end
			out("%s  %s|r %s%s|r", label, verdict(ok), C_DIM, text or "")
			log("ALL_STEP", { n = i, step = step.name, result = ok == nil and "done" or ok and "ok" or "fail", text = text })
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
		local ok, err = ns.Safe(step.run, done, progress, sub)
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
	Test.RegisterPeerHandlers()
	ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", systemFilter)
	ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE", channelNoticeFilter)
	ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE_USER", channelNoticeFilter)
	-- Loopback is a test-only state; never carry it over a reload.
	KinshipDB.settings.loopback = nil
	KinshipDB.settings.testEvents, KinshipDB.settings.testLockdown = nil, nil
end)
