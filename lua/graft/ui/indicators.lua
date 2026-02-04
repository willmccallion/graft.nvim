--- @module graft.ui.indicators
--- @description UI components for displaying loading states and progress indicators.
local M = {}
local Popup = require("nui.popup")
local state = require("graft.core.state")

local ns_id = vim.api.nvim_create_namespace("graft_ai")
vim.api.nvim_set_hl(0, "graftAdd", { fg = "#00AA00", bg = "#003300", bold = true })
vim.api.nvim_set_hl(0, "graftDelete", { fg = "#AA0000", bg = "#330000", strikethrough = true })

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_timer = nil
local loading_popup = nil
local start_time = 0

--- Returns the namespace ID used for Graft AI highlights.
--- @return integer The namespace ID.
function M.get_namespace()
	return ns_id
end

--- Starts a loading spinner popup with information about the current AI operation.
--- @param bufnr integer The buffer ID where the operation is occurring.
--- @param line integer The line number (currently unused).
--- @param model_name string|nil The name of the AI model being used.
--- @param retry_count integer|nil The current retry attempt number (0 for first try).
function M.start_spinner(bufnr, line, model_name, retry_count)
	M.stop_spinner()
	start_time = vim.loop.hrtime()

	local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
	if fname == "" then
		fname = "[No Name]"
	end

	local is_retry = retry_count and retry_count > 0
	local height = is_retry and 5 or 4

	loading_popup = Popup({
		enter = false,
		focusable = false,
		zindex = 50,
		position = { row = 1, col = "100%" },
		anchor = "NE",
		size = { width = 35, height = height },
		border = {
			style = "rounded",
			text = { top = " Graft AI " },
		},
		win_options = { winhighlight = "Normal:Normal,FloatBorder:SpecialChar" },
	})

	loading_popup:mount()

	local frame_idx = 1
	spinner_timer = vim.loop.new_timer()
	spinner_timer:start(
		0,
		100,
		vim.schedule_wrap(function()
			if not loading_popup or not loading_popup.winid then
				return
			end

			local icon = spinner_frames[frame_idx]
			frame_idx = (frame_idx % #spinner_frames) + 1

			local elapsed = (vim.loop.hrtime() - start_time) / 1e9
			local time_str = string.format("%.1fs", elapsed)

			local lines = {
				string.format(" %s %s", icon, model_name or "AI"),
				string.format(" Time: %s", time_str),
				string.format(" Context: %d files", #state.context_files),
				string.format(" Edit: %s", fname),
			}

			if is_retry then
				-- Insert the attempt line right after the model name
				table.insert(lines, 2, string.format(" Attempt: %d (Auto-Fixing)", retry_count + 1))
			end

			vim.api.nvim_buf_set_lines(loading_popup.bufnr, 0, -1, false, lines)
		end)
	)
end

--- Stops the loading spinner and closes the popup.
--- @param bufnr integer|nil The buffer ID (optional, currently unused).
function M.stop_spinner(bufnr)
	if spinner_timer then
		spinner_timer:stop()
		spinner_timer:close()
		spinner_timer = nil
	end
	if loading_popup then
		loading_popup:unmount()
		loading_popup = nil
	end
end

return M
