--!strict
-- omp-gallery, host half: the `gallery` block, every omp session on this
-- machine as a grid of cards.
--
-- Session files (~/.omp/agent/sessions/<project>/<time>_<id>.jsonl), and the
-- subagent sessions in the folder beside each, are read a few at a time on
-- timer ticks and cached by size and mtime in <data>/index.json, so a refresh
-- reads only the files that changed. Each card shows what its session spent
-- (tokens and list-price dollars, subagents included) and takes the color of
-- the tab it is open in. Archiving hides a session under the Archived button;
-- deleting removes its files for good.
-- A session omp holds shows what omp does with it: working on a turn (and
-- for how long), waiting for the user's answer, or just open. The window half
-- reports how its omp panes are doing; a session only an omp elsewhere holds
-- (`omp session lease`) goes by its file. Resuming one is the window's
-- business (a new tab), asked for with an `omp-gallery://` link.
--
-- Keys: type to search, ←↑↓→ move, Enter resumes in a new tab (⌥Enter: in a
-- split), ⌃N starts a new session in a folder you pick, Tab/⇧Tab cycle the
-- project filter, ⌃G the grouping (none, workspace, last active), ⌃L
-- switches cards and list, ⌃E archives, ⌃D deletes (after asking), Esc
-- clears, ⌃R refreshes.

local common = require("./common")

local ui = tern.ui

local HOME = tern.getenv("HOME") or ""
local ROOT = HOME .. "/.omp/agent/sessions"
local INDEX_FILE = tern.plugin.data .. "/index.json"
local INDEX_VERSION = 3

local MAX_FILE = 160 * 1024 * 1024 -- larger session files are listed, not read
local HEAD = 320 -- bytes at the start of a line that say what it is
local PROMPT_CHARS = 280
local SLICE_MS = 120 -- parsing per timer tick
local WAKE_MS = 5000 -- a focus refresh this soon after the last scan is skipped
local SOON_MS = 400 -- after an agent's turn starts or ends, until its file shows it
local TICK_MS = 20000 -- how often a list showing working sessions redraws their minutes
local REPORT_MS = 500 -- after the block starts, until it asks the window half for its report

local PAGE = 24 -- cards per page: whole rows at 1 to 4 columns
local LIST_PAGE = 60 -- list rows per page
local CARD_CELLS = 44 -- pane width one column of cards needs, in cells
local MAX_COLUMNS = 4

local ALL = "*" -- the project filter's "every project"
local SEARCH_ID = "main.bar.search"
local PROJECT_ID = "main.bar.project"
local GROUP_ID = "main.bar.group"
local VIEW_ID = "main.bar.view"
local GRID_ID = "main.grid"

local VIEWS = { "cards", "list" }
local GROUPINGS = { "none", "workspace", "time" }
local LAYOUT_FILE = tern.plugin.data .. "/layout.json" -- the last view and grouping chosen
local ARCHIVE_FILE = tern.plugin.data .. "/archived.json" -- archived session ids, with when

-- Tab colors gallery.css tints a card or row with.
local TAB_COLORS: { [string]: boolean } = {
	red = true,
	orange = true,
	yellow = true,
	green = true,
	teal = true,
	blue = true,
	purple = true,
	pink = true,
}

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

-- Lists every session file, and the subagent sessions in the folder beside
-- each, with sizes and mtimes in one process. Exit 3: no sessions folder yet.
local LIST_SCRIPT = [[
cd "$1" 2>/dev/null || exit 3
if stat --version >/dev/null 2>&1; then
	exec find . -mindepth 2 -type f -name '*.jsonl' -exec stat -c '%Y %s %n' -- {} +
fi
exec find . -mindepth 2 -type f -name '*.jsonl' -exec stat -f '%m %z %N' -- {} +
]]

type FileStat = {
	rel: string, -- "<project folder>/<file>.jsonl" under ROOT
	size: number, -- -1 when unknown
	mtime: number, -- seconds since the epoch; -1 when unknown
}

-- What a session file's requests spent, as omp recorded them.
type Usage = {
	input: number,
	output: number,
	cache_read: number,
	cache_write: number,
	tokens: number, -- all four
	cost: number, -- US dollars at the provider's list price
	requests: number,
}

-- A subagent's (or the advisor's) session file in a session's folder.
type Part = { rel: string, size: number, mtime: number, usage: Usage }

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
	turn: number?, -- the unfinished last turn's start, epoch ms; nil once answered
	asks: boolean?, -- that turn waits for an answer to omp's ask tool
	usage: Usage, -- what this file's requests spent
	spent: Usage?, -- with its subagents' sessions, worked out by rebuild
	subagents: number?, -- how many of those
	hay: string?, -- folded search text, built by the first search
}

type State = {
	cx: BlockCx,
	query: string,
	project: string, -- a cwd, or ALL
	project_open: boolean,
	view: string, -- one of VIEWS
	grouping: string, -- one of GROUPINGS
	grouping_open: boolean,
	folded: { [string]: boolean }, -- collapsed groups, by group key
	selected: string?, -- a session key
	pages: number,
	archived: boolean, -- showing the archive instead of the sessions
	confirm: string?, -- the session key a delete waits on
}

type Project = { cwd: string, count: number }

type Group = {
	key: string, -- node key
	title: string?, -- nil for the one group of an ungrouped view
	cwd: string?, -- a workspace group's folder
	sessions: { Session },
	drawn: number, -- how many of `sessions` the view draws
}

-- What the view draws, which is what the keys move through.
type Plan = {
	shown: { Session }, -- every session the filters let through
	groups: { Group },
	cols: number,
	order: { Session }, -- the drawn sessions in reading order
	rows: { { number } }, -- indexes into `order`, one row of cards at a time
	ids: { [string]: string }, -- node id by session key
	at: { [string]: number }, -- index into `order` by session key
	total: number, -- sessions outside folded groups
}

-- What omp does with a session it holds.
type Activity = {
	state: string, -- "working" on a turn, "waiting" for the user's answer, or just "open"
	since: number?, -- working: when the turn started, epoch ms, if known
	color: string?, -- the color of the tab showing it, if any
}

-- The index, shared by every gallery block of this host.
local sessions: { [string]: Session } = {} -- by rel
local list: { Session } = {} -- most recently active first
local live: { [string]: boolean } = {} -- ids a running omp holds
local parts: { [string]: Part } = {} -- subagent session files, by rel
local archive: { [string]: number } = {} -- archived sessions by id, with when
local tab_colors: { [number]: string } = {} -- each pane's tab color, by pane
-- How the window half's omp panes are doing (cx.agents:list() states, by
-- pane), and when this half saw a pane start working, for a file not read since.
local agents: { [number]: string } = {}
local went: { [number]: number } = {}
local soon = false -- a refresh after an agent state change is on its way
local ticking = false -- a redraw of the working minutes in lists is on its way
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

