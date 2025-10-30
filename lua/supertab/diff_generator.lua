local M = {}

---Split text into lines
---@param text string
---@return string[]
local function split_lines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  return lines
end

---Generate a simple unified diff between two texts
---@param before_text string Original text
---@param after_text string Modified text
---@param file_path string File path for diff header
---@param max_lines integer|nil Maximum lines in diff (nil = no limit)
---@return string|nil Unified diff string, or nil if no changes
function M.generate_unified_diff(before_text, after_text, file_path, max_lines)
  -- Quick check: if texts are identical, return nil
  if before_text == after_text then
    return nil
  end

  local before_lines = split_lines(before_text)
  local after_lines = split_lines(after_text)

  -- Build a simple diff
  local diff_lines = {}

  -- Add diff header
  table.insert(diff_lines, "--- a/" .. file_path)
  table.insert(diff_lines, "+++ b/" .. file_path)

  -- Simple approach: show removed lines then added lines
  local has_changes = false

  -- Find first and last line that differs
  local first_diff = 1
  local last_diff_before = #before_lines
  local last_diff_after = #after_lines

  -- Find first difference
  while first_diff <= math.min(#before_lines, #after_lines) and before_lines[first_diff] == after_lines[first_diff] do
    first_diff = first_diff + 1
  end

  -- If no differences found, return nil
  if first_diff > math.max(#before_lines, #after_lines) then
    return nil
  end

  -- Add hunk header (simplified)
  local context_start = math.max(1, first_diff - 2)
  table.insert(
    diff_lines,
    string.format("@@ -%d +%d @@", context_start, context_start)
  )

  -- Add context lines before change
  for i = context_start, first_diff - 1 do
    table.insert(diff_lines, " " .. (before_lines[i] or ""))
  end

  -- Show removed lines
  for i = first_diff, #before_lines do
    if before_lines[i] ~= (after_lines[i] or "") then
      table.insert(diff_lines, "-" .. before_lines[i])
      has_changes = true
    end
  end

  -- Show added lines
  for i = first_diff, #after_lines do
    if after_lines[i] ~= (before_lines[i] or "") then
      table.insert(diff_lines, "+" .. after_lines[i])
      has_changes = true
    end
  end

  -- Add context after (a few lines)
  local context_end = math.min(#after_lines, first_diff + 10)
  for i = math.max(#before_lines, #after_lines) + 1, context_end do
    if after_lines[i] then
      table.insert(diff_lines, " " .. after_lines[i])
    end
  end

  -- Apply max_lines limit if specified
  if max_lines and #diff_lines > max_lines then
    diff_lines = vim.list_slice(diff_lines, 1, max_lines)
    table.insert(diff_lines, "... (truncated)")
  end

  -- Return nil if no actual changes
  if not has_changes or #diff_lines <= 3 then
    return nil
  end

  return table.concat(diff_lines, "\n")
end

return M
