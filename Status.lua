-- Status snapshot: used by /kin status and included in every report.

local _, ns = ...

function ns.StatusSnapshot()
	local Comm = ns.Comm
	local a, n, b = Comm.QueueDepth()
	local records = 0
	for _, s in ipairs(KinshipLog.sessions) do records = records + #s.records end
	local clubId = C_Club and C_Club.GetGuildClubId and C_Club.GetGuildClubId()
	return {
		version = ns.version,
		dev = ns.isDev,
		serverTime = GetServerTime(),
		char = UnitName("player"),
		guid = UnitGUID("player"),
		guild = GetGuildInfo("player"),
		guildClubId = clubId,
		inInstance = select(2, IsInInstance()),
		comm = {
			stats = Comm.stats,
			queue = { alert = a, normal = n, bulk = b },
			partial = Comm.PartialCount(),
			locked = Comm.IsLocked(),
			cfg = KinshipDB.settings.comm,
		},
		log = { sessions = #KinshipLog.sessions, records = records, inbox = #KinshipLog.inbox },
		debug = KinshipDB.settings.debug,
	}
end

function ns.PrintStatus()
	local s = ns.StatusSnapshot()
	local c = s.comm
	ns.Print("v%s%s · %s · guild: %s", s.version, s.dev and " (dev)" or "", s.char or "?", s.guild or "none")
	ns.Print("comm: sent %d msgs/%d frames, recv %d/%d, throttled %d, failed %d, dropped %d",
		c.stats.sentMsgs, c.stats.sentFrames, c.stats.recvMsgs, c.stats.recvFrames,
		c.stats.throttled, c.stats.failed, c.stats.dropped)
	ns.Print("queue: alert %d · normal %d · bulk %d · partial %d · %s · burst %d, %.2f/s",
		c.queue.alert, c.queue.normal, c.queue.bulk, c.partial,
		c.locked and "|cffff6060LOCKED|r" or "unlocked", c.cfg.burst, c.cfg.rate)
	local on = {}
	for cat, v in pairs(s.debug) do if v then on[#on + 1] = cat end end
	table.sort(on)
	ns.Print("log: %d records in %d sessions · inbox %d · debug: %s",
		s.log.records, s.log.sessions, s.log.inbox, #on > 0 and table.concat(on, ", ") or "off")
end
