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
--- STRICTLY FORBIDS COMMENTS unless requested.
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
1. **Separator**: Use "==== REPLACE" exactly. Do NOT use "====".
2. **Context**: Include enough lines in the SEARCH block to uniquely locate the code.
3. **Accuracy**: The SEARCH block must match the original file content exactly (including whitespace).
4. **Completeness**: If replacing a function, include the whole function signature in the SEARCH block.
5. **No Diffs**: Do NOT use Unified Diff format (no +++ or ---).
6. **No Markdown**: Output the blocks directly without markdown code fences.
7. **NO COMMENTS**: Do NOT add comments, docstrings, Doxygen, or explanations unless the user explicitly asks for them. Output raw, functional code only.
]]

--- Prompt plan for the Senior Technical Lead persona.
--- Defines formatting rules and communication style.
local PROMPT_PLAN = [[You are a knowledgeable Senior Technical Lead.
- Use Markdown formatting.
- Be concise but thorough.
- When suggesting code, use proper syntax highlighting.
- If providing code examples, keep them minimal and focused.]]

--- System prompt for File Header Documentation.
--- Focused on Architecture, Ownership, and High-Level Purpose.
local PROMPT_DOC_HEADER = [[You are a Documentation Expert.
Your task is to add or update the FILE-LEVEL HEADER comment at the very top of the file.

STRICT OUTPUT FORMAT:
<<<< SEARCH
[The first few lines of the file (imports, package declaration, or existing header)]
==== REPLACE
[A high-quality file header comment block]
[The original first few lines of the file]
>>>> END

RULES:
1. **Scope**: ONLY touch the top of the file. Do NOT document functions or classes further down.
2. **Content**: Describe the file's architectural role, key responsibilities, and any global assumptions.
3. **Format**: Use the standard comment style for the language (e.g., `///` or `/**` for C/C++/Rust, `#` for Python, `---` for Lua).
4. **Standard**: Follow the language's standard documentation convention (e.g., Doxygen, JSDoc, GoDoc).
5. **Preservation**: You must include the original imports/package lines in the REPLACE block so they are not deleted.
]]

--- System prompt for Selection Documentation.
--- Focused on Contracts: Parameters, Returns, and Errors.
local PROMPT_DOC_SELECTION = [[You are a Documentation Expert.
Your task is to document the SPECIFIC code block provided (Function, Struct, Enum, or Class).

STRICT OUTPUT FORMAT:
<<<< SEARCH
[The exact code block provided in the selection]
==== REPLACE
[The documentation comment (Docstring/JSDoc/LuaDoc/Doxygen)]
[The original code block]
>>>> END

RULES:
1. **Scope**: Document ONLY the provided selection.
2. **Detail**: Explicitly document parameters (`@param`), return values (`@return`), and potential errors/exceptions (`@throws`).
3. **Clean Code**: Do NOT add inline comments inside the function body. ONLY add the documentation block above the definition.
4. **Style**: Use standard conventions (JSDoc, GoDoc, Rustdoc, Doxygen) optimized for IDE tooltips.
5. **Logic**: Do NOT change the code logic.
]]

--- System prompt for Scope Mode (Function Isolation).
--- Strictly enforces isolation and forbids comments.
local PROMPT_SCOPE = [[You are a specialized coding agent focused on a SINGLE FUNCTION.
Your task is to refactor or modify ONLY the logic inside the provided function.

STRICT OUTPUT FORMAT:
<<<< SEARCH
[Exact lines from the provided function to replace]
==== REPLACE
[The new code]
>>>> END

IMPORTANT: The separator is "==== REPLACE". Do NOT use "====".

CRITICAL RULES:
1. **Isolation**: Treat this function as an isolated unit.
2. **Assumptions**: ASSUME all imports, helper functions, and global constants defined outside this function ALREADY EXIST and work correctly.
3. **No Side Effects**: Do NOT add imports, do NOT add file-level constants, do NOT modify anything outside this function's scope.
4. **Signature**: Keep the function signature (name, params) unchanged unless explicitly instructed to refactor the API.
5. **NO COMMENTS**: Do NOT add comments, docstrings, Doxygen, or explanations unless the user explicitly asks for them. Output raw, functional code only.
]]

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
		components.Menu.item("Scope Refactor (Function)"),
		components.Menu.item("Doc: File Header"),
		components.Menu.item("Doc: Selection (Visual)"),
		components.Menu.item("Plan (Chat Mode)"),
		components.Menu.item("Context Manager (" .. ctx_count .. ")"),
		components.Menu.item("Select Model"),
	}

	components.select("graft [" .. model_display .. "]", options, function(menu_mode)
		if menu_mode.text == "Refactor (Smart Patch)" then
			M.refactor()
		elseif menu_mode.text == "Scope Refactor (Function)" then
			M.scope_refactor()
		elseif menu_mode.text == "Doc: File Header" then
			M.document_file_header()
		elseif menu_mode.text == "Doc: Selection (Visual)" then
			M.document_selection()
		elseif menu_mode.text == "Plan (Chat Mode)" then
			M.plan()
		elseif menu_mode.text:match("Context Manager") then
			M.manage_context()
		elseif menu_mode.text == "Select Model" then
			M.select_model()
		end
	end)
