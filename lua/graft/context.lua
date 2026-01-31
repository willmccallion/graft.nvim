--- @module graft.context
--- @description Utilities for capturing and resolving editor context.
--- This includes capturing visual selections, external files, and current buffer content.
local M = {}

local utils = require("graft.utils")
local state = require("graft.core.state")

--- Get text from a range of lines in a buffer.
--- @param bufnr number The buffer number.
--- @param start_row number The starting row (0-indexed).
--- @param end_row number The ending row (0-indexed, inclusive).
--- @return string The text from the range.
local function get_text_from_range(bufnr, start_row, end_row)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
	return table.concat(lines, "\n")
end

--- Retrieves and formats the content of external context files.
---
--- This function iterates through the list of files stored in `state.context_files`,
--- reads their content, and formats them into a single string with headers and
--- markdown code blocks. This is typically used to provide additional context
--- to an LLM.
---
--- @return string The formatted string containing the content of all context files, or an empty string if no files are present.
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

--- Captures the current editor state, specifically identifying if the user is in visual mode.
--- If in visual mode, it forces an exit to normal mode to ensure that the visual selection
--- marks ('< and '>) are correctly updated before retrieving the selection range.
---
--- @return table state A table containing:
---   - type (string): "visual" if the function was called from visual mode, "normal" otherwise.
---   - start_line (number|nil): The starting line of the visual selection (1-indexed).
---   - end_line (number|nil): The ending line of the visual selection (1-indexed).
function M.get_current_state()
	local mode = vim.fn.mode()
	if mode:match("[vV\22]") then
		vim.cmd("normal! \27")
		local _, start_line, end_line = utils.get_visual_selection()
		return { type = "visual", start_line = start_line, end_line = end_line }
	end
	return { type = "normal" }
end

--- Resolves the text content and line range from the current buffer based on the provided state.
---
--- @param state_obj table The state object defining the scope of resolution.
---   - type (string): If "visual", resolution is restricted to the specified range.
---   - start_line (number): The starting line index (0-indexed) for visual selection.
---   - end_line (number): The ending line index (0-indexed) for visual selection.
--- @param _ any Reserved for future use or internal state (currently unused).
--- @return string text The extracted text from the buffer.
--- @return number[] range A tuple containing {start_line, end_line} of the resolved text.
--- @return boolean is_visual True if the text was resolved from a visual selection, false otherwise.
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
