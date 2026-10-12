-- Kinship core: namespace, safe event dispatch, load/login hooks, small helpers.

local ADDON_NAME, ns = ...
Kinship = ns

ns.name = ADDON_NAME
ns.version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "dev"
-- Pre-release builds ("0.1.0-alpha", "dev") log more by default.
ns.isDev = ns.version == "dev" or ns.version:find("-", 1, true) ~= nil

-- Calls fn(...) through xpcall so one broken handler never breaks the caller.
-- ns.OnError is defined in Log.lua; it runs only when an error actually happens.
function ns.Safe(fn, ...)
	return xpcall(fn, ns.OnError, ...)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local handlers = {}
local eventFrame = CreateFrame("Frame")

-- Registers fn for event. Returns false if this client does not know the event
-- (registering an unknown event throws on the retail API).
function ns.On(event, fn)
	local list = handlers[event]
	if not list then
		if not pcall(eventFrame.RegisterEvent, eventFrame, event) then
			if ns.Log then ns.Log("WARN", "core", "EVENT_UNKNOWN", { event = event }) end
			return false
		end
		list = {}
		handlers[event] = list
	end
	list[#list + 1] = fn
	return true
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for i = 1, #list do
		ns.Safe(list[i], event, ...)
	end
end)

---------------------------------------------------------------------------
-- Load / login hooks (run in registration order, after SavedVariables exist)
---------------------------------------------------------------------------
local loadQueue, loginQueue = {}, {}
function ns.OnLoad(fn) loadQueue[#loadQueue + 1] = fn end
function ns.OnLogin(fn) loginQueue[#loginQueue + 1] = fn end

ns.On("ADDON_LOADED", function(_, name)
	if name ~= ADDON_NAME then return end
	KinshipDB = KinshipDB or {}
	KinshipDB.settings = KinshipDB.settings or {}
	KinshipCharDB = KinshipCharDB or {}
	for i = 1, #loadQueue do ns.Safe(loadQueue[i]) end
end)

ns.On("PLAYER_LOGIN", function()
	for i = 1, #loginQueue do ns.Safe(loginQueue[i]) end
end)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local PREFIX = "|cff7fbfffKinship|r: "
function ns.Print(fmt, ...)
	local msg = select("#", ...) > 0 and fmt:format(...) or fmt
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

function ns.NowMs()
	return math.floor(GetTimePreciseSec() * 1000)
end

-- Short name of a sender/target ("First Surname-Realm" -> "First Surname").
function ns.ShortName(name)
	if not name then return nil end
	return Ambiguate(name, "none"):match("^[^-]+") or name
end

function ns.IsMe(name)
	return name ~= nil and ns.ShortName(name) == UnitName("player")
end

-- Own messages are ignored, except in loopback test mode (/kin test loopback on),
-- which lets a single client without guild or group exercise the whole pipeline.
function ns.AcceptFrom(sender)
	return not ns.IsMe(sender) or KinshipDB.settings.loopback == true
end

-- Reads a value that may be a secret on this client; secrets become nil.
function ns.Plain(value)
	if issecretvalue and issecretvalue(value) then return nil end
	return value
end
