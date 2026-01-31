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

--- Tries to find the function node under the cursor using Tree-sitter.
--- @return table|nil: { start_line, end_line } (0-indexed) or nil if not found.
local function get_function_range()
	local has_ts, ts_utils = pcall(require, "nvim-treesitter.ts_utils")
	if not has_ts then
		utils.notify("nvim-treesitter is required for Scope mode.", vim.log.levels.ERROR)
		return nil
	end

	local node = ts_utils.get_node_at_cursor()
	while node do
		local type = node:type()
		-- Common node types for functions in various languages
		if type:match("function") or type:match("method") or type:match("def") or type:match("func") then
			local start_row, _, end_row, _ = node:range()
			return { start_row, end_row }
		end
		node = node:parent()
	end
	return nil
end

--- Captures the current editor state, specifically identifying if the user is in visual mode.
--- If in visual mode, it forces an exit to normal mode to ensure that the visual selection
--- marks ('< and '>) are correctly updated before retrieving the selection range.
---
--- @param scope string|nil Optional scope override ("function").
--- @return table state A table containing:
---   - type (string): "visual", "function", or "normal".
---   - start_line (number|nil): The starting line of the selection (0-indexed).
---   - end_line (number|nil): The ending line of the selection (0-indexed).
function M.get_current_state(scope)
	local mode = vim.fn.mode()
	if mode:match("[vV\22]") then
		vim.cmd("normal! \27")
		local _, start_line, end_line = utils.get_visual_selection()
		return { type = "visual", start_line = start_line, end_line = end_line }
	end

	if scope == "function" then
		local range = get_function_range()
		if range then
			return { type = "function", start_line = range[1], end_line = range[2] }
		else
			utils.notify("No function definition found under cursor. Falling back to file.", vim.log.levels.WARN)
		end
	end

	return { type = "normal" }
end

--- Resolves the text content and line range from the current buffer based on the provided state.
---
--- @param state_obj table The state object defining the scope of resolution.
---   - type (string): If "visual" or "function", resolution is restricted to the specified range.
---   - start_line (number): The starting line index (0-indexed).
---   - end_line (number): The ending line index (0-indexed).
--- @param _ any Reserved for future use or internal state (currently unused).
--- @return string text The extracted text from the buffer.
--- @return number[] range A tuple containing {start_line, end_line} of the resolved text.
--- @return boolean is_visual True if the text was resolved from a visual/function selection.
function M.resolve(state_obj, _)
	local current_buf = vim.api.nvim_get_current_buf()
	if state_obj.type == "visual" or state_obj.type == "function" then
		local text = get_text_from_range(current_buf, state_obj.start_line, state_obj.end_line)
		return text, { state_obj.start_line, state_obj.end_line }, true
	end
	local line_count = vim.api.nvim_buf_line_count(current_buf)
	local text = get_text_from_range(current_buf, 0, line_count - 1)
	return text, { 0, line_count - 1 }, false
end

return M
