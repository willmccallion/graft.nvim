--- @module graft.actions
--- @brief Main UI controller for the Graft plugin.
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
local PROMPT_PLAN = [[You are a knowledgeable Senior Technical Lead.
- Use Markdown formatting.
- Be concise but thorough.
- When suggesting code, use proper syntax highlighting.
- If providing code examples, keep them minimal and focused.]]

--- System prompt for Scope Mode (Function Isolation).
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

local DOC_HEADER_C = [[You are a C/C++ Documentation Expert.
Your task is to add or update the FILE-LEVEL HEADER comment at the very top of the file.

STRICT OUTPUT FORMAT:
<<<< SEARCH
[The first few lines of the file (includes, macros, or existing header)]
==== REPLACE
[A high-quality file header comment block]
[The original first few lines of the file]
>>>> END

STYLE GUIDE (DOXYGEN):
1. **Style**: Use Doxygen block style (`/** ... */`).
2. **Tags**: Include `@file`, `@brief`, and `@author` (if known, otherwise omit).
3. **Content**: Describe the file's architectural role and key responsibilities.
4. **Preservation**: You must include the original includes/defines in the REPLACE block so they are not deleted.
]]

local DOC_SELECTION_C = [[You are a C/C++ Documentation Expert.
Your task is to document the SPECIFIC code block provided.

STRICT OUTPUT FORMAT:
<<<< SEARCH
[The exact code block provided in the selection]
==== REPLACE
[The documented code block]
>>>> END

STYLE GUIDE (DOXYGEN):
- **Structs/Enums**: Use `/** @brief ... */` above definition. Use `///<` for fields.
- **Functions**: Use `/** ... */` block above prototype.
- **Tags**: Use `@brief`, `@param [name] [desc]`, `@return [desc]`.

RULES:
1. **Consistency**: Apply this style to ALL types found in the selection.
2. **No Logic Changes**: Do not modify the actual code logic.
]]

local DOC_HEADER_RUST = [[You are a Rust Documentation Expert.
Your task is to add or update the MODULE-LEVEL documentation at the very top of the file.

STRICT OUTPUT FORMAT:
<<<< SEARCH
[The first few lines of the file]
==== REPLACE
[The module documentation]
[The original first few lines]
>>>> END

STYLE GUIDE (RUSTDOC):
1. **Syntax**: Use `//!` for module-level documentation.
2. **Content**: Provide a high-level summary of the module's purpose.
3. **No Tags**: Do NOT use `@file` or `@brief`. Use standard Markdown headers if needed.

Example:
//! # Module Name
//!
//! Brief description of what this module does.
]]

local DOC_SELECTION_RUST = [[You are a Rust Documentation Expert.
Your task is to document the SPECIFIC code block provided using idiomatic Rustdoc.

STRICT OUTPUT FORMAT:
<<<< SEARCH
[The exact code block provided in the selection]
==== REPLACE
[The documented code block]
>>>> END

STYLE GUIDE (RUSTDOC):
- **Items**: Place `///` comments ABOVE structs, enums, functions, and fields.
- **Arguments**: Use Markdown lists or sections (e.g., `# Arguments`) inside the comment.
- **No Tags**: Do NOT use `@param` or `@return`.

Example:
/// Calculates the sum.
///
/// # Arguments
/// * `a` - First number
fn add(a: i32, b: i32) -> i32 { ... }
]]

local DOC_HEADER_LUA = [[You are a Lua Documentation Expert.
Your task is to add or update the MODULE-LEVEL documentation at the very top of the file.

STRICT OUTPUT FORMAT:
<<<< SEARCH
[The first few lines of the file]
==== REPLACE
[The module documentation]
[The original first few lines]
>>>> END

STYLE GUIDE (EMMYLUA / LDOC):
1. **Syntax**: Use `---` (three dashes) for documentation comments.
2. **Tags**: Use `@module [name]`, `@brief` (or `@description`), and `@author`.
3. **Content**: Describe the module's purpose.

Example:
--- @module my_module
--- @brief Handles X and Y logic.
local M = {}
]]

local DOC_SELECTION_LUA = [[You are a Lua Documentation Expert.
Your task is to document the SPECIFIC code block provided using EmmyLua/LDoc style.

STRICT OUTPUT FORMAT:
<<<< SEARCH
[The exact code block provided in the selection]
==== REPLACE
[The documented code block]
>>>> END

STYLE GUIDE (EMMYLUA / LDOC):
- **Syntax**: Place `---` comments ABOVE the function or table.
- **Tags**:
  - `@param [name] [type] [description]`
  - `@return [type] [description]`
  - `@field [name] [type] [description]` (for tables)

Example:
--- Calculates sum.
--- @param a number First number
--- @return number The sum
function M.add(a, b) ... end
]]

local DOC_HEADER_GENERIC = [[You are a Polyglot Documentation Expert.
Your task is to add or update the FILE-LEVEL HEADER comment at the very top of the file.

STRICT OUTPUT FORMAT:
<<<< SEARCH
[The first few lines of the file]
==== REPLACE
[The file header comment block]
[The original first few lines]
>>>> END

RULES:
1. **Language Detection**: Analyze the code to detect the language (e.g., Python, Go, JS).
2. **Style**: Use the STANDARD idiom for that language (e.g., `"""` docstrings for Python, `//` for Go, `/**` for JS).
3. **Content**: Describe the file's purpose clearly.
4. **Preservation**: You must include the original imports/package lines in the REPLACE block.
]]

local DOC_SELECTION_GENERIC = [[You are a Polyglot Documentation Expert.
Your task is to document the SPECIFIC code block provided.

STRICT OUTPUT FORMAT:
<<<< SEARCH
[The exact code block provided in the selection]
==== REPLACE
[The documented code block]
>>>> END

RULES:
1. **Language Detection**: Analyze the code to detect the language.
2. **Style**: Use the STANDARD documentation idiom for that language (e.g., JSDoc for JS/TS, Docstrings for Python).
3. **Consistency**: Document all parameters and return values if applicable.
4. **No Logic Changes**: Do not modify the actual code logic.
]]

--- Recursively adds files from a directory to the context.
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
	local initial_state = context_manager.get_current_state()
	local ft = vim.bo.filetype

	local prompt = DOC_HEADER_GENERIC
	if ft == "rust" then
		prompt = DOC_HEADER_RUST
	elseif ft == "lua" then
		prompt = DOC_HEADER_LUA
	elseif vim.tbl_contains({ "c", "cpp", "java" }, ft) then
		prompt = DOC_HEADER_C
	end

	utils.notify("Generating file header (" .. ft .. ")...")
	run_patch_job(
		"Analyze the file content and generate a comprehensive file-level header comment.",
		initial_state,
		prompt,
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

	local ft = vim.bo.filetype
	local prompt = DOC_SELECTION_GENERIC
	if ft == "rust" then
		prompt = DOC_SELECTION_RUST
	elseif ft == "lua" then
		prompt = DOC_SELECTION_LUA
	elseif vim.tbl_contains({ "c", "cpp", "java" }, ft) then
		prompt = DOC_SELECTION_C
	end

	utils.notify("Documenting selection (" .. ft .. ")...")
	run_patch_job("Add documentation comments to this selection.", initial_state, prompt, "SELECTED CODE")
end

--- Initiates the Plan (Chat Mode) workflow.
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
