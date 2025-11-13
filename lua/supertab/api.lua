local handler_factory = require("supertab.handler_factory")
local listener = require("supertab.document_listener")
local log = require("supertab.logger")
local u = require("supertab.util")

local loop = u.uv

local M = {}

M.is_running = function()
  local handler = handler_factory.get_handler()
  return handler:is_running()
end

M.start = function()
  if M.is_running() then
    log:warn("Completion handler is already running.")
    return
  else
    log:trace("Starting completion handler...")
  end
  vim.g.SUPERTAB_DISABLED = 0
  vim.g.SUPERMAVEN_DISABLED = 0
  local handler = handler_factory.get_handler()
  handler:start_binary()
  listener.setup()
end

M.stop = function()
  vim.g.SUPERTAB_DISABLED = 1
  vim.g.SUPERMAVEN_DISABLED = 1
  if not M.is_running() then
    log:warn("Completion handler is not running.")
    return
  else
    log:trace("Stopping completion handler...")
  end
  listener.teardown()
  local handler = handler_factory.get_handler()
  handler:stop_binary()
end

M.restart = function()
  if M.is_running() then
    M.stop()
  end
  M.start()
end

M.toggle = function()
  if M.is_running() then
    M.stop()
  else
    M.start()
  end
end

M.use_free_version = function()
  local handler = handler_factory.get_handler()
  handler:use_free_version()
end

M.use_pro = function()
  local handler = handler_factory.get_handler()
  handler:use_pro()
end

M.logout = function()
  local handler = handler_factory.get_handler()
  handler:logout()
end

M.show_log = function()
  local log_path = log:get_log_path()
  if log_path ~= nil then
    vim.cmd.tabnew()
    vim.cmd(string.format(":e %s", log_path))
  else
    log:warn("No log file found to show!")
  end
end

M.clear_log = function()
  local log_path = log:get_log_path()
  if log_path ~= nil then
    loop.fs_unlink(log_path)
  else
    log:warn("No log file found to remove!")
  end
end

M.get_completion_metrics = function()
  local handler = handler_factory.get_handler()
  if handler.get_last_completion_metrics then
    return handler:get_last_completion_metrics()
  end
  return {
    token_count = 0,
    char_count = 0,
    start_time = nil,
    end_time = nil,
    duration_ms = 0,
    first_token_ms = nil,
  }
end

return M
