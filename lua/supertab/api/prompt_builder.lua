local M = {}

---Inserts a cursor marker in the text at the given offset
---@param text string The full file content
---@param offset integer Character offset where cursor is located
---@return string Text with <|cursor|> marker inserted
local function insert_cursor_marker(text, offset)
  if offset < 0 or offset > #text then
    return text
  end

  local before = text:sub(1, offset)
  local after = text:sub(offset + 1)
  return before .. "<|cursor|>" .. after
end

---Builds OpenAI chat completion messages for code completion
---@param file_path string Path to the file
---@param file_content string Content of the file
---@param cursor_offset integer Character offset of cursor position
---@param change_history string|nil Optional formatted change history
---@param treesitter_context string|nil Optional treesitter extracted context
---@return table OpenAI messages array
function M.build_completion_prompt(file_path, file_content, cursor_offset, change_history, treesitter_context)
  -- Handle nil content gracefully
  if not file_content then
    file_content = ""
  end

  local content_with_cursor = insert_cursor_marker(file_content, cursor_offset)

  -- Extract file extension for context
  local file_ext = file_path:match("%.([^%.]+)$") or ""
  local language = file_ext

  -- Build the messages
  local messages = {
    {
      role = "system",
      content = "You are an expert code completion assistant. Complete the code at the <|cursor|> position. "
        .. "Only return the completion text that should be inserted at the cursor position. "
        .. "Do not include the code before the cursor. "
        .. "Do not include explanations or markdown formatting. "
        .. "Return only the raw code completion."
    },
  }

  -- Add change history if provided
  if change_history and change_history ~= "" then
    table.insert(messages, {
      role = "user",
      content = change_history
    })
  end

  -- Add treesitter context if provided
  if treesitter_context and treesitter_context ~= "" then
    table.insert(messages, {
      role = "user",
      content = treesitter_context
    })
  end

  -- Add the current code
  table.insert(messages, {
    role = "user",
    content = string.format("Complete the %s code at <|cursor|>:\n\n%s", language, content_with_cursor)
  })

  return messages
end

---Extracts just the completion part from API response
---Some models may include context, we only want the new part
---@param completion string The full completion text from API
---@param original_text string The original text before cursor
---@return string The cleaned completion text
function M.clean_completion(completion, original_text)
  -- Remove any markdown code blocks
  completion = completion:gsub("^```%w*\n", ""):gsub("\n```$", "")

  -- Trim leading/trailing whitespace from the completion
  -- but preserve internal structure
  completion = completion:match("^%s*(.-)%s*$") or completion

  return completion
end

return M
