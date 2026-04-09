--- mlbuddy/trainer/renderer.lua
--- Renders the live training dashboard: charts, stats, progress, GPU.
local ui     = require("mlbuddy.ui")
local util   = require("mlbuddy.util")
local parser = require("mlbuddy.trainer.parser")
local M      = {}

local NS = vim.api.nvim_create_namespace("mlbuddy_trainer")

-- ── Metric color map ──────────────────────────────────────────────────────────

local METRIC_COLORS = {
  loss      = "MlbuddyLoss",   train_loss = "MlbuddyLoss",
  val_loss  = "MlbuddyWarn",   test_loss  = "MlbuddyError",
  acc       = "MlbuddyAcc",    accuracy   = "MlbuddyAcc",
  val_acc   = "MlbuddyGood",
  lr        = "MlbuddyLr",     learning_rate = "MlbuddyLr",
  reward    = "MlbuddyMetric", f1         = "MlbuddyMetric",
}
local function metric_color(k)
  return METRIC_COLORS[k] or "MlbuddySparkline"
end

-- ── Section builders ─────────────────────────────────────────────────────────

--- Build the status bar line
---@param state table  trainer state
---@param cfg   table
---@return string, table[]
local function status_bar(state, W, icons)
  local parts = {}
  local hls   = {}
  local off   = 0

  local function add(s, hl)
    parts[#parts+1] = s
    if hl then
      hls[#hls+1] = { c0=off, c1=off+#s, hl=hl }
    end
    off = off + #s + 1  -- +1 for space
  end

  -- Status icon
  if state.running then
    add((icons.spinner or {" "})[math.floor(vim.uv.now()/100) % #(icons.spinner or {" "}) + 1], "MlbuddyWarn")
    add("RUNNING", "MlbuddyWarn")
  else
    add("●", state.exit_code == 0 and "MlbuddyGood" or "MlbuddyError")
    add(state.exit_code == 0 and "DONE" or ("FAILED("..tostring(state.exit_code)..")"),
      state.exit_code == 0 and "MlbuddyGood" or "MlbuddyError")
  end

  -- Epoch/step
  local hist = state.history
  local ep   = parser.stats(hist, "epoch")
  local st   = parser.stats(hist, "step")
  if ep then add(string.format("epoch %.0f", ep.last), "MlbuddyEpoch") end
  if st then add(string.format("step %.0f", st.last),  "MlbuddyDim")  end

  -- Elapsed / ETA
  if state.start_time then
    local elapsed = os.time() - state.start_time
    add("⏱ "..util.fmt_secs(elapsed), "MlbuddyDim")

    local prog = parser.stats(hist, "pct")
    if prog and prog.last > 0 and prog.last < 1 then
      local eta = elapsed * (1 - prog.last) / prog.last
      add("ETA "..util.fmt_secs(eta), "MlbuddyDim")
    end
  end

  local line = "  " .. table.concat(parts, " ")
  return line, hls
end

--- Build progress bar line
---@param state table
---@param W     integer
---@return string, table[]
local function progress_section(state, W)
  local pct_stat = parser.stats(state.history, "pct")
  local pct      = pct_stat and pct_stat.last or 0
  local bar_w    = W - 12
  local bar      = util.progress_bar(pct, bar_w, "block")
  local pct_str  = string.format("%5.1f%%", pct * 100)
  return "  " .. bar .. "  " .. pct_str, {
    { c0=2, c1=2+bar_w, hl="MlbuddyBar" },
    { c0=2+bar_w+2, c1=-1, hl="MlbuddyDim" },
  }
end

--- Build metrics summary table
---@param state   table
---@param tracked string[]
---@param W       integer
---@return string[], table[]
local function metrics_section(state, tracked, W)
  local lines = {}
  local hls   = {}
  local hist  = state.history

  lines[#lines+1] = "  ─── Latest Metrics " .. string.rep("─", W-22)
  hls[#hls+1] = { row=#lines-1, c0=0, c1=-1, hl="MlbuddyDim" }

  local col_w = math.floor((W - 4) / 3)
  local row   = ""
  local col   = 0

  local function flush()
    if row ~= "" then
      lines[#lines+1] = "  " .. row
      row = ""
      col = 0
    end
  end

  for _, k in ipairs(tracked) do
    local st = parser.stats(hist, k)
    if st then
      local s = string.format("%-12s %10.5g  Δ%+.4g",
        k, st.last, st.delta)
      s = util.pad(s, col_w)
      row = row .. s
      col = col + 1
      if col >= 3 then flush() end
    end
  end
  flush()

  -- also show any untracked keys that appeared
  for k, _ in pairs(hist.data) do
    if not vim.tbl_contains(tracked, k) then
      local st = parser.stats(hist, k)
      if st then
        local s = util.pad(string.format("%-12s %10.5g", k, st.last), col_w)
        row = row .. s
        col = col + 1
        if col >= 3 then flush() end
      end
    end
  end
  flush()

  for li = 2, #lines do
    hls[#hls+1] = { row=li-1, c0=0, c1=-1, hl="MlbuddyMetric" }
  end
  return lines, hls
end

--- Build a chart for a given metric key
---@param hist    MetricHistory
---@param key     string
---@param val_key string|nil  secondary series (e.g. "val_loss" for "loss")
---@param W       integer
---@param H       integer
---@param smooth  integer
---@return table  chart result from util.chart2d
local function build_chart(hist, key, val_key, W, H, smooth)
  local series = {}
  local v1 = parser.get_series(hist, key)
  if #v1 > 0 then
    if smooth > 1 then v1 = util.smooth_ema(v1, smooth) end
    series[#series+1] = { name=key, values=v1, color=metric_color(key) }
  end
  if val_key then
    local v2 = parser.get_series(hist, val_key)
    if #v2 > 0 then
      if smooth > 1 then v2 = util.smooth_ema(v2, smooth) end
      series[#series+1] = { name=val_key, values=v2, color=metric_color(val_key) }
    end
  end
  return util.chart2d({
    width   = W - 2,
    height  = H,
    title   = key .. (val_key and " / "..val_key or ""),
    x_label = "step",
    series  = series,
  })
end

-- ── Public: render full dashboard ────────────────────────────────────────────

---@class TrainerState
---@field running    boolean
---@field exit_code  integer|nil
---@field start_time integer|nil   os.time()
---@field history    MetricHistory
---@field active_key string        currently displayed metric
---@field log_tail   string[]      last N lines of raw stdout

---@param buf    integer
---@param state  TrainerState
---@param cfg    table
function M.render(buf, state, cfg)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local W       = cfg.width  or 84
  local H       = cfg.height or 40
  local icons   = cfg.icons  or {}
  local tracked = cfg.trainer.chart_series or {}
  local smooth  = cfg.trainer.smooth_window or 5
  local chart_h = cfg.trainer.chart_height or 14

  -- choose active pair (loss/val_loss, acc/val_acc, etc.)
  local key    = state.active_key or tracked[1] or "loss"
  local val_key
  if key:sub(1,4) ~= "val_" then
    local candidate = "val_" .. key
    if state.history.data[candidate] then val_key = candidate end
  end

  local lines = {}
  local hls   = {}
  local base  = 0

  local function push_all(new_lines, new_hls)
    for _, l in ipairs(new_lines) do lines[#lines+1] = l end
    for _, h in ipairs(new_hls or {}) do
      h.row = (h.row or 0) + base
      hls[#hls+1] = h
    end
    base = #lines
  end

  -- Header
  push_all(
    { string.format("  %s  Training Monitor", icons.train or "󱘖"), string.rep("─", W-2) },
    { { row=0, c0=0, c1=-1, hl="MlbuddyTitle" } }
  )

  -- Status bar
  do
    local sl, sh = status_bar(state, W, icons)
    push_all({ sl }, sh)
  end

  -- Progress bar
  do
    local pl, ph = progress_section(state, W)
    push_all({ pl }, ph)
    push_all({ string.rep("─", W-2) }, {})
  end

  -- Chart
  if state.history and next(state.history.data) then
    local chart = build_chart(state.history, key, val_key, W, chart_h, smooth)
    push_all(chart.lines, chart.hls)
    push_all({ string.rep("─", W-2) }, {})
  end

  -- Metrics summary
  do
    local ml, mh = metrics_section(state, tracked, W)
    push_all(ml, mh)
    push_all({ string.rep("─", W-2) }, {})
  end

  -- Log tail
  push_all({ "  ─── Log (last 5 lines) " .. string.rep("─", W-26) },
    { { row=0, c0=0, c1=-1, hl="MlbuddyDim" } })
  for _, l in ipairs(state.log_tail or {}) do
    push_all({ "  " .. l:sub(1, W-4) }, { { row=0, c0=0, c1=-1, hl="MlbuddyDim" } })
  end

  -- Footer
  push_all({ string.rep("─", W-2),
    "  [q] close  [p] pause/resume  [K] kill  [<Tab>] cycle metric  [R] clear" },
    { { row=1, c0=0, c1=-1, hl="MlbuddyDim" } })

  -- Write buffer
  ui.set_lines(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    local c1 = (h.c1 == -1) and (lines[h.row+1] and #lines[h.row+1] or 0) or h.c1
    vim.api.nvim_buf_add_highlight(buf, NS, h.hl, h.row, h.c0, c1)
  end
end

--- Open the trainer float.
---@param state TrainerState
---@param cfg   table
---@return integer buf, integer win
function M.open(state, cfg)
  local buf, win = ui.float({
    title  = (cfg.icons and cfg.icons.train or "󱘖") .. "  Training Monitor",
    width  = cfg.width  or 84,
    height = cfg.height or 40,
    border = cfg.border,
  })
  M.render(buf, state, cfg)
  vim.bo[buf].filetype = "mlbuddy_trainer"
  return buf, win
end

return M
