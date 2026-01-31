local M = {}

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

M.state = {
	current_provider = nil,
}

function M.setup(user_opts)
	M.options = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
end

return M
