-- Persistent structured log (KinshipLog SavedVariable) and error capture.
-- Record layout (positional, compact in SavedVariables):
--   { serverTime, preciseMs, level, category, code, data }

local _, ns = ...

local LEVELS = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5 }
local LEVEL_NAMES = { "ERROR", "WARN", "INFO", "DEBUG", "TRACE" }
ns.LOG_LEVELS, ns.LOG_LEVEL_NAMES = LEVELS, LEVEL_NAMES

ns.LOG_CATEGORIES = { "core", "comm", "sync", "ledger", "deed", "fold", "loot", "ui", "report", "test" }
local DEV_DEFAULT_DEBUG = { comm = true, sync = true, report = true, test = true }

local MAX_RECORDS = ns.isDev and 10000 or 5000
local MAX_SESSIONS = 20

-- The current session exists before SavedVariables load; it is attached to
-- KinshipLog in OnLoad, so records written during file load are kept.
local session = {
	header = {
		version = ns.version,
		startServer = GetServerTime(),
		startMs = ns.NowMs(),
	},
	records = {},
}
ns.logSession = session

local debugCats = {}   -- category -> true when DEBUG/TRACE is recorded
local echoCats = {}    -- category -> true when records are also printed to chat
local total = 0        -- records across all stored sessions

local function trim()
	local log = KinshipLog
	if not log then return end
	while total > MAX_RECORDS and #log.sessions > 1 do
		total = total - #table.remove(log.sessions, 1).records
	end
	if total > MAX_RECORDS then
		-- Only the current session is left: keep its newest records.
		local recs, keep = session.records, math.floor(MAX_RECORDS * 0.9)
		local fresh, first = {}, #recs - keep + 1
		for i = first, #recs do fresh[#fresh + 1] = recs[i] end
		session.dropped = (session.dropped or 0) + (first - 1)
		session.records = fresh
		total = #fresh
	end
end

function ns.Log(level, category, code, data)
	local lv = LEVELS[level] or 3
	if lv > 3 and not debugCats[category] then return end
	local recs = session.records
	recs[#recs + 1] = { GetServerTime(), ns.NowMs(), lv, category, code, data }
	total = total + 1
	if total > MAX_RECORDS * 1.1 then trim() end
	if echoCats[category] then
		ns.Print("|cff999999[%s %s]|r %s %s", LEVEL_NAMES[lv], category, code, ns.LogDataText(data))
	end
end

-- Compact one-line rendering of a record's data table.
function ns.LogDataText(data)
	if type(data) ~= "table" then return data ~= nil and tostring(data) or "" end
	local parts = {}
	for k, v in pairs(data) do
		if type(v) == "table" then v = "{" .. ns.LogDataText(v) .. "}" end
		parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
	end
	table.sort(parts)
	return table.concat(parts, " ")
end

function ns.SetDebug(category, on)
	local saved = KinshipDB.settings.debug
	if category == "all" then
		for _, cat in ipairs(ns.LOG_CATEGORIES) do saved[cat] = on end
	else
		saved[category] = on
	end
	for cat, v in pairs(saved) do debugCats[cat] = v or nil end
end

function ns.IsDebug(category) return debugCats[category] == true end

function ns.SetEcho(category, on) echoCats[category] = on or nil end

---------------------------------------------------------------------------
-- Errors
---------------------------------------------------------------------------
local seenErrors = {}
local hinted = false

function ns.OnError(err)
	local msg = tostring(err)
	local n = (seenErrors[msg] or 0) + 1
	seenErrors[msg] = n
	if n <= 5 then
		ns.Log("ERROR", "core", "LUA_ERROR", { msg = msg, stack = debugstack(2, 12, 0), n = n })
	end
	if not hinted then
		hinted = true
		ns.Print("an internal error was logged. Please send a report: /kin report")
	end
	-- Hand the error to BugSack too, when the player uses it.
	if C_AddOns.IsAddOnLoaded("BugSack") then
		geterrorhandler()(err)
	end
	return err
end

---------------------------------------------------------------------------
-- Load: attach the session, apply debug settings
---------------------------------------------------------------------------
ns.OnLoad(function()
	KinshipLog = KinshipLog or {}
	local log = KinshipLog
	log.sessions = log.sessions or {}
	log.inbox = log.inbox or {}

	local s = KinshipDB.settings
	if not s.debug then
		s.debug = {}
		if ns.isDev then
			for cat in pairs(DEV_DEFAULT_DEBUG) do s.debug[cat] = true end
		end
	end
	for cat, v in pairs(s.debug) do debugCats[cat] = v or nil end

	local sessions = log.sessions
	sessions[#sessions + 1] = session
	while #sessions > MAX_SESSIONS do table.remove(sessions, 1) end
	total = 0
	for i = 1, #sessions do total = total + #sessions[i].records end
	trim()
end)

ns.OnLogin(function()
	local h = session.header
	local name, realm = UnitFullName("player")
	h.build, h.buildNumber, h.buildDate, h.interface = GetBuildInfo()
	h.locale = GetLocale()
	h.char, h.realm = ns.Plain(name), ns.Plain(realm)
	h.normalizedRealm = GetNormalizedRealmName()
	h.guid = UnitGUID("player")
	h.guild = GetGuildInfo("player")
	h.class = select(2, UnitClass("player"))
	h.level = UnitLevel("player")
	local addons = {}
	for i = 1, C_AddOns.GetNumAddOns() do
		if C_AddOns.IsAddOnLoaded(i) then addons[#addons + 1] = C_AddOns.GetAddOnInfo(i) end
	end
	h.addons = addons

	-- Anchor precise time to the moment the server second ticks over, so logs of
	-- different clients line up to about one frame instead of one second.
	local startSecond = GetServerTime()
	local anchor = CreateFrame("Frame")
	anchor:SetScript("OnUpdate", function(self)
		local now = GetServerTime()
		if now ~= startSecond then
			h.anchorServer, h.anchorMs = now, ns.NowMs()
			self:SetScript("OnUpdate", nil)
		end
	end)

	ns.Log("INFO", "core", "SESSION_START", { version = ns.version, dev = ns.isDev })
end)

ns.On("PLAYER_LOGOUT", function()
	ns.Log("INFO", "core", "SESSION_END", nil)
end)
