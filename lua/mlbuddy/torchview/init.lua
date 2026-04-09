--- mlbuddy.torchview
--- Orchestrates model parsing, virtual-text attachment, and window toggling.
local parser   = require("mlbuddy.torchview.parser")
local renderer = require("mlbuddy.torchview.renderer")
local ui       = require("mlbuddy.ui")
local util     = require("mlbuddy.util")
local M        = {}

local NS_VIRT = vim.api.nvim_create_namespace("mlbuddy_tv_virt")
local state   = { win = nil, buf = nil, src_buf = nil }

-- ── Virtual text ───────────────────────────────────────────────────────────────

--- Attach inline param-count hints to a Python source buffer.
---@param bufnr   integer
---@param classes MlbuddyClass[]
---@param cfg     table
local function attach_virt(bufnr, classes, cfg)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, NS_VIRT, 0, -1)
  if not cfg.torchview.virtual_text then return end

  for _, cls in ipairs(classes) do
    for _, layer in ipairs(cls.layers) do
      local hint
      if layer.params > 0 then
        hint = string.format("  params: %s", util.fmt_num(layer.params))
        ui.virt(bufnr, NS_VIRT, layer.line - 1, hint, "MlbuddyDim")
      elseif layer.params == 0 then
        hint = "  no params"
        ui.virt(bufnr, NS_VIRT, layer.line - 1, hint, "MlbuddyDim")
      end
    end
  end
end

-- ── Toggle ─────────────────────────────────────────────────────────────────────

--- Toggle the TorchView panel for the current Python buffer.
---@param cfg table
function M.toggle(cfg)
  -- Close if already open
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
    state.win = nil
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "python" then
    vim.notify("[mlbuddy] TorchView: current buffer is not Python", vim.log.levels.WARN)
    return
  end

  state.src_buf = bufnr
  local classes = parser.parse(bufnr)

  if #classes == 0 then
    vim.notify("[mlbuddy] TorchView: no nn.Module subclasses found", vim.log.levels.INFO)
    return
  end

  attach_virt(bufnr, classes, cfg)

  local buf, win = renderer.open(classes, cfg)
  state.buf = buf
  state.win = win

  -- Keymaps inside the float
  local km = cfg.torchview.keymaps
  ui.map(buf, km.close or "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
      state.win = nil
    end
  end, "Close TorchView")

  ui.map(buf, "R", function()
    if not vim.api.nvim_win_is_valid(win) then return end
    local src = state.src_buf
    if not (src and vim.api.nvim_buf_is_valid(src)) then return end
    local fresh = parser.parse(src)
    attach_virt(src, fresh, cfg)
    local lines, hls = renderer.build_lines(fresh, cfg)
    ui.set_lines(buf, lines)
    local NS = vim.api.nvim_create_namespace("mlbuddy_tv_render")
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    for _, h in ipairs(hls) do
      local c1 = (h.c1 == -1) and #lines[h.row + 1] or h.c1
      vim.api.nvim_buf_add_highlight(buf, NS, h.hl, h.row, h.c0, c1)
    end
    vim.notify("[mlbuddy] TorchView refreshed", vim.log.levels.INFO)
  end, "Re-parse model")

  -- Auto-close when leaving the float
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer  = buf,
    once    = true,
    callback = function() state.win = nil end,
  })
end

-- ── Setup ──────────────────────────────────────────────────────────────────────

--- Install autocommands for virtual-text on Python buffers.
---@param cfg table
function M.setup_autocmds(cfg)
  if not cfg.torchview.auto_attach then return end

  local ag = vim.api.nvim_create_augroup("MlbuddyTorchView", { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group   = ag,
    pattern = "*.py",
    callback = function(ev)
      vim.defer_fn(function()
        if not vim.api.nvim_buf_is_valid(ev.buf) then return end
        local classes = parser.parse(ev.buf)
        attach_virt(ev.buf, classes, cfg)
      end, 150)
    end,
  })

  -- Clear hints when buffer is deleted
  vim.api.nvim_create_autocmd("BufDelete", {
    group   = ag,
    pattern = "*.py",
    callback = function(ev)
      if vim.api.nvim_buf_is_valid(ev.buf) then
        vim.api.nvim_buf_clear_namespace(ev.buf, NS_VIRT, 0, -1)
      end
    end,
  })
end

return M
