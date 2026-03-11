--- @since 25.5.31

-- ---- Constants & Enums ----

local shell = os.getenv("SHELL") or "/bin/sh"

---@enum FUSE_ARCHIVE_RETURN_CODE
local FUSE_ARCHIVE_RETURN_CODE = {
	SUCCESS = 0,
	ERROR_GENERIC = 1, -- Missing/extra args, unknown option, mount point not empty, etc.
	CREATE_MOUNT_POINT_FAILED = 10,
	OPEN_THE_ACHIVE_FILE_FAILED = 11,
	CREATE_CACHE_FILE_FAILED = 12,
	NOT_ENOUGH_TEMP_SPACE = 13, -- Not enough temp space for uncompressed cache.
	ENCRYPTED_FILE_BUT_NOT_PASSWORD = 20,
	ENCRYPTED_FILE_BUT_WRONG_PASSWORD = 21,
	ENCRYPTED_METHOD_UNSUPPORTED = 22,
	ARCHIVE_FORMAT_UNSUPPORTED = 30,
	ARCHIVE_HEADER_INVALID = 31,
	ARCHIVE_READ_PERMISSION_INVALID = 32,
}

---@enum FUSE_ARCHIVE_MOUNT_ERROR_MSG
local FUSE_ARCHIVE_MOUNT_ERROR_MSG = {
	[FUSE_ARCHIVE_RETURN_CODE.ERROR_GENERIC] = "Fuse-archive exited with error: %s",
	[FUSE_ARCHIVE_RETURN_CODE.CREATE_MOUNT_POINT_FAILED] = "Cannot create mount point %s, check permissions",
	[FUSE_ARCHIVE_RETURN_CODE.OPEN_THE_ACHIVE_FILE_FAILED] = "Cannot open archive file, check permissions",
	[FUSE_ARCHIVE_RETURN_CODE.CREATE_CACHE_FILE_FAILED] = "Cannot create cache file, trying nocache (this will be slower)",
	[FUSE_ARCHIVE_RETURN_CODE.NOT_ENOUGH_TEMP_SPACE] = "Not enough temp space for cache, trying nocache (this will be slower)",
	[FUSE_ARCHIVE_RETURN_CODE.ENCRYPTED_METHOD_UNSUPPORTED] = "Encryption method is unsupported",
	[FUSE_ARCHIVE_RETURN_CODE.ENCRYPTED_FILE_BUT_WRONG_PASSWORD] = "Incorrect password, %s attempts remaining.",
	[FUSE_ARCHIVE_RETURN_CODE.ENCRYPTED_FILE_BUT_NOT_PASSWORD] = "Please enter password to unlock file, %s attempts remaining.",
	[FUSE_ARCHIVE_RETURN_CODE.ARCHIVE_FORMAT_UNSUPPORTED] = "Unsupported archive format",
	[FUSE_ARCHIVE_RETURN_CODE.ARCHIVE_HEADER_INVALID] = "Archive file is corrupted",
	[FUSE_ARCHIVE_RETURN_CODE.ARCHIVE_READ_PERMISSION_INVALID] = "Cannot open archive file, check permissions",
}

---@enum YA_INPUT_EVENT
local YA_INPUT_EVENT = {
	ERROR = 0,
	CONFIRMED = 1,
	CANCELLED = 2,
	VALUE_CHANGED = 3,
}

-- ---- Notification Helpers ----
-- Named to avoid shadowing Lua's built-in error()

local function notify_error(s, ...)
	ya.notify({ title = "fuse-archive", content = string.format(s, ...), timeout = 3, level = "error" })
end

local function notify_info(s, ...)
	ya.notify({ title = "fuse-archive", content = string.format(s, ...), timeout = 3, level = "info" })
end

-- ---- State Helpers ----
-- Config is stored under "__config" to avoid collisions with archive temp names.

local set_state = ya.sync(function(state, archive, key, value)
	if not state[archive] then
		state[archive] = {}
	end
	state[archive][key] = value
end)

