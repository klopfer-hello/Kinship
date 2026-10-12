-- Diagnostic reports: build, show for copy-paste, send to another player in game.
-- Report string = "!KIN-DIAG1!" .. ns.Encode(bundle); decode with scripts/kinship-diag.py.

local _, ns = ...

local Report = {}
ns.Report = Report

local TAG = "!KIN-DIAG1!"
local MAX_INBOX = 10
local OFFER_TIMEOUT = 120

-- Set by the test pipeline: chat output is suppressed, offers from yourself are
-- accepted without the popup, and the running transfer is exposed for progress.
Report.quiet = false
Report.autoAcceptSelf = false
Report.activeHandle = nil

local function say(...)
	if not Report.quiet then ns.Print(...) end
end

local outgoing = {}   -- offer id -> { bundle, target, channel, at }
local incoming = {}   -- offer id -> sender (accepted offers)

-- hours: only records from the last N hours (nil = everything stored).
function Report.Build(hours)
	local since = hours and (GetServerTime() - hours * 3600) or 0
	local sessions = {}
	for _, s in ipairs(KinshipLog.sessions) do
		local recs = {}
		for _, r in ipairs(s.records) do
			if r[1] >= since then recs[#recs + 1] = r end
		end
		if #recs > 0 or s == ns.logSession then
			sessions[#sessions + 1] = { header = s.header, records = recs, dropped = s.dropped }
		end
	end
	return {
		v = 1,
		from = UnitName("player"),
		created = GetServerTime(),
		hours = hours,
		status = ns.StatusSnapshot(),
		sessions = sessions,
	}
end

function Report.ToString(bundle)
	local text, err = ns.Encode(bundle)
	if not text then return nil, err end
	return TAG .. text
end

function Report.Show(hours)
	local text, err = Report.ToString(Report.Build(hours))
	if not text then
		say("could not build the report: %s", tostring(err))
		return
	end
	ns.Log("INFO", "report", "REPORT_SHOWN", { bytes = #text, hours = hours })
	ns.ShowText("Kinship report",
		("Ctrl+C to copy (%d KB), then paste it to the developer. Or send it in game: /kin report <name>")
			:format(math.ceil(#text / 1024)),
		text, true)
end

local function sizeText(bytes)
	local cfg = KinshipDB.settings.comm
	local frames = math.ceil(bytes / 230)
	local seconds = math.max(0, frames - cfg.burst) / cfg.rate
	return ("%d KB, about %d min"):format(math.ceil(bytes / 1024), math.ceil(seconds / 60))
end

-- route: "WHISPER" (default) or "GUILD" (addressed to target over guild chat).
-- route: "WHISPER" (default), "GUILD", or "CHANNEL" with chanIndex.
function Report.Send(target, hours, route, chanIndex)
	local channel = route or "WHISPER"
	local bundle = Report.Build(hours)
	local encoded = ns.Encode(bundle)
	if not encoded then
		say("could not build the report")
		return
	end
	local id = ("%x"):format(math.random(0, 0x7fffffff))
	outgoing[id] = { bundle = bundle, target = target, channel = channel, chanIndex = chanIndex, at = GetTime() }
	ns.Comm.Send("RO", { id = id, bytes = #encoded, hours = hours }, channel, target, ns.Comm.PRIO.NORMAL, chanIndex)
	ns.Log("INFO", "report", "OFFER_SENT", { id = id, to = target, ch = channel, bytes = #encoded })
	say("asked %s to accept a report (%s). Waiting for them…", target, sizeText(#encoded))
	C_Timer.After(OFFER_TIMEOUT, function()
		if not outgoing[id] or outgoing[id].accepted then return end
		outgoing[id] = nil
		ns.Log("WARN", "report", "OFFER_TIMEOUT", { id = id, to = target, ch = channel })
		-- Whispered addon messages may not arrive on this client: retry once via guild chat.
		if channel == "WHISPER" and IsInGuild() then
			say("no answer from %s by whisper — trying via guild chat.", target)
			Report.Send(target, hours, "GUILD")
		else
			say("%s did not answer. Do they have Kinship enabled and are they online?", target)
		end
	end)
end

-- Answers on the channel the message came from (addressed to its sender).
local function reply(msgType, payload, sender, channel, chanIndex)
	ns.Comm.Send(msgType, payload, channel, sender, ns.Comm.PRIO.ALERT, chanIndex)
end

local function acceptOffer(data)
	incoming[data.id] = data.sender
	reply("RA", { id = data.id, ok = true }, data.sender, data.channel, data.chanIndex)
	ns.Log("INFO", "report", "OFFER_ACCEPTED", { id = data.id, from = data.sender })
end

StaticPopupDialogs["KINSHIP_REPORT_OFFER"] = {
	text = "%s wants to send you a Kinship diagnostic report (%s).\nAccept it?",
	button1 = ACCEPT,
	button2 = DECLINE,
	OnAccept = function(self, data)
		acceptOffer(data or self.data)
	end,
	OnCancel = function(self, data)
		data = data or self.data
		reply("RA", { id = data.id, ok = false }, data.sender, data.channel, data.chanIndex)
	end,
	timeout = OFFER_TIMEOUT - 10,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

ns.OnLoad(function()
	local Comm = ns.Comm

	-- Receiver: an offer arrives.
	Comm.Register("RO", function(p, sender, channel, chanIndex)
		if type(p) ~= "table" or not p.id then return end
		ns.Log("INFO", "report", "OFFER_RECEIVED", { id = p.id, from = sender, ch = channel, bytes = p.bytes })
		if Report.autoAcceptSelf and ns.IsMe(sender) then
			acceptOffer({ id = p.id, sender = sender, channel = channel, chanIndex = chanIndex })
			return
		end
		StaticPopup_Show("KINSHIP_REPORT_OFFER", ns.ShortName(sender), sizeText(p.bytes or 0),
			{ id = p.id, sender = sender, channel = channel, chanIndex = chanIndex })
	end)

	-- Sender: the receiver answered.
	Comm.Register("RA", function(p, sender)
		local o = type(p) == "table" and outgoing[p.id]
		if not o or not ns.SameName(sender, o.target) then return end
		if not p.ok then
			outgoing[p.id] = nil
			say("%s declined the report.", o.target)
			return
		end
		o.accepted = true
		local nextPct = 25
		local h = Comm.Send("RD", { id = p.id, bundle = o.bundle }, o.channel, o.target, Comm.PRIO.BULK, o.chanIndex)
		if not h then
			say("sending the report failed (see /kin log)")
			return
		end
		Report.activeHandle = h
		say("%s accepted — sending %d parts in the background.", o.target, h.parts)
		h.onProgress = function(hh)
			local pct = math.floor(hh.sent / hh.parts * 100)
			if pct >= nextPct and hh.sent < hh.parts then
				say("report to %s: %d%%", o.target, pct)
				nextPct = nextPct + 25
			end
		end
		h.onDone = function()
			outgoing[p.id] = nil
			say("report sent to %s.", o.target)
			ns.Log("INFO", "report", "REPORT_SENT", { id = p.id, to = o.target, parts = h.parts })
		end
		h.onFail = function(_, res)
			outgoing[p.id] = nil
			say("sending the report to %s failed (%s).", o.target, tostring(res))
		end
	end)

	-- Receiver: the report itself.
	Comm.Register("RD", function(p, sender)
		if type(p) ~= "table" or not incoming[p.id] then return end
		incoming[p.id] = nil
		local text = Report.ToString(p.bundle)
		local inbox = KinshipLog.inbox
		inbox[#inbox + 1] = { from = sender, at = GetServerTime(), id = p.id, data = text }
		while #inbox > MAX_INBOX do table.remove(inbox, 1) end
		ns.Log("INFO", "report", "REPORT_RECEIVED", { id = p.id, from = sender, bytes = text and #text })
		say("received a report from %s — it is saved and will be written to disk on /reload or logout.", ns.ShortName(sender))
	end)
end)
