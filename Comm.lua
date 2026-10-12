-- Transport: framing, chunking, prioritised outbox with throttle and lockdown
-- handling, reassembly, dispatch by message type.
--
-- Wire frame (one addon message, <= 255 bytes):
--   "K1" .. msgId(base36) .. ":" .. part .. "/" .. parts .. ":" .. chunk
-- The concatenated chunks are ns.Encode(envelope), envelope = { t = type, to = target?, p = payload }.
-- "to" addresses a message sent over a broadcast channel (GUILD/RAID/PARTY) to one player.

local _, ns = ...

local Comm = {}
ns.Comm = Comm

local PREFIX = "Kinship"
local MAX_MSG = 255
local REASSEMBLY_TIMEOUT = 60

local PRIO = { ALERT = 1, NORMAL = 2, BULK = 3 }
Comm.PRIO = PRIO

local queues = { {}, {}, {} }   -- frames waiting, per priority
local handlers = {}              -- type -> fn(payload, sender, channel)
local partial = {}               -- sender|msgId -> { parts, got, n, last }
local nextId = math.random(0, 36 ^ 3)
local tokens, lastRefill = 0, 0
local locked = false
-- Timers run only while there is work (D30: nothing ticks when idle).
local pumpTicker, expireTicker
local pump, expire

Comm.stats = { sentFrames = 0, recvFrames = 0, sentMsgs = 0, recvMsgs = 0, throttled = 0, failed = 0, dropped = 0 }

local function settings()
	local s = KinshipDB.settings
	s.comm = s.comm or { burst = 8, rate = 1 }
	return s.comm
end

local function base36(n)
	local digits, s = "0123456789abcdefghijklmnopqrstuvwxyz", ""
	repeat
		local d = n % 36
		s = digits:sub(d + 1, d + 1) .. s
		n = math.floor(n / 36)
	until n == 0
	return s
end

function Comm.Register(msgType, fn)
	handlers[msgType] = fn
end

