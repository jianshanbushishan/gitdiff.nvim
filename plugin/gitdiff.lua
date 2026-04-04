if vim.g.loaded_gitdiff then
  return
end
vim.g.loaded_gitdiff = 1

require("gitdiff").setup()
