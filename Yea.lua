-- ActionSpy.lua
-- Record: listen to incoming + outgoing remotes, then save.
-- Start: replay the last saved recording (outgoing only, same order/timing).
-- One take. No tabs, dump, copy, or remotes browser.

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")
local lp = Players.LocalPlayer
local unpack = unpack or table.unpack

local THEME = {
	BG = Color3.fromRGB(16, 16, 20),
	PANEL = Color3.fromRGB(26, 26, 32),
	BTN = Color3.fromRGB(38, 38, 48),
	TEXT = Color3.fromRGB(236, 236, 240),
	DIM = Color3.fromRGB(138, 138, 148),
	WARN = Color3.fromRGB(255, 176, 64),
	ERR = Color3.fromRGB(232, 78, 78),
	OK = Color3.fromRGB(72, 196, 128),
	OUT = Color3.fromRGB(72, 196, 128),
	IN = Color3.fromRGB(160, 140, 255),
	SEL = Color3.fromRGB(56, 56, 88),
	CARET = Color3.fromRGB(255, 214, 102),
	LINE = Color3.fromRGB(48, 52, 78),
	STROKE = Color3.fromRGB(58, 58, 72),
	HOVER = Color3.fromRGB(52, 52, 66),
}

local NOISY = {
	"heartbeat", "ping", "fps", "mouse", "camera", "tick", "replicate",
	"render", "inputstate", "lookvector", "footstep", "animation",
	"positionupdate", "cframe", "syncpos", "characterlook", "getping",
	"updatemouse", "physics", "collision", "cameramove", "stream",
	"byte", "ack", "keepalive", "keep_alive", "clock",
	"livetime", "getlivetime", "getthelivetime", "servertime", "clienttime",
	"gettime", "osclock", "timestamp", "timesync", "synctime", "unixtime",
	"worldtime", "networktime", "remotetime", "servertick", "clienttick",
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
	stopReplay = false,
	selected = {},
	backup = nil,
	editIndex = 1,
	listFilter = "",
	minimized = false,
	listW = 280,
	inspectOpen = false,
	inspectW = 250,
}

local LINE_H = 18
local noteData = { "-- record, then stop.", "-- Click a line to edit. Enter = new line. Empty line + Backspace = delete." }
local editSlot = 1
local noteRowFrames = {}
local noteBusy = false

local gui, win, logLabel, recBtn, startBtn, listFrame, noteBox, noteScroll, argLab
local repeatBox, gapBox, waitAllBox, filterBox, statusLab, listHold, noteHold, splitBar
local inspHold, inspArrow, inspBody, inspHead
local f10Conn, dragConn, dragBegan, dragEnded, noteKeyConn
local dragging, dragStart, startPos
local resizing, resizeStart, startSize, splitting, splitStart, splitW
local rebuildNote, layoutPanels, markPlayLine, showInspect, tryDeleteEmptyLine, placeInspect
local btnBase = {}

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

local function stroke(inst, col, thick)
	local ok, s = pcall(function()
		local u = Instance.new("UIStroke")
		u.Color = col or THEME.STROKE
		u.Thickness = thick or 1
		u.Parent = inst
		return u
	end)
	if ok then
		return s
	end
end

