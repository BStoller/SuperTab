local function register_aliases()
  local legacy_prefix = "supermaven-nvim"
  local target_prefix = "supertab"

  local modules = {
    "",
    "config",
    "commands",
    "util",
    "logger",
    "message_logger",
    "completion_preview",
    "handler_factory",
    "document_listener",
    "context_tracker",
    "diff_generator",
    "api",
    "api.api_handler",
    "api.http_client",
    "api.prompt_builder",
    "binary.binary_handler",
    "binary.binary_fetcher",
    "cmp",
    "textual",
    "treesitter.context_extractor",
    "types",
  }

  for _, suffix in ipairs(modules) do
    local legacy_name = legacy_prefix .. (suffix ~= "" and "." .. suffix or "")
    local target_name = target_prefix .. (suffix ~= "" and "." .. suffix or "")

    if package.preload[legacy_name] == nil then
      package.preload[legacy_name] = function()
        local mod = require(target_name)
        package.loaded[legacy_name] = mod
        return mod
      end
    end
  end
end

register_aliases()

return require("supertab")
