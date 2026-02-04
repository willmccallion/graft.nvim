--- @module graft.api.client
--- @brief Handles streaming responses from LLM providers and processing them into Neovim buffers.
local M = {}
local Job = require("plenary.job")
local state = require("graft.core.state")
local config = require("graft.config")
local utils = require("graft.utils")
local preview = require("graft.ui.preview")
local indicators = require("graft.ui.indicators")
local patcher = require("graft.core.patcher")
local parsers = require("graft.api.parsers")

--- Stops the currently active streaming job.
function M.stop_job()
	if state.job then
		state.job:shutdown()
		indicators.stop_spinner(state.transaction.bufnr)
		utils.notify("Generation stopped.", vim.log.levels.WARN)
	end
	state.is_streaming = false
end

--- Helper to write logs to cache dir
local function write_log(filename, content, header)
	local path = vim.fn.stdpath("cache") .. "/" .. filename
	local f = io.open(path, "w")
	if f then
		if header then
			f:write(header .. "\n")
		end
		f:write(content)
		f:close()
		return path
	end
	return nil
end

--- Initiates a streaming request to an LLM provider and processes the output.
--- @param provider table The provider configuration.
--- @param prompt string The user prompt.
--- @param target_buf number The buffer handle.
--- @param opts table Configuration options.
function M.stream_to_buffer(provider, prompt, target_buf, opts)
	local is_chat = opts.is_chat or false
	local is_patch = opts.is_patch or false
	local model_name = opts.model_name or "Unknown Model"

	-- Track retries
	local retry_count = opts.retry_count or 0
	local max_retries = 2

	parsers.reset()

	local show_preview = config.options.show_preview or config.options.debug

	if is_patch and show_preview then
		local buf, _ = preview.ensure_preview_window()
		local header = retry_count > 0 and ("--- RETRY ATTEMPT " .. retry_count .. " ---")
			or ("--- graft START [" .. model_name .. "] ---")
		vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", header, "" })
	end

	local output_buf = target_buf
	local current_line_idx = is_chat and vim.api.nvim_buf_line_count(target_buf) or 0

	local sr_mode = "IDLE"
	local search_buffer = {}
	local replace_buffer = {}
	local buffer_text = ""
	local patches_applied = 0

	-- Stats tracking
	local last_patch_result = { success = false, score = 0 }
	local min_score = 1.0
	local captured_search_block = {}

	local usage_stats = { input = 0, output = 0, total = 0 }

	local function process_line(line)
		line = line:gsub("\r", "")

		if is_chat then
			vim.api.nvim_buf_set_lines(output_buf, current_line_idx, current_line_idx, false, { line })
			current_line_idx = current_line_idx + 1
			local win_ids = vim.fn.win_findbuf(output_buf)
			for _, win_id in ipairs(win_ids) do
				vim.api.nvim_win_call(win_id, function()
					vim.cmd("normal! G")
				end)
			end
		elseif is_patch then
			if show_preview then
				preview.log(line)
			end

			if line:match("^%s*<<<< SEARCH") then
				sr_mode = "SEARCH"
				search_buffer = {}
				return
			elseif line:match("^%s*==== REPLACE") then
				sr_mode = "REPLACE"
				replace_buffer = {}
				return
			elseif line:match("^%s*>>>> END") then
				if sr_mode == "REPLACE" then
					captured_search_block = vim.deepcopy(search_buffer)

					last_patch_result =
						patcher.apply_search_replace(target_buf, search_buffer, replace_buffer, opts.replace_range)

					if last_patch_result.success then
						patches_applied = patches_applied + 1
						if last_patch_result.score < min_score then
							min_score = last_patch_result.score
						end
					end
				end
				sr_mode = "IDLE"
				return
			end
			if sr_mode == "SEARCH" then
				table.insert(search_buffer, line)
			elseif sr_mode == "REPLACE" then
				table.insert(replace_buffer, line)
			end
		end
	end

	state.transaction.bufnr = target_buf
	state.transaction.original_lines = nil
	state.is_streaming = true

	local spinner_line = (is_patch and opts.replace_range and opts.replace_range[1])
		or (vim.api.nvim_win_get_cursor(0)[1] - 1)

	indicators.start_spinner(target_buf, spinner_line, model_name, retry_count)

	local history = is_chat and state.chat_history or {}
	if is_chat then
		table.insert(history, { role = "user", content = prompt })
	end

	local body = provider.make_body(prompt, provider.model_id, history, opts.system_prompt)
	local headers = type(provider.headers) == "function" and provider.headers() or provider.headers
	local url = type(provider.url) == "function" and provider.url(provider.model_id) or provider.url

	local args = { "-s", "-S", "-N", "-X", "POST", url, "-d", body }
	for _, h in ipairs(headers) do
		table.insert(args, "-H")
		table.insert(args, h)
	end

	local full_response = ""
	local stderr_buffer = ""

	state.job = Job:new({
		command = "curl",
		args = args,
		on_stdout = function(_, data)
			if not state.is_streaming then
				return
			end

			local content, metadata = provider.parse_chunk(data)
			if metadata then
				usage_stats = metadata
			end
			if not content or content == "" then
				return
			end

			full_response = full_response .. content
			vim.schedule(function()
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
		on_stderr = function(_, data)
			if data then
				stderr_buffer = stderr_buffer .. data .. "\n"
			end
		end,
		on_exit = function()
			vim.schedule(function()
				if buffer_text ~= "" then
					process_line(buffer_text)
				end

				-- --- ERROR LOGGING (NETWORK/CURL) ---
				if full_response == "" and stderr_buffer ~= "" then
					local header = "--- GRAFT API ERROR ---\nURL: " .. url
					local log_path = write_log("graft_error.log", stderr_buffer, header)
					utils.notify(
						"API Request Failed. Debug info: " .. (log_path or "Error writing log"),
						vim.log.levels.ERROR
					)

					state.is_streaming = false
					indicators.stop_spinner(target_buf)
					return
				end

				-- --- RETRY LOGIC START ---
				if is_patch and patches_applied == 0 and retry_count < max_retries then
					if last_patch_result.score > 0.45 then
						utils.notify(
							string.format(
								"Patch failed (Confidence %.0f%%). Attempting auto-fix...",
								last_patch_result.score * 100
							),
							vim.log.levels.WARN
						)

						local search_block_str = table.concat(captured_search_block, "\n")
						local repair_prompt = string.format(
							"Your previous attempt failed because the SEARCH block did not match the file content exactly.\n"
								.. "Confidence Score: %.2f%%\n"
								.. "Your SEARCH block was:\n```\n%s\n```\n"
								.. "Please RETRY. Ensure the SEARCH block matches the file content byte-for-byte (check indentation and whitespace). Output the corrected SEARCH/REPLACE block.",
							last_patch_result.score * 100,
							search_block_str
						)

						local combined_prompt = prompt .. "\n\n" .. "SYSTEM: " .. repair_prompt
						local new_opts = vim.deepcopy(opts)
						new_opts.retry_count = retry_count + 1

						M.stream_to_buffer(provider, combined_prompt, target_buf, new_opts)
						return
					elseif last_patch_result.score > 0 and last_patch_result.score <= 0.45 then
						utils.notify(
							"Patch failed. The model hallucinated the code structure (Low Confidence).",
							vim.log.levels.ERROR
						)
					end
				end
				-- --- RETRY LOGIC END ---

				state.is_streaming = false
				indicators.stop_spinner(target_buf)

				if is_chat then
					table.insert(state.chat_history, { role = "assistant", content = full_response })
				end

				local token_msg = ""
				local t_in = usage_stats.input or 0
				local t_out = usage_stats.output or 0
				if (t_in + t_out) > 0 then
					token_msg = string.format(" [In:%d Out:%d]", t_in, t_out)
				end

				if is_patch then
					if patches_applied > 0 then
						-- SUCCESS CASE
						local attempts = retry_count + 1
						local score_display = math.floor(min_score * 100)
						local msg = string.format(
							"Refactor Complete (Try %d, %d%% match). Applied %d changes.%s",
							attempts,
							score_display,
							patches_applied,
							token_msg
						)
						utils.notify(msg)
						preview.close()
					elseif full_response:match("<<<< SEARCH") then
						-- FAILURE CASE 1: AI tried to code, but context match failed
						local log_path =
							write_log("graft_ai_response.log", full_response, "--- GRAFT FAILED PATCH RESPONSE ---")

						if retry_count == max_retries then
							utils.notify(
								"Auto-fix failed. Response saved to: " .. (log_path or "cache"),
								vim.log.levels.ERROR
							)
						else
							utils.notify(
								"Refactor Failed: Context match error. Response saved to: " .. (log_path or "cache"),
								vim.log.levels.ERROR
							)
						end
					else
						-- FAILURE CASE 2: AI didn't output code blocks (Chatted instead)
						local log_path = write_log(
							"graft_ai_response.log",
							full_response,
							"--- GRAFT INVALID RESPONSE (NO BLOCKS) ---"
						)
						utils.notify(
							"Refactor Failed: No SEARCH/REPLACE blocks found. Response saved to: "
								.. (log_path or "cache"),
							vim.log.levels.WARN
						)
					end
				else
					utils.notify("Done." .. token_msg)
				end
			end)
		end,
	})
	state.job:start()
end

return M
