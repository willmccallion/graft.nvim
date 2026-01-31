--- @module graft.ui.components
--- UI components for Graft using nui.nvim.
local M = {}
local Input = require("nui.input")
local Menu = require("nui.menu")
local Split = require("nui.split")
local Popup = require("nui.popup")
local state = require("graft.core.state")

M.Menu = Menu

--- Displays a multi-line popup for user input.
--- @param title string The title of the popup.
--- @param on_submit function(text: string) Callback function when input is submitted.
function M.ask(title, on_submit)
	local popup = Popup({
		enter = true,
		focusable = true,
		border = {
			style = "rounded",
			text = {
				top = " " .. title .. " ",
				bottom = " [Ctrl+Enter] to Submit ",
			},
		},
		position = { row = "10%", col = "98%" },
		size = { width = 60, height = 12 },
		relative = "editor",
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:Normal",
			wrap = true,
			linebreak = true,
		},
	})

	popup:mount()

	vim.schedule(function()
		vim.cmd("startinsert")
	end)

	local function submit_input()
		local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
		local text = table.concat(lines, "\n")
		if text:match("%S") then
			popup:unmount()
			on_submit(text)
		end
	end

	popup:map("n", "<Esc>", function()
		popup:unmount()
	end, { noremap = true })

	popup:map("i", "<C-CR>", submit_input, { noremap = true })
	popup:map("i", "<C-s>", submit_input, { noremap = true })
	popup:map("n", "<CR>", submit_input, { noremap = true })
end

--- Displays a selection menu.
--- @param title string The title of the menu.
--- @param items table List of Menu.item objects.
--- @param on_select function(item: table) Callback function when an item is selected.
function M.select(title, items, on_select)
	local menu = Menu({
		position = { row = "10%", col = "98%" }, -- Right side
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

--- Creates a persistent input box at the bottom of a split.
--- @param split table The nui.split instance.
--- @param on_submit_cb function(value: string) Callback function when input is submitted.
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

			vim.defer_fn(function()
				M.create_input_box(split, on_submit_cb)
			end, 20)
		end,
	})

	input:mount()

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

--- Opens a chat window in a split.
--- @param on_submit function(value: string, bufnr: number) Callback function when input is submitted.
--- @return number bufnr The buffer number of the chat window.
function M.open_chat(on_submit)
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
