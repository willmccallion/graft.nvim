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

local function normalize_fuzzy(str)
	-- 1. Remove carriage returns
	local clean = str:gsub("\r", "")
	-- 2. Trim leading/trailing whitespace
	local trimmed = clean:match("^%s*(.-)%s*$") or ""
	-- 3. Collapse internal whitespace to single space (handles tab vs space mismatch)
	return trimmed:gsub("%s+", " ")
end

local function is_closer(line)
	local trimmed = line:match("^%s*(.-)%s*$")
	return trimmed == "end" or trimmed == "}" or trimmed == "]" or trimmed == ")" or trimmed == "};"
end

local function fuzzy_eq(b, s)
	local nb = normalize_fuzzy(b)
	local ns = normalize_fuzzy(s)
	if nb == ns then
		return true
	end
	if #nb < 8 or #ns < 8 then
		return false
	end
	local len_b = #nb
	local len_s = #ns
	if len_b > len_s then
		if nb:find(ns, 1, true) and (len_s / len_b > 0.5) then
			return true
		end
	else
		if ns:find(nb, 1, true) and (len_b / len_s > 0.5) then
			return true
		end
	end
	return false
end

local function scan_buffer(buf_lines, clean_search)
	for i = 1, #buf_lines do
		if fuzzy_eq(buf_lines[i], clean_search[1]) then
			local b_idx = i + 1
			local s_idx = 2
			local match_failed = false

			while s_idx <= #clean_search do
				if b_idx > #buf_lines then
					match_failed = true
					break
				end

				local b_line = buf_lines[b_idx]
				local s_line = clean_search[s_idx]

				local b_empty = not b_line:match("%S")
				local s_empty = not s_line:match("%S")

				if b_empty and not s_empty then
					b_idx = b_idx + 1
				elseif not b_empty and s_empty then
					match_failed = true
					break
				else
					if fuzzy_eq(b_line, s_line) then
						b_idx = b_idx + 1
						s_idx = s_idx + 1
					elseif is_closer(b_line) and is_closer(s_line) then
						b_idx = b_idx + 1
						s_idx = s_idx + 1
					else
						match_failed = true
						break
					end
				end
			end

			if not match_failed then
				return i - 1, b_idx - 1
			end
		end
	end
	return nil, nil
end

-- Returns: start_idx, end_idx, trim_start_count, trim_end_count
local function find_lines_adaptive(bufnr, search_lines)
	local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local s_work = {}
	for _, l in ipairs(search_lines) do
		table.insert(s_work, l)
	end

	-- Clean leading empty lines
	while #s_work > 0 and not s_work[1]:match("%S") do
		table.remove(s_work, 1)
	end
	if #s_work == 0 then
		return nil, nil, 0, 0
	end

	-- Attempt 1: Exact
	local start_idx, end_idx = scan_buffer(buf_lines, s_work)
	if start_idx then
		return start_idx, end_idx, 0, 0
	end

	-- Attempt 2: Trim Trailing
	local max_trim = 4
	local trim_count = 0
	while trim_count < max_trim and #s_work > 2 do
		table.remove(s_work)
		trim_count = trim_count + 1
		local s, e = scan_buffer(buf_lines, s_work)
		if s then
			preview.log(">> Adaptive: Ignored " .. trim_count .. " trailing lines.")
			return s, e, 0, trim_count
		end
	end

	-- Attempt 3: Trim Leading
	s_work = {}
	for _, l in ipairs(search_lines) do
		table.insert(s_work, l)
	end
	trim_count = 0
	while trim_count < max_trim and #s_work > 2 do
		table.remove(s_work, 1)
		trim_count = trim_count + 1
		local s, e = scan_buffer(buf_lines, s_work)
		if s then
			preview.log(">> Adaptive: Ignored " .. trim_count .. " leading lines.")
			return s, e, trim_count, 0
		end
	end

	return nil, nil, 0, 0
end

function M.apply_patch_block(bufnr, ops)
	if #ops == 0 then
		return false
	end
	M.save_snapshot(bufnr)

	-- 1. Extract Search Lines (Context + Deleted)
	local search_lines = {}
	for _, op in ipairs(ops) do
		if op.op == "ctx" or op.op == "del" then
			table.insert(search_lines, op.text)
		end
	end

	-- 2. Handle Empty File / Pure Insertion
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local first_line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
	local is_empty = (line_count <= 1 and first_line == "")

	if is_empty or #search_lines == 0 then
		local row = is_empty and 0 or (vim.api.nvim_win_get_cursor(0)[1] - 1)
		local lines_to_add = {}
		for _, op in ipairs(ops) do
			if op.op == "add" then
				table.insert(lines_to_add, op.text)
			end
		end

		if #lines_to_add > 0 then
			preview.log("\n>> Inserting new code at cursor/start.\n")
			vim.api.nvim_buf_set_lines(bufnr, row, row, false, lines_to_add)
			for i = 0, #lines_to_add - 1 do
				vim.api.nvim_buf_add_highlight(bufnr, ns_id, "graftAdd", row + i, 0, -1)
			end
			return true
		end
		return false
	end

	-- 3. Find Block
	local start_idx, end_idx, trim_s, trim_e = find_lines_adaptive(bufnr, search_lines)

	if start_idx and end_idx then
		preview.log("\n>> Match Found: Lines " .. (start_idx + 1) .. "-" .. (end_idx + 1) .. "\n")

		-- Filter Ops based on trim
		local active_ops = {}
		local s_seen, e_seen = 0, 0

		-- Forward pass to skip trimmed start
		local op_start_idx = 1
		if trim_s > 0 then
			for i = 1, #ops do
				if ops[i].op ~= "add" then
					s_seen = s_seen + 1
					if s_seen > trim_s then
						op_start_idx = i
						break
					end
				end
			end
		end

		-- Backward pass to skip trimmed end
		local op_end_idx = #ops
		if trim_e > 0 then
			for i = #ops, 1, -1 do
				if ops[i].op ~= "add" then
					e_seen = e_seen + 1
					if e_seen > trim_e then
						op_end_idx = i
						break
					end
				end
			end
		end

		for i = op_start_idx, op_end_idx do
			table.insert(active_ops, ops[i])
		end

		-- Construct Replacement Block
		local final_lines = {}
		for _, op in ipairs(active_ops) do
			if op.op == "ctx" or op.op == "add" then
				table.insert(final_lines, op.text)
			end
		end

		-- Apply Change
		vim.api.nvim_buf_set_lines(bufnr, start_idx, end_idx, false, final_lines)

		-- Apply Highlights (Green) and Virtual Text (Red)
		local current_row = start_idx
		for _, op in ipairs(active_ops) do
			if op.op == "ctx" then
				current_row = current_row + 1
			elseif op.op == "add" then
				vim.api.nvim_buf_add_highlight(bufnr, ns_id, "graftAdd", current_row, 0, -1)
				current_row = current_row + 1
			elseif op.op == "del" then
				-- Show deleted line as virtual text ABOVE the current row
				local virt = { { op.text, "graftDelete" } }
				pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, current_row, 0, {
					virt_lines = { virt },
					virt_lines_above = true,
				})
			end
		end
		return true
	else
		preview.log("\n!! MATCH FAILED !!\nCould not find this block in file:\n")
		for _, l in ipairs(search_lines) do
			preview.log("  " .. l .. "\n")
		end
		preview.log("----------------------\n")
		return false
	end
end

return M
