--- @module graft.ui.preview
--- @description Handles the preview window for streaming output.
local M = {}
local config = require("graft.config")

M.preview_win = nil
M.preview_buf = nil

--- Ensures that the preview window and buffer exist.
--- If they don't exist or are invalid, it creates a new floating window.
--- @return integer buf The buffer handle.
--- @return integer win The window handle.
function M.ensure_preview_window()
	if M.preview_win and vim.api.nvim_win_is_valid(M.preview_win) then
		return M.preview_buf, M.preview_win
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "filetype", "diff")

	local width = 60
	local height = 20
	local row = 2
	local col = vim.o.columns - width - 2

	local opts = {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " graft Stream ",
		title_pos = "center",
		zindex = 50,
	}

	local win = vim.api.nvim_open_win(buf, false, opts)
	vim.api.nvim_win_set_option(win, "wrap", true)

	M.preview_win = win
	M.preview_buf = buf
	return buf, win
end

--- Appends a message to the preview buffer and scrolls to the bottom.
--- @param msg string The message to append.
function M.log(msg)
	if not config.options.show_preview then
		return
	end

	local buf, win = M.ensure_preview_window()
	if not buf then
		return
	end

	msg = msg:gsub("\r", "")
	local line_count = vim.api.nvim_buf_line_count(buf)
	local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""
	local combined = last_line .. msg
	local lines = vim.split(combined, "\n")
	vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, { lines[1] })
	if #lines > 1 then
		local new_lines = {}
		for i = 2, #lines do
			table.insert(new_lines, lines[i])
		end
		vim.api.nvim_buf_set_lines(buf, line_count, -1, false, new_lines)
	end
	if vim.api.nvim_win_is_valid(win) then
		local new_count = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_win_set_cursor(win, { new_count, 0 })
	end
end

--- Closes the preview window and resets the window handle.
function M.close()
	if M.preview_win and vim.api.nvim_win_is_valid(M.preview_win) then
		vim.api.nvim_win_close(M.preview_win, true)
		M.preview_win = nil
	end
end

return M