local function tween(inst, props, t)
	if not inst then
		return
	end
	pcall(function()
		TweenService:Create(
			inst,
			TweenInfo.new(t or 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			props
		):Play()
	end)
end

local function addPressAnim(b)
	if not b then
		return
	end
	local sc = Instance.new("UIScale")
	sc.Scale = 1
	sc.Parent = b
	if b.AnchorPoint == Vector2.new(0, 0) and b.Size.X.Scale == 0 and b.Size.Y.Scale == 0 then
		local sz = b.Size
		local pos = b.Position
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		b.Position = UDim2.new(
			pos.X.Scale,
			pos.X.Offset + sz.X.Offset * 0.5,
			pos.Y.Scale,
			pos.Y.Offset + sz.Y.Offset * 0.5
		)
	end
	b.MouseButton1Down:Connect(function()
		tween(sc, { Scale = 0.88 }, 0.06)
	end)
	local function restore()
		tween(sc, { Scale = 1 }, 0.1)
	end
	b.MouseButton1Up:Connect(restore)
	b.MouseLeave:Connect(restore)
end

local function isInst(v)
	local ok, r = pcall(function()
		return typeof(v) == "Instance"
	end)
	return ok and r == true
end

local function paintBtn(b, color)
	if not b then
		return
	end
	btnBase[b] = color
	tween(b, { BackgroundColor3 = color }, 0.12)
end

local function trunc(s, n)
	s = tostring(s or "")
	n = n or 160
	if #s <= n then
		return s
	end
	return string.sub(s, 1, n - 1) .. "…"
end

local function compactName(name)
	return string.lower((string.gsub(tostring(name or ""), "[^%a%d]", "")))
end

local function isNoisy(name)
	local raw = string.lower(tostring(name or ""))
	local compact = compactName(name)
	for i = 1, #NOISY do
		local tok = NOISY[i]
		if string.find(raw, tok, 1, true) or string.find(compact, tok, 1, true) then
			return true
		end
	end
	if string.find(compact, "live", 1, true) and string.find(compact, "time", 1, true) then
		return true
	end
	return false
end

local function lineColor(line)
	local low = string.lower(tostring(line or ""))
	local t = string.match(tostring(line or ""), "^%s*(.-)%s*$") or ""
	if t == "" or string.match(low, "^%s*%-%-") then
		return THEME.DIM
	end
	if string.match(low, "^%s*in[%s%p]") then
		return THEME.IN
	end
	if string.match(low, "^%s*out[%s%p]") then
		return THEME.OUT
	end
	if string.match(low, "^%s*wait%s*%(") then
		return THEME.WARN
	end
	return THEME.TEXT
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
	if isInst(ev.remote) and ev.remote.Parent then
		return ev.remote
	end
	local byPath = fromPath(ev.path)
	if isInst(byPath) then
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

local function tyof(v)
	if type(typeof) == "function" then
		local ok, t = pcall(typeof, v)
		if ok then
			return t
		end
	end
	return type(v)
end

local function luaVal(v, depth, indent)
	depth = depth or 0
	indent = indent or ""
	if v == nil then
		return "nil"
	end
	if depth > 3 then
		return "nil--[[depth]]"
	end
	local ty = tyof(v)
	if ty == "boolean" then
		if v then
			return "true"
		end
		return "false"
	end
	if ty == "number" then
		if v ~= v then
			return "0/0"
		end
		if v == math.huge then
			return "math.huge"
		end
		if v == -math.huge then
			return "-math.huge"
		end
		return string.format("%.10g", v)
	end
	if ty == "string" then
		return string.format("%q", v)
	end
	if ty == "Vector3" then
		return string.format("Vector3.new(%.5f, %.5f, %.5f)", v.X, v.Y, v.Z)
	end
	if ty == "Vector2" then
		return string.format("Vector2.new(%.5f, %.5f)", v.X, v.Y)
	end
	if ty == "CFrame" then
		local ok, a, b, c, d, e, f, g, h, i, j, k, l = pcall(function()
			return v:GetComponents()
		end)
		if ok then
			return string.format(
				"CFrame.new(%.5f, %.5f, %.5f, %.5f, %.5f, %.5f, %.5f, %.5f, %.5f, %.5f, %.5f, %.5f)",
				a, b, c, d, e, f, g, h, i, j, k, l
			)
		end
	end
	if ty == "Color3" then
		return string.format("Color3.new(%.5f, %.5f, %.5f)", v.R, v.G, v.B)
	end
	if ty == "UDim2" then
		return string.format(
			"UDim2.new(%.4f, %d, %.4f, %d)",
			v.X.Scale,
			v.X.Offset,
			v.Y.Scale,
			v.Y.Offset
		)
	end
	if ty == "UDim" then
		return string.format("UDim.new(%.4f, %d)", v.Scale, v.Offset)
	end
	if ty == "BrickColor" then
		return string.format("BrickColor.new(%q)", tostring(v))
	end
	if ty == "EnumItem" then
		return tostring(v)
	end
	if ty == "Instance" then
		local ok, full = pcall(function()
			return v:GetFullName()
		end)
		if not ok or not full then
			return "nil--[[instance]]"
		end
		local s = "game"
		for part in string.gmatch(full, "[^.]+") do
			if string.match(part, "^[%a_][%w_]*$") then
				s = s .. "." .. part
			else
				s = s .. ":FindFirstChild(" .. string.format("%q", part) .. ")"
			end
		end
		return s
	end
	if ty == "table" then
		local n = 0
		local isArr = true
		for k, _ in pairs(v) do
			n = n + 1
			if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
				isArr = false
			end
		end
		if n == 0 then
			return "{}"
		end
		local nextIndent = indent .. "  "
		if isArr then
			if n == 1 and type(v[1]) ~= "table" then
				return "{ " .. luaVal(v[1], depth + 1, nextIndent) .. " }"
			end
			local parts = {}
			for i = 1, n do
				parts[i] = nextIndent .. luaVal(v[i], depth + 1, nextIndent)
			end
			return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
		end
		local parts = {}
		for k, val in pairs(v) do
			local ks
			if type(k) == "string" and string.match(k, "^[%a_][%w_]*$") then
				ks = k
			else
				ks = "[" .. luaVal(k, depth + 1, nextIndent) .. "]"
			end
			parts[#parts + 1] = nextIndent .. ks .. " = " .. luaVal(val, depth + 1, nextIndent)
			if #parts >= 12 then
				parts[#parts + 1] = nextIndent .. "--[[...]]"
				break
			end
		end
		return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
	end
	return "nil--[[ " .. ty .. " ]]"
end

local function luaArgs(packed)
	if type(packed) ~= "table" then
		return ""
	end
	local n = packed.n or 0
	local parts = {}
	for i = 1, n do
		parts[i] = luaVal(packed[i])
	end
	return table.concat(parts, ", ")
end

local function luaArgsPretty(packed, indent)
	indent = indent or "  "
	if type(packed) ~= "table" then
		return ""
	end
	local n = packed.n or 0
	if n <= 0 then
		return ""
	end
	if n == 1 and type(packed[1]) ~= "table" then
		return luaVal(packed[1], 0, indent)
	end
	local parts = {}
	for i = 1, n do
		parts[i] = indent .. luaVal(packed[i], 0, indent)
	end
	return "\n" .. table.concat(parts, ",\n") .. "\n"
end

local function pathToLua(full)
	full = tostring(full or "")
	if full == "" then
		return "nil"
	end
	local s = "game"
	for part in string.gmatch(full, "[^.]+") do
		if string.match(part, "^[%a_][%w_]*$") then
			s = s .. "." .. part
		else
			s = s .. ":FindFirstChild(" .. string.format("%q", part) .. ")"
		end
	end
	return s
end

local function remotePath(ev)
	if not ev then
		return "?"
	end
	if isInst(ev.remote) then
		local ok, full = pcall(function()
			return ev.remote:GetFullName()
		end)
		if ok and full and full ~= "" then
			return full
		end
	end
	local p = tostring(ev.path or "")
	if p ~= "" and string.find(p, ".", 1, true) then
		return p
	end
	return tostring(ev.name or "?")
end

local function remoteClass(ev)
	if not ev then
		return "?"
	end
	if ev.className and ev.className ~= "" then
		return tostring(ev.className)
	end
	if isInst(ev.remote) then
		local ok, c = pcall(function()
			return ev.remote.ClassName
		end)
		if ok and c then
			return tostring(c)
		end
	end
	return "?"
end

local function eventSnippet(ev)
	if not ev then
		return "-- nothing selected"
	end
	local path = remotePath(ev)
	local className = remoteClass(ev)
	local dir = ev.inbound and "game → you (inbound)" or "you → game (outbound)"
	local method = tostring(ev.method or (ev.inbound and "OnClientEvent" or "FireServer"))
	local n = (ev.packed and ev.packed.n) or 0
	local lines = {
		"-- Explorer path",
		"-- " .. path,
		"-- Class: " .. className,
		"-- " .. dir,
		"-- Method: " .. method,
		"",
	}
	if ev.inbound then
		lines[#lines + 1] = "-- received args:"
		if n <= 0 then
			lines[#lines + 1] = "-- (none)"
		else
			local body = luaArgsPretty(ev.packed, "  ")
			if string.sub(body, 1, 1) == "\n" then
				lines[#lines + 1] = "-- ("
				for part in string.gmatch(body, "[^\n]+") do
					lines[#lines + 1] = "-- " .. part
				end
				lines[#lines + 1] = "-- )"
			else
				lines[#lines + 1] = "-- " .. body
			end
		end
	else
		local target = pathToLua(path)
		local body = luaArgsPretty(ev.packed, "  ")
		if n <= 0 then
			lines[#lines + 1] = target .. ":" .. method .. "()"
		else
			lines[#lines + 1] = target .. ":" .. method .. "(" .. body .. ")"
		end
	end
	return table.concat(lines, "\n")
end

local function pause(sec)
	sec = tonumber(sec) or 0
	if sec < 0 then
		sec = 0
	end
	if sec > 8 then
		sec = 8
	end
	if sec < 0.03 then
		sec = 0.03
	end
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
	if statusLab then
		if S.recording then
			statusLab.Text = "REC  " .. (S.live and #S.live.events or 0)
			statusLab.TextColor3 = THEME.ERR
		elseif S.replaying then
			statusLab.Text = "PLAY"
			statusLab.TextColor3 = THEME.OK
		else
			statusLab.Text = "idle"
			statusLab.TextColor3 = THEME.DIM
		end
	end
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
		if i > 1 and gap >= 0.05 then
			lines[#lines + 1] = string.format("wait(%.2f)", gap)
		end
		lastDelay = ev.delay or lastDelay
		local name = tostring(ev.name or "Remote")
		local ident = string.match(name, "^[%a_][%w_]*$")
		local shown = ident and name or string.format("%q", name)
		if ev.inbound then
			lines[#lines + 1] = "in fire(" .. shown .. ")"
		else
			lines[#lines + 1] = "out fire(" .. shown .. ")"
		end
	end
	return table.concat(lines, "\n")
end

local function clipSet(text)
	text = tostring(text or "")
	local names = {
		"setclipboard",
		"toclipboard",
		"set_clipboard",
		"writeclipboard",
		"setrbxclipboard",
	}
	for i = 1, #names do
		local fn = pickFn(names[i])
		if type(fn) == "function" then
			local ok = pcall(fn, text)
			if ok then
				return true
			end
		end
	end
	local syn = envGet("syn")
	if type(syn) == "table" then
		if type(syn.write_clipboard) == "function" then
			local ok = pcall(syn.write_clipboard, text)
			if ok then
				return true
			end
		end
		if type(syn.set_clipboard) == "function" then
			local ok = pcall(syn.set_clipboard, text)
			if ok then
				return true
			end
		end
	end
	local clip = envGet("Clipboard")
	if type(clip) == "table" and type(clip.set) == "function" then
		local ok = pcall(clip.set, text)
		if ok then
			return true
		end
	end
	print("-------- ActionSpy script --------")
	print(text)
	print("-------- end --------")
	return false
end

local function parseNameToken(tok)
	tok = string.match(tostring(tok or ""), "^%s*(.-)%s*$") or ""
	local dq = string.match(tok, "^\"(.*)\"$")
	if dq then
		return dq
	end
	local sq = string.match(tok, "^'(.*)'$")
	if sq then
		return sq
	end
	return tok
end

local function parseNote(text)
	local steps = {}
	local lineNo = 0
	text = tostring(text or "") .. "\n"
	for line in string.gmatch(text, "(.-)\n") do
		lineNo = lineNo + 1
		local t = string.match(line, "^%s*(.-)%s*$") or ""
		if t ~= "" and not string.match(t, "^%-%-") then
			local w = string.match(t, "^wait%s*%(%s*([%d%.]+)%s*%)")
			if w then
				steps[#steps + 1] = { kind = "wait", t = tonumber(w) or 0, line = lineNo }
			else
				local inner = string.match(t, "[Ff][Ii][Rr][Ee]%s*%(%s*(.-)%s*%)")
				if inner then
					local name = parseNameToken(inner)
					local low = string.lower(t)
					local inbound = false
					if string.match(low, "^in[%s%p]") or string.match(low, "^in$") then
						inbound = true
					end
					if string.match(low, "^out[%s%p]") then
						inbound = false
					end
					if string.find(low, "%-%-%s*inbound", 1, false) then
						inbound = true
					end
					if string.find(low, "%-%-%s*outbound", 1, false) then
						inbound = false
					end
					steps[#steps + 1] = {
						kind = "fire",
						name = name,
						inbound = inbound,
						invoke = string.find(low, "invoke", 1, true) ~= nil,
						line = lineNo,
					}
				end
			end
		end
	end
	return steps
end

local function namesEqual(a, b)
	return string.lower(tostring(a or "")) == string.lower(tostring(b or ""))
end

local function typeKey(inbound, name)
	return (inbound and "in|" or "out|") .. string.lower(tostring(name or ""))
end

local function ctrlHeld()
	local ok, v = pcall(function()
		return UIS:IsKeyDown(Enum.KeyCode.LeftControl) or UIS:IsKeyDown(Enum.KeyCode.RightControl)
	end)
	return ok and v == true
end

local function keyFromLine(t)
	t = string.match(tostring(t or ""), "^%s*(.-)%s*$") or ""
	if t == "" or string.match(t, "^%-%-") then
		return nil
	end
	local inner = string.match(t, "[Ff][Ii][Rr][Ee]%s*%(%s*(.-)%s*%)")
	if not inner then
		return nil
	end
	local name = parseNameToken(inner)
	local low = string.lower(t)
	local inbound = false
	if string.match(low, "^in[%s%p]") or string.match(low, "^in$") then
		inbound = true
	end
	if string.match(low, "^out[%s%p]") then
		inbound = false
	end
	if string.find(low, "%-%-%s*inbound", 1, false) then
		inbound = true
	end
	if string.find(low, "%-%-%s*outbound", 1, false) then
		inbound = false
	end
	return typeKey(inbound, name)
end

local function copyTake(take)
	if not take then
		return nil
	end
	local evs = {}
	for i = 1, #(take.events or {}) do
		evs[i] = take.events[i]
	end
	return { events = evs }
end

local function trimLine(s)
	return string.match(tostring(s or ""), "^%s*(.-)%s*$") or ""
end

local function isWaitLine(s)
	local t = trimLine(s)
	return t ~= "" and not string.match(t, "^%-%-") and string.match(t, "^wait%s*%(") ~= nil
end

local function squashWaits(lines)
	local out = {}
	local i = 1
	while i <= #lines do
		if isWaitLine(lines[i]) then
			out[#out + 1] = lines[i]
			i = i + 1
			while i <= #lines and (trimLine(lines[i]) == "" or isWaitLine(lines[i])) do
				i = i + 1
			end
		else
			out[#out + 1] = lines[i]
			i = i + 1
		end
	end
	return out
end

local function selectedCount()
	local n = 0
	for _ in pairs(S.selected or {}) do
		n = n + 1
	end
	return n
end

local function splitNote(text)
	local t = {}
	local s = tostring(text or "")
	if s == "" then
		return { "" }
	end
	for line in string.gmatch(s .. "\n", "(.-)\n") do
		t[#t + 1] = line
	end
	if #t == 0 then
		t[1] = ""
	end
	while #t > 1 and t[#t] == "" do
		t[#t] = nil
	end
	return t
end

local function commitEdit()
	if noteBox and noteBox.Parent and type(editSlot) == "number" and noteData[editSlot] ~= nil then
		noteData[editSlot] = noteBox.Text
	end
end

local function getNoteText()
	commitEdit()
	return table.concat(noteData, "\n")
end

local function setNoteText(text)
	noteBusy = true
	noteBox = nil
	editSlot = nil
	noteData = splitNote(text)
	S.editIndex = 1
	if rebuildNote then
		rebuildNote(false)
	else
		noteBusy = false
	end
end

tryDeleteEmptyLine = function()
	if noteBusy then
		return false
	end
	if not noteBox or not noteBox.Parent then
		return false
	end
	local focused = false
	pcall(function()
		focused = noteBox:IsFocused()
	end)
	if not focused then
		return false
	end
	local text = tostring(noteBox.Text or "")
	if text ~= "" then
		return false
	end
	local idx = editSlot or S.editIndex
	if type(idx) ~= "number" or idx < 1 or idx > #noteData then
		return false
	end
	if #noteData <= 1 then
		noteData[1] = ""
		noteBox.Text = ""
		return true
	end
	noteBusy = true
	table.remove(noteData, idx)
	if S.editIndex > #noteData then
		S.editIndex = #noteData
	elseif idx > 1 and S.editIndex >= idx then
		S.editIndex = idx - 1
	else
		S.editIndex = math.min(idx, #noteData)
	end
	if rebuildNote then
		rebuildNote(true)
	else
		noteBusy = false
	end
	return true
end

local function cursorLine()
	return S.editIndex or 1
end

local function jumpNoteToKey(key)
	if not key then
		return
	end
	commitEdit()
	for i = 1, #noteData do
		if keyFromLine(noteData[i]) == key then
			S.editIndex = i
			if rebuildNote then
				rebuildNote(true)
			end
			if noteScroll then
				local y = (i - 1) * LINE_H - 24
				if y < 0 then
					y = 0
				end
				noteScroll.CanvasPosition = Vector2.new(0, y)
			end
			return
		end
	end
end

local function claimEvent(take, used, name, inbound)
	if not take then
		return nil
	end
	local wantIn = inbound and true or false
	for i = 1, #take.events do
		if not used[i] then
			local ev = take.events[i]
			local isIn = ev.inbound and true or false
			if namesEqual(ev.name, name) and isIn == wantIn then
				used[i] = true
				return ev
			end
		end
	end
	return nil
end

local function previewArgs()
	if not argLab then
		return
	end
	commitEdit()
	local line = S.editIndex or 1
	local steps = parseNote(getNoteText())
	local idx
	for i = 1, #steps do
		if steps[i].line == line then
			idx = i
			break
		end
	end
	if not idx then
		argLab.Text = "  click a line · Enter new line · empty Backspace deletes"
		argLab.TextColor3 = THEME.DIM
		if showInspect then
			showInspect(nil, "Click a notepad line or a recorded event.")
		end
		return
	end
	local step = steps[idx]
	if step.kind == "wait" then
		argLab.Text = string.format("  wait(%.2f)", step.t or 0)
		argLab.TextColor3 = THEME.WARN
		if showInspect then
			showInspect(nil, string.format("-- wait\nwait(%.2f)", step.t or 0))
		end
		return
	end
	if step.inbound then
		argLab.Text = "  in " .. tostring(step.name) .. "  (game → you, Start skips this)"
		argLab.TextColor3 = THEME.IN
	end
	local take = S.saved
	if not take then
		if not step.inbound then
			argLab.Text = "  out " .. tostring(step.name) .. "  (record first to capture args)"
			argLab.TextColor3 = THEME.OUT
		end
		if showInspect then
			showInspect(nil, "-- no recording saved yet\n-- " .. tostring(step.name))
		end
		return
	end
	local used = {}
	for i = 1, idx - 1 do
		if steps[i].kind == "fire" then
			local wantIn = steps[i].inbound and true or false
			if wantIn == (step.inbound and true or false) then
				claimEvent(take, used, steps[i].name, wantIn)
			end
		end
	end
	local ev = claimEvent(take, used, step.name, step.inbound and true or false)
	if not ev then
		if not step.inbound then
			argLab.Text = "  out " .. tostring(step.name) .. "  (no saved args)"
			argLab.TextColor3 = THEME.ERR
		end
		if showInspect then
			showInspect(nil, "-- no matching recorded event for\n-- " .. tostring(step.name))
		end
		return
	end
	if not step.inbound then
		local shown = luaArgs(ev.packed)
		if shown == "" then
			shown = "no args"
		end
		argLab.Text = trunc(
			"  " .. tostring(ev.method or "FireServer") .. "  " .. tostring(step.name) .. "(" .. shown .. ")",
			240
		)
		argLab.TextColor3 = THEME.OUT
	end
	if showInspect then
		showInspect(ev)
	end
end

showInspect = function(ev, fallback)
	if not inspBody then
		return
	end
	local text
	if ev then
		text = eventSnippet(ev)
		if inspHead then
			inspHead.Text = trunc((ev.inbound and "in  " or "out  ") .. tostring(ev.name or "Remote"), 40)
			inspHead.TextColor3 = ev.inbound and THEME.IN or THEME.OUT
		end
		if not S.inspectOpen and inspHold then
			S.inspectOpen = true
			inspHold.Visible = true
			if placeInspect then
				placeInspect()
			elseif layoutPanels then
				layoutPanels()
			end
		end
	else
		text = tostring(fallback or "-- click a recorded event or a notepad line")
		if inspHead then
			inspHead.Text = "Inspector"
			inspHead.TextColor3 = THEME.DIM
		end
	end
	inspBody.Text = text
end

markPlayLine = function(line)
	line = tonumber(line)
	if not line then
		return
	end
	S.editIndex = line
	for i = 1, #noteRowFrames do
		local row = noteRowFrames[i]
		if row and row.Parent then
			if i == line then
				row.BackgroundColor3 = THEME.CARET
				row.BackgroundTransparency = 0.55
			else
				row.BackgroundColor3 = THEME.LINE
				row.BackgroundTransparency = 1
			end
		end
	end
	if noteScroll then
		local y = (line - 1) * LINE_H - 40
		if y < 0 then
			y = 0
		end
		noteScroll.CanvasPosition = Vector2.new(0, y)
	end
end

local function refreshList()
	if not listFrame then
		return
	end
	for _, ch in ipairs(listFrame:GetChildren()) do
		if not ch:IsA("UIListLayout") then
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
		return
	end
	local maxShow = math.min(#take.events, 80)
	local shown = 0
	local filt = string.lower(tostring(S.listFilter or ""))
	for i = 1, #take.events do
		if shown >= maxShow then
			break
		end
		local ev = take.events[i]
		if filt == "" or string.find(string.lower(tostring(ev.name or "")), filt, 1, true) then
			shown = shown + 1
			local key = typeKey(ev.inbound, ev.name)
			local on = S.selected[key] == true
			local row = Instance.new("TextButton")
			row.Size = UDim2.new(1, -4, 0, 18)
			row.BackgroundColor3 = THEME.SEL
			row.BackgroundTransparency = on and 0.25 or 1
			row.BorderSizePixel = 0
			row.AutoButtonColor = false
			row.Font = Enum.Font.Gotham
			row.TextSize = 12
			row.TextXAlignment = Enum.TextXAlignment.Left
			row.TextColor3 = ev.inbound and THEME.IN or THEME.OUT
			row.Text = "  " .. trunc(ev.label, 70)
			row.Parent = listFrame
			row.MouseEnter:Connect(function()
				if not on then
					tween(row, { BackgroundTransparency = 0.7 }, 0.08)
				end
			end)
			row.MouseLeave:Connect(function()
				tween(row, { BackgroundTransparency = on and 0.25 or 1 }, 0.1)
			end)
			row.MouseButton1Click:Connect(function()
				if S.recording or S.replaying then
					return
				end
				if ctrlHeld() then
					if S.selected[key] then
						S.selected[key] = nil
					else
						S.selected[key] = true
					end
				else
					S.selected = { [key] = true }
					jumpNoteToKey(key)
					if showInspect then
						showInspect(ev)
					end
				end
				refreshList()
			end)
		end
	end
	if shown == 0 then
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.new(1, -4, 0, 22)
		empty.BackgroundTransparency = 1
		empty.Font = Enum.Font.Gotham
		empty.TextSize = 12
		empty.TextXAlignment = Enum.TextXAlignment.Left
		empty.TextColor3 = THEME.DIM
		empty.Text = filt ~= "" and "  No remotes match that filter." or "  Nothing saved yet."
		empty.Parent = listFrame
	elseif #take.events > maxShow then
		local more = Instance.new("TextLabel")
		more.Size = UDim2.new(1, -4, 0, 18)
		more.BackgroundTransparency = 1
		more.Font = Enum.Font.Gotham
		more.TextSize = 12
		more.TextXAlignment = Enum.TextXAlignment.Left
		more.TextColor3 = THEME.DIM
		more.Text = "  … +" .. tostring(#take.events - shown) .. " more"
		more.Parent = listFrame
	end
end

local function schedulePaint()
	if S.recording and S.live then
		if logLabel and logLabel.Parent then
			logLabel.Text = "  Recording… " .. tostring(#S.live.events) .. " remotes (notepad fills when you stop)"
			logLabel.TextColor3 = THEME.DIM
		end
		if statusLab then
			statusLab.Text = "REC  " .. tostring(#S.live.events)
			statusLab.TextColor3 = THEME.ERR
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

local function dropSpamNamed(key)
	if not S.live then
		return
	end
	S.live.spam = S.live.spam or {}
	S.live.spam[key] = true
	local src = S.live.events
	local dst = {}
	for i = 1, #src do
		if string.lower(tostring(src[i].name or "")) ~= key then
			dst[#dst + 1] = src[i]
		end
	end
	S.live.events = dst
end

local function tooFast(name)
	if not S.live then
		return false
	end
	local key = string.lower(tostring(name or ""))
	if key == "" then
		return false
	end
	S.live.spam = S.live.spam or {}
	if S.live.spam[key] then
		return true
	end
	S.live.hits = S.live.hits or {}
	local hits = S.live.hits[key]
	if not hits then
		hits = {}
		S.live.hits[key] = hits
	end
	local now = os.clock()
	hits[#hits + 1] = now
	if #hits > 24 then
		local keep = {}
		for i = #hits - 15, #hits do
			keep[#keep + 1] = hits[i]
		end
		hits = keep
		S.live.hits[key] = hits
	end
	local n = 0
	for i = #hits, 1, -1 do
		if now - hits[i] <= 0.6 then
			n = n + 1
		else
			break
		end
	end
	if n >= 5 then
		dropSpamNamed(key)
		return true
	end
	return false
end

local function addCaptured(remote, method, inbound, packed)
	if S.replaying or S.stopped or not S.recording or not S.live then
		return
	end
	if not isInst(remote) then
		return
	end
	if #S.live.events >= 250 then
		return
	end
	local name = ""
	local path = ""
	local className = ""
	pcall(function()
		name = remote.Name
		path = remote:GetFullName()
		className = remote.ClassName
	end)
	if isNoisy(name) or tooFast(name) then
		return
	end
	local now = os.clock()
	if S.t0 == 0 then
		S.t0 = now
	end
	local ev = {
		delay = now - S.t0,
		method = method,
		inbound = inbound and true or false,
		remote = remote,
		name = name,
		path = (path ~= "" and path) or name,
		className = className,
		packed = packed,
		label = string.format("+%.2fs  %s  %s", now - S.t0, inbound and "in" or "out", name),
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
		if n >= 40 or not isInst(inst) then
			return
		end
		local okRe, isRe = pcall(function()
			return inst:IsA("RemoteEvent")
		end)
		local okUr, isUr = pcall(function()
			return inst:IsA("UnreliableRemoteEvent")
		end)
		if not ((okRe and isRe) or (okUr and isUr)) then
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
	S.live = { events = {}, spam = {}, hits = {} }
	S.selected = {}
	S.lastPaint = 0
	if recBtn then
		recBtn.Text = "Stop"
		paintBtn(recBtn, THEME.ERR)
	end
	setNoteText("-- recording…")
	refreshList()
	log("Listening (" .. tostring(how) .. "). Do the action, then press Record again to save.", THEME.OK)
	later(startInbound)
end

local function stopRecord()
	S.recording = false
	stopInbound()
	S.saved = S.live
	S.live = nil
	S.selected = {}
	S.backup = copyTake(S.saved)
	if recBtn then
		recBtn.Text = "Record"
		paintBtn(recBtn, THEME.BTN)
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
				if isInst(ev.remote) then
					ev.path = ev.remote:GetFullName()
					ev.className = ev.remote.ClassName
				end
			end)
		end
	end
	refreshList()
	if noteBox or rebuildNote then
		local src = scriptFromTake(take)
		setNoteText(src)
		S.originalNote = src
	end
	log(string.format("Saved. %d outbound, %d inbound. Edit the notepad, then Start runs THAT script.", out, inn), THEME.OK)
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
	local packed = ev.packed or { n = 0 }
	local n = packed.n or 0
	local args = {}
	for i = 1, n do
		args[i] = cloneArg(packed[i])
	end
	if ev.method == "FireServer" then
		local ok, err = pcall(function()
			remote:FireServer(unpack(args, 1, n))
		end)
		if ok then
			return true
		end
		ok, err = pcall(function()
			remote:InvokeServer(unpack(args, 1, n))
		end)
		return ok, err
	end
	if ev.method == "InvokeServer" then
		return pcall(function()
			remote:InvokeServer(unpack(args, 1, n))
		end)
	end
	return false, "skip"
end

local function finishReplay(msg, color)
	S.replaying = false
	S.stopReplay = false
	if startBtn then
		startBtn.Text = "Start"
		paintBtn(startBtn, THEME.OK)
	end
	if msg then
		log(msg, color)
	end
end

local function runReplay(take, steps, loops, loopGap, startAt)
	startAt = tonumber(startAt) or 1
	if startAt < 1 then
		startAt = 1
	end
	local fired, failed, skipped = 0, 0, 0
	for loop = 1, loops do
		if S.stopReplay or S.stopped then
			break
		end
		local used = {}
		for s = 1, startAt - 1 do
			local step = steps[s]
			if step and step.kind == "fire" and not step.inbound then
				claimEvent(take, used, step.name, false)
			end
		end
		for s = startAt, #steps do
			if S.stopReplay or S.stopped then
				break
			end
			local step = steps[s]
			if step.kind == "wait" then
				if markPlayLine then
					markPlayLine(step.line)
				end
				pause(step.t or 0.03)
			elseif step.inbound then
				skipped = skipped + 1
			else
				if markPlayLine then
					markPlayLine(step.line)
				end
				local ev = claimEvent(take, used, step.name, false)
				if not ev then
					failed = failed + 1
				else
					if step.invoke then
						ev = {
							remote = ev.remote,
							path = ev.path,
							name = ev.name,
							method = "InvokeServer",
							packed = ev.packed,
						}
					end
					local ok = fireEvent(ev)
					if ok then
						fired = fired + 1
					else
						failed = failed + 1
					end
					pause(0.05)
				end
			end
		end
		if loop < loops and not S.stopReplay then
			pause(loopGap)
		end
	end
	local extra = S.stopReplay and " Stopped." or ""
	finishReplay(
		string.format("Done.%s fired %d outbound, skipped %d inbound, failed %d.", extra, fired, skipped, failed),
		failed > 0 and THEME.ERR or THEME.OK
	)
end

local function loopSettings()
	local loops = 1
	if repeatBox then
		loops = math.floor(tonumber(repeatBox.Text) or 1)
	end
	if loops < 1 then
		loops = 1
	end
	if loops > 8 then
		loops = 8
	end
	local loopGap = 0.6
	if gapBox then
		loopGap = tonumber(gapBox.Text) or 0.6
	end
	if loopGap < 0.3 then
		loopGap = 0.3
	end
	if loopGap > 8 then
		loopGap = 8
	end
	return loops, loopGap
end

local function fallbackSteps(take)
	local steps = {}
	local last = 0
	for i = 1, #take.events do
		local ev = take.events[i]
		local gap = (ev.delay or 0) - last
		if i > 1 and gap >= 0.05 then
			steps[#steps + 1] = { kind = "wait", t = gap, line = i }
		end
		last = ev.delay or last
		steps[#steps + 1] = {
			kind = "fire",
			name = ev.name,
			inbound = ev.inbound and true or false,
			invoke = ev.method == "InvokeServer",
			line = i,
		}
	end
	return steps
end

local function beginReplay(take, steps, startAt, why)
	local loops, loopGap = loopSettings()
	S.replaying = true
	S.stopReplay = false
	if startBtn then
		startBtn.Text = "Stop"
		paintBtn(startBtn, THEME.ERR)
	end
	log(
		string.format(
			"%s x%d (x gap %.2fs between repeats). Stop to halt.",
			why or "Running notepad",
			loops,
			loopGap
		),
		THEME.OK
	)
	later(function()
		runReplay(take, steps, loops, loopGap, startAt)
	end)
end

local function doStart()
	if S.recording then
		log("Stop recording first (press Record again).", THEME.WARN)
		return
	end
	if S.replaying then
		S.stopReplay = true
		log("Stopping…", THEME.WARN)
		return
	end
	local take = S.saved
	if not take or #take.events == 0 then
		log("Nothing saved. Record something first.", THEME.WARN)
		return
	end
	local text = getNoteText()
	local steps = parseNote(text)
	local outFires = 0
	for i = 1, #steps do
		if steps[i].kind == "fire" and not steps[i].inbound then
			outFires = outFires + 1
		end
	end
	if outFires == 0 then
		steps = fallbackSteps(take)
	end
	beginReplay(take, steps, 1, "Running notepad")
end

local function doFromHere()
	if S.recording then
		log("Stop recording first.", THEME.WARN)
		return
	end
	if S.replaying then
		S.stopReplay = true
		log("Stopping…", THEME.WARN)
		return
	end
	local take = S.saved
	if not take or #take.events == 0 then
		log("Nothing saved. Record something first.", THEME.WARN)
		return
	end
	local steps = parseNote(getNoteText())
	local line = cursorLine()
	local startAt
	for i = 1, #steps do
		if (steps[i].line or 0) >= line then
			startAt = i
			break
		end
	end
	if not startAt then
		log("Nothing at or below the caret to run.", THEME.WARN)
		return
	end
	local outFires = 0
	for i = startAt, #steps do
		if steps[i].kind == "fire" and not steps[i].inbound then
			outFires = outFires + 1
		end
	end
	if outFires == 0 then
		log("No outbound fire() from the caret down. Click an out line, then From here.", THEME.WARN)
		return
	end
	beginReplay(take, steps, startAt, "From line " .. tostring(line))
end

local function doFireOne()
	if S.recording then
		log("Stop recording first.", THEME.WARN)
		return
	end
	if S.replaying then
		log("Wait until Start finishes.", THEME.WARN)
		return
	end
	local take = S.saved
	if not take or #take.events == 0 then
		log("Nothing saved. Record something first.", THEME.WARN)
		return
	end
	local steps = parseNote(getNoteText())
	local line = cursorLine()
	local idx
	for i = 1, #steps do
		if (steps[i].line or 0) >= line and steps[i].kind == "fire" and not steps[i].inbound then
			idx = i
			break
		end
	end
	if not idx then
		log("Put the caret on (or above) an out fire(...) line, then Fire 1.", THEME.WARN)
		return
	end
	local used = {}
	for i = 1, idx - 1 do
		if steps[i].kind == "fire" and not steps[i].inbound then
			claimEvent(take, used, steps[i].name, false)
		end
	end
	local step = steps[idx]
	local ev = claimEvent(take, used, step.name, false)
	if not ev then
		log("No recorded args for " .. tostring(step.name), THEME.ERR)
		return
	end
	if step.invoke then
		ev = {
			remote = ev.remote,
			path = ev.path,
			name = ev.name,
			method = "InvokeServer",
			packed = ev.packed,
		}
	end
	local ok = fireEvent(ev)
	if step.line then
		markPlayLine(step.line)
	end
	if ok then
		log("Fired 1: " .. tostring(step.name), THEME.OK)
	else
		log("Fire 1 failed: " .. tostring(step.name), THEME.ERR)
	end
end

local function doCopy()
	local body = getNoteText()
	if body == "" or string.find(body, "nothing recorded", 1, true) then
		log("Notepad is empty. Record first.", THEME.WARN)
		return
	end
	local script = "-- ActionSpy script (edit + Start in the GUI, or keep as notes)\n"
		.. "-- out = you → game   in = game → you (Start skips in)\n\n"
		.. body
	if clipSet(script) then
		log("Copied notepad to clipboard.", THEME.OK)
	else
		log("Clipboard blocked. Script printed in F9 console.", THEME.WARN)
	end
end

local function doReset()
	if S.recording then
		log("Stop recording first.", THEME.WARN)
		return
	end
	if not S.saved then
		log("Nothing to reset.", THEME.WARN)
		return
	end
	setNoteText(S.originalNote or scriptFromTake(S.backup or S.saved))
	if S.backup then
		S.saved = copyTake(S.backup)
	end
	S.selected = {}
	refreshList()
	log("Notepad restored to the recording.", THEME.OK)
end

local function filterSavedBySelection(keepHit)
	if not S.saved or not S.saved.events then
		return
	end
	local evs = {}
	for i = 1, #S.saved.events do
		local ev = S.saved.events[i]
		local hit = S.selected[typeKey(ev.inbound, ev.name)] and true or false
		if hit == keepHit then
			evs[#evs + 1] = ev
		end
	end
	S.saved.events = evs
end

local function doDeleteAll()
	if S.recording then
		log("Stop recording first.", THEME.WARN)
		return
	end
	if S.replaying then
		log("Wait until Start finishes.", THEME.WARN)
		return
	end
	if selectedCount() == 0 then
		log("Click a remote first (Ctrl+click for more), then Delete all.", THEME.WARN)
		return
	end
	local types = selectedCount()
	filterSavedBySelection(false)
	setNoteText(scriptFromTake(S.saved))
	S.selected = {}
	refreshList()
	local after = S.saved and S.saved.events and #S.saved.events or 0
	log(string.format("Removed %d type(s). Notepad now matches the %d leftover recorded events.", types, after), THEME.OK)
end

local function doKeepOnly()
	if S.recording then
		log("Stop recording first.", THEME.WARN)
		return
	end
	if S.replaying then
		log("Wait until Start finishes.", THEME.WARN)
		return
	end
	if selectedCount() == 0 then
		log("Click a remote first (Ctrl+click for more), then Keep only.", THEME.WARN)
		return
	end
	local types = selectedCount()
	filterSavedBySelection(true)
	setNoteText(scriptFromTake(S.saved))
	S.selected = {}
	refreshList()
	local after = S.saved and S.saved.events and #S.saved.events or 0
	log(string.format("Kept %d type(s). Notepad now matches the %d remaining recorded events.", types, after), THEME.OK)
end

local function doSetWaits()
	if S.recording then
		log("Stop recording first.", THEME.WARN)
		return
	end
	if S.replaying then
		log("Wait until Start finishes.", THEME.WARN)
		return
	end
	local sec = tonumber(waitAllBox and waitAllBox.Text or "")
	if not sec then
		log("Type a wait time first, e.g. 0.10", THEME.WARN)
		return
	end
	if sec < 0 then
		sec = 0
	elseif sec > 8 then
		sec = 8
	end
	local n = 0
	local keep = {}
	local text = getNoteText() .. "\n"
	for line in string.gmatch(text, "(.-)\n") do
		local t = trimLine(line)
		if t ~= "" and not string.match(t, "^%-%-") and string.match(t, "^wait%s*%(") then
			keep[#keep + 1] = string.format("wait(%.2f)", sec)
		else
			keep[#keep + 1] = line
		end
	end
	keep = squashWaits(keep)
	for i = 1, #keep do
		if isWaitLine(keep[i]) then
			n = n + 1
		end
	end
	setNoteText(table.concat(keep, "\n"))
	log(string.format("Set waits to %.2f (%d wait line(s), extras in a row removed).", sec, n), THEME.OK)
end

local function mkBtn(parent, text, x, w, color, fn)
	local base = color or THEME.BTN
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(w, 32)
	b.Position = UDim2.fromOffset(x, 0)
	b.BackgroundColor3 = base
	btnBase[b] = base
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 13
	b.TextColor3 = THEME.TEXT
	b.Text = text
	b.AutoButtonColor = false
	b.Parent = parent
	corner(b, 8)
	b.MouseEnter:Connect(function()
		local c = btnBase[b] or base
		tween(b, {
			BackgroundColor3 = Color3.new(
				math.min(c.R + 0.07, 1),
				math.min(c.G + 0.07, 1),
				math.min(c.B + 0.07, 1)
			),
		}, 0.1)
	end)
	b.MouseLeave:Connect(function()
		tween(b, { BackgroundColor3 = btnBase[b] or base }, 0.12)
	end)
	b.MouseButton1Down:Connect(function()
		local c = btnBase[b] or base
		tween(b, {
			BackgroundColor3 = Color3.new(c.R * 0.82, c.G * 0.82, c.B * 0.82),
		}, 0.06)
	end)
	b.MouseButton1Up:Connect(function()
		tween(b, { BackgroundColor3 = btnBase[b] or base }, 0.1)
	end)
	b.MouseButton1Click:Connect(fn)
	addPressAnim(b)
	return b
end

local function destroyGui()
	S.stopped = true
	S.recording = false
	S.stopReplay = true
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
	if noteKeyConn then
		pcall(function()
			noteKeyConn:Disconnect()
		end)
		noteKeyConn = nil
	end
	logLabel = nil
	inspBody = nil
	inspHead = nil
	inspHold = nil
	inspArrow = nil
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
	win.Size = UDim2.fromOffset(780, 420)
	win.Position = UDim2.fromOffset(64, 64)
	win.BackgroundColor3 = THEME.BG
	win.BorderSizePixel = 0
	win.ClipsDescendants = true
	win.Active = true
	win.Parent = gui
	corner(win, 12)
	stroke(win, THEME.STROKE, 1)
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 0.96
	uiScale.Parent = win
	tween(uiScale, { Scale = 1 }, 0.22)

	local top = Instance.new("Frame")
	top.Size = UDim2.new(1, 0, 0, 42)
	top.BackgroundColor3 = THEME.PANEL
	top.BorderSizePixel = 0
	top.Parent = win
	corner(top, 12)
	stroke(top, THEME.STROKE, 1)

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(14, 0)
	title.Size = UDim2.new(1, -96, 1, 0)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = THEME.TEXT
	title.Text = "Action Spy"
	title.Parent = top
	title.Active = true

	statusLab = Instance.new("TextLabel")
	statusLab.BackgroundTransparency = 1
	statusLab.Position = UDim2.new(1, -210, 0, 0)
	statusLab.Size = UDim2.fromOffset(110, 42)
	statusLab.Font = Enum.Font.Gotham
	statusLab.TextSize = 11
	statusLab.TextXAlignment = Enum.TextXAlignment.Right
	statusLab.TextColor3 = THEME.DIM
	statusLab.Text = "idle"
	statusLab.Parent = top

	local minBtn = Instance.new("TextButton")
	minBtn.Size = UDim2.fromOffset(28, 24)
	minBtn.Position = UDim2.new(1, -68, 0.5, -12)
	minBtn.BackgroundColor3 = THEME.BTN
	minBtn.BorderSizePixel = 0
	minBtn.Text = "–"
	minBtn.Font = Enum.Font.GothamBold
	minBtn.TextSize = 16
	minBtn.TextColor3 = THEME.TEXT
	minBtn.AutoButtonColor = false
	minBtn.Parent = top
	corner(minBtn, 6)
	addPressAnim(minBtn)

	local close = Instance.new("TextButton")
	close.Size = UDim2.fromOffset(28, 24)
	close.Position = UDim2.new(1, -36, 0.5, -12)
	close.BackgroundColor3 = THEME.BTN
	close.BorderSizePixel = 0
	close.Text = "X"
	close.Font = Enum.Font.GothamBold
	close.TextSize = 12
	close.TextColor3 = THEME.TEXT
	close.AutoButtonColor = false
	close.Parent = top
	corner(close, 6)
	addPressAnim(close)
	close.MouseEnter:Connect(function()
		tween(close, { BackgroundColor3 = THEME.ERR }, 0.1)
	end)
	close.MouseLeave:Connect(function()
		tween(close, { BackgroundColor3 = THEME.BTN }, 0.12)
	end)
	close.MouseButton1Click:Connect(destroyGui)

	local savedH = 420
	minBtn.MouseButton1Click:Connect(function()
		S.minimized = not S.minimized
		if S.minimized then
			savedH = win.AbsoluteSize.Y
			tween(win, { Size = UDim2.fromOffset(win.AbsoluteSize.X, 42) }, 0.18)
			minBtn.Text = "+"
		else
			tween(win, { Size = UDim2.fromOffset(win.AbsoluteSize.X, savedH) }, 0.18)
			minBtn.Text = "–"
		end
		later(function()
			if placeInspect then
				placeInspect()
			end
		end)
	end)

	dragBegan = title.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			resizing = false
			splitting = false
			dragStart = input.Position
			startPos = win.Position
		end
	end)
	dragEnded = UIS.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
			resizing = false
			splitting = false
		end
	end)
	dragConn = UIS.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		if dragging then
			local d = input.Position - dragStart
			win.Position = UDim2.fromOffset(startPos.X.Offset + d.X, startPos.Y.Offset + d.Y)
			if placeInspect then
				placeInspect()
			end
		elseif splitting then
			if S.minimized then
				return
			end
			local d = input.Position - splitStart
			local w = splitW + d.X
			if w < 170 then
				w = 170
			elseif w > 420 then
				w = 420
			end
			S.listW = w
			if layoutPanels then
				layoutPanels()
			end
		elseif resizing and not S.minimized then
			local d = input.Position - resizeStart
			local w = startSize.X + d.X
			local h = startSize.Y + d.Y
			if w < 580 then
				w = 580
			elseif w > 1500 then
				w = 1500
			end
			if h < 300 then
				h = 300
			elseif h > 920 then
				h = 920
			end
			win.Size = UDim2.fromOffset(w, h)
			if layoutPanels then
				layoutPanels()
			end
		end
	end)

	local bar = Instance.new("Frame")
	bar.BackgroundTransparency = 1
	bar.Position = UDim2.fromOffset(12, 52)
	bar.Size = UDim2.new(1, -24, 0, 32)
	bar.Parent = win

	recBtn = mkBtn(bar, "Record", 0, 80, THEME.BTN, toggleRecord)
	startBtn = mkBtn(bar, "Start", 88, 80, THEME.OK, doStart)
	mkBtn(bar, "Copy", 176, 64, THEME.BTN, doCopy)
	mkBtn(bar, "Reset", 248, 64, THEME.BTN, doReset)

	local timesLab = Instance.new("TextLabel")
	timesLab.BackgroundTransparency = 1
	timesLab.Position = UDim2.fromOffset(318, 0)
	timesLab.Size = UDim2.fromOffset(18, 32)
	timesLab.Font = Enum.Font.Gotham
	timesLab.TextSize = 12
	timesLab.TextXAlignment = Enum.TextXAlignment.Right
	timesLab.TextColor3 = THEME.DIM
	timesLab.Text = "x"
	timesLab.Parent = bar

	repeatBox = Instance.new("TextBox")
	repeatBox.Size = UDim2.fromOffset(36, 32)
	repeatBox.Position = UDim2.fromOffset(340, 0)
	repeatBox.BackgroundColor3 = THEME.PANEL
	repeatBox.BorderSizePixel = 0
	repeatBox.Font = Enum.Font.GothamMedium
	repeatBox.TextSize = 13
	repeatBox.TextColor3 = THEME.TEXT
	repeatBox.Text = "1"
	repeatBox.ClearTextOnFocus = false
	repeatBox.Parent = bar
	corner(repeatBox, 8)

	local gapLab = Instance.new("TextLabel")
	gapLab.BackgroundTransparency = 1
	gapLab.Position = UDim2.fromOffset(376, 0)
	gapLab.Size = UDim2.fromOffset(36, 32)
	gapLab.Font = Enum.Font.Gotham
	gapLab.TextSize = 11
	gapLab.TextXAlignment = Enum.TextXAlignment.Right
	gapLab.TextColor3 = THEME.DIM
	gapLab.Text = "x gap"
	gapLab.Parent = bar

	gapBox = Instance.new("TextBox")
	gapBox.Size = UDim2.fromOffset(44, 32)
	gapBox.Position = UDim2.fromOffset(414, 0)
	gapBox.BackgroundColor3 = THEME.PANEL
	gapBox.BorderSizePixel = 0
	gapBox.Font = Enum.Font.GothamMedium
	gapBox.TextSize = 13
	gapBox.TextColor3 = THEME.TEXT
	gapBox.Text = "0.6"
	gapBox.ClearTextOnFocus = false
	gapBox.Parent = bar
	corner(gapBox, 8)

	local bar2 = Instance.new("Frame")
	bar2.BackgroundTransparency = 1
	bar2.Position = UDim2.fromOffset(12, 88)
	bar2.Size = UDim2.new(1, -24, 0, 32)
	bar2.Parent = win

	mkBtn(bar2, "Delete all", 0, 78, THEME.ERR, doDeleteAll)
	mkBtn(bar2, "Keep only", 82, 74, THEME.OK, doKeepOnly)

	local waitLab = Instance.new("TextLabel")
	waitLab.BackgroundTransparency = 1
	waitLab.Position = UDim2.fromOffset(160, 0)
	waitLab.Size = UDim2.fromOffset(28, 32)
	waitLab.Font = Enum.Font.Gotham
	waitLab.TextSize = 11
	waitLab.TextXAlignment = Enum.TextXAlignment.Right
	waitLab.TextColor3 = THEME.DIM
	waitLab.Text = "wait"
	waitLab.Parent = bar2

	waitAllBox = Instance.new("TextBox")
	waitAllBox.Size = UDim2.fromOffset(40, 32)
	waitAllBox.Position = UDim2.fromOffset(192, 0)
	waitAllBox.BackgroundColor3 = THEME.PANEL
	waitAllBox.BorderSizePixel = 0
	waitAllBox.Font = Enum.Font.GothamMedium
	waitAllBox.TextSize = 13
	waitAllBox.TextColor3 = THEME.TEXT
	waitAllBox.Text = "0.10"
	waitAllBox.ClearTextOnFocus = false
	waitAllBox.Parent = bar2
	corner(waitAllBox, 8)

	mkBtn(bar2, "Set waits", 238, 76, THEME.BTN, doSetWaits)
	mkBtn(bar2, "From here", 320, 78, THEME.OK, doFromHere)
	mkBtn(bar2, "Fire 1", 404, 54, THEME.BTN, doFireOne)

	listHold = Instance.new("Frame")
	listHold.BackgroundColor3 = THEME.PANEL
	listHold.BorderSizePixel = 0
	listHold.Parent = win
	corner(listHold, 8)
	stroke(listHold, THEME.STROKE, 1)

	filterBox = Instance.new("TextBox")
	filterBox.Position = UDim2.fromOffset(8, 6)
	filterBox.Size = UDim2.new(1, -16, 0, 24)
	filterBox.BackgroundColor3 = THEME.BG
	filterBox.BorderSizePixel = 0
	filterBox.Font = Enum.Font.Gotham
	filterBox.TextSize = 12
	filterBox.TextColor3 = THEME.TEXT
	filterBox.PlaceholderColor3 = THEME.DIM
	filterBox.PlaceholderText = "filter remotes…"
	filterBox.Text = ""
	filterBox.ClearTextOnFocus = false
	filterBox.Parent = listHold
	corner(filterBox, 6)
	filterBox:GetPropertyChangedSignal("Text"):Connect(function()
		S.listFilter = string.lower(filterBox.Text or "")
		refreshList()
	end)

	listFrame = Instance.new("ScrollingFrame")
	listFrame.Position = UDim2.fromOffset(4, 34)
	listFrame.Size = UDim2.new(1, -8, 1, -38)
	listFrame.BackgroundTransparency = 1
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 4
	listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	listFrame.Parent = listHold
	local lay = Instance.new("UIListLayout")
	lay.Padding = UDim.new(0, 1)
	lay.Parent = listFrame

	splitBar = Instance.new("TextButton")
	splitBar.AutoButtonColor = false
	splitBar.Text = ""
	splitBar.BackgroundColor3 = THEME.STROKE
	splitBar.BackgroundTransparency = 0.35
	splitBar.BorderSizePixel = 0
	splitBar.ZIndex = 4
	splitBar.Parent = win
	corner(splitBar, 3)
	splitBar.MouseEnter:Connect(function()
		tween(splitBar, { BackgroundTransparency = 0 }, 0.1)
	end)
	splitBar.MouseLeave:Connect(function()
		if not splitting then
			tween(splitBar, { BackgroundTransparency = 0.35 }, 0.12)
		end
	end)
	splitBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			splitting = true
			dragging = false
			resizing = false
			splitStart = input.Position
			splitW = S.listW or 280
		end
	end)

	noteHold = Instance.new("Frame")
	noteHold.BackgroundColor3 = THEME.PANEL
	noteHold.BorderSizePixel = 0
	noteHold.Parent = win
	corner(noteHold, 8)
	stroke(noteHold, THEME.STROKE, 1)

	inspArrow = Instance.new("TextButton")
	inspArrow.AutoButtonColor = false
	inspArrow.Text = "›"
	inspArrow.Font = Enum.Font.GothamBold
	inspArrow.TextSize = 16
	inspArrow.TextColor3 = THEME.TEXT
	inspArrow.BackgroundColor3 = THEME.BTN
	inspArrow.BorderSizePixel = 0
	inspArrow.ZIndex = 20
	inspArrow.Parent = gui
	corner(inspArrow, 6)
	btnBase[inspArrow] = THEME.BTN
	inspArrow.MouseEnter:Connect(function()
		tween(inspArrow, { BackgroundColor3 = THEME.HOVER }, 0.1)
	end)
	inspArrow.MouseLeave:Connect(function()
		tween(inspArrow, { BackgroundColor3 = btnBase[inspArrow] or THEME.BTN }, 0.12)
	end)

	inspHold = Instance.new("Frame")
	inspHold.BackgroundColor3 = THEME.PANEL
	inspHold.BorderSizePixel = 0
	inspHold.Visible = false
	inspHold.ClipsDescendants = true
	inspHold.ZIndex = 19
	inspHold.Parent = gui
	corner(inspHold, 8)
	stroke(inspHold, THEME.STROKE, 1)

	inspHead = Instance.new("TextLabel")
	inspHead.BackgroundTransparency = 1
	inspHead.Position = UDim2.fromOffset(8, 4)
	inspHead.Size = UDim2.new(1, -16, 0, 20)
	inspHead.Font = Enum.Font.GothamMedium
	inspHead.TextSize = 12
	inspHead.TextXAlignment = Enum.TextXAlignment.Left
	inspHead.TextColor3 = THEME.DIM
	inspHead.Text = "Inspector"
	inspHead.ZIndex = 20
	inspHead.Parent = inspHold

	local inspScroll = Instance.new("ScrollingFrame")
	inspScroll.Position = UDim2.fromOffset(4, 26)
	inspScroll.Size = UDim2.new(1, -8, 1, -32)
	inspScroll.BackgroundTransparency = 1
	inspScroll.BorderSizePixel = 0
	inspScroll.ScrollBarThickness = 4
	inspScroll.ScrollBarImageColor3 = THEME.DIM
	inspScroll.ScrollingDirection = Enum.ScrollingDirection.XY
	inspScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	inspScroll.AutomaticCanvasSize = Enum.AutomaticSize.XY
	inspScroll.ZIndex = 20
	inspScroll.Parent = inspHold

	inspBody = Instance.new("TextBox")
	inspBody.Size = UDim2.new(0, 0, 0, 0)
	inspBody.AutomaticSize = Enum.AutomaticSize.XY
	inspBody.BackgroundTransparency = 1
	inspBody.BorderSizePixel = 0
	inspBody.ClearTextOnFocus = false
	inspBody.TextEditable = false
	inspBody.MultiLine = true
	inspBody.TextWrapped = false
	inspBody.TextXAlignment = Enum.TextXAlignment.Left
	inspBody.TextYAlignment = Enum.TextYAlignment.Top
	inspBody.Font = Enum.Font.Code
	inspBody.TextSize = 12
	inspBody.TextColor3 = THEME.TEXT
	inspBody.Text = "-- click a recorded event\n-- or a notepad line"
	inspBody.ZIndex = 20
	inspBody.Parent = inspScroll

	placeInspect = function()
		if not win or not inspArrow then
			return
		end
		local ap = win.AbsolutePosition
		local as = win.AbsoluteSize
		local arrowW = 20
		local gap = 4
		local top = 128
		local h = as.Y - 180
		if h < 48 then
			h = 48
		end
		if S.minimized then
			inspArrow.Visible = false
			if inspHold then
				inspHold.Visible = false
			end
			return
		end
		inspArrow.Visible = true
		if S.inspectOpen then
			local iw = S.inspectW or 260
			if inspHold then
				inspHold.Visible = true
				inspHold.Position = UDim2.fromOffset(ap.X + as.X + gap, ap.Y + top)
				inspHold.Size = UDim2.fromOffset(iw, h)
			end
			inspArrow.Position = UDim2.fromOffset(ap.X + as.X + gap + iw + gap, ap.Y + top)
			inspArrow.Size = UDim2.fromOffset(arrowW, h)
			inspArrow.Text = "‹"
		else
			if inspHold then
				inspHold.Visible = false
			end
			inspArrow.Position = UDim2.fromOffset(ap.X + as.X + gap, ap.Y + top)
			inspArrow.Size = UDim2.fromOffset(arrowW, h)
			inspArrow.Text = "›"
		end
	end

	local function setInspectOpen(open)
		S.inspectOpen = open and true or false
		if placeInspect then
			placeInspect()
		end
	end
	inspArrow.MouseButton1Click:Connect(function()
		setInspectOpen(not S.inspectOpen)
	end)

	layoutPanels = function()
		local lw = S.listW or 280
		listHold.Position = UDim2.fromOffset(12, 128)
		listHold.Size = UDim2.new(0, lw, 1, -180)
		splitBar.Position = UDim2.fromOffset(12 + lw + 1, 140)
		splitBar.Size = UDim2.new(0, 6, 1, -204)
		noteHold.Position = UDim2.fromOffset(12 + lw + 10, 128)
		noteHold.Size = UDim2.new(1, -(12 + lw + 10 + 12), 1, -180)
		if placeInspect then
			placeInspect()
		end
	end
	layoutPanels()
	setInspectOpen(false)
	pcall(function()
		win:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
			if placeInspect then
				placeInspect()
			end
		end)
		win:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if placeInspect then
				placeInspect()
			end
		end)
	end)

	noteScroll = Instance.new("ScrollingFrame")
	noteScroll.Position = UDim2.fromOffset(4, 4)
	noteScroll.Size = UDim2.new(1, -8, 1, -26)
	noteScroll.BackgroundTransparency = 1
	noteScroll.BorderSizePixel = 0
	noteScroll.ScrollBarThickness = 6
	noteScroll.ScrollBarImageColor3 = THEME.DIM
	noteScroll.ScrollingDirection = Enum.ScrollingDirection.Y
	noteScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	noteScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	noteScroll.ClipsDescendants = true
	noteScroll.Parent = noteHold

	local function beamOn()
		pcall(function()
			UIS.MouseIcon = "rbxasset://SystemCursors/IBeam"
		end)
		pcall(function()
			if lp then
				lp:GetMouse().Icon = "rbxasset://SystemCursors/IBeam"
			end
		end)
	end
	local function beamOff()
		pcall(function()
			UIS.MouseIcon = ""
		end)
		pcall(function()
			if lp then
				lp:GetMouse().Icon = ""
			end
		end)
	end
	noteHold.MouseEnter:Connect(beamOn)
	noteHold.MouseLeave:Connect(beamOff)

	local noteList = Instance.new("Frame")
	noteList.BackgroundTransparency = 1
	noteList.Size = UDim2.new(1, -6, 0, 0)
	noteList.AutomaticSize = Enum.AutomaticSize.Y
	noteList.Parent = noteScroll
	local noteLay = Instance.new("UIListLayout")
	noteLay.SortOrder = Enum.SortOrder.LayoutOrder
	noteLay.Padding = UDim.new(0, 0)
	noteLay.Parent = noteList

	argLab = Instance.new("TextLabel")
	argLab.Position = UDim2.new(0, 8, 1, -22)
	argLab.Size = UDim2.new(1, -16, 0, 18)
	argLab.BackgroundTransparency = 1
	argLab.Font = Enum.Font.Gotham
	argLab.TextSize = 11
	argLab.TextXAlignment = Enum.TextXAlignment.Left
	argLab.TextColor3 = THEME.DIM
	pcall(function()
		argLab.TextTruncate = Enum.TextTruncate.AtEnd
	end)
	argLab.Text = "  recorded args show here when you click a line"
	argLab.Parent = noteHold

	rebuildNote = function(grab)
		noteBusy = true
		if noteBox and noteBox.Parent and type(editSlot) == "number" then
			commitEdit()
		end
		if #noteData == 0 then
			noteData[1] = ""
		end
		if S.editIndex < 1 then
			S.editIndex = 1
		end
		if S.editIndex > #noteData then
			S.editIndex = #noteData
		end
		for _, ch in ipairs(noteList:GetChildren()) do
			if not ch:IsA("UIListLayout") then
				ch:Destroy()
			end
		end
		noteBox = nil
		noteRowFrames = {}
		local function paintEdit()
			for _, ch in ipairs(noteList:GetChildren()) do
				if ch:IsA("Frame") then
					ch.BackgroundTransparency = ch.LayoutOrder == S.editIndex and 0.45 or 1
				end
			end
		end
		for i = 1, #noteData do
			local idx = i
			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, 0, 0, LINE_H)
			row.BackgroundColor3 = THEME.LINE
			row.BackgroundTransparency = idx == S.editIndex and 0.45 or 1
			row.BorderSizePixel = 0
			row.Active = false
			row.LayoutOrder = idx
			row.Parent = noteList
			noteRowFrames[idx] = row
			local box = Instance.new("TextBox")
			box.Size = UDim2.new(1, -4, 1, 0)
			box.Position = UDim2.fromOffset(2, 0)
			box.BackgroundTransparency = 1
			box.BorderSizePixel = 0
			box.ClearTextOnFocus = false
			box.TextWrapped = false
			box.TextXAlignment = Enum.TextXAlignment.Left
			box.TextYAlignment = Enum.TextYAlignment.Center
			box.Font = Enum.Font.Code
			box.TextSize = 13
			box.TextColor3 = lineColor(noteData[idx])
			box.Text = noteData[idx]
			box.Parent = row
			box.MouseEnter:Connect(beamOn)
			if idx == S.editIndex then
				noteBox = box
				editSlot = idx
			end
			box.Focused:Connect(function()
				S.editIndex = idx
				editSlot = idx
				noteBox = box
				paintEdit()
				previewArgs()
			end)
			box:GetPropertyChangedSignal("Text"):Connect(function()
				if noteBusy then
					return
				end
				noteData[idx] = box.Text
				box.TextColor3 = lineColor(box.Text)
				previewArgs()
			end)
			box.FocusLost:Connect(function(enter)
				if noteBusy then
					return
				end
				noteData[idx] = box.Text
				if enter then
					table.insert(noteData, idx + 1, "")
					S.editIndex = idx + 1
					rebuildNote(true)
				else
					previewArgs()
				end
			end)
			box.InputBegan:Connect(function(input)
				if input.UserInputType ~= Enum.UserInputType.Keyboard then
					return
				end
				if input.KeyCode == Enum.KeyCode.Up then
					noteData[idx] = box.Text
					if S.editIndex > 1 then
						S.editIndex = S.editIndex - 1
						rebuildNote(true)
					end
				elseif input.KeyCode == Enum.KeyCode.Down then
					noteData[idx] = box.Text
					if S.editIndex < #noteData then
						S.editIndex = S.editIndex + 1
						rebuildNote(true)
					end
				end
			end)
		end
		noteBusy = false
		previewArgs()
		if grab and noteBox then
			later(function()
				if noteBox then
					pcall(function()
						noteBox:CaptureFocus()
					end)
				end
			end)
			if noteScroll then
				local y = (S.editIndex - 1) * LINE_H - 40
				if y < 0 then
					y = 0
				end
				noteScroll.CanvasPosition = Vector2.new(0, y)
			end
		end
	end
	rebuildNote(false)

	logLabel = Instance.new("TextLabel")
	logLabel.Position = UDim2.new(0, 12, 1, -40)
	logLabel.Size = UDim2.new(1, -40, 0, 28)
	logLabel.BackgroundColor3 = THEME.PANEL
	logLabel.BorderSizePixel = 0
	logLabel.Font = Enum.Font.Gotham
	logLabel.TextSize = 11
	logLabel.TextXAlignment = Enum.TextXAlignment.Left
	logLabel.TextColor3 = THEME.DIM
	logLabel.TextWrapped = true
	logLabel.Text = "  Drag the title to move. Drag the bar between panels, or the corner, to resize. F10 closes."
	logLabel.Parent = win
	corner(logLabel, 6)
	stroke(logLabel, THEME.STROKE, 1)

	local grip = Instance.new("TextButton")
	grip.AutoButtonColor = false
	grip.Text = ""
	grip.Size = UDim2.fromOffset(18, 18)
	grip.Position = UDim2.new(1, -20, 1, -20)
	grip.BackgroundColor3 = THEME.HOVER
	grip.BorderSizePixel = 0
	grip.ZIndex = 8
	grip.Parent = win
	corner(grip, 5)
	for i = 1, 3 do
		local d = Instance.new("Frame")
		d.BackgroundColor3 = THEME.DIM
		d.BorderSizePixel = 0
		d.Size = UDim2.fromOffset(8, 2)
		d.Position = UDim2.fromOffset(5, 3 + i * 3)
		d.Rotation = -45
		d.ZIndex = 9
		d.Parent = grip
	end
	grip.MouseEnter:Connect(function()
		tween(grip, { BackgroundColor3 = THEME.OK }, 0.1)
	end)
	grip.MouseLeave:Connect(function()
		tween(grip, { BackgroundColor3 = THEME.HOVER }, 0.12)
	end)
	grip.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and not S.minimized then
			resizing = true
			dragging = false
			splitting = false
			resizeStart = input.Position
			startSize = win.AbsoluteSize
		end
	end)

	later(function()
		while win and win.Parent and not S.stopped do
			if S.recording and recBtn and recBtn.Parent then
				tween(recBtn, { BackgroundColor3 = Color3.fromRGB(255, 96, 96) }, 0.35)
				pause(0.35)
				if S.recording and recBtn and recBtn.Parent then
					tween(recBtn, { BackgroundColor3 = THEME.ERR }, 0.35)
				end
			end
			pause(0.08)
		end
	end)
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
	if showInspect then
		showInspect(nil, "-- click a recorded event\n-- or a notepad line")
	end
	noteKeyConn = UIS.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		if input.KeyCode == Enum.KeyCode.Backspace or input.KeyCode == Enum.KeyCode.Delete then
			tryDeleteEmptyLine()
		end
	end)
	f10Conn = UIS.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.F10 then
			destroyGui()
		end
	end)
end

boot()
