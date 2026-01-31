--- @module graft.actions
--- @brief Main UI controller for the Graft plugin.
---
--- This module provides the primary entry points for user interaction with Graft.
--- It handles:
--- - Context management (adding files/directories to AI context).
--- - Refactor workflow (generating smart patches for code modification).
--- - Plan workflow (interactive chat for architectural planning).
--- - Model and provider selection.
--- - Transaction management (accepting/rejecting AI-generated changes).
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

--- System prompt for the Refactor (Smart Patch) workflow.
--- Instructs the AI to generate Search/Replace blocks instead of Diffs.
--- This matches the parser logic in client.lua and patcher.lua.
local PROMPT_REFACTOR = [[You are an expert coding agent.
Your task is to modify the provided code based on the user's instruction using Search and Replace blocks.

STRICT OUTPUT FORMAT:
For every modification, output a block in this exact format:

<<<< SEARCH
[Exact lines from the original file to be replaced]
==== REPLACE
[The new code to insert]
>>>> END

RULES:
1. **Context**: Include enough lines in the SEARCH block to uniquely locate the code.
2. **Accuracy**: The SEARCH block must match the original file content exactly (including whitespace).
3. **Completeness**: If replacing a function, include the whole function signature in the SEARCH block.
4. **No Diffs**: Do NOT use Unified Diff format (no +++ or ---).
5. **No Markdown**: Output the blocks directly without markdown code fences.
]]

--- Prompt plan for the Senior Technical Lead persona.
--- Defines formatting rules and communication style.
local PROMPT_PLAN = [[You are a knowledgeable Senior Technical Lead.
- Use Markdown formatting.
- Be concise but thorough.
- When suggesting code, use proper syntax highlighting.]]

--- Recursively adds files from a directory to the context.
--- Skips .git and node_modules directories to avoid cluttering the context.
--- @param dir_path string: The path to the directory to add.
local function add_directory_recursive(dir_path)
	local abs_dir = vim.fn.fnamemodify(dir_path, ":p")
	if vim.fn.isdirectory(abs_dir) == 0 then
		utils.notify("Directory not found: " .. dir_path, vim.log.levels.ERROR)
		return
	end

	local files = vim.fn.glob(abs_dir .. "**/*", true, true)
	local added = 0
	for _, file in ipairs(files) do
		if vim.fn.isdirectory(file) == 0 and not file:match("/%.git/") and not file:match("/node_modules/") then
			if utils.add_to_context(file) then
				added = added + 1
			end
		end
	end
	utils.notify("Added " .. added .. " files from " .. dir_path)
end

--- Opens a Telescope picker to select a directory for context.
--- Falls back to manual input if Telescope is not installed.
--- @param callback function: The function to call with the selected directory path.
local function select_dir_telescope(callback)
	local has_tel, _ = pcall(require, "telescope")
	if not has_tel then
		utils.notify("Telescope not found. Falling back to manual input.", vim.log.levels.WARN)
		components.ask("Directory Path", callback)
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions_tel = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "Select Directory for Context",
			finder = finders.new_oneshot_job({ "find", ".", "-type", "d", "-not", "-path", "*/.*" }, {}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, _)
				actions_tel.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions_tel.close(prompt_bufnr)
					if selection then
						callback(selection[1])
					end
				end)
				return true
			end,
		})
		:find()
end

--- Opens the Context Manager menu.
--- Allows the user to add files (supports multi-select via Telescope), add directories,
--- clear the current context, or return to the main menu.
function M.manage_context()
	local ctx_label = "Context Manager (" .. #state.context_files .. " files)"
	local options = {
		components.Menu.item("Add File(s) (Multi-select)"),
		components.Menu.item("Add Directory (Telescope)"),
		components.Menu.item("Clear All Context"),
		components.Menu.item("Back"),
	}

	components.select(ctx_label, options, function(item)
		if item.text:match("Add File") then
			local has_tel, builtin = pcall(require, "telescope.builtin")
			if has_tel then
				builtin.find_files({
					prompt_title = "Tab to select multiple, Enter to finish",
					attach_mappings = function(prompt_bufnr, map)
						local actions_tel = require("telescope.actions")
						local action_state = require("telescope.actions.state")
						actions_tel.select_default:replace(function()
							local picker = action_state.get_current_picker(prompt_bufnr)
							local multi = picker:get_multi_selection()
							local count = 0
							if #multi > 0 then
								for _, entry in ipairs(multi) do
									if utils.add_to_context(entry[1] or entry.path) then
										count = count + 1
									end
								end
							else
								local selection = action_state.get_selected_entry()
								if selection and utils.add_to_context(selection[1] or selection.path) then
									count = 1
								end
							end
							actions_tel.close(prompt_bufnr)
							utils.notify("Added " .. count .. " files.")
							vim.schedule(M.manage_context)
						end)
						return true
					end,
				})
			else
				components.ask("File Path", function(path)
					utils.add_to_context(path)
					M.manage_context()
				end)
			end
		elseif item.text:match("Add Directory") then
			select_dir_telescope(function(dir)
				if dir and dir ~= "" then
					add_directory_recursive(dir)
				end
				vim.schedule(M.manage_context)
			end)
		elseif item.text:match("Clear All") then
			state.context_files = {}
			utils.notify("Context cleared.")
			M.manage_context()
		elseif item.text:match("Back") then
			M.start()
		end
	end)