-- An ISO 8601 UTC time in milliseconds since the epoch.
local function utc_ms(s: string): number?
	local t = utc(s, ":")
	if t == nil then
		return nil
	end
	local frac = string.match(s, "^[^.]+%.(%d+)")
	return t * 1000 + (if frac then tonumber(string.sub(frac .. "00", 1, 3)) or 0 else 0)
end

-- Wall-clock milliseconds since the epoch. os.time() counts whole seconds, so
-- the monotonic clock carries the fraction; a jump (sleep, a clock change)
-- anchors it again.
local clock_base = os.time() * 1000 - tern.now()
local function now_ms(): number
	local ms = clock_base + tern.now()
	if math.abs(ms - os.time() * 1000) > 2000 then
		clock_base = os.time() * 1000 - tern.now()
		ms = clock_base + tern.now()
	end
	return ms
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

local tilde = common.tilde
local basename = common.basename

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

local USAGE_KEYS = { "input", "output", "cache_read", "cache_write", "tokens", "cost", "requests" }

local function no_usage(): Usage
	return { input = 0, output = 0, cache_read = 0, cache_write = 0, tokens = 0, cost = 0, requests = 0 }
end

local function add_usage(into: Usage, u: Usage)
	into.input += u.input
	into.output += u.output
	into.cache_read += u.cache_read
	into.cache_write += u.cache_write
	into.tokens += u.tokens
	into.cost += u.cost
	into.requests += u.requests
end

local function copy_usage(u: Usage): Usage
	local c = no_usage()
	add_usage(c, u)
	return c
end

-- A stored Usage, if it has every field.
local function usage_from(raw: any): Usage?
	if type(raw) ~= "table" then
		return nil
	end
	for _, k in USAGE_KEYS do
		if type(raw[k]) ~= "number" then
			return nil
		end
	end
	return {
		input = raw.input,
		output = raw.output,
		cache_read = raw.cache_read,
		cache_write = raw.cache_write,
		tokens = raw.tokens,
		cost = raw.cost,
		requests = raw.requests,
	}
end

-- Adds one request to `u`: the "usage" object of an assistant line, starting
-- at `from` (its keys looked up, not assumed in order).
local function count_usage(u: Usage, data: string, from: number, stop: number)
	local chunk = string.sub(data, from, math.min(stop, from + 1023))
	local input = tonumber(string.match(chunk, '"input":(%d+)')) or 0
	local output = tonumber(string.match(chunk, '"output":(%d+)')) or 0
	local cache_read = tonumber(string.match(chunk, '"cacheRead":(%d+)')) or 0
	local cache_write = tonumber(string.match(chunk, '"cacheWrite":(%d+)')) or 0
	u.input += input
	u.output += output
	u.cache_read += cache_read
	u.cache_write += cache_write
	u.tokens += tonumber(string.match(chunk, '"totalTokens":(%d+)')) or (input + output + cache_read + cache_write)
	u.cost += tonumber(string.match(chunk, '"cost":{[^}]*"total":([%d%.eE+-]+)')) or 0
	u.requests += 1
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
		usage = no_usage(),
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
	local turn: number? = nil -- when the last turn started, epoch ms
	local last_role: string? = nil -- of the last user, assistant or tool result message
	local usage_at = 0 -- where the next "usage" object starts, as far as searched
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
			-- A prompt after an answer starts a turn; one sent while the agent
			-- worked (after a tool result) joins that turn.
			if turn == nil or last_role == "assistant" then
				turn = if at then utc_ms(at) else nil
			end
			last_role = "user"
		elseif string.find(head, '"message":{"role":"assistant"', 1, true) then
			assistant_at, assistant_end = pos, stop
			last_role = "assistant"
			-- Each search goes past the lines before its hit, so the whole
			-- file is searched once.
			if usage_at < pos then
				usage_at = string.find(data, '"usage":{', pos, true) or n + 1
			end
			if usage_at <= stop then
				count_usage(s.usage, data, usage_at, stop)
			end
		elseif string.find(head, '"message":{"role":"toolResult"', 1, true) then
			last_role = "toolResult"
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
	local answer = if assistant_at > 0 then string.sub(data, assistant_at, assistant_end) else ""
	local provider, model = string.match(answer, '"provider":"([^"]*)","model":"([^"]*)"')
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
	-- The last turn goes on unless the agent's last answer ended it; one that
	-- stopped to call omp's ask tool waits for the user.
	if turn and last_role then
		local reason = if last_role == "assistant" then string.match(answer, '.*"stopReason":"(%a+)"') else nil
		if last_role ~= "assistant" or reason == "toolUse" then
			s.turn = turn
			s.asks = if reason == "toolUse" and string.find(answer, '"type":"toolCall","id":"[^"]*","name":"ask"')
				then true
				else nil
		end
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

-- A subagent session file ("<project>/<session>/…/<name>.jsonl"), not a
-- session of its own.
local function is_part(rel: string): boolean
	return string.match(rel, "^[^/]+/[^/]+/") ~= nil
end

-- The session file a subagent session file belongs to.
local function parent_of(rel: string): string?
	local folder = string.match(rel, "^([^/]+/[^/]+)/")
	return if folder then folder .. ".jsonl" else nil
end

local function read_part(f: FileStat): Part?
	local ok, data = pcall(tern.fs.read, ROOT .. "/" .. f.rel, MAX_FILE)
	if ok then
		return { rel = f.rel, size = f.size, mtime = f.mtime, usage = parse(data, f).usage }
	elseif f.size > MAX_FILE then
		return { rel = f.rel, size = f.size, mtime = f.mtime, usage = no_usage() }
	end
	return nil
end

