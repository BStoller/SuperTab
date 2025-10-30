# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

supermaven-nvim is a Neovim plugin that integrates Supermaven AI code completion into Neovim. The plugin communicates with a native binary via stdio, manages inline completion previews using extmarks, and integrates with nvim-cmp for completion menu display.

## Code Style

- Use `stylua` for formatting: `stylua .`
- Configuration in `.stylua.toml`: 2 spaces, Unix line endings, auto-prefer double quotes
- Format all Lua files before committing

## Architecture

### Core Components

**Binary Communication (`lua/supermaven-nvim/binary/`)**
- `binary_handler.lua`: Manages the lifecycle of the Supermaven binary process, handles stdio communication, and processes completion responses
- `binary_fetcher.lua`: Downloads and caches the platform-specific binary
- The binary is spawned as a subprocess with stdio pipes and communicates via JSON messages prefixed with "SM-MESSAGE"
- State management tracks completion requests via incrementing state IDs, with old states purged after 50 retained states

**Completion Preview (`completion_preview.lua`)**
- Renders inline completions using Neovim's extmark API (`nvim_buf_set_extmark`)
- Two rendering modes:
  - **Standard**: Completion appears at cursor position with `virt_text` and `virt_lines`
  - **Floating**: Completion appears at end-of-line when cursor is mid-line
- Manages acceptance of full completions (Tab) or partial completions (Ctrl-j, up to next word)
- The `inlay_instance` tracks active completion state including prior_delete count for text replacement

**Document Synchronization (`document_listener.lua`)**
- Sets up autocommands to track buffer changes and cursor movements
- Triggers on `TextChanged`, `TextChangedI`, `TextChangedP`, `CursorMoved`, `CursorMovedI`
- Manages conditional enabling/disabling based on `config.condition()` or `g:SUPERMAVEN_DISABLED`
- Disposes inline previews on `InsertLeave`

**Configuration (`config.lua`)**
- Default keymaps: `<Tab>` (accept), `<C-]>` (clear), `<C-j>` (accept word)
- Supports `ignore_filetypes`, `disable_inline_completion`, `disable_keymaps`, and conditional activation
- Uses metatable for clean config access pattern

**nvim-cmp Integration (`cmp.lua`)**
- Registered as a cmp source named "supermaven"
- Converts inline completion to cmp items when `disable_inline_completion = true`
- Uses `CmpItemKindSupermaven` highlight group

### Key Patterns

1. **State Management**: `binary_handler.lua:submit_query()` creates state entries that map prefixes to completion arrays. As users type, `check_state()` finds the best matching state and strips the user's typed prefix from cached completions.

2. **Polling Loop**: A 25ms timer polls for new completions via `poll_once()` when `wants_polling` is true, stopping after 5 seconds of inactivity.

3. **Text Replacement**: When accepting completions, `prior_delete` characters are removed before cursor, then the completion text is inserted via LSP `apply_text_edits` to handle multi-line completions.

4. **Message Protocol**: Binary messages include:
   - `greeting`: Initial handshake
   - `state_update`: Document and cursor changes
   - `response`: Completion items for a state ID
   - `activation_request`/`activation_success`: Pro account setup
   - `service_tier`: Free/Pro status

## File Organization

```
lua/supermaven-nvim/
├── init.lua              # Plugin entry point, setup()
├── api.lua               # Public API functions
├── commands.lua          # Vim user commands
├── config.lua            # Configuration management
├── completion_preview.lua # Inline completion rendering
├── document_listener.lua  # Buffer change tracking
├── cmp.lua               # nvim-cmp source integration
├── textual.lua           # Text processing utilities
├── util.lua              # General utilities
├── logger.lua            # Logging system
├── types.lua             # Type definitions
└── binary/
    ├── binary_handler.lua  # Binary process management
    └── binary_fetcher.lua  # Binary download
```

## Testing and Debugging

**Manual Testing**
- Load plugin in Neovim with minimal config
- Test in insert mode with various file types
- Verify completions appear and can be accepted/rejected

**Debugging**
- `:SupermavenShowLog` to view logs at `stdpath-cache/supermaven-nvim.log`
- `:SupermavenClearLog` to clear logs
- `:SupermavenShowMessages` to view protocol messages at `stdpath-cache/supermaven-messages.log`
- `:SupermavenClearMessages` to clear protocol message log
- Set `log_level = "trace"` in config for verbose logging
- Check binary process: `binary:is_running()` returns boolean
- Message log captures all JSON communication between plugin and binary for analysis

**Common Issues**
- Buffer validation: Always check `nvim_buf_is_valid(buf)` before operations (see `completion_preview.lua:98`)
- Race conditions: The polling loop continues until completion or 5s timeout
- State cleanup: Old states purged after `max_state_id_retention` (50) to prevent memory leaks

## Commands

- `:SupermavenStart` / `:SupermavenStop` / `:SupermavenRestart` / `:SupermavenToggle`
- `:SupermavenStatus` - Check if running
- `:SupermavenUseFree` / `:SupermavenUsePro` - Switch service tiers
- `:SupermavenLogout` - Clear credentials
- `:SupermavenShowLog` / `:SupermavenClearLog` - Log management
- `:SupermavenShowMessages` / `:SupermavenClearMessages` - View/clear protocol message log (for debugging)

## Lua API

```lua
local api = require("supermaven-nvim.api")
api.start()
api.stop()
api.restart()
api.toggle()
api.is_running()
```

## Key Implementation Details

- **Extmark-based rendering** (not virtual text): Allows precise positioning and multi-line completions
- **State-based caching**: Avoids re-requesting completions when user types predicted text
- **Conditional activation**: `BufEnter` autocmd checks `config.condition()` to enable/disable per-buffer
- **Hard size limit**: Files over 10MB (`HARD_SIZE_LIMIT = 10e6`) are not sent to the binary
- **Graceful fallback**: If no suggestion active, Tab key passes through to normal behavior
