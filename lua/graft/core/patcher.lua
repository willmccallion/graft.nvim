--- @module graft.core.patcher
--- @brief Core logic for applying search and replace patches to buffers.
--- This module provides functionality to fuzzy match search blocks within a buffer
--- and replace them with new content, while maintaining a snapshot for potential rejection.

local M = {}
local state = require("graft.core.state")
local indicators = require("graft.ui.indicators")
local preview = require("graft.ui.preview")

local ns_id = indicators.get_namespace()

--- Saves the current state of the buffer before modification to allow for rejection.
--- @param bufnr number The buffer number to snapshot.
function M.save_snapshot(bufnr)
	if not state.transaction.original_lines or #state.transaction.original_lines == 0 then
		state.transaction.bufnr = bufnr
		state.transaction.original_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	end
end

--- Normalizes a string for comparison by stripping all whitespace.
--- This allows for matching lines regardless of indentation or spacing differences.
--- @param str string The string to normalize.
--- @return string The normalized string.
local function normalize(str)
	return str:gsub("%s+", "")
end

--- Calculates the similarity score between two strings.
--- Returns 1.0 for an exact match, 0.9 for a match ignoring whitespace, and 0.0 otherwise.
--- @param a string The first string (from buffer).
--- @param b string The second string (from search block).
--- @return number The similarity score.
local function get_line_score(a, b)
	if a == b then
		return 1.0
	end
	local na = normalize(a)
	local nb = normalize(b)
	if na == nb then
		return 0.9
	end
	if na == "" and nb == "" then
		return 1.0
	end
	return 0.0
end

--- Applies a search and replace operation on a buffer using a sliding window fuzzy match.
--- Locates the best matching block in the buffer corresponding to the search block
--- and replaces it with the replace block.
--- @param bufnr number The buffer handle.
--- @param search_block table The list of lines to search for.
--- @param replace_block table The list of lines to replace with.
--- @return boolean True if the patch was applied successfully (confidence > 85%), false otherwise.
function M.apply_search_replace(bufnr, search_block, replace_block)
	M.save_snapshot(bufnr)

	local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local search_len = #search_block
	local buf_len = #buf_lines

	if search_len == 0 then
		return false
	end

	local best_idx = -1
	local best_score = -1.0

	for i = 1, (buf_len - search_len + 1) do
		local current_match_score = 0
		for j = 1, search_len do
			local line_score = get_line_score(buf_lines[i + j - 1], search_block[j])
			current_match_score = current_match_score + line_score
		end

		local confidence = current_match_score / search_len
		if confidence > best_score then
			best_score = confidence
			best_idx = i - 1
		end
	end

	if best_score > 0.85 then
		local start_row = best_idx
		local end_row = best_idx + search_len

		vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, replace_block)

		for i = 0, #replace_block - 1 do
			vim.api.nvim_buf_add_highlight(bufnr, ns_id, "graftAdd", start_row + i, 0, -1)
		end

		preview.log(string.format(">> Applied Patch (Confidence: %.0f%%)", best_score * 100))
		return true
	else
		preview.log("!! PATCH FAILED !! Best match was only " .. (best_score * 100) .. "%")
		return false
	end
end

return M
