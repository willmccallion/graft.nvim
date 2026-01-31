local M = {}
local config = require("graft.config")
local actions = require("graft.actions")
local utils = require("graft.utils")
local client = require("graft.api.client")
local state = require("graft.core.state")

function M.setup(user_opts)
	config.setup(user_opts)

	-- Commands (Must start with Uppercase)
	vim.api.nvim_create_user_command("GraftStop", function()
		if client and client.stop_job then
			client.stop_job()
		else
			vim.notify("Graft Error: client.stop_job is not available.", vim.log.levels.ERROR)
		end
	end, {})

	vim.api.nvim_create_user_command("GraftAccept", function()
		actions.accept_changes()
	end, {})

	vim.api.nvim_create_user_command("GraftReject", function()
		actions.reject_changes()
	end, {})

	vim.api.nvim_create_user_command("GraftDebug", function()
		config.options.debug = not config.options.debug
		utils.notify("Graft Debug Mode: " .. (config.options.debug and "ON" or "OFF"))
	end, {})

	vim.api.nvim_create_user_command("GraftClearChat", function()
		state.chat_history = {}
		if state.chat_bufnr and vim.api.nvim_buf_is_valid(state.chat_bufnr) then
			vim.api.nvim_buf_set_lines(state.chat_bufnr, 0, -1, false, { "# Graft Chat", "" })
		end
		utils.notify("Chat history cleared.")
	end, {})

	-- Keymaps
	if user_opts and user_opts.use_default_keymaps ~= false then
		vim.keymap.set({ "n", "v" }, "<leader>aa", actions.start, { desc = "Graft: Menu" })
		vim.keymap.set({ "n", "v" }, "<leader>ar", actions.refactor, { desc = "Graft: Refactor" })
		vim.keymap.set({ "n", "v" }, "<leader>ap", actions.plan, { desc = "Graft: Plan (Chat)" })
		vim.keymap.set("n", "<leader>am", actions.select_model, { desc = "Graft: Select Model" })

		vim.keymap.set("n", "<leader>as", function()
			if client and client.stop_job then
				client.stop_job()
			end
		end, { desc = "Graft: Stop" })

		vim.keymap.set("n", "<leader>ay", ":GraftAccept<CR>", { desc = "Graft: [A]ccept [Y]es" })
		vim.keymap.set("n", "<leader>an", ":GraftReject<CR>", { desc = "Graft: [A]ccept [N]o (Reject)" })
	end
end

-- Expose Public API
M.start = actions.start
M.refactor = actions.refactor
M.plan = actions.plan
M.select_model = actions.select_model
M.stop_job = client.stop_job

return M
