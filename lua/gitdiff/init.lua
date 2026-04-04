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
  source_bufnr = nil,
  source_winid = nil,
  compare_bufnr = nil,
  compare_winid = nil,
  temp_file = nil,
  active = false,
  mode = nil, -- "git" | "file"
}

local closing = false

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

---@param win integer|nil
---@return boolean
local function is_valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@param bufnr integer|nil
---@return boolean
local function is_valid_buf(bufnr)
  return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end


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

---@return string|nil
local function get_git_repo_root()
  local filepath = vim.api.nvim_buf_get_name(0)
  if filepath == "" then
    return nil
  end
  local dir = vim.fn.fnamemodify(filepath, ":h")
  local handle = io.popen(string.format("git -C %s rev-parse --show-toplevel", dir))
  if not handle then
    return nil
  end
  local result = handle:read("*a")
  handle:close()
  result = vim.trim(result)
  if result == "" then
    return nil
  end
  return result
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
---@param source_bufnr integer
---@param compare_bufnr integer
local function sync_compare_buffer_options(source_bufnr, compare_bufnr)
  local options = {
    "filetype",
    "binary",
    "endofline",
    "fixendofline",
    "bomb",
    "fileformat",
  }

  for _, option in ipairs(options) do
    local ok, value = pcall(vim.api.nvim_get_option_value, option, { buf = source_bufnr })
    if ok then
      pcall(vim.api.nvim_set_option_value, option, value, { buf = compare_bufnr })
    end
  end
end

local function reset_state()
  state.source_bufnr = nil
  state.source_winid = nil
  state.compare_bufnr = nil
  state.compare_winid = nil
  state.temp_file = nil
  state.active = false
  state.mode = nil
end

local function cleanup_temp_file()
  if state.temp_file and type(state.temp_file) == "string" and vim.fn.filereadable(state.temp_file) == 1 then
    os.remove(state.temp_file)
  end
end

---@param source_bufnr integer
---@param content string
---@return string|nil
local function write_temp_file(source_bufnr, content)
  local filepath = vim.api.nvim_buf_get_name(source_bufnr)
  local ext = vim.fn.fnamemodify(filepath, ":e")
  local tmp = os.tmpname()
  if ext ~= "" then
    tmp = tmp .. "." .. ext
  end

  local f = io.open(tmp, "wb")
  if not f then
    vim.notify("[gitdiff] 无法创建临时文件", vim.log.levels.ERROR)
    return nil
  end
  f:write(content)
  f:close()
  return tmp
end

---@param win integer
local function clear_diff_for_win(win)
  if not is_valid_win(win) then
    return
  end
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd("silent! diffoff!")
    vim.cmd("setlocal nodiff")
  end)
end

local function reset_tab_diff_state()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_valid_win(win) then
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd("silent! diffoff!")
        vim.cmd("setlocal nodiff")
      end)
    end
  end
end

---@param source_win integer
---@param compare_win integer
local function enable_diff_pair(source_win, compare_win)
  vim.api.nvim_win_call(source_win, function()
    vim.cmd("silent! diffthis")
  end)
  vim.api.nvim_win_call(compare_win, function()
    vim.cmd("silent! diffthis")
  end)
end

local function close_session()
  if not state.active or closing then
    return
  end

  closing = true

  local source_winid = state.source_winid
  local compare_winid = state.compare_winid
  local compare_bufnr = state.compare_bufnr

  reset_tab_diff_state()

  if is_valid_win(source_winid) and vim.api.nvim_win_get_buf(source_winid) == state.source_bufnr then
    clear_diff_for_win(source_winid)
  end
  clear_diff_for_win(compare_winid)

  if is_valid_win(compare_winid) then
    pcall(vim.api.nvim_win_close, compare_winid, true)
  end

  if state.mode == "git" and is_valid_buf(compare_bufnr) then
    pcall(vim.api.nvim_buf_delete, compare_bufnr, { force = true })
  end

  cleanup_temp_file()
  reset_state()
  closing = false
end

---@param compare_target string
---@param mode "git"|"file"
local function open_diff(compare_target, mode)
  local source_winid = vim.api.nvim_get_current_win()
  local source_bufnr = vim.api.nvim_get_current_buf()
  reset_tab_diff_state()

  if config.only_before_open then
    vim.cmd("only")
    source_winid = vim.api.nvim_get_current_win()
    source_bufnr = vim.api.nvim_get_current_buf()
  end

  vim.cmd(config.split_cmd .. " split")
  local compare_winid = vim.api.nvim_get_current_win()

  if mode == "git" then
    local tmp = write_temp_file(source_bufnr, compare_target)
    if not tmp then
      pcall(vim.api.nvim_win_close, compare_winid, true)
      return
    end
    state.temp_file = tmp
    vim.cmd("edit " .. vim.fn.fnameescape(tmp))
    local compare_bufnr = vim.api.nvim_get_current_buf()
    sync_compare_buffer_options(source_bufnr, compare_bufnr)
    vim.api.nvim_set_option_value("readonly", true, { buf = compare_bufnr })
    vim.api.nvim_set_option_value("modifiable", false, { buf = compare_bufnr })
    vim.api.nvim_set_option_value("buflisted", false, { buf = compare_bufnr })
    state.compare_bufnr = compare_bufnr
  else
    vim.cmd("edit " .. vim.fn.fnameescape(compare_target))
    state.compare_bufnr = vim.api.nvim_get_current_buf()
  end

  state.source_bufnr = source_bufnr
  state.source_winid = source_winid
  state.compare_winid = compare_winid
  state.active = true
  state.mode = mode

  enable_diff_pair(source_winid, compare_winid)
  vim.api.nvim_set_current_win(source_winid)
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Open a vertical diff between the current buffer and its Git HEAD version
function M.diff_with_latest()
  if state.active then
    close_session()
    return
  end

  local content = get_git_head_content()
  if not content then
    return
  end

  open_diff(content, "git")
end

--- Close the active diff session and clean up
function M.close_diff()
  if state.active and state.mode == "git" then
    close_session()
  end
end

--- Toggle diff session on/off
function M.toggle()
  if state.active and state.mode == "git" then
    M.close_diff()
  else
    M.diff_with_latest()
  end
end

--- Check if a diff session is active
---@return boolean
function M.is_active()
  return state.active and state.mode == "git"
end

--- Check if a file diff session is active
---@return boolean
function M.is_file_diff_active()
  return state.active and state.mode == "file"
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
  if state.active and state.mode == "file" then
    M.close_file_diff()
    return
  end

  if state.active then
    close_session()
  end

  vim.ui.select(list_tracked_files(), {
    prompt = "Select file to compare",
  }, function(selected)
    if selected == nil then
      return
    end
    open_diff(selected, "file")
  end)
end

--- Close the file-to-file diff session
function M.close_file_diff()
  if state.active and state.mode == "file" then
    close_session()
  end
end

-------------------------------------------------------------------------------
-- Setup
-------------------------------------------------------------------------------

--- Setup the plugin with user options
---@param opts table|nil user configuration
function M.setup(opts)
  config = vim.tbl_deep_extend("force", defaults, opts or {})

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

  vim.api.nvim_create_autocmd("BufEnter", {
    callback = function(args)
      if not state.active or closing then
        return
      end
      if args.buf ~= state.source_bufnr and args.buf ~= state.compare_bufnr then
        close_session()
      end
    end,
    desc = "Auto-close gitdiff when buffer switches",
  })

  if config.auto_cleanup then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        close_session()
      end,
    })
  end
end

return M
