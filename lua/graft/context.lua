local M = {}
local utils = require("graft.utils")
local state = require("graft.core.state")

local function get_text_from_range(bufnr, start_row, end_row)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
	return table.concat(lines, "\n")
end

local function get_diagnostics(bufnr)
	local diagnostics = vim.diagnostic.get(bufnr)
	if #diagnostics == 0 then
		return ""
	end
	local out = "\nDETECTED LSP ERRORS/WARNINGS (Fix these if relevant):\n"
	for _, d in ipairs(diagnostics) do
		out = out .. string.format("- Line %d: %s\n", d.lnum + 1, d.message)
	end
	return out
end

-- NEW: Read external context files
function M.get_external_context()
	if #state.context_files == 0 then
		return ""
	end

	local out = "\n=== EXTERNAL CONTEXT (READ-ONLY REFERENCE) ===\n"

	for _, filepath in ipairs(state.context_files) do
		local f = io.open(filepath, "r")
		if f then
			local content = f:read("*a")
			f:close()
			out = out .. string.format("\nFILE: %s\n```\n%s\n```\n", filepath, content)
		else
			out = out .. string.format("\nFILE: %s (Error: Could not read)\n", filepath)
		end
	end

	out = out .. "==============================================\n"
	return out
end

function M.get_current_state()
	local mode = vim.fn.mode()
	local is_visual = (mode:match("[vV\22]"))
	if is_visual then
		vim.cmd("normal! \27")
		local _, start_line, end_line = utils.get_visual_selection()
		return { type = "visual", start_line = start_line, end_line = end_line }
	else
		return { type = "normal" }
	end
end

function M.resolve(state, prompt_text)
	local current_buf = vim.api.nvim_get_current_buf()
	local line_count = vim.api.nvim_buf_line_count(current_buf)
	local diagnostics = get_diagnostics(current_buf)

	if state.type == "visual" then
		local text = get_text_from_range(current_buf, state.start_line, state.end_line)
		return text .. diagnostics, { state.start_line, state.end_line }, true
	end

	local text = get_text_from_range(current_buf, 0, line_count - 1)
	return text .. diagnostics, { 0, line_count - 1 }, false
end

return M
