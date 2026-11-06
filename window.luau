--!strict
-- omp-gallery, window half: the "Show omp sessions" command and its status
-- line button, the gallery's tab at window start, a refresh whenever the
-- gallery gets focus, and the resume links the gallery block opens.

local common = require("./common")

local HOME = tern.getenv("HOME") or ""
local SESSIONS = HOME .. "/.omp/agent/sessions/"
local START_TRIES = 20 -- at window start, wait up to 10 s for the host half

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

-- Coming back to the gallery picks up sessions that changed meanwhile.
tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	local p = cx.session:pane(ev.pane)
	if p and p.block == common.KIND then
		cx.session:event(ev.pane, { ev = "action", id = "main", act = "wake" })
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

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	local verb, fields = common.parse(link.url)
	if verb == nil then
		return nil
	end
	-- Only the gallery block asks, and every window showing it hears the
	-- request: the window where it has focus acts on it.
	local from = cx.session:pane(link.pane)
	if verb == "resume" and from and from.block == common.KIND and cx.session:focused() == link.pane then
		resume(cx, fields, link.pane)
	end
	return { handled = true }
end)
