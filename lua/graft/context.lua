local M = {}
local utils = require("graft.utils")
local state = require("graft.core.state")

local function get_text_from_range(bufnr, start_row, end_row)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
	return table.concat(lines, "\n")
end

function M.get_external_context()
	if #state.context_files == 0 then
		return ""
	end
	local out = "\n=== ADDITIONAL CONTEXT FILES ===\n"
	for _, filepath in ipairs(state.context_files) do
		local f = io.open(filepath, "r")
		if f then
			local content = f:read("*a")
			f:close()
			local rel_path = vim.fn.fnamemodify(filepath, ":.")
			out = out .. string.format("\nFILE: %s\n```\n%s\n```\n", rel_path, content)
		end
	end
	out = out .. "================================\n"
	return out
end

function M.get_current_state()
	local mode = vim.fn.mode()
	if mode:match("[vV\22]") then
		vim.cmd("normal! \27")
		local _, start_line, end_line = utils.get_visual_selection()
		return { type = "visual", start_line = start_line, end_line = end_line }
	end
	return { type = "normal" }
end

function M.resolve(state_obj, _)
	local current_buf = vim.api.nvim_get_current_buf()
	if state_obj.type == "visual" then
		local text = get_text_from_range(current_buf, state_obj.start_line, state_obj.end_line)
		return text, { state_obj.start_line, state_obj.end_line }, true
	end
	local line_count = vim.api.nvim_buf_line_count(current_buf)
	local text = get_text_from_range(current_buf, 0, line_count - 1)
	return text, { 0, line_count - 1 }, false
end

return M
