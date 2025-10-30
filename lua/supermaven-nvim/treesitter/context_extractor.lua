local config = require("supermaven-nvim.config")
local log = require("supermaven-nvim.logger")

local uv = vim.uv or vim.loop

local M = {}

local collect_type_definitions
local collect_symbol_summaries

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

local function extract_types_from_text(text, lang, max_items, max_lines, symbol_limits)
  if not text or text == "" or not lang or lang == "" then
    return {}, nil
  end

  if not vim.treesitter.get_string_parser then
    return {}, nil
  end

  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok or not parser then
    return {}, nil
  end

  local parsed = parser:parse()
  if not parsed or not parsed[1] then
    return {}, nil
  end

  local root = parsed[1]:root()
  if not root then
    return {}, nil
  end

  local definitions, type_map = collect_type_definitions(root, text, max_items, max_lines)
  local symbol_summary = collect_symbol_summaries(root, text, lang, symbol_limits, type_map)
  return definitions, type_map, symbol_summary
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

local PRIMITIVE_TYPES = {
  ["string"] = true,
  ["number"] = true,
  ["boolean"] = true,
  ["nil"] = true,
  ["null"] = true,
  ["void"] = true,
  ["undefined"] = true,
  ["any"] = true,
  ["unknown"] = true,
  ["never"] = true,
  ["object"] = true,
  ["symbol"] = true,
  ["bigint"] = true,
}

local IGNORED_TYPE_NAMES = {
  ["Array"] = true,
  ["Promise"] = true,
  ["Record"] = true,
  ["Map"] = true,
  ["Set"] = true,
  ["Readonly"] = true,
  ["Partial"] = true,
  ["Pick"] = true,
  ["Omit"] = true,
  ["Exclude"] = true,
  ["Extract"] = true,
  ["Required"] = true,
  ["InstanceType"] = true,
  ["ReturnType"] = true,
  ["Parameters"] = true,
  ["keyof"] = true,
}

local IDENTIFIER_TYPES = {
  identifier = true,
  property_identifier = true,
  field_identifier = true,
  type_identifier = true,
  name = true,
  method_identifier = true,
  operator_identifier = true,
  simple_identifier = true,
}

local NAME_FIELDS = { "name", "identifier", "field", "property", "type", "key" }

local SCOPE_NODE_TYPES = {
  function_definition = true,
  function_declaration = true,
  function_statement = true,
  function_expression = true,
  method_definition = true,
  method_declaration = true,
  arrow_function = true,
  class_body = false,
  class_declaration = true,
  class_definition = true,
  interface_declaration = true,
  struct_spec = true,
  struct_declaration = true,
  impl_item = true,
  module = true,
  table_constructor = true,
  block = false, -- prevent false positives
}

local TYPE_NODE_TYPES = {
  interface_declaration = true,
  type_alias_declaration = true,
  class_declaration = true,
  enum_declaration = true,
  export_statement = true,
}

local SCOPE_TYPE_FALLBACK_PATTERNS = {
  "function",
  "class",
  "method",
  "struct",
  "interface",
  "impl",
}

local function ts_available()
  return vim.treesitter ~= nil and vim.treesitter.get_parser ~= nil
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

local function is_scope_node(node)
  if not node then
    return false
  end
  local node_type = node:type()
  if SCOPE_NODE_TYPES[node_type] ~= nil then
    return SCOPE_NODE_TYPES[node_type]
  end
  for _, pattern in ipairs(SCOPE_TYPE_FALLBACK_PATTERNS) do
    if node_type:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function get_node_name(node, source)
  if not node then
    return nil
  end

  for _, field in ipairs(NAME_FIELDS) do
    local field_nodes = node:field(field)
    if field_nodes and field_nodes[1] then
      local ok, text = pcall(vim.treesitter.get_node_text, field_nodes[1], source)
      if ok and text and #text > 0 then
        return trim(text)
      end
    end
  end

  for child in node:iter_children() do
    local ctype = child:type()
    if IDENTIFIER_TYPES[ctype] then
      local ok, text = pcall(vim.treesitter.get_node_text, child, source)
      if ok and text and #text > 0 then
        return trim(text)
      end
    end
  end

  return nil
