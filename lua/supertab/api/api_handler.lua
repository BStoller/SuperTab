local api = vim.api
local u = require("supertab.util")
local loop = u.uv
local textual = require("supertab.textual")
local config = require("supertab.config")
local preview = require("supertab.completion_preview")
local log = require("supertab.logger")
local http_client = require("supertab.api.http_client")
local prompt_builder = require("supertab.api.prompt_builder")
local context_tracker = require("supertab.context_tracker")
local treesitter_extractor = require("supertab.treesitter.context_extractor")

local APIHandler = {
  state_map = {},
  current_state_id = 0,
  last_provide_time = 0,
  buffer = nil,
  cursor = nil,
  max_state_id_retention = 50,
  changed_document_list = {},
  last_state = nil,
  active_request = nil,
  is_active = false,
  -- Metrics tracking
  last_completion_metrics = {
    token_count = 0,
    char_count = 0,
    input_char_count = 0,
    output_char_count = 0,
    start_time = nil,
    end_time = nil,
    duration_ms = 0,
    first_token_ms = nil,
  },
}

APIHandler.HARD_SIZE_LIMIT = 10e6

local timer = loop.new_timer()
timer:start(
  0,
  25,
  vim.schedule_wrap(function()
    if APIHandler.wants_polling then
      APIHandler:poll_once()
    end
  end)
)

function APIHandler:start_binary()
  self.is_active = true
  self.last_text = nil
  self.last_path = nil
  self.last_context = nil
  self.wants_polling = false
  log:info("API handler started")
end

function APIHandler:is_running()
  return self.is_active
end

function APIHandler:stop_binary()
  self.is_active = false
  if self.active_request then
    -- Try to kill the active request
    pcall(function()
      self.active_request:kill(loop.constants.SIGTERM)
    end)
    self.active_request = nil
  end
  log:info("API handler stopped")
end

---@param buffer integer
---@param file_name string
---@param event_type "text_changed" | "cursor"
function APIHandler:on_update(buffer, file_name, event_type)
  if config.ignore_filetypes[vim.bo.ft] or vim.tbl_contains(config.ignore_filetypes, vim.bo.filetype) then
    return
  end

  local buffer_text = u.get_text(buffer)
  local file_path = api.nvim_buf_get_name(buffer)

  if #buffer_text > self.HARD_SIZE_LIMIT then
    log:warn("File is too large to send to API. Skipping...")
    return
  end

  local cursor = api.nvim_win_get_cursor(0)
  local completion_is_allowed = (buffer_text ~= self.last_text) and (self.last_path == file_name)

  local context = {
    document_text = buffer_text,
    cursor = cursor,
    file_name = file_name,
  }

  if completion_is_allowed then
    self:provide_inline_completion_items(buffer, cursor, context)
  elseif not self:same_context(context) then
    preview:dispose_inlay()
  end

  self.last_path = file_name
  self.last_text = buffer_text
  self.last_context = context
end

function APIHandler:same_context(context)
  if self.last_context == nil then
    return false
  end
  return context.cursor[1] == self.last_context.cursor[1]
    and context.cursor[2] == self.last_context.cursor[2]
    and context.file_name == self.last_context.file_name
    and context.document_text == self.last_context.document_text
end

function APIHandler:purge_old_states()
  for state_id, _ in pairs(self.state_map) do
    if state_id < self.current_state_id - self.max_state_id_retention then
      self.state_map[state_id] = nil
    end
  end
end

function APIHandler:provide_inline_completion_items(buffer, cursor, context)
  self.buffer = buffer
  self.cursor = cursor
  self.last_context = context
  self.last_provide_time = loop.now()
  self:poll_once()
end

