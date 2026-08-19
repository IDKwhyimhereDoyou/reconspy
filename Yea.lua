-- PlaceRecon.lua
-- Client recon for THIS place: Scan, Spy, Dump, Copy.
-- Paste and Execute. Not an aimbot. Does not invent FireServer args.
-- Replay only fires a capture Spy actually recorded (two clicks).

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local lp = Players.LocalPlayer

local THEME = {
	BG = Color3.fromRGB(16, 16, 20),
	PANEL = Color3.fromRGB(26, 26, 32),
	BTN = Color3.fromRGB(38, 38, 48),
	ACCENT = Color3.fromRGB(72, 148, 255),
	TEXT = Color3.fromRGB(236, 236, 240),
	DIM = Color3.fromRGB(138, 138, 148),
	WARN = Color3.fromRGB(255, 176, 64),
	ERR = Color3.fromRGB(232, 78, 78),
	OK = Color3.fromRGB(72, 196, 128),
	SEL = Color3.fromRGB(42, 58, 88),
}

local NOISY = {
	"heartbeat", "ping", "fps", "mouse", "camera", "tick", "replicate",
	"render", "inputstate", "lookvector", "footstep", "animation",
	"positionupdate", "cframe", "syncpos", "characterlook", "getping",
	"updatemouse", "physics", "collision", "cameramove",
}

local DUMP_NEEDLES = {
	"gun", "bullet", "shoot", "shot", "fire", "raycast", "projectile",
	"ammo", "reload", "damage", "hit", "remote", "fireserver", "invokeserver",
	"shop", "buy", "click", "coin", "cash", "weapon", "tool",
}

local S = {
	remotes = {},
	values = {},
	captures = {},
	dumps = {},
	tab = "remotes",
	filter = "",
	selected = nil,
	spyOn = false,
	spyHooked = false,
	oldNamecall = nil,
	replaying = false,
	replayArmed = nil,
	capId = 0,
	stopped = false,
}

local gui, win, listFrame, logLabel, infoLabel, spyBtn, replayBtn
local filterBox, tabBtns
local f10Conn, dragConn, dragBegan, dragEnded
local dragging, dragStart, startPos

local function envGet(name)
	local function grab(t)
		if type(t) == "table" then
			return t[name]
		end
		return nil
	end
	if type(getgenv) == "function" then
		local ok, env = pcall(getgenv)
		if ok then
			local v = grab(env)
			if v ~= nil then
				return v
			end
		end
	end
	if type(getfenv) == "function" then
		local ok, env = pcall(getfenv, 0)
		if ok then
			local v = grab(env)
			if v ~= nil then
				return v
			end
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
		local n = select(i, ...)
		local v = envGet(n)
		if type(v) == "function" then
			return v
		end
		if type(n) == "function" then
			return n
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
	local hide = envGet("hidegui") or envGet("protect_gui")
	local syn = envGet("syn")
	if type(syn) == "table" and type(syn.protect_gui) == "function" then
		pcall(syn.protect_gui, obj)
	elseif type(hide) == "function" then
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

local function clipSet(text)
	local fn = pickFn("setclipboard", "toclipboard", "set_clipboard", "Clipboard.set")
	if type(fn) == "function" then
		local ok, err = pcall(fn, text)
		return ok, err
	end
	local clip = envGet("Clipboard")
	if type(clip) == "table" and type(clip.set) == "function" then
		local ok, err = pcall(clip.set, text)
		return ok, err
	end
	return false, "no clipboard"
end

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = inst
	return c
end

local function trunc(s, n)
	s = tostring(s or "")
	n = n or 180
	if #s <= n then
		return s
	end
	return string.sub(s, 1, n - 1) .. "…"
end

local function lower(s)
	return string.lower(tostring(s or ""))
end

local function isNoisy(name)
	local n = lower(name)
	for i = 1, #NOISY do
		if string.find(n, NOISY[i], 1, true) then
			return true
		end
	end
	return false
