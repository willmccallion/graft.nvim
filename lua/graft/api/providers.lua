--- @module graft.api.providers
--- @brief Provider configurations and utilities for LLM interactions.
--- This module defines how to interact with different LLM providers (Gemini, Ollama, etc.),
--- including request formatting, URL generation, and response parsing.

local M = {}
local utils = require("graft.utils")
local config = require("graft.config")
local parsers = require("graft.api.parsers")

--- Retrieves the Gemini API key from environment variables.
--- @return string|nil The API key if found, nil otherwise.
local function get_key()
	return os.getenv("GEMINI_API_KEY")
end

--- Generates the streaming API URL for a specific Gemini model.
--- @param model string The model identifier.
--- @return string The full API endpoint URL.
local function get_url(model)
	return "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":streamGenerateContent"
end

--- Constructs the HTTP headers required for Gemini API requests.
--- @return table A list of header strings.
local function get_headers()
	local key = get_key() or ""
	return { "Content-Type: application/json", "x-goog-api-key: " .. key }
end

--- Constructs the JSON request body for Gemini API calls.
--- @param prompt string The user prompt.
--- @param model string The model identifier.
--- @param history table|nil Optional conversation history.
--- @param system_instruction_text string|nil Optional system instruction override.
--- @return string JSON encoded request body.
local function make_gemini_body(prompt, model, history, system_instruction_text)
	utils.debug_log("--- NEW REQUEST START ---")

	local contents = {}

	local default_sys =
		"You are a coding agent. Output UNIFIED DIFF format only. Start immediately with '---'. Do NOT use Markdown."
	local sys_text = system_instruction_text or default_sys

	local sys_prompt = { parts = { { text = sys_text } } }

	if history and #history > 0 then
		for _, msg in ipairs(history) do
			if msg.role ~= "system" then
				local role = (msg.role == "assistant") and "model" or "user"
				table.insert(contents, { role = role, parts = { { text = msg.content } } })
			end
		end
	else
		table.insert(contents, { role = "user", parts = { { text = prompt } } })
	end

	-- local is_flash = model:match("flash")
	local max_tokens = 1000000

	return vim.fn.json_encode({
		contents = contents,
		systemInstruction = sys_prompt,
		generationConfig = { temperature = 0.0, maxOutputTokens = max_tokens },
	})
end

--- Registry of supported LLM providers.
--- @type table<string, Provider>
---
--- @class Provider
--- @field name string Display name.
--- @field model_id string|nil Internal model identifier.
--- @field url string API endpoint.
--- @field headers table HTTP headers.
--- @field verify function Function to check if the provider is available/configured.
--- @field make_body function(prompt: string, model: string, history: table|nil, system_instruction_text: string|nil): string Function to format the request payload.
--- @field parse_chunk function(chunk: string): string|nil Function to parse streaming response chunks.
M.list = {
	ollama = {
		name = "Ollama",
		model_id = nil,
		url = "http://localhost:11434/api/chat",
		headers = { "Content-Type: application/json" },
		verify = function(self)
			if not utils.is_ollama_running() then
				utils.start_ollama()
			end
			if not self.model_id then
				utils.get_ollama_models(function(models)
					if #models > 0 then
						self.model_id = models[1]
					end
				end)
			end
			return true
		end,
		make_body = function(prompt, model, history, system_instruction_text)
			local messages = {}

			if system_instruction_text then
				table.insert(messages, { role = "system", content = system_instruction_text })
			end

			if history and #history > 0 then
				for _, m in ipairs(history) do
					table.insert(messages, m)
				end
			else
				table.insert(messages, { role = "user", content = prompt })
			end
			return vim.fn.json_encode({
				model = model,
				messages = messages,
				stream = true,
				options = { num_predict = -1 }, -- -1 = infinite/max context
			})
		end,
		parse_chunk = parsers.parse_ollama_chunk,
	},

	gemini_flash = {
		name = "Gemini 3.0 Flash",
		model_id = "gemini-3-flash-preview",
		url = get_url("gemini-3-flash-preview"),
		headers = get_headers(),
		verify = function()
			if not get_key() then
				utils.debug_log("MISSING KEY")
				return false, "Gemini API Key is missing. Please set GEMINI_API_KEY."
			end
			return true
		end,
		make_body = make_gemini_body,
		parse_chunk = parsers.parse_gemini_stream,
	},

	gemini_pro = {
		name = "Gemini 3.0 Pro",
		model_id = "gemini-3-pro-preview",
		url = get_url("gemini-3-pro-preview"),
		headers = get_headers(),
		verify = function()
			if not get_key() then
				utils.debug_log("MISSING KEY")
				return false, "Gemini API Key is missing. Please set GEMINI_API_KEY."
			end
			return true
		end,
		make_body = make_gemini_body,
		parse_chunk = parsers.parse_gemini_stream,
	},
}

--- Retrieves the currently active provider based on configuration.
--- It also refreshes dynamic fields (like headers/URLs) for Gemini providers.
--- @return Provider The provider configuration object.
function M.get_current()
	local key = config.state.current_provider or config.options.default_provider or "gemini_flash"
	if not M.list[key] then
		key = "gemini_flash"
	end
	if M.list[key].make_body == make_gemini_body then
		M.list[key].headers = get_headers()
		M.list[key].url = get_url(M.list[key].model_id)
	end
	return M.list[key]
end

return M
