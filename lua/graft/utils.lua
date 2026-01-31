local M = {}
local config = require("graft.config")
local Job = require("plenary.job")
local state = require("graft.core.state")

function M.notify(msg, level)
	vim.notify("graft: " .. msg, level or vim.log.levels.INFO)
end

function M.debug_log(msg)
	if config.options.debug then
		vim.schedule(function()
			vim.notify("[graft Debug] " .. msg, vim.log.levels.INFO)
		end)
	end
end

-- NEW: Helper to add files to context with deduplication
function M.add_to_context(path)
	if not path or path == "" then
		return false
	end
	local absolute_path = vim.fn.fnamemodify(path, ":p")

	-- Don't add if it's a directory (we only want files in the context list)
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

function M.get_visual_selection()
	local s_start = vim.fn.getpos("'<")
	local s_end = vim.fn.getpos("'>")
	local lines = vim.api.nvim_buf_get_lines(0, s_start[2] - 1, s_end[2], false)
	return table.concat(lines, "\n"), s_start[2] - 1, s_end[2] - 1
end

function M.is_ollama_running()
	local handle = io.popen("curl -s -o /dev/null -w '%{http_code}' http://localhost:11434")
	local result = handle:read("*a")
	handle:close()
	return result == "200"
end

function M.start_ollama()
	if M.is_ollama_running() then
		return true
	end
	M.notify("Starting Ollama...", vim.log.levels.INFO)
	vim.loop.spawn("ollama", { args = { "serve" }, detached = true }, function() end)
	return true
end

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
