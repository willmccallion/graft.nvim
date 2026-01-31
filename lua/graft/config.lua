--- @module graft.config
--- @brief Configuration and state management for the plugin.
--- This module defines the default settings, manages API keys from environment variables,
--- and provides a setup function to merge user configurations.

local M = {}

--- Default configuration settings for the plugin.
--- @table defaults
--- @field default_provider string The default AI model provider (default: "gemini_flash").
--- @field show_preview boolean Whether to display the preview window (default: false).
--- @field keys table A map of provider names to their respective API keys.
--- @field ui table UI-related settings like window width and border style.
--- @field debug boolean Toggle for verbose logging and debugging information.
M.defaults = {
	default_provider = "gemini_flash",
	show_preview = false,
	keys = {
		gemini = os.getenv("GEMINI_API_KEY"),
		openai = os.getenv("OPENAI_API_KEY"),
		anthropic = os.getenv("ANTHROPIC_API_KEY"),
	},
	ui = {
		width = 60,
		border = "rounded",
	},
	debug = false,
}

--- Current state of the plugin.
--- @table state
--- @field current_provider string|nil The currently active AI provider.
M.state = {
	current_provider = nil,
}

--- Initializes the plugin with user-provided options.
--- @param user_opts table|nil User configuration options to override defaults.
function M.setup(user_opts)
	M.options = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
end

return M