function APIHandler:poll_once()
  if config.ignore_filetypes[vim.bo.ft] or vim.tbl_contains(config.ignore_filetypes, vim.bo.filetype) then
    return
  end

  local now = loop.now()
  if now - self.last_provide_time > 5 * 1000 then
    self.wants_polling = false
    return
  end

  self.wants_polling = true
  local buffer = self.buffer
  local cursor = self.cursor

  if not api.nvim_buf_is_valid(buffer) then
    self.wants_polling = false
    return
  end

  local text_split = u.get_text_before_after_cursor(cursor)
  local line_before_cursor = text_split.text_before_cursor
  local line_after_cursor = text_split.text_after_cursor

  if line_before_cursor == nil or line_after_cursor == nil then
    return
  end

  local status, prefix = pcall(u.get_cursor_prefix, buffer, cursor)
  if not status then
    return
  end

  local get_following_line = function(index)
    return u.safe_get_line(buffer, cursor[1] + index) or ""
  end

  -- Get current file info
  local file_path = api.nvim_buf_get_name(buffer)
  local buffer_text = u.get_text(buffer)

  local query_state_id = self:submit_query(buffer, prefix, file_path, buffer_text)
  if query_state_id == nil then
    return
  end

  local maybe_completion =
    self:check_state(prefix, line_before_cursor, line_after_cursor, false, get_following_line, query_state_id, nil)

  if maybe_completion == nil then
    preview:dispose_inlay()
    return
  end

  if maybe_completion.kind == "jump" or maybe_completion.kind == "delete" or maybe_completion.kind == "skip" then
    return
  end

  self.wants_polling = maybe_completion.is_incomplete

  if
    maybe_completion.dedent == nil
    or (#maybe_completion.dedent > 0 and not u.ends_with(line_before_cursor, maybe_completion.dedent))
  then
    return
  end

  while
    #maybe_completion.dedent > 0
    and #maybe_completion.text > 0
    and maybe_completion.dedent:sub(1, 1) == maybe_completion.text:sub(1, 1)
  do
    maybe_completion.text = maybe_completion.text:sub(2)
    maybe_completion.dedent = maybe_completion.dedent:sub(2)
  end

  local prior_delete = #maybe_completion.dedent
  maybe_completion.text = u.trim_end(maybe_completion.text)
  preview:render_with_inlay(buffer, prior_delete, maybe_completion.text, line_after_cursor, line_before_cursor)
end

---@param bufnr integer
---@param prefix string
---@param file_path string
---@param buffer_text string
---@return integer | nil
function APIHandler:submit_query(bufnr, prefix, file_path, buffer_text)
  self:purge_old_states()

  local offset = #prefix

  -- Check if we already have this exact state
  if self.last_state ~= nil then
    if
      self.last_state.cursor_offset == offset
      and self.last_state.file_path == file_path
      and self.last_state.content == buffer_text
    then
      return self.current_state_id
    end
  end

  self.current_state_id = self.current_state_id + 1
  local state_id = self.current_state_id

  -- Create state entry
  self.state_map[state_id] = {
    prefix = prefix,
    completion = {},
    has_ended = false,
  }

  self.last_state = {
    cursor_offset = offset,
    file_path = file_path,
    content = buffer_text,
  }

  -- Make API request
  self:request_completion(state_id, file_path, buffer_text, offset)

  return state_id
end

function APIHandler:request_completion(state_id, file_path, buffer_text, cursor_offset)
  -- Cancel any active request
  if self.active_request then
    pcall(function()
      self.active_request:kill(loop.constants.SIGTERM)
    end)
    self.active_request = nil
  end

  -- Build the API request
  local api_url = config.api.url or "https://api.openai.com/v1/chat/completions"
  local api_key = config.api.api_key or ""
  local model = config.api.model or "gpt-3.5-turbo"
  local max_tokens = config.api.max_tokens or 100
  local temperature = config.api.temperature or 0.2

  -- Get change history if context tracking is enabled
  local change_history = context_tracker.is_enabled() and context_tracker.get_formatted_history() or nil

  -- Get treesitter context if enabled
  local treesitter_context = nil
  if treesitter_extractor.is_enabled() then
    -- Determine language from file extension
    local file_ext = file_path:match("%.([^%.]+)$")
    local lang_map = {
      ts = "typescript",
      tsx = "tsx",
      js = "javascript",
      jsx = "javascriptreact",
      lua = "lua",
      py = "python",
      go = "go",
    }
    local lang = lang_map[file_ext] or file_ext

    treesitter_context = treesitter_extractor.extract_context(self.buffer, file_path, lang, self.cursor)
  end

  local messages =
    prompt_builder.build_completion_prompt(file_path, buffer_text, cursor_offset, change_history, treesitter_context)

  local headers = {
    ["Authorization"] = "Bearer " .. api_key,
  }

  local body = {
    model = model,
    messages = messages,
    stream = true,
    max_tokens = max_tokens,
    temperature = temperature,
  }

  local extra_params = config.api.extra_params
  if type(extra_params) == "table" and next(extra_params) ~= nil then
    body = vim.tbl_deep_extend("force", {}, body, extra_params)
  end

  -- Initialize metrics for this request
  local start_time = loop.now()
  local first_token_time = nil
  local accumulated_text = ""

  -- Calculate input character count from messages
  local input_char_count = 0
  for _, message in ipairs(messages) do
    if message.content then
      input_char_count = input_char_count + #message.content
    end
  end

  local on_chunk = function(delta_content)
    -- Track first token timing
    if first_token_time == nil then
      first_token_time = loop.now()
      self.last_completion_metrics.first_token_ms = first_token_time - start_time
    end

    accumulated_text = accumulated_text .. delta_content

    -- Update the state with the new text
    local state = self.state_map[state_id]
    if state then
      state.completion = {
        { kind = "text", text = accumulated_text },
      }
    end
  end

  local on_done = function()
    local end_time = loop.now()

    -- Update metrics
    local output_char_count = #accumulated_text
    self.last_completion_metrics = {
      token_count = vim.split(accumulated_text, "%s+", { trimempty = true }) and #vim.split(accumulated_text, "%s+", { trimempty = true }) or 0,
      char_count = input_char_count + output_char_count,
      input_char_count = input_char_count,
      output_char_count = output_char_count,
      start_time = start_time,
      end_time = end_time,
      duration_ms = end_time - start_time,
      first_token_ms = first_token_time and (first_token_time - start_time) or 0,
    }

    local state = self.state_map[state_id]
    if state then
      -- Add finish marker
      table.insert(state.completion, { kind = "finish_edit" })
      state.has_ended = true
    end
    self.active_request = nil
  end

  local on_error = function(error_msg)
    log:error("API request failed: " .. error_msg)
    preview:dispose_inlay()
    self.active_request = nil

    -- Mark state as ended even on error
    local state = self.state_map[state_id]
    if state then
      state.has_ended = true
    end
  end

  self.active_request = http_client.stream_post(api_url, headers, body, on_chunk, on_done, on_error)
end

---@param prefix string
---@param line_before_cursor string
---@param line_after_cursor string
---@param can_retry boolean
---@param get_following_line fun(line: string): string
---@param query_state_id integer
---@param cached_chain_info any
---@return any
function APIHandler:check_state(
  prefix,
  line_before_cursor,
  line_after_cursor,
  can_retry,
  get_following_line,
  query_state_id,
  cached_chain_info
)
  local params = {
    line_before_cursor = line_before_cursor,
    line_after_cursor = line_after_cursor,
    get_following_line = get_following_line,
    dust_strings = {},
    can_show_partial_line = true,
    can_retry = can_retry,
    source_state_id = query_state_id,
  }

  local best_completion = {}
  local best_length = 0
  local best_state_id = -1

  for state_id, state in pairs(self.state_map) do
    local state_prefix = state.prefix
    if state_prefix ~= nil and #prefix >= #state_prefix then
      if string.sub(prefix, 1, #state_prefix) == state_prefix then
        local user_input = prefix:sub(#state_prefix + 1)
        local remaining_completion = self:strip_prefix(state.completion, user_input)

        if remaining_completion ~= nil then
          local total_length = self:completion_text_length(remaining_completion)
          if total_length > best_length or (total_length == best_length and state_id > best_state_id) then
            best_completion = remaining_completion
            best_length = total_length
            best_state_id = state_id
          end
        end
      end
    end
  end

  return textual.derive_completion(best_completion, params)
end

function APIHandler:completion_text_length(completion)
  local length = 0
  for _, response_item in ipairs(completion) do
    if response_item.kind == "text" then
      length = length + #response_item.text
    end
  end
  return length
end

---@param completion table[]
---@param original_prefix string
---@return table[] | nil
function APIHandler:strip_prefix(completion, original_prefix)
  local prefix = original_prefix
  local remaining_response_item = {}

  for _, response_item in ipairs(completion) do
    if response_item.kind == "text" then
      local text = response_item.text
      if not self:shares_common_prefix(text, prefix) then
        return nil
      end

      local trim_length = math.min(#text, #prefix)
      text = text:sub(trim_length + 1)
      prefix = prefix:sub(trim_length + 1)

      if #text > 0 then
        table.insert(remaining_response_item, {
          kind = "text",
          text = text,
        })
      end
    else
      if #prefix == 0 then
        table.insert(remaining_response_item, response_item)
      end
    end
  end

  return remaining_response_item
end

function APIHandler:shares_common_prefix(str1, str2)
  local min_length = math.min(#str1, #str2)
  if str1:sub(1, min_length) ~= str2:sub(1, min_length) then
    return false
  end
  return true
end

-- Stub functions for compatibility with binary_handler interface
function APIHandler:use_free_version()
  log:warn("use_free_version is not supported in API mode")
end

function APIHandler:use_pro()
  log:warn("use_pro is not supported in API mode")
end

function APIHandler:logout()
  log:warn("logout is not supported in API mode")
end

function APIHandler:show_activation_message()
  -- Not applicable for API mode
end

function APIHandler:get_last_completion_metrics()
  return self.last_completion_metrics
end

return APIHandler
