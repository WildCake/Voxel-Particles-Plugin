--!strict

export type API = { Show: (string, string) -> (), Destroy: () -> () }
local Export = {}

function Export.Create(owner: Plugin): API
	local info = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 640, 500, 320, 240)
	local widget = owner:CreateDockWidgetPluginGuiAsync("VoxelParticlesPresetSource", info)
	widget.Title = "Voxel Particles — Export preset"
	local instructions = Instance.new("TextLabel")
	instructions.BackgroundColor3 = Color3.fromRGB(32, 34, 42)
	instructions.TextColor3 = Color3.fromRGB(235, 237, 245)
	instructions.Font = Enum.Font.BuilderSans
	instructions.TextSize = 14; instructions.TextWrapped = true
	instructions.Size = UDim2.new(1, 0, 0, 60)
	instructions.Text = "Copy this Luau source to your preset's disk file. Export does not change the project or mark the preset as saved."
	instructions.Parent = widget
	local scroll = Instance.new("ScrollingFrame")
	scroll.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
	scroll.BorderSizePixel = 0; scroll.ScrollBarThickness = 8
	scroll.Position = UDim2.fromOffset(0, 60); scroll.Size = UDim2.new(1, 0, 1, -60)
	scroll.CanvasSize = UDim2.fromOffset(0, 0); scroll.AutomaticCanvasSize = Enum.AutomaticSize.XY
	scroll.Parent = widget
	local source = Instance.new("TextBox")
	source.BackgroundTransparency = 1; source.ClearTextOnFocus = false
	source.MultiLine = true; source.TextEditable = false; source.TextWrapped = false
	source.TextXAlignment = Enum.TextXAlignment.Left; source.TextYAlignment = Enum.TextYAlignment.Top
	source.Font = Enum.Font.Code; source.TextSize = 14; source.TextColor3 = Color3.fromRGB(235, 237, 245)
	source.Position = UDim2.fromOffset(10, 8); source.Size = UDim2.fromOffset(0, 0)
	source.AutomaticSize = Enum.AutomaticSize.XY; source.Parent = scroll
	return table.freeze({
		Show = function(name: string, text: string)
			widget.Title = "Export " .. name .. ".luau"
			source.Text = text; scroll.CanvasPosition = Vector2.zero; widget.Enabled = true
			source:CaptureFocus(); source.CursorPosition = #text + 1; source.SelectionStart = 1
		end,
		Destroy = function() widget:Destroy() end,
	})
end

return table.freeze(Export)
