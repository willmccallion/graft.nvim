local M = {}
local state = require("graft.core.state")

local ns_id = vim.api.nvim_create_namespace("graft_ai")
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_timer = nil
local current_spinner_extmark = nil

-- Define Highlights
vim.api.nvim_set_hl(0, "graftAdd", { fg = "#00AA00", bg = "#003300", bold = true })
vim.api.nvim_set_hl(0, "graftDelete", { fg = "#AA0000", bg = "#330000", strikethrough = true })

function M.get_namespace()
	return ns_id
end

function M.start_spinner(bufnr, line, model_name)
	M.stop_spinner(bufnr)
	spinner_timer = vim.loop.new_timer()
	local frame_idx = 1
	local label = model_name and ("graft (" .. model_name .. ")") or "graft"

	spinner_timer:start(
		0,
		100,
		vim.schedule_wrap(function()
			if not state.is_streaming then
				M.stop_spinner(bufnr)
				return
			end
			local icon = spinner_frames[frame_idx]
			frame_idx = (frame_idx % #spinner_frames) + 1

			if current_spinner_extmark and vim.api.nvim_buf_is_valid(bufnr) then
				pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_id, current_spinner_extmark)
			end

			local opts = {
				virt_text = { { " " .. icon .. " " .. label .. " is thinking...", "Comment" } },
				virt_text_pos = "eol",
			}
			if vim.api.nvim_buf_is_valid(bufnr) then
				local count = vim.api.nvim_buf_line_count(bufnr)
				local safe_line = math.min(math.max(line, 0), count - 1)
				local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, safe_line, 0, opts)
				if ok then
					current_spinner_extmark = id
				end
			end
		end)
	)
end

function M.stop_spinner(bufnr)
	if spinner_timer then
		spinner_timer:stop()
		spinner_timer:close()
		spinner_timer = nil
	end
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) and current_spinner_extmark then
		pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_id, current_spinner_extmark)
		current_spinner_extmark = nil
	end
end

return M
