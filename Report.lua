-- Diagnostic reports: build, show for copy-paste, send to another player in game.
-- Report string = "!KIN-DIAG1!" .. ns.Encode(bundle); decode with scripts/kinship-diag.py.

local _, ns = ...

local Report = {}
ns.Report = Report

local TAG = "!KIN-DIAG1!"
local MAX_INBOX = 10
local OFFER_TIMEOUT = 120

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
		ns.Print("could not build the report: %s", tostring(err))
		return
	end
	ns.Log("INFO", "report", "REPORT_SHOWN", { bytes = #text, hours = hours })
	ns.ShowText("Kinship report",
		("Ctrl+C to copy (%d KB), then paste it to the developer. Or send it in game: /kin report send <name>")
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
function Report.Send(target, hours, route)
	local channel = route or "WHISPER"
	local bundle = Report.Build(hours)
	local encoded = ns.Encode(bundle)
	if not encoded then
		ns.Print("could not build the report")
		return
	end
	local id = ("%x"):format(math.random(0, 0x7fffffff))
	outgoing[id] = { bundle = bundle, target = target, channel = channel, at = GetTime() }
	ns.Comm.Send("RO", { id = id, bytes = #encoded, hours = hours }, channel, target, ns.Comm.PRIO.NORMAL)
	ns.Log("INFO", "report", "OFFER_SENT", { id = id, to = target, ch = channel, bytes = #encoded })
	ns.Print("asked %s to accept a report (%s). Waiting for them…", target, sizeText(#encoded))
	C_Timer.After(OFFER_TIMEOUT, function()
		if outgoing[id] and not outgoing[id].accepted then
			outgoing[id] = nil
			ns.Print("%s did not answer the report offer. Do they have Kinship enabled? Try: /kin report send %s guild", target, target)
			ns.Log("WARN", "report", "OFFER_TIMEOUT", { id = id, to = target, ch = channel })
		end
	end)
end

local function reply(msgType, payload, sender, channel)
	if channel == "WHISPER" then
		ns.Comm.Send(msgType, payload, "WHISPER", sender, ns.Comm.PRIO.ALERT)
	else
		ns.Comm.Send(msgType, payload, channel, sender, ns.Comm.PRIO.ALERT)
	end
end

StaticPopupDialogs["KINSHIP_REPORT_OFFER"] = {
	text = "%s wants to send you a Kinship diagnostic report (%s).\nAccept it?",
	button1 = ACCEPT,
	button2 = DECLINE,
	OnAccept = function(self, data)
		data = data or self.data
		incoming[data.id] = data.sender
		reply("RA", { id = data.id, ok = true }, data.sender, data.channel)
		ns.Log("INFO", "report", "OFFER_ACCEPTED", { id = data.id, from = data.sender })
	end,
	OnCancel = function(self, data)
		data = data or self.data
		reply("RA", { id = data.id, ok = false }, data.sender, data.channel)
	end,
	timeout = OFFER_TIMEOUT - 10,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

ns.OnLoad(function()
	local Comm = ns.Comm

	-- Receiver: an offer arrives.
	Comm.Register("RO", function(p, sender, channel)
		if type(p) ~= "table" or not p.id then return end
		ns.Log("INFO", "report", "OFFER_RECEIVED", { id = p.id, from = sender, ch = channel, bytes = p.bytes })
		StaticPopup_Show("KINSHIP_REPORT_OFFER", ns.ShortName(sender), sizeText(p.bytes or 0),
			{ id = p.id, sender = sender, channel = channel })
	end)

	-- Sender: the receiver answered.
	Comm.Register("RA", function(p, sender)
		local o = type(p) == "table" and outgoing[p.id]
		if not o or ns.ShortName(sender) ~= ns.ShortName(o.target) then return end
		if not p.ok then
			outgoing[p.id] = nil
			ns.Print("%s declined the report.", o.target)
			return
		end
		o.accepted = true
		local nextPct = 25
		local h = Comm.Send("RD", { id = p.id, bundle = o.bundle }, o.channel, o.target, Comm.PRIO.BULK)
		if not h then
			ns.Print("sending the report failed (see /kin log)")
			return
		end
		ns.Print("%s accepted — sending %d parts in the background.", o.target, h.parts)
		h.onProgress = function(hh)
			local pct = math.floor(hh.sent / hh.parts * 100)
			if pct >= nextPct and hh.sent < hh.parts then
				ns.Print("report to %s: %d%%", o.target, pct)
				nextPct = nextPct + 25
			end
		end
		h.onDone = function()
			outgoing[p.id] = nil
			ns.Print("report sent to %s.", o.target)
			ns.Log("INFO", "report", "REPORT_SENT", { id = p.id, to = o.target, parts = h.parts })
		end
		h.onFail = function(_, res)
			outgoing[p.id] = nil
			ns.Print("sending the report to %s failed (%s).", o.target, tostring(res))
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
		ns.Print("received a report from %s — /kin reports (it is also saved in your SavedVariables).", ns.ShortName(sender))
	end)
end)

function Report.ListInbox()
	local inbox = KinshipLog.inbox
	if #inbox == 0 then
		ns.Print("no reports received.")
		return
	end
	for i, r in ipairs(inbox) do
		ns.Print("%d. %s · %s · %d KB", i, ns.ShortName(r.from), date("%Y-%m-%d %H:%M", r.at), math.ceil(#(r.data or "") / 1024))
	end
	ns.Print("/kin reports <n> to show one, /kin reports clear to delete all.")
end

function Report.ShowInbox(i)
	local r = KinshipLog.inbox[i]
	if not r then
		ns.Print("no report #%s.", tostring(i))
		return
	end
	ns.ShowText("Report from " .. ns.ShortName(r.from), "Ctrl+C to copy, decode with scripts/kinship-diag.py", r.data, true)
end
