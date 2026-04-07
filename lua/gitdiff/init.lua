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
  tabpage = nil,
  source_bufnr = nil,
  source_winid = nil,
  compare_bufnr = nil,
  compare_winid = nil,
  temp_file = nil,
  active = false,
  visible = false,
  mode = nil, -- "git" | "file"
}

local closing = false
local close_session

local compare_buffer_options = {
  "filetype",
  "binary",
  "endofline",
  "fixendofline",
  "bomb",
  "fileformat",
}

local commands = {
  diff_on = "silent! diffthis",
  diff_off = "silent! diffoff!",
  no_diff = "setlocal nodiff",
}

local git_commands = {
  inside_work_tree = { "git", "rev-parse", "--is-inside-work-tree" },
  show_toplevel = { "git", "rev-parse", "--show-toplevel" },
  show_head = { "git", "show" },
}

local mouse_scroll_mappings = {
  { lhs = "<ScrollWheelUp>", keys = "<C-Y>" },
  { lhs = "<ScrollWheelDown>", keys = "<C-E>" },
  { lhs = "<S-ScrollWheelUp>", keys = "<C-B>" },
  { lhs = "<S-ScrollWheelDown>", keys = "<C-F>" },
}

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
  local result = vim.system(git_commands.inside_work_tree, { cwd = dir, text = true }):wait()
  return result.code == 0 and vim.trim(result.stdout or "") == "true"
end

