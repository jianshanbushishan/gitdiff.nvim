# gitdiff.nvim

将当前文件与 Git HEAD 版本进行双列 diff 对比，或与工作区中任意文件进行 diff 对比的 Neovim 插件。

## 功能

- **Git HEAD Diff**：将当前缓冲区与 `git show HEAD:<file>` 的内容进行垂直 diff 对比
- **文件 Diff**：从工作区文件列表中选择一个文件，与当前缓冲区进行 diff 对比
- **Toggle 模式**：一键开关 Git HEAD diff 会话
- **会话挂起恢复**：切换到非当前 diff 会话相关的 buffer 时，会收起 diff split 但保留会话；回到原始 buffer 时自动恢复
- **自动清理**：关闭 Git HEAD diff 时会自动删除临时文件和临时缓冲区；退出 Neovim 时也会清理
- **互斥保护**：Git HEAD diff 和文件 diff 两种会话互斥，不会同时激活

## 依赖

- [ripgrep](https://github.com/Burntoushi/ripgrep)（文件 diff 功能需要 `rg` 命令列出文件列表）
- Git（所有功能需要）

## 安装

使用 [lazy.nvim](https://github.com/folke/lazy.nvim)：

```lua
{
  "jianshanbushishan/gitdiff.nvim",
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
  -- split 的分割方式
  split_cmd = "leftabove vert", -- 可选："rightbelow vert", "leftabove", "rightbelow"

  -- 打开 diff 前是否关闭其他窗口（相当于 :only）
  only_before_open = true,

  -- 退出 Neovim 时是否自动清理 Git HEAD diff 产生的临时文件
  auto_cleanup = true,

  -- 文件 diff 用来列出文件的命令
  list_files_cmd = "rg --files",
}
```

## 行为说明

- Git HEAD diff 使用临时文件作为 compare 侧缓冲区，以保证 diff 结果稳定
- 新开启 diff 前，会先清理当前 tab 中残留的 diff 状态，避免上一次对比影响下一次对比
- 当你切换到与当前 diff 无关的 buffer 时，插件会收起 compare 窗口并挂起当前 diff 会话，同时保留对比状态
- 当你重新回到原始 buffer 时，插件会自动恢复之前的 diff 视图
- 文件 diff 与 Git HEAD diff 共用同一套会话管理逻辑，同一时刻只会存在一个 diff 会话

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

## 说明

- Git HEAD diff 依赖当前 buffer 的文件路径位于 Git 仓库中
- `toggle()` 只针对 Git HEAD diff；文件 diff 通过 `diff_with_file()` / `close_file_diff()` 控制
