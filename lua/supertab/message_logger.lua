local M = {}

local log_file_path = nil

local function get_log_path()
  if log_file_path == nil then
    local cache_dir = vim.fn.stdpath("cache")
    log_file_path = cache_dir .. "/supertab-messages.log"
  end
  return log_file_path
end

function M.log_outgoing(msg)
  local path = get_log_path()
  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local file = io.open(path, "a")
  if file then
    file:write("\n" .. string.rep("=", 80) .. "\n")
    file:write("OUTGOING @ " .. timestamp .. "\n")
    file:write(string.rep("=", 80) .. "\n")
    file:write(vim.inspect(msg) .. "\n")
    file:close()
  end
end

function M.log_incoming(msg)
  local path = get_log_path()
  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local file = io.open(path, "a")
  if file then
    file:write("\n" .. string.rep("=", 80) .. "\n")
    file:write("INCOMING @ " .. timestamp .. "\n")
    file:write(string.rep("=", 80) .. "\n")
    file:write(vim.inspect(msg) .. "\n")
    file:close()
  end
end

function M.get_log_path()
  return get_log_path()
end

function M.clear_log()
  local path = get_log_path()
  local file = io.open(path, "w")
  if file then
    file:close()
  end
end

return M