-- Queues a message. Returns a handle { id, parts, sent, onProgress, onDone } or nil, err.
function Comm.Send(msgType, payload, channel, target, prio)
	local envelope = { t = msgType, p = payload }
	if target and channel ~= "WHISPER" then envelope.to = target end
	local text, err = ns.Encode(envelope)
	if not text then
		ns.Log("WARN", "comm", "ENCODE_FAIL", { type = msgType, err = err })
		return nil, err
	end

	nextId = (nextId + 1) % (36 ^ 4)
	local id = base36(nextId)
	-- Header length depends on the part count, so size chunks for the worst case.
	local room = MAX_MSG - #("K1" .. id .. ":999/999:")
	local parts = math.ceil(#text / room)
	if parts > 999 then
		ns.Log("WARN", "comm", "TOO_LARGE", { type = msgType, bytes = #text })
		return nil, "too large"
	end

	local handle = { id = id, parts = parts, sent = 0, type = msgType }
	local q = queues[prio or PRIO.NORMAL]
	for i = 1, parts do
		local chunk = text:sub((i - 1) * room + 1, i * room)
		q[#q + 1] = {
			text = "K1" .. id .. ":" .. i .. "/" .. parts .. ":" .. chunk,
			channel = channel, target = channel == "WHISPER" and target or nil,
			handle = handle,
		}
	end
	ns.Log("DEBUG", "comm", "TX_QUEUE", { type = msgType, id = id, parts = parts, bytes = #text, ch = channel, to = target })
	if not pumpTicker then
		pumpTicker = C_Timer.NewTicker(0.1, function() ns.Safe(pump) end)
	end
	return handle
end

local function isThrottle(res)
	local R = Enum.SendAddonMessageResult
	return R and (res == R.AddonMessageThrottle or res == R.ChannelThrottle)
end

local function isSuccess(res)
	local R = Enum.SendAddonMessageResult
	if res == nil or res == true then return true end
	return R and res == R.Success
end

local function checkLockdown()
	local lock = C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
	if not lock and C_ChatInfo.AreOutgoingAddonChatMessagesRestricted then
		local ok, restricted = pcall(C_ChatInfo.AreOutgoingAddonChatMessagesRestricted)
		lock = ok and restricted
	end
	lock = lock and true or false
	if lock ~= locked then
		locked = lock
		ns.Log("INFO", "comm", lock and "LOCKDOWN_ON" or "LOCKDOWN_OFF", nil)
	end
	return lock
end
Comm.IsLocked = checkLockdown

function pump()
	local cfg = settings()
	local now = GetTime()
	tokens = math.min(cfg.burst, tokens + (now - lastRefill) * cfg.rate)
	lastRefill = now
	if checkLockdown() then return end

	for p = 1, 3 do
		local q = queues[p]
		while q[1] and tokens >= 1 do
			local f = q[1]
			local res = C_ChatInfo.SendAddonMessage(PREFIX, f.text, f.channel, f.target)
			if isSuccess(res) then
				table.remove(q, 1)
				tokens = tokens - 1
				Comm.stats.sentFrames = Comm.stats.sentFrames + 1
				local h = f.handle
				h.sent = h.sent + 1
				if h.onProgress then ns.Safe(h.onProgress, h) end
				if h.sent == h.parts then
					Comm.stats.sentMsgs = Comm.stats.sentMsgs + 1
					ns.Log("DEBUG", "comm", "TX_DONE", { type = h.type, id = h.id, parts = h.parts })
					if h.onDone then ns.Safe(h.onDone, h) end
				end
			elseif isThrottle(res) then
				Comm.stats.throttled = Comm.stats.throttled + 1
				ns.Log("DEBUG", "comm", "THROTTLED", { res = res, prio = p })
				tokens = 0
				return
			else
				-- Not retryable (not in group, bad target, ...): drop the whole message.
				Comm.stats.failed = Comm.stats.failed + 1
				ns.Log("WARN", "comm", "TX_FAIL", { res = tostring(res), type = f.handle.type, ch = f.channel, to = f.target })
				local h = f.handle
				for i = #q, 1, -1 do
					if q[i].handle == h then table.remove(q, i) end
				end
				if h.onFail then ns.Safe(h.onFail, h, res) end
			end
		end
	end
	if not queues[1][1] and not queues[2][1] and not queues[3][1] then
		pumpTicker:Cancel()
		pumpTicker = nil
	end
end

function Comm.QueueDepth()
	return #queues[1], #queues[2], #queues[3]
end

---------------------------------------------------------------------------
-- Receive
---------------------------------------------------------------------------
local function dispatch(text, sender, channel)
	local env, err = ns.Decode(text)
	if type(env) ~= "table" or type(env.t) ~= "string" then
		ns.Log("WARN", "comm", "RX_DECODE_FAIL", { from = sender, err = err })
		return
	end
	if env.to and not ns.IsMe(env.to) then return end
	Comm.stats.recvMsgs = Comm.stats.recvMsgs + 1
	ns.Log("DEBUG", "comm", "RX_MSG", { type = env.t, from = sender, ch = channel, bytes = #text })
	local fn = handlers[env.t]
	if fn then
		ns.Safe(fn, env.p, sender, channel)
	else
		ns.Log("DEBUG", "comm", "RX_UNHANDLED", { type = env.t, from = sender })
	end
end

local function onAddonMessage(_, prefix, text, channel, sender)
	if prefix ~= PREFIX or ns.IsMe(sender) then return end
	local id, part, parts, chunk = text:match("^K1(%w+):(%d+)/(%d+):(.*)$")
	if not id then
		ns.Log("DEBUG", "comm", "RX_BAD_FRAME", { from = sender, len = #text })
		return
	end
	Comm.stats.recvFrames = Comm.stats.recvFrames + 1
	part, parts = tonumber(part), tonumber(parts)
	if parts == 1 then
		dispatch(chunk, sender, channel)
		return
	end
	local key = sender .. "|" .. id
	local p = partial[key]
	if not p then
		p = { chunks = {}, got = 0, n = parts }
		partial[key] = p
		if not expireTicker then
			expireTicker = C_Timer.NewTicker(10, function() ns.Safe(expire) end)
		end
	end
	p.last = GetTime()
	if not p.chunks[part] then
		p.chunks[part] = chunk
		p.got = p.got + 1
	end
	if p.got == p.n then
		partial[key] = nil
		dispatch(table.concat(p.chunks), sender, channel)
	end
end

-- Partial messages whose sender went quiet are dropped.
function expire()
	local now = GetTime()
	for key, p in pairs(partial) do
		if now - p.last > REASSEMBLY_TIMEOUT then
			partial[key] = nil
			Comm.stats.dropped = Comm.stats.dropped + 1
			ns.Log("WARN", "comm", "RX_EXPIRED", { key = key, got = p.got, n = p.n })
		end
	end
	if not next(partial) then
		expireTicker:Cancel()
		expireTicker = nil
	end
end

function Comm.PartialCount()
	local n = 0
	for _ in pairs(partial) do n = n + 1 end
	return n
end

ns.OnLoad(function()
	C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
	ns.On("CHAT_MSG_ADDON", onAddonMessage)
	lastRefill = GetTime()
	tokens = settings().burst
end)