end

--- Helper to execute a patch job.
--- @param instruction string The user instruction.
--- @param state_obj table The context state (visual/normal/function).
--- @param system_prompt_override string|nil Optional system prompt override.
--- @param content_header_override string|nil Optional override for the content header (e.g., "TARGET FUNCTION").
local function run_patch_job(instruction, state_obj, system_prompt_override, content_header_override)
	local prov = providers.get_current()
	local ok, err = prov:verify()
	if not ok then
		utils.notify(err, vim.log.levels.ERROR)
		return
	end

	local context, replace_range, _ = context_manager.resolve(state_obj, instruction)
	local extra_context = context_manager.get_external_context()
	local target_buf = vim.api.nvim_get_current_buf()
	local filename = vim.api.nvim_buf_get_name(target_buf)
	if filename == "" then
		filename = "[No Name]"
	else
		filename = vim.fn.fnamemodify(filename, ":.")
	end

	local content_header = content_header_override or "TARGET FILE CONTENT"

	local full_prompt = string.format(
		"%s\n\n=== TARGET FILE: %s ===\n=== %s ===\n%s\n\n=== INSTRUCTION ===\n%s",
		extra_context,
		filename,
		content_header,
		context,
		instruction
	)

	client.stream_to_buffer(prov, full_prompt, target_buf, {
		replace_range = replace_range,
		is_chat = false,
		is_patch = true,
		model_name = prov.model_id or prov.name,
		system_prompt = system_prompt_override or PROMPT_REFACTOR,
	})
end

--- Initiates the Refactor (Smart Patch) workflow.
--- Verifies the provider, captures the current context, prompts the user for instructions,
--- and streams the AI response to the buffer as a patch.
function M.refactor()
	local initial_state = context_manager.get_current_state()
	components.ask("Refactor Instruction", function(prompt_text)
		if not prompt_text or prompt_text == "" then
			return
		end
		run_patch_job(prompt_text, initial_state, PROMPT_REFACTOR)
	end)
end

--- Initiates the Scope Refactor (Function) workflow.
--- Targets only the function under the cursor.
function M.scope_refactor()
	local initial_state = context_manager.get_current_state("function")

	if initial_state.type == "function" then
		local buf = vim.api.nvim_get_current_buf()
		local ns = vim.api.nvim_create_namespace("graft_flash")
		vim.highlight.range(
			buf,
			ns,
			"Visual",
			{ initial_state.start_line, 0 },
			{ initial_state.end_line, -1 },
			{ regtype = "V", inclusive = true }
		)
		vim.defer_fn(function()
			vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		end, 500)
	end

	components.ask("Refactor Function", function(prompt_text)
		if not prompt_text or prompt_text == "" then
			return
		end
		run_patch_job(prompt_text, initial_state, PROMPT_SCOPE, "TARGET FUNCTION")
	end)
end

--- Generates a File Header for the current file.
function M.document_file_header()
	-- We pass 'normal' state to get the full file context,
	-- but the prompt instructs to only touch the top.
	local initial_state = context_manager.get_current_state()
	utils.notify("Generating file header...")
	run_patch_job(
		"Analyze the file content and generate a comprehensive file-level header comment.",
		initial_state,
		PROMPT_DOC_HEADER,
		"FULL FILE CONTENT"
	)
end

--- Documents the currently selected code (Visual Mode).
function M.document_selection()
	local initial_state = context_manager.get_current_state()

	if initial_state.type ~= "visual" then
		utils.notify("Please select code in Visual Mode first.", vim.log.levels.WARN)
		return
	end

	utils.notify("Documenting selection...")
	run_patch_job("Add documentation comments to this selection.", initial_state, PROMPT_DOC_SELECTION, "SELECTED CODE")
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
