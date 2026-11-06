--!strict
-- omp-gallery, host half: the `gallery` block, every omp session on this
-- machine as a grid of cards.
--
-- Session files (~/.omp/agent/sessions/<project>/<time>_<id>.jsonl) are read
-- a few at a time on timer ticks and cached by size and mtime in
-- <data>/index.json, so a refresh reads only the sessions that changed.
-- A session shows as running while an omp holds it (`omp session lease`) or
-- an omp pane is titled after it. Resuming one is the window's business (a
-- new tab), asked for with an `omp-gallery://` link.
--
-- Keys: type to search, ←↑↓→ move, Enter resumes in a new tab (⌥Enter: in a
-- split), Tab/⇧Tab cycle the project filter, Esc clears, ⌃R refreshes.

local common = require("./common")

local ui = tern.ui

local HOME = tern.getenv("HOME") or ""
local ROOT = HOME .. "/.omp/agent/sessions"
local INDEX_FILE = tern.plugin.data .. "/index.json"
local INDEX_VERSION = 1

local MAX_FILE = 160 * 1024 * 1024 -- larger session files are listed, not read
local HEAD = 320 -- bytes at the start of a line that say what it is
local PROMPT_CHARS = 280
local SLICE_MS = 120 -- parsing per timer tick
local WAKE_MS = 5000 -- a focus refresh this soon after the last scan is skipped

local PAGE = 24 -- cards per page: whole rows at 1 to 4 columns
local CARD_CELLS = 44 -- pane width one column of cards needs, in cells
local MAX_COLUMNS = 4

local ALL = "*" -- the project filter's "every project"
local SEARCH_ID = "main.bar.search"
local PROJECT_ID = "main.bar.project"
local GRID_ID = "main.grid"

-- `omp` by name first, then where it gets installed: a daemon started by
-- launchd has a PATH without Tern's own omp.
local OMP: { string } = {
	"omp",
	HOME .. "/Library/Application Support/Tern/omp/bin/omp",
	HOME .. "/.local/bin/omp",
	HOME .. "/.bun/bin/omp",
	"/opt/homebrew/bin/omp",
	"/usr/local/bin/omp",
}

