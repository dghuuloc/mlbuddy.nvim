--- mlbuddy/gpu/renderer.lua + init.lua merged for compactness
--- Renders GPU monitor panel: per-device bars, history sparklines, alerts.
local ui    = require("mlbuddy.ui")
local util  = require("mlbuddy.util")
local nv    = require("mlbuddy.gpu.nvidia")
local M     = {}

local NS = vim.api.nvim_create_namespace("mlbuddy_gpu")

-- ── Gauge bar ─────────────────────────────────────────────────────────────────

local function gauge(val, max_val, width, alert_pct)
  local pct   = max_val > 0 and val / max_val or 0
  local bar   = util.progress_bar(pct, width, "block")
  local hl    = (pct * 100 >= (alert_pct or 90)) and "MlbuddyError"
             or (pct * 100 >= 70)                and "MlbuddyWarn"
             or                                      "MlbuddyGood"
  return bar, hl, pct
end

-- ── Build display lines ───────────────────────────────────────────────────────

---@param gpus     GpuInfo[]
---@param history  table<integer, {util:number[], mem:number[]}>  per-GPU history
---@param cfg      table
---@return string[], table[]
function M.build_lines(gpus, history, cfg)
  local W      = (cfg.width or 84) - 4
  local icons  = cfg.icons or {}
  local a_vram = cfg.gpu.alert_vram_pct or 90
  local a_temp = cfg.gpu.alert_temp_c   or 85
  local SPARK  = 20
  local BAR    = 28

  local lines = {}
  local hls   = {}

  local function push(text, hl_list)
    local row = #lines
    lines[#lines+1] = text
    if hl_list then
      for _, h in ipairs(hl_list) do h.row = row; hls[#hls+1] = h end
    end
  end

  local function rule(ch) push(string.rep(ch or "─", W)) end

  push(string.format("  %s  GPU Monitor  (%d device%s)",
    icons.gpu or "󰊗", #gpus, #gpus==1 and "" or "s"),
    { {c0=0, c1=-1, hl="MlbuddyTitle"} })
  rule()

  if #gpus == 0 then
    push("  (no GPUs detected — install nvidia-smi or rocm-smi)",
      { {c0=0, c1=-1, hl="MlbuddyWarn"} })
  end

  for _, g in ipairs(gpus) do
    push("")
    push(string.format("  GPU %d  %s  driver %s",
      g.index, g.name, g.driver),
      { {c0=2, c1=-1, hl="MlbuddyIdent"} })

    -- Utilization bar
    local util_bar, util_hl = gauge(g.util_pct, 100, BAR)
    push(string.format("  %s Util   %s  %5.1f%%",
      icons.util or "󰓿", util_bar, g.util_pct),
      { {c0=2+#(icons.util or "󰓿")+8, c1=2+#(icons.util or "󰓿")+8+BAR, hl=util_hl} })

    -- VRAM bar
    local vram_bar, vram_hl = gauge(g.mem_used_mib, g.mem_total_mib, BAR, a_vram)
    push(string.format("  %s VRAM   %s  %s / %s",
      icons.vram or "󰍛", vram_bar,
      util.fmt_bytes(g.mem_used_mib*1024*1024),
      util.fmt_bytes(g.mem_total_mib*1024*1024)),
      { {c0=2+#(icons.vram or "󰍛")+8, c1=2+#(icons.vram or "󰍛")+8+BAR, hl=vram_hl} })

    -- Temp / Power / Clock
    local temp_hl = g.temp_c >= a_temp and "MlbuddyError" or "MlbuddyDim"
    push(string.format("  %s %d°C   ⚡ %.0fW   ⏱ %dMHz   🌀 %d%%",
      icons.temp or "󰔅", g.temp_c, g.power_w, g.clock_mhz, g.fan_pct),
      { {c0=0, c1=-1, hl=temp_hl} })

    -- Sparkline history
    local hist = history and history[g.index]
    if hist and #(hist.util or {}) > 2 then
      local u_spark = util.sparkline(hist.util, SPARK)
      local m_spark = util.sparkline(hist.mem,  SPARK)
      push(string.format("  util  %s   vram  %s", u_spark, m_spark),
        { {c0=8, c1=8+SPARK, hl="MlbuddySparkline"},
          {c0=8+SPARK+8, c1=8+SPARK+8+SPARK, hl="MlbuddyBar"} })
    end

    -- Alerts
    if g.mem_pct >= a_vram then
      push(string.format("  %s VRAM HIGH %.0f%%  — risk of OOM",
        icons.warn or "󰀦", g.mem_pct),
        { {c0=0, c1=-1, hl="MlbuddyError"} })
    end
    if g.temp_c >= a_temp then
      push(string.format("  %s TEMP HIGH %d°C  — check cooling",
        icons.warn or "󰀦", g.temp_c),
        { {c0=0, c1=-1, hl="MlbuddyError"} })
    end
  end

  push(""); rule()
  push("  [q] close  [R] manual refresh  — auto-refresh every 1s",
    { {c0=0, c1=-1, hl="MlbuddyDim"} })

  return lines, hls
end

-- ── Render to buf ─────────────────────────────────────────────────────────────

function M.render(buf, gpus, history, cfg)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local lines, hls = M.build_lines(gpus, history, cfg)
  ui.set_lines(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    local c1 = (h.c1==-1) and (lines[h.row+1] and #lines[h.row+1] or 0) or h.c1
    vim.api.nvim_buf_add_highlight(buf, NS, h.hl, h.row, h.c0, c1)
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- GPU module init (state + toggle + statusline)
-- ══════════════════════════════════════════════════════════════════════════════

local ctx = {
  win     = nil,
  buf     = nil,
  timer   = nil,
  gpus    = {},
  history = {},  -- index → { util=[], mem=[] }
}

local HIST_LEN = 60

local function push_hist(gpus)
  for _, g in ipairs(gpus) do
    if not ctx.history[g.index] then
      ctx.history[g.index] = { util={}, mem={} }
    end
    local h = ctx.history[g.index]
    h.util[#h.util+1] = g.util_pct
    h.mem[#h.mem+1]   = g.mem_pct
    while #h.util > HIST_LEN do table.remove(h.util, 1) end
    while #h.mem  > HIST_LEN do table.remove(h.mem,  1) end
  end
end

local function do_query(cfg)
  nv.query(cfg.gpu.backend or "auto", function(gpus)
    -- fix mem_pct for mock
    for _, g in ipairs(gpus) do
      if g.mem_total_mib > 0 then
        g.mem_pct = g.mem_used_mib / g.mem_total_mib * 100
      end
    end
    ctx.gpus = gpus
    push_hist(gpus)
  end)
end

function M.toggle(cfg)
  if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
    if ctx.timer then ctx.timer:stop(); ctx.timer = nil end
    vim.api.nvim_win_close(ctx.win, true)
    ctx.win = nil
    return
  end

  local h = math.min(cfg.height or 40, #ctx.gpus * 10 + 8)
  local buf, win = ui.float({
    title  = (cfg.icons.gpu or "󰊗") .. "  GPU Monitor",
    width  = cfg.width  or 84,
    height = math.max(h, 12),
    border = cfg.border,
  })
  ctx.buf = buf; ctx.win = win

  ui.map(buf, cfg.gpu.keymaps.close or "q", function()
    if ctx.timer then ctx.timer:stop(); ctx.timer = nil end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true); ctx.win = nil
    end
  end, "Close GPU monitor")

  ui.map(buf, "R", function() do_query(cfg) end, "Manual refresh")

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer=buf, once=true,
    callback=function()
      if ctx.timer then ctx.timer:stop(); ctx.timer = nil end
      ctx.win = nil
    end,
  })

  -- Start querying
  do_query(cfg)
  ctx.timer = util.timer(cfg.gpu.refresh_interval or 1000, function()
    do_query(cfg)
    if ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf) then
      M.render(ctx.buf, ctx.gpus, ctx.history, cfg)
    end
  end)
end

-- ── Statusline component ──────────────────────────────────────────────────────

--- Returns a short GPU status string for the statusline.
---@return string
function M.statusline()
  if #ctx.gpus == 0 then return "" end
  local parts = {}
  for _, g in ipairs(ctx.gpus) do
    parts[#parts+1] = string.format("GPU%d %.0f%% %.0fMiB", g.index, g.util_pct, g.mem_used_mib)
  end
  return "󰊗 " .. table.concat(parts, "  ")
end

--- Start background GPU polling (for statusline, no window needed).
---@param cfg table
function M.start_background(cfg)
  if ctx.timer then return end  -- already running
  do_query(cfg)
  ctx.timer = util.timer(cfg.gpu.refresh_interval or 2000, function()
    do_query(cfg)
  end)
end

function M.stop_background()
  if ctx.timer then ctx.timer:stop(); ctx.timer = nil end
end

return M