-- Every session file under ROOT and its subagents'. `stat` gives sizes and
-- mtimes for the cache; without a shell (Windows) the folders are listed and
-- every file is read.
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
		-- A session's subagents and advisor keep theirs in the folder named
		-- after its file.
		local function walk(rel: string, depth: number)
			local listed, names = pcall(tern.fs.list, ROOT .. "/" .. rel)
			if not listed or depth > 4 then
				return
			end
			for _, name in names do
				if string.sub(name, 1, 1) ~= "." then
					if string.sub(name, -6) == ".jsonl" then
						table.insert(files, { rel = rel .. "/" .. name, size = -1, mtime = -1 })
					else
						walk(rel .. "/" .. name, depth + 1)
					end
				end
			end
		end
		for _, dir in dirs do
			if string.sub(dir, 1, 1) ~= "." then
				local listed, names = pcall(tern.fs.list, ROOT .. "/" .. dir)
				if listed then
					for _, name in names do
						if string.sub(name, 1, 1) ~= "." and string.sub(name, -6) == ".jsonl" then
							table.insert(files, { rel = dir .. "/" .. name, size = -1, mtime = -1 })
							walk(dir .. "/" .. string.sub(name, 1, -7), 1)
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
						local mtime, size, rel = string.match(row, "^(%d+) (%d+) %./(.+)$")
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
	-- What each session spent, its subagents' sessions included.
	for _, s in all do
		s.spent = copy_usage(s.usage)
		s.subagents = 0
	end
	for rel, p in parts do
		local parent = parent_of(rel)
		local s = if parent then sessions[parent] else nil
		if s then
			local spent = s.spent
			if spent then
				add_usage(spent, p.usage)
			end
			s.subagents = (s.subagents or 0) + 1
		end
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
			local s: { [string]: any } = {
				key = "",
				big = if raw.big == true then true else nil,
				turn = if type(raw.turn) == "number" then raw.turn else nil,
				asks = if raw.asks == true then true else nil,
			}
			local valid = true
			for _, field in STRINGS do
				valid = valid and type(raw[field]) == "string"
				s[field] = raw[field]
			end
			for _, field in NUMBERS do
				valid = valid and type(raw[field]) == "number"
				s[field] = raw[field]
			end
			s.usage = usage_from(raw.usage)
			valid = valid and s.usage ~= nil
			if valid then
				sessions[s.rel] = s :: any
			end
		end
	end
	if type(data.parts) == "table" then
		for _, raw in data.parts do
			local usage = if type(raw) == "table" then usage_from(raw.usage) else nil
			if usage and type(raw.rel) == "string" and type(raw.size) == "number" and type(raw.mtime) == "number" then
				parts[raw.rel] = { rel = raw.rel, size = raw.size, mtime = raw.mtime, usage = usage }
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
			turn = s.turn,
			asks = s.asks,
			usage = s.usage,
		})
	end
	local kept = tern.json.array()
	for _, p in parts do
		table.insert(kept, { rel = p.rel, size = p.size, mtime = p.mtime, usage = p.usage })
	end
	local ok, err = pcall(function()
		if not tern.fs.exists(tern.plugin.data) then
			tern.fs.mkdir(tern.plugin.data)
		end
		tern.fs.write(INDEX_FILE, tern.json.encode({ v = INDEX_VERSION, sessions = out, parts = kept }))
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

-- List rows can't hold a live timer: while one shows how long a session has
-- been working, redraw it now and then.
local function tick_later()
	if ticking then
		return
	end
	ticking = true
	tern.timer(TICK_MS, function()
		ticking = false
		render_all()
	end)
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
			local size, mtime = -2, -2
			if is_part(f.rel) then
				local old = parts[f.rel]
				if old then
					size, mtime = old.size, old.mtime
				end
			else
				local old = sessions[f.rel]
				if old then
					size, mtime = old.size, old.mtime
				end
			end
			if size ~= f.size or mtime ~= f.mtime or f.mtime < 0 then
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
		for rel in parts do
			if not present[rel] then
				table.insert(gone, rel)
			end
		end
		for _, rel in gone do
			sessions[rel] = nil
			parts[rel] = nil
			changed = true
		end
		-- Sessions before subagents, newest first, so the sessions people look
		-- for show up first.
		table.sort(todo, function(a: FileStat, b: FileStat): boolean
			local pa, pb = is_part(a.rel), is_part(b.rel)
			if pa ~= pb then
				return pb
			end
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
				if is_part(f.rel) then
					local ok, p = pcall(read_part, f)
					if not ok then
						tern.log.warn("omp-gallery: could not read", f.rel, p)
					elseif p then
						parts[f.rel] = p
					else
						parts[f.rel] = nil
					end
				else
					local ok, s = pcall(read_session, f)
					if not ok then
						tern.log.warn("omp-gallery: could not read", f.rel, s)
					elseif s then
						sessions[f.rel] = s
					else
						sessions[f.rel] = nil
					end
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

-- The window half's report of its panes (JSON): how each omp pane is doing
-- (`states`, as cx.agents:list() says) and each pane's tab color (`colors`).
-- Sent when the gallery gets focus and whenever an agent's state changes.
-- True when something changed.
local function take_report(value: any): boolean
	local data = if type(value) == "string" then decode(value) else nil
	if data == nil then
		return false
	end
	local changed = false
	local colors: { [number]: string } = {}
	if type(data.colors) == "table" then
		for id, color in data.colors do
			local pane = tonumber(id)
			if pane and type(color) == "string" and TAB_COLORS[color] then
				colors[pane] = color
				changed = changed or tab_colors[pane] ~= color
			end
		end
	end
	for pane in tab_colors do
		changed = changed or colors[pane] == nil
	end
	tab_colors = colors
	local now = now_ms()
	local fresh: { [number]: string } = {}
	if type(data.states) == "table" then
		for id, st in data.states do
			local pane = tonumber(id)
			if pane and type(st) == "string" then
				fresh[pane] = st
				local was = agents[pane]
				if st ~= was then
					changed = true
					-- A turn seen starting; one under way before the first report has no start here.
					if st == "working" and was ~= nil then
						went[pane] = now
					else
						went[pane] = nil
					end
				end
			end
		end
	end
	for pane in agents do
		if fresh[pane] == nil then
			changed = true
			went[pane] = nil
		end
	end
	agents = fresh
	return changed
end

-- After a turn starts or ends, reads the files that changed once they show it.
local function refresh_soon()
	if soon then
		return
	end
	soon = true
	tern.timer(SOON_MS, function()
		soon = false
		refresh(true)
	end)
end

-- The archive: sessions put away, by id (a file without one goes by its
-- path), with when. They show only under the Archived button.
local function archive_key(s: Session): string
	return if s.id ~= "" then s.id else s.rel
end

local function is_archived(s: Session): boolean
	return archive[archive_key(s)] ~= nil
end

local function load_archive()
	local ok, data = pcall(function(): any
		return tern.json.decode(tern.fs.read(ARCHIVE_FILE, 16 * 1024 * 1024))
	end)
	if ok and type(data) == "table" then
		for id, at in data do
			if type(id) == "string" and type(at) == "number" then
				archive[id] = at
			end
		end
	end
end

local function save_archive()
	local ok, err = pcall(function()
		if not tern.fs.exists(tern.plugin.data) then
			tern.fs.mkdir(tern.plugin.data)
		end
		tern.fs.write(ARCHIVE_FILE, tern.json.encode(archive))
	end)
	if not ok then
		tern.log.warn("omp-gallery: archive not saved", err)
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

-- The sessions the query, the project filter and the archive button let
-- through, newest first.
local function filtered(state: State): { Session }
	local terms: { string } = {}
	for term in string.gmatch(fold(state.query), "%S+") do
		table.insert(terms, term)
	end
	local out: { Session } = {}
	for _, s in list do
		if (state.project == ALL or s.cwd == state.project) and is_archived(s) == state.archived then
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

-- A short name for each project folder: its own name, with its parent's when
-- two folders share a name.
local function project_names(): { [string]: string }
	local all = projects()
	local seen: { [string]: number } = {}
	for _, p in all do
		local name = basename(p.cwd)
		seen[name] = (seen[name] or 0) + 1
	end
	local names: { [string]: string } = {}
	for _, p in all do
		local name = basename(p.cwd)
		if (seen[name] or 0) > 1 then
			name = string.match(p.cwd, "([^/]+/[^/]+)/*$") or name
		end
		names[p.cwd] = name
	end
	return names
end

local function columns(cx: BlockCx): number
	return math.clamp(cx.cols // CARD_CELLS, 1, MAX_COLUMNS)
end

local function find(key: string?): Session?
	for _, s in list do
		if s.key == key then
			return s
		end
	end
	return nil
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

-- The omp pane on this host showing each session (see common.shows), by key.
local function on_screen(): { [string]: number }
	local open: { [string]: number } = {}
	local panes = tern.pane.list()
	for _, s in list do
		for _, p in panes do
			if common.shows(p.title, p.cwd, s.title, s.cwd) then
				open[s.key] = p.pane
				break
			end
		end
	end
	return open
end

-- What omp does with each session it holds, by key. The window half's report
-- says how an omp pane is doing; a session an omp elsewhere leases, or one in
-- a pane not reported yet, goes by its file.
local function activities(): { [string]: Activity }
	local panes = on_screen()
	local out: { [string]: Activity } = {}
	for _, s in list do
		local pane = panes[s.key]
		local reported = if pane then agents[pane] else nil
		local state: string? = nil
		if reported == "working" then
			state = "working"
		elseif reported == "waiting_input" then
			state = "waiting"
		elseif reported == "idle" then
			state = "open"
		elseif live[s.id] or (pane and reported == nil) then
			state = if s.turn == nil then "open" elseif s.asks then "waiting" else "working"
		end
		if state then
			out[s.key] = {
				state = state,
				since = if state ~= "working" then nil elseif s.turn then s.turn elseif pane then went[pane] else nil,
				color = if pane then tab_colors[pane] else nil,
			}
		end
	end
	return out
end

local function page_size(state: State): number
	return if state.view == "list" then LIST_PAGE else PAGE
end

-- A node key for any text (a folder path), the same every time.
local function slug(text: string): string
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + string.byte(text, i)) % 4294967296
	end
	return string.format("%08x", h)
end

-- Local midnight today, in seconds since the epoch.
local function today(): number
	local now = os.date("*t") :: any
	return os.time({ year = now.year, month = now.month, day = now.day, hour = 0, min = 0, sec = 0 })
end

-- The "last active" groups between the ones omp holds and "Older": a session
-- last active on or after `days` days before today goes in the first that
-- takes it.
local SPANS = {
	{ key = "today", title = "Today", days = 0 },
	{ key = "yesterday", title = "Yesterday", days = 1 },
	{ key = "week", title = "Last 7 days", days = 6 },
	{ key = "month", title = "Last 30 days", days = 29 },
}

local function groups_of(state: State, shown: { Session }, doing: { [string]: Activity }): { Group }
	if state.grouping == "workspace" then
		local names = project_names()
		local by: { [string]: Group } = {}
		local out: { Group } = {}
		for _, s in shown do
			local g = by[s.cwd]
			if g == nil then
				g = {
					key = "w" .. slug(s.cwd),
					title = if s.cwd == "" then "Unknown folder" else names[s.cwd] or basename(s.cwd),
					cwd = s.cwd,
					sessions = {},
					drawn = 0,
				}
				by[s.cwd] = g
				table.insert(out, g)
			end
			table.insert(g.sessions, s)
		end
		return out
	elseif state.grouping == "time" then
		-- What omp does with a session first, then when it was last active.
		local groups: { Group } = {
			{ key = "tworking", title = "Working now", sessions = {}, drawn = 0 },
			{ key = "twaiting", title = "Waiting for you", sessions = {}, drawn = 0 },
			{ key = "topen", title = "Open", sessions = {}, drawn = 0 },
		}
		local held = #groups
		for _, span in SPANS do
			table.insert(groups, { key = "t" .. span.key, title = span.title, sessions = {}, drawn = 0 })
		end
		table.insert(groups, { key = "tolder", title = "Older", sessions = {}, drawn = 0 })
		local start = today()
		for _, s in shown do
			local into = groups[#groups]
			local a = doing[s.key]
			if a then
				into = groups[if a.state == "working" then 1 elseif a.state == "waiting" then 2 else 3]
			else
				for i, span in SPANS do
					if s.updated >= start - span.days * 86400 then
						into = groups[held + i]
						break
					end
				end
			end
			table.insert(into.sessions, s)
		end
		local out: { Group } = {}
		for _, g in groups do
			if #g.sessions > 0 then
				table.insert(out, g)
			end
		end
		return out
	end
	return { { key = "all", sessions = shown, drawn = 0 } }
end

-- Folded groups draw their heading only; sessions past the pages shown wait
-- behind the pager.
local function plan(state: State, cx: BlockCx, doing: { [string]: Activity }): Plan
	local shown = filtered(state)
	local cols = if state.view == "list" then 1 else columns(cx)
	local limit = state.pages * page_size(state)
	local p: Plan = {
		shown = shown,
		groups = groups_of(state, shown, doing),
		cols = cols,
		order = {},
		rows = {},
		ids = {},
		at = {},
		total = 0,
	}
	for _, g in p.groups do
		if g.title and state.folded[g.key] then
			continue
		end
		p.total += #g.sessions
		local base = if g.title then GRID_ID .. "." .. g.key else GRID_ID
		g.drawn = math.clamp(limit - #p.order, 0, #g.sessions)
		for i = 1, g.drawn do
			local s = g.sessions[i]
			table.insert(p.order, s)
			p.at[s.key] = #p.order
			if (i - 1) % cols == 0 then
				table.insert(p.rows, {})
			end
			table.insert(p.rows[#p.rows], #p.order)
			p.ids[s.key] = if state.view == "list"
				then base .. ".list." .. s.key
				else base .. ".r" .. ((i - 1) // cols + 1) .. "." .. s.key
		end
	end
	return p
end

-- The selected session: the one picked, else the first drawn.
local function chosen(state: State, p: Plan): Session?
	return p.order[p.at[state.selected or ""] or 1]
end

-- Moves the selection `n` sessions, or `n` rows of cards with `rows`. Moving
-- past the last one drawn shows the next page.
local function move(state: State, cx: BlockCx, n: number, rows: boolean): boolean
	local doing = activities()
	local p = plan(state, cx, doing)
	if #p.order == 0 then
		return false
	end
	local i = p.at[state.selected or ""] or 1
	local r, c = 1, 1
	for ri, row in p.rows do
		local ci = table.find(row, i)
		if ci then
			r, c = ri, ci
			break
		end
	end
	local past = if rows then r + n > #p.rows else i + n > #p.order
	if past and p.total > #p.order then
		state.pages = if n == math.huge then math.ceil(p.total / page_size(state)) else state.pages + 1
		p = plan(state, cx, doing)
	end
	local target = math.clamp(i + n, 1, #p.order)
	if rows then
		local row = p.rows[math.clamp(r + n, 1, #p.rows)]
		target = row[math.min(c, #row)]
	end
	local s = p.order[target]
	state.selected = s.key
	-- Draw first, so the node the reveal names exists.
	cx:render()
	cx:frame({ { "reveal", p.ids[s.key], "nearest" } })
	return true
end

local function one_of(value: any, allowed: { string }): string?
	return if type(value) == "string" and table.find(allowed, value) then value else nil
end

-- The view and grouping last chosen, for galleries opened later.
local function load_layout(): (string?, string?)
	local ok, data = pcall(function(): any
		return tern.json.decode(tern.fs.read(LAYOUT_FILE))
	end)
	if ok and type(data) == "table" then
		return one_of(data.view, VIEWS), one_of(data.grouping, GROUPINGS)
	end
	return nil, nil
end

local function set_layout(state: State, view: string, grouping: string)
	if view == state.view and grouping == state.grouping then
		return
	end
	state.view, state.grouping, state.pages = view, grouping, 1
	local ok, err = pcall(function()
		if not tern.fs.exists(tern.plugin.data) then
			tern.fs.mkdir(tern.plugin.data)
		end
		tern.fs.write(LAYOUT_FILE, tern.json.encode({ view = view, grouping = grouping }))
	end)
	if not ok then
		tern.log.warn("omp-gallery: layout not saved", err)
	end
end

local function cycle(allowed: { string }, value: string, step: number): string
	local at = table.find(allowed, value) or 1
	return allowed[(at - 1 + step) % #allowed + 1]
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

-- Asks the window half for a new omp session in `cwd`, or without one for its
-- folder picker (at the project filter's folder, else home).
local function new_session(state: State, cx: BlockCx, cwd: string?)
	if cwd then
		cx:open(common.link("start", { cwd = cwd }))
		return
	end
	cx:open(common.link("new", { cwd = if state.project ~= ALL then state.project else "" }))
end

local function has_mod(ev: UiEvent, mod: string): boolean
	return type(ev.mods) == "table" and table.find(ev.mods, mod) ~= nil
end

-- Archive and delete --------------------------------------------------------

-- A session's title as people read it.
local function display_title(s: Session): string
	local _, _, text = split_title(s.title)
	return if text ~= "" then text else "Untitled session"
end

local function archived_count(): number
	local n = 0
	for _, s in list do
		if is_archived(s) then
			n += 1
		end
	end
	return n
end

local function toggle_archive(cx: BlockCx, s: Session)
	local id = archive_key(s)
	if archive[id] then
		archive[id] = nil
		cx:toast("success", "Unarchived", display_title(s))
	else
		archive[id] = os.time()
		cx:toast("success", "Archived", display_title(s) .. ": the Archived button shows it again.")
	end
	save_archive()
	render_all()
end

-- Whether omp holds `s` now: a running omp leases it or a pane shows it.
local function held_now(s: Session): boolean
	return live[s.id] == true or activities()[s.key] ~= nil
end

-- Removes a session for good: its file, the folder beside it (subagents,
-- advisor, tool output), its lock file, and its project's folder once empty.
local function delete_session(cx: BlockCx, s: Session)
	local file = ROOT .. "/" .. s.rel
	local folder = string.sub(file, 1, -7)
	local lock = (string.gsub(file, "([^/]+)$", ".%1.lock.os"))
	local ok, err = pcall(function()
		tern.fs.remove(file)
		for _, path in { folder, lock } do
			if tern.fs.exists(path) then
				tern.fs.remove(path)
			end
		end
	end)
	if not ok then
		cx:toast("error", "Couldn't delete the session", tostring(err))
		refresh(true)
		return
	end
	-- omp makes the project's folder again for its next session there.
	pcall(function()
		local project = string.match(file, "^(.*)/[^/]+$") :: string
		if #tern.fs.list(project) == 0 then
			tern.fs.remove(project)
		end
	end)
	sessions[s.rel] = nil
	local inside = string.sub(s.rel, 1, -7) .. "/"
	local gone: { string } = {}
	for rel in parts do
		if string.sub(rel, 1, #inside) == inside then
			table.insert(gone, rel)
		end
	end
	for _, rel in gone do
		parts[rel] = nil
	end
	if archive[archive_key(s)] then
		archive[archive_key(s)] = nil
		save_archive()
	end
	rebuild()
	save_index()
	render_all()
	cx:toast("success", "Deleted", display_title(s))
end

local HELD_TITLE = "omp has this session open"
local HELD_TEXT = "Close it in omp first, then delete it."

-- Asks before deleting `s`, with the strip in the dock.
local function ask_delete(state: State, cx: BlockCx, s: Session?): boolean
	if s == nil then
		return false
	end
	if held_now(s) then
		cx:toast("info", HELD_TITLE, HELD_TEXT)
		return true
	end
	state.selected = s.key
	state.confirm = s.key
	return true
end

-- The delete the strip asked about, confirmed.
local function erase(state: State, cx: BlockCx)
	local s = find(state.confirm)
	state.confirm = nil
	if s == nil then
		return
	end
	if held_now(s) then
		cx:toast("info", HELD_TITLE, HELD_TEXT)
		return
	end
	delete_session(cx, s)
end

-- The dock's question before a delete: Escape cancels, Enter deletes.
local function confirm_strip(s: Session): Node
	return ui.node("card", {
		key = "confirm",
		tone = "error",
		icon = "trash",
		head = "Delete “" .. display_title(s) .. "”?",
		["end"] = "dock.confirm.end",
	}, {
		ui.node("row", { key = "end", gap = "sm" }, {
			ui.button("Cancel", { key = "cancel", variant = "quiet", size = "sm", keys = { "esc" }, actions = { click = "cancel" } }),
			ui.button("Delete", { key = "go", variant = "danger", size = "sm", keys = { "enter" }, actions = { click = "erase" } }),
		}),
		ui.node("text", {
			key = "what",
			spans = { ui.span("Its transcript, subagents and tool output are deleted for good; omp can't resume it afterwards.", "muted") },
		}),
	})
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
		ui.button("New session", {
			key = "new",
			icon = "plus",
			variant = "primary",
			keys = { "ctrl+n" },
			actions = { click = "new" },
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
	local names = project_names()
	local options: { any } = { { value = ALL, label = "All projects", detail = group(#list) } }
	for _, p in projects() do
		table.insert(options, { value = p.cwd, label = names[p.cwd], detail = group(p.count), icon = "folder" })
	end
	return options
end

local function toolbar(state: State): Node
	local stored = archived_count()
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
		ui.node("select", {
			key = "group",
			variant = "quiet",
			label = "Group",
			value = state.grouping,
			open = state.grouping_open,
			options = {
				{ value = "none", label = "None" },
				{ value = "workspace", label = "Workspace", icon = "folder" },
				{ value = "time", label = "Last active", icon = "clock" },
			},
		}),
		ui.node("tabs", {
			key = "view",
			variant = "segmented",
			active = state.view,
			items = { { id = "cards", label = "Cards" }, { id = "list", label = "List" } },
		}),
		ui.button(if stored > 0 then "Archived " .. group(stored) else "Archived", {
			key = "archived",
			icon = "inbox",
			variant = "quiet",
			on = state.archived,
			title = if state.archived then "Back to your sessions" else "Show archived sessions",
			actions = { click = "archived" },
		}),
	})
end

local function card_menu(s: Session, held: boolean): { any }
	return {
		{
			id = "open=" .. s.key,
			label = if held then "Show open session" else "Resume in new tab",
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
		{
			id = "here=" .. s.key,
			label = "New session in this folder",
			icon = "plus",
			disabled = if s.cwd == "" then "Unknown folder" else false,
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
		"-",
		{
			id = "archive=" .. s.key,
			label = if is_archived(s) then "Unarchive" else "Archive",
			icon = "inbox",
			keys = { "ctrl", "e" },
		},
		{
			id = "delete=" .. s.key,
			label = "Delete…",
			icon = "trash",
			danger = true,
			keys = { "ctrl", "d" },
			disabled = if held then "Close it in omp first" else false,
		},
	}
end

-- Money at list prices: "$4.21", "<$0.01", "$1,234".
local function money(n: number): string
	if n <= 0 then
		return "$0"
	elseif n < 0.01 then
		return "<$0.01"
	elseif n < 1000 then
		return string.format("$%.2f", n)
	end
	return "$" .. group(n)
end

-- What a session spent, its subagents included: the hovercard of its spend.
local function spend_card(s: Session): Node
	local u = s.spent or s.usage
	local items: { any } = {
		{ k = "Cost", v = { ui.span(money(u.cost), "strong") } },
		{ k = "Tokens", v = { ui.span(group(u.tokens), "mono") } },
		{ k = "Input", v = { ui.span(group(u.input), "mono") } },
		{ k = "Output", v = { ui.span(group(u.output), "mono") } },
		{ k = "Cache read", v = { ui.span(group(u.cache_read), "mono") } },
		{ k = "Cache write", v = { ui.span(group(u.cache_write), "mono") } },
		{ k = "Requests", v = { ui.span(group(u.requests), "mono") } },
	}
	local helpers = s.subagents or 0
	if helpers > 0 then
		table.insert(items, {
			k = "Subagents",
			v = { ui.span(money(u.cost - s.usage.cost), "mono"), ui.span(" in " .. count(helpers, "session"), "muted") },
		})
	end
	return ui.node("col", { gap = "sm" }, {
		ui.node("text", { spans = { ui.span("Spent on this session", "strong") } }),
		ui.node("kv", { items = items }),
		ui.node("text", { spans = { ui.span("At list prices, as omp recorded them", "dim") } }),
	})
end

-- The role gallery.css tints a session's card or row by, with its tab's color.
local function tab_role(a: Activity?): string?
	return if a and a.color then "omp-gallery.tab-" .. a.color else nil
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
	local u = s.spent or s.usage
	if u.requests > 0 then
		table.insert(kids, ui.node("badge", { key = "spent", text = money(u.cost), hovercard = spend_card(s) }))
	end
	return ui.node("row", { key = "foot", gap = "sm", align = "center" }, kids)
end

-- How long, in minutes: "<1m", "4m", "1h 05m".
local function minutes(ms: number): string
	local m = ms // 60000
	if m < 1 then
		return "<1m"
	elseif m < 60 then
		return string.format("%dm", m)
	end
	return string.format("%dh %02dm", m // 60, m % 60)
end

-- A held session's marks: what omp does with it and, while it works, a live
-- timer of the turn.
local function activity_marks(a: Activity?): { Node }
	if a == nil then
		return {}
	elseif a.state == "working" then
		local marks: { Node } = {
			ui.node("badge", { key = "doing", text = "Working", tone = "pending", title = "omp is working on a turn" }),
		}
		if a.since then
			table.insert(marks, ui.node("elapsed", { key = "took", age = math.max(0, now_ms() - a.since) }))
		end
		return marks
	elseif a.state == "waiting" then
		return {
			ui.node("badge", { key = "doing", text = "Waiting for you", tone = "warning", title = "omp asks you something" }),
		}
	end
	return { ui.node("badge", { key = "doing", text = "Open", title = "Open in omp, idle" }) }
end

local function session_card(s: Session, id: string, selected: boolean, a: Activity?): Node
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
		grow = 1,
		basis = 0,
		role = tab_role(a),
		actions = { click = "pick=" .. s.key, dblclick = "open=" .. s.key, menu = card_menu(s, a ~= nil) },
	}
	local kids: { Node } = {}
	local marks = activity_marks(a)
	if code then
		table.insert(marks, ui.node("badge", { key = "code", text = code }))
	end
	if #marks > 0 then
		table.insert(kids, ui.node("row", { key = "end", gap = "sm", align = "center" }, marks))
		props["end"] = id .. ".end"
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

-- A session as one list row: title, folder and prompt, then when.
local function session_item(s: Session, a: Activity?): Node
	local glyph, code, text = split_title(s.title)
	local label: { Span | string } = {}
	if glyph then
		table.insert(label, ui.span(glyph .. " "))
	end
	if text ~= "" then
		table.insert(label, ui.span(text, "strong"))
	else
		table.insert(label, ui.span(if s.big then "Large session" else "Untitled session", "muted"))
	end
	if code then
		table.insert(label, ui.span("  " .. code, "accent"))
	end
	local detail: { Span | string } = { ui.span(if s.cwd ~= "" then tilde(s.cwd) else "unknown folder", "path") }
	if s.prompt ~= "" then
		table.insert(detail, ui.span("   " .. s.prompt, "dim"))
	end
	local value: { Span | string } = {}
	if a and a.state == "working" then
		local took = if a.since then " " .. minutes(now_ms() - a.since) else ""
		table.insert(value, ui.span("Working" .. took .. " · ", "pending"))
	elseif a and a.state == "waiting" then
		table.insert(value, ui.span("Waiting for you · ", "warning"))
	elseif a then
		table.insert(value, ui.span("Open · "))
	end
	local u = s.spent or s.usage
	if u.requests > 0 then
		table.insert(value, ui.span(money(u.cost) .. " · ", "mono"))
	end
	table.insert(value, ui.span(ago(s.updated), "muted"))
	return ui.node("item", {
		key = s.key,
		label = label,
		detail = detail,
		value = value,
		icon = if s.provider ~= "" then "provider:" .. s.provider else "app-omp",
		role = tab_role(a),
		hovercard = if u.requests > 0 then spend_card(s) else nil,
		actions = { click = "pick=" .. s.key, dblclick = "open=" .. s.key, menu = card_menu(s, a ~= nil) },
	})
end

-- A group's drawn sessions as rows of equal cards, the last row padded, so
-- every column lines up.
local function card_rows(g: Group, p: Plan, sel: string?, doing: { [string]: Activity }): { Node }
	local rows: { Node } = {}
	for first = 1, g.drawn, p.cols do
		local cells: { Node } = {}
		for i = first, math.min(first + p.cols - 1, g.drawn) do
			local s = g.sessions[i]
			table.insert(cells, session_card(s, p.ids[s.key], s.key == sel, doing[s.key]))
		end
		for pad = #cells + 1, p.cols do
			table.insert(cells, ui.node("row", { key = "pad" .. pad, grow = 1, basis = 0 }))
		end
		table.insert(rows, ui.node("row", { key = "r" .. ((first - 1) // p.cols + 1), gap = "md", align = "stretch" }, cells))
	end
	return rows
end

local function session_list(g: Group, p: Plan, sel: string?, doing: { [string]: Activity }): Node
	local items: { Node } = {}
	local selected: string? = nil
	for i = 1, g.drawn do
		local s = g.sessions[i]
		if s.key == sel then
			selected = p.ids[s.key]
		end
		table.insert(items, session_item(s, doing[s.key]))
	end
	return ui.node("list", { key = "list", selected = selected }, items)
end

local function group_body(state: State, g: Group, p: Plan, sel: string?, doing: { [string]: Activity }): { Node }
	if state.view == "list" then
		return { session_list(g, p, sel, doing) }
	end
	return card_rows(g, p, sel, doing)
end

-- A workspace heading's counts of what omp does with its sessions.
local COUNTS = {
	{ state = "working", label = "working", tone = "pending" },
	{ state = "waiting", label = "waiting", tone = "warning" },
	{ state = "open", label = "open", tone = "muted" },
}

-- A group's heading: its name, its folder and counts; a workspace's also
-- starts a session there or shows only it.
local function group_head(g: Group, doing: { [string]: Activity }): Node
	local spans: { Span | string } = { ui.span(g.title or "", "strong") }
	local cwd = g.cwd or ""
	if cwd ~= "" then
		table.insert(spans, ui.span("   " .. tilde(cwd), "muted"))
	end
	table.insert(spans, ui.span("   " .. count(#g.sessions, "session"), "dim"))
	if g.cwd then
		local counts: { [string]: number } = {}
		for _, s in g.sessions do
			local a = doing[s.key]
			if a then
				counts[a.state] = (counts[a.state] or 0) + 1
			end
		end
		for _, c in COUNTS do
			local n = counts[c.state]
			if n then
				table.insert(spans, ui.span(" · " .. n .. " " .. c.label, c.tone))
			end
		end
	end
	local kids: { Node } = { ui.node("text", { key = "title", grow = 1, wrap = "none", truncate = "end", spans = spans }) }
	if cwd ~= "" then
		table.insert(kids, ui.button("New session", {
			key = "new",
			icon = "plus",
			variant = "quiet",
			size = "sm",
			actions = { click = "newin=" .. cwd },
		}))
		table.insert(kids, ui.button("Only this", {
			key = "only",
			icon = "funnel",
			variant = "quiet",
			size = "sm",
			actions = { click = "only=" .. cwd },
		}))
	end
	return ui.node("row", { key = "head", gap = "sm", align = "center" }, kids)
end

local function sessions_view(state: State, p: Plan, doing: { [string]: Activity }): Node
	local current = chosen(state, p)
	local sel = if current then current.key else nil
	local kids: { Node } = {}
	for _, g in p.groups do
		if g.title == nil then
			kids = group_body(state, g, p, sel, doing)
			break
		end
		local folded = state.folded[g.key] == true
		if not folded and g.drawn == 0 then
			break -- behind the pager
		end
		local body: { Node } = { group_head(g, doing) }
		if not folded then
			for _, node in group_body(state, g, p, sel, doing) do
				table.insert(body, node)
			end
		end
		table.insert(kids, ui.node("section", {
			key = g.key,
			head = GRID_ID .. "." .. g.key .. ".head",
			collapsible = true,
			collapsed = folded,
		}, body))
		if not folded and g.drawn < #g.sessions then
			break
		end
	end
	return ui.node("col", { key = "grid", gap = "md" }, kids)
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
		if state.archived and state.query == "" then
			return ui.node("empty", { key = "grid", variant = "inline", frame = true, icon = "inbox", text = "No archived sessions" }, {
				ui.button("Back to sessions", { key = "back", variant = "quiet", size = "sm", keys = { "esc" }, actions = { click = "archived" } }),
			})
		end
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
		ui.button("New session", { key = "new", icon = "plus", variant = "primary", actions = { click = "new" } }),
		ui.button("Refresh", { key = "retry", icon = "repeat", actions = { click = "refresh" } }),
	})
end

local function legend(): Node
	local items = {
		{ "←↑↓→", "move" },
		{ "enter", "resume" },
		{ "alt+enter", "split" },
		{ "ctrl+n", "new session" },
		{ "tab", "project" },
		{ "ctrl+g", "group" },
		{ "ctrl+l", "cards/list" },
		{ "ctrl+e", "archive" },
		{ "ctrl+d", "delete" },
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
	local doing = activities()
	local p = plan(state, cx, doing)
	if state.view == "list" then
		for _, s in p.order do
			local a = doing[s.key]
			if a and a.since then
				tick_later()
				break
			end
		end
	end
	local main: { Node } = { head_row() }
	if #list > 0 then
		table.insert(main, stats_strip(p.shown))
	end
	table.insert(main, toolbar(state))
	if #p.shown > 0 then
		table.insert(main, sessions_view(state, p, doing))
		if p.total > #p.order then
			table.insert(main, ui.node("pager", {
				key = "more",
				variant = "more",
				page = state.pages,
				size = page_size(state),
				total = p.total,
				label = "sessions",
			}))
		end
	elseif #list == 0 and problem == nil and (scanning or scanned_clock == nil) then
		table.insert(main, loading(columns(cx)))
	else
		table.insert(main, nothing(state))
	end
	local dock: { Node } = {}
	local doomed = if state.confirm then find(state.confirm) else nil
	if doomed then
		table.insert(dock, confirm_strip(doomed))
	else
		state.confirm = nil
	end
	table.insert(dock, legend())
	return { main = ui.node("col", { gap = "md" }, main), dock = ui.col(dock) }
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
	local s = chosen(state, plan(state, cx, activities()))
	if s == nil then
		return false
	end
	state.selected = s.key
	resume(cx, s, how)
	return true
end

local function key(state: State, k: Key, cx: BlockCx): boolean?
	local name = k.name
	-- The delete question takes Enter and Escape while it shows.
	if state.confirm and not (k.meta or k.ctrl or k.alt) then
		if name == "enter" then
			erase(state, cx)
			return true
		elseif name == "escape" then
			state.confirm = nil
			return true
		end
	end
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
			new_session(state, cx)
		elseif name == "g" then
			set_layout(state, state.view, cycle(GROUPINGS, state.grouping, if k.shift then -1 else 1))
		elseif name == "l" then
			set_layout(state, cycle(VIEWS, state.view, 1), state.grouping)
		elseif name == "e" or name == "d" then
			local s = chosen(state, plan(state, cx, activities()))
			if s == nil then
				return false
			elseif name == "d" then
				return ask_delete(state, cx, s)
			end
			toggle_archive(cx, s)
		else
			return false
		end
		return true
	end
	if name == "left" then
		return move(state, cx, -1, false)
	elseif name == "right" then
		return move(state, cx, 1, false)
	elseif name == "up" then
		return move(state, cx, -1, true)
	elseif name == "down" then
		return move(state, cx, 1, true)
	elseif name == "page_up" then
		return move(state, cx, -3, true)
	elseif name == "page_down" then
		return move(state, cx, 3, true)
	elseif name == "home" then
		return move(state, cx, -math.huge, false)
	elseif name == "end" then
		return move(state, cx, math.huge, false)
	elseif name == "enter" then
		return open_selected(state, cx, if k.alt then "split" else "tab")
	elseif name == "escape" then
		if state.project_open or state.grouping_open then
			state.project_open, state.grouping_open = false, false
		elseif state.query ~= "" then
			set_query(state, "")
		elseif state.project ~= ALL then
			state.project = ALL
			state.pages = 1
		elseif state.archived then
			state.archived = false
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
			take_report(ev.value)
			refresh(false) -- the window half: the gallery got focus
		elseif act == "agents" then
			-- The window half: an omp pane started or ended a turn.
			if take_report(ev.value) then
				render_all()
				refresh_soon()
			end
		elseif act == "new" then
			new_session(state, cx)
		elseif act == "refresh" then
			refresh(true)
		elseif act == "more" then
			state.pages += 1
		elseif act == "clear" then
			set_query(state, "")
		elseif act == "reset" then
			set_query(state, "")
			state.project = ALL
		elseif act == "newin" and type(ev.value) == "string" and ev.value ~= "" then
			new_session(state, cx, ev.value)
		elseif act == "only" and type(ev.value) == "string" then
			state.project = ev.value
			state.pages = 1
		elseif act == "archived" then
			state.archived = not state.archived
			state.pages = 1
		elseif act == "cancel" then
			state.confirm = nil
		elseif act == "erase" then
			erase(state, cx)
		elseif s == nil then
			return
		elseif act == "pick" then
			state.selected = s.key
		elseif act == "open" or act == "split" then
			state.selected = s.key
			resume(cx, s, if act == "split" or has_mod(ev, "alt") then "split" else "tab")
		elseif act == "folder" then
			cx:open(s.cwd)
		elseif act == "here" and s.cwd ~= "" then
			new_session(state, cx, s.cwd)
		elseif act == "copyid" then
			cx:copy(s.id)
			cx:toast("success", "Copied the session ID", s.id)
		elseif act == "copycmd" then
			local command = common.resume_command(ROOT .. "/" .. s.rel)
			cx:copy(command)
			cx:toast("success", "Copied the resume command", command)
		elseif act == "archive" then
			toggle_archive(cx, s)
		elseif act == "delete" then
			ask_delete(state, cx, s)
		end
	elseif ev.ev == "change" and ev.id == PROJECT_ID and type(ev.value) == "string" then
		state.project = ev.value
		state.project_open = false
		state.pages = 1
	elseif ev.ev == "toggle" and ev.id == PROJECT_ID then
		state.project_open = ev.open == true
	elseif ev.ev == "change" and ev.id == GROUP_ID then
		state.grouping_open = false
		set_layout(state, state.view, one_of(ev.value, GROUPINGS) or state.grouping)
	elseif ev.ev == "toggle" and ev.id == GROUP_ID then
		state.grouping_open = ev.open == true
	elseif ev.ev == "select" and ev.id == VIEW_ID then
		set_layout(state, one_of(ev.item, VIEWS) or state.view, state.grouping)
	elseif ev.ev == "toggle" and type(ev.key) == "string" and ev.collapsed ~= nil then
		-- A group's heading folded or unfolded it.
		state.folded[ev.key] = ev.collapsed == true
	elseif ev.ev == "focus" and ev.id == SEARCH_ID then
		cx:frame({ { "focus", SEARCH_ID } })
	end
end

load_index()
load_archive()

tern.block.define("gallery", {
	font = "sans",

	init = function(cx: BlockCx, _args: { string }, saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local last: { [string]: any } = if type(saved) == "table" then saved else {}
		local view, grouping = load_layout()
		local folded: { [string]: boolean } = {}
		if type(last.folded) == "table" then
			for k, v in last.folded do
				if type(k) == "string" and v == true then
					folded[k] = true
				end
			end
		end
		local state: State = {
			cx = cx,
			query = "",
			project = if type(last.project) == "string" then last.project else ALL,
			project_open = false,
			view = one_of(last.view, VIEWS) or view or "cards",
			grouping = one_of(last.grouping, GROUPINGS) or grouping or "none",
			grouping_open = false,
			folded = folded,
			selected = nil,
			pages = 1,
			archived = false,
			confirm = nil,
		}
		running[cx.pane] = state
		refresh(true)
		-- Draw first, so the field the focus op names exists.
		cx:render()
		cx:frame({ { "focus", SEARCH_ID } })
		-- The window half's report (agents, tab colors) comes with focus and
		-- agent changes; ask for one now, once that half has loaded too.
		tern.timer(REPORT_MS, function()
			if running[cx.pane] == state then
				cx:open(common.link("report", {}))
			end
		end)
		return state
	end,

	title = function(_state: State): string?
		return "omp sessions"
	end,

	view = view,
	key = key,
	event = event,

	save = function(state: State): any
		return { project = state.project, view = state.view, grouping = state.grouping, folded = state.folded }
	end,
})
