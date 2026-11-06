--!strict
-- omp-gallery, window half: the "Show omp sessions" command and its status
-- line button, the gallery's tab at window start, a refresh whenever the
-- gallery gets focus, how this window's omp panes are doing (working, waiting
-- or idle) whenever that changes, and the links the gallery block opens:
-- resume a session, or start a new one in a folder picked here.

local common = require("./common")

local HOME = tern.getenv("HOME") or ""
local SESSIONS = HOME .. "/.omp/agent/sessions/"
local START_TRIES = 20 -- at window start, wait up to 10 s for the host half
local MAX_FOLDERS = 1000 -- subfolders the folder picker lists
local RECENT = 12 -- project folders the folder picker offers
local INDEX_FILE = tern.plugin.data .. "/index.json" -- written by the host half

-- The gallery's pane in this window, if it has one.
local function gallery(cx: WindowCx): number?
	for _, p in cx.session:panes() do
		if p.block == common.KIND then
			return p.pane
		end
	end
	return nil
end

-- Focuses the gallery, else opens it in a new tab. False when the host half
-- can't make one (not loaded yet).
local function show(cx: WindowCx): boolean
	local pane = gallery(cx)
	if pane then
		cx.layout:focus(pane)
		return true
	end
	return cx:new_block(common.KIND, nil, "tab") ~= nil
end

tern.command({
	id = "open",
	title = "Show omp sessions",
	icon = "history",
	keys = { if tern.runtime.os == "macos" then "cmd+shift+h" else "ctrl+shift+h" },
	run = function(cx: WindowCx)
		if not show(cx) then
			cx:toast("error", "omp sessions are unavailable", "The plugin's host half isn't loaded on this host.")
		end
	end,
})

-- The button: a segment at the end of the status line, everywhere but in the
-- gallery itself.
tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	if pane.block == common.KIND or pane.program == common.KIND then
		return nil
	end
	return { { text = "Sessions", icon = "history", command = common.OPEN } }
end)

-- The status line is off by default, which would hide the button: turn it on
-- the first time the plugin runs on this machine. Later it is the user's call.
local function status_line_once(cx: WindowCx)
	if tern.kv.get("status_line_offered") then
		return
	end
	tern.kv.set("status_line_offered", true)
	local read, on = pcall(function(): any
		return cx.settings:get("status_bar")
	end)
	if read and on == false then
		local set = pcall(function()
			cx.settings:set("status_bar", true)
		end)
		if set then
			cx:toast("info", "Status line turned on", "Its Sessions button opens your omp sessions.")
		end
	end
end

local function start(cx: WindowCx, tries: number)
	if show(cx) or tries >= START_TRIES then
		return
	end
	tern.timer(500, function(later: WindowCx?)
		if later then
			start(later, tries + 1)
		end
	end)
end

tern.on("window_start", function(cx: WindowCx)
	status_line_once(cx)
	start(cx, 1)
end)

-- Tells the gallery block in `pane` something (`act`), with how each omp pane
-- of this window is doing (cx.agents:list() states by pane id, as JSON).
local function tell(cx: WindowCx, pane: number, act: string)
	-- Raises when the block has ended (its plugin failed to load): nobody to tell.
	pcall(function()
		local states: { [string]: string } = {}
		for _, a in cx.agents:list() do
			states[tostring(a.pane)] = a.state
		end
		cx.session:event(pane, { ev = "action", id = "main", act = act, value = tern.json.encode(states) })
	end)
end

-- Coming back to the gallery picks up sessions that changed meanwhile.
tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	local p = cx.session:pane(ev.pane)
	if p and p.block == common.KIND then
		tell(cx, ev.pane, "wake")
	end
end)

-- An omp pane started or ended a turn, or began waiting for an answer.
tern.on("agent_state", function(_ev: AgentStateEvent, cx: WindowCx)
	local pane = gallery(cx)
	if pane then
		tell(cx, pane, "agents")
	end
end)

local function in_sessions(path: string): boolean
	return HOME ~= ""
		and string.sub(path, 1, #SESSIONS) == SESSIONS
		and string.sub(path, -6) == ".jsonl"
		and string.find(path, "/../", 1, true) == nil
		and string.find(path, "%c") == nil
end

-- This window's pane that has the session open: one it was resumed in (its
-- command names the file), else an omp titled like it (see common.shows).
local function showing(cx: WindowCx, fields: { [string]: string }): number?
	local panes: { PaneInfo } = {}
	for _, p in cx.session:panes() do
		if p.block == nil and not p.parked and p.exited == nil then
			table.insert(panes, p)
		end
	end
	local path = fields.path or ""
	for _, agent in cx.agents:list() do
		local command = agent.command
		if agent.state ~= "exited" and type(command) == "string" and string.find(command, path, 1, true) then
			for _, p in panes do
				if p.pane == agent.pane then
					return p.pane
				end
			end
		end
	end
	for _, p in panes do
		if common.shows(p.title, p.cwd, fields.title or "", fields.cwd or "") then
			return p.pane
		end
	end
	return nil
