local config = require("supertab.config")
local log = require("supertab.logger")

local uv = vim.uv or vim.loop

local M = {}

local context_cache = {}
local refresh_jobs = {}

local function get_ts_config()
  local api_conf = config.api
  if not api_conf then
    return nil
  end
  local context_conf = api_conf.context
  if not context_conf then
    return nil
  end
  return context_conf.treesitter
end

local function normalize_location_range(location)
  if type(location) ~= "table" then
    return nil
  end
  local range = location.targetRange or location.targetSelectionRange or location.range
  if not range or not range.start or not range["end"] then
    return nil
  end
  local start_line = range.start.line or 0
  local end_line = range["end"].line or start_line
  if end_line <= start_line then
    end_line = start_line + 1
  end
  return {
    start_line = start_line,
    end_line = end_line,
  }
end

local function trim(s)
  return (s and s:match("^%s*(.-)%s*$")) or s
end

local function join_paths(...)
  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end
  local parts = { ... }
  local path = parts[1] or ""
  for i = 2, #parts do
    local part = parts[i]
    if part ~= nil and part ~= "" then
      if path == "" or path:sub(-1) == "/" then
        path = path .. part
      else
        path = path .. "/" .. part
      end
    end
  end
  return path
end

local function dirname(path)
  if vim.fs and vim.fs.dirname then
    return vim.fs.dirname(path)
  end
  return path:match("^(.*)/[^/]*$") or "."
end

local function normalize(path)
  if vim.fs and vim.fs.normalize then
    return vim.fs.normalize(path)
  end
  return path
end