end

local function truncate_text(text, max_lines)
  if not text or max_lines == nil or max_lines <= 0 then
    return text
  end

  local lines = vim.split(text, "\n", { plain = true })
  if #lines <= max_lines then
    return text
  end

  local truncated = {}
  for i = 1, max_lines do
    table.insert(truncated, lines[i])
  end
  table.insert(truncated, "... (truncated)")

  return table.concat(truncated, "\n")
end

local function describe_node(node, source)
  if not node then
    return nil
  end

  local sr, _, er = node:range()
  local name = get_node_name(node, source)

  if name and #name > 0 then
    return string.format("%s (%s, lines %d-%d)", name, node:type(), sr + 1, er + 1)
  end

  return string.format("%s (lines %d-%d)", node:type(), sr + 1, er + 1)
end

local function get_node_text(node, source, max_lines)
  if not node then
    return nil
  end
  local ok, text = pcall(vim.treesitter.get_node_text, node, source)
  if not ok or not text or #text == 0 then
    return nil
  end
  return truncate_text(text, max_lines)
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

local function single_line(text)
  if not text or text == "" then
    return text
  end
  text = text:gsub("\n+", " ")
  text = text:gsub("%s+", " ")
  return trim(text)
end

local function get_field_node(node, field)
  if not node or not field then
    return nil
  end

  if node.child_by_field_name then
    local ok, child = pcall(node.child_by_field_name, node, field)
    if ok and child then
      return child
    end
  end

  if node.field then
    local ok, field_nodes = pcall(node.field, node, field)
    if ok and field_nodes and field_nodes[1] then
      return field_nodes[1]
    end
  end

  return nil
end

local function get_child_text(node, field, source, fallback)
  if not node then
    return fallback
  end
  local child = get_field_node(node, field)
  if not child then
    return fallback
  end
  local ok, text = pcall(vim.treesitter.get_node_text, child, source)
  if not ok or not text or text == "" then
    return fallback
  end
  return trim(text)
end

local function find_ancestor(node, predicate)
  local current = node and node:parent()
  while current do
    if predicate(current) then
      return current
    end
    current = current:parent()
  end
  return nil
end

local function get_call_context_label(node, source)
  local current = node and node:parent()
  while current do
    local ctype = current:type()
    if ctype == "call_expression" or ctype == "new_expression" or ctype == "await_expression" then
      local callee = get_field_node(current, "function")
        or get_field_node(current, "callee")
        or get_field_node(current, "argument")
      if callee then
        local text = single_line(get_node_text(callee, source))
        if text and text ~= "" then
          local label = text:match("([%w_]+)%s*$") or text
          return trim(label)
        end
      end
    end
    if is_scope_node(current) then
      break
    end
    current = current:parent()
  end
  return nil
end

local function extract_type_identifiers(...)
  local collected = {}
  local args = { ... }
  for _, text in ipairs(args) do
    if text and text ~= "" then
      local sanitized = text:gsub("[%[%]{}()%<>:,|&=?]", " ")
      sanitized = sanitized:gsub("%s+", " ")
      for word in sanitized:gmatch("([%a_][%w_]*)") do
        local base = word:gsub("%[%]$", "")
        base = base:gsub("^_+", "")
        base = base:gsub("_+$", "")
        base = base:gsub("%d+$", "")
        if base ~= "" then
          if not PRIMITIVE_TYPES[base]
            and not IGNORED_TYPE_NAMES[base]
            and base:match("^[A-Z]")
          then
            collected[base] = true
          end
        end
      end
    end
  end
  return collected
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

