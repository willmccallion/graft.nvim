# graft.nvim

A Neovim plugin for AI-assisted development, focusing on precise code refactoring and contextual awareness.

## Features

- **Smart Patching**: Applies AI-generated Search/Replace blocks directly to buffers using fuzzy matching and adaptive context resolution. Whitespace and indentation agnostic.
- **Scope Refactor**: Isolate refactoring to the function under the cursor using Tree-sitter, preventing side effects in the rest of the file.
- **Auto-Documentation**: Automatically generates high-quality documentation for files and functions, ensuring entry points like `main` are never skipped.
- **Context Management**: Add specific files (with multi-select support) or entire directories recursively to provide the LLM with relevant project knowledge.
- **Multi-Provider Support**: Native integration with Google Gemini (Flash and Pro) and local Ollama instances.
- **Interactive Chat**: Dedicated split-view interface for architectural planning and technical discussions.
- **Visual Diffing**: Real-time highlights for additions, allowing for manual review before acceptance.
- **Stability & Performance**: Robust JSON parsing for streaming responses and defensive token counting to prevent crashes on API errors.

## Requirements

- Neovim 0.9.0 or later
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)
- `curl` installed on your system

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "willmccallion/graft.nvim",
    dependencies = {
        "nvim-lua/plenary.nvim",
        "MunifTanjim/nui.nvim",
    },
    config = function()
        require("graft").setup({
            -- Optional configuration
        })
    end,
}
```

## Configuration

The following are the default configuration options:

```lua
require("graft").setup({
    default_provider = "gemini_flash", -- "gemini_flash", "gemini_pro", or "ollama"
    show_preview = false,              -- Show a floating window with the raw AI stream
    ui = {
        width = 60,
        border = "rounded",
    },
    debug = false,
})
```

### Environment Variables

For Gemini providers, ensure your API key is set:
```bash
export GEMINI_API_KEY="your_api_key_here"
```

## Usage

### Refactor (Smart Patch)
Trigger the refactor action to provide instructions for the current buffer or a visual selection. Graft uses a Search/Replace block strategy to ensure the AI provides precise, functional code modifications. It can handle complex multi-function refactors, such as adding enums and updating all call sites simultaneously.

The plugin generates a patch and applies it to the buffer using fuzzy matching. You can then review the changes with green highlights indicating added lines.

### Scope Refactor
Target only the function under the cursor. This uses Tree-sitter to identify function boundaries and instructs the AI to modify only the logic within that scope, preserving imports and global state.

### Auto-Documentation
Automatically document your code. Graft will analyze the file and generate docstrings for the file header and every function found, following a strict completeness rule.

### Plan (Chat Mode)
Open an interactive chat session. Plan mode is context-aware; it uses the current buffer and any files added via the Context Manager to answer architectural questions or help plan complex features across your codebase.

### Context Manager
Manage the files sent to the AI. You can:
- Add individual files via a file picker (Telescope supported with multi-select).
- Add directories recursively (Telescope supported).
- Clear the current context.

## Commands

- `GraftStop`: Abort the current AI generation.
- `GraftAccept`: Accept the applied changes and clear highlights.
- `GraftReject`: Revert the changes to the original state.
- `GraftClearChat`: Reset the chat history and buffer.
- `GraftScope`: Trigger Scope Refactor on the function under cursor.
- `GraftDoc`: Trigger Auto-Documentation for the current file.
- `GraftDebug`: Toggle debug logging.

## Default Keymaps

If `use_default_keymaps` is not set to `false` in setup:

- `<leader>aa`: Open the main Graft menu.
- `<leader>ar`: Trigger Refactor.
- `<leader>ap`: Trigger Plan (Chat).
- `<leader>am`: Select AI Model/Provider.
- `<leader>ag`: Scope Refactor (Function).
- `<leader>ad`: Auto Document.
- `<leader>as`: Stop generation.
- `<leader>ay`: Accept changes.
- `<leader>an`: Reject changes.
