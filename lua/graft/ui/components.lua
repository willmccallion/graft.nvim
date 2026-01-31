local M = {}
local Input = require("nui.input")
local Menu = require("nui.menu")
local Split = require("nui.split")
local state = require("graft.core.state")

-- EXPORT Menu so other modules can use Menu.item()
M.Menu = Menu

--- Generic Input Box
function M.ask(title, on_submit)
	local input = Input({
		position = "20%",
		size = { width = 60 },
		border = {
			style = "rounded",
			text = { top = " " .. title .. " " },
		},
		win_options = { winhighlight = "Normal:Normal,FloatBorder:Normal" },
	}, {
		on_submit = on_submit,
	})

	input:mount()

	-- Auto-enter insert mode
	vim.schedule(function()
		vim.cmd("startinsert")
	end)

	-- Close on Esc
	input:map("n", "<Esc>", function()
		input:unmount()
	end, { noremap = true })
	input:map("i", "<Esc>", function()
		input:unmount()
	end, { noremap = true })
end

--- Generic Selection Menu
function M.select(title, items, on_select)
	local menu = Menu({
		position = "20%",
		size = { width = 40 },
		border = {
			style = "rounded",
			text = { top = " " .. title .. " " },
		},
		win_options = { winhighlight = "Normal:Normal,FloatBorder:Normal" },
	}, {
		lines = items,
		max_width = 20,
		keymap = {
			focus_next = { "j", "<Down>", "<Tab>" },
			focus_prev = { "k", "<Up>", "<S-Tab>" },
			close = { "<Esc>", "<C-c>" },
			submit = { "<CR>", "<Space>" },
		},
		on_submit = on_select,
	})

	menu:mount()
end

--- Helper: Chat Input Box (Recursive for persistence)
function M.create_input_box(split, on_submit_cb)
	local input

	input = Input({
		relative = "win",
		winid = split.winid,
		position = { row = "100%", col = 0 },
		size = { width = "100%", height = 3 },
		border = {
			style = "rounded",
			text = { top = " Chat Input (Enter to send) " },
		},
		win_options = { winhighlight = "Normal:Normal,FloatBorder:Normal" },
	}, {
		on_submit = function(value)
			if not value or value == "" then
				return
			end

			input:unmount()
			on_submit_cb(value)

			-- Create a FRESH input box to replace the old one
			vim.defer_fn(function()
				M.create_input_box(split, on_submit_cb)
			end, 20)
		end,
	})

	input:mount()

	-- Ensure input closes if the split closes
	local event_id = vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(split.winid),
		callback = function()
			if input and input.winid and vim.api.nvim_win_is_valid(input.winid) then
				input:unmount()
			end
		end,
		once = true,
	})

	vim.schedule(function()
		if input.winid and vim.api.nvim_win_is_valid(input.winid) then
			vim.api.nvim_set_current_win(input.winid)
			vim.cmd("startinsert")
		end
	end)
end

--- Open Chat Interface
function M.open_chat(on_submit)
	-- Create buffer if it doesn't exist
	if not state.chat_bufnr or not vim.api.nvim_buf_is_valid(state.chat_bufnr) then
		state.chat_bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_option(state.chat_bufnr, "filetype", "markdown")
		vim.api.nvim_buf_set_option(state.chat_bufnr, "bufhidden", "hide")
		vim.api.nvim_buf_set_lines(state.chat_bufnr, 0, -1, false, { "# Graft Chat", "" })
	end

	local split = Split({
		relative = "editor",
		position = "right",
		size = "40%",
		win_options = { wrap = true, linebreak = true, foldcolumn = "0" },
		buf_options = { filetype = "markdown" },
	})

	split:mount()

	vim.api.nvim_win_set_buf(split.winid, state.chat_bufnr)

	split:map("n", "q", function()
		split:unmount()
	end, { noremap = true })

	M.create_input_box(split, function(value)
		on_submit(value, state.chat_bufnr)
	end)

	return state.chat_bufnr
end

return M
