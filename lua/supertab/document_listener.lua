local handler_factory = require("supertab.handler_factory")
local preview = require("supertab.completion_preview")
local config = require("supertab.config")
local context_tracker = require("supertab.context_tracker")
local treesitter_extractor = require("supertab.treesitter.context_extractor")

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
    callback = function(event)
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

      -- Proactively warm treesitter context cache when entering a buffer
      if treesitter_extractor.is_enabled() then
        local bufnr = event.buf
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          local file_path = vim.api.nvim_buf_get_name(bufnr)
          if file_path and file_path ~= "" then
            -- Defer to not interfere with buffer opening
            vim.defer_fn(function()
              if vim.api.nvim_buf_is_valid(bufnr) then
                treesitter_extractor.warm_cache(bufnr, file_path, nil)
              end
            end, 200)
          end
        end
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

      -- Warm treesitter context cache after editing session
      if treesitter_extractor.is_enabled() then
        local file_path = vim.api.nvim_buf_get_name(bufnr)
        if file_path and file_path ~= "" then
          vim.defer_fn(function()
            treesitter_extractor.warm_cache(bufnr, file_path, nil)
          end, 100)
        end
      end
    end,
  })

  -- Refresh cache after saving (dependencies may have changed)
  vim.api.nvim_create_autocmd({ "BufWritePost" }, {
    group = M.augroup,
    callback = function(event)
      if not treesitter_extractor.is_enabled() then
        return
      end

      local bufnr = event.buf
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end

      local file_path = vim.api.nvim_buf_get_name(bufnr)
      if not file_path or file_path == "" then
        return
      end

      -- Defer slightly to not interfere with save operations
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          treesitter_extractor.warm_cache(bufnr, file_path, nil)
        end
      end, 100)
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