local function starts_with(str, prefix)
  return str:sub(1, #prefix) == prefix
end

local function find_import_position(bufnr, specifier)
  if not bufnr or not specifier or specifier == "" then
    return nil
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if not ok or not lines then
    return nil
  end
  for idx, line in ipairs(lines) do
    local col = line:find(specifier, 1, true)
    if col then
      return idx - 1, col - 1
    end
  end
  return nil
end

local function cache_key_for_path(path)
  if not path or path == "" then
    return ""
  end
  return normalize(path)
end

local function get_cached_context(path, changedtick)
  local key = cache_key_for_path(path)
  if key == "" then
    return nil
  end
  local entry = context_cache[key]
  if not entry then
    return nil
  end
  if changedtick and entry.changedtick ~= changedtick then
    log:debug(string.format(
      "[treesitter] Returning cached context for %s from tick %d (current tick %d)",
      path,
      entry.changedtick or -1,
      changedtick
    ))
  end
  return entry.context
end

local function update_cache(path, changedtick, context)
  local key = cache_key_for_path(path)
  if key == "" then
    return
  end
  context_cache[key] = {
    changedtick = changedtick,
    context = context,
    timestamp = uv.now(),
  }
end

local function clear_job(path)
  local key = cache_key_for_path(path)
  refresh_jobs[key] = nil
end

local LANGUAGE_MAP = {
  ts = "typescript",
  tsx = "tsx",
  js = "javascript",
  mjs = "javascript",
  cjs = "javascript",
  jsx = "javascriptreact",
  lua = "lua",
  py = "python",
  go = "go",
}

local function ts_available()
  return vim.treesitter ~= nil and vim.treesitter.get_parser ~= nil
end

local function normalize_client_list(raw)
  if not raw then
    return {}
  end
  if vim.tbl_islist and vim.tbl_islist(raw) then
    return raw
  end
  local list = {}
  for _, client in pairs(raw) do
    table.insert(list, client)
  end
  return list
end

local function get_lsp_clients(bufnr)
  if vim.lsp == nil then
    return {}
  end
  local raw = nil
  if vim.lsp.get_clients then
    raw = vim.lsp.get_clients({ bufnr = bufnr })
  elseif vim.lsp.get_active_clients then
    raw = vim.lsp.get_active_clients({ bufnr = bufnr })
  end
  return normalize_client_list(raw)
end

local function iter_lsp_locations(result, cb)
  if not result or not cb then
    return
  end

  local function handle(location)
    if type(location) ~= "table" then
      return
    end
    cb(location)
  end

  if vim.tbl_islist and vim.tbl_islist(result) then
    for _, loc in ipairs(result) do
      handle(loc)
    end
  elseif type(result) == "table" then
    handle(result)
  end
end

local function get_language_from_path(path)
  if not path or path == "" then
    return nil
  end
  local ext = path:match("%.([^%.]+)$")
  if not ext then
    return nil
  end
  return LANGUAGE_MAP[ext] or ext
end

function M.is_enabled()
  local ts_conf = get_ts_config()
  if not ts_conf or ts_conf.enabled == false then
    return false
  end
  if not ts_available() then
    return false
  end
  return true
end

local function read_file(path, max_lines)
  local ok, fd = pcall(io.open, path, "r")
  if not ok or not fd then
    return nil
  end

  local lines = {}
  local count = 0
  for line in fd:lines() do
    count = count + 1
    table.insert(lines, line)
    if max_lines and max_lines > 0 and count >= max_lines then
      table.insert(lines, "... (truncated)")
      break
    end
  end

  fd:close()

  if #lines == 0 then
    return nil
  end

  return table.concat(lines, "\n")
end

local function read_entire_file(path)
  local ok, fd = pcall(io.open, path, "r")
  if not ok or not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  return content
end

local function extract_file_segments(path, ranges, max_lines)
  if not ranges or #ranges == 0 then
    return read_file(path, max_lines)
  end

  local content = read_entire_file(path)
  if not content then
    return nil
  end

  local lines = vim.split(content, "\n", { plain = true })
  table.sort(ranges, function(a, b)
    if a.start_line == b.start_line then
      return a.end_line < b.end_line
    end
    return a.start_line < b.start_line
  end)

  local pieces = {}
  local total_lines = 0

  for _, range in ipairs(ranges) do
    if max_lines > 0 and total_lines >= max_lines then
      break
    end

    local start_idx = math.max(1, (range.start_line or 0) + 1)
    local end_exclusive = (range.end_line or (range.start_line or 0) + 1)
    if end_exclusive <= (range.start_line or 0) then
      end_exclusive = (range.start_line or 0) + 1
    end
    local end_idx = math.min(#lines, math.max(start_idx, end_exclusive))

    if start_idx > #lines then
      goto continue_range
    end

    local segment = {}
    table.insert(segment, string.format("[lines %d-%d]", start_idx, end_idx))
    for i = start_idx, end_idx do
      table.insert(segment, lines[i])
      total_lines = total_lines + 1
      if max_lines > 0 and total_lines >= max_lines then
        break
      end
    end

    table.insert(pieces, table.concat(segment, "\n"))

    if max_lines > 0 and total_lines >= max_lines then
      break
    end

    ::continue_range::
  end

  if #pieces == 0 then
    return nil
  end

  local combined = table.concat(pieces, "\n\n")
  if max_lines > 0 and total_lines >= max_lines then
    combined = combined .. "\n... (truncated)"
  end
  return combined
end

local function indent_block(text, prefix)
  if not text or text == "" then
    return nil
  end
  local lines = vim.split(text, "\n", { plain = true })
  local indentation = prefix or "  "
  for i, line in ipairs(lines) do
    lines[i] = indentation .. line
  end
  return table.concat(lines, "\n")
end

local function file_exists(path)
  if not path or path == "" then
    return false
  end
  local stat = uv.fs_stat(path)
  return stat and stat.type == "file"
end

local function find_upwards_tsconfig(start_dir)
  if not start_dir or start_dir == "" then
    return nil
  end

  local current = normalize(start_dir)
  local processed = {}
  while current and current ~= "" and not processed[current] do
    processed[current] = true
    for _, name in ipairs({ "tsconfig.json", "jsconfig.json" }) do
      local candidate = normalize(join_paths(current, name))
      if file_exists(candidate) then
        return candidate
      end
    end
    local parent = dirname(current)
    if not parent or parent == "" or parent == current then
      break
    end
    current = parent
  end

  return nil
end

local function decode_json(text)
  if not text or text == "" then
    return nil
  end
  if vim.json and vim.json.decode then
    local ok, result = pcall(vim.json.decode, text)
    if ok then
      return result
    end
  end
  if vim.fn and vim.fn.json_decode then
    local ok, result = pcall(vim.fn.json_decode, text)
    if ok then
      return result
    end
  end
  return nil
end

local function escape_lua_pattern(s)
  return (s:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1"))
end

local function pattern_to_regex(pattern)
  if not pattern or pattern == "" then
    return nil, 0
  end
  local escaped = escape_lua_pattern(pattern)
  local capture_count = 0
  local regex = "^" .. escaped:gsub("%*", function()
    capture_count = capture_count + 1
    return "(.*)"
  end) .. "$"
  return regex, capture_count
end

local function apply_wildcards(target, captures)
  if not target or target == "" then
    return target
  end
  local index = 0
  return target:gsub("%*", function()
    index = index + 1
    return captures[index] or ""
  end)
end

local function build_tsconfig_alias_resolver(tsconfig_path, data)
  if type(data) ~= "table" then
    return nil
  end

  local compiler = data.compilerOptions
  if type(compiler) ~= "table" then
    return nil
  end

  local paths = compiler.paths
  if type(paths) ~= "table" then
    return nil
  end

  local base_dir = dirname(tsconfig_path)
  local base_root = base_dir
  local base_url = compiler.baseUrl
  if type(base_url) == "string" and base_url ~= "" then
    if starts_with(base_url, "/") then
      base_root = normalize(base_url)
    else
      base_root = normalize(join_paths(base_dir, base_url))
    end
  end

  local entries = {}
  for pattern, targets in pairs(paths) do
    if type(pattern) == "string" and type(targets) == "table" and #targets > 0 then
      local regex, capture_count = pattern_to_regex(pattern)
      if regex then
        table.insert(entries, {
          pattern = pattern,
          regex = regex,
          capture_count = capture_count,
          targets = targets,
        })
      end
    end
  end

  if #entries == 0 then
    return nil
  end

  local function match_entry(entry, specifier)
    if entry.capture_count == 0 then
      if specifier:match(entry.regex) then
        return {}
      end
      return nil
    end

    local captures = { specifier:match(entry.regex) }
    if #captures == entry.capture_count then
      return captures
    end
    return nil
  end

  local function make_candidate(target, captures)
    local resolved = target
    if captures and #captures > 0 then
      resolved = apply_wildcards(target, captures)
    end

    if starts_with(resolved, "/") then
      return normalize(resolved)
    end

    return normalize(join_paths(base_root, resolved))
  end

  return function(specifier)
    if not specifier or specifier == "" then
      return nil
    end

    local candidates = {}
    for _, entry in ipairs(entries) do
      local captures = match_entry(entry, specifier)
      if captures then
        for _, target in ipairs(entry.targets) do
          if type(target) == "string" and target ~= "" then
            table.insert(candidates, make_candidate(target, captures))
          end
        end
      end
    end

    if #candidates == 0 then
      return nil
    end
    return candidates
  end
end

local tsconfig_cache = {}

local function get_tsconfig_alias_resolver(file_path)
  if not file_path or file_path == "" then
    return nil
  end

  local base_dir = dirname(file_path)
  local tsconfig_path = find_upwards_tsconfig(base_dir)
  if not tsconfig_path then
    return nil
  end

  local stat = uv.fs_stat(tsconfig_path)
  if not stat then
    return nil
  end

  local mtime = stat.mtime
  local mtime_sec = mtime and (mtime.sec or mtime) or 0
  local cache_entry = tsconfig_cache[tsconfig_path]
  if cache_entry and cache_entry.mtime == mtime_sec then
    return cache_entry.resolver
  end

  local content = read_entire_file(tsconfig_path)
  if not content then
    tsconfig_cache[tsconfig_path] = { mtime = mtime_sec, resolver = nil }
    return nil
  end

  local data = decode_json(content)
  if not data then
    tsconfig_cache[tsconfig_path] = { mtime = mtime_sec, resolver = nil }
    return nil
  end

  local resolver = build_tsconfig_alias_resolver(tsconfig_path, data)
  tsconfig_cache[tsconfig_path] = { mtime = mtime_sec, resolver = resolver }
  return resolver
end

local DEFAULT_EXTENSIONS = {
  ".ts",
  ".tsx",
  ".js",
  ".jsx",
  ".mjs",
  ".cjs",
  ".d.ts",
  ".lua",
  ".py",
  ".go",
}

local INDEX_FILES = {
  "index.ts",
  "index.tsx",
  "index.js",
  "index.jsx",
  "index.d.ts",
  "init.lua",
  "__init__.py",
  "mod.go",
}

local node_modules_cache = {}
local package_metadata_cache = {}

local function get_node_modules_dir(start_dir)
  if not start_dir or start_dir == "" then
    return nil
  end

  local normalized_start = normalize(start_dir)
  local cached = node_modules_cache[normalized_start]
  if cached ~= nil then
    if cached == false then
      return nil
    end
    return cached
  end

  local seen = {}
  local current = normalized_start
  while current and current ~= "" and not seen[current] do
    seen[current] = true
    local candidate = normalize(join_paths(current, "node_modules"))
    local stat = uv.fs_stat(candidate)
    if stat and stat.type == "directory" then
      node_modules_cache[normalized_start] = candidate
      return candidate
    end
    local parent = dirname(current)
    if not parent or parent == "" or parent == current then
      break
    end
    current = parent
  end

  node_modules_cache[normalized_start] = false
  return nil
end

local function split_module_specifier(specifier)
  if not specifier or specifier == "" then
    return nil, nil
  end

  if starts_with(specifier, "@") then
    local scope, rest = specifier:match("^(@[^/]+/[^/]+)(/?(.*))$")
    if not scope then
      return nil, nil
    end
    local subpath = rest or ""
    if starts_with(subpath, "/") then
      subpath = subpath:sub(2)
    end
    return scope, subpath
  end

  local name, rest = specifier:match("^([^/]+)(/?(.*))$")
  if not name then
    return nil, nil
  end
  local subpath = rest or ""
  if starts_with(subpath, "/") then
    subpath = subpath:sub(2)
  end
  return name, subpath
end

local function get_package_metadata(module_root)
  if not module_root or module_root == "" then
    return nil
  end

  local package_json_path = normalize(join_paths(module_root, "package.json"))
  local stat = uv.fs_stat(package_json_path)
  if not stat then
    return nil
  end
  local mtime = stat.mtime
  local mtime_sec = mtime and (mtime.sec or mtime) or 0

  local cached = package_metadata_cache[package_json_path]
  if cached and cached.mtime == mtime_sec then
    return cached.data
  end

  local content = read_entire_file(package_json_path)
  if not content then
    package_metadata_cache[package_json_path] = { mtime = mtime_sec, data = nil }
    return nil
  end

  local data = decode_json(content)
  package_metadata_cache[package_json_path] = { mtime = mtime_sec, data = data }
  return data
end

local function gather_package_entry_candidates(metadata)
  local candidates = {}
  if type(metadata) ~= "table" then
    return candidates
  end

  local function add_entry(value)
    if type(value) ~= "string" or value == "" then
      return
    end
    local cleaned = value
    if starts_with(cleaned, "./") then
      cleaned = cleaned:sub(3)
    elseif starts_with(cleaned, ".\\") then
      cleaned = cleaned:sub(4)
    end
    if cleaned == "" then
      return
    end
    table.insert(candidates, cleaned)
  end

  if type(metadata.exports) == "string" then
    add_entry(metadata.exports)
  elseif type(metadata.exports) == "table" then
    local dot_export = metadata.exports["."]
    if type(dot_export) == "string" then
      add_entry(dot_export)
    elseif type(dot_export) == "table" then
      for _, key in ipairs({ "default", "import", "require", "types" }) do
        add_entry(dot_export[key])
      end
    end
  end

  for _, field in ipairs({ "types", "typings", "module", "main" }) do
    add_entry(metadata[field])
  end

  return candidates
end

local function resolve_candidate_path(candidate_base)
  if not candidate_base or candidate_base == "" then
    return nil
  end

  local normalized_candidate = normalize(candidate_base)

  local function check_file(path)
    local stat = uv.fs_stat(path)
    if stat and stat.type == "file" then
      return path
    end
    if stat and stat.type == "link" then
      local real = uv.fs_realpath(path)
      if real then
        local real_stat = uv.fs_stat(real)
        if real_stat and real_stat.type == "file" then
          return real
        end
      end
    end
    return nil
  end

  local existing_ext = normalized_candidate:match("%.[^/%.]+$")
  local base_without_ext = normalized_candidate
  if existing_ext then
    base_without_ext = normalized_candidate:sub(1, #normalized_candidate - #existing_ext)
    local exact = check_file(normalized_candidate)
    if exact then
      return normalize(exact)
    end
  end

  for _, ext in ipairs(DEFAULT_EXTENSIONS) do
    local resolved = check_file(base_without_ext .. ext)
    if resolved then
      return normalize(resolved)
    end
  end

  local stat = uv.fs_stat(normalized_candidate)
  if stat and stat.type == "directory" then
    for _, index_name in ipairs(INDEX_FILES) do
      local resolved = check_file(join_paths(normalized_candidate, index_name))
      if resolved then
        return normalize(resolved)
      end
    end
  end

  return nil
end

local function resolve_node_module_import(base_dir, specifier)
  if not base_dir or base_dir == "" or not specifier or specifier == "" then
    return nil
  end

  local module_name, subpath = split_module_specifier(specifier)
  if not module_name then
    return nil
  end

  local node_modules_dir = get_node_modules_dir(base_dir)
  if not node_modules_dir then
    log:debug(string.format("[treesitter] No node_modules found for '%s' starting from %s", specifier, base_dir))
    return nil
  end

  local module_root = normalize(join_paths(node_modules_dir, module_name))
  local module_stat = uv.fs_stat(module_root)
  if not module_stat or module_stat.type ~= "directory" then
    log:debug(string.format("[treesitter] Module '%s' not found under %s", module_name, node_modules_dir))
    return nil
  end

  log:debug(string.format("[treesitter] Resolving module '%s' under %s", specifier, module_root))

  if subpath and subpath ~= "" then
    local candidate = normalize(join_paths(module_root, subpath))
    log:debug(string.format("[treesitter] Module subpath candidate: %s", candidate))
    local resolved = resolve_candidate_path(candidate)
    if resolved then
      log:debug(string.format("[treesitter] Resolved module subpath '%s' -> %s", specifier, resolved))
      return resolved
    end
    log:debug(string.format("[treesitter] Module subpath '%s' had no matching file", candidate))
  end

  local metadata = get_package_metadata(module_root)
  local entries = gather_package_entry_candidates(metadata)
  for _, entry in ipairs(entries) do
    local candidate = entry
    if not starts_with(candidate, "/") then
      candidate = normalize(join_paths(module_root, candidate))
    end
    log:debug(string.format("[treesitter] Module entry candidate: %s", candidate))
    local resolved = resolve_candidate_path(candidate)
    if resolved then
      log:debug(string.format("[treesitter] Resolved module entry '%s' -> %s", specifier, resolved))
      return resolved
    end
  end

  if not subpath or subpath == "" then
    local fallback = normalize(join_paths(module_root, "index"))
    log:debug(string.format("[treesitter] Module fallback candidate: %s", fallback))
    local resolved = resolve_candidate_path(fallback)
    if resolved then
      log:debug(string.format("[treesitter] Resolved module fallback '%s' -> %s", specifier, resolved))
      return resolved
    end
  end

  log:debug(string.format("[treesitter] Unable to resolve module import '%s'", specifier))
  return nil
end

local function normalize_import_path(text)
  local cleaned = trim(text)
  if not cleaned or cleaned == "" then
    return nil
  end
  cleaned = cleaned:gsub("^['\"`]", "")
  cleaned = cleaned:gsub("['\"`]$", "")
  if cleaned == "" or cleaned:find("%${", 1, true) then
    return nil
  end
  return cleaned
end

local JS_TS_IMPORT_QUERY = [[
  (import_statement
    source: [(string) (template_string)] @import.path)

  (import_call_expression
    arguments: (arguments [(string) (template_string)] @import.path))

  (call_expression
    function: (identifier) @import.require_name
    arguments: (arguments [(string) (template_string)] @import.path)
    (#eq? @import.require_name "require"))
]]

local LUA_IMPORT_QUERY = [[
  (function_call
    name: (identifier) @import.require_name
    arguments: (arguments (string) @import.path)
    (#eq? @import.require_name "require"))
]]

local IMPORT_QUERY_SOURCES = {
  javascript = JS_TS_IMPORT_QUERY,
  javascriptreact = JS_TS_IMPORT_QUERY,
  typescript = JS_TS_IMPORT_QUERY,
  typescriptreact = JS_TS_IMPORT_QUERY,
  tsx = JS_TS_IMPORT_QUERY,
  lua = LUA_IMPORT_QUERY,
}

local import_query_cache = {}

local function parse_ts_query(lang, source)
  if not vim.treesitter then
    return nil
  end
  if vim.treesitter.query and vim.treesitter.query.parse then
    local ok, query = pcall(vim.treesitter.query.parse, lang, source)
    if ok then
      return query
    end
    return nil
  end
  if vim.treesitter.parse_query then
    local ok, query = pcall(vim.treesitter.parse_query, lang, source)
    if ok then
      return query
    end
  end
  return nil
end

local function get_import_query(lang)
  if not lang or lang == "" then
    return nil
  end
  local cached = import_query_cache[lang]
  if cached ~= nil then
    if cached == false then
      return nil
    end
    return cached
  end

  local query_source = IMPORT_QUERY_SOURCES[lang]
  if not query_source then
    import_query_cache[lang] = false
    return nil
  end

  local query = parse_ts_query(lang, query_source)
  if not query then
    import_query_cache[lang] = false
    return nil
  end

  import_query_cache[lang] = query
  return query
end

local function collect_import_nodes_with_treesitter(root, source, lang)
  if not root or not lang then
    return {}
  end

  local query = get_import_query(lang)
  if not query then
    return {}
  end

  local imports = {}
  local seen = {}
  for capture_id, node in query:iter_captures(root, source, 0, -1) do
    local capture_name = query.captures[capture_id]
    if capture_name == "import.path" then
      local ok, text = pcall(vim.treesitter.get_node_text, node, source)
      if ok and text and text ~= "" then
        local normalized = normalize_import_path(text)
        if normalized and not seen[normalized] then
          local sr, sc, er, ec = node:range()
          seen[normalized] = true
          table.insert(imports, {
            specifier = normalized,
            node = node,
            range = {
              start_line = sr,
              start_col = sc,
              end_line = er,
              end_col = ec,
            },
          })
        end
      end
    end
  end

  return imports
end

local function parse_text_to_tree(text, lang)
  if not text or text == "" or not lang or lang == "" then
    return nil
  end
  if not vim.treesitter or not vim.treesitter.get_string_parser then
    return nil
  end
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok or not parser then
    return nil
  end
  local parsed = parser:parse()
  return parsed and parsed[1] or nil
end

local function extract_import_paths_fallback(text)
  local imports = {}
  local seen = {}
  if not text or text == "" then
    return imports
  end

  local function add(specifier)
    if specifier and specifier ~= "" and not seen[specifier] then
      seen[specifier] = true
      table.insert(imports, specifier)
    end
  end

  for specifier in text:gmatch('import%s+.-from%s+["\']([^"\']+)["\']') do
    add(specifier)
  end

  for specifier in text:gmatch('import%s+["\']([^"\']+)["\']') do
    add(specifier)
  end

  for specifier in text:gmatch('require%s*%(%s*["\']([^"\']+)["\']%s*%)') do
    add(specifier)
  end

  return imports
end

local function extract_import_paths_from_text(text, lang)
  if not text or text == "" then
    return {}
  end

  if lang and lang ~= "" then
    local tree = parse_text_to_tree(text, lang)
    if tree then
      local imports = collect_import_nodes_with_treesitter(tree:root(), text, lang)
      if #imports > 0 then
        return imports
      end
    end
  end

  local fallback = extract_import_paths_fallback(text)
  local specs = {}
  for _, specifier in ipairs(fallback) do
    table.insert(specs, { specifier = specifier })
  end
  return specs
end

local function get_buffer_content(bufnr)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if not ok or not lines then
    return nil
  end
  if #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n")
end

local function extract_import_paths_from_tree(root, bufnr, lang)
  local imports = collect_import_nodes_with_treesitter(root, bufnr, lang)
  if #imports > 0 then
    local paths = {}
    for _, spec in ipairs(imports) do
      table.insert(paths, spec.specifier)
    end
    return paths, imports
  end
  local content = get_buffer_content(bufnr)
  if not content then
    return {}, nil
  end
  local specs = extract_import_paths_from_text(content, lang)
  local paths = {}
  for _, spec in ipairs(specs) do
    table.insert(paths, spec.specifier)
  end
  return paths, specs
end

local function resolve_import_path(base_dir, import_path, alias_resolver)
  if not import_path or import_path == "" then
    return nil
  end

  log:debug(string.format("[treesitter] Resolving import '%s' (base: %s)", import_path, base_dir or ""))

  if starts_with(import_path, ".") then
    if not base_dir or base_dir == "" then
      return nil
    end
    local normalized_base = normalize(base_dir)
    local candidate_base = normalize(join_paths(normalized_base, import_path))
    log:debug(string.format("[treesitter] Relative candidate: %s", candidate_base))
    local resolved = resolve_candidate_path(candidate_base)
    if resolved then
      log:debug(string.format("[treesitter] Resolved relative import '%s' -> %s", import_path, resolved))
    else
      log:debug(string.format("[treesitter] Relative import '%s' had no matching file", import_path))
    end
    return resolved
  end

  if alias_resolver then
    local candidates = alias_resolver(import_path)
    if type(candidates) == "table" then
      for _, candidate in ipairs(candidates) do
        log:debug(string.format("[treesitter] Alias candidate for '%s': %s", import_path, candidate))
        local resolved = resolve_candidate_path(candidate)
        if resolved then
          log:debug(string.format("[treesitter] Resolved alias import '%s' -> %s", import_path, resolved))
          return resolved
        end
      end
      log:debug(string.format("[treesitter] No alias targets resolved for '%s'", import_path))
    else
      log:debug(string.format("[treesitter] Alias resolver produced no candidates for '%s'", import_path))
    end
  end

  if base_dir and base_dir ~= "" then
    local node_resolved = resolve_node_module_import(base_dir, import_path)
    if node_resolved then
      return node_resolved
    end
  end

  log:debug(string.format("[treesitter] Unable to resolve import '%s'", import_path))
  return nil
end

local function collect_import_contexts(file_path, import_paths, max_depth, max_files, max_lines, alias_resolver)
  if not file_path or file_path == "" then
    return {}
  end

  if not import_paths or #import_paths == 0 then
    return {}
  end

  local contexts = {}
  local visited = {}
  local root_path = normalize(file_path)
  if root_path then
    visited[root_path] = true
  end

  local function traverse(path, depth, current_resolver)
    if depth > max_depth or #contexts >= max_files then
      return
    end

    local content = read_file(path, max_lines)
    if not content then
      return
    end

    local lang = get_language_from_path(path)
    table.insert(contexts, {
      path = path,
      content = content,
      language = lang,
    })

    if depth == max_depth or #contexts >= max_files then
      return
    end

    local next_specs = extract_import_paths_from_text(content, lang)
    if #next_specs == 0 then
      return
    end

    local base_dir = dirname(path)
    local next_resolver = get_tsconfig_alias_resolver(path) or current_resolver
    for _, spec in ipairs(next_specs) do
      local next_path = spec.specifier
      local resolved = resolve_import_path(base_dir, next_path, next_resolver)
      if resolved then
        local normalized = normalize(resolved)
        if normalized and not visited[normalized] then
          visited[normalized] = true
          traverse(resolved, depth + 1, next_resolver)
          if #contexts >= max_files then
            break
          end
        end
      end
    end
  end

  local base_dir = dirname(file_path)
  for _, import_path in ipairs(import_paths) do
    local resolved = resolve_import_path(base_dir, import_path, alias_resolver)
    if resolved then
      local normalized = normalize(resolved)
      if normalized and not visited[normalized] then
        visited[normalized] = true
        traverse(resolved, 1, alias_resolver)
        if #contexts >= max_files then
          break
        end
      end
    end
  end

  return contexts
end

local function format_context_output(file_path, contexts)
  if not contexts or #contexts == 0 then
    return nil
  end

  local pieces = {}
  table.insert(pieces, string.format("Imported file context for %s", file_path))

  for _, context_info in ipairs(contexts) do
    table.insert(pieces, "")
    if context_info.language and context_info.language ~= "" then
      table.insert(pieces, string.format("%s (%s)", context_info.path, context_info.language))
    else
      table.insert(pieces, context_info.path)
    end
    local indented = indent_block(context_info.content, "  ")
    if indented then
      table.insert(pieces, indented)
    end
  end

  return table.concat(pieces, "\n")
end

local function finalize_refresh(file_path, changedtick, contexts)
  clear_job(file_path)
  local formatted = format_context_output(file_path, contexts)
  if formatted then
    update_cache(file_path, changedtick, formatted)
  end
end

local function fallback_refresh(file_path, import_paths, max_depth, max_files, max_lines, alias_resolver, changedtick)
  local contexts = collect_import_contexts(file_path, import_paths, max_depth, max_files, max_lines, alias_resolver)
  finalize_refresh(file_path, changedtick, contexts)
end

local function schedule_lsp_refresh(bufnr, file_path, lang, import_nodes, import_paths, ts_conf, alias_resolver)
  if not import_nodes or #import_nodes == 0 then
    return
  end

  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local key = cache_key_for_path(file_path)
  local existing_job = refresh_jobs[key]
  if existing_job and existing_job.changedtick == changedtick then
    return
  end

  if existing_job then
    existing_job.cancelled = true
  end

  local job = {
    cancelled = false,
    changedtick = changedtick,
  }
  refresh_jobs[key] = job

  vim.schedule(function()
    if job.cancelled then
      return
    end

    local clients = get_lsp_clients(bufnr)
    local client_count = clients and #clients or 0
    log:debug(string.format("[treesitter] LSP refresh for %s (imports: %d, clients: %d)", file_path, #import_nodes, client_count))
    if not clients or client_count == 0 then
      log:debug(string.format("[treesitter] No LSP clients attached to %s; using fallback resolver", file_path))
      job.cancelled = true
      clear_job(file_path)
      return
    end

    local max_files = math.max(0, ts_conf.max_files or 20)
    local max_lines_per_file = ts_conf.max_lines_per_file or 200
    local import_depth = math.max(0, ts_conf.max_depth or 0)

    local resolved_entries = {}
    local path_entries = {}
    local pending = 0

    local function maybe_finish()
      if pending > 0 or job.cancelled then
        return
      end

      if #resolved_entries == 0 then
        log:debug(string.format("[treesitter] LSP refresh returned no paths for %s; falling back", file_path))
        clear_job(file_path)
        if import_depth > 0 and max_files > 0 then
          fallback_refresh(file_path, import_paths, import_depth, max_files, max_lines_per_file, alias_resolver, changedtick)
        end
        return
      end

      local contexts = {}
      local visited_paths = {}
      visited_paths[normalize(file_path)] = true

      -- Function to recursively collect imports from resolved files
      local function collect_recursive_imports(entries_to_process, current_depth)
        if current_depth > import_depth or #contexts >= max_files then
          return
        end

        local next_level_paths = {}

        for _, entry in ipairs(entries_to_process) do
          if #contexts >= max_files then
            break
          end

          -- Read the file content (respecting ranges if available)
          local content
          if entry.ranges and #entry.ranges > 0 then
            content = extract_file_segments(entry.path, entry.ranges, max_lines_per_file)
          else
            content = read_file(entry.path, max_lines_per_file)
          end

          if content then
            log:debug(string.format("[treesitter] Including file %s at depth %d (%d bytes)", entry.path, current_depth, #content))
            local lang = get_language_from_path(entry.path)
            table.insert(contexts, {
              path = entry.path,
              content = content,
              language = lang,
            })

            -- Extract imports from this file to process at the next depth level
            if current_depth < import_depth and #contexts < max_files then
              local full_content = read_entire_file(entry.path)
              if not full_content then
                log:debug(string.format("[treesitter] Could not read full content from %s for import extraction", entry.path))
              else
                local import_specs = extract_import_paths_from_text(full_content, lang)
                log:debug(string.format("[treesitter] Found %d imports in %s", #import_specs, entry.path))
                if #import_specs > 0 then
                  local base_dir = dirname(entry.path)
                  local entry_resolver = get_tsconfig_alias_resolver(entry.path) or alias_resolver

                  for _, spec in ipairs(import_specs) do
                    if #contexts >= max_files then
                      break
                    end

                    local resolved = resolve_import_path(base_dir, spec.specifier, entry_resolver)
                    if resolved then
                      local normalized = normalize(resolved)
                      if normalized and not visited_paths[normalized] then
                        visited_paths[normalized] = true
                        table.insert(next_level_paths, { path = resolved, ranges = {} })
                        log:debug(string.format("[treesitter] Discovered import '%s' from %s -> %s (will process at depth %d)", spec.specifier, entry.path, resolved, current_depth + 1))
                      else
                        log:debug(string.format("[treesitter] Skipping already visited: %s", normalized or resolved))
                      end
                    else
                      log:debug(string.format("[treesitter] Could not resolve import '%s' from %s", spec.specifier, entry.path))
                    end
                  end
                end
              end
            end
          else
            log:debug(string.format("[treesitter] No content extracted from %s (ranges: %d)", entry.path, entry.ranges and #entry.ranges or 0))
          end
        end

        -- Recursively process the next level
        if #next_level_paths > 0 and current_depth + 1 <= import_depth and #contexts < max_files then
          log:debug(string.format("[treesitter] Recursing to depth %d with %d files", current_depth + 1, #next_level_paths))
          collect_recursive_imports(next_level_paths, current_depth + 1)
        end
      end

      -- Start recursive collection from the initial LSP-resolved entries
      collect_recursive_imports(resolved_entries, 1)

      finalize_refresh(file_path, changedtick, contexts)
    end

    local active_clients = {}
    for _, client in ipairs(clients) do
      if client then
        local has_definition = false
        if client.supports_method and client:supports_method("textDocument/definition") then
          has_definition = true
        elseif client.server_capabilities then
          local cap = client.server_capabilities.definitionProvider
          if cap == true or type(cap) == "table" then
            has_definition = true
          end
        end
        if has_definition then
          table.insert(active_clients, client)
        end
      end
    end

    if #active_clients == 0 then
      log:debug(string.format("[treesitter] No definition-capable clients for %s", file_path))
      clear_job(file_path)
      return
    end

    for _, spec in ipairs(import_nodes) do
      if job.cancelled then
        break
      end

      if max_files > 0 and #resolved_entries >= max_files then
        break
      end

      local range = spec.range or {}
      local line
      local character

      if spec.node then
        line = range.start_line or 0
        character = math.max(0, (range.start_col or 0) + 1)
      else
        line, character = find_import_position(bufnr, spec.specifier)
        if line == nil then
          log:debug(string.format("[treesitter] Could not determine position for import '%s'", spec.specifier or ""))
        else
          log:debug(string.format("[treesitter] Using fallback position line %d col %d for import '%s'", line + 1, character + 1, spec.specifier or ""))
        end
      end

      if line == nil or character == nil then
        goto continue_spec
      end

      for _, client in ipairs(active_clients) do
        local params = {
          textDocument = vim.lsp.util.make_text_document_params(bufnr),
          position = {
            line = line,
            character = character,
          },
        }

        pending = pending + 1
        log:debug(string.format("[treesitter] Requesting definition from client %s for import '%s'", client.name or tostring(client.id), spec.specifier or ""))

        client.request("textDocument/definition", params, function(err, result)
          if job.cancelled then
            pending = pending - 1
            maybe_finish()
            return
          end

          if err then
            log:debug(string.format("[treesitter] LSP definition error (client %s): %s", client.name or tostring(client.id), err.message or tostring(err)))
          elseif result then
            local ok, inspected = pcall(vim.inspect, result)
            if ok then
              log:debug(string.format("[treesitter] LSP definition result (client %s): %s", client.name or tostring(client.id), inspected))
            end
            iter_lsp_locations(result, function(location)
              local uri = location.uri or location.targetUri
              if not uri then
                return
              end
              local ok_uri, path = pcall(vim.uri_to_fname, uri)
              if not ok_uri or not path or path == "" then
                return
              end
              path = normalize(path)
              if path == normalize(file_path) then
                return
              end

              local entry = path_entries[path]
              if not entry then
                if max_files > 0 and #resolved_entries >= max_files then
                  return
                end
                entry = { path = path, ranges = {} }
                path_entries[path] = entry
                table.insert(resolved_entries, entry)
                log:debug(string.format("[treesitter] LSP candidate path for %s: %s", file_path, path))
              end

              local range_info = normalize_location_range(location)
              if range_info then
                local duplicate = false
                for _, existing in ipairs(entry.ranges) do
                  if existing.start_line == range_info.start_line and existing.end_line == range_info.end_line then
                    duplicate = true
                    break
                  end
                end
                if not duplicate then
                  table.insert(entry.ranges, range_info)
                end
              end
            end)
          else
            log:debug(string.format("[treesitter] LSP definition returned no result (client %s)", client.name or tostring(client.id)))
          end

          pending = pending - 1
          maybe_finish()
        end, bufnr)
      end

      ::continue_spec::
    end

    if pending == 0 then
      maybe_finish()
    end
  end)
end

function M.extract_context(bufnr, file_path, lang, cursor)
  if not M.is_enabled() then
    return nil
  end

  if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
    log:debug("[treesitter] Invalid buffer passed to context extractor")
    return nil
  end

  if not ts_available() then
    return nil
  end

  if not file_path or file_path == "" then
    return nil
  end

  local ts_conf = get_ts_config() or {}
  local max_lines_per_file = ts_conf.max_lines_per_file or 200
  local max_files = math.max(0, ts_conf.max_files or 20)
  local import_depth = math.max(0, ts_conf.max_depth or 0)

  if max_files <= 0 or import_depth <= 0 then
    return nil
  end

  local effective_lang = lang or get_language_from_path(file_path) or vim.bo[bufnr].filetype
  if not effective_lang or effective_lang == "" then
    return nil
  end

  local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, effective_lang)
  if not parser_ok or not parser then
    log:debug(string.format("[treesitter] No parser for %s (%s)", file_path, effective_lang or ""))
    return nil
  end

  local parsed_ok, tree = pcall(function()
    local parsed = parser:parse()
    return parsed and parsed[1] or nil
  end)

  if not parsed_ok or not tree then
    log:debug(string.format("[treesitter] Failed to parse buffer %d", bufnr))
    return nil
  end

  local root = tree:root()
  if not root then
    return nil
  end

  local import_paths, import_nodes = extract_import_paths_from_tree(root, bufnr, effective_lang)
  if not import_paths or #import_paths == 0 then
    return get_cached_context(file_path, vim.api.nvim_buf_get_changedtick(bufnr))
  end

  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = get_cached_context(file_path, changedtick)

  local alias_resolver = get_tsconfig_alias_resolver(file_path)

  if import_depth > 0 and max_files > 0 then
    schedule_lsp_refresh(bufnr, file_path, effective_lang, import_nodes, import_paths, ts_conf, alias_resolver)
  end

  if cached then
    return cached
  end

  local import_contexts =
    collect_import_contexts(file_path, import_paths, import_depth, max_files, max_lines_per_file, alias_resolver)

  if not import_contexts or #import_contexts == 0 then
    return nil
  end

  local formatted = format_context_output(file_path, import_contexts)
  if formatted then
    update_cache(file_path, changedtick, formatted)
  end
  return formatted
end

return M
