local log = require("supertab.logger")
local msg_log = require("supertab.message_logger")

local M = {}

---Parse SSE (Server-Sent Events) data chunk
---@param chunk string Raw SSE chunk
---@return table|nil Parsed JSON data or nil
local function parse_sse_chunk(chunk)
  -- SSE format: "data: {...}\n\n"
  local data = chunk:match("data: (.*)")
  if not data or data == "[DONE]" then
    return nil
  end

  local ok, parsed = pcall(vim.json.decode, data)
  if ok then
    return parsed
  else
    log:warn("Failed to parse SSE chunk: " .. data)
    return nil
  end
end

---Make a streaming POST request to OpenAI-compatible API
---@param url string API endpoint URL
---@param headers table HTTP headers
---@param body table Request body (will be JSON encoded)
---@param on_chunk function Callback for each streaming chunk: function(delta_content)
---@param on_done function Callback when stream is complete
---@param on_error function Callback on error: function(error_message)
function M.stream_post(url, headers, body, on_chunk, on_done, on_error)
  -- Log the outgoing request
  msg_log.log_outgoing({
    url = url,
    headers = headers,
    body = body,
  })

  local json_body = vim.json.encode(body)

  -- Build curl command for streaming
  local curl_args = {
    "curl",
    "-s", -- Silent
    "-N", -- No buffering
    "--no-buffer",
    "-X", "POST",
    url,
    "-H", "Content-Type: application/json",
  }

  -- Add headers
  for key, value in pairs(headers) do
    table.insert(curl_args, "-H")
    table.insert(curl_args, key .. ": " .. value)
  end

  -- Add body
  table.insert(curl_args, "-d")
  table.insert(curl_args, json_body)

  local buffer = ""

  -- Start the streaming request
  local job = vim.system(curl_args, {
    stdout = function(err, data)
      if err then
        vim.schedule(function()
          on_error("stdout error: " .. err)
        end)
        return
      end

      if data then
        buffer = buffer .. data

        -- Process complete SSE messages (ending with \n\n)
        while true do
          local end_pos = buffer:find("\n\n")
          if not end_pos then
            break
          end

          local message = buffer:sub(1, end_pos - 1)
          buffer = buffer:sub(end_pos + 2)

          if message ~= "" then
            local parsed = parse_sse_chunk(message)
            if parsed then
              -- Log the incoming chunk
              msg_log.log_incoming(parsed)

              -- Extract delta content from OpenAI format
              if parsed.choices and parsed.choices[1] and parsed.choices[1].delta then
                local delta = parsed.choices[1].delta
                local content = delta.content
                local has_data = content or parsed.usage

                if has_data then
                  vim.schedule(function()
                    on_chunk(content, parsed.usage)
                  end)
                end
              -- Handle chunks that only have usage (no choices array)
              elseif parsed.usage then
                vim.schedule(function()
                  on_chunk(nil, parsed.usage)
                end)
              end
            elseif message:match("data: %[DONE%]") then
              vim.schedule(function()
                on_done()
              end)
              return
            end
          end
        end
      end
    end,
    stderr = function(err, data)
      if data then
        log:warn("curl stderr: " .. data)
      end
    end,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local error_msg = "HTTP request failed with code " .. result.code
        if result.stderr then
          error_msg = error_msg .. ": " .. result.stderr
        end
        on_error(error_msg)
      else
        on_done()
      end
    end)
  end)

  return job
end

return M
