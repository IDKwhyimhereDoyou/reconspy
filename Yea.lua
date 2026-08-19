-- ActionSpy.lua
-- Record: listen to incoming + outgoing remotes, then save.
-- Start: replay the last saved recording (outgoing only, same order/timing).
-- One take. No tabs, dump, copy, or remotes browser.

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local lp = Players.LocalPlayer

local THEME = {
	BG = Color3.fromRGB(16, 16, 20),
	PANEL = Color3.fromRGB(26, 26, 32),
	BTN = Color3.fromRGB(38, 38, 48),
	TEXT = Color3.fromRGB(236, 236, 240),
	DIM = Color3.fromRGB(138, 138, 148),
	WARN = Color3.fromRGB(255, 176, 64),
	ERR = Color3.fromRGB(232, 78, 78),
	OK = Color3.fromRGB(72, 196, 128),
	IN = Color3.fromRGB(160, 140, 255),
}

local NOISY = {
	"heartbeat", "ping", "fps", "mouse", "camera", "tick", "replicate",
	"render", "inputstate", "lookvector", "footstep", "animation",
	"positionupdate", "cframe", "syncpos", "characterlook", "getping",
	"updatemouse", "physics", "collision", "cameramove", "stream",
	"byte", "ack", "keepalive", "keep_alive", "clock",
}

local S = {
	recording = false,
	saved = nil,
	live = nil,
	t0 = 0,
	spyHooked = false,
	replaying = false,
	stopped = false,
	inConns = {},
	listDirty = false,
	lastPaint = 0,
}

local gui, win, logLabel, recBtn, startBtn, listFrame, noteBox
local f10Conn, dragConn, dragBegan, dragEnded
local dragging, dragStart, startPos

local function envGet(name)
	if type(getgenv) == "function" then
		local ok, env = pcall(getgenv)
		if ok and type(env) == "table" and env[name] ~= nil then
			return env[name]
		end
	end
	if type(getfenv) == "function" then
		local ok, env = pcall(getfenv, 0)
		if ok and type(env) == "table" and env[name] ~= nil then
			return env[name]
		end
	end
	local ok, v = pcall(function()
		return _G[name]
	end)
	if ok then
		return v
	end
	return nil
end

local function pickFn(...)
	for i = 1, select("#", ...) do
		local v = envGet(select(i, ...))
		if type(v) == "function" then
			return v
		end
	end
	return nil
end

local function wrapC(fn)
	local nc = envGet("newcclosure")
	if type(nc) == "function" then
		local ok, w = pcall(nc, fn)
		if ok and type(w) == "function" then
			return w
		end
	end
	return fn
end

local function parentGui(obj)
	local syn = envGet("syn")
	if type(syn) == "table" and type(syn.protect_gui) == "function" then
		pcall(syn.protect_gui, obj)
	end
	local hide = envGet("hidegui") or envGet("protect_gui")
	if type(hide) == "function" then
		pcall(hide, obj)
	end
	local gethui = pickFn("gethui", "get_hidden_gui")
	if gethui then
		local ok, h = pcall(gethui)
		if ok and typeof(h) == "Instance" then
			obj.Parent = h
			return
		end
	end
	local ok = pcall(function()
		obj.Parent = CoreGui
	end)
	if not ok and lp then
		obj.Parent = lp:WaitForChild("PlayerGui")
	end
end

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = inst
end

local function trunc(s, n)
	s = tostring(s or "")
	n = n or 160
	if #s <= n then
		return s
	end
	return string.sub(s, 1, n - 1) .. "…"
end

local function isNoisy(name)
	local n = string.lower(tostring(name or ""))
	for i = 1, #NOISY do
		if string.find(n, NOISY[i], 1, true) then
			return true
		end
	end
	return false
end

