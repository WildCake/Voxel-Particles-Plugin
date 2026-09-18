--!strict

export type API = { Show: (string, string, string?) -> (), Destroy: () -> () }
local Export = {}

function Export.Create(owner: Plugin): API
	local info = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 640, 500, 320, 400)
	local widget = owner:CreateDockWidgetPluginGuiAsync("VoxelParticlesPresetSource", info)
	widget.Title = "Voxel Particles — Export preset"
	local instructions = Instance.new("TextLabel")
	instructions.BackgroundColor3 = Color3.fromRGB(32, 34, 42)
	instructions.TextColor3 = Color3.fromRGB(235, 237, 245)
	instructions.Font = Enum.Font.BuilderSans
	instructions.TextSize = 14; instructions.TextWrapped = true
	instructions.Size = UDim2.new(1, -16, 0, 0); instructions.AutomaticSize = Enum.AutomaticSize.Y
	instructions.Position = UDim2.fromOffset(8, 4)
	instructions.Parent = widget
	local scroll = Instance.new("ScrollingFrame")
	scroll.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
	scroll.BorderSizePixel = 0; scroll.ScrollBarThickness = 8
	scroll.Position = UDim2.fromOffset(0, 166); scroll.Size = UDim2.new(1, 0, 1, -166)
	scroll.CanvasSize = UDim2.fromOffset(0, 0); scroll.AutomaticCanvasSize = Enum.AutomaticSize.XY
	scroll.Parent = widget
	local source = Instance.new("TextBox")
	source.BackgroundTransparency = 1; source.ClearTextOnFocus = false
	source.MultiLine = true; source.TextEditable = false; source.TextWrapped = false
	source.TextXAlignment = Enum.TextXAlignment.Left; source.TextYAlignment = Enum.TextYAlignment.Top
	source.Font = Enum.Font.Code; source.TextSize = 14; source.TextColor3 = Color3.fromRGB(235, 237, 245)
	source.Position = UDim2.fromOffset(10, 8); source.Size = UDim2.fromOffset(0, 0)
	source.AutomaticSize = Enum.AutomaticSize.XY; source.Parent = scroll
	local function selectAll()
		source:CaptureFocus(); source.CursorPosition = #source.Text + 1; source.SelectionStart = 1
	end
	local select = Instance.new("TextButton")
	select.Name = "SelectAll"; select.Text = "Select all — then copy (Ctrl+C / Cmd+C)"
	select.Font = Enum.Font.BuilderSansBold; select.TextSize = 13; select.TextWrapped = true
	select.BackgroundColor3 = Color3.fromRGB(75, 125, 235); select.TextColor3 = Color3.new(1, 1, 1)
	select.Position = UDim2.fromOffset(8, 132); select.Size = UDim2.new(1, -16, 0, 28)
	select.Parent = widget; select.Activated:Connect(selectAll)
	local function layout()
		local top = instructions.AbsoluteSize.Y + 12
		select.Position = UDim2.fromOffset(8, top)
		scroll.Position = UDim2.fromOffset(0, top + 36)
		scroll.Size = UDim2.new(1, 0, 1, -top - 36)
	end
	instructions:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	return table.freeze({
		Show = function(name: string, text: string, projectPath: string?)
			widget.Title = "Export " .. name .. ".luau"
			instructions.Text = "Export does not save the original preset.\n"
				.. "1. Copy the selected text below.\n2. Open " .. name .. ".luau, replace its contents and save.\n"
				.. "For Script Sync: find the preset in Explorer, then Script Sync > Reveal in Explorer/Finder."
				.. (if projectPath then "\nPreset: " .. projectPath else "")
			source.Text = text; scroll.CanvasPosition = Vector2.zero; widget.Enabled = true
			selectAll()
		end,
		Destroy = function() widget:Destroy() end,
	})
end

return table.freeze(Export)
