--- mlbuddy/ui.lua  ── Enterprise UI primitives
local M = {}

-- ── Highlight groups ─────────────────────────────────────────────────────────

local _hl_ok = false
function M.define_highlights()
  if _hl_ok then return end; _hl_ok = true
  local defs = {
    MlbuddyTitle     = { link="Title",           default=true },
    MlbuddyDim       = { link="Comment",          default=true },
    MlbuddyGood      = { link="DiagnosticOk",     default=true },
    MlbuddyWarn      = { link="DiagnosticWarn",   default=true },
    MlbuddyError     = { link="DiagnosticError",  default=true },
    MlbuddyLayer     = { link="Type",             default=true },
    MlbuddyIdent     = { link="Identifier",       default=true },
    MlbuddyParam     = { link="Number",           default=true },
    MlbuddyBar       = { link="String",           default=true },
    MlbuddyMetric    = { link="Function",         default=true },
    MlbuddyNaN       = { link="ErrorMsg",         default=true },
    MlbuddySparkline = { link="Special",          default=true },
    MlbuddyTabSel    = { link="TabLineSel",       default=true },
    MlbuddyTabNorm   = { link="TabLine",          default=true },
    MlbuddyBorder    = { link="FloatBorder",      default=true },
    MlbuddyStatus    = { link="StatusLine",       default=true },
    MlbuddyGpu       = { fg="#76cce0",  bold=true, default=true },
    MlbuddyLoss      = { fg="#e06c75",  bold=true, default=true },
    MlbuddyAcc       = { fg="#98c379",  bold=true, default=true },
    MlbuddyLr        = { fg="#e5c07b",  bold=true, default=true },
    MlbuddyEpoch     = { fg="#c678dd",  bold=true, default=true },
    MlbuddyCell      = { bg="#2d2d2d",             default=true },
    MlbuddyCellRun   = { fg="#e5c07b",  bold=true, default=true },
  }
  for g, opts in pairs(defs) do
    vim.api.nvim_set_hl(0, g, opts)
  end
end

-- ── Float window ─────────────────────────────────────────────────────────────

---@param opts {title?:string,width?:integer,height?:integer,border?:string,buf?:integer}
---@return integer buf, integer win
function M.float(opts)
  opts = opts or {}
  local W = opts.width  or 84
  local H = opts.height or 40
  local B = opts.border or "rounded"
  local col = math.floor((vim.o.columns - W) / 2)
  local row = math.floor((vim.o.lines   - H) / 2)

  local buf = opts.buf or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].modifiable = false

  local title = opts.title
    and { { "  " .. opts.title .. "  ", "FloatTitle" } }
    or nil

  local win = vim.api.nvim_open_win(buf, true, {
    relative="editor", width=W, height=H, col=col, row=row,
    style="minimal", border=B,
    title=title, title_pos=title and "center" or nil,
    zindex=50,
  })
  vim.wo[win].wrap       = false
  vim.wo[win].cursorline = true
  vim.wo[win].number     = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].winhighlight =
    "Normal:NormalFloat,CursorLine:Visual,FloatBorder:FloatBorder"
  return buf, win
end

-- ── Terminal split ────────────────────────────────────────────────────────────

---@param cmd        string[]
---@param opts       {direction?:"right"|"bottom"|"tab",size?:integer,title?:string}
---@return integer bufnr, integer winnr
function M.terminal_split(cmd, opts)
  opts = opts or {}
  local dir  = opts.direction or "right"
  local size = opts.size or 55

  if dir == "tab" then
    vim.cmd("tabnew")
  elseif dir == "bottom" then
    vim.cmd(size .. "split")
  else
    vim.cmd("vertical " .. size .. "split")
  end

  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)

  -- On Windows wrap command so termopen can launch it
  local launch_cmd = require("mlbuddy.platform").term_cmd(cmd)

  vim.fn.termopen(launch_cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_set_name(buf,
            "[mlbuddy] " .. (opts.title or "process") .. " [exit:" .. code .. "]")
        end
      end)
    end,
  })

  if opts.title then
    vim.api.nvim_buf_set_name(buf, "[mlbuddy] " .. opts.title)
  end

  return buf, win
end

-- ── Tab panel ─────────────────────────────────────────────────────────────────
-- Renders a multi-tab panel in a single float window.
-- Tabs are drawn as a header line; the body below changes per tab.
--
-- Usage:
--   local panel = ui.TabPanel.new({
--     tabs = { { name="TorchView", render=fn }, { name="MLflow", render=fn } },
--     width=84, height=40, border="rounded",
--   })
--   panel:open()
--   panel:select_tab(2)
--   panel:close()

M.TabPanel = {}
M.TabPanel.__index = M.TabPanel

---@param opts {tabs:table[], width:integer, height:integer, border:string, title:string}
function M.TabPanel.new(opts)
  local self = setmetatable({}, M.TabPanel)
  self.opts    = opts
  self.tabs    = opts.tabs or {}
  self.active  = 1
  self.buf     = nil
  self.win     = nil
  self._ns     = vim.api.nvim_create_namespace("mlbuddy_tabpanel_" .. tostring(math.random(1e6)))
  return self
