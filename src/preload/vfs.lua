-- preload/vfs.lua
-- luacheck: globals vfs
-- User-facing VFS convenience namespace (vfs.*)

if type(sys) ~= "table" or type(sys.vfs) ~= "table" then
	return
end

vfs = {}

local function vfs_validation_err(message, context)
	return {
		code = "VALIDATION_FAILED",
		message = message,
		context = context or {},
		recoverable = false,
		suggestion = "Check the parameter values and retry",
	}
end

vfs.__schema = {
	namespace = "vfs",
	service = "core",
	description = "Runtime-local virtual filesystem for scratch storage. Exposing files as host-visible copies requires guarded mode.",
	usage_hint = "Use VFS-relative paths for scratch storage. Use guarded vfs.expose() for host-visible temporary copies.",
	types = {
		FileInfo = { shape = "{path:string, size:number, is_dir:boolean}" },
		ToTextResult = { shape = "{kind:string, extracted_dir:string, summary:string, files:table}" },
		ExposedFile = { shape = "{original_vfs_path:string, host_path:string, size:number, mime?:string}" },
		ExposeResult = { shape = "{files:ExposedFile[]}" },
	},
	functions = {
		{
			name = "mkdirp",
			signature = "(path)",
			returns_contract = "core.result",
			guarded = false,
			description = "Create a directory and its parents in VFS",
			params = { { name = "path", type = "string" } },
			returns_typed = { { name = "result", type = "boolean" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "remove",
			signature = "(path)",
			returns_contract = "core.result",
			guarded = false,
			description = "Remove a VFS file or directory tree to reclaim runtime quota",
			params = { { name = "path", type = "string" } },
			returns_typed = { { name = "removed", type = "boolean" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "write_text",
			signature = "(path, text, opts?)",
			returns_contract = "core.result",
			guarded = false,
			description = "Write text to a VFS file, creating parent directories as needed. Overwrite defaults to true.",
			params = {
				{ name = "path", type = "string" },
				{ name = "text", type = "string" },
				{ name = "opts", type = "table", optional = true, description = "Options: {overwrite?: boolean}" },
			},
			returns_typed = { { name = "info", type = "FileInfo" }, { name = "err", type = "core.error|nil" } },
			examples = [[
-- Write a text file
local info, err = vfs.write_text("output/report.txt", "Hello, world!")
if err then error(err.message) end
print("Wrote", info.size, "bytes to", info.path)
]],
		},
		{
			name = "read_text",
			signature = "(path, opts?)",
			returns_contract = "core.result",
			guarded = false,
			description = "Read text content from a VFS file. Options: max_bytes, offset",
			params = {
				{ name = "path", type = "string" },
				{ name = "opts", type = "table", optional = true, description = "Options: {max_bytes?: number, offset?: number}" },
			},
			returns_typed = { { name = "text", type = "string" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "ls",
			signature = "(path, opts?)",
			returns_contract = "core.result",
			guarded = false,
			description = "List VFS directory entries. Options: recursive, max_entries",
			params = {
				{ name = "path", type = "string" },
				{ name = "opts", type = "table", optional = true, description = "Options: {recursive?: boolean, max_entries?: number}" },
			},
			returns_typed = { { name = "entries", type = "table" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "stat",
			signature = "(path)",
			returns_contract = "core.result",
			guarded = false,
			description = "Get file/directory info from VFS",
			params = { { name = "path", type = "string" } },
			returns_typed = { { name = "info", type = "FileInfo" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "expose",
			signature = "(paths)",
			returns_contract = "core.result",
			guarded = true,
			description = "Copy one or more VFS files into a fresh OS temp exposure bundle and return host-visible paths for agent inspection. Input must be an array of VFS file paths.",
			params = {
				{ name = "paths", type = "table", optional = false, description = "Array of VFS file paths to expose" },
			},
			returns_typed = { { name = "result", type = "ExposeResult" }, { name = "err", type = "core.error|nil" } },
			examples = [[
-- Expose a downloaded archive for agent inspection (requires guarded mode)
local res, err = download_archive()
if err then error(err.message) end

local exposed, err2 = vfs.expose({res.file})
if err2 then error(err2.message) end
print("Exposed:", exposed.files[1].host_path)
]],
		},
		{
			name = "to_txt",
			signature = "(path, opts?)",
			returns_contract = "core.result",
			guarded = false,
			description = "Convert a binary file to text representation (zip extraction + previews). Returns summary, file list, and text previews.",
			params = {
				{ name = "path", type = "string" },
				{ name = "opts", type = "table", optional = true, description = "Options: {extract_dir?: string, max_files?: number, preview_bytes_per_file?: number, total_preview_bytes?: number, text_extensions?: string[]}" },
			},
			returns_typed = { { name = "result", type = "ToTextResult" }, { name = "err", type = "core.error|nil" } },
			examples = [[
-- Extract and inspect a zip file
local result, err = vfs.to_txt("artifacts/job-456.zip")
if err then error(err.message) end

print(result.summary)
print("Extracted to:", result.extracted_dir)
for _, f in ipairs(result.files) do
  print(f.path, f.bytes, "bytes")
  if f.preview then
    print("  Preview:", f.preview:sub(1, 100))
  end
end
]],
		},
	},
}

-- vfs.mkdirp(path) -> (true|nil, err)
function vfs.mkdirp(path)
	return sys.vfs.mkdirp(path)
end

-- vfs.remove(path) -> (removed|nil, err)
function vfs.remove(path)
	return sys.vfs.remove(path)
end

-- vfs.write_text(path, text, opts?) -> (info|nil, err)
function vfs.write_text(path, text, opts)
	return sys.vfs.write_text(path, text, opts)
end

-- vfs.read_text(path, opts?) -> (text|nil, err)
function vfs.read_text(path, opts)
	return sys.vfs.read_text(path, opts)
end

-- vfs.ls(path, opts?) -> (entries|nil, err)
function vfs.ls(path, opts)
	return sys.vfs.list(path, opts)
end

-- vfs.stat(path) -> (info|nil, err)
function vfs.stat(path)
	return sys.vfs.stat(path)
end

-- vfs.expose(paths) -> (result|nil, err)
function vfs.expose(paths)
	if type(paths) ~= "table" then
		return nil, vfs_validation_err("vfs.expose requires an array of VFS file paths", { paths_type = type(paths) })
	end
	return sys.vfs.expose(paths)
end

-- vfs.to_txt(path, opts?) -> (result|nil, err)
function vfs.to_txt(path, opts)
	return sys.vfs.to_text(path, opts)
end
