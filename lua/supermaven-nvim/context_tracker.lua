local config = require("supermaven-nvim.config")
local diff_generator = require("supermaven-nvim.diff_generator")
local log = require("supermaven-nvim.logger")
local u = require("supermaven-nvim.util")

local M = {
  -- Buffer snapshots: buffer_id -> {text, file_path, timestamp}
  buffer_snapshots = {},

  -- Change history: circular buffer of recent changes
  change_history = {},
}

---Capture a snapshot of the current buffer before editing
---@param bufnr integer Buffer number
function M.capture_snapshot(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local file_path = vim.api.nvim_buf_get_name(bufnr)

  -- Skip if no file path or special buffers
  if not file_path or file_path == "" or vim.bo[bufnr].buftype ~= "" then
    return
  end

  local text = u.get_text(bufnr)

  M.buffer_snapshots[bufnr] = {
    text = text,
    file_path = file_path,
    timestamp = os.time(),
  }

  log:debug("Captured snapshot for buffer " .. bufnr .. ": " .. file_path)
end

---Generate and record a change diff when exiting insert mode
---@param bufnr integer Buffer number
function M.record_change(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Check if we have a snapshot for this buffer
  local snapshot = M.buffer_snapshots[bufnr]
  if not snapshot then
    log:debug("No snapshot found for buffer " .. bufnr)
    return
  end

  local current_text = u.get_text(bufnr)
  local file_path = vim.api.nvim_buf_get_name(bufnr)

  -- Generate diff
  local max_diff_lines = config.api and config.api.context and config.api.context.max_diff_lines or 50
  local diff = diff_generator.generate_unified_diff(snapshot.text, current_text, file_path, max_diff_lines)

  -- Clear the snapshot
  M.buffer_snapshots[bufnr] = nil

  -- If no diff, don't add to history
  if not diff then
    log:debug("No changes detected for buffer " .. bufnr)
    return
  end

  -- Add to change history
  local change = {
    file_path = file_path,
    timestamp = os.time(),
    diff = diff,
  }

  table.insert(M.change_history, change)

  -- Maintain circular buffer (keep only last N changes)
  local max_changes = config.api and config.api.context and config.api.context.max_changes or 5
  while #M.change_history > max_changes do
    table.remove(M.change_history, 1) -- Remove oldest
  end

  log:debug("Recorded change for " .. file_path .. " (" .. #M.change_history .. " changes in history)")
end

---Get formatted change history for inclusion in prompts
---@return string Formatted change history
function M.get_formatted_history()
  if #M.change_history == 0 then
    return ""
  end

  local include_timestamps = config.api and config.api.context and config.api.context.include_timestamps or false
  local lines = { "Recent code changes:" }

  for i, change in ipairs(M.change_history) do
    table.insert(lines, "")
    if include_timestamps then
      local time_ago = os.time() - change.timestamp
      local time_str = time_ago < 60 and time_ago .. "s ago"
        or time_ago < 3600 and math.floor(time_ago / 60) .. "m ago"
        or math.floor(time_ago / 3600) .. "h ago"
      table.insert(lines, string.format("Change %d: %s (%s)", i, change.file_path, time_str))
    else
      table.insert(lines, string.format("Change %d: %s", i, change.file_path))
    end
    table.insert(lines, change.diff)
  end

  return table.concat(lines, "\n")
end

---Check if context tracking is enabled
---@return boolean
function M.is_enabled()
  return config.api and config.api.context and config.api.context.enabled ~= false
end

---Clear all tracking data
function M.clear()
  M.buffer_snapshots = {}
  M.change_history = {}
  log:debug("Cleared context tracker")
end

return M
