# mdrender.nvim

Minimal in-buffer Markdown rendering for Neovim. No dependencies — it uses the
treesitter `markdown` parser bundled with Neovim (0.10+).

Renders headings, bullets, task checkboxes, block quotes, horizontal rules and
fenced code blocks with extmarks. The line under the cursor always shows the raw
Markdown so you can edit it (set `raw_cursor_line = false` to render it too).

## Install

With the built-in package manager (Neovim 0.12+):

```lua
vim.pack.add({ "https://github.com/yuji-luigi/mdrender.nvim" })
```

It attaches to every `markdown` buffer automatically. `setup()` is optional:

```lua
require("mdrender").setup({
  enabled = true,
  raw_cursor_line = true, -- false: render the cursor line too (copy rendered text)
  heading_icons = { "◉ ", "○ ", "✸ ", "✿ ", "◆ ", "◇ " },
  bullets = { "●", "○", "◆", "◇" },
  checkbox = { unchecked = "☐", checked = "☑" },
  quote = "▎",
  hr = "─",
})
```

## Commands

`:MdRender [toggle|enable|disable]` — defaults to `toggle`, applies to the current buffer.

## Highlights

`MdRenderH1`–`MdRenderH6`, `MdRenderH1Bg`–`MdRenderH6Bg`, `MdRenderCode`,
`MdRenderBullet`, `MdRenderChecked`, `MdRenderUnchecked`, `MdRenderQuote`,
`MdRenderHr`. All are defined with `default = true`, so your colorscheme or
config can override them.