local function splitDot(s)
	local t = {}
	for part in string.gmatch(tostring(s), "[^.]+") do
		t[#t + 1] = part
	end
	return t
end

local function fromPath(full)
	local parts = splitDot(full)
	if #parts == 0 then
		return nil
	end
	local cur
	local okSvc, svc = pcall(function()
		return game:GetService(parts[1])
	end)
	if okSvc and svc then
		cur = svc
	else
		cur = game:FindFirstChild(parts[1])
	end
	if not cur then
		return nil
	end
	for i = 2, #parts do
		cur = cur:FindFirstChild(parts[i])
		if not cur then
			return nil
		end
	end
	return cur
end

local function findRemote(ev)
	if typeof(ev.remote) == "Instance" and ev.remote.Parent then
		return ev.remote
	end
	local byPath = fromPath(ev.path)
	if typeof(byPath) == "Instance" then
		return byPath
	end
	local found
	pcall(function()
		for _, d in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
			if d.Name == ev.name and (d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("UnreliableRemoteEvent")) then
				found = d
				break
			end
		end
	end)
	return found
end

local function looksLikeGuid(v)
	return type(v) == "string"
		and string.match(v, "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

local function cloneArg(v)
	if looksLikeGuid(v) then
		return HttpService:GenerateGUID(false)
	end
	return v
end

local function pause(sec)
	if type(task) == "table" and type(task.wait) == "function" then
		task.wait(sec)
	else
		wait(sec)
	end
end

local function log(msg, color)
	if logLabel and logLabel.Parent then
		logLabel.Text = "  " .. trunc(tostring(msg), 200)
		logLabel.TextColor3 = color or THEME.DIM
	end
	print("[ActionSpy] " .. tostring(msg))
end

local function scriptFromTake(take)
	if not take or #take.events == 0 then
		return "-- nothing recorded"
	end
	local lines = {}
	local lastDelay = 0
	for i = 1, #take.events do
		local ev = take.events[i]
		local gap = (ev.delay or 0) - lastDelay
		if i > 1 then
			if gap >= 0.05 then
				lines[#lines + 1] = ""
				lines[#lines + 1] = string.format("wait(%.2f)", gap)
				lines[#lines + 1] = ""
			else
				lines[#lines + 1] = ""
			end
		end
		lastDelay = ev.delay or lastDelay
		local name = tostring(ev.name or "Remote")
		local ident = string.match(name, "^[%a_][%w_]*$")
		local call
		if ident then
			call = "fire(" .. name .. "):"
		else
			call = "fire(" .. string.format("%q", name) .. "):"
		end
		if ev.inbound then
			lines[#lines + 1] = call .. " -- client"
		elseif ev.method == "InvokeServer" then
			lines[#lines + 1] = call .. " -- invoke"
		else
			lines[#lines + 1] = call .. " -- server"
		end
	end
	return table.concat(lines, "\n")
end

local function refreshList()
	if not listFrame then
		return
	end
	for _, ch in ipairs(listFrame:GetChildren()) do
		if ch:IsA("TextLabel") then
			ch:Destroy()
		end
	end
	local take = S.recording and S.live or S.saved
	if not take or #take.events == 0 then
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.new(1, -4, 0, 22)
		empty.BackgroundTransparency = 1
		empty.Font = Enum.Font.Gotham
		empty.TextSize = 12
		empty.TextXAlignment = Enum.TextXAlignment.Left
		empty.TextColor3 = THEME.DIM
		empty.Text = "  Nothing saved yet."
		empty.Parent = listFrame
		if noteBox then
			noteBox.Text = "-- record, then stop. this notepad fills with fire() / wait()"
		end
		return
	end
	local maxShow = math.min(#take.events, 80)
	for i = 1, maxShow do
		local ev = take.events[i]
		local row = Instance.new("TextLabel")
		row.Size = UDim2.new(1, -4, 0, 18)
		row.BackgroundTransparency = 1
		row.Font = Enum.Font.Gotham
		row.TextSize = 12
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextColor3 = ev.inbound and THEME.IN or THEME.TEXT
		row.Text = "  " .. trunc(ev.label, 70)
		row.Parent = listFrame
	end
	if #take.events > maxShow then
		local more = Instance.new("TextLabel")
		more.Size = UDim2.new(1, -4, 0, 18)
		more.BackgroundTransparency = 1
		more.Font = Enum.Font.Gotham
		more.TextSize = 12
		more.TextXAlignment = Enum.TextXAlignment.Left
		more.TextColor3 = THEME.DIM
		more.Text = "  … +" .. tostring(#take.events - maxShow) .. " more (full order is in the notepad)"
		more.Parent = listFrame
	end
	if noteBox and not S.recording then
		noteBox.Text = scriptFromTake(take)
	end
end

local function schedulePaint()
	if S.recording and S.live then
		if logLabel and logLabel.Parent then
			logLabel.Text = "  Recording… " .. tostring(#S.live.events) .. " remotes (notepad fills when you stop)"
			logLabel.TextColor3 = THEME.DIM
		end
		return
	end
	refreshList()
end

local function later(fn)
	if type(task) == "table" and type(task.defer) == "function" then
		task.defer(fn)
	elseif type(task) == "table" and type(task.spawn) == "function" then
		task.spawn(fn)
	else
		spawn(fn)
	end
end

local function packSelect(...)
	local n = select("#", ...)
	local packed = { n = n }
	for i = 1, n do
		packed[i] = select(i, ...)
	end
	return packed
end

local function addCaptured(remote, method, inbound, packed)
	if S.replaying or S.stopped or not S.recording or not S.live then
		return
	end
	if typeof(remote) ~= "Instance" then
		return
	end
	if #S.live.events >= 250 then
		return
	end
	local name = ""
	pcall(function()
		name = remote.Name
	end)
	if isNoisy(name) then
		return
	end
	local now = os.clock()
	if S.t0 == 0 then
		S.t0 = now
	end
	local n = packed.n or 0
	local ev = {
		delay = now - S.t0,
		method = method,
		inbound = inbound and true or false,
		remote = remote,
		name = name,
		path = name,
		packed = packed,
		label = string.format("+%.2fs  %s  %s", now - S.t0, inbound and "← client" or "→ server", name),
	}
	S.live.events[#S.live.events + 1] = ev
	schedulePaint()
end

local function noteOutgoing(self, pretty, packed)
	later(function()
		addCaptured(self, pretty, false, packed)
	end)
end

local function hookNamecall()
	if S.oldNamecall then
		return true
	end
	local getncm = pickFn("getnamecallmethod", "get_namecall_method")
	local hook = pickFn("hookmetamethod")
	if type(hook) ~= "function" or type(getncm) ~= "function" then
		return false
	end
	local box = { old = nil }
	local function raw(self, ...)
		if S.recording and not S.replaying and not S.stopped then
			local okM, m = pcall(getncm)
			if okM then
				local low = string.lower(tostring(m or ""))
				if low == "fireserver" or low == "invokeserver" then
					pcall(noteOutgoing, self, low == "fireserver" and "FireServer" or "InvokeServer", packSelect(...))
				end
			end
		end
		local orig = box.old
		if type(orig) ~= "function" then
			return
		end
		return orig(self, ...)
	end
	local ok, ret = pcall(function()
		return hook(game, "__namecall", raw)
	end)
	if not ok or type(ret) ~= "function" then
		ok, ret = pcall(function()
			return hook(game, "__namecall", wrapC(raw))
		end)
	end
	if ok and type(ret) == "function" then
		box.old = ret
		S.oldNamecall = ret
		return true
	end
	return false
end

local function ensureHook()
	if S.spyHooked then
		return true, "ok"
	end
	if hookNamecall() then
		S.spyHooked = true
		return true, "namecall"
	end
	return false, "this executor cannot hook remotes without breaking them (no hookmetamethod)"
end

local function stopInbound()
	for i = 1, #S.inConns do
		pcall(function()
			S.inConns[i]:Disconnect()
		end)
	end
	S.inConns = {}
end

local function startInbound()
	stopInbound()
	local n = 0
	local function consider(inst)
		if n >= 40 or typeof(inst) ~= "Instance" then
			return
		end
		if not inst:IsA("RemoteEvent") and not inst:IsA("UnreliableRemoteEvent") then
			return
		end
		if isNoisy(inst.Name) then
			return
		end
		local ok, conn = pcall(function()
			return inst.OnClientEvent:Connect(function(...)
				if not S.recording then
					return
				end
				local packed = packSelect(...)
				local remote = inst
				later(function()
					addCaptured(remote, "OnClientEvent", true, packed)
				end)
			end)
		end)
		if ok and conn then
			S.inConns[#S.inConns + 1] = conn
			n = n + 1
		end
	end
	local rs = game:GetService("ReplicatedStorage")
	consider(rs)
	local ok, desc = pcall(function()
		return rs:GetDescendants()
	end)
	if ok then
		for i = 1, math.min(#desc, 2000) do
			consider(desc[i])
			if n >= 40 then
				break
			end
		end
	end
end

local function startRecord()
	local ok, how = ensureHook()
	if not ok then
		log("Cannot listen: " .. tostring(how), THEME.ERR)
		return
	end
	S.recording = true
	S.t0 = 0
	S.live = { events = {} }
	S.lastPaint = 0
	if recBtn then
		recBtn.Text = "Stop"
		recBtn.BackgroundColor3 = THEME.ERR
	end
	if noteBox then
		noteBox.Text = "-- recording…"
	end
	refreshList()
	log("Listening (" .. tostring(how) .. "). Do the action, then press Record again to save.", THEME.OK)
	later(startInbound)
end

local function stopRecord()
	S.recording = false
	stopInbound()
	S.saved = S.live
	S.live = nil
	if recBtn then
		recBtn.Text = "Record"
		recBtn.BackgroundColor3 = THEME.BTN
	end
	local take = S.saved
	local out, inn = 0, 0
	if take then
		for i = 1, #take.events do
			local ev = take.events[i]
			if ev.inbound then
				inn = inn + 1
			else
				out = out + 1
			end
			pcall(function()
				if typeof(ev.remote) == "Instance" then
					ev.path = ev.remote:GetFullName()
				end
			end)
		end
	end
	refreshList()
	if noteBox then
		noteBox.Text = scriptFromTake(take)
	end
	log(string.format("Saved. %d outgoing, %d incoming. Press Start to replay outgoing.", out, inn), THEME.OK)
end

local function toggleRecord()
	if S.replaying then
		log("Wait until Start finishes.", THEME.WARN)
		return
	end
	if S.recording then
		stopRecord()
	else
		startRecord()
	end
end

local function fireEvent(ev)
	local remote = findRemote(ev)
	if not remote then
		return false, "remote gone: " .. tostring(ev.path)
	end
	local n = ev.packed.n or 0
	local args = {}
	for i = 1, n do
		args[i] = cloneArg(ev.packed[i])
	end
	if ev.method == "FireServer" then
		return pcall(function()
			remote:FireServer(unpack(args, 1, n))
		end)
	end
	if ev.method == "InvokeServer" then
		return pcall(function()
			remote:InvokeServer(unpack(args, 1, n))
		end)
	end
	return false, "skip"
end

local function doStart()
	if S.recording then
		log("Stop recording first (press Record again).", THEME.WARN)
		return
	end
	local take = S.saved
	if not take or #take.events == 0 then
		log("Nothing saved. Record something first.", THEME.WARN)
		return
	end
	S.replaying = true
	if startBtn then
		startBtn.Text = "…"
		startBtn.BackgroundColor3 = THEME.WARN
	end
	local fired, failed, skipped = 0, 0, 0
	local lastDelay = 0
	for i = 1, #take.events do
		local ev = take.events[i]
		local waitFor = (ev.delay or 0) - lastDelay
		if waitFor > 0.001 then
			pause(math.min(waitFor, 2))
		end
		lastDelay = ev.delay or lastDelay
		if ev.inbound then
			skipped = skipped + 1
		else
			local ok, err = fireEvent(ev)
			if ok then
				fired = fired + 1
			else
				failed = failed + 1
				log("Failed " .. tostring(ev.name) .. ": " .. tostring(err), THEME.ERR)
			end
		end
	end
	S.replaying = false
	if startBtn then
		startBtn.Text = "Start"
		startBtn.BackgroundColor3 = THEME.OK
	end
	log(string.format("Done. fired %d outgoing, skipped %d incoming, failed %d.", fired, skipped, failed), failed > 0 and THEME.ERR or THEME.OK)
end

local function mkBtn(parent, text, x, w, color, fn)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(w, 32)
	b.Position = UDim2.fromOffset(x, 0)
	b.BackgroundColor3 = color or THEME.BTN
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 13
	b.TextColor3 = THEME.TEXT
	b.Text = text
	b.AutoButtonColor = false
	b.Parent = parent
	corner(b, 8)
	b.MouseButton1Click:Connect(fn)
	return b
end

local function destroyGui()
	S.stopped = true
	S.recording = false
	stopInbound()
	if f10Conn then
		pcall(function()
			f10Conn:Disconnect()
		end)
	end
	if dragConn then
		pcall(function()
			dragConn:Disconnect()
		end)
	end
	if dragBegan then
		pcall(function()
			dragBegan:Disconnect()
		end)
	end
	if dragEnded then
		pcall(function()
			dragEnded:Disconnect()
		end)
	end
	logLabel = nil
	if gui then
		pcall(function()
			gui:Destroy()
		end)
		gui = nil
	end
end

local function createGui()
	pcall(function()
		if lp then
			local pg = lp:FindFirstChild("PlayerGui")
			if pg then
				local old = pg:FindFirstChild("ActionSpy")
				if old then
					old:Destroy()
				end
			end
		end
		local old = CoreGui:FindFirstChild("ActionSpy")
		if old then
			old:Destroy()
		end
	end)

	gui = Instance.new("ScreenGui")
	gui.Name = "ActionSpy"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 125
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	parentGui(gui)

	win = Instance.new("Frame")
	win.Size = UDim2.fromOffset(720, 380)
	win.Position = UDim2.fromOffset(64, 64)
	win.BackgroundColor3 = THEME.BG
	win.BorderSizePixel = 0
	win.Parent = gui
	corner(win, 10)

	local top = Instance.new("Frame")
	top.Size = UDim2.new(1, 0, 0, 40)
	top.BackgroundColor3 = THEME.PANEL
	top.BorderSizePixel = 0
	top.Parent = win
	corner(top, 10)

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(12, 0)
	title.Size = UDim2.new(1, -52, 1, 0)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = THEME.TEXT
	title.Text = "Action Spy"
	title.Parent = top

	local close = Instance.new("TextButton")
	close.Size = UDim2.fromOffset(28, 24)
	close.Position = UDim2.new(1, -36, 0.5, -12)
	close.BackgroundColor3 = THEME.BTN
	close.BorderSizePixel = 0
	close.Text = "X"
	close.Font = Enum.Font.GothamBold
	close.TextSize = 12
	close.TextColor3 = THEME.TEXT
	close.Parent = top
	corner(close, 6)
	close.MouseButton1Click:Connect(destroyGui)

	dragBegan = top.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			dragStart = input.Position
			startPos = win.Position
		end
	end)
	dragEnded = top.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)
	dragConn = UIS.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			local d = input.Position - dragStart
			win.Position = UDim2.fromOffset(startPos.X.Offset + d.X, startPos.Y.Offset + d.Y)
		end
	end)

	local bar = Instance.new("Frame")
	bar.BackgroundTransparency = 1
	bar.Position = UDim2.fromOffset(12, 52)
	bar.Size = UDim2.new(1, -24, 0, 32)
	bar.Parent = win

	recBtn = mkBtn(bar, "Record", 0, 120, THEME.BTN, toggleRecord)
	startBtn = mkBtn(bar, "Start", 132, 120, THEME.OK, doStart)

	local listHold = Instance.new("Frame")
	listHold.Position = UDim2.fromOffset(12, 96)
	listHold.Size = UDim2.new(0, 280, 1, -148)
	listHold.BackgroundColor3 = THEME.PANEL
	listHold.BorderSizePixel = 0
	listHold.Parent = win
	corner(listHold, 8)

	listFrame = Instance.new("ScrollingFrame")
	listFrame.Position = UDim2.fromOffset(4, 4)
	listFrame.Size = UDim2.new(1, -8, 1, -8)
	listFrame.BackgroundTransparency = 1
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 4
	listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	listFrame.Parent = listHold
	local lay = Instance.new("UIListLayout")
	lay.Padding = UDim.new(0, 1)
	lay.Parent = listFrame

	local noteHold = Instance.new("Frame")
	noteHold.Position = UDim2.fromOffset(300, 96)
	noteHold.Size = UDim2.new(1, -312, 1, -148)
	noteHold.BackgroundColor3 = THEME.PANEL
	noteHold.BorderSizePixel = 0
	noteHold.Parent = win
	corner(noteHold, 8)

	noteBox = Instance.new("TextBox")
	noteBox.Position = UDim2.fromOffset(8, 8)
	noteBox.Size = UDim2.new(1, -16, 1, -16)
	noteBox.BackgroundTransparency = 1
	noteBox.BorderSizePixel = 0
	noteBox.ClearTextOnFocus = false
	noteBox.MultiLine = true
	noteBox.TextWrapped = true
	noteBox.TextXAlignment = Enum.TextXAlignment.Left
	noteBox.TextYAlignment = Enum.TextYAlignment.Top
	noteBox.Font = Enum.Font.Code
	noteBox.TextSize = 13
	noteBox.TextColor3 = THEME.TEXT
	noteBox.PlaceholderColor3 = THEME.DIM
	noteBox.PlaceholderText = "fire(Remote):\n\nwait(0.50)\n\nfire(Other):"
	noteBox.Text = "-- record, then stop. this notepad fills with fire() / wait()"
	noteBox.Parent = noteHold

	logLabel = Instance.new("TextLabel")
	logLabel.Position = UDim2.new(0, 12, 1, -40)
	logLabel.Size = UDim2.new(1, -24, 0, 28)
	logLabel.BackgroundColor3 = THEME.PANEL
	logLabel.BorderSizePixel = 0
	logLabel.Font = Enum.Font.Gotham
	logLabel.TextSize = 11
	logLabel.TextXAlignment = Enum.TextXAlignment.Left
	logLabel.TextColor3 = THEME.DIM
	logLabel.TextWrapped = true
	logLabel.Text = "  Record → do the action → Record again to save. Start replays it. F10 closes."
	logLabel.Parent = win
	corner(logLabel, 6)
end

local function boot()
	if type(getgenv) == "function" then
		pcall(function()
			local g = getgenv()
			if g.ActionSpyStop then
				pcall(g.ActionSpyStop)
			end
			g.ActionSpyStop = destroyGui
		end)
	end
	createGui()
	refreshList()
	f10Conn = UIS.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.F10 then
			destroyGui()
		end
	end)
end

boot()