end

local function resume(cx: WindowCx, fields: { [string]: string }, from: number)
	local path = fields.path or ""
	if not in_sessions(path) then
		cx:toast("error", "Not an omp session file", path)
		return
	end
	-- Open already: show it rather than start a second omp on it.
	local open = showing(cx, fields)
	if open then
		cx.layout:focus(open)
		return
	end
	if fields.live == "1" then
		local title = fields.title or ""
		cx:toast("info", "omp is already running this session elsewhere", if title ~= "" then title else fields.id)
		return
	end
	local cwd = fields.cwd or ""
	local launch: Launch = {
		cwd = if cwd ~= "" and tern.fs.exists(cwd) then cwd else HOME,
		command = common.resume_command(path),
	}
	local pane = if fields.how == "split" then cx.layout:split(from, "right", launch) else cx.layout:new_tab(launch)
	if pane == nil then
		cx:toast("error", "Couldn't open the session", path)
	end
end

local function start_omp(cx: WindowCx, dir: string)
	if cx.layout:new_tab({ cwd = dir, command = "omp" }) == nil then
		cx:toast("error", "Couldn't start omp", dir)
	end
end

local function is_dir(path: string): boolean
	-- `file/.` doesn't exist, so this is false for files.
	return path ~= "" and tern.fs.exists(if path == "/" then path else path .. "/.")
end

local function join(dir: string, name: string): string
	return if dir == "/" then "/" .. name else dir .. "/" .. name
end

local function parent(dir: string): string
	local up = string.match(dir, "^(.*)/[^/]+$")
	return if up == nil or up == "" then "/" else up
end

-- A typed path made absolute: `~` is home, relative paths start at `dir`.
local function resolve(dir: string, typed: string): string
	local path = string.match(typed, "^%s*(.-)%s*$") or ""
	if path == "~" or string.sub(path, 1, 2) == "~/" then
		path = HOME .. string.sub(path, 2)
	elseif string.sub(path, 1, 1) ~= "/" then
		path = join(dir, path)
	end
	local parts: { string } = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return "/" .. table.concat(parts, "/")
end

-- `dir`'s visible subfolders, sorted.
local function folders(dir: string): { string }
	local out: { string } = {}
	local ok, names = pcall(tern.fs.list, dir)
	if not ok then
		return out
	end
	for _, name in names :: { string } do
		if string.sub(name, 1, 1) ~= "." and is_dir(join(dir, name)) then
			table.insert(out, name)
			if #out >= MAX_FOLDERS then
				break
			end
		end
	end
	return out
end

-- The folders of the most recently used sessions in the gallery's index.
local function recent_projects(): { string }
	local out: { string } = {}
	local ok, data = pcall(function(): any
		return tern.json.decode(tern.fs.read(INDEX_FILE))
	end)
	if not ok or type(data) ~= "table" or type(data.sessions) ~= "table" then
		return out
	end
	local sessions: { { cwd: string, updated: number } } = {}
	for _, s in data.sessions do
		if type(s) == "table" and type(s.cwd) == "string" and s.cwd ~= "" and type(s.updated) == "number" then
			table.insert(sessions, { cwd = s.cwd, updated = s.updated })
		end
	end
	table.sort(sessions, function(a, b): boolean
		return a.updated > b.updated
	end)
	local seen: { [string]: boolean } = {}
	for _, s in sessions do
		if not seen[s.cwd] then
			seen[s.cwd] = true
			table.insert(out, s.cwd)
			if #out >= RECENT then
				break
			end
		end
	end
	return out
end

local browse: (cx: WindowCx, dir: string, recent: { string }) -> ()

local function type_path(cx: WindowCx, dir: string, recent: { string })
	cx:prompt({
		value = common.tilde(dir) .. "/",
		placeholder = "Folder path (~/…, relative to " .. common.tilde(dir) .. ")",
		icon = "folder-go",
		action = "go",
	}):next(function(typed: string?, _err: string?, later: WindowCx?)
		if typed == nil or later == nil then
			return
		end
		local path = resolve(dir, typed)
		if is_dir(path) then
			browse(later, path, recent)
		else
			later:toast("error", "Not a folder", common.tilde(path))
			browse(later, dir, recent)
		end
	end)