end

--- Starts the main Graft interface.
--- Displays the main menu with options for Refactor, Plan, Context Manager, and Model Selection.
--- This is the primary entry point for the plugin's UI.
function M.start()
	local prov = providers.get_current()
	local model_display = prov.model_id or prov.name
	local ctx_count = #state.context_files

	local options = {
		components.Menu.item("Refactor (Smart Patch)"),
		components.Menu.item("Plan (Chat Mode)"),
		components.Menu.item("Context Manager (" .. ctx_count .. ")"),
		components.Menu.item("Select Model"),
	}

	components.select("graft [" .. model_display .. "]", options, function(menu_mode)
		if menu_mode.text == "Refactor (Smart Patch)" then
			M.refactor()
		elseif menu_mode.text == "Plan (Chat Mode)" then
			M.plan()
		elseif menu_mode.text:match("Context Manager") then
			M.manage_context()
		elseif menu_mode.text == "Select Model" then
			M.select_model()
		end
	end)
end

--- Initiates the Refactor (Smart Patch) workflow.
--- Verifies the provider, captures the current context, prompts the user for instructions,
--- and streams the AI response to the buffer as a patch.
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
		local context, replace_range, _ = context_manager.resolve(initial_state, prompt_text)
		local extra_context = context_manager.get_external_context()
		local target_buf = vim.api.nvim_get_current_buf()

		local full_prompt = string.format(
			"%s\n\n=== TARGET FILE CONTENT ===\n%s\n\n=== INSTRUCTION ===\n%s",
			extra_context,
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

--- Initiates the Plan (Chat Mode) workflow.
--- Opens a dedicated chat buffer and streams the conversation with the AI model.
--- Handles chat history and context resolution for the first message.
function M.plan()
	local prov = providers.get_current()
	local ok, err = prov:verify()
	if not ok then
		utils.notify(err, vim.log.levels.ERROR)
		return
	end
	local initial_state = context_manager.get_current_state()
	components.open_chat(function(user_input, chat_buf)
		local line_count = vim.api.nvim_buf_line_count(chat_buf)

		local input_lines = vim.split(user_input, "\n")
		local lines_to_add = { "", "## User" }
		vim.list_extend(lines_to_add, input_lines)
		table.insert(lines_to_add, "")
		table.insert(lines_to_add, "## graft")

		vim.api.nvim_buf_set_lines(chat_buf, line_count, line_count, false, lines_to_add)

		local prompt_to_send = user_input
		if #state.chat_history == 0 then
			local context, _, _ = context_manager.resolve(initial_state, user_input)
			local extra_context = context_manager.get_external_context()
			prompt_to_send = string.format("%s\n\nCONTEXT:\n%s\n\nQUESTION: %s", extra_context, context, user_input)
		end
		client.stream_to_buffer(prov, prompt_to_send, chat_buf, {
			is_chat = true,
			is_patch = false,
			model_name = prov.model_id or prov.name,
			system_prompt = PROMPT_PLAN,
		})
	end)
end

--- Opens a menu to select the AI provider and model.
--- Supports switching between configured providers (e.g., OpenAI, Anthropic) and selecting specific Ollama models.
function M.select_model()
	local items = {}
	for key, val in pairs(providers.list) do
		table.insert(items, components.Menu.item(val.name, { id = key }))
	end
	components.select("Select AI Provider", items, function(item)
		if item.id == "ollama" then
			utils.start_ollama()
			utils.get_ollama_models(function(models)
				local m_items = {}
				for _, m in ipairs(models) do
					table.insert(m_items, components.Menu.item(m))
				end
				components.select("Select Local Model", m_items, function(mi)
					config.state.current_provider = "ollama"
					providers.list.ollama.model_id = mi.text
					utils.notify("Switched to Ollama: " .. mi.text)
				end)
			end)
		else
			config.state.current_provider = item.id
			utils.notify("Switched to " .. item.text)
		end
	end)
end

--- Accepts the pending changes in the current transaction.
--- Clears indicators, closes the preview window, and resets the internal state.
function M.accept_changes()
	if not state.transaction.bufnr then
		return
	end
	vim.api.nvim_buf_clear_namespace(state.transaction.bufnr, indicators.get_namespace(), 0, -1)
	preview.close()
	state.reset()
	utils.notify("Changes Accepted.")
end

--- Rejects the pending changes in the current transaction.
--- Reverts the buffer to its original state, clears indicators, closes the preview window, and resets the internal state.
function M.reject_changes()
	if not state.transaction.bufnr or not state.transaction.original_lines then
		return
	end
	vim.api.nvim_buf_set_lines(state.transaction.bufnr, 0, -1, false, state.transaction.original_lines)
	vim.api.nvim_buf_clear_namespace(state.transaction.bufnr, indicators.get_namespace(), 0, -1)
	preview.close()
	state.reset()
	utils.notify("Changes Rejected.")
end

return M
