local M = {}

M.job = nil
M.is_streaming = false
M.is_waiting_for_approval = false

-- Chat State
M.chat_history = {}
M.chat_bufnr = nil

-- NEW: Context Files List
M.context_files = {}

-- Transaction Snapshot
M.transaction = {
	bufnr = nil,
	mode = nil,
	original_start = nil,
	original_end = nil,
	new_start = nil,
	new_end = nil,
	original_lines = {},
}

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
	-- We deliberately do NOT clear context_files on reset,
	-- so context persists between runs until you clear it manually.
end

return M
