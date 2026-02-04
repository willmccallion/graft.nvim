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
--- @return table result { success=bool, score=number, msg=string }
function M.apply_search_replace(bufnr, search_block, replace_block, range)
	M.save_snapshot(bufnr)

	local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local buf_len = #buf_lines
	local search_len = #search_block

	-- Handle empty file case
	local is_buf_empty = (buf_len == 0) or (buf_len == 1 and buf_lines[1] == "")
	if is_buf_empty then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, replace_block)
		preview.log(">> Applied Patch (Empty File Mode)")
		return { success = true, score = 1.0, msg = "Empty file populated" }
	end

	if search_len == 0 then
		return { success = false, score = 0.0, msg = "Search block was empty" }
	end

	local best_idx = -1
	local best_score = -1.0
	local search_start = 0
	local search_end = buf_len - search_len

	if range then
		search_start = math.max(0, range[1])
		search_end = math.min(search_end, range[2])
	end

	-- Sliding window search
	for i = search_start, search_end do
		local current_match_score = 0
		for j = 1, search_len do
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

		for i = 0, #replace_block - 1 do
			vim.api.nvim_buf_add_highlight(bufnr, ns_id, "graftAdd", start_row + i, 0, -1)
		end

		local msg = string.format(">> Applied Patch (Confidence: %.0f%%)", best_score * 100)
		preview.log(msg)
		return { success = true, score = best_score, msg = msg }
	else
		local msg = string.format("!! PATCH FAILED !! Best match was only %.0f%%", best_score * 100)
		preview.log(msg)
		return { success = false, score = best_score, msg = msg }
	end
end

return M
