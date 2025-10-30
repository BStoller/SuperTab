local api = require("supertab.api")
local log = require("supertab.logger")
local msg_log = require("supertab.message_logger")

local M = {}

local function create_alias(old, new)
  vim.api.nvim_create_user_command(old, function(opts)
    log:warn(string.format("Command :%s is deprecated. Use :%s instead.", old, new))
    local cmd = new
    if opts.args and opts.args ~= "" then
      cmd = cmd .. " " .. opts.args
    end
    vim.cmd(cmd)
  end, { nargs = "*" })
end

M.setup = function()
  vim.api.nvim_create_user_command("SuperTabStart", function()
    api.start()
  end, {})

  vim.api.nvim_create_user_command("SuperTabStop", function()
    api.stop()
  end, {})

  vim.api.nvim_create_user_command("SuperTabRestart", function()
    api.restart()
  end, {})

  vim.api.nvim_create_user_command("SuperTabToggle", function()
    api.toggle()
  end, {})

  vim.api.nvim_create_user_command("SuperTabStatus", function()
    log:trace(string.format("SuperTab is %s", api.is_running() and "running" or "not running"))
  end, {})

  vim.api.nvim_create_user_command("SuperTabShowLog", function()
    api.show_log()
  end, {})

  vim.api.nvim_create_user_command("SuperTabClearLog", function()
    api.clear_log()
  end, {})

  vim.api.nvim_create_user_command("SuperTabShowMessages", function()
    local log_path = msg_log.get_log_path()
    if vim.fn.filereadable(log_path) == 1 then
      vim.cmd.tabnew()
      vim.cmd(string.format(":e %s", log_path))
    else
      log:warn("No message log file found. Messages will be logged to: " .. log_path)
    end
  end, {})

  vim.api.nvim_create_user_command("SuperTabClearMessages", function()
    msg_log.clear_log()
    log:info("Message log cleared")
  end, {})
end

return M
