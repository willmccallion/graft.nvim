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

-- IMPROVED PROMPT: Forces "Whole Function Replacement" for stability
local PROMPT_REFACTOR = [[You are an expert coding agent specializing in Unified Diff generation.
Your task is to modify the provided code based on the user's instruction.

STRICT GENERATION STRATEGY:
1. **WHOLE FUNCTION REPLACEMENT**: If you need to modify code inside a function, you MUST delete (-) the ENTIRE original function and add (+) the ENTIRE new function.
   - Do NOT try to patch individual lines inside a function. It causes syntax errors.
   - Replace the whole block.

2. **SCAN FOR DEPENDENCIES**:
   - If you change a function signature (e.g., add_task), you MUST scan the entire file for calls to that function (especially in `main`) and update them too.
   - If you add a new function, ensure it is placed correctly (e.g., before main).

3. **OUTPUT FORMAT**:
   - Start immediately with `--- a/filename`.
   - Use standard Unified Diff format.
   - No Markdown.

Example of Whole Function Replacement:
@@ ... @@
-void func(int a) {
-    printf("Old: %d", a);
-}
+void func(int a, int b) {
+    printf("New: %d %d", a, b);
+}
]]

local PROMPT_PLAN = [[You are a knowledgeable Senior Technical Lead.
- Use Markdown formatting.
- Be concise but thorough.
- When suggesting code, use proper syntax highlighting.]]

-- RECURSIVE DIRECTORY ADDER
local function add_directory_recursive(dir_path)
	local abs_dir = vim.fn.fnamemodify(dir_path, ":p")
	if vim.fn.isdirectory(abs_dir) == 0 then
		utils.notify("Directory not found: " .. dir_path, vim.log.levels.ERROR)
		return
	end

	-- Find all files, skip .git, node_modules, etc.
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

-- NEW: Telescope Directory Picker
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

		-- Explicitly label sections for the LLM
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

		-- FIX: Split input into lines to prevent "item contains newlines" error
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

function M.accept_changes()
	if not state.transaction.bufnr then
		return
	end
	vim.api.nvim_buf_clear_namespace(state.transaction.bufnr, indicators.get_namespace(), 0, -1)
	preview.close()
	state.reset()
	utils.notify("Changes Accepted.")
end

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
