--!strict

export type State = {
	available: boolean, editable: boolean, writable: boolean, canCopy: boolean,
	dirty: boolean, saving: boolean, automatic: boolean, external: boolean,
	name: string, message: string?,
}
export type Actions = {
	Save: () -> boolean, Copy: () -> (), Export: () -> (), SetAutomatic: (boolean) -> (),
}
export type API = {
	Update: (State) -> (), ConfirmLeave: (() -> ()) -> (), Destroy: () -> (),
}

local Controls = {}
local BLUE = Color3.fromRGB(75, 125, 235)
local MUTED = Color3.fromRGB(58, 61, 72)
local GREEN = Color3.fromRGB(110, 215, 160)
local AMBER = Color3.fromRGB(255, 198, 105)

local function button(parent: Instance, name: string, text: string, callback: () -> ()): TextButton
	local result = Instance.new("TextButton")
	result.Name = name; result.Text = text
	result.BackgroundColor3 = BLUE; result.TextColor3 = Color3.new(1, 1, 1)
	result.BorderSizePixel = 0; result.Font = Enum.Font.BuilderSansBold; result.TextSize = 13
	result.TextWrapped = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6); corner.Parent = result
	result.Parent = parent
	result.Activated:Connect(callback)
	return result
end

local function enable(target: TextButton, enabled: boolean)
	target.Active = enabled; target.Selectable = enabled; target.AutoButtonColor = enabled
	target.BackgroundColor3 = if enabled then BLUE else MUTED
	target.TextTransparency = if enabled then 0 else 0.35
end

