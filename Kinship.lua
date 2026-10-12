-- Kinship: guild deeds, points and togetherness.
-- Scaffold only; see README for the feature set this is growing into.

local ADDON_NAME, ns = ...
Kinship = ns

ns.version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "dev"

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, name)
	if name ~= ADDON_NAME then return end
	self:UnregisterEvent("ADDON_LOADED")
	KinshipDB = KinshipDB or {}
	KinshipCharDB = KinshipCharDB or {}
end)
