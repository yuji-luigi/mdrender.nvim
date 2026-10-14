if vim.g.loaded_mdrender then
  return
end
vim.g.loaded_mdrender = true

require("mdrender")._init()