function Controls.Create(header: Frame, widget: DockWidgetPluginGui, actions: Actions): API
	local state: State? = nil
	local pending: (() -> ())? = nil
	local panel = Instance.new("Frame")
	panel.Name = "PresetSaving"; panel.LayoutOrder = 1
	panel.BackgroundTransparency = 1; panel.Size = UDim2.new(1, 0, 0, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Parent = header
	local primary = button(panel, "SavePreset", "Save preset", function()
		local current = state
		if not current or not current.available or not current.editable or current.saving then return end
		if current.writable then actions.Save()
		elseif current.canCopy and not current.external then actions.Copy()
		else actions.Export() end
	end)
	primary.Size = UDim2.new(0.5, -3, 0, 34)
	local copy = button(panel, "SaveCopy", "Save a copy", function()
		if state and state.editable and state.available and state.canCopy and not state.saving then actions.Copy() end
	end)
	copy.Size = UDim2.new(0.5, -3, 0, 34); copy.Position = UDim2.new(0.5, 3, 0, 0)
	local automatic = button(panel, "AutoSave", "Auto-save: ON", function()
		if state and state.editable and state.writable and not state.saving then actions.SetAutomatic(not state.automatic) end
	end)
	automatic.Size = UDim2.new(0.5, -3, 0, 26); automatic.Position = UDim2.fromOffset(0, 40)
	local export = button(panel, "ExportPreset", "Export preset", function()
		if state and state.available and not state.saving then actions.Export() end
	end)
	export.Size = UDim2.new(0.5, -3, 0, 26); export.Position = UDim2.new(0.5, 3, 0, 40)
	local status = Instance.new("TextLabel")
	status.Name = "SaveStatus"; status.BackgroundTransparency = 1
	status.Position = UDim2.fromOffset(0, 72); status.Size = UDim2.new(1, 0, 0, 0)
	status.AutomaticSize = Enum.AutomaticSize.Y
	status.Font = Enum.Font.BuilderSans; status.TextSize = 12; status.TextWrapped = true
	status.TextXAlignment = Enum.TextXAlignment.Left; status.TextYAlignment = Enum.TextYAlignment.Top
	status.Parent = panel

	local overlay = Instance.new("TextButton")
	overlay.Name = "UnsavedPreset"; overlay.Text = ""; overlay.AutoButtonColor = false
	overlay.BackgroundColor3 = Color3.new(0, 0, 0); overlay.BackgroundTransparency = 0.25
	overlay.Size = UDim2.fromScale(1, 1); overlay.ZIndex = 1000; overlay.Visible = false
	overlay.InputSink = Enum.InputSink.All; overlay.Parent = widget
	local dialog = Instance.new("Frame")
	dialog.AnchorPoint = Vector2.new(0.5, 0.5); dialog.Position = UDim2.fromScale(0.5, 0.5)
	dialog.Size = UDim2.new(1, -32, 0, 236); dialog.BackgroundColor3 = Color3.fromRGB(30, 32, 42)
	dialog.BorderSizePixel = 0; dialog.Parent = overlay
	local message = Instance.new("TextLabel")
	message.BackgroundTransparency = 1; message.TextColor3 = AMBER
	message.Font = Enum.Font.BuilderSans; message.TextSize = 15; message.TextWrapped = true
	message.Position = UDim2.fromOffset(12, 12); message.Size = UDim2.new(1, -24, 0, 70)
	message.Parent = dialog
	local function close()
		overlay.Visible = false; pending = nil
	end
	local keep = button(dialog, "KeepEditing", "Keep editing", close)
	keep.Position = UDim2.fromOffset(12, 90); keep.Size = UDim2.new(1, -24, 0, 36)
	local save = button(dialog, "SaveBeforeLeaving", "Save and continue", function()
		local current = state
		if not current or current.saving then return end
		if current.writable then
			if actions.Save() then local proceed = pending; close(); if proceed then proceed() end end
		elseif current.canCopy and not current.external then close(); actions.Copy()
		else actions.Export() end
	end)
	save.Position = UDim2.fromOffset(12, 134); save.Size = UDim2.new(1, -24, 0, 36)
	local discard = button(dialog, "DiscardChanges", "Discard changes and continue", function()
		if state and state.saving then return end
		local proceed = pending; close(); if proceed then proceed() end
	end)
	discard.Position = UDim2.fromOffset(12, 178); discard.Size = UDim2.new(1, -24, 0, 36)
	discard.BackgroundColor3 = MUTED

	return table.freeze({
		Update = function(nextState: State)
			state = nextState
			local editable = nextState.available and nextState.editable and not nextState.saving
			primary.Text = if nextState.writable then "Save preset"
				elseif nextState.canCopy and not nextState.external then "Save a copy" else "Export preset..."
			enable(primary, editable and (nextState.dirty or not nextState.writable))
			enable(copy, editable and nextState.canCopy)
			enable(export, nextState.available and not nextState.saving)
			enable(automatic, editable and nextState.writable)
			automatic.Text = if not nextState.writable then "Auto-save unavailable"
				elseif nextState.automatic then "Auto-save: ON" else "Auto-save: OFF"
			local text = "Select an emitter and preset to begin."
			if nextState.available then
				if nextState.saving then text = "Saving " .. nextState.name .. "..."
				elseif nextState.message then text = nextState.message
				elseif nextState.external then
					text = (if nextState.dirty then "Unsaved changes. " else "External file. ")
						.. "Script Sync owns this preset; use Export preset to update its file."
				elseif not nextState.writable then
					text = "Built-in example. " .. (if nextState.canCopy then "Save a copy to keep your changes."
						else "Initialize project to save a copy, or export this preset.")
				elseif nextState.dirty then
					text = if nextState.automatic then "Changes pending auto-save..." else "Unsaved changes. Click Save preset to keep them."
				else text = "Saved in this place. Save or publish the place to keep it after closing Studio." end
			end
			status.Text = text
			status.TextColor3 = if nextState.dirty or nextState.message then AMBER else GREEN
			save.Text = if nextState.writable then "Save and continue"
				elseif nextState.canCopy and not nextState.external then "Save a copy..." else "Export changes..."
			enable(save, nextState.available and nextState.editable and not nextState.saving)
			enable(discard, not nextState.saving)
		end,
		ConfirmLeave = function(proceed: () -> ())
			pending = proceed
			message.Text = "Unsaved changes to " .. (if state then state.name else "this preset")
				.. ".\nKeep editing, save your changes, or discard them. Exporting alone does not save the original."
			overlay.Visible = true
		end,
		Destroy = function() close(); panel:Destroy(); overlay:Destroy() end,
	})
end

return table.freeze(Controls)
