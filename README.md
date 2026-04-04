# gitdiff.nvim

将当前文件与 Git HEAD 版本进行 diff 对比，或与工作区中任意文件进行 diff 对比的 Neovim 插件。

## 功能

- **Git HEAD Diff**：将当前缓冲区与 `git show HEAD:<file>` 的内容进行垂直 diff 对比
- **文件 Diff**：从工作区文件列表中选择一个文件，与当前缓冲区进行 diff 对比
- **Toggle 模式**：一键开关 diff 会话
- **自动清理**：关闭 diff 时自动删除临时文件和缓冲区，退出 Neovim 时也会清理
- **互斥保护**：Git HEAD diff 和文件 diff 两种会话互斥，不会同时激活

## 依赖

- [ripgrep](https://github.com/Burntoushi/ripgrep)（文件 diff 功能需要 `rg` 命令列出文件列表）
- Git（所有功能需要）

## 安装

使用 [lazy.nvim](https://github.com/folke/lazy.nvim)：

```lua
{
  "jianshanbushishan/gitdiff",
  lazy = false,
  keys = {
    { "<F6>", function() require("gitdiff").toggle() end, desc = "Toggle Git Diff" },
    { "<C-F6>", function() require("gitdiff").diff_with_file() end, desc = "Diff with File" },
  },
  opts = {},
}
```

## 配置

```lua
{
  -- diffsplit 的分割方式
  split_cmd = "leftabove vert", -- 可选："rightbelow vert", "leftabove", "rightbelow"

  -- 打开 diff 前是否关闭其他窗口（相当于 :only）
  only_before_open = true,

  -- 退出 Neovim 时是否自动清理临时文件
  auto_cleanup = true,

  -- 文件 diff 用来列出文件的命令
  list_files_cmd = "rg --files",
}
```

## 命令

| 命令 | 说明 |
|------|------|
| `:GitDiffLatest` | 打开当前文件与 Git HEAD 版本的 diff |
| `:GitDiffClose` | 关闭 Git HEAD diff 会话 |
| `:GitDiffToggle` | 切换 Git HEAD diff 开/关 |
| `:GitDiffFile` | 选择文件进行 diff（已激活时则关闭） |
| `:GitDiffFileClose` | 关闭文件 diff 会话 |

## API

可以通过 Lua 调用以下函数：

```lua
local gd = require("gitdiff")

gd.diff_with_latest()   -- 打开与 Git HEAD 的 diff
gd.close_diff()         -- 关闭 Git HEAD diff
gd.toggle()             -- 切换 Git HEAD diff

gd.diff_with_file()     -- 选择文件进行 diff（已激活时关闭）
gd.close_file_diff()    -- 关闭文件 diff

gd.is_active()          -- Git HEAD diff 是否激活（返回 boolean）
gd.is_file_diff_active() -- 文件 diff 是否激活（返回 boolean）
```