---@param bufnr integer
---@return string|nil
local function get_buf_path(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then
    return nil
  end

  return filepath
end

---@param filepath string
---@return string
local function get_parent_dir(filepath)
  return vim.fn.fnamemodify(filepath, ":h")
end

---@param cwd string
---@param args string[]
---@return vim.SystemCompleted
local function run_git(cwd, args)
  return vim.system(args, { cwd = cwd, text = true }):wait()
end

---@param filepath string
---@return string|nil
local function get_git_repo_root(filepath)
  local result = run_git(get_parent_dir(filepath), git_commands.show_toplevel)
  if result.code ~= 0 then
    return nil
  end

  local root = vim.trim(result.stdout or "")
  if root == "" then
    return nil
  end

  return root
end

---@param filepath string
---@param base string
---@return string
local function make_relative_path(filepath, base)
  return vim.fs.relpath(base, filepath):gsub("\\", "/")
end

--- Get the content of the current file at HEAD
---@return string|nil content
local function get_git_head_content()
  if not is_in_git_repo() then
    vim.notify("[gitdiff] 当前文件不在 Git 仓库中", vim.log.levels.ERROR)
    return nil
  end

  local filepath = get_buf_path(0)
  if not filepath then
    return nil
  end

  local repo_root = get_git_repo_root(filepath)
  if not repo_root then
    vim.notify("[gitdiff] 无法获取 Git 仓库根目录", vim.log.levels.ERROR)
    return nil
  end

  local rel_path = make_relative_path(filepath, repo_root)
  local result = run_git(repo_root, { git_commands.show_head[1], git_commands.show_head[2], "HEAD:" .. rel_path })

  if result.code ~= 0 then
    vim.notify("[gitdiff] 无法执行 git show", vim.log.levels.ERROR)
    return nil
  end

  return result.stdout
end

--- Write content to a temp file preserving the original file extension
---@param content string
---@return string|nil temp_path
---@param source_bufnr integer
---@param compare_bufnr integer
local function sync_compare_buffer_options(source_bufnr, compare_bufnr)
  for _, option in ipairs(compare_buffer_options) do
    local ok, value = pcall(vim.api.nvim_get_option_value, option, { buf = source_bufnr })
    if ok then
      pcall(vim.api.nvim_set_option_value, option, value, { buf = compare_bufnr })
    end
  end
end

local function reset_state()
  state.tabpage = nil
  state.source_bufnr = nil
  state.source_winid = nil
  state.compare_bufnr = nil
  state.compare_winid = nil
  state.temp_file = nil
  state.active = false
  state.visible = false
  state.mode = nil
end

---@param mode "git"|"file"|nil
---@return boolean
local function is_active_mode(mode)
  return state.active and state.mode == mode
end

---@param win integer
---@param callback fun()
local function with_win_call(win, callback)
  if not is_valid_win(win) then
    return
  end

  pcall(vim.api.nvim_win_call, win, callback)
end

---@param win integer
---@param cmd string
local function win_cmd(win, cmd)
  with_win_call(win, function()
    vim.cmd(cmd)
  end)
end

---@param winids integer[]
---@param cmd string
local function win_cmd_each(winids, cmd)
  for _, win in ipairs(winids) do
    win_cmd(win, cmd)
  end
end

---@param bufnr integer|nil
---@param wins integer[]|nil
---@return integer|nil
local function find_window_for_buffer(bufnr, wins)
  if not is_valid_buf(bufnr) then
    return nil
  end

  for _, win in ipairs(wins or vim.api.nvim_tabpage_list_wins(0)) do
    if is_valid_win(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end

  return nil
end

---@return integer|nil, integer|nil
local function get_session_windows()
  local tabpage = state.tabpage
  local wins

  if tabpage ~= nil and vim.api.nvim_tabpage_is_valid(tabpage) then
    wins = vim.api.nvim_tabpage_list_wins(tabpage)
  else
    wins = vim.api.nvim_tabpage_list_wins(0)
  end

  local source_winid = find_window_for_buffer(state.source_bufnr, wins)
  local compare_winid = find_window_for_buffer(state.compare_bufnr, wins)
  return source_winid, compare_winid
end

---@return boolean
local function ensure_session_buffers()
  if is_valid_buf(state.source_bufnr) and is_valid_buf(state.compare_bufnr) then
    return true
  end

  close_session()
  return false
end

---@return boolean
local function has_visible_session()
  local source_winid, compare_winid = get_session_windows()
  return is_valid_win(source_winid) and is_valid_win(compare_winid)
end

---@return integer|nil
local function get_hovered_diff_win()
  local ok, mousepos = pcall(vim.fn.getmousepos)
  local hovered_win = ok and mousepos.winid or nil
  if is_valid_win(hovered_win)
    and (hovered_win == state.source_winid or hovered_win == state.compare_winid) then
    return hovered_win
  end

  local current_win = vim.api.nvim_get_current_win()
  if current_win == state.source_winid or current_win == state.compare_winid then
    return current_win
  end

  return nil
end

---@param keys string
local function scroll_hovered_diff_win(keys)
  local target_win = get_hovered_diff_win()
  if not is_valid_win(target_win) then
    return
  end

  with_win_call(target_win, function()
    local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
    vim.api.nvim_feedkeys(termcodes, "n", false)
  end)
end

---@param bufnr integer|nil
local function clear_mouse_scroll_mappings(bufnr)
  if not is_valid_buf(bufnr) then
    return
  end

  for _, mapping in ipairs(mouse_scroll_mappings) do
    pcall(vim.keymap.del, "n", mapping.lhs, { buffer = bufnr })
  end
end

---@param bufnr integer
local function set_mouse_scroll_mappings(bufnr)
  for _, mapping in ipairs(mouse_scroll_mappings) do
    vim.keymap.set("n", mapping.lhs, function()
      scroll_hovered_diff_win(mapping.keys)
    end, {
      buffer = bufnr,
      silent = true,
      desc = "gitdiff hovered mouse scroll",
    })
  end
end

---@param source_bufnr integer
---@param source_winid integer
---@param compare_bufnr integer
---@param compare_winid integer
---@param mode "git"|"file"
local function set_active_session(source_bufnr, source_winid, compare_bufnr, compare_winid, mode)
  state.tabpage = vim.api.nvim_get_current_tabpage()
  state.source_bufnr = source_bufnr
  state.source_winid = source_winid
  state.compare_bufnr = compare_bufnr
  state.compare_winid = compare_winid
  state.active = true
  state.visible = true
  state.mode = mode
end

local function cleanup_temp_file()
  if state.temp_file and type(state.temp_file) == "string" and vim.fn.filereadable(state.temp_file) == 1 then
    os.remove(state.temp_file)
  end
end

---@param compare_bufnr integer
local function configure_git_compare_buffer(compare_bufnr)
  vim.api.nvim_set_option_value("readonly", true, { buf = compare_bufnr })
  vim.api.nvim_set_option_value("modifiable", false, { buf = compare_bufnr })
  vim.api.nvim_set_option_value("buflisted", false, { buf = compare_bufnr })
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
  win_cmd(win, commands.diff_off)
  win_cmd(win, commands.no_diff)
end

local function reset_tab_diff_state()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  win_cmd_each(wins, commands.diff_off)
  win_cmd_each(wins, commands.no_diff)
end

---@param source_win integer
---@param compare_win integer
local function enable_diff_pair(source_win, compare_win)
  win_cmd_each({ source_win, compare_win }, commands.diff_on)
end

local function suspend_session()
  if not state.active or closing or not state.visible then
    return
  end

  local source_winid, compare_winid = get_session_windows()
  local compare_bufnr = state.compare_bufnr

  clear_mouse_scroll_mappings(state.source_bufnr)
  clear_mouse_scroll_mappings(state.compare_bufnr)

  if is_valid_win(source_winid) then
    clear_diff_for_win(source_winid)
  end
  if is_valid_win(compare_winid) then
    clear_diff_for_win(compare_winid)
  end
  if is_valid_win(compare_winid) and vim.api.nvim_win_get_buf(compare_winid) == compare_bufnr then
    pcall(vim.api.nvim_win_close, compare_winid, true)
  end

  state.source_winid = nil
  state.compare_winid = nil
  state.visible = false
end

local function resume_session()
  if not state.active or closing or state.visible then
    return
  end
  if vim.api.nvim_get_current_buf() ~= state.source_bufnr then
    return
  end
  if not ensure_session_buffers() then
    return
  end

  local source_winid = vim.api.nvim_get_current_win()
  local compare_winid = find_window_for_buffer(state.compare_bufnr)

  if compare_winid == source_winid then
    compare_winid = nil
  end

  if not is_valid_win(compare_winid) then
    vim.cmd(config.split_cmd .. " split")
    compare_winid = vim.api.nvim_get_current_win()

    local ok = pcall(vim.api.nvim_win_set_buf, compare_winid, state.compare_bufnr)
    if not ok then
      pcall(vim.api.nvim_win_close, compare_winid, true)
      return
    end
  end

  if state.mode == "git" then
    sync_compare_buffer_options(state.source_bufnr, state.compare_bufnr)
    configure_git_compare_buffer(state.compare_bufnr)
  end

  state.tabpage = vim.api.nvim_get_current_tabpage()
  state.source_winid = source_winid
  state.compare_winid = compare_winid
  state.visible = true

  enable_diff_pair(source_winid, compare_winid)
  set_mouse_scroll_mappings(state.source_bufnr)
  set_mouse_scroll_mappings(state.compare_bufnr)
  vim.api.nvim_set_current_win(source_winid)
end

close_session = function()
  if not state.active or closing then
    return
  end

  closing = true

  local source_winid, compare_winid = get_session_windows()
  local source_bufnr = state.source_bufnr
  local compare_bufnr = state.compare_bufnr

  clear_mouse_scroll_mappings(source_bufnr)
  clear_mouse_scroll_mappings(compare_bufnr)

  if is_valid_win(source_winid) then
    clear_diff_for_win(source_winid)
  end
  if is_valid_win(compare_winid) then
    clear_diff_for_win(compare_winid)
  end

  if is_valid_win(compare_winid) and vim.api.nvim_win_get_buf(compare_winid) == compare_bufnr then
    pcall(vim.api.nvim_win_close, compare_winid, true)
  end

  if state.mode == "git" and is_valid_buf(compare_bufnr) then
    pcall(vim.api.nvim_buf_delete, compare_bufnr, { force = true })
  end

  cleanup_temp_file()
  reset_state()
  closing = false
end

---@param source_bufnr integer
---@param content string
---@param compare_winid integer
---@return integer|nil
local function open_git_compare_buffer(source_bufnr, content, compare_winid)
  local tmp = write_temp_file(source_bufnr, content)
  if not tmp then
    pcall(vim.api.nvim_win_close, compare_winid, true)
    return nil
  end

  state.temp_file = tmp
  vim.cmd("edit " .. vim.fn.fnameescape(tmp))

  local compare_bufnr = vim.api.nvim_get_current_buf()
  sync_compare_buffer_options(source_bufnr, compare_bufnr)
  configure_git_compare_buffer(compare_bufnr)
  return compare_bufnr
end

---@param compare_target string
---@return integer
local function open_file_compare_buffer(compare_target)
  vim.cmd("edit " .. vim.fn.fnameescape(compare_target))
  return vim.api.nvim_get_current_buf()
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
  local compare_bufnr

  if mode == "git" then
    compare_bufnr = open_git_compare_buffer(source_bufnr, compare_target, compare_winid)
    if not compare_bufnr then
      return
    end
  else
    compare_bufnr = open_file_compare_buffer(compare_target)
  end

  set_active_session(source_bufnr, source_winid, compare_bufnr, compare_winid, mode)

  enable_diff_pair(source_winid, compare_winid)
  set_mouse_scroll_mappings(source_bufnr)
  set_mouse_scroll_mappings(compare_bufnr)
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
  if is_active_mode("git") then
    close_session()
  end
end

--- Toggle diff session on/off
function M.toggle()
  if is_active_mode("git") then
    M.close_diff()
  else
    M.diff_with_latest()
  end
end

--- Check if a diff session is active
---@return boolean
function M.is_active()
  return is_active_mode("git")
end

--- Check if a file diff session is active
---@return boolean
function M.is_file_diff_active()
  return is_active_mode("file")
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
  if is_active_mode("file") then
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
  if is_active_mode("file") then
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
      if args.buf == state.source_bufnr then
        if not state.visible then
          resume_session()
          return
        end
        if not has_visible_session() then
          state.visible = false
          resume_session()
        end
        return
      end
      if args.buf == state.compare_bufnr then
        return
      end
      if state.visible then
        suspend_session()
      end
    end,
    desc = "Suspend and resume gitdiff when buffer switches",
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
