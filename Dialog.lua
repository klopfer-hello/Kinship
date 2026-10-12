-- Read-only text window for copying reports and viewing the log (Blizzard style).

local _, ns = ...

local frame

local function build()
	local f = CreateFrame("Frame", "KinshipTextFrame", UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(640, 420)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	tinsert(UISpecialFrames, "KinshipTextFrame")

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.title:SetPoint("TOP", 0, -5)

	f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.hint:SetPoint("TOPLEFT", 14, -32)
	f.hint:SetPoint("TOPRIGHT", -14, -32)
	f.hint:SetJustifyH("LEFT")

	local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 14, -56)
	scroll:SetPoint("BOTTOMRIGHT", -34, 14)

	local edit = CreateFrame("EditBox", nil, scroll)
	edit:SetMultiLine(true)
	edit:SetAutoFocus(false)
	edit:SetFontObject(ChatFontNormal)
	edit:SetWidth(580)
	edit:SetMaxLetters(0)
	edit:SetScript("OnEscapePressed", function() f:Hide() end)
	-- Read-only: typing restores the original text.
	edit:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			self:SetText(f.text or "")
			self:HighlightText()
		end
	end)
	scroll:SetScrollChild(edit)
	f.edit = edit
	return f
end

-- Shows text in the window. select = true highlights all of it for Ctrl+C.
function ns.ShowText(title, hint, text, select)
	frame = frame or build()
	frame.title:SetText(title)
	frame.hint:SetText(hint or "")
	frame.text = text
	frame.edit:SetText(text)
	frame:Show()
	if select then
		frame.edit:SetFocus()
		frame.edit:HighlightText()
	else
		frame.edit:ClearFocus()
	end
end
