local M = {}

local components = require("graft.ui.components")
local indicators = require("graft.ui.indicators")
local preview = require("graft.ui.preview")
local config = require("graft.config")
local providers = require("graft.api.providers")
local utils = require("graft.utils")
local state = require("graft.core.state")
local context_manager = require("graft.context")
local client = require("graft.api.client")

local PROMPT_REFACTOR = [[You are a diff generation tool. 
Your ONLY task is to output a UNIFIED DIFF based on the user's instruction.

STRICT RULES:
1. Output MUST start immediately with `--- a/filename`.
2. Followed by `+++ b/filename`.
3. Followed by the diff hunks starting with `@@ ... @@`.
4. Do NOT use Markdown code blocks (no ```).
5. Do NOT include any conversational text.

CRITICAL INSTRUCTION FOR COMPLETENESS:
- If the user asks to modify ALL instances, you MUST generate a diff hunk for EVERY SINGLE INSTANCE in the file.
- Do NOT stop after the first change.
- Process the ENTIRE file from top to bottom.]]

local PROMPT_PLAN = [[You are a knowledgeable Senior Technical Lead.
- Answer questions clearly and helpfully.
- Use Markdown formatting (bold, lists, code blocks) for readability.
- If the user asks for code, provide it in ```lua``` (or relevant lang) blocks.
- Be concise.]]

-- NEW: Context Management UI
function M.manage_context()
	local options = {
		components.Menu.item("Add File to Context"),
		components.Menu.item("Clear Context (" .. #state.context_files .. " files)"),
		components.Menu.item("Back"),
	}

	components.select("Context Manager", options, function(item)
		if item.text == "Add File to Context" then
			-- Try to use Telescope
			local has_tel, builtin = pcall(require, "telescope.builtin")
			if has_tel then
				builtin.find_files({
					prompt_title = "Select Context File",
					attach_mappings = function(prompt_bufnr, map)
						local actions_tel = require("telescope.actions")
						local action_state = require("telescope.actions.state")
						actions_tel.select_default:replace(function()
							actions_tel.close(prompt_bufnr)
							local selection = action_state.get_selected_entry()
							if selection then
								local path = selection[1]
								table.insert(state.context_files, path)
								utils.notify("Added context: " .. path)
							end
						end)
						return true
					end,
				})
			else
				-- Fallback to Input
				components.ask("File Path (Relative)", function(path)
					if path and path ~= "" then
						table.insert(state.context_files, path)
						utils.notify("Added context: " .. path)
					end
				end)
			end
		elseif item.text:match("Clear Context") then
			state.context_files = {}
			utils.notify("Context Cleared.")
		elseif item.text == "Back" then
			M.start()
		end
	end)
end

function M.refactor()
	local prov = providers.get_current()
	local ok, err = prov:verify()
	if not ok then
		utils.notify(err, vim.log.levels.ERROR)
		return
	end

	local initial_state = context_manager.get_current_state()

	components.ask("Refactor Instruction", function(prompt_text)
		if not prompt_text or prompt_text == "" then
			return
		end

		local context, replace_range, is_selection = context_manager.resolve(initial_state, prompt_text)
		-- Get External Context
		local extra_context = context_manager.get_external_context()

		local target_buf = vim.api.nvim_get_current_buf()
		local filetype = vim.bo.filetype
		local filename = vim.fn.expand("%:t")

		local full_prompt = string.format(
			[[
%s

TARGET FILE: %s (Type: %s)
--------------------------------------------------
%s
--------------------------------------------------

INSTRUCTION: %s

RESPONSE (Unified Diff Only):]],
			extra_context, -- Injected at the top
			filename,
			filetype,
			context,
			prompt_text
		)

		client.stream_to_buffer(prov, full_prompt, target_buf, {
			replace_range = replace_range,
			is_chat = false,
			is_patch = true,
			model_name = prov.model_id or prov.name,
			system_prompt = PROMPT_REFACTOR,
		})
	end)
end

function M.plan()
	local prov = providers.get_current()
	local ok, err = prov:verify()
	if not ok then
		utils.notify(err, vim.log.levels.ERROR)
		return
	end

	local filename = vim.fn.expand("%:t")
	local initial_state = context_manager.get_current_state()

	components.open_chat(function(user_input, chat_buf)
		local line_count = vim.api.nvim_buf_line_count(chat_buf)
		vim.api.nvim_buf_set_lines(chat_buf, line_count, line_count, false, {
			"",
			"## User",
			user_input,
			"",
			"## graft",
		})

		local prompt_to_send = user_input

		if #state.chat_history == 0 then
			local context, _, is_sel = context_manager.resolve(initial_state, user_input)
			local extra_context = context_manager.get_external_context()
			local ctx_label = is_sel and "Selected Code" or "File Context"

			prompt_to_send = string.format(
				"%s\n%s (%s):\n%s\n\nQuestion: %s",
				extra_context,
				ctx_label,
				filename,
				context,
				user_input
			)
		end

		client.stream_to_buffer(prov, prompt_to_send, chat_buf, {
			replace_range = nil,
			is_chat = true,
			is_patch = false,
			model_name = prov.model_id or prov.name,
			system_prompt = PROMPT_PLAN,
		})
	end)
end

function M.select_model()
	local items = {}
	for key, val in pairs(providers.list) do
		table.insert(items, components.Menu.item(val.name, { id = key }))
	end

	components.select("Select AI Provider", items, function(item)
		if item.id == "ollama" then
			if not utils.is_ollama_running() then
				utils.start_ollama()
			end
			utils.get_ollama_models(function(models)
				if #models == 0 then
					utils.notify("No models found.", vim.log.levels.WARN)
					return
				end
				local model_items = {}
				for _, m in ipairs(models) do
					table.insert(model_items, components.Menu.item(m))
				end
				components.select("Select Local Model", model_items, function(model_item)
					config.state.current_provider = "ollama"
					providers.list.ollama.model_id = model_item.text
					utils.notify("Switched to Ollama: " .. model_item.text)
				end)
			end)
		else
			config.state.current_provider = item.id
			utils.notify("Switched to " .. item.text)
		end
	end)
end

function M.start()
	local prov = providers.get_current()
	local model_display = prov.model_id or prov.name
	local ctx_count = #state.context_files

	local options = {
		components.Menu.item("Refactor (Smart Patch)"),
		components.Menu.item("Plan (Chat Mode)"),
		components.Menu.item("Context: " .. ctx_count .. " files"), -- NEW Item
		components.Menu.item("Select Model"),
	}

	components.select("graft [" .. model_display .. "]", options, function(menu_mode)
		if menu_mode.text == "Refactor (Smart Patch)" then
			M.refactor()
		elseif menu_mode.text == "Plan (Chat Mode)" then
			M.plan()
		elseif menu_mode.text:match("Context") then
			M.manage_context()
		elseif menu_mode.text == "Select Model" then
			M.select_model()
		end
	end)
end

function M.accept_changes()
	if not state.transaction.bufnr then
		return
	end
	local ns_id = indicators.get_namespace()
	vim.api.nvim_buf_clear_namespace(state.transaction.bufnr, ns_id, 0, -1)
	preview.close()
	state.reset()
	utils.notify("Changes Accepted.")
end

function M.reject_changes()
	if not state.transaction.bufnr or not state.transaction.original_lines then
		utils.notify("No changes to reject.", vim.log.levels.WARN)
		return
	end
	local ns_id = indicators.get_namespace()
	vim.api.nvim_buf_set_lines(state.transaction.bufnr, 0, -1, false, state.transaction.original_lines)
	vim.api.nvim_buf_clear_namespace(state.transaction.bufnr, ns_id, 0, -1)
	preview.close()
	utils.notify("Changes Rejected.")
	state.reset()
end

return M
