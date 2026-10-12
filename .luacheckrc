-- luacheck config (run: scripts/lint.ps1, or `luacheck .` in the repo root)
std = "lua51"
max_line_length = false
codes = true
exclude_files = { "Libs/", "dist/", ".git/" }

ignore = {
	"212",   -- unused arguments: event/comm callbacks keep their full signature
}

-- Globals this addon defines or writes into.
globals = {
	"Kinship", "KinshipDB", "KinshipCharDB", "KinshipLog",
	"SLASH_KINSHIP1", "SLASH_KINSHIP2",
	"SlashCmdList", "StaticPopupDialogs", "UISpecialFrames",
}

-- WoW API used by the addon (Forever 1.60.1, retail API). Add names as needed;
-- an unknown global is usually a typo or an API that does not exist here.
read_globals = {
	-- namespaces
	"C_AddOns", "C_Calendar", "C_ChatInfo", "C_Club", "C_DateAndTime", "C_EncodingUtil",
	"C_GuildInfo", "C_Timer", "Enum",
	-- functions
	"ChatFrame_AddMessageEventFilter", "CreateFrame", "date", "debugstack", "geterrorhandler", "GetBuildInfo", "GetChannelName",
	"GetGuildInfo", "GetGuildRosterInfo", "GetInstanceInfo", "GetLocale", "GetNormalizedRealmName",
	"GetNumGroupMembers", "GetNumGuildMembers", "GetRealmName", "GetServerTime", "GetTime",
	"GetTimePreciseSec", "InCombatLockdown", "IsEncounterInProgress", "IsInGroup", "IsInGuild",
	"IsInInstance", "IsInRaid", "issecretvalue", "JoinTemporaryChannel", "LeaveChannelByName", "StaticPopup_Show", "tinsert", "UnitClass",
	"UnitExists", "UnitFullName", "UnitGUID", "UnitIsConnected", "UnitIsInMyGuild", "UnitLevel",
	"UnitName", "UnitXP", "UnitXPMax", "wipe",
	-- frames, objects and strings
	"ACCEPT", "ChatFontNormal", "DECLINE", "ERR_CHAT_PLAYER_NOT_FOUND_S", "DEFAULT_CHAT_FRAME", "NO", "UIParent", "YES",
}