end

-- The new session picker: start omp in `dir`, start it in a recent project,
-- or go to another folder (a subfolder, up, home or a typed path) and pick
-- again there.
browse = function(cx: WindowCx, dir: string, recent: { string })
	local here = common.tilde(dir)
	local items: { PickItem } = {
		{ label = "Start omp here", detail = here, icon = "play", group = here, go = "start", path = dir },
	}
	if dir ~= "/" then
		table.insert(items, { label = "..", detail = common.tilde(parent(dir)), icon = "arrow-up", group = here, go = "open", path = parent(dir) })
	end
	if dir ~= HOME and HOME ~= "" then
		table.insert(items, { label = "Home", detail = "~", icon = "folder", group = here, go = "open", path = HOME })
	end
	table.insert(items, { label = "Type a path…", icon = "folder-go", group = here, go = "type" })
	for _, path in recent do
		if path ~= dir and is_dir(path) then
			table.insert(items, {
				label = common.basename(path),
				detail = common.tilde(path),
				icon = "app-omp",
				group = "Start in a recent project",
				go = "start",
				path = path,
			})
		end
	end
	local heading = "Folders in " .. common.basename(here)
	for _, name in folders(dir) do
		table.insert(items, { label = name, icon = "folder", group = heading, go = "open", path = join(dir, name) })
	end
	cx:pick({
		items = items,
		placeholder = "New omp session in " .. here .. " — type to find a folder",
		icon = "folder-open",
		action = "choose",
	}):next(function(item: PickItem?, _err: string?, later: WindowCx?)
		if item == nil or later == nil then
			return
		end
		if item.go == "start" then
			start_omp(later, item.path)
		elseif item.go == "type" then
			type_path(later, dir, recent)
		else
			browse(later, item.path, recent)
		end
	end)
end

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	local verb, fields = common.parse(link.url)
	if verb == nil then
		return nil
	end
	-- Only the gallery block asks, and every window showing it hears the
	-- request: the window where it has focus acts on it.
	local from = cx.session:pane(link.pane)
	if from and from.block == common.KIND and cx.session:focused() == link.pane then
		if verb == "resume" then
			resume(cx, fields, link.pane)
		elseif verb == "start" and is_dir(fields.cwd or "") then
			start_omp(cx, fields.cwd)
		elseif verb == "new" then
			local cwd = fields.cwd or ""
			browse(cx, if is_dir(cwd) then cwd else HOME, recent_projects())
		end
	end
	return { handled = true }
end)

-- New tab (the tab bar's + and ⌘T) asks what to open: a shell, a new omp
-- session or the gallery. "Toggle the new tab menu" turns that off and on.
local function asks_on_new_tab(): boolean
	return tern.kv.get("new_tab_menu") ~= false
end

tern.override("new_tab", function(cx: WindowCx): boolean?
	if not asks_on_new_tab() then
		return false
	end
	local focused = cx.session:focused()
	local pane = if focused then cx.session:pane(focused) else nil
	local here = if pane then pane.cwd else nil
	local cwd: string = if here and is_dir(here) then here else HOME
	cx:pick({
		items = {
			{ label = "New tab", detail = "a shell", icon = "terminal", go = "tab" },
			{ label = "New omp session…", detail = "in a folder you pick", icon = "app-omp", go = "omp" },
			{ label = "omp sessions", detail = "every past session", icon = "history", go = "gallery" },
		},
		placeholder = "Open in a new tab",
		icon = "plus",
		action = "open",
	}):next(function(item: PickItem?, _err: string?, later: WindowCx?)
		if item == nil or later == nil then
			return
		end
		if item.go == "tab" then
			later:command("new_tab") -- Tern's own: overrides don't run inside a handler
		elseif item.go == "omp" then
			browse(later, cwd, recent_projects())
		elseif not show(later) then
			later:toast("error", "omp sessions are unavailable", "The plugin's host half isn't loaded on this host.")
		end
	end)
	return true
end)

tern.command({
	id = "new_tab_menu",
	title = "Toggle the new tab menu",
	icon = "plus",
	run = function(cx: WindowCx)
		local on = not asks_on_new_tab()
		tern.kv.set("new_tab_menu", on)
		if on then
			cx:toast("info", "New tab asks what to open", "A shell, a new omp session or omp sessions.")
		else
			cx:toast("info", "New tab opens a shell", "Run “Toggle the new tab menu” to ask again.")
		end
	end,
})