local get_state = ya.sync(function(state, archive, key)
	if state[archive] then
		return state[archive][key]
	end
	return nil
end)

local remove_state = ya.sync(function(state, archive)
	state[archive] = nil
	-- Also remove from __mounts tracking list
	if state["__mounts"] then
		local new_list = {}
		for _, k in ipairs(state["__mounts"]) do
			if k ~= archive then
				table.insert(new_list, k)
			end
		end
		state["__mounts"] = new_list
	end
end)

---Register an archive key in the __mounts tracking list
local register_mount = ya.sync(function(state, archive_key)
	if not state["__mounts"] then
		state["__mounts"] = {}
	end
	-- Avoid duplicates
	for _, k in ipairs(state["__mounts"]) do
		if k == archive_key then return end
	end
	table.insert(state["__mounts"], archive_key)
end)

---Collect all currently tracked mounted archives from state
---@return {key: string, name: string, cwd: string, tmp: string}[]
local get_mounted_archives = ya.sync(function(state)
	local mounts = {}
	local keys = state["__mounts"] or {}
	for _, key in ipairs(keys) do
		local val = state[key]
		if val and val.tmp then
			local archive_name = key:match("^(.+)%.tmp%.") or key
			table.insert(mounts, {
				key = key,
				name = archive_name,
				cwd = val.cwd or "",
				tmp = val.tmp or "",
			})
		end
	end
	return mounts
end)

-- ---- Pure Utility Functions ----

local function is_literal_string(str)
	return str and str:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

local function path_remove_trailing_slash(path)
	if path == "/" then
		return path
	end
	return (path:gsub("/$", ""))
end

-- ---- Sync Helpers (ya.sync) ----

local is_mount_point = ya.sync(function(state)
	local dir = cx.active.current.cwd.name
	local cwd = tostring(cx.active.current.cwd.path or cx.active.current.cwd)
	local mount_root_dir = get_state("__config", "mount_root_dir")
	local match_pattern = "^" .. is_literal_string(mount_root_dir .. "/yazi/fuse-archive") .. "/[^/]+%.tmp%.[^/]+$"

	for archive, _ in pairs(state) do
		if archive == dir and string.match(cwd, match_pattern) then
			return true
		end
	end
	return false
end)

---@return Url|nil, boolean|nil
local current_file = ya.sync(function()
	local h = cx.active.current.hovered
	if not h then
		return
	end
	return h.url, h.cha.is_dir
end)

local current_dir = ya.sync(function()
	return cx.active.current.cwd
end)

local current_dir_name = ya.sync(function()
	return cx.active.current.cwd.name
end)

