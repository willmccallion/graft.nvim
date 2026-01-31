--- @module graft.utils
--- @brief Utility functions for Graft
---
--- This module contains various utility functions used throughout the plugin,
--- including logging, context management, and Ollama service interaction.
local M = {}

local config = require("graft.config")
local Job = require("plenary.job")
local state = require("graft.core.state")

--- Sends a notification to the user
---@param msg string The message to display
---@param level number|nil The log level (default: vim.log.levels.INFO)
function M.notify(msg, level)
	vim.notify("graft: " .. msg, level or vim.log.levels.INFO)
end

--- Logs a debug message if debug mode is enabled
---@param msg string The debug message to log
function M.debug_log(msg)
	if config.options.debug then
		vim.schedule(function()
			vim.notify("[graft Debug] " .. msg, vim.log.levels.INFO)
		end)
	end
end

--- Adds a file to the context state
---@param path string The file path to add
---@return boolean success True if the file was added, false otherwise
function M.add_to_context(path)
	if not path or path == "" then
		return false
	end
	local absolute_path = vim.fn.fnamemodify(path, ":p")

	if vim.fn.isdirectory(absolute_path) == 1 then
		return false
	end

	-- Check for duplicates
	for _, existing in ipairs(state.context_files) do
		if existing == absolute_path then
			return false
		end
	end

	table.insert(state.context_files, absolute_path)
	return true
end

--- Gets the current visual selection
---@return string text The selected text
---@return number start_line The start line number (0-indexed)
---@return number end_line The end line number (0-indexed)
function M.get_visual_selection()
	local s_start = vim.fn.getpos("'<")
	local s_end = vim.fn.getpos("'>")
	local lines = vim.api.nvim_buf_get_lines(0, s_start[2] - 1, s_end[2], false)
	return table.concat(lines, "\n"), s_start[2] - 1, s_end[2] - 1
end

--- Checks if the Ollama service is running
---@return boolean is_running True if Ollama is running, false otherwise
function M.is_ollama_running()
	local handle = io.popen("curl -s -o /dev/null -w '%{http_code}' http://localhost:11434")
	local result = handle:read("*a")
	handle:close()
	return result == "200"
end

--- Starts the Ollama service if it's not already running
---@return boolean success True if started or already running
function M.start_ollama()
	if M.is_ollama_running() then
		return true
	end
	M.notify("Starting Ollama...", vim.log.levels.INFO)
	vim.loop.spawn("ollama", { args = { "serve" }, detached = true }, function() end)
	return true
end

--- Fetches available Ollama models asynchronously
---@param callback function A callback function that receives a list of model names
function M.get_ollama_models(callback)
	Job:new({
		command = "curl",
		args = { "-s", "http://localhost:11434/api/tags" },
		on_exit = function(j, code)
			if code ~= 0 then
				vim.schedule(function()
					callback({})
				end)
				return
			end
			local result = table.concat(j:result(), "")
			local ok, data = pcall(vim.json.decode, result)
			local models = {}
			if ok and data.models then
				for _, m in ipairs(data.models) do
					table.insert(models, m.name)
				end
			end
			vim.schedule(function()
				callback(models)
			end)
		end,
	}):start()
end

return M
