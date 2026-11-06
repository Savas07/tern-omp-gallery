--!strict
-- Shared by both halves: names, the links the gallery block opens for the
-- window half to act on, and shell quoting for the resume command.

local M = {}

M.KIND = "omp-gallery.gallery"
M.OPEN = "plugin.omp-gallery.open"

-- A block can't reach the window's layout, so it asks with `cx:open` of an
-- `omp-gallery://<verb>?<field>=<value>&…` link, which the window half's
-- `tern.route.link` claims.
local SCHEME = "omp-gallery://"

local function encode(s: string): string
	return (string.gsub(s, "[^%w%-%._~/]", function(c: string): string
		return string.format("%%%02X", string.byte(c))
	end))
end

local function decode(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h: string): string
		return string.char(tonumber(h, 16) :: number)
	end))
end

function M.link(verb: string, fields: { [string]: string }): string
	local names: { string } = {}
	for name in fields do
		table.insert(names, name)
	end
	table.sort(names)
	local parts: { string } = {}
	for _, name in names do
		table.insert(parts, name .. "=" .. encode(fields[name]))
	end
	return SCHEME .. verb .. "?" .. table.concat(parts, "&")
end

-- The verb and fields of a gallery link; nil for any other URL.
function M.parse(url: string): (string?, { [string]: string })
	local fields: { [string]: string } = {}
	if string.sub(url, 1, #SCHEME) ~= SCHEME then
		return nil, fields
	end
	local verb, query = string.match(string.sub(url, #SCHEME + 1), "^([%w_]+)/?%??(.*)$")
	if verb == nil then
		return nil, fields
	end
	for name, value in string.gmatch(query or "", "([^&=]+)=([^&]*)") do
		fields[name] = decode(value :: string)
	end
	return verb, fields
end

-- `s` as one word for sh, bash, zsh and fish.
function M.quote(s: string): string
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

function M.resume_command(path: string): string
	return "omp --resume " .. M.quote(path)
end

-- omp names its pane after the session's title, so a pane with that title in
-- the session's folder shows the session. Untitled sessions can't be told
-- apart this way.
function M.shows(pane_title: string?, pane_cwd: string?, title: string, cwd: string): boolean
	if title == "" or pane_title ~= title then
		return false
	end
	return cwd == "" or pane_cwd == nil or pane_cwd == "" or pane_cwd == cwd
end

return M
