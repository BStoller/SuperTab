local handler_factory = require("supertab.handler_factory")
local preview = require("supertab.completion_preview")
local config = require("supertab.config")
local context_tracker = require("supertab.context_tracker")

local M = {
  augroup = nil,
}

M.setup = function()
  M.augroup = vim.api.nvim_create_augroup("supertab", { clear = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = M.augroup,
    callback = function(event)
      local file_name = event["file"]
      local buffer = event["buf"]
      if not file_name or not buffer then
        return
      end
      local handler = handler_factory.get_handler()
      handler:on_update(buffer, file_name, "text_changed")
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter" }, {
    callback = function(_)
      local ok, api = pcall(require, "supertab.api")
      if not ok then
        return
      end
      local disabled = vim.g.SUPERTAB_DISABLED == 1 or vim.g.SUPERMAVEN_DISABLED == 1
      if config.condition() or disabled then
        if api.is_running() then
          api.stop()
          return
        end
      else
        if api.is_running() then
          return
        end
        api.start()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = M.augroup,
    callback = function(event)
      local file_name = event["file"]
      local buffer = event["buf"]
      if not file_name or not buffer then
        return
      end
      local handler = handler_factory.get_handler()
      handler:on_update(buffer, file_name, "cursor")
    end,
  })

  vim.api.nvim_create_autocmd({ "InsertEnter" }, {
    group = M.augroup,
    callback = function(event)
      local bufnr = event.buf
      if context_tracker.is_enabled() then
        context_tracker.capture_snapshot(bufnr)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "InsertLeave" }, {
    group = M.augroup,
    callback = function(event)
      preview:dispose_inlay()

      local bufnr = event.buf
      if context_tracker.is_enabled() then
        context_tracker.record_change(bufnr)
      end
    end,
  })

  -- Default highlight linking for suggestions
  vim.api.nvim_set_hl(0, "SuperTabSuggestion", { link = "Comment" })
  vim.api.nvim_set_hl(0, "SupermavenSuggestion", { link = "SuperTabSuggestion" })

  if config.color and config.color.suggestion_color and config.color.cterm then
    vim.api.nvim_create_autocmd({ "VimEnter", "ColorScheme" }, {
      group = M.augroup,
      pattern = "*",
      callback = function(event)
        local group = "SuperTabSuggestion"
        vim.api.nvim_set_hl(0, group, {
          fg = config.color.suggestion_color,
          ctermfg = config.color.cterm,
        })
        preview.suggestion_group = group
        -- Maintain backwards compatibility
        vim.api.nvim_set_hl(0, "SupermavenSuggestion", { link = group })
      end,
    })
  end
end

M.teardown = function()
  if M.augroup ~= nil then
    vim.api.nvim_del_augroup_by_id(M.augroup)
    M.augroup = nil
  end
end

return M
