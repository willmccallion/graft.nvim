--- @module graft.core.patcher
--- @brief Core logic for applying search and replace patches to buffers.
local M = {}
local state = require("graft.core.state")
local indicators = require("graft.ui.indicators")
local preview = require("graft.ui.preview")

local ns_id = indicators.get_namespace()

function M.save_snapshot(bufnr)
	if not state.transaction.original_lines or #state.transaction.original_lines == 0 then
		state.transaction.bufnr = bufnr
		state.transaction.original_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	end
end

local function normalize(str)
	return str:gsub("%s+", "")
end

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

--- Applies a search and replace operation.
--- @param bufnr number The buffer handle.
--- @param search_block table The list of lines to search for.
--- @param replace_block table The list of lines to replace with.
--- @param range table|nil Optional [start_line, end_line] (0-indexed) to constrain search.
--- @return boolean True if applied.
function M.apply_search_replace(bufnr, search_block, replace_block, range)
	M.save_snapshot(bufnr)

	local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local buf_len = #buf_lines
	local search_len = #search_block

	local is_buf_empty = (buf_len == 0) or (buf_len == 1 and buf_lines[1] == "")
	if is_buf_empty then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, replace_block)
		preview.log(">> Applied Patch (Empty File Mode)")
		return true
	end

	-- If search block is empty but file isn't, we can't safely match "nothing".
	-- (Unless we implement pure insertion, but for refactor this usually implies an error)
	if search_len == 0 then
		preview.log("!! PATCH FAILED !! Search block was empty, but file is not.")
		return false
	end

	local best_idx = -1
	local best_score = -1.0

	local search_start = 0
	local search_end = buf_len - search_len

	if range then
		-- Ensure we don't go out of bounds
		search_start = math.max(0, range[1])
		-- We allow the search to scan slightly past the visual selection end
		-- to account for context mismatch, but generally keep it tight.
		search_end = math.min(search_end, range[2])
	end

	-- Sliding window search
	for i = search_start, search_end do
		local current_match_score = 0
		for j = 1, search_len do
			-- i is 0-indexed, lua tables are 1-indexed
			-- buf_lines[i + j] gets the line at index i + (j-1) + 1
			local line_idx = i + j
			if line_idx <= buf_len then
				local line_score = get_line_score(buf_lines[line_idx], search_block[j])
				current_match_score = current_match_score + line_score
			end
		end

		local confidence = current_match_score / search_len
		if confidence > best_score then
			best_score = confidence
			best_idx = i
		end
	end

	-- Threshold: 85% match required
	if best_score > 0.85 then
		local start_row = best_idx
		local end_row = best_idx + search_len

		vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, replace_block)

		-- Highlight the changes
		for i = 0, #replace_block - 1 do
			vim.api.nvim_buf_add_highlight(bufnr, ns_id, "graftAdd", start_row + i, 0, -1)
		end

		preview.log(string.format(">> Applied Patch (Confidence: %.0f%%) at line %d", best_score * 100, start_row + 1))
		return true
	else
		preview.log("!! PATCH FAILED !! Best match was only " .. (best_score * 100) .. "%")
		return false
	end
end

return M
