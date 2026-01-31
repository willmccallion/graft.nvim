--- @module graft.parser
--- @description Handles parsing of streaming responses from LLM providers like Gemini and Ollama.
local M = {}
local utils = require("graft.utils")

local chunk_buffer = ""

--- Resets the internal buffer used for stream parsing.
function M.reset()
	chunk_buffer = ""
end

--- Parses a chunk of data from a Gemini API stream.
--- Handles partial JSON chunks and extracts text and usage metadata.
--- @param data string Raw data chunk from the stream.
--- @return string|nil text Extracted and cleaned text.
--- @return table|nil metadata Token usage statistics.
function M.parse_gemini_stream(data)
	if not data or data == "" then
		return nil, nil
	end
	chunk_buffer = chunk_buffer .. data

	local accumulated_text = ""
	local metadata = nil

	while true do
		local clean_start = chunk_buffer:match("^%s*[%[%,]%s*(.*)")
		if clean_start then
			chunk_buffer = clean_start
		end

		chunk_buffer = chunk_buffer:gsub("^%s+", "")

		if chunk_buffer:sub(1, 1) ~= "{" then
			if chunk_buffer:match("^%]") then
				chunk_buffer = ""
				utils.debug_log("[END] Stream finished.")
			end
			break
		end

		local match_found = false
		local p = 0

		while true do
			p = string.find(chunk_buffer, "}", p + 1)
			if not p then
				break
			end

			local potential_json = chunk_buffer:sub(1, p)
			local ok, decoded = pcall(vim.json.decode, potential_json)

			if ok then
				match_found = true

				chunk_buffer = chunk_buffer:sub(p + 1)

				if decoded.candidates and decoded.candidates[1].content then
					local parts = decoded.candidates[1].content.parts
					if parts and parts[1] and parts[1].text then
						accumulated_text = accumulated_text .. parts[1].text
					end
				end

				if decoded.usageMetadata then
					metadata = {
						input = decoded.usageMetadata.promptTokenCount or 0,
						output = decoded.usageMetadata.candidatesTokenCount or 0,
						total = decoded.usageMetadata.totalTokenCount or 0,
					}
				end

				if decoded.error then
					vim.schedule(function()
						utils.notify("Gemini API Error: " .. decoded.error.message, vim.log.levels.ERROR)
					end)
				end

				break
			end
		end

		if not match_found then
			break
		end
	end

	if accumulated_text == "" and not metadata then
		return nil, nil
	end

	local clean_text = accumulated_text:gsub("^```%w*%s*", ""):gsub("%s*```$", ""):gsub("^Here is the code:%s*", "")

	return clean_text, metadata
end

--- Parses a single JSON chunk from an Ollama API stream.
--- @param data string Raw JSON string from Ollama.
--- @return string|nil content Extracted message content.
--- @return table|nil metadata Token usage statistics if the stream is complete.
function M.parse_ollama_chunk(data)
	local ok, decoded = pcall(vim.json.decode, data)
	if ok then
		local meta = nil
		if decoded.done and decoded.prompt_eval_count then
			meta = {
				input = decoded.prompt_eval_count or 0,
				output = decoded.eval_count or 0,
				total = (decoded.prompt_eval_count or 0) + (decoded.eval_count or 0),
			}
		end

		if decoded.message and decoded.message.content then
			return decoded.message.content, meta
		end

		if meta then
			return "", meta
		end
	end
	return nil, nil
end

return M
