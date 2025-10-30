local config = require("supertab.config")
local log = require("supertab.logger")

local M = {}

-- Cache the handler so we only create it once
local cached_handler = nil

---@return table The selected handler (binary_handler or api_handler)
function M.get_handler()
  -- Return cached handler if already created
  if cached_handler then
    return cached_handler
  end

  log:debug("=== HANDLER FACTORY ===")
  log:debug("config.api exists: " .. tostring(config.api ~= nil))
  if config.api then
    log:debug("config.api.api_key: " .. tostring(config.api.api_key))
    log:debug("config.api.url: " .. tostring(config.api.url))
  end

  -- Check if API mode should be used
  -- Only use API mode if api_key is actually set (not empty)
  local use_api = config.api and config.api.api_key and config.api.api_key ~= ""
  log:debug("use_api decision: " .. tostring(use_api))

  if use_api then
    log:info("Using API mode for completions")
    cached_handler = require("supertab.api.api_handler")
  else
    log:info("Using Supermaven binary mode for completions")
    cached_handler = require("supertab.binary.binary_handler")
  end

  return cached_handler
end

return M
