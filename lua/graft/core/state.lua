--- @module graft.core.state
--- @description Maintains the global state for the plugin.
--- It tracks active jobs, chat history, context files, and ongoing code transactions.
---
--- The state is used to coordinate between different parts of the plugin,
--- such as the UI, the LLM client, and the code modification logic.
local M = {}

--- @type any|nil The current active job (e.g., from vim.fn.jobstart).
M.job = nil

--- @type boolean Indicates if a response is currently being streamed from the LLM.
M.is_streaming = false

--- @type boolean Indicates if the plugin is waiting for user confirmation before applying changes.
M.is_waiting_for_approval = false

--- @type table[] A list of messages representing the current chat history.
M.chat_history = {}

--- @type number|nil The buffer number of the chat window.
M.chat_bufnr = nil

--- @type string[] A list of file paths currently included in the context.
M.context_files = {}

--- @table Transaction
--- @description
--- Represents a code modification transaction, allowing for tracking and undoing changes.
--- @field bufnr number|nil The buffer number where the transaction is occurring.
--- @field mode string|nil The type of transaction (e.g., "replace", "append").
--- @field original_start number|nil The starting line number of the original selection.
--- @field original_end number|nil The ending line number of the original selection.
--- @field new_start number|nil The starting line number of the newly inserted content.
--- @field new_end number|nil The ending line number of the newly inserted content.
--- @field original_lines string[] The original lines that were replaced.
M.transaction = {
	bufnr = nil,
	mode = nil,
	original_start = nil,
	original_end = nil,
	new_start = nil,
	new_end = nil,
	original_lines = {},
}

--- Resets the plugin state to its default values.
--- This is typically called when starting a new session or canceling an operation.
function M.reset()
	M.job = nil
	M.is_streaming = false
	M.is_waiting_for_approval = false
	M.transaction = {
		bufnr = nil,
		mode = nil,
		original_start = nil,
		original_end = nil,
		new_start = nil,
		new_end = nil,
		original_lines = {},
	}
end

return M