end

function M.TabPanel:open()
  self.buf, self.win = M.float({
    title  = self.opts.title,
    width  = self.opts.width  or 84,
    height = self.opts.height or 40,
    border = self.opts.border,
  })

  -- Tab keymaps
  for i = 1, #self.tabs do
    local idx = i
    local key = tostring(i)
    M.map(self.buf, key, function() self:select_tab(idx) end, "Tab "..i)
  end
  M.map(self.buf, "<Tab>",   function() self:next_tab() end, "Next tab")
  M.map(self.buf, "<S-Tab>", function() self:prev_tab() end, "Prev tab")

  self:_render()
  return self.buf, self.win
end

function M.TabPanel:close()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  self.win = nil
  self.buf = nil
end

function M.TabPanel:select_tab(idx)
  self.active = M.clamp_tab(idx, 1, #self.tabs)
  self:_render()
end

function M.TabPanel:next_tab() self:select_tab(self.active % #self.tabs + 1) end
function M.TabPanel:prev_tab() self:select_tab(((self.active - 2) % #self.tabs) + 1) end

-- Re-render current tab (call from timer/autocmd)
function M.TabPanel:refresh()
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    self:_render()
  end
end

function M.TabPanel:_render()
  if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then return end
  local W = self.opts.width or 84

  -- Build tab header
  local tab_line  = ""
  local tab_hls   = {}
  for i, t in ipairs(self.tabs) do
    local label  = " " .. (t.name or "Tab"..i) .. " "
    local is_sel = (i == self.active)
    local c0     = #tab_line
    tab_line = tab_line .. label .. (i < #self.tabs and "│" or "")
    tab_hls[#tab_hls+1] = {
      row = 0,
      c0  = c0, c1 = c0 + #label,
      hl  = is_sel and "MlbuddyTabSel" or "MlbuddyTabNorm",
    }
  end
  local sep = string.rep("─", W)

  -- Get body lines from active tab's render function
  local tab   = self.tabs[self.active]
  local body  = tab and tab.render and tab.render(W, (self.opts.height or 40) - 3) or {}
  local lines = { tab_line, sep }
  for _, l in ipairs(body.lines or body or {}) do lines[#lines+1] = l end

  M.set_lines(self.buf, lines)

  vim.api.nvim_buf_clear_namespace(self.buf, self._ns, 0, -1)
  for _, h in ipairs(tab_hls) do
    vim.api.nvim_buf_add_highlight(self.buf, self._ns, h.hl, h.row, h.c0, h.c1)
  end

  -- Merge body highlights (shifted by 2 rows for header)
  local body_hls = body.hls or {}
  for _, h in ipairs(body_hls) do
    local c1 = (h.c1 == -1) and #lines[h.row + 3] or h.c1
    vim.api.nvim_buf_add_highlight(self.buf, self._ns, h.hl, h.row + 2, h.c0, c1)
  end
end

M.clamp_tab = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- ── Buffer helpers ────────────────────────────────────────────────────────────

function M.set_lines(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified   = false
end

function M.hl(buf, ns, hl, row, c0, c1)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_add_highlight(buf, ns, hl, row, c0, c1)
end

function M.virt(buf, ns, row, text, hl)
  vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
    virt_text = { { text, hl } }, virt_text_pos = "eol", hl_mode = "combine",
  })
end

-- ── Keymaps ───────────────────────────────────────────────────────────────────

function M.map(buf, lhs, rhs, desc)
  vim.keymap.set("n", lhs, rhs, {
    buffer=buf, silent=true, nowait=true, desc="[mlbuddy] "..(desc or lhs),
  })
end

-- ── Spinner ───────────────────────────────────────────────────────────────────

local _spinners = {}

---@param buf integer
---@param ns  integer
---@param row integer
---@param frames string[]
---@return fun()  stop function
function M.spinner_start(buf, ns, row, frames)
  local idx = 1
  local key = buf .. ":" .. row
  if _spinners[key] then _spinners[key]() end

  local t = vim.uv.new_timer()
  t:start(0, 100, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(buf) then t:stop(); return end
    vim.api.nvim_buf_clear_namespace(buf, ns, row, row+1)
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      virt_text = { { frames[idx], "MlbuddyWarn" } },
      virt_text_pos = "eol",
    })
    idx = idx % #frames + 1
  end))

  local stop = function() t:stop(); _spinners[key] = nil end
  _spinners[key] = stop
  return stop
end

-- ── Notification helpers ──────────────────────────────────────────────────────

function M.info(msg)  vim.notify("[mlbuddy] "..msg, vim.log.levels.INFO)  end
function M.warn(msg)  vim.notify("[mlbuddy] "..msg, vim.log.levels.WARN)  end
function M.error(msg) vim.notify("[mlbuddy] "..msg, vim.log.levels.ERROR) end

return M