local function extract_import_paths(text)
  local imports = {}
  local seen = {}
  if not text or text == "" then
    return imports
  end

  for specifier in text:gmatch('import%s+.-from%s+["\']([^"\']+)["\']') do
    if not seen[specifier] then
      seen[specifier] = true
      table.insert(imports, specifier)
    end
  end

  for specifier in text:gmatch('import%s+["\']([^"\']+)["\']') do
    if not seen[specifier] then
      seen[specifier] = true
      table.insert(imports, specifier)
    end
  end

  for specifier in text:gmatch('require%s*%(%s*["\']([^"\']+)["\']%s*%)') do
    if not seen[specifier] then
      seen[specifier] = true
      table.insert(imports, specifier)
    end
  end

  return imports
end

local function resolve_import_path(base_dir, import_path)
  if not import_path or import_path == "" or not starts_with(import_path, ".") then
    return nil
  end

  if not base_dir or base_dir == "" then
    return nil
  end

  local normalized_base = normalize(base_dir)
  local candidate_base = normalize(join_paths(normalized_base, import_path))

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

  local existing_ext = candidate_base:match("%.[^/%.]+$")
  local base_without_ext = candidate_base
  if existing_ext then
    base_without_ext = candidate_base:sub(1, #candidate_base - #existing_ext)
  end

  -- Exact match for written extension
  if existing_ext then
    local exact = check_file(candidate_base)
    if exact then
      return normalize(exact)
    end
  end

  local extensions = { ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".d.ts" }
  for _, ext in ipairs(extensions) do
    local resolved = check_file(base_without_ext .. ext)
    if resolved then
      return normalize(resolved)
    end
  end

  local stat = uv.fs_stat(candidate_base)
  if stat and stat.type == "directory" then
    local index_files = { "index.ts", "index.tsx", "index.js", "index.jsx", "index.d.ts" }
    for _, index_name in ipairs(index_files) do
      local resolved = check_file(join_paths(candidate_base, index_name))
      if resolved then
        return normalize(resolved)
      end
    end
  end

  return nil
end

local function collect_import_contexts(file_path, max_depth, max_files, max_lines, symbol_limits)
  if not file_path or file_path == "" then
    return {}
  end

  symbol_limits = symbol_limits or {}

  local visited = { [file_path] = true }
  local contexts = {}
  local type_limit = math.min(5, math.max(0, max_files))
  local wants_symbols = ((symbol_limits.max_imports or 0) > 0)
    or ((symbol_limits.max_functions or 0) > 0)
    or ((symbol_limits.max_variables or 0) > 0)
    or ((symbol_limits.max_types or 0) > 0)

  local function traverse(path, depth)
    if depth > max_depth then
      return
    end

    if #contexts >= max_files then
      return
    end

    local content = read_file(path, max_lines)
    if not content then
      return
    end

    local lang = get_language_from_path(path)
    local type_definitions = {}
    local type_map = {}
    local symbol_summary = nil
    if type_limit > 0 or wants_symbols then
      type_definitions, type_map, symbol_summary = extract_types_from_text(content, lang, type_limit, max_lines, symbol_limits)
    end

    table.insert(contexts, {
      path = path,
      content = content,
      language = lang,
      type_definitions = type_definitions,
      type_map = type_map,
      symbols = symbol_summary,
    })

    if depth == max_depth or #contexts >= max_files then
      return
    end

    local base_dir = dirname(path)
    for _, import_path in ipairs(extract_import_paths(content)) do
      local resolved = resolve_import_path(base_dir, import_path)
      if resolved and not visited[resolved] then
        visited[resolved] = true
        traverse(resolved, depth + 1)
        if #contexts >= max_files then
          break
        end
      end
    end
  end

  local initial_content = read_file(file_path, max_lines)
  if not initial_content then
    return contexts
  end

  local base_dir = dirname(file_path)
  for _, import_path in ipairs(extract_import_paths(initial_content)) do
    local resolved = resolve_import_path(base_dir, import_path)
    if resolved and not visited[resolved] then
      visited[resolved] = true
      traverse(resolved, 1)
      if #contexts >= max_files then
        break
      end
    end
  end

  return contexts
end

collect_type_definitions = function(root, source, max_items, max_lines)
  if not root or max_items <= 0 then
    return {}, {}
  end

  local collected_nodes = {}

  local function visit(node)
    if not node or #collected_nodes >= max_items then
      return
    end

    local node_type = node:type()
    if TYPE_NODE_TYPES[node_type] then
      if node_type == "export_statement" then
        for child in node:iter_children() do
          if TYPE_NODE_TYPES[child:type()] and child:type() ~= "export_statement" then
            visit(child)
            if #collected_nodes >= max_items then
              return
            end
          end
        end
      else
        table.insert(collected_nodes, node)
      end
    end

    for child in node:iter_children() do
      if #collected_nodes >= max_items then
        return
      end
      visit(child)
    end
  end

  visit(root)

  local definitions = {}
  local type_map = {}
  for _, node in ipairs(collected_nodes) do
    local snippet = get_node_text(node, source, max_lines)
    if snippet and snippet ~= "" then
      local name = get_node_name(node, source)
      table.insert(definitions, {
        name = name,
        description = describe_node(node, source),
        text = snippet,
      })
      if name and name ~= "" and type_map[name] == nil then
        type_map[name] = snippet
      end
    end
  end

  return definitions, type_map
end

local function get_type_annotation_text(node, source)
  local annotation_fields = { "return_type", "type_annotation", "type" }
  for _, field in ipairs(annotation_fields) do
    local text = get_child_text(node, field, source)
    if text and text ~= "" then
      return single_line(text)
    end
  end

  for child in node:iter_children() do
    if child:type() == "type_annotation" then
      local ok, text = pcall(vim.treesitter.get_node_text, child, source)
      if ok and text and text ~= "" then
        return single_line(text)
      end
    end
  end

  return nil
end

collect_symbol_summaries = function(root, source, lang, limits, type_lookup)
  if not root or not lang then
    return nil
  end

  local is_ts = lang == "typescript" or lang == "tsx" or lang == "typescriptreact"
  if not is_ts then
    return nil
  end

  limits = limits or {}
  local import_limit = math.max(0, limits.max_imports or 20)
  local function_limit = math.max(0, limits.max_functions or 20)
  local variable_limit = math.max(0, limits.max_variables or 20)
  local types_limit = math.max(0, limits.max_types or 10)

  local results = {
    imports = {},
    functions = {},
    variables = {},
    type_expansions = {},
  }

  local function add_entry(list_name, entry, limit)
    if limit <= 0 or not entry or entry == "" then
      return
    end
    local list = results[list_name]
    if #list >= limit then
      return
    end
    table.insert(list, entry)
  end

  local type_seen = {}
  local function add_type_entry(name, snippet)
    if types_limit <= 0 then
      return
    end
    if not name or name == "" or not snippet then
      return
    end
    if type_seen[name] then
      return
    end
    if #results.type_expansions >= types_limit then
      return
    end
    type_seen[name] = true
    table.insert(results.type_expansions, {
      name = name,
      text = snippet,
    })
  end

  local function summarize_import(node)
    local source_node = get_field_node(node, "source")
    local clause_node = get_field_node(node, "clause")
    local source_text = source_node and get_node_text(source_node, source) or ""
    source_text = source_text and source_text:gsub("^[\"']", ""):gsub("[\"']$", "") or ""

    local clause_text = nil
    if clause_node then
      clause_text = single_line(get_node_text(clause_node, source))
    end

    if not clause_text or clause_text == "" then
      local full_text = single_line(get_node_text(node, source)) or ""
      clause_text = full_text:match("import%s+(.+)%s+from")
      if clause_text then
        clause_text = trim(clause_text)
      end
    end

    if clause_text and clause_text ~= "" and not clause_text:match("^from%s") then
      return string.format("%s from %s", clause_text, source_text)
    end

    return string.format("side effect import from %s", source_text)
  end

  local function summarize_function(node)
    local name = get_child_text(node, "name", source)
    if not name or name == "" then
      local decl = find_ancestor(node, function(parent)
        local t = parent:type()
        return t == "variable_declarator" or t == "method_definition" or t == "pair" or t == "property_signature"
      end)
      name = decl and get_node_name(decl, source) or get_node_name(node, source) or "<anonymous>"
    end

    local params = get_child_text(node, "parameters", source, "()")
    params = single_line(params or "()")

    local return_type = get_type_annotation_text(node, source)
    if return_type and not return_type:match("^:") then
      return_type = ": " .. return_type
    end

    local type_params = get_child_text(node, "type_parameters", source)
    type_params = type_params and single_line(type_params) or ""

    if (not name or name == "" or name == "<anonymous>") and node:type() == "arrow_function" then
      local call_label = get_call_context_label(node, source)
      if call_label and call_label ~= "" then
        name = string.format("%s callback", call_label)
      end
    end

    if not name or name == "" then
      name = "<anonymous>"
    end

    local signature = string.format("%s%s%s%s", name, type_params or "", params or "()", return_type or "")

    if type_lookup then
      local referenced = extract_type_identifiers(params, return_type, type_params)
      for type_name in pairs(referenced) do
        local snippet = type_lookup[type_name]
        if snippet then
          add_type_entry(type_name, snippet)
        end
      end
    end

    return trim(signature)
  end

  local function summarize_variable(node)
    local name = get_child_text(node, "name", source) or get_node_name(node, source)
    if not name or name == "" then
      return nil
    end

    local type_annotation = get_type_annotation_text(node, source)
    if not type_annotation or type_annotation == "" then
      return nil
    end

    if type_lookup then
      local referenced = extract_type_identifiers(type_annotation)
      for type_name in pairs(referenced) do
        local snippet = type_lookup[type_name]
        if snippet then
          add_type_entry(type_name, snippet)
        end
      end
    end

    return trim(string.format("%s %s", name, type_annotation))
  end

  local function traverse(node)
    local node_type = node:type()

    if import_limit > 0 and node_type == "import_statement" then
      local entry = summarize_import(node)
      add_entry("imports", entry, import_limit)
    elseif function_limit > 0 and (node_type == "function_declaration"
      or node_type == "method_definition"
      or node_type == "method_signature"
      or node_type == "function_signature"
      or node_type == "arrow_function") then
      local entry = summarize_function(node)
      add_entry("functions", entry, function_limit)
    elseif variable_limit > 0 and (node_type == "variable_declarator" or node_type == "property_signature") then
      local entry = summarize_variable(node)
      add_entry("variables", entry, variable_limit)
    end

    for child in node:iter_children() do
      traverse(child)
    end
  end

  traverse(root)

  local has_results = (#results.imports > 0) or (#results.functions > 0) or (#results.variables > 0)
    or (#results.type_expansions > 0)
  if not has_results then
    return nil
  end

  return results
end

local function build_scope_chain(node)
  local chain = {}
  local current = node
  while current do
    if is_scope_node(current) then
      table.insert(chain, 1, current)
    end
    current = current:parent()
  end
  return chain
end

local function collect_sibling_definitions(node, max_items)
  if not max_items or max_items <= 0 then
    return {}
  end
  if not node then
    return {}
  end
  local parent = node:parent()
  if not parent then
    return {}
  end

  local siblings = {}
  for child in parent:iter_children() do
    if child ~= node and is_scope_node(child) then
      table.insert(siblings, child)
    end
  end

  if #siblings <= max_items then
    return siblings
  end

  local trimmed = {}
  for i = 1, math.min(max_items, #siblings) do
    trimmed[i] = siblings[i]
  end
  return trimmed
end

local function get_cursor_position(cursor)
  local line, col = 1, 0
  if cursor and cursor[1] then
    line = cursor[1]
  end
  if cursor and cursor[2] then
    col = cursor[2]
  end
  return line, col
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

  local ts_conf = get_ts_config() or {}
  local max_lines_per_snippet = ts_conf.max_lines_per_file or 200
  local max_files = ts_conf.max_files or 20
  max_files = math.max(0, max_files)
  local sibling_limit = math.min(3, math.max(0, max_files - 1))
  local type_limit = math.min(5, max_files)
  local import_limit = math.max(0, max_files - 1)
  local symbol_limits = ts_conf.symbol_details or {}
  local effective_lang = lang or get_language_from_path(file_path) or vim.bo[bufnr].filetype

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, effective_lang)
  if not ok or not parser then
    local display_path = (file_path and #file_path > 0) and file_path or string.format("buffer %d", bufnr)
    log:debug(string.format("[treesitter] No parser for %s (%s)", display_path, effective_lang or ""))
    return nil
  end

  local tree
  ok, tree = pcall(function()
    local parsed = parser:parse()
    return parsed and parsed[1] or nil
  end)
  if not ok or not tree then
    log:debug(string.format("[treesitter] Failed to parse buffer %d", bufnr))
    return nil
  end

  local root = tree:root()
  if not root then
    return nil
  end

  local cursor_line, cursor_col = get_cursor_position(cursor or vim.api.nvim_win_get_cursor(0))
  local row = cursor_line - 1
  local col = cursor_col

  local current_node = root:named_descendant_for_range(row, col, row, col)
  if not current_node then
    return nil
  end

  local scope_chain = build_scope_chain(current_node)
  local innermost_scope = scope_chain[#scope_chain]
  if not innermost_scope then
    local probe = current_node
    while probe and not is_scope_node(probe) do
      probe = probe:parent()
    end
    innermost_scope = probe or current_node
  end

  local type_definitions, type_map = collect_type_definitions(root, bufnr, type_limit, max_lines_per_snippet)
  local aggregated_type_map = {}
  for name, snippet in pairs(type_map) do
    aggregated_type_map[name] = snippet
  end

  local import_depth = ts_conf.max_depth or 0
  local import_contexts = {}
  if import_limit > 0 and import_depth > 0 and file_path and #file_path > 0 then
    import_contexts =
      collect_import_contexts(file_path, import_depth, import_limit, max_lines_per_snippet, symbol_limits)
    for _, context_info in ipairs(import_contexts) do
      if context_info.type_map then
        for name, snippet in pairs(context_info.type_map) do
          if aggregated_type_map[name] == nil then
            aggregated_type_map[name] = snippet
          end
        end
      end
    end
  end

  local symbol_info = collect_symbol_summaries(root, bufnr, effective_lang, symbol_limits, aggregated_type_map)

  local pieces = {}
  table.insert(pieces, string.format("Treesitter context for %s", file_path or ("buffer " .. bufnr)))
  table.insert(pieces, string.format("Cursor: line %d, column %d", cursor_line, cursor_col))

  if #scope_chain > 0 then
    table.insert(pieces, "")
    table.insert(pieces, "Enclosing scopes:")
    for _, scope in ipairs(scope_chain) do
      local description = describe_node(scope, bufnr)
      if description then
        table.insert(pieces, "- " .. description)
      end
    end
  end

  local scope_snippet = get_node_text(innermost_scope, bufnr, max_lines_per_snippet)
  if scope_snippet and scope_snippet ~= "" then
    table.insert(pieces, "")
    table.insert(pieces, "Current scope:")
    table.insert(pieces, scope_snippet)
  end

  local siblings = collect_sibling_definitions(innermost_scope, sibling_limit)
  if #siblings > 0 then
    table.insert(pieces, "")
    table.insert(pieces, "Nearby definitions:")
    for _, sibling in ipairs(siblings) do
      local description = describe_node(sibling, bufnr)
      if description then
        table.insert(pieces, "- " .. description)
      end
      local text = get_node_text(sibling, bufnr, math.max(1, math.floor(max_lines_per_snippet / 2)))
      local indented = indent_block(text, "  ")
      if indented then
        table.insert(pieces, indented)
      end
    end
  end

  if #type_definitions > 0 then
    table.insert(pieces, "")
    table.insert(pieces, "Type definitions in current file:")
    for _, definition in ipairs(type_definitions) do
      if definition.description then
        table.insert(pieces, "- " .. definition.description)
      end
      local indented = indent_block(definition.text, "  ")
      if indented then
        table.insert(pieces, indented)
      end
    end
  end

  if symbol_info then
    table.insert(pieces, "")
    table.insert(pieces, "Symbol overview:")
    if symbol_info.imports and #symbol_info.imports > 0 then
      table.insert(pieces, "  Imports:")
      for _, entry in ipairs(symbol_info.imports) do
        table.insert(pieces, "  - " .. entry)
      end
    end
    if symbol_info.functions and #symbol_info.functions > 0 then
      table.insert(pieces, "  Functions:")
      for _, entry in ipairs(symbol_info.functions) do
        table.insert(pieces, "  - " .. entry)
      end
    end
    if symbol_info.variables and #symbol_info.variables > 0 then
      table.insert(pieces, "  Variables:")
      for _, entry in ipairs(symbol_info.variables) do
        table.insert(pieces, "  - " .. entry)
      end
    end
    if symbol_info.type_expansions and #symbol_info.type_expansions > 0 then
      table.insert(pieces, "  Related types:")
      for _, entry in ipairs(symbol_info.type_expansions) do
        table.insert(pieces, "  - " .. entry.name)
        local indented = indent_block(entry.text, "    ")
        if indented then
          table.insert(pieces, indented)
        end
      end
    end
  end

  if import_limit > 0 and import_depth > 0 and file_path and #file_path > 0 and #import_contexts > 0 then
    table.insert(pieces, "")
    table.insert(pieces, "Imported modules:")
    for _, context_info in ipairs(import_contexts) do
      table.insert(pieces, "- " .. context_info.path)
      local type_defs = context_info.type_definitions or {}
      if #type_defs > 0 then
        table.insert(pieces, "  Type definitions:")
        for _, def in ipairs(type_defs) do
          if def.description then
            table.insert(pieces, "  - " .. def.description)
          end
          local indented_def = indent_block(def.text, "    ")
          if indented_def then
            table.insert(pieces, indented_def)
          end
        end
      end
      local symbols = context_info.symbols
      if symbols then
        if symbols.imports and #symbols.imports > 0 then
          table.insert(pieces, "  Imports:")
          for _, entry in ipairs(symbols.imports) do
            table.insert(pieces, "  - " .. entry)
          end
        end
        if symbols.functions and #symbols.functions > 0 then
          table.insert(pieces, "  Functions:")
          for _, entry in ipairs(symbols.functions) do
            table.insert(pieces, "  - " .. entry)
          end
        end
        if symbols.variables and #symbols.variables > 0 then
          table.insert(pieces, "  Variables:")
          for _, entry in ipairs(symbols.variables) do
            table.insert(pieces, "  - " .. entry)
          end
        end
        if symbols.type_expansions and #symbols.type_expansions > 0 then
          table.insert(pieces, "  Related types:")
          for _, entry in ipairs(symbols.type_expansions) do
            table.insert(pieces, "  - " .. entry.name)
            local indented_type = indent_block(entry.text, "    ")
            if indented_type then
              table.insert(pieces, indented_type)
            end
          end
        end
      end
      local has_symbol_entries = symbols
        and ((symbols.imports and #symbols.imports > 0)
          or (symbols.functions and #symbols.functions > 0)
          or (symbols.variables and #symbols.variables > 0)
          or (symbols.type_expansions and #symbols.type_expansions > 0))

      if (#type_defs == 0) and not has_symbol_entries then
        local indented = indent_block(context_info.content, "  ")
        if indented then
          table.insert(pieces, indented)
        end
      end
      table.insert(pieces, "")
    end
    if pieces[#pieces] == "" then
      table.remove(pieces)
    end
  end

  if #pieces == 0 then
    return nil
  end

  return table.concat(pieces, "\n")
end

return M
