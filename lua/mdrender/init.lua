-- mdrender.nvim: render Markdown in the buffer with extmarks.
-- Uses only Neovim's built-in treesitter markdown parser (0.10+).

local M = {}

local ns = vim.api.nvim_create_namespace("mdrender")
local group = vim.api.nvim_create_augroup("mdrender", { clear = true })

M.config = {
  enabled = true, -- render new markdown buffers automatically
  heading_icons = { "◉ ", "○ ", "✸ ", "✿ ", "◆ ", "◇ " },
  bullets = { "●", "○", "◆", "◇" },
  checkbox = { unchecked = "☐", checked = "☑" },
  quote = "▎",
  hr = "─",
}

local state = {} -- bufnr -> true (enabled) / false (attached but disabled)

local query
local function get_query()
  query = query
    or vim.treesitter.query.parse(
      "markdown",
      [[
        (atx_heading) @heading
        [(list_marker_minus) (list_marker_plus) (list_marker_star)] @bullet
        (task_list_marker_unchecked) @unchecked
        (task_list_marker_checked) @checked
        (fenced_code_block) @code
        [(block_quote_marker) (block_continuation)] @quote
        (thematic_break) @hr
      ]]
    )
  return query
end

-- Highlights -----------------------------------------------------------------

local function hl_color(name, attr)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hl[attr] or nil
end

local function blend(fg, bg, alpha)
  local out = 0
  for _, shift in ipairs({ 65536, 256, 1 }) do
    local f, b = math.floor(fg / shift) % 256, math.floor(bg / shift) % 256
    out = out + math.floor(f * alpha + b * (1 - alpha) + 0.5) * shift
  end
  return out
end

local function set_highlights()
  local light = vim.o.background == "light"
  local bg = hl_color("Normal", "bg") or (light and 0xffffff or 0x000000)
  local fg = hl_color("Normal", "fg") or (light and 0x000000 or 0xffffff)
  local fallback = { "Title", "Constant", "String", "Function", "Identifier", "Special" }

  for i = 1, 6 do
    local color = hl_color("@markup.heading." .. i .. ".markdown", "fg")
      or hl_color(fallback[i], "fg")
      or fg
    vim.api.nvim_set_hl(0, "MdRenderH" .. i, { fg = color, bold = true, default = true })
    vim.api.nvim_set_hl(0, "MdRenderH" .. i .. "Bg", { bg = blend(color, bg, 0.15), default = true })
  end
  vim.api.nvim_set_hl(0, "MdRenderCode", { bg = blend(fg, bg, 0.07), default = true })
  vim.api.nvim_set_hl(0, "MdRenderBullet", { link = "@markup.list", default = true })
  vim.api.nvim_set_hl(0, "MdRenderUnchecked", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "MdRenderChecked", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "MdRenderQuote", { link = "@markup.quote", default = true })
  vim.api.nvim_set_hl(0, "MdRenderHr", { link = "WinSeparator", default = true })
end

-- Rendering ------------------------------------------------------------------

local function mark(buf, row, col, opts)
  opts.strict = false
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, opts)
end

-- Hide text[scol, ecol) on `row` and show `text` in its place.
local function replace(buf, row, scol, ecol, text, hl)
  mark(buf, row, scol, { end_col = ecol, conceal = "" })
  mark(buf, row, scol, { virt_text = { { text, hl } }, virt_text_pos = "inline" })
end

local function list_depth(node)
  local depth, parent = 0, node:parent()
  while parent do
    if parent:type() == "list" then
      depth = depth + 1
    end
    parent = parent:parent()
  end
  return math.max(depth, 1)
end

local handlers = {}

function handlers.heading(buf, node, cursor)
  local row = node:range()
  local marker = node:child(0)
  local level = tonumber(marker and marker:type():match("^atx_h(%d)_marker$"))
  if not level then
    return
  end
  mark(buf, row, 0, { line_hl_group = "MdRenderH" .. level .. "Bg" })
  if row == cursor then
    return
  end
  local _, mcol, _, mend = marker:range()
  local content = node:child(1)
  local cend = content and select(2, content:range()) or mend
  local icon = M.config.heading_icons[level] or ""
  replace(buf, row, mcol, cend, icon, "MdRenderH" .. level)
end