end

local function luaPath(inst)
	if typeof(inst) ~= "Instance" then
		return "nil"
	end
	if inst == game then
		return "game"
	end
	local parent = inst.Parent
	if not parent then
		return "nil -- destroyed"
	end
	local name = inst.Name
	local key
	if string.match(name, "^[%a_][%w_]*$") then
		key = "." .. name
	else
		key = string.format("[%q]", name)
	end
	if parent == game then
		local ok = pcall(function()
			return game:GetService(name)
		end)
		if ok then
			return string.format("game:GetService(%q)", name)
		end
		return "game" .. key
	end
	return luaPath(parent) .. key
end

local function ser(v, depth)
	depth = depth or 0
	if depth > 3 then
		return "nil -- nested"
	end
	local t = typeof(v)
	if t == "nil" then
		return "nil"
	elseif t == "number" then
		return tostring(v)
	elseif t == "boolean" then
		return v and "true" or "false"
	elseif t == "string" then
		return string.format("%q", v)
	elseif t == "Vector3" then
		return string.format("Vector3.new(%s, %s, %s)", v.X, v.Y, v.Z)
	elseif t == "Vector2" then
		return string.format("Vector2.new(%s, %s)", v.X, v.Y)
	elseif t == "Color3" then
		return string.format("Color3.new(%s, %s, %s)", v.R, v.G, v.B)
	elseif t == "CFrame" then
		local a = { v:GetComponents() }
		return "CFrame.new(" .. table.concat(a, ", ") .. ")"
	elseif t == "EnumItem" then
		return tostring(v)
	elseif t == "Instance" then
		return luaPath(v)
	elseif t == "table" then
		local bits = {}
		local n = 0
		for k, val in pairs(v) do
			n = n + 1
			if n > 12 then
				bits[#bits + 1] = "-- …"
				break
			end
			bits[#bits + 1] = string.format("[%s] = %s", ser(k, depth + 1), ser(val, depth + 1))
		end
		return "{ " .. table.concat(bits, ", ") .. " }"
	end
	return string.format("nil -- %s (live value only in Replay)", t)
end

local function argSummary(packed)
	local n = packed.n or #packed
	local bits = {}
	for i = 1, math.min(n, 6) do
		local v = packed[i]
		local t = typeof(v)
		if t == "string" then
			bits[#bits + 1] = trunc(string.format("%q", v), 28)
		elseif t == "Instance" then
			bits[#bits + 1] = v.ClassName .. ":" .. v.Name
		else
			bits[#bits + 1] = trunc(tostring(v), 24)
		end
	end
	if n > 6 then
		bits[#bits + 1] = "+" .. tostring(n - 6)
	end
	if n == 0 then
		return "(no args)"
	end
	return table.concat(bits, ", ")
end

local function log(msg, color)
	if not logLabel then
		print("[PlaceRecon] " .. tostring(msg))
		return
	end
	logLabel.Text = trunc(tostring(msg), 240)
	logLabel.TextColor3 = color or THEME.DIM
	print("[PlaceRecon] " .. tostring(msg))
end

local function gameTitle()
	local name = "Place"
	pcall(function()
		name = game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId).Name
	end)
	return name
end

local function passFilter(text)
	local f = lower(S.filter)
	if f == "" then
		return true
	end
	return string.find(lower(text), f, 1, true) ~= nil
end

local refreshList

local function setTab(id)
	S.tab = id
	if tabBtns then
		for k, b in pairs(tabBtns) do
			b.BackgroundColor3 = (k == id) and THEME.ACCENT or THEME.BTN
		end
	end
	refreshList()
end

local function selectRow(kind, item)
	S.selected = { kind = kind, item = item }
	S.replayArmed = nil
	if replayBtn then
		replayBtn.Text = "Replay"
		replayBtn.BackgroundColor3 = THEME.BTN
	end
	refreshList()
end

refreshList = function()
	if not listFrame then
		return
	end
	for _, ch in ipairs(listFrame:GetChildren()) do
		if ch:IsA("TextButton") then
			ch:Destroy()
		end
	end
	local items = S.remotes
	local kind = S.tab
	if S.tab == "values" then
		items = S.values
	elseif S.tab == "captures" then
		items = S.captures
	elseif S.tab == "dumps" then
		items = S.dumps
	end
	local startI, endI, step = 1, #items, 1
	if S.tab == "captures" then
		startI, endI, step = #items, 1, -1
	end
	for i = startI, endI, step do
		local item = items[i]
		local label = item.label or ""
		if passFilter(label) then
			local btn = Instance.new("TextButton")
			btn.Size = UDim2.new(1, -4, 0, 22)
			btn.BackgroundColor3 = (S.selected and S.selected.item == item) and THEME.SEL or Color3.fromRGB(32, 32, 40)
			btn.BorderSizePixel = 0
			btn.AutoButtonColor = false
			btn.Font = Enum.Font.Gotham
			btn.TextSize = 12
			btn.TextXAlignment = Enum.TextXAlignment.Left
			btn.TextColor3 = THEME.TEXT
			btn.Text = "  " .. trunc(label, 92)
			btn.Parent = listFrame
			corner(btn, 4)
			btn.MouseButton1Click:Connect(function()
				selectRow(kind, item)
			end)
		end
	end
end

-- scan ------------------------------------------------------------------

local function considerRemote(inst, seen)
	if typeof(inst) ~= "Instance" then
		return
	end
	if not (inst:IsA("RemoteEvent") or inst:IsA("UnreliableRemoteEvent") or inst:IsA("RemoteFunction")) then
		return
	end
	local path = inst:GetFullName()
	if seen[path] then
		return
	end
	seen[path] = true
	S.remotes[#S.remotes + 1] = {
		inst = inst,
		name = inst.Name,
		className = inst.ClassName,
		path = path,
		label = inst.ClassName .. "  " .. inst.Name .. "  " .. path,
	}
end

local function considerValue(inst, seen)
	if typeof(inst) ~= "Instance" then
		return
	end
	if not (inst:IsA("IntValue") or inst:IsA("NumberValue") or inst:IsA("StringValue") or inst:IsA("BoolValue") or inst:IsA("DoubleConstrainedValue") or inst:IsA("IntConstrainedValue")) then
		return
	end
	local path = inst:GetFullName()
	if seen[path] then
		return
	end
	seen[path] = true
	local val = "?"
	pcall(function()
		val = tostring(inst.Value)
	end)
	S.values[#S.values + 1] = {
		inst = inst,
		name = inst.Name,
		path = path,
		label = inst.Name .. " = " .. trunc(val, 40) .. "  " .. path,
	}
end

local function walkRoot(root, seenR, seenV, cap)
	if typeof(root) ~= "Instance" then
		return
	end
	local ok, desc = pcall(function()
		return root:GetDescendants()
	end)
	if not ok or type(desc) ~= "table" then
		return
	end
	considerRemote(root, seenR)
	considerValue(root, seenV)
	for i = 1, math.min(#desc, cap or 8000) do
		considerRemote(desc[i], seenR)
		considerValue(desc[i], seenV)
	end
end

local function doScan()
	S.remotes = {}
	S.values = {}
	local seenR, seenV = {}, {}
	local roots = {
		game:GetService("ReplicatedStorage"),
		game:GetService("ReplicatedFirst"),
		game:GetService("StarterGui"),
		game:GetService("StarterPack"),
		game:GetService("StarterPlayer"),
		workspace,
	}
	pcall(function()
		roots[#roots + 1] = game:GetService("Lighting")
	end)
	if lp then
		roots[#roots + 1] = lp
		pcall(function()
			roots[#roots + 1] = lp:FindFirstChild("PlayerGui")
			roots[#roots + 1] = lp:FindFirstChild("Backpack")
			roots[#roots + 1] = lp:FindFirstChild("PlayerScripts")
			roots[#roots + 1] = lp.Character
		end)
	end
	for i = 1, #roots do
		walkRoot(roots[i], seenR, seenV, 7000)
	end
	table.sort(S.remotes, function(a, b)
		return a.path < b.path
	end)
	table.sort(S.values, function(a, b)
		return a.path < b.path
	end)
	local teams = {}
	pcall(function()
		for _, t in ipairs(game:GetService("Teams"):GetTeams()) do
			teams[#teams + 1] = t.Name
		end
	end)
	local teamTxt = #teams > 0 and table.concat(teams, ", ") or "no Teams (FFA or custom)"
	if infoLabel then
		infoLabel.Text = string.format(
			"%s  ·  PlaceId %s  ·  %d remotes  ·  %d values  ·  %d players  ·  %s",
			trunc(gameTitle(), 28),
			tostring(game.PlaceId),
			#S.remotes,
			#S.values,
			#Players:GetPlayers(),
			teamTxt
		)
	end
	setTab("remotes")
	log(
		string.format(
			"Scan: %d remotes, %d values. Client only — server scripts are hidden. Competitive FPS often validate hits on the server.",
			#S.remotes,
			#S.values
		),
		THEME.OK
	)
end

-- spy -------------------------------------------------------------------

local function pushCapture(remote, method, packed)
	if S.replaying or not S.spyOn then
		return
	end
	if typeof(remote) ~= "Instance" then
		return
	end
	if isNoisy(remote.Name) then
		return
	end
	local n = packed.n or select("#", unpack(packed))
	S.capId = S.capId + 1
	local from = nil
	local gcs = pickFn("getcallingscript")
	if gcs then
		local ok, src = pcall(gcs)
		if ok and typeof(src) == "Instance" then
			from = src.Name
		end
	end
	local cap = {
		id = S.capId,
		remote = remote,
		method = method,
		name = remote.Name,
		path = remote:GetFullName(),
		packed = packed,
		from = from,
		label = method .. "  " .. remote.Name .. "  " .. argSummary(packed) .. (from and ("  ← " .. from) or ""),
	}
	S.captures[#S.captures + 1] = cap
	if #S.captures > 150 then
		table.remove(S.captures, 1)
	end
	if S.tab == "captures" then
		refreshList()
	end
	log("Spy: " .. cap.label, THEME.TEXT)
end

local function packArgs(...)
	local n = select("#", ...)
	local t = { n = n }
	for i = 1, n do
		t[i] = select(i, ...)
	end
	return t
end

local function onOutgoing(self, pretty, ...)
	if not S.spyOn or S.replaying or S.stopped then
		return
	end
	if pretty == "FireServer" then
		if not self:IsA("RemoteEvent") and not self:IsA("UnreliableRemoteEvent") then
			return
		end
	elseif pretty == "InvokeServer" then
		if not self:IsA("RemoteFunction") then
			return
		end
	else
		return
	end
	pushCapture(self, pretty, packArgs(...))
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
	local handler = wrapC(function(self, ...)
		local method = ""
		local okM, m = pcall(getncm)
		if okM then
			method = tostring(m or "")
			local low = string.lower(method)
			if low == "fireserver" then
				pcall(onOutgoing, self, "FireServer", ...)
			elseif low == "invokeserver" then
				pcall(onOutgoing, self, "InvokeServer", ...)
			end
		end
		return box.old(self, ...)
	end)
	local ok, old = pcall(hook, game, "__namecall", handler)
	if ok and type(old) == "function" then
		box.old = old
		S.oldNamecall = old
		return true
	end
	return false
end

local function hookMethods()
	local hf = pickFn("hookfunction", "hookfunc", "replaceclosure", "detour")
	if type(hf) ~= "function" then
		return false
	end
	local hooked = false
	local function hookClass(className, methodName, pretty)
		local okD, dummy = pcall(Instance.new, className)
		if not okD or typeof(dummy) ~= "Instance" then
			return
		end
		local meth = dummy[methodName]
		pcall(dummy.Destroy, dummy)
		if type(meth) ~= "function" then
			return
		end
		local box = { old = nil }
		local ok, old = pcall(function()
			return hf(
				meth,
				wrapC(function(self, ...)
					pcall(onOutgoing, self, pretty, ...)
					return box.old(self, ...)
				end)
			)
		end)
		if ok and type(old) == "function" then
			box.old = old
			hooked = true
		end
	end
	pcall(hookClass, "RemoteEvent", "FireServer", "FireServer")
	pcall(hookClass, "RemoteFunction", "InvokeServer", "InvokeServer")
	pcall(function()
		hookClass("UnreliableRemoteEvent", "FireServer", "FireServer")
	end)
	return hooked
end

local function ensureSpyHook()
	if S.spyHooked then
		return true, nil
	end
	local a = hookNamecall()
	local b = hookMethods()
	if a or b then
		S.spyHooked = true
		return true, (a and "namecall" or "") .. ((a and b) and "+" or "") .. (b and "method" or "")
	end
	return false, "no hookmetamethod / hookfunction / getnamecallmethod"
end

local function toggleSpy()
	if S.spyOn then
		S.spyOn = false
		if spyBtn then
			spyBtn.Text = "Spy"
			spyBtn.BackgroundColor3 = THEME.BTN
		end
		log("Spy off. Hook stays idle (cannot always unhook). Captures kept.", THEME.DIM)
		return
	end
	local ok, how = ensureSpyHook()
	if not ok then
		log("Spy cannot see FireServer: " .. tostring(how) .. ". Scan still works. Dump may still work.", THEME.ERR)
		return
	end
	S.spyOn = true
	if spyBtn then
		spyBtn.Text = "Spy on"
		spyBtn.BackgroundColor3 = THEME.OK
	end
	setTab("captures")
	log("Spy on (" .. tostring(how) .. "). Do the action in-game. Noisy remotes (ping/camera) are hidden. Replay uses these args only.", THEME.OK)
end

-- dump ------------------------------------------------------------------

local function dumpApis()
	return pickFn("getconstants"), pickFn("getsenv"), pickFn("decompile")
end

local function collectScripts()
	local out = {}
	local function add(inst)
		if typeof(inst) ~= "Instance" then
			return
		end
		if inst:IsA("LocalScript") or inst:IsA("ModuleScript") then
			out[#out + 1] = inst
		end
	end
	local roots = {}
	if lp then
		roots[#roots + 1] = lp:FindFirstChild("PlayerGui")
		roots[#roots + 1] = lp:FindFirstChild("PlayerScripts")
		roots[#roots + 1] = lp:FindFirstChild("Backpack")
		roots[#roots + 1] = lp.Character
	end
	roots[#roots + 1] = game:GetService("ReplicatedStorage")
	roots[#roots + 1] = game:GetService("ReplicatedFirst")
	roots[#roots + 1] = game:GetService("StarterPlayer")
	roots[#roots + 1] = game:GetService("StarterGui")
	for i = 1, #roots do
		local r = roots[i]
		if r then
			add(r)
			local ok, desc = pcall(function()
				return r:GetDescendants()
			end)
			if ok then
				for j = 1, math.min(#desc, 2500) do
					add(desc[j])
					if #out >= 80 then
						return out
					end
				end
			end
		end
	end
	return out
end

local function blobOf(scriptInst, getc, gets, dec)
	local chunks = {}
	if type(dec) == "function" then
		local ok, src = pcall(dec, scriptInst)
		if ok and type(src) == "string" and #src > 0 then
			chunks[#chunks + 1] = src
		end
	end
	if type(gets) == "function" then
		local ok, env = pcall(gets, scriptInst)
		if ok and type(env) == "table" then
			for k, v in pairs(env) do
				chunks[#chunks + 1] = tostring(k)
				if type(v) == "string" then
					chunks[#chunks + 1] = v
				elseif type(v) == "function" and type(getc) == "function" then
					local okc, consts = pcall(getc, v)
					if okc and type(consts) == "table" then
						for i = 1, math.min(#consts, 80) do
							chunks[#chunks + 1] = tostring(consts[i])
						end
					end
				end
			end
		end
	end
	return table.concat(chunks, "\n")
end

local function doDump()
	local getc, gets, dec = dumpApis()
	if not getc and not gets and not dec then
		log("Dump cannot read scripts: this executor has no getconstants / getsenv / decompile. Scan still lists remotes and values.", THEME.ERR)
		return
	end
	S.dumps = {}
	local scripts = collectScripts()
	local hits = 0
	local f = lower(S.filter)
	for i = 1, #scripts do
		local sc = scripts[i]
		local blob = blobOf(sc, getc, gets, dec)
		if blob ~= "" then
			local low = lower(blob)
			local matched = false
			if f ~= "" then
				matched = string.find(low, f, 1, true) ~= nil
			else
				for n = 1, #DUMP_NEEDLES do
					if string.find(low, DUMP_NEEDLES[n], 1, true) then
						matched = true
						break
					end
				end
			end
			if matched then
				local snippet = trunc(string.gsub(blob, "[\r\n]+", " | "), 160)
				S.dumps[#S.dumps + 1] = {
					inst = sc,
					path = sc:GetFullName(),
					blob = blob,
					label = sc.ClassName .. "  " .. sc.Name .. "  " .. snippet,
				}
				hits = hits + 1
				if hits >= 80 then
					break
				end
			end
		end
	end
	setTab("dumps")
	log(
		string.format(
			"Dump: %d script hits of %d client scripts. Filter empty = gun/shop/click needles. Server scripts will not appear.",
			#S.dumps,
			#scripts
		),
		THEME.OK
	)
end

-- copy / replay ---------------------------------------------------------

local function snippetFor(sel)
	if not sel then
		return nil, "Select a row first."
	end
	if sel.kind == "remotes" then
		local r = sel.item
		return table.concat({
			"-- Scan listing. No args. Spy the action, then Copy a capture.",
			"local remote = " .. luaPath(r.inst),
			"-- Spy, select the capture, Copy. Do not guess FireServer args.",
		}, "\n")
	end
	if sel.kind == "values" then
		local v = sel.item
		return table.concat({
			"-- Value on this client. Server-owned stats often snap back.",
			"local v = " .. luaPath(v.inst),
			"print(v.Name, v.Value)",
		}, "\n")
	end
	if sel.kind == "captures" then
		local cap = sel.item
		local bits = {}
		local n = cap.packed.n or 0
		for i = 1, n do
			bits[#bits + 1] = ser(cap.packed[i])
		end
		return table.concat({
			"-- PlaceRecon capture. Real args from Spy. Do not add extra args.",
			"local remote = " .. luaPath(cap.remote),
			"remote:" .. cap.method .. "(" .. table.concat(bits, ", ") .. ")",
		}, "\n")
	end
	if sel.kind == "dumps" then
		local d = sel.item
		return table.concat({
			"-- Dump hit: " .. d.path,
			"-- strings from this client script (truncated)",
			"--[[" .. string.gsub(trunc(d.blob, 2500), "%]%]", "] ]") .. "]]",
		}, "\n")
	end
	return nil, "Unknown row."
end

local function doCopy()
	local code, err = snippetFor(S.selected)
	if not code then
		log(err or "Select a row, then Copy.", THEME.WARN)
		return
	end
	local ok = clipSet(code)
	if ok then
		log("Copied Lua to clipboard.", THEME.OK)
	else
		print("-------- PlaceRecon copy --------")
		print(code)
		print("-------- end --------")
		log("No setclipboard/toclipboard. Snippet printed in the console (F9).", THEME.WARN)
	end
end

local function doReplay()
	local sel = S.selected
	if not sel or sel.kind ~= "captures" then
		log("Replay only works on a Spy capture (real args). Scan rows have no args.", THEME.WARN)
		return
	end
	local cap = sel.item
	if S.replayArmed ~= cap.id then
		S.replayArmed = cap.id
		if replayBtn then
			replayBtn.Text = "Again"
			replayBtn.BackgroundColor3 = THEME.ERR
		end
		log("Replay fires the captured remote with those exact args. Common ban if you spam it. Click Replay again to fire.", THEME.WARN)
		return
	end
	S.replayArmed = nil
	if replayBtn then
		replayBtn.Text = "Replay"
		replayBtn.BackgroundColor3 = THEME.BTN
	end
	local remote = cap.remote
	if typeof(remote) ~= "Instance" or not remote.Parent then
		log("Remote is gone: " .. tostring(cap.path), THEME.ERR)
		return
	end
	local args = {}
	local n = cap.packed.n or 0
	for i = 1, n do
		args[i] = cap.packed[i]
	end
	S.replaying = true
	local ok, err
	if cap.method == "FireServer" then
		ok, err = pcall(function()
			remote:FireServer(unpack(args, 1, n))
		end)
	else
		ok, err = pcall(function()
			return remote:InvokeServer(unpack(args, 1, n))
		end)
	end
	S.replaying = false
	if ok then
		log("Replayed " .. cap.method .. " " .. cap.name .. " with captured args.", THEME.OK)
	else
		log("Replay failed: " .. tostring(err), THEME.ERR)
	end
end

-- gui -------------------------------------------------------------------

local function mkBtn(parent, text, x, w, fn)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(w, 26)
	b.Position = UDim2.fromOffset(x, 0)
	b.BackgroundColor3 = THEME.BTN
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 12
	b.TextColor3 = THEME.TEXT
	b.Text = text
	b.AutoButtonColor = false
	b.Parent = parent
	corner(b, 6)
	b.MouseButton1Click:Connect(fn)
	return b
end

local function destroyGui()
	S.stopped = true
	S.spyOn = false
	if f10Conn then
		pcall(function()
			f10Conn:Disconnect()
		end)
		f10Conn = nil
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
	log("PlaceRecon closed. Spy hook stays idle if it was installed.")
	logLabel = nil
	if gui then
		pcall(function()
			gui:Destroy()
		end)
		gui = nil
	end
end

local function createGui()
	if lp then
		pcall(function()
			local pg = lp:FindFirstChild("PlayerGui")
			if pg then
				local old = pg:FindFirstChild("PlaceRecon")
				if old then
					old:Destroy()
				end
			end
		end)
	end
	pcall(function()
		local old = CoreGui:FindFirstChild("PlaceRecon")
		if old then
			old:Destroy()
		end
	end)

	gui = Instance.new("ScreenGui")
	gui.Name = "PlaceRecon"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 120
	parentGui(gui)

	win = Instance.new("Frame")
	win.Name = "Win"
	win.Size = UDim2.fromOffset(560, 468)
	win.Position = UDim2.fromOffset(72, 72)
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
	title.Text = "Place Recon"
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

	infoLabel = Instance.new("TextLabel")
	infoLabel.BackgroundTransparency = 1
	infoLabel.Position = UDim2.fromOffset(12, 42)
	infoLabel.Size = UDim2.new(1, -24, 0, 18)
	infoLabel.Font = Enum.Font.Gotham
	infoLabel.TextSize = 11
	infoLabel.TextXAlignment = Enum.TextXAlignment.Left
	infoLabel.TextColor3 = THEME.DIM
	infoLabel.Text = "Scan this place. Spy records real FireServer args. Copy writes Lua. F10 closes."
	infoLabel.Parent = win

	local bar = Instance.new("Frame")
	bar.BackgroundTransparency = 1
	bar.Position = UDim2.fromOffset(12, 64)
	bar.Size = UDim2.new(1, -24, 0, 26)
	bar.Parent = win

	mkBtn(bar, "Scan", 0, 64, doScan)
	spyBtn = mkBtn(bar, "Spy", 70, 70, toggleSpy)
	mkBtn(bar, "Dump", 146, 64, doDump)
	mkBtn(bar, "Copy", 216, 64, doCopy)
	replayBtn = mkBtn(bar, "Replay", 286, 78, doReplay)

	filterBox = Instance.new("TextBox")
	filterBox.Size = UDim2.new(1, -376, 1, 0)
	filterBox.Position = UDim2.fromOffset(372, 0)
	filterBox.BackgroundColor3 = THEME.PANEL
	filterBox.BorderSizePixel = 0
	filterBox.Font = Enum.Font.Gotham
	filterBox.TextSize = 12
	filterBox.TextColor3 = THEME.TEXT
	filterBox.PlaceholderColor3 = THEME.DIM
	filterBox.PlaceholderText = "Filter"
	filterBox.Text = ""
	filterBox.ClearTextOnFocus = false
	filterBox.Parent = bar
	corner(filterBox, 6)
	filterBox:GetPropertyChangedSignal("Text"):Connect(function()
		S.filter = filterBox.Text
		refreshList()
	end)

	local tabs = Instance.new("Frame")
	tabs.BackgroundTransparency = 1
	tabs.Position = UDim2.fromOffset(12, 98)
	tabs.Size = UDim2.new(1, -24, 0, 24)
	tabs.Parent = win

	tabBtns = {}
	local tabDefs = {
		{ "remotes", "Remotes", 0 },
		{ "values", "Values", 90 },
		{ "captures", "Captures", 180 },
		{ "dumps", "Dump", 270 },
	}
	for i = 1, #tabDefs do
		local id, label, x = tabDefs[i][1], tabDefs[i][2], tabDefs[i][3]
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(84, 24)
		b.Position = UDim2.fromOffset(x, 0)
		b.BackgroundColor3 = THEME.BTN
		b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamMedium
		b.TextSize = 12
		b.TextColor3 = THEME.TEXT
		b.Text = label
		b.Parent = tabs
		corner(b, 6)
		b.MouseButton1Click:Connect(function()
			setTab(id)
		end)
		tabBtns[id] = b
	end

	listFrame = Instance.new("ScrollingFrame")
	listFrame.Position = UDim2.fromOffset(12, 130)
	listFrame.Size = UDim2.new(1, -24, 1, -178)
	listFrame.BackgroundColor3 = THEME.PANEL
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 4
	listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listFrame.Parent = win
	corner(listFrame, 8)
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 2)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = listFrame
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingLeft = UDim.new(0, 4)
	pad.PaddingRight = UDim.new(0, 4)
	pad.Parent = listFrame

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
	logLabel.Text = "  Client only. Spy records real remotes. Copy does not invent args. F10 closes."
	logLabel.Parent = win
	corner(logLabel, 6)
	local logPad = Instance.new("UIPadding")
	logPad.PaddingLeft = UDim.new(0, 8)
	logPad.PaddingRight = UDim.new(0, 8)
	logPad.Parent = logLabel
end

local function boot()
	if type(getgenv) == "function" then
		pcall(function()
			local g = getgenv()
			if g.PlaceReconStop then
				pcall(g.PlaceReconStop)
			end
			g.PlaceReconStop = destroyGui
		end)
	end
	createGui()
	f10Conn = UIS.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.F10 then
			destroyGui()
		end
	end)
	doScan()
end

boot()
