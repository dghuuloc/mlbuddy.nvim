--- mlbuddy.mlflow.renderer
--- Renders experiment runs as a table with ASCII sparklines.
local ui     = require("mlbuddy.ui")
local util   = require("mlbuddy.util")
local client = require("mlbuddy.mlflow.client")
local M      = {}

local NS = vim.api.nvim_create_namespace("mlbuddy_mf_render")

-- ── Layout constants ──────────────────────────────────────────────────────────
local COL = {
  STATUS  = 6,
  NAME    = 22,
  METRICS = 38,   -- metric key + value
  SPARK   = 24,   -- sparkline chars
  TIME    = 12,
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function ts_to_relative(ms)
  if not ms then return "?" end
  local sec = math.floor((os.time() * 1000 - ms) / 1000)
  if sec < 60    then return sec  .. "s ago"  end
  if sec < 3600  then return math.floor(sec/60)   .. "m ago" end
  if sec < 86400 then return math.floor(sec/3600) .. "h ago" end
  return math.floor(sec/86400) .. "d ago"
end

local function truncate(s, w)
  s = tostring(s)
  if vim.fn.strdisplaywidth(s) <= w then return util.pad(s, w) end
  return s:sub(1, w - 1) .. "…"
end

-- ── Line builder ──────────────────────────────────────────────────────────────

---@class MlflowViewState
---@field experiments table[]
---@field runs        table[]
---@field sparklines  table<string,string>   run_id → sparkline string
---@field active_exp  string|nil

---@param state MlflowViewState
---@param cfg   table
---@return string[], table[]  lines, hls
function M.build_lines(state, cfg)
  local W     = (cfg.width or 76) - 2
  local icons = cfg.icons or {}
  local lines = {}
  local hls   = {}

  local function push(text, hl_list)
    local row = #lines
    lines[#lines + 1] = text
    if hl_list then
      for _, h in ipairs(hl_list) do
        h.row = row
        hls[#hls + 1] = h
      end
    end
  end

  local function rule(ch) push(string.rep(ch or "─", W)) end

  -- Header
  push(string.format(
    "  %s  MLflow Experiment Tracker  [%s]",
    icons.run or "󰓄",
    cfg.mlflow.tracking_uri),
    { { c0 = 0, c1 = -1, hl = "MlbuddyTitle" } }
  )
  rule()

  -- Experiments list
  if #(state.experiments or {}) == 0 then
    push("  (no experiments — is MLflow running?)",
      { { c0 = 0, c1 = -1, hl = "MlbuddyWarn" } })
    push("")
  else
    push("  Experiments:", { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
    for _, exp in ipairs(state.experiments or {}) do
      local active = (state.active_exp == exp.experiment_id)
      local prefix = active and "  ▶ " or "    "
      local name   = truncate(exp.name or exp.experiment_id, 40)
      push(prefix .. name, {
        { c0 = 0, c1 = -1, hl = active and "MlbuddyMetric" or "Normal" },
      })
    end
    push("")
  end

  -- Column header for runs
  rule("─")
  local hdr = string.format("  %-6s %-22s %-38s %-24s %-12s",
    "Status", "Run Name", "Metrics (last val)", "Trend", "Started")
  push(hdr, { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
  rule("─")

  -- Runs
  if #(state.runs or {}) == 0 then
    push("  (no runs found)",
      { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
  else
    for _, run in ipairs(state.runs or {}) do
      local info    = run.info or {}
      local metrics = client.last_metrics(run)
      local status, st_hl = client.run_status(run)

      -- Run name (use tags if available)
      local tags     = run.data and run.data.tags or {}
      local run_name = info.run_name or ""
      for _, t in ipairs(tags) do
        if t.key == "mlflow.runName" then run_name = t.value; break end
      end
      if run_name == "" then run_name = (info.run_id or ""):sub(1, 8) end

      -- Metric summary (first two keys)
      local metric_parts = {}
      for k, v in pairs(metrics) do
        metric_parts[#metric_parts + 1] = string.format("%s=%.4g", k, v)
        if #metric_parts >= 2 then break end
      end
      local metric_str = #metric_parts > 0
        and table.concat(metric_parts, "  ")
        or  "—"

      local spark = state.sparklines and state.sparklines[info.run_id] or
                    string.rep("─", cfg.mlflow.sparkline_width or 20)

      local rel_time = ts_to_relative(info.start_time)

      local row_text = string.format("  %-6s %-22s %-38s %-24s %-12s",
        status,
        truncate(run_name, 21),
        truncate(metric_str, 37),
        spark,
        rel_time
      )

      -- Find byte offsets for each column
      local c_status  = 2
      local c_name    = c_status + 7
      local c_metrics = c_name   + 23
      local c_spark   = c_metrics + 39
      local c_time    = c_spark   + 25

      push(row_text, {
        { c0 = c_status,  c1 = c_status + 6,  hl = st_hl         },
        { c0 = c_name,    c1 = c_name + 22,   hl = "MlbuddyIdent"},
        { c0 = c_metrics, c1 = c_metrics + 38, hl = "MlbuddyMetric"},
        { c0 = c_spark,   c1 = c_spark + 24,  hl = "MlbuddySparkline"},
        { c0 = c_time,    c1 = -1,            hl = "MlbuddyDim"  },
      })
    end
  end

  push("")
  rule("─")
  push(
    "  [R] refresh  [<CR>] detail  [c] compare  [e] experiments  [q] close",
    { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } }
  )

  return lines, hls
end

-- ── Sparkline enrichment ──────────────────────────────────────────────────────

--- Asynchronously fetch metric history for each run and build sparklines.
---@param runs   table[]
---@param uri    string
---@param width  integer
---@param cb     fun(sparklines: table<string,string>)
function M.fetch_sparklines(runs, uri, width, cb)
  local sparklines = {}
  local pending    = 0

  for _, run in ipairs(runs) do
    local info    = run.info or {}
    local metrics = client.last_metrics(run)
    -- Pick first available metric key
    local key
    for k in pairs(metrics) do key = k; break end
    if not key or not info.run_id then goto skip end

    pending = pending + 1
    client.metric_history(uri, info.run_id, key, function(ok, pts)
      if ok and #pts > 0 then
        local vals = {}
        for _, p in ipairs(pts) do vals[#vals + 1] = p.value end
        sparklines[info.run_id] = util.sparkline(vals, width)
      else
        sparklines[info.run_id] = string.rep("─", width)
      end
      pending = pending - 1
      if pending == 0 then cb(sparklines) end
    end)

    ::skip::
  end

  if pending == 0 then cb(sparklines) end
end

-- ── Render helpers ────────────────────────────────────────────────────────────

--- Apply highlight specs to a buffer.
---@param buf  integer
---@param hls  table[]
---@param lines string[]
function M.apply_hls(buf, hls, lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    local c1 = (h.c1 == -1) and #lines[h.row + 1] or h.c1
    vim.api.nvim_buf_add_highlight(buf, NS, h.hl, h.row, h.c0, c1)
  end
end

--- Redraw an existing buffer with fresh state.
---@param buf   integer
---@param state MlflowViewState
---@param cfg   table
function M.redraw(buf, state, cfg)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local lines, hls = M.build_lines(state, cfg)
  ui.set_lines(buf, lines)
  M.apply_hls(buf, hls, lines)
end

--- Open the MLflow float window.
---@param state MlflowViewState
---@param cfg   table
---@return integer buf, integer win
function M.open(state, cfg)
  local buf, win = ui.float({
    title  = (cfg.icons and cfg.icons.run or "󰓄") .. "  MLflow",
    width  = cfg.width  or 76,
    height = cfg.height or 36,
    border = cfg.border,
  })
  M.redraw(buf, state, cfg)
  vim.bo[buf].filetype = "mlbuddy_mlflow"
  return buf, win
end

return M
