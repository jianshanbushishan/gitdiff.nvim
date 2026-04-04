local M = {}

--- Default configuration
local defaults = {
  --- Diff split command (e.g. "leftabove vert", "rightbelow vert", "leftabove", "rightbelow")
  split_cmd = "leftabove vert",
  --- Whether to close other windows before opening diff (like `:only`)
  only_before_open = true,
  --- Auto-cleanup on VimLeavePre
  auto_cleanup = true,
  --- Command used to list files for file-diff picker (default: rg --files)
  list_files_cmd = "rg --files",
}

local config = {}

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local state = {
  -- git HEAD diff session
  temp_bufnr = nil, -- buffer number of the temp file showing git HEAD version
  temp_file = nil, -- path to the temp file on disk
  source_bufnr = nil, -- buffer number of the original file being diffed
  active = false, -- whether a git HEAD diff session is currently active
  -- file diff session
  file_diff_active = false, -- whether a file-to-file diff session is active
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

--- Check if the current buffer is inside a Git work tree
---@return boolean
local function is_in_git_repo()
  local filepath = vim.api.nvim_buf_get_name(0)
  if filepath == "" then
    return false
  end
  local dir = vim.fn.fnamemodify(filepath, ":h")
  local handle = io.popen(string.format("git -C %s rev-parse --is-inside-work-tree", dir))
  if not handle then
    return false
  end
  local result = handle:read("*a")
  handle:close()
  return result:match("true") ~= nil
end

--- Get the content of the current file at HEAD
---@return string|nil content
local function get_git_head_content()
  if not is_in_git_repo() then
    vim.notify("[gitdiff] 当前文件不在 Git 仓库中", vim.log.levels.ERROR)
    return nil
  end

  local filepath = vim.api.nvim_buf_get_name(0)
  local rel_path = vim.fn.fnamemodify(filepath, ":."):gsub("\\", "/")

  local handle = io.popen(string.format("git show HEAD:%s", rel_path))
  if not handle then
    vim.notify("[gitdiff] 无法执行 git show", vim.log.levels.ERROR)
    return nil
  end

  local content = handle:read("*a")
  handle:close()
  return content
end

--- Write content to a temp file preserving the original file extension
---@param content string
---@return string|nil temp_path
local function write_temp_file(content)
  local filepath = vim.api.nvim_buf_get_name(0)
  local ext = vim.fn.fnamemodify(filepath, ":e")
  local tmp = os.tmpname()
  if ext ~= "" then
    tmp = tmp .. "." .. ext
  end

  local f = io.open(tmp, "w")
  if not f then
    vim.notify("[gitdiff] 无法创建临时文件", vim.log.levels.ERROR)
    return nil
  end
  f:write(content)
  f:close()
  return tmp
end

--- Clean up temp file and buffer, reset state
local function cleanup()
  if state.temp_bufnr and vim.api.nvim_buf_is_valid(state.temp_bufnr) then
    vim.api.nvim_buf_delete(state.temp_bufnr, { force = true })
  end
  if state.temp_file and vim.fn.filereadable(state.temp_file) == 1 then
    os.remove(state.temp_file)
  end
  state.temp_bufnr = nil
  state.temp_file = nil
  state.source_bufnr = nil
  state.active = false
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Open a vertical diff between the current buffer and its Git HEAD version
function M.diff_with_latest()
  if state.active then
    vim.notify("[gitdiff] 已有 diff 会话在运行，请先关闭", vim.log.levels.WARN)
    return
  end

  local content = get_git_head_content()
  if not content then
    return
  end

  local tmp = write_temp_file(content)
  if not tmp then
    return
  end

  state.temp_file = tmp
  state.source_bufnr = vim.api.nvim_get_current_buf()

  if config.only_before_open then
    vim.cmd("only")
  end

  local current_win = vim.api.nvim_get_current_win()
  vim.cmd(config.split_cmd .. " diffsplit " .. vim.fn.fnameescape(tmp))

  state.temp_bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_option_value("readonly", true, { buf = state.temp_bufnr })
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.temp_bufnr })
  vim.api.nvim_set_option_value("buflisted", false, { buf = state.temp_bufnr })

  vim.api.nvim_set_current_win(current_win)
  state.active = true

  -- Auto-cleanup when source buffer is deleted
  vim.api.nvim_create_autocmd("BufDelete", {
    buffer = state.source_bufnr,
    once = true,
    callback = function()
      cleanup()
    end,
  })
end

--- Close the active diff session and clean up
function M.close_diff()
  if not state.active then
    return
  end
  vim.cmd("diffoff")
  cleanup()
end

--- Toggle diff session on/off
function M.toggle()
  if state.active then
    M.close_diff()
  else
    M.diff_with_latest()
  end
end

--- Check if a diff session is active
---@return boolean
function M.is_active()
  return state.active
end

--- Check if a file diff session is active
---@return boolean
function M.is_file_diff_active()
  return state.file_diff_active
end

-------------------------------------------------------------------------------
-- File-to-file diff
-------------------------------------------------------------------------------

--- List git-tracked files using the configured command
---@return string[]
local function list_tracked_files()
  local files = vim.fn.systemlist(config.list_files_cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify("[gitdiff] 无法获取文件列表", vim.log.levels.ERROR)
    return {}
  end
  return files
end

--- Open a diff between the current buffer and a selected file
function M.diff_with_file()
  if state.active then
    return
  end

  if state.file_diff_active then
    M.close_file_diff()
  else
    vim.ui.select(list_tracked_files(), {
      prompt = "Select file to compare",
    }, function(selected)
      if selected == nil then
        return
      end
      state.file_diff_active = true
      if config.only_before_open then
        vim.cmd("only")
      end
      vim.cmd("diffsplit " .. vim.fn.fnameescape(selected))
    end)
  end
end

--- Close the file-to-file diff session
function M.close_file_diff()
  if not state.file_diff_active then
    return
  end
  vim.cmd("diffoff!")
  vim.cmd("close")
  state.file_diff_active = false
end

-------------------------------------------------------------------------------
-- Setup
-------------------------------------------------------------------------------

--- Setup the plugin with user options
---@param opts table|nil user configuration
function M.setup(opts)
  config = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Commands
  vim.api.nvim_create_user_command("GitDiffLatest", function()
    M.diff_with_latest()
  end, { desc = "Open diff with Git HEAD version" })

  vim.api.nvim_create_user_command("GitDiffClose", function()
    M.close_diff()
  end, { desc = "Close Git diff session" })

  vim.api.nvim_create_user_command("GitDiffToggle", function()
    M.toggle()
  end, { desc = "Toggle Git diff session" })

  vim.api.nvim_create_user_command("GitDiffFile", function()
    M.diff_with_file()
  end, { desc = "Diff with a selected file" })

  vim.api.nvim_create_user_command("GitDiffFileClose", function()
    M.close_file_diff()
  end, { desc = "Close file diff session" })

  -- Auto-cleanup on exit
  if config.auto_cleanup then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        if state.active then
          cleanup()
        end
        if state.file_diff_active then
          state.file_diff_active = false
        end
      end,
    })
  end
end

return M
