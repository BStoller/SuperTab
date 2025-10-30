local api = require("supermaven-nvim.api")
local log = require("supermaven-nvim.logger")
local msg_log = require("supermaven-nvim.message_logger")

local M = {}

M.setup = function()
  vim.api.nvim_create_user_command("SupermavenStart", function()
    api.start()
  end, {})

  vim.api.nvim_create_user_command("SupermavenStop", function()
    api.stop()
  end, {})

  vim.api.nvim_create_user_command("SupermavenRestart", function()
    api.restart()
  end, {})

  vim.api.nvim_create_user_command("SupermavenToggle", function()
    api.toggle()
  end, {})

  vim.api.nvim_create_user_command("SupermavenStatus", function()
    log:trace(string.format("Supermaven is %s", api.is_running() and "running" or "not running"))
  end, {})

  vim.api.nvim_create_user_command("SupermavenUseFree", function()
    api.use_free_version()
  end, {})

  vim.api.nvim_create_user_command("SupermavenUsePro", function()
    api.use_pro()
  end, {})

  vim.api.nvim_create_user_command("SupermavenLogout", function()
    api.logout()
  end, {})

  vim.api.nvim_create_user_command("SupermavenShowLog", function()
    api.show_log()
  end, {})

  vim.api.nvim_create_user_command("SupermavenClearLog", function()
    api.clear_log()
  end, {})

  vim.api.nvim_create_user_command("SupermavenShowMessages", function()
    local log_path = msg_log.get_log_path()
    if vim.fn.filereadable(log_path) == 1 then
      vim.cmd.tabnew()
      vim.cmd(string.format(":e %s", log_path))
    else
      log:warn("No message log file found. Messages will be logged to: " .. log_path)
    end
  end, {})

  vim.api.nvim_create_user_command("SupermavenClearMessages", function()
    msg_log.clear_log()
    log:info("Message log cleared")
  end, {})
end

return M
