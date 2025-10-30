# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with the SuperTab repository.

## Project Overview

SuperTab is a Neovim plugin that delivers AI code completions (backed by the Supermaven service). The plugin can operate in two modes:

1. **Binary Mode** (default): Talks directly to the local `sm-agent` binary via stdio.
2. **API Mode**: Streams completions from an OpenAI-compatible HTTP endpoint.

SuperTab renders inline “ghost text” suggestions with extmarks and also exposes a `cmp` source for completion menus.

> **Compatibility note:** The project was previously named `supermaven-nvim`. Compatibility shims keep the legacy module/command names working, but new code should use the `supertab` namespace.

## Configuration

### Basic Setup (Binary Mode)
```lua
require("supertab").setup({})
```

### API Mode (OpenAI-Compatible)
```lua
require("supertab").setup({
  api = {
    url = "https://api.openai.com/v1/chat/completions",
    api_key = "sk-...",
    model = "gpt-3.5-turbo",
    max_tokens = 100,
    temperature = 0.2,
    extra_params = {}, -- optional provider-specific payload
  },
})
```

API mode automatically activates when `api.api_key` (or another explicit setting) is provided. Otherwise the binary handler is used.

## Code Style

- Format Lua with `stylua` (`stylua .` – config in `.stylua.toml`).
- Two-space indentation, Unix line endings, prefer double quotes.

## Architecture Overview

### Core Modules (under `lua/supertab/`)

- **`init.lua`** – Entry point, applies config, registers commands/keymaps, starts the selected handler.
- **`config.lua`** – Default options and config merging (`supertab.config`).
- **`handler_factory.lua`** – Decides between binary/API handler and caches the instance.
- **`completion_preview.lua`** – Inline suggestion rendering via extmarks (`virt_text` / `virt_lines`).
- **`commands.lua`** – User commands (`:SuperTabStart`, etc.) with legacy aliases (`:Supermaven*`).
- **`document_listener.lua`** – Autocommands for buffer/cursor changes, plus conditional enablement.
- **`context_tracker.lua`** – Keeps lightweight change history for request prompts.
- **`cmp.lua`** – nvim-cmp source (names `supertab` and legacy `supermaven`).
- **`logger.lua` / `message_logger.lua`** – Persistent logging helpers (`supertab.log`, `supertab-messages.log`).
- **`binary/binary_handler.lua`** – Manages the `sm-agent` process and JSON protocol.
- **`binary/binary_fetcher.lua`** – Downloads/caches the platform-specific binary (`~/.supertab/...`).
- **`api/api_handler.lua`** – Mirrors the binary handler interface using streaming HTTP (`http_client.lua`).
- **`treesitter/context_extractor.lua`** – Builds contextual snippets using Tree-sitter + LSP definition lookups, now trimmed to imported ranges.

### Key Patterns

- **State Management** – Handlers cache completion states keyed by cursor prefix. `check_state()` strips user-typed text to reuse cached responses.
- **Polling Loop** – Binary handler keeps a timer that polls every 25 ms until results arrive or a 5 s timeout elapses.
- **Inline Editing** – Accepting a suggestion deletes `prior_delete` characters and applies the new text via `vim.lsp.util.apply_text_edits` for multiline safety.
- **Context Refresh** – Tree-sitter import discovery now invokes `textDocument/definition` asynchronously. Resolved files are cached, and only the relevant ranges are sent.
- **Compatibility** – All Lua modules and commands under the old `supermaven-nvim` namespace are aliased to the new equivalents.

## Testing & Debugging Tips

- Use a minimal Neovim config to sanity-check completions in various filetypes.
- Increase verbosity with `require("supertab").setup({ log_level = "trace" })`.
- Logs live in `stdpath('cache')/supertab.log`; protocol dumps in `supertab-messages.log`.
- Commands `:SuperTabShowLog`, `:SuperTabClearLog`, `:SuperTabShowMessages`, `:SuperTabClearMessages` manage logs; the `Supermaven*` variants still exist but are deprecated.
- Ensure buffers are valid before mutating (`nvim_buf_is_valid`) and guard extmark operations.

## Command Reference

New command names:

- `:SuperTabStart` / `:SuperTabStop` / `:SuperTabRestart` / `:SuperTabToggle`
- `:SuperTabStatus`
- `:SuperTabUseFree` / `:SuperTabUsePro`
- `:SuperTabLogout`
- `:SuperTabShowLog` / `:SuperTabClearLog`
- `:SuperTabShowMessages` / `:SuperTabClearMessages`

Legacy `Supermaven*` commands forward to the new ones with a warning.

## Lua API

```lua
local api = require("supertab.api")
api.start()
api.stop()
api.restart()
api.toggle()
api.is_running()
api.use_free_version()
api.use_pro()
api.logout()
api.show_log()
api.clear_log()
```

`require("supermaven-nvim.api")` remains valid and returns the same table.

## Implementation Reminders

- Inline previews use the `SuperTabSuggestion` highlight group (linking to `Comment` by default).
- nvim-cmp source registers as `supertab` with highlight `CmpItemKindSuperTab`.
- Tree-sitter contexts fall back to raw file content when LSP location ranges are unavailable.
- Binary downloads now live under `~/.supertab` (falling back to `~/.supermaven` if already present).
- Respect `vim.g.SUPERTAB_DISABLED` (and the legacy global) when deciding whether to update state.

Keep these conventions in mind when making changes or guiding automated updates.
