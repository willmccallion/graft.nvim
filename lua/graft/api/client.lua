local M = {}
local Job = require("plenary.job")
local state = require("graft.core.state")
local config = require("graft.config")
local utils = require("graft.utils")
local preview = require("graft.ui.preview")
local indicators = require("graft.ui.indicators")
local patcher = require("graft.core.patcher")
local parsers = require("graft.api.parsers")

function M.stop_job()
	if state.job then
		state.job:shutdown()
		indicators.stop_spinner(state.transaction.bufnr)
		utils.notify("Generation stopped.", vim.log.levels.WARN)
	end
	state.is_streaming = false
end

function M.stream_to_buffer(provider, prompt, target_buf, opts)
	local is_chat = opts.is_chat or false
	local is_patch = opts.is_patch or false
	local model_name = opts.model_name or "Unknown Model"

	parsers.reset()

	if is_patch and config.options.show_preview then
		local buf, _ = preview.ensure_preview_window()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "--- graft START [" .. model_name .. "] ---", "" })
	end

	local output_buf = target_buf
	local current_line_idx = is_chat and vim.api.nvim_buf_line_count(target_buf) or 0
	local patch_state = "IDLE"
	local hunk_ops = {}
	local buffer_text = ""
	local patches_applied = 0

	-- Token tracking (Initialize with 0s)
	local usage_stats = { input = 0, output = 0, total = 0 }

	local function flush_hunk()
		if #hunk_ops > 0 then
			if patcher.apply_patch_block(target_buf, hunk_ops) then
				patches_applied = patches_applied + 1
			end
			hunk_ops = {}
		end
	end

	local function process_line(line)
		line = line:gsub("\r", "")
		if is_chat then
			vim.api.nvim_buf_set_lines(output_buf, current_line_idx, current_line_idx, false, { line })
			current_line_idx = current_line_idx + 1
			-- Auto-scroll
			local win_ids = vim.fn.win_findbuf(output_buf)
			for _, win_id in ipairs(win_ids) do
				vim.api.nvim_win_call(win_id, function()
					vim.cmd("normal! G")
				end)
			end
		elseif is_patch then
			if line:match("^%s*```") then
				return
			end
			if line:match("^@@ %-") then
				flush_hunk()
				patch_state = "IN_HUNK"
				return
			end
			if patch_state == "IN_HUNK" then
				local first_char = line:sub(1, 1)
				local content = line:sub(2)
				if first_char == " " then
					table.insert(hunk_ops, { op = "ctx", text = content })
				elseif first_char == "-" then
					table.insert(hunk_ops, { op = "del", text = content })
				elseif first_char == "+" then
					table.insert(hunk_ops, { op = "add", text = content })
				else
					if line == "" then
						table.insert(hunk_ops, { op = "ctx", text = "" })
					else
						flush_hunk()
						patch_state = "IDLE"
					end
				end
			end
		end
	end

	state.transaction.bufnr = target_buf
	state.transaction.original_lines = nil
	state.is_streaming = true

	local spinner_line = (is_patch and opts.replace_range and opts.replace_range[1])
		or (vim.api.nvim_win_get_cursor(0)[1] - 1)
	indicators.start_spinner(target_buf, spinner_line, model_name)

	local history = is_chat and state.chat_history or {}
	if is_chat then
		table.insert(history, { role = "user", content = prompt })
	end

	local body = provider.make_body(prompt, provider.model_id, history, opts.system_prompt)
	local headers = type(provider.headers) == "function" and provider.headers() or provider.headers
	local url = type(provider.url) == "function" and provider.url(provider.model_id) or provider.url

	local args = { "-N", "-X", "POST", url, "-d", body }
	for _, h in ipairs(headers) do
		table.insert(args, "-H")
		table.insert(args, h)
	end

	local full_response = ""

	state.job = Job:new({
		command = "curl",
		args = args,
		on_stdout = function(_, data)
			if not state.is_streaming then
				return
			end

			-- Updated to accept metadata
			local content, metadata = provider.parse_chunk(data)

			if metadata then
				usage_stats = metadata
			end

			if not content or content == "" then
				return
			end

			full_response = full_response .. content
			vim.schedule(function()
				if is_patch then
					preview.log(content)
				end
				buffer_text = buffer_text .. content
				if buffer_text:find("\n") then
					local lines = vim.split(buffer_text, "\n")
					buffer_text = table.remove(lines)
					for _, line in ipairs(lines) do
						process_line(line)
					end
				end
			end)
		end,
		on_exit = function()
			vim.schedule(function()
				if buffer_text ~= "" then
					process_line(buffer_text)
				end
				flush_hunk()
				state.is_streaming = false
				indicators.stop_spinner(target_buf)

				if is_chat then
					table.insert(state.chat_history, { role = "assistant", content = full_response })
				end

				-- Construct status message with tokens (Defensive checks)
				local token_msg = ""
				local t_in = usage_stats.input or 0
				local t_out = usage_stats.output or 0
				local t_total = usage_stats.total or (t_in + t_out)

				if t_total > 0 then
					token_msg = string.format(" [In:%d Out:%d]", t_in, t_out)
				end

				if is_patch then
					if patches_applied > 0 then
						utils.notify("Refactor Complete. Applied " .. patches_applied .. " changes." .. token_msg)
						preview.close()
					elseif full_response:match("@@") then
						if patches_applied == 0 then
							utils.notify("Refactor Failed: Context match error." .. token_msg, vim.log.levels.ERROR)
						end
					else
						utils.notify("Refactor Failed: Invalid Diff format." .. token_msg, vim.log.levels.WARN)
					end
				else
					-- Chat completion notification
					utils.notify("Done." .. token_msg)
				end
			end)
		end,
	})
	state.job:start()
end

return M