function handlers.bullet(buf, node, cursor)
  local row, col = node:range()
  if row == cursor then
    return
  end
  local off = vim.treesitter.get_node_text(node, buf):find("[-+*]")
  if not off then
    return
  end
  local icons = M.config.bullets
  local icon = icons[(list_depth(node) - 1) % #icons + 1]
  replace(buf, row, col + off - 1, col + off, icon, "MdRenderBullet")
end

local function checkbox(kind)
  return function(buf, node, cursor)
    local row, col, _, ecol = node:range()
    if row == cursor then
      return
    end
    local hl = kind == "checked" and "MdRenderChecked" or "MdRenderUnchecked"
    replace(buf, row, col, ecol, M.config.checkbox[kind], hl)
  end
end
handlers.unchecked = checkbox("unchecked")
handlers.checked = checkbox("checked")

function handlers.code(buf, node, cursor)
  local srow, _, erow, ecol = node:range()
  local last = ecol == 0 and erow - 1 or erow
  for row = srow, last do
    mark(buf, row, 0, { line_hl_group = "MdRenderCode" })
  end
  for child in node:iter_children() do
    if child:type() == "fenced_code_block_delimiter" then
      local row, col, _, cend = child:range()
      if row ~= cursor then
        mark(buf, row, col, { end_col = cend, conceal = "" })
      end
    end
  end
end

function handlers.quote(buf, node, cursor)
  local row, col = node:range()
  if row == cursor then
    return
  end
  -- Continuation lines can hold several markers (nested quotes) or none (lists).
  local text = vim.treesitter.get_node_text(node, buf):match("^[^\n]*")
  for off in text:gmatch("()>") do
    replace(buf, row, col + off - 1, col + off, M.config.quote, "MdRenderQuote")
  end
end

function handlers.hr(buf, node, cursor, width)
  local row, col = node:range()
  if row == cursor then
    return
  end
  local len = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
  replace(buf, row, col, len, string.rep(M.config.hr, math.max(width - col, 1)), "MdRenderHr")
end

local function render(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local wins = vim.fn.win_findbuf(buf)
  if not state[buf] or #wins == 0 then
    return
  end

  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok or not parser then
    return
  end
  parser:parse()

  -- Only render what is visible in any window showing this buffer.
  local top, bot, width = math.huge, 0, 0
  for _, win in ipairs(wins) do
    vim.wo[win][0].conceallevel = 2
    vim.wo[win][0].concealcursor = ""
    top = math.min(top, vim.fn.line("w0", win) - 1)
    bot = math.max(bot, vim.fn.line("w$", win))
    local info = vim.fn.getwininfo(win)[1]
    width = math.max(width, info.width - info.textoff)
  end

  -- Show raw markdown on the cursor line so it stays editable.
  local cursor = -1
  if vim.api.nvim_get_current_buf() == buf then
    cursor = vim.api.nvim_win_get_cursor(0)[1] - 1
  end

  local q = get_query()
  for _, tree in ipairs(parser:trees()) do
    for id, node in q:iter_captures(tree:root(), buf, top, bot) do
      local handler = handlers[q.captures[id]]
      if handler then
        handler(buf, node, cursor, width)
      end
    end
  end
end

local scheduled = {}
local function schedule(buf)
  if scheduled[buf] then
    return
  end
  scheduled[buf] = true
  vim.schedule(function()
    scheduled[buf] = nil
    render(buf)
  end)
end

-- Public API -----------------------------------------------------------------

function M.attach(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if state[buf] ~= nil then
    return
  end
  state[buf] = M.config.enabled
  vim.api.nvim_create_autocmd({
    "TextChanged",
    "TextChangedI",
    "CursorMoved",
    "CursorMovedI",
    "BufWinEnter",
    "ModeChanged",
  }, { group = group, buffer = buf, callback = function() schedule(buf) end })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = buf,
    callback = function()
      state[buf] = nil
    end,
  })
  schedule(buf)
end

local function set_enabled(buf, value)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  M.attach(buf)
  if value == nil then
    value = not state[buf]
  end
  state[buf] = value
  if not value then
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.wo[win][0].conceallevel = 0
    end
  end
  render(buf)
end

function M.enable(buf) set_enabled(buf, true) end
function M.disable(buf) set_enabled(buf, false) end
function M.toggle(buf) set_enabled(buf, nil) end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  for buf in pairs(state) do
    schedule(buf)
  end
end

local initialized = false
function M._init()
  if initialized then
    return
  end
  initialized = true
  set_highlights()

  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev) M.attach(ev.buf) end,
  })
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
    group = group,
    callback = function()
      for buf in pairs(state) do
        schedule(buf)
      end
    end,
  })

  vim.api.nvim_create_user_command("MdRender", function(cmd)
    local action = cmd.args ~= "" and cmd.args or "toggle"
    if not M[action] or action == "setup" or action:sub(1, 1) == "_" then
      return vim.notify("MdRender: unknown action " .. action, vim.log.levels.ERROR)
    end
    M[action](0)
  end, {
    nargs = "?",
    complete = function() return { "toggle", "enable", "disable" } end,
    desc = "Toggle in-buffer markdown rendering",
  })

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "markdown" then
      M.attach(buf)
    end
  end
end

return M
