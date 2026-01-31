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

function M.get_namespace()
	return ns_id
end

function M.start_spinner(bufnr, line, model_name)
	M.stop_spinner()
	start_time = vim.loop.hrtime()

	-- Get filename for display
	local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
	if fname == "" then
		fname = "[No Name]"
	end

	loading_popup = Popup({
		enter = false,
		focusable = false,
		zindex = 50,
		position = { row = 1, col = "100%" },
		anchor = "NE",
		size = { width = 35, height = 4 }, -- Taller for more info
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

			-- Calculate elapsed time
			local elapsed = (vim.loop.hrtime() - start_time) / 1e9
			local time_str = string.format("%.1fs", elapsed)

			local lines = {
				string.format(" %s %s", icon, model_name or "AI"),
				string.format(" Time: %s", time_str),
				string.format(" Context: %d files", #state.context_files),
				string.format(" Edit: %s", fname),
			}

			vim.api.nvim_buf_set_lines(loading_popup.bufnr, 0, -1, false, lines)
		end)
	)
end

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