-- Lists every session file with its size and mtime in one process. Exit 3:
-- no sessions folder yet.
local LIST_SCRIPT = [[
cd "$1" 2>/dev/null || exit 3
set -- */*.jsonl
[ -e "$1" ] || exit 0
if stat --version >/dev/null 2>&1; then
	exec stat -c '%Y %s %n' -- "$@"
fi
exec stat -f '%m %z %N' -- "$@"
]]

type FileStat = {
	rel: string, -- "<project folder>/<file>.jsonl" under ROOT
	size: number, -- -1 when unknown
	mtime: number, -- seconds since the epoch; -1 when unknown
}

type Session = {
	key: string, -- the id, made unique: node key and action value
	rel: string,
	id: string,
	cwd: string,
	title: string,
	prompt: string, -- the first prompt, on one line, clipped
	provider: string,
	model: string,
	prompts: number,
	created: number, -- seconds since the epoch
	updated: number, -- seconds since the epoch of its last entry
	size: number,
	mtime: number,
	big: boolean?, -- too large to read: only its file name is known
	hay: string?, -- folded search text, built by the first search
}

type State = {
	cx: BlockCx,
	query: string,
	project: string, -- a cwd, or ALL
	project_open: boolean,
	selected: string?, -- a session key
	pages: number,
}

type Project = { cwd: string, count: number }

-- The index, shared by every gallery block of this host.
local sessions: { [string]: Session } = {} -- by rel
local list: { Session } = {} -- most recently active first
local live: { [string]: boolean } = {} -- ids a running omp holds
local scanning = false
local again = false -- a forced refresh came in during a scan
local done_count, todo_count = 0, 0
local scanned_at = -math.huge -- tern.now() when the last scan ended
local scanned_clock: number? = nil -- os.time() of the same
local problem: string? = nil

-- Gallery blocks by pane; the state object identifies one run of a pane.
local running: { [number]: State } = {}

local function keyed(node: Node, key: string): Node
	local p: { [string]: any } = node.p or {}
	p.key = key
	node.p = p
	return node
end

-- Text -----------------------------------------------------------------------

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Seconds since the epoch of a UTC date, by the days-from-civil algorithm:
-- `os.time` with a table reads local time.
local function epoch(y: number, m: number, d: number, hh: number, mm: number, ss: number): number
	if m <= 2 then
		y -= 1
	end
	local era = y // 400
	local yoe = y - era * 400
	local doy = (153 * (if m > 2 then m - 3 else m + 9) + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return (era * 146097 + doe - 719468) * 86400 + hh * 3600 + mm * 60 + ss
end

-- `sep` is "%-" for a session file name (`2026-11-06T12-47-23-636Z_…`) and
-- ":" for an ISO 8601 UTC time (`2026-11-06T12:47:23.636Z`).
local function utc(s: string, sep: string): number?
	local y, m, d, hh, mm, ss =
		string.match(s, "^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d)" .. sep .. "(%d%d)" .. sep .. "(%d%d)")
	if ss == nil then
		return nil
	end
	return epoch(
		tonumber(y) :: number,
		tonumber(m) :: number,
		tonumber(d) :: number,
		tonumber(hh) :: number,
		tonumber(mm) :: number,
		tonumber(ss) :: number
	)
end

local function ago(t: number): string
	if t <= 0 then
		return "unknown"
	end
	local s = math.max(0, os.time() - t)
	if s < 60 then
		return "just now"
	elseif s < 3600 then
		return string.format("%dm ago", s // 60)
	elseif s < 86400 then
		return string.format("%dh ago", s // 3600)
	elseif s < 7 * 86400 then
		return string.format("%dd ago", s // 86400)
	end
	local date = os.date("*t", math.floor(t))
	local label = MONTHS[date.month] .. " " .. date.day
	if date.year ~= os.date("*t").year then
		label ..= ", " .. date.year
	end
	return label
end

local function group(n: number): string
	local digits = tostring(math.floor(n))
	local grouped = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	if string.sub(grouped, 1, 1) == "," then
		grouped = string.sub(grouped, 2)
	end
	return grouped
end

local function count(n: number, word: string): string
	return group(n) .. " " .. word .. (if n == 1 then "" else "s")
end

local function size_text(n: number): string
	if n < 1024 then
		return string.format("%d B", n)
	elseif n < 1024 * 1024 then
		return string.format("%d KB", n // 1024)
	end
	return string.format("%.1f MB", n / (1024 * 1024))
end

local function tilde(path: string): string
	if HOME ~= "" and (path == HOME or string.sub(path, 1, #HOME + 1) == HOME .. "/") then
		return "~" .. string.sub(path, #HOME + 1)
	end
	return path
end

local function basename(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

-- At most `chars` characters of `s`, cut on a character boundary.
local function clip(s: string, chars: number): string
	local cut = utf8.offset(s, chars + 1)
	if cut and cut <= #s then
		return string.sub(s, 1, cut - 1) .. "…"
	end
	return s
end

-- Lowercase for matching: ASCII, Latin-1 and Latin Extended-A letters
-- (Turkish included: İ folds to i).
local function fold(s: string): string
	local lower = string.lower(s)
	if not string.find(lower, "[\195-\197]") then
		return lower
	end
	local ok, folded = pcall(function(): string
		local out: { string } = {}
		for _, cp in utf8.codes(lower) do
			if cp >= 0xC0 and cp <= 0xDE and cp ~= 0xD7 then
				cp += 0x20
			elseif cp == 0x130 then
				cp = 0x69
			elseif (cp >= 0x100 and cp <= 0x137) or (cp >= 0x14A and cp <= 0x177) then
				cp += if cp % 2 == 0 then 1 else 0
			elseif (cp >= 0x139 and cp <= 0x148) or (cp >= 0x179 and cp <= 0x17E) then
				cp += if cp % 2 == 1 then 1 else 0
			end
			table.insert(out, utf8.char(cp))
		end
		return table.concat(out)
	end)
	return if ok then folded else lower
end

local function utf16_len(s: string): number
	local ok, n = pcall(function(): number
		local units = 0
		for _, cp in utf8.codes(s) do
			units += if cp > 0xFFFF then 2 else 1
		end
		return units
	end)
	return if ok then n else #s
end

-- Pictographs and Nerd Font glyphs that lead omp's titles ("🦅 SWIFT: …").
local function is_symbol(cp: number): boolean
	return (cp >= 0x2190 and cp <= 0x2BFF)
		or (cp >= 0x1F000 and cp <= 0x1FAFF)
		or (cp >= 0xE000 and cp <= 0xF8FF)
		or cp >= 0xF0000
end

-- A title's leading glyph, its `CODE:` tag and the rest.
local function split_title(title: string): (string?, string?, string)
	local rest = title
	local glyph: string? = nil
	local first, after = string.match(rest, "^(%S+)%s+(.+)$")
	if first and after then
		local ok, cp = pcall(utf8.codepoint, first, 1, 1)
		if ok and type(cp) == "number" and is_symbol(cp) then
			glyph, rest = first, after
		end
	end
	local code, text = string.match(rest, "^([%u%d][%u%d_%-]+):%s+(.+)$")
	if code and text and #code <= 12 then
		return glyph, code, text
	end
	return glyph, nil, rest
end

-- Reading sessions -----------------------------------------------------------

local function decode(text: string): { [string]: any }?
	local ok, value = pcall(tern.json.decode, text)
	if ok and type(value) == "table" then
		return value
	end
	return nil
end

-- The text of a user message line, on one line and clipped.
local function prompt_of(line: string): string
	local entry = decode(line)
	local message = if entry then entry.message else nil
	if type(message) ~= "table" then
		return ""
	end
	local parts: { string } = {}
	local content = message.content
	if type(content) == "string" then
		table.insert(parts, content)
	elseif type(content) == "table" then
		for _, part in content do
			if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
				table.insert(parts, part.text)
			end
		end
	end
	local text = string.gsub(table.concat(parts, " "), "%s+", " ")
	return clip(string.match(text, "^ ?(.-) ?$") or text, PROMPT_CHARS)
end

local function blank(f: FileStat, size: number): Session
	local name = string.match(f.rel, "([^/]+)$") or f.rel
	local created = utc(name, "%-") or 0
	return {
		key = "",
		rel = f.rel,
		id = string.match(name, "_([%x%-]+)%.jsonl$") or "",
		cwd = "",
		title = "",
		prompt = "",
		provider = "",
		model = "",
		prompts = 0,
		created = created,
		updated = if f.mtime > 0 then f.mtime else created,
		size = size,
		mtime = f.mtime,
	}
end

-- One pass over the lines, looking only at each line's start except for the
-- few lines it decodes: the header, the title, the first prompt and the last
-- assistant message (for its model).
local function parse(data: string, f: FileStat): Session
	local s = blank(f, if f.size >= 0 then f.size else #data)
	local title, renamed, header_title = "", "", ""
	local first_user: string? = nil
	local assistant_at, assistant_end = 0, 0
	local switched: string? = nil
	local last_time: string? = nil
	local n = #data
	local pos = 1
	local line = 0
	while pos <= n do
		local nl = string.find(data, "\n", pos, true)
		local stop = if nl then nl - 1 else n
		line += 1
		local head = string.sub(data, pos, math.min(stop, pos + HEAD - 1))
		local at = string.match(head, '"timestamp":"([^"]+)"')
		if at then
			last_time = at
		end
		if string.find(head, '"message":{"role":"user"', 1, true) then
			s.prompts += 1
			if first_user == nil then
				first_user = string.sub(data, pos, stop)
			end
		elseif string.find(head, '"message":{"role":"assistant"', 1, true) then
			assistant_at, assistant_end = pos, stop
		elseif string.find(head, '{"type":"model_change"', 1, true) then
			switched = string.match(head, '"model":"([^"]+)"') or switched
		elseif string.find(head, '{"type":"title_change"', 1, true) then
			local entry = decode(string.sub(data, pos, stop))
			if entry and type(entry.title) == "string" then
				renamed = entry.title
			end
		elseif line <= 3 and string.find(head, '{"type":"title",', 1, true) then
			local entry = decode(string.sub(data, pos, stop))
			if entry and type(entry.title) == "string" then
				title = entry.title
			end
		elseif line <= 3 and string.find(head, '{"type":"session",', 1, true) then
			local entry = decode(string.sub(data, pos, stop))
			if entry then
				if type(entry.id) == "string" and entry.id ~= "" then
					s.id = entry.id
				end
				if type(entry.cwd) == "string" then
					s.cwd = entry.cwd
				end
				if type(entry.title) == "string" then
					header_title = entry.title
				end
				if type(entry.timestamp) == "string" then
					s.created = utc(entry.timestamp, ":") or s.created
				end
			end
		end
		pos = stop + 2
	end
	s.title = if title ~= "" then title elseif renamed ~= "" then renamed else header_title
	if first_user then
		s.prompt = prompt_of(first_user)
	end
	local provider, model
	if assistant_at > 0 then
		provider, model = string.match(
			string.sub(data, assistant_at, assistant_end),
			'"provider":"([^"]*)","model":"([^"]*)"'
		)
	end
	if provider and provider ~= "" then
		s.provider, s.model = provider, model or ""
	elseif switched then
		local p, m = string.match(switched, "^([^/]+)/(.+)$")
		if p and m then
			s.provider, s.model = p, m
		else
			s.model = switched
		end
	end
	local updated = if last_time then utc(last_time, ":") else nil
	if updated then
		s.updated = updated
	end
	return s
end

local function read_session(f: FileStat): Session?
	local ok, data = pcall(tern.fs.read, ROOT .. "/" .. f.rel, MAX_FILE)
	if ok then
		return parse(data, f)
	end
	if f.size > MAX_FILE then
		local s = blank(f, f.size)
		s.big = true
		return s
	end
	return nil -- gone since the listing, or unreadable
end

-- Every session file under ROOT. `stat` gives sizes and mtimes for the cache;
-- without a shell (Windows) the folders are listed and every file is read.
local function list_files(done: ({ FileStat }) -> ())
	local function by_listing()
		local files: { FileStat } = {}
		if not tern.fs.exists(ROOT) then
			done(files)
			return
		end
		local ok, dirs = pcall(tern.fs.list, ROOT)
		if not ok then
			problem = tostring(dirs)
			done(files)
			return
		end
		for _, dir in dirs do
			if string.sub(dir, 1, 1) ~= "." then
				local listed, names = pcall(tern.fs.list, ROOT .. "/" .. dir)
				if listed then
					for _, name in names do
						if string.sub(name, 1, 1) ~= "." and string.sub(name, -6) == ".jsonl" then
							table.insert(files, { rel = dir .. "/" .. name, size = -1, mtime = -1 })
						end
					end
				end
			end
		end
		done(files)
	end
	local started = pcall(function()
		tern.process.run(
			{ "/bin/sh", "-c", LIST_SCRIPT, "sh", ROOT },
			{ timeout_ms = 20000 },
			function(r: ProcessResult)
				if r.status == 3 then
					done({})
				elseif r.status ~= 0 then
					by_listing()
				else
					local files: { FileStat } = {}
					for row in string.gmatch(r.stdout, "[^\n]+") do
						local mtime, size, rel = string.match(row, "^(%d+) (%d+) (.+)$")
						if rel then
							table.insert(files, { rel = rel, size = tonumber(size) :: number, mtime = tonumber(mtime) :: number })
						end
					end
					done(files)
				end
			end
		)
	end)
	if not started then
		by_listing()
	end
end

-- The index -------------------------------------------------------------------

local function rebuild()
	local all: { Session } = {}
	for _, s in sessions do
		table.insert(all, s)
	end
	table.sort(all, function(a: Session, b: Session): boolean
		if a.updated ~= b.updated then
			return a.updated > b.updated
		end
		return a.rel < b.rel
	end)
	local taken: { [string]: boolean } = {}
	for _, s in all do
		local base = string.gsub(if s.id ~= "" then s.id else s.rel, "[^%w%-_]", "_")
		local key, n = base, 1
		while taken[key] do
			n += 1
			key = base .. "_" .. n
		end
		taken[key] = true
		s.key = key
	end
	list = all
end

local STRINGS = { "rel", "id", "cwd", "title", "prompt", "provider", "model" }
local NUMBERS = { "prompts", "created", "updated", "size", "mtime" }

local function load_index()
	if not tern.fs.exists(INDEX_FILE) then
		return
	end
	local ok, text = pcall(tern.fs.read, INDEX_FILE, 64 * 1024 * 1024)
	local data = if ok then decode(text) else nil
	if data == nil or data.v ~= INDEX_VERSION or type(data.sessions) ~= "table" then
		return
	end
	for _, raw in data.sessions do
		if type(raw) == "table" then
			local s: { [string]: any } = { key = "", big = if raw.big == true then true else nil }
			local valid = true
			for _, field in STRINGS do
				valid = valid and type(raw[field]) == "string"
				s[field] = raw[field]
			end
			for _, field in NUMBERS do
				valid = valid and type(raw[field]) == "number"
				s[field] = raw[field]
			end
			if valid then
				sessions[s.rel] = s :: any
			end
		end
	end
	rebuild()
end

local function save_index()
	local out = tern.json.array()
	for _, s in list do
		table.insert(out, {
			rel = s.rel,
			id = s.id,
			cwd = s.cwd,
			title = s.title,
			prompt = s.prompt,
			provider = s.provider,
			model = s.model,
			prompts = s.prompts,
			created = s.created,
			updated = s.updated,
			size = s.size,
			mtime = s.mtime,
			big = s.big,
		})
	end
	local ok, err = pcall(function()
		if not tern.fs.exists(tern.plugin.data) then
			tern.fs.mkdir(tern.plugin.data)
		end
		tern.fs.write(INDEX_FILE, tern.json.encode({ v = INDEX_VERSION, sessions = out }))
	end)
	if not ok then
		tern.log.warn("omp-gallery: index not saved", err)
	end
end

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
end

-- Blocks have no close hook: a pane that left the host's list is retired.
local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	retire(state)
	return false
end

local function render_all()
	for _, state in running do
		if alive(state) then
			state.cx:render()
		end
	end
end

-- Asks omp which of the sessions a running omp holds.
local function check_live()
	local args: { string } = { "session", "lease", "--json", "--" }
	for _, s in list do
		if s.id ~= "" then
			table.insert(args, s.id)
		end
	end
	if #args == 4 then
		live = {}
		return
	end
	for _, exe in OMP do
		if exe == "omp" or tern.fs.exists(exe) then
			local argv: { string } = { exe }
			table.move(args, 1, #args, 2, argv)
			local started = pcall(function()
				tern.process.run(argv, { timeout_ms = 15000 }, function(r: ProcessResult)
					local data = if r.status == 0 then decode(r.stdout) else nil
					if data == nil or type(data.held) ~= "table" then
						return
					end
					local held: { [string]: boolean } = {}
					local changed = false
					for _, id in data.held do
						if type(id) == "string" then
							held[id] = true
							changed = changed or not live[id]
						end
					end
					for id in live do
						changed = changed or not held[id]
					end
					live = held
					if changed then
						render_all()
					end
				end)
			end)
			if started then
				return
			end
		end
	end
end

local scan: () -> ()

scan = function()
	scanning, again, problem = true, false, nil
	done_count, todo_count = 0, 0
	render_all()
	list_files(function(files: { FileStat })
		local present: { [string]: boolean } = {}
		local todo: { FileStat } = {}
		for _, f in files do
			present[f.rel] = true
			local old = sessions[f.rel]
			if old == nil or old.size ~= f.size or old.mtime ~= f.mtime or f.mtime < 0 then
				table.insert(todo, f)
			end
		end
		local changed = #todo > 0
		local gone: { string } = {}
		for rel in sessions do
			if not present[rel] then
				table.insert(gone, rel)
			end
		end
		for _, rel in gone do
			sessions[rel] = nil
			changed = true
		end
		-- Newest first, so the sessions people look for show up first.
		table.sort(todo, function(a: FileStat, b: FileStat): boolean
			return a.mtime > b.mtime
		end)
		todo_count = #todo
		local i = 1
		local drawn = tern.now()
		local function step()
			local start = tern.now()
			while i <= #todo and tern.now() - start < SLICE_MS do
				local f = todo[i]
				i += 1
				local ok, s = pcall(read_session, f)
				if not ok then
					tern.log.warn("omp-gallery: could not read", f.rel, s)
				elseif s then
					sessions[f.rel] = s
				else
					sessions[f.rel] = nil
				end
				done_count += 1
			end
			if i <= #todo then
				if tern.now() - drawn > 500 then
					rebuild()
					render_all()
					drawn = tern.now()
				end
				tern.timer(0, step)
				return
			end
			rebuild()
			if changed then
				save_index()
			end
			scanning = false
			scanned_at = tern.now()
			scanned_clock = os.time()
			render_all()
			check_live()
			if again then
				scan()
			end
		end
		step()
	end)
end

-- `force`: the user asked. Otherwise (the gallery got focus) skip a refresh
-- right after the last one.
local function refresh(force: boolean)
	if scanning then
		again = again or force
	elseif force or tern.now() - scanned_at >= WAKE_MS then
		scan()
	end
end

-- Filtering and selection ----------------------------------------------------

local function hay(s: Session): string
	local cached = s.hay
	if cached then
		return cached
	end
	local text = fold(table.concat({ s.title, s.prompt, s.cwd, s.provider, s.model, s.id }, "\n"))
	s.hay = text
	return text
end

-- The sessions the query and the project filter let through, newest first.
local function filtered(state: State): { Session }
	local terms: { string } = {}
	for term in string.gmatch(fold(state.query), "%S+") do
		table.insert(terms, term)
	end
	local out: { Session } = {}
	for _, s in list do
		if state.project == ALL or s.cwd == state.project then
			local text = hay(s)
			local hit = true
			for _, term in terms do
				if not string.find(text, term, 1, true) then
					hit = false
					break
				end
			end
			if hit then
				table.insert(out, s)
			end
		end
	end
	return out
end

-- Every project folder, most recently used first.
local function projects(): { Project }
	local by: { [string]: Project } = {}
	local out: { Project } = {}
	for _, s in list do
		if s.cwd ~= "" then
			local p = by[s.cwd]
			if p == nil then
				p = { cwd = s.cwd, count = 0 }
				by[s.cwd] = p
				table.insert(out, p)
			end
			p.count += 1
		end
	end
	return out
end

local function columns(cx: BlockCx): number
	return math.clamp(cx.cols // CARD_CELLS, 1, MAX_COLUMNS)
end

-- The selected card's place in `shown`: the selected session, else the first.
local function current(state: State, shown: { Session }): number
	if state.selected then
		for i, s in shown do
			if s.key == state.selected then
				return i
			end
		end
	end
	return 1
end

local function card_id(shown: { Session }, i: number, cols: number): string
	return GRID_ID .. ".r" .. ((i - 1) // cols + 1) .. "." .. shown[i].key
end

local function find(key: string?): Session?
	for _, s in list do
		if s.key == key then
			return s
		end
	end
	return nil
end

local function move(state: State, cx: BlockCx, delta: number): boolean
	local shown = filtered(state)
	if #shown == 0 then
		return false
	end
	local i = math.clamp(current(state, shown) + delta, 1, #shown)
	state.selected = shown[i].key
	if i > state.pages * PAGE then
		state.pages = (i - 1) // PAGE + 1
	end
	-- Draw first, so the card the reveal names exists.
	cx:render()
	cx:frame({ { "reveal", card_id(shown, i, columns(cx)), "nearest" } })
	return true
end

local function set_query(state: State, query: string)
	state.query = query
	state.pages = 1
end

local function cycle_project(state: State, step: number)
	local values = { ALL }
	for _, p in projects() do
		table.insert(values, p.cwd)
	end
	local at = table.find(values, state.project) or 1
	state.project = values[(at - 1 + step) % #values + 1]
	state.pages = 1
end

-- Sessions an omp pane on this host shows (see common.shows), by key.
local function on_screen(): { [string]: boolean }
	local open: { [string]: boolean } = {}
	local panes = tern.pane.list()
	for _, s in list do
		for _, p in panes do
			if common.shows(p.title, p.cwd, s.title, s.cwd) then
				open[s.key] = true
				break
			end
		end
	end
	return open
end

-- Asks the window half to resume `s` (`how`: "tab" or "split"), or to show the
-- pane that has it open.
local function resume(cx: BlockCx, s: Session, how: string)
	cx:open(common.link("resume", {
		how = how,
		id = s.id,
		path = ROOT .. "/" .. s.rel,
		cwd = s.cwd,
		title = s.title,
		live = if live[s.id] then "1" else "0",
	}))
end

local function has_mod(ev: UiEvent, mod: string): boolean
	return type(ev.mods) == "table" and table.find(ev.mods, mod) ~= nil
end

-- The view ----------------------------------------------------------------------

local function head_row(): Node
	local meta = ""
	if scanning and todo_count > 0 then
		meta = string.format("indexing %d of %d", done_count, todo_count)
	elseif scanned_clock then
		meta = "updated " .. os.date("%H:%M", scanned_clock)
	end
	return ui.node("row", { key = "head", gap = "sm", align = "center" }, {
		ui.node("icon", { key = "mark", name = "app-omp" }),
		ui.node("text", {
			key = "title",
			grow = 1,
			wrap = "none",
			truncate = "end",
			spans = { ui.span("omp sessions", "title"), ui.span("   " .. meta, "muted") },
		}),
		ui.button("Refresh", {
			key = "refresh",
			icon = "repeat",
			keys = { "ctrl+r" },
			busy = scanning,
			actions = { click = "refresh" },
		}),
	})
end

local function stats_strip(shown: { Session }): Node
	local seen: { [string]: boolean } = {}
	local folders, prompts = 0, 0
	for _, s in shown do
		if not seen[s.cwd] then
			seen[s.cwd] = true
			folders += 1
		end
		prompts += s.prompts
	end
	local last = shown[1]
	return keyed(
		ui.stats({
			{ label = "Sessions", value = group(#shown), sub = if #shown < #list then "of " .. group(#list) else nil },
			{ label = "Projects", value = group(folders) },
			{ label = "Prompts", value = group(prompts) },
			{
				label = "Last active",
				value = if last then ago(last.updated) else "–",
				sub = if last and last.cwd ~= "" then basename(last.cwd) else nil,
			},
		}),
		"stats"
	)
end

local function project_options(): { any }
	local all = projects()
	local names: { [string]: number } = {}
	for _, p in all do
		local name = basename(p.cwd)
		names[name] = (names[name] or 0) + 1
	end
	local options: { any } = { { value = ALL, label = "All projects", detail = group(#list) } }
	for _, p in all do
		local label = basename(p.cwd)
		if (names[label] or 0) > 1 then
			label = string.match(p.cwd, "([^/]+/[^/]+)/*$") or label
		end
		table.insert(options, { value = p.cwd, label = label, detail = group(p.count), icon = "folder" })
	end
	return options
end

local function toolbar(state: State): Node
	return ui.node("row", { key = "bar", gap = "sm", align = "center" }, {
		ui.node("input", {
			key = "search",
			grow = 1,
			text = state.query,
			cursor = utf16_len(state.query),
			placeholder = "Search titles, prompts, folders, models",
			icon = "search",
			clear = true,
		}),
		ui.node("select", {
			key = "project",
			variant = "quiet",
			label = "Project",
			value = state.project,
			open = state.project_open,
			options = project_options(),
		}),
	})
end

local function card_menu(s: Session, held: boolean): { any }
	return {
		{
			id = "open=" .. s.key,
			label = if held then "Show running session" else "Resume in new tab",
			icon = "play",
			keys = { "enter" },
		},
		{
			id = "split=" .. s.key,
			label = "Resume in split",
			icon = "split",
			keys = { "alt", "enter" },
			disabled = if held then "omp is already running it" else false,
		},
		"-",
		{
			id = "folder=" .. s.key,
			label = "Open project folder",
			icon = "folder",
			disabled = if s.cwd == "" then "Unknown folder" else false,
		},
		{ id = "copyid=" .. s.key, label = "Copy session ID", icon = "copy" },
		{ id = "copycmd=" .. s.key, label = "Copy resume command", icon = "terminal" },
	}
end

local function footer(s: Session): Node
	local kids: { Node } = {}
	if s.provider ~= "" then
		table.insert(kids, ui.node("avatar", {
			key = "mark",
			icon = "provider:" .. s.provider,
			text = s.provider,
			size = "xs",
			title = s.provider,
		}))
	end
	table.insert(kids, ui.node("text", {
		key = "model",
		grow = 1,
		wrap = "none",
		truncate = "end",
		spans = { ui.span(if s.model ~= "" then s.model else "no model yet", "mono muted") },
	}))
	table.insert(kids, ui.node("text", {
		key = "size",
		wrap = "none",
		spans = { ui.span(count(s.prompts, "prompt"), "muted"), ui.span(" · " .. size_text(s.size), "dim") },
	}))
	return ui.node("row", { key = "foot", gap = "sm", align = "center" }, kids)
end

local function session_card(s: Session, id: string, selected: boolean, held: boolean): Node
	local glyph, code, text = split_title(s.title)
	local head: { Span | string } = {}
	if glyph then
		table.insert(head, ui.span(glyph .. " "))
	end
	if text ~= "" then
		table.insert(head, ui.span(text, "strong"))
	else
		-- No title yet: the prompt under the head says what it is.
		table.insert(head, ui.span(if s.big then "Large session" else "Untitled session", "muted"))
	end
	local props: { [string]: any } = {
		key = s.key,
		head = head,
		meta = ago(s.updated),
		selected = selected,
		status = if held then "running" else nil,
		grow = 1,
		basis = 0,
		actions = { click = "pick=" .. s.key, dblclick = "open=" .. s.key, menu = card_menu(s, held) },
	}
	local kids: { Node } = {}
	if code then
		table.insert(kids, ui.node("badge", { key = "code", text = code }))
		props["end"] = id .. ".code"
	end
	table.insert(kids, ui.node("text", {
		key = "where",
		wrap = "none",
		truncate = "middle",
		spans = { ui.span(if s.cwd ~= "" then tilde(s.cwd) else "unknown folder", "path") },
	}))
	table.insert(kids, ui.node("text", {
		key = "prompt",
		lines = 3,
		min = { h = "3lines" },
		spans = {
			if s.prompt ~= "" then ui.span(s.prompt)
			elseif s.big then ui.span("Too large to index: " .. size_text(s.size), "dim")
			else ui.span("No prompts", "dim"),
		},
	}))
	table.insert(kids, footer(s))
	return ui.node("card", props, kids)
end

-- Explicit rows of equal cards, the last row padded, so every column lines up.
local function grid(state: State, shown: { Session }, cols: number, open: { [string]: boolean }): Node
	local limit = math.min(#shown, state.pages * PAGE)
	local sel = current(state, shown)
	local rows: { Node } = {}
	local r = 0
	for first = 1, limit, cols do
		r += 1
		local row_id = GRID_ID .. ".r" .. r
		local cells: { Node } = {}
		for i = first, math.min(first + cols - 1, limit) do
			local s = shown[i]
			table.insert(cells, session_card(s, row_id .. "." .. s.key, i == sel, live[s.id] == true or open[s.key] == true))
		end
		for pad = #cells + 1, cols do
			table.insert(cells, ui.node("row", { key = "pad" .. pad, grow = 1, basis = 0 }))
		end
		table.insert(rows, ui.node("row", { key = "r" .. r, gap = "md", align = "stretch" }, cells))
	end
	return ui.node("col", { key = "grid", gap = "md" }, rows)
end

local function loading(cols: number): Node
	local rows: { Node } = {}
	for r = 1, 2 do
		local cells: { Node } = {}
		for c = 1, cols do
			table.insert(cells, ui.node("card", { key = "c" .. c, grow = 1, basis = 0 }, {
				ui.node("skeleton", { key = "lines", lines = 5 }),
			}))
		end
		table.insert(rows, ui.node("row", { key = "r" .. r, gap = "md", align = "stretch" }, cells))
	end
	return ui.node("col", { key = "grid", gap = "md" }, rows)
end

local function nothing(state: State): Node
	if #list > 0 then
		local text = if state.query ~= "" then "Nothing matches “" .. state.query .. "”" else "No sessions here"
		return ui.node("empty", { key = "grid", variant = "inline", frame = true, icon = "search", text = text }, {
			ui.button("Clear", { key = "reset", variant = "quiet", size = "sm", keys = { "esc" }, actions = { click = "reset" } }),
		})
	elseif problem then
		return ui.node("empty", {
			key = "grid",
			tone = "error",
			grow = 1,
			title = "Couldn't read omp's sessions",
			text = problem,
		}, {
			ui.button("Retry", { key = "retry", icon = "repeat", actions = { click = "refresh" } }),
		})
	end
	return ui.node("empty", {
		key = "grid",
		grow = 1,
		icon = "history",
		title = "No omp sessions yet",
		text = "Sessions show up here once omp saves one in " .. tilde(ROOT) .. ".",
	}, {
		ui.button("Refresh", { key = "retry", icon = "repeat", actions = { click = "refresh" } }),
	})
end

local function legend(): Node
	local items = {
		{ "←↑↓→", "move" },
		{ "enter", "resume" },
		{ "alt+enter", "split" },
		{ "tab", "project" },
		{ "esc", "clear" },
		{ "ctrl+r", "refresh" },
	}
	local spans: { Span | string } = {}
	for i, item in items do
		if i > 1 then
			table.insert(spans, ui.span("    "))
		end
		table.insert(spans, ui.span(item[1], "key"))
		table.insert(spans, ui.span(" " .. item[2], "muted"))
	end
	return ui.node("text", { key = "keys", wrap = "none", truncate = "end", spans = spans })
end

local function view(state: State, cx: BlockCx): BlockView
	-- A project that went away (its sessions were deleted) stops filtering.
	if state.project ~= ALL and #list > 0 then
		local known = false
		for _, s in list do
			if s.cwd == state.project then
				known = true
				break
			end
		end
		if not known then
			state.project = ALL
		end
	end
	local shown = filtered(state)
	local cols = columns(cx)
	local main: { Node } = { head_row() }
	if #list > 0 then
		table.insert(main, stats_strip(shown))
	end
	table.insert(main, toolbar(state))
	if #shown > 0 then
		table.insert(main, grid(state, shown, cols, on_screen()))
		if #shown > state.pages * PAGE then
			table.insert(main, ui.node("pager", {
				key = "more",
				variant = "more",
				page = state.pages,
				size = PAGE,
				total = #shown,
				label = "sessions",
			}))
		end
	elseif #list == 0 and problem == nil and (scanning or scanned_clock == nil) then
		table.insert(main, loading(cols))
	else
		table.insert(main, nothing(state))
	end
	return { main = ui.node("col", { gap = "md" }, main), dock = ui.col({ legend() }) }
end

-- Keys ------------------------------------------------------------------------

local function drop_char(s: string): string
	local cut = utf8.offset(s, -1)
	if cut then
		return string.sub(s, 1, cut - 1)
	end
	return string.sub(s, 1, -2)
end

local function drop_word(s: string): string
	return (string.gsub(s, "%S*%s*$", "", 1))
end

local function open_selected(state: State, cx: BlockCx, how: string): boolean
	local shown = filtered(state)
	local s = shown[current(state, shown)]
	if s == nil then
		return false
	end
	state.selected = s.key
	resume(cx, s, how)
	return true
end

local function key(state: State, k: Key, cx: BlockCx): boolean?
	local name = k.name
	if k.meta then
		if name == "backspace" and state.query ~= "" then
			set_query(state, "")
			return true
		end
		return false
	end
	if k.ctrl then
		if name == "r" then
			refresh(true)
		elseif name == "u" then
			set_query(state, "")
		elseif name == "w" then
			set_query(state, drop_word(state.query))
		elseif name == "n" then
			return move(state, cx, columns(cx))
		elseif name == "p" then
			return move(state, cx, -columns(cx))
		else
			return false
		end
		return true
	end
	if name == "left" then
		return move(state, cx, -1)
	elseif name == "right" then
		return move(state, cx, 1)
	elseif name == "up" then
		return move(state, cx, -columns(cx))
	elseif name == "down" then
		return move(state, cx, columns(cx))
	elseif name == "page_up" then
		return move(state, cx, -columns(cx) * 3)
	elseif name == "page_down" then
		return move(state, cx, columns(cx) * 3)
	elseif name == "home" then
		return move(state, cx, -math.huge)
	elseif name == "end" then
		return move(state, cx, math.huge)
	elseif name == "enter" then
		return open_selected(state, cx, if k.alt then "split" else "tab")
	elseif name == "escape" then
		if state.project_open then
			state.project_open = false
		elseif state.query ~= "" then
			set_query(state, "")
		elseif state.project ~= ALL then
			state.project = ALL
			state.pages = 1
		else
			return false
		end
		return true
	elseif name == "backspace" then
		if state.query == "" then
			return false
		end
		set_query(state, if k.alt then drop_word(state.query) else drop_char(state.query))
		return true
	elseif name == "tab" then
		cycle_project(state, if k.shift then -1 else 1)
		return true
	elseif name == "paste" then
		local text = string.gsub(k.text or "", "%s+", " ")
		if text == "" then
			return false
		end
		set_query(state, state.query .. text)
		return true
	end
	local text = k.text
	if text and text ~= "" and not string.find(text, "%c") then
		set_query(state, state.query .. text)
		return true
	end
	return false
end

-- Events ----------------------------------------------------------------------

local function event(state: State, ev: UiEvent, cx: BlockCx)
	if ev.ev == "action" then
		local act = ev.act
		local s = find(if type(ev.value) == "string" then ev.value else nil)
		if act == "wake" then
			refresh(false) -- the window half: the gallery got focus
		elseif act == "refresh" then
			refresh(true)
		elseif act == "more" then
			state.pages += 1
		elseif act == "clear" then
			set_query(state, "")
		elseif act == "reset" then
			set_query(state, "")
			state.project = ALL
		elseif s == nil then
			return
		elseif act == "pick" then
			state.selected = s.key
		elseif act == "open" or act == "split" then
			state.selected = s.key
			resume(cx, s, if act == "split" or has_mod(ev, "alt") then "split" else "tab")
		elseif act == "folder" then
			cx:open(s.cwd)
		elseif act == "copyid" then
			cx:copy(s.id)
			cx:toast("success", "Copied the session ID", s.id)
		elseif act == "copycmd" then
			local command = common.resume_command(ROOT .. "/" .. s.rel)
			cx:copy(command)
			cx:toast("success", "Copied the resume command", command)
		end
	elseif ev.ev == "change" and ev.id == PROJECT_ID and type(ev.value) == "string" then
		state.project = ev.value
		state.project_open = false
		state.pages = 1
	elseif ev.ev == "toggle" and ev.id == PROJECT_ID then
		state.project_open = ev.open == true
	elseif ev.ev == "focus" and ev.id == SEARCH_ID then
		cx:frame({ { "focus", SEARCH_ID } })
	end
end

load_index()

tern.block.define("gallery", {
	font = "sans",

	init = function(cx: BlockCx, _args: { string }, saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local state: State = {
			cx = cx,
			query = "",
			project = if type(saved) == "table" and type(saved.project) == "string" then saved.project else ALL,
			project_open = false,
			selected = nil,
			pages = 1,
		}
		running[cx.pane] = state
		refresh(true)
		-- Draw first, so the field the focus op names exists.
		cx:render()
		cx:frame({ { "focus", SEARCH_ID } })
		return state
	end,

	title = function(_state: State): string?
		return "omp sessions"
	end,

	view = view,
	key = key,
	event = event,

	save = function(state: State): any
		return { project = state.project }
	end,
})