---Check if any tab's cwd is inside a given mount path, and redirect them out
---@param mount_path string
---@param fallback_cwd string
local redirect_tabs_from_mount = ya.sync(function(_, mount_path, fallback_cwd)
	local found = false
	for _, tab in ipairs(cx.tabs) do
		local cwd = tostring(tab.current.cwd.path or tab.current.cwd)
		if cwd == mount_path or cwd:sub(1, #mount_path + 1) == mount_path .. "/" then
			found = true
			ya.emit("cd", {
				fallback_cwd,
				tab = (type(tab.id) == "number" or type(tab.id) == "string") and tab.id or tab.id.value,
				raw = true,
			})
		end
	end
	return found
end)

local function enter(hovered_url, is_dir)
	if hovered_url and is_dir then
		ya.emit("enter", {})
	else
		if get_state("__config", "smart_enter") then
			ya.emit("open", { hovered = true })
		else
			ya.emit("enter", {})
		end
	end
end

-- ---- Command Execution ----

---Run any command
---@param cmd string
---@param args string[]
---@param _stdin? STD_STREAM|nil
---@return integer|nil, Output|nil
local function run_command(cmd, args, _stdin)
	local cwd = current_dir()
	cwd = tostring(
		cwd.scheme and cwd.scheme.is_virtual and Url(cwd.scheme.cache .. tostring(cwd.path)).parent or cwd.path or cwd
	)

	local stdin = _stdin or Command.PIPED
	local child, cmd_err =
		Command(cmd):arg(args):cwd(cwd):stdin(stdin):stdout(Command.PIPED):stderr(Command.PIPED):spawn()

	if not child then
		notify_error("Failed to start `%s`: %s", cmd, cmd_err)
		return cmd_err, nil
	end

	local output, out_err = child:wait_with_output()
	if not output then
		notify_error("Cannot read `%s` output: %s", cmd, out_err)
		return out_err, nil
	else
		return nil, output
	end
end

local function is_mounted(dir_path)
	local cmd_err_code, res = run_command(shell, { "-c", "mountpoint -q " .. ya.quote(tostring(dir_path)) })
	if cmd_err_code or res == nil or res.status.code ~= 0 then
		return false
	end
	return res and res.status.success
end

---Get the fuse mount point
---@return string|nil
local function fuse_dir()
	local mount_root_dir = get_state("__config", "mount_root_dir")
	local fuse_mount_point = mount_root_dir .. "/yazi/fuse-archive"
	local _, _, exit_code = os.execute("mkdir -p " .. ya.quote(fuse_mount_point))
	if exit_code ~= 0 then
		notify_error("Cannot create mount point %s", fuse_mount_point)
		return
	end
	return fuse_mount_point
end

local function split_by_space_or_comma(input)
	local result = {}
	for word in string.gmatch(input, "[^%s,]+") do
		table.insert(result, word)
	end
	return result
end

--- return a string array with unique value
---@param tbl string[]
---@return string[] table with only unique strings
local function tbl_unique_strings(tbl)
	local unique_table = {}
	local seen = {}

	for _, str in ipairs(tbl) do
		if not seen[str] then
			seen[str] = true
			table.insert(unique_table, str)
		end
	end

	return unique_table
end

local function tbl_to_set(t1)
	local set = {}

	for _, v in ipairs(t1) do
		set[v] = true
	end

	return set
end

local function remove_from_set(set, t2)
	if not set then
		set = {}
	end
	for _, v in ipairs(t2) do
		set[v] = nil
	end
	return set
end

local function add_to_set(set, t2)
	if not set then
		set = {}
	end
	for _, v in ipairs(t2) do
		set[v] = true
	end
	return set
end

---
---@param tmp_file_name string tmp file name
---@return Url|nil
local function get_mount_url(tmp_file_name)
	local fuse_mount_point = get_state("__config", "fuse_dir")
	if not fuse_mount_point then
		return
	end
	return Url(fuse_mount_point):join(tmp_file_name)
end

-- ---- UI Helpers ----

---Show password input dialog
---@return boolean cancelled, string password
local function show_ask_pw_dialog()
	local passphrase = ""
	local cancelled = false
	local input_pw = ya.input({
		title = "Enter password to unlock:",
		obscure = true,
		pos = { "center", x = 0, y = 0, w = 50, h = 3 },
		position = { "center", x = 0, y = 0, w = 50, h = 3 },
		realtime = true,
	})

	while input_pw do
		---@type string, YA_INPUT_EVENT
		local value, ev = input_pw:recv()
		if ev == YA_INPUT_EVENT.CONFIRMED then
			passphrase = value or ""
			break
		elseif ev == YA_INPUT_EVENT.CANCELLED then
			passphrase = ""
			cancelled = true
			break
		end
	end
	return cancelled, passphrase
end

-- ---- Core Logic ----

local redirect_mounted_tab_to_home = ya.sync(function(state, _)
	local mount_root_dir = get_state("__config", "mount_root_dir")
	local match_pattern = "^" .. is_literal_string(mount_root_dir .. "/yazi/fuse-archive") .. "/[^/]+%.tmp%.[^/]+$"
	local HOME = os.getenv("HOME")

	for _, tab in ipairs(cx.tabs) do
		local dir = tab.current.cwd.name
		local cwd = tostring(tab.current.cwd)

		for archive, _ in pairs(state) do
			if archive == dir and string.match(cwd, match_pattern) then
				ya.emit("cd", {
					HOME,
					tab = (type(tab.id) == "number" or type(tab.id) == "string") and tab.id or tab.id.value,
					raw = true,
				})
				goto continue
			end
		end
		::continue::
	end
end)

---Execute fuse-archive and return exit code + stderr
---@param archive_path Url
---@param fuse_mount_point Url
---@param mount_opts string[]
---@param passphrase? string
---@return integer|nil code, string|nil stderr_msg
local function run_fuse_archive(archive_path, fuse_mount_point, mount_opts, passphrase)
	local res, _ = Command(shell)
		:arg({
			"-c",
			(passphrase and "printf '%s\n' " .. ya.quote(passphrase) .. " | " or "")
				.. "fuse-archive -o "
				.. table.concat(mount_opts, ",")
				.. " "
				.. ya.quote(tostring(archive_path))
				.. " "
				.. ya.quote(tostring(fuse_mount_point)),
		})
		:stderr(Command.PIPED)
		:stdout(Command.PIPED)
		:output()

	if not res then
		return nil, nil
	end
	return res.status.code, res.stderr
end

---Handle ARCHIVE_READ_PERMISSION_INVALID with specific sub-errors
---@param archive_path Url
---@param stderr_msg string|nil
---@return boolean handled -- true if a specific error was detected and reported
local function handle_read_permission_error(archive_path, stderr_msg)
	if archive_path.ext == "rar" and stderr_msg
		and stderr_msg:find("encrypted data is not currently supported", 1, true) then
		notify_error("Password-protected RAR file is not supported yet!")
		return true
	elseif stderr_msg and stderr_msg:find("Unspecified error", 1, true) then
		notify_error("Cannot mount archive file: Unspecified error")
		return true
	end
	return false
end

---Mount fuse archive with retry loop for password-protected files
---@param opts {archive_path: Url, fuse_mount_point: Url, mount_options: string[], passphrase?: string, max_retry?: integer}
---@return boolean
local function mount_fuse(opts)
	local archive_path = opts.archive_path
	local fuse_mount_point = opts.fuse_mount_point
	local mount_options = opts.mount_options or {}
	local passphrase = opts.passphrase
	local max_retry = opts.max_retry or 3
	local retries = 0

	if is_mounted(fuse_mount_point) then
		return true
	end

	local mount_opts = tbl_unique_strings({ "auto_unmount", table.unpack(mount_options) })

	while retries <= max_retry do
		local code, stderr_msg = run_fuse_archive(archive_path, fuse_mount_point, mount_opts, passphrase)

		-- Already mounted
		if stderr_msg and stderr_msg:find("mountpoint is not empty") then
			return true
		end

		if code == FUSE_ARCHIVE_RETURN_CODE.SUCCESS then
			return true
		end

		-- Cache errors: retry with nocache
		if code == FUSE_ARCHIVE_RETURN_CODE.NOT_ENOUGH_TEMP_SPACE
			or code == FUSE_ARCHIVE_RETURN_CODE.CREATE_CACHE_FILE_FAILED then
			notify_info(FUSE_ARCHIVE_MOUNT_ERROR_MSG[code])
			table.insert(mount_opts, "nocache")
			mount_opts = tbl_unique_strings(mount_opts)
			-- One retry with nocache, not a password retry
			local retry_code, retry_msg = run_fuse_archive(archive_path, fuse_mount_point, mount_opts, passphrase)
			if retry_code == FUSE_ARCHIVE_RETURN_CODE.SUCCESS then
				return true
			elseif retry_msg and retry_msg:find("mountpoint is not empty") then
				return true
			end
			notify_error("Mount failed even with nocache disabled")
			return false
		end

		-- Password required or wrong password: prompt user
		if code == FUSE_ARCHIVE_RETURN_CODE.ENCRYPTED_FILE_BUT_NOT_PASSWORD
			or code == FUSE_ARCHIVE_RETURN_CODE.ENCRYPTED_FILE_BUT_WRONG_PASSWORD then
			if retries >= max_retry then
				notify_error("Too many incorrect password attempts")
				return false
			end
			local remaining = max_retry - retries
			if retries == 0 then
				notify_info(FUSE_ARCHIVE_MOUNT_ERROR_MSG[code], remaining)
			else
				notify_error(FUSE_ARCHIVE_MOUNT_ERROR_MSG[code], remaining)
			end
			local cancelled, pw = show_ask_pw_dialog()
			if cancelled then
				return false
			end
			passphrase = pw
			retries = retries + 1
			-- continue loop for next attempt
		else
			-- All other errors: report and bail
			if code == FUSE_ARCHIVE_RETURN_CODE.ARCHIVE_READ_PERMISSION_INVALID then
				if handle_read_permission_error(archive_path, stderr_msg) then
					return false
				end
			end
			local msg = FUSE_ARCHIVE_MOUNT_ERROR_MSG[code]
			if msg then
				if code == FUSE_ARCHIVE_RETURN_CODE.ERROR_GENERIC then
					notify_error(msg, code)
				elseif code == FUSE_ARCHIVE_RETURN_CODE.CREATE_MOUNT_POINT_FAILED then
					notify_error(msg, tostring(fuse_mount_point))
				else
					notify_error(msg)
				end
			end
			return false
		end
	end

	return false
end

---Mount path using inode (unique for each files)
---@param file_url Url
---@return string|nil
local function tmp_file_name(file_url)
	local fname = file_url.name
	local cmd_err_code, res = run_command(shell, { "-c", "xxh128sum -q " .. ya.quote(tostring(file_url)) })
	if cmd_err_code or res == nil or res.status.code ~= 0 then
		notify_error("Cannot create unique path of file %s", fname)
		return nil
	end
	local hashed_name = res.stdout:match("^(%S+)")
	return fname .. ".tmp." .. hashed_name
end

local function unmount_on_quit()
	redirect_mounted_tab_to_home()
	local mount_root_dir = get_state("__config", "mount_root_dir")
	local unmount_script =
		ya.quote(os.getenv("HOME") .. "/.config/yazi/plugins/fuse-archive.yazi/assets/unmount_on_quit.sh")
	os.execute("chmod +x " .. unmount_script)
	os.execute(unmount_script .. " " .. ya.quote(tostring(mount_root_dir)))
end

---Unmount a single fuse-archive mount point and clean up state
---@param mount_entry {key: string, name: string, cwd: string, tmp: string}
---@return boolean success
local function unmount_single(mount_entry)
	if not mount_entry or not mount_entry.tmp or mount_entry.tmp == "" then
		return false
	end
	-- Redirect ALL tabs that are inside this mount point
	local dest = mount_entry.cwd ~= "" and mount_entry.cwd or os.getenv("HOME") or "/"
	redirect_tabs_from_mount(mount_entry.tmp, dest)

	local quoted = ya.quote(mount_entry.tmp)
	-- Try normal unmount first
	local _, _, code = os.execute("fusermount -u " .. quoted .. " 2>/dev/null")
	if code ~= 0 then
		-- Lazy unmount as fallback — detaches immediately, cleans up when no longer busy
		_, _, code = os.execute("fusermount -uz " .. quoted .. " 2>/dev/null")
		if code ~= 0 then
			_, _, code = os.execute("umount -l " .. quoted .. " 2>/dev/null")
			if code ~= 0 then
				notify_error("Failed to unmount %s", mount_entry.name)
				return false
			end
		end
	end
	remove_state(mount_entry.key)
	notify_info("Unmounted %s", mount_entry.name)
	return true
end

-- ---- Menu ----

---Generate key labels for menu items: 1-9, then a-z
local function menu_key(i)
	if i <= 9 then return tostring(i) end
	local c = i - 9
	if c <= 26 then return string.char(96 + c) end -- a-z
	return tostring(i)
end

---Show a picker sub-menu for mounted archives, returns selected entry or nil
---@param mounts {key: string, name: string, cwd: string, tmp: string}[]
---@param title string
---@return {key: string, name: string, cwd: string, tmp: string}|nil
local function pick_archive(mounts, title)
	if #mounts == 0 then
		notify_info("No archives are currently mounted")
		return nil
	end

	local cands = {}
	for i, m in ipairs(mounts) do
		table.insert(cands, { on = menu_key(i), desc = title .. ": " .. m.name })
	end
	local idx = ya.which({ cands = cands })
	if not idx or idx > #mounts then
		return nil
	end
	return mounts[idx]
end

---Show the main fuse-archive menu
local function show_menu()
	local idx = ya.which({
		cands = {
			{ on = "u", desc = "Unmount an archive" },
			{ on = "U", desc = "Unmount all archives" },
		},
	})

	if not idx then return end

	local mounts = get_mounted_archives()

	-- Unmount one
	if idx == 1 then
		local entry = pick_archive(mounts, "Unmount")
		if entry then
			unmount_single(entry)
		end

	-- Unmount all
	elseif idx == 2 then
		if #mounts == 0 then
			notify_info("No archives are currently mounted")
			return
		end
		local yes = ya.confirm({
			pos = { "center", w = 50, h = 8 },
			title = "Unmount all archives?",
			content = string.format("This will unmount %d archive(s).", #mounts),
		})
		if yes then
			unmount_on_quit()
			notify_info("Unmounted all archives")
		end
	end
end

-- ---- Setup & Entry ----

local function setup(_, opts)
	set_state(
		"__config",
		"mount_root_dir",
		opts
				and opts.mount_root_dir
				and type(opts.mount_root_dir) == "string"
				and path_remove_trailing_slash(opts.mount_root_dir)
			or "/tmp"
	)
	local fuse = fuse_dir()
	set_state("__config", "fuse_dir", fuse)
	set_state("__config", "smart_enter", opts and opts.smart_enter)
	local mount_options = {}
	if opts and opts.mount_options then
		if type(opts.mount_options) == "string" then
			mount_options = split_by_space_or_comma(opts.mount_options)
		else
			notify_error("mount_options option in setup() must be a string separated by space or comma")
		end
	end
	set_state("__config", "mount_options", mount_options)

	-- stylua: ignore
	local ORIGINAL_SUPPORTED_EXTENSIONS = {
		"7z",       "7zip",     "a",        "aia",      "apk",
		"ar",       "b64",      "base64",   "br",       "brotli",
		"bz2",      "bzip2",    "cab",      "cpio",     "crx",
		"deb",      "docx",     "grz",      "grzip",    "gz",
		"gzip",     "iso",      "iso9660",  "jar",      "lha",
		"lrz",      "lrzip",    "lz",       "lz4",      "lzip",
		"lzma",     "lzo",      "lzop",     "mtree",    "odf",
		"odg",      "odp",      "ods",      "odt",      "ppsx",
		"pptx",     "rar",      "rpm",      "tar",      "tar.br",
		"tar.brotli","tar.bz2", "tar.bzip2","tar.grz",  "tar.grzip",
		"tar.gz",   "tar.gzip", "tar.lha",  "tar.lrz",  "tar.lrzip",
		"tar.lz",   "tar.lz4",  "tar.lzip", "tar.lzma", "tar.lzo",
		"tar.lzop", "tar.xz",   "tar.z",    "tar.zst",  "tar.zstd",
		"taz",      "tb2",      "tbr",      "tbz",      "tbz2",
		"tgz",      "tlz",      "tlz4",     "tlzip",    "tlzma",
		"txz",      "tz",       "tz2",      "tzs",      "tzst",
		"tzstd",    "uu",       "warc",     "xar",      "xlsx",
		"xz",       "z",        "zip",      "zipx",     "zst",
		"zstd",
	}

	local SET_ALLOWED_EXTENSIONS = tbl_to_set(ORIGINAL_SUPPORTED_EXTENSIONS)

	if opts and opts.extra_extensions then
		if type(opts.extra_extensions) == "table" then
			SET_ALLOWED_EXTENSIONS = add_to_set(SET_ALLOWED_EXTENSIONS, opts.extra_extensions)
		else
			notify_error("extra_extensions option in setup() must be a table of string")
		end
	end

	if opts and opts.excluded_extensions then
		if type(opts.excluded_extensions) == "table" then
			SET_ALLOWED_EXTENSIONS = remove_from_set(SET_ALLOWED_EXTENSIONS, opts.excluded_extensions)
		else
			notify_error("excluded_extensions option in setup() must be a table of string")
		end
	end
	set_state("__config", "valid_extensions", SET_ALLOWED_EXTENSIONS)

	-- trigger unmount on quit
	ps.sub("key-quit", function(args)
		unmount_on_quit()
		return args
	end)
	ps.sub("emit-quit", function(args)
		unmount_on_quit()
		return args
	end)
	ps.sub("emit-ind-quit", function(args)
		unmount_on_quit()
		return args
	end)
end

local unsub_download = ya.sync(function()
	ps.unsub("download")
end)

local sub_download = ya.sync(function(_, url)
	unsub_download()
	ps.sub("download", function(body)
		if not body or not body.urls or #body.urls == 0 then
			return
		end
		for _, u in ipairs(body.urls) do
			if tostring(u) == tostring(url) then
				ya.emit("plugin", { "fuse-archive", "mount" .. " --url=" .. ya.quote(tostring(u)) })
				unsub_download()
			end
		end
	end)
end)

return {
	entry = function(_, job)
		local action = job.args[1]
		if not action then
			return
		end

		unsub_download()
		if action == "mount" then
			local hovered_url, is_dir = job.args.url and Url(job.args.url), false
			if not hovered_url then
				hovered_url, is_dir = current_file()
			end
			if hovered_url == nil then
				return
			end
			local VALID_EXTENSIONS = get_state("__config", "valid_extensions")
			if is_dir or is_dir == nil or (is_dir == false and not VALID_EXTENSIONS[hovered_url.ext]) then
				enter(hovered_url, is_dir)
				return
			end
			local is_virtual = hovered_url.scheme and hovered_url.scheme.is_virtual
			local hovered_url_cached = is_virtual and Url(hovered_url.scheme.cache .. tostring(hovered_url.path))
				or hovered_url.path
				or hovered_url
			if is_virtual and not fs.cha(hovered_url_cached) then
				sub_download(tostring(hovered_url), job)
				ya.emit("download", { tostring(hovered_url) })
				return
			end
			local tmp_fname = tmp_file_name(hovered_url_cached)
			if not tmp_fname then
				return
			end
			local tmp_file_url = get_mount_url(tmp_fname)

			if tmp_file_url then
				local success = mount_fuse({
					archive_path = hovered_url_cached,
					fuse_mount_point = tmp_file_url,
					mount_options = get_state("__config", "mount_options"),
				})
				if success then
					local cwd = current_dir()
					set_state(tmp_fname, "cwd", tostring(cwd))
					set_state(tmp_fname, "tmp", tostring(tmp_file_url))
					register_mount(tmp_fname)
					ya.emit("cd", { tostring(tmp_file_url), raw = true })
				end
			end
			-- leave without unmount
		elseif action == "leave" then
			if not is_mount_point() then
				ya.emit("leave", {})
				return
			end
			local file = current_dir_name()
			ya.emit("cd", { get_state(file, "cwd"), raw = true })
			return
		elseif action == "unmount" then
			unmount_on_quit()
		elseif action == "menu" then
			show_menu()
		elseif action == "jump" then
			local mounts = get_mounted_archives()
			local entry = pick_archive(mounts, "Jump to")
			if entry then
				ya.emit("cd", { entry.tmp, raw = true })
			end
		elseif action == "select-then-unmount" then
			local mounts = get_mounted_archives()
			local entry = pick_archive(mounts, "Unmount")
			if entry then
				unmount_single(entry)
			end
		elseif action == "unmount-all" then
			unmount_on_quit()
			notify_info("Unmounted all archives")
		end
	end,
	setup = setup,
}
