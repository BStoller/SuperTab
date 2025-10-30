local default_config = {
  keymaps = {
    accept_suggestion = "<Tab>",
    clear_suggestion = "<C-]>",
    accept_word = "<C-j>",
  },
  ignore_filetypes = {},
  disable_inline_completion = false,
  disable_keymaps = false,
  condition = function()
    return false
  end,
  log_level = "info",
  -- API mode configuration
  api = {
    url = "https://api.openai.com/v1/chat/completions",
    api_key = "",
    model = "gpt-3.5-turbo",
    max_tokens = 100,
    temperature = 0.2,
    extra_params = {},
    -- Context enrichment for API completions
    context = {
      enabled = true, -- Enable/disable context tracking
      max_changes = 5, -- Keep last N changes in history
      max_diff_lines = 50, -- Limit diff size per change
      include_timestamps = false, -- Show when changes were made
      -- Treesitter context extraction (currently disabled due to Neovim 0.11.0 compatibility issues)
      treesitter = {
        enabled = true, -- Enable/disable treesitter context
        max_depth = 2, -- How deep to follow imports (0-3)
        max_files = 20, -- Maximum files to parse
        max_lines_per_file = 200, -- Truncate large definitions
        symbol_details = {
          max_imports = 20,
          max_functions = 20,
          max_variables = 20,
          max_types = 10,
        },
      },
    },
  },
}

local M = {
  config = vim.deepcopy(default_config),
}

M.setup = function(args)
  local log = require("supermaven-nvim.logger")
  log:debug("=== CONFIG SETUP ===")
  log:debug("Received args: " .. vim.inspect(args))
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), args)
  log:debug("Final config: " .. vim.inspect(M.config))
end

return setmetatable(M, {
  __index = function(_, key)
    if key == "setup" then
      return M.setup
    end
    return rawget(M.config, key)
  end,
})
