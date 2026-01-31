local M = {}
local utils = require("graft.utils")

local chunk_buffer = ""

function M.reset()
	chunk_buffer = ""
end

-- Returns: text (string|nil), metadata (table|nil)
function M.parse_gemini_stream(data)
	if not data or data == "" then
		return nil, nil
	end
	chunk_buffer = chunk_buffer .. data

	local accumulated_text = ""
	local metadata = nil

	-- Loop to process ALL complete objects in the buffer
	while true do
		-- 1. Clean leading junk (whitespace, comma, bracket)
		local clean_start = chunk_buffer:match("^%s*[%[%,]%s*(.*)")
		if clean_start then
			chunk_buffer = clean_start
		end

		-- Trim leading whitespace
		chunk_buffer = chunk_buffer:gsub("^%s+", "")

		-- 2. Check for Start of Object
		if chunk_buffer:sub(1, 1) ~= "{" then
			-- If we see a closing bracket alone, the stream is likely done
			if chunk_buffer:match("^%]") then
				chunk_buffer = ""
				utils.debug_log("[END] Stream finished.")
			end
			break
		end

		-- 3. Robust JSON Finder
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
				-- SUCCESS: We found a valid JSON object
				match_found = true

				-- Remove this object from buffer
				chunk_buffer = chunk_buffer:sub(p + 1)

				-- Extract Text
				if decoded.candidates and decoded.candidates[1].content then
					local parts = decoded.candidates[1].content.parts
					if parts and parts[1] and parts[1].text then
						accumulated_text = accumulated_text .. parts[1].text
					end
				end

				-- Extract Token Usage (Gemini usually sends this in the last chunk)
				-- FIX: Added 'or 0' to prevent nil errors if API omits fields
				if decoded.usageMetadata then
					metadata = {
						input = decoded.usageMetadata.promptTokenCount or 0,
						output = decoded.usageMetadata.candidatesTokenCount or 0,
						total = decoded.usageMetadata.totalTokenCount or 0,
					}
				end

				if decoded.error then
					-- FIX: Wrap UI notification in schedule to prevent E5560
					vim.schedule(function()
						utils.notify("Gemini API Error: " .. decoded.error.message, vim.log.levels.ERROR)
					end)
				end

				-- Break inner loop to process next object in outer loop
				break
			end
		end

		if not match_found then
			-- We ran out of '}' but didn't find a valid object yet.
			-- Wait for more network data.
			break
		end
	end

	if accumulated_text == "" and not metadata then
		return nil, nil
	end

	-- Clean formatting (optional, but keeps diffs clean)
	local clean_text = accumulated_text:gsub("^```%w*%s*", ""):gsub("%s*```$", ""):gsub("^Here is the code:%s*", "")

	return clean_text, metadata
end

-- Returns: text (string|nil), metadata (table|nil)
function M.parse_ollama_chunk(data)
	local ok, decoded = pcall(vim.json.decode, data)
	if ok then
		local meta = nil
		-- Ollama sends stats in the final response where done=true
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

		-- Return just metadata if it's the final frame without content
		if meta then
			return "", meta
		end
	end
	return nil, nil
end

return M
