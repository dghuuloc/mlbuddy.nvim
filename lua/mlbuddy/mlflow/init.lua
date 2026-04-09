--- mlbuddy.mlflow
--- Orchestrates the MLflow experiment tracker panel.
local client   = require("mlbuddy.mlflow.client")
local renderer = require("mlbuddy.mlflow.renderer")
local ui       = require("mlbuddy.ui")
local util     = require("mlbuddy.util")
local M        = {}

---@type { win:integer|nil, buf:integer|nil, timer:uv_timer_t|nil, state:MlflowViewState }
local ctx = {
  win   = nil,
  buf   = nil,
  timer = nil,
  state = { experiments = {}, runs = {}, sparklines = {}, active_exp = nil },
}

-- ── Data fetch ────────────────────────────────────────────────────────────────

---@param cfg table
---@param then_cb fun()|nil
local function fetch_all(cfg, then_cb)
  local uri = cfg.mlflow.tracking_uri

  client.list_experiments(uri, function(ok, exps)
    ctx.state.experiments = ok and exps or {}

    -- pick first experiment if none active
    if not ctx.state.active_exp and #ctx.state.experiments > 0 then
      ctx.state.active_exp = ctx.state.experiments[1].experiment_id
    end

    local exp_ids = {}
    if ctx.state.active_exp then
      exp_ids = { ctx.state.active_exp }
    end

    client.search_runs(uri, exp_ids, cfg.mlflow.max_runs, function(ok2, runs)
      ctx.state.runs = ok2 and runs or {}

      renderer.fetch_sparklines(
        ctx.state.runs, uri,
        cfg.mlflow.sparkline_width or 20,
        function(sparks)
          ctx.state.sparklines = sparks
          if ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf) then
            renderer.redraw(ctx.buf, ctx.state, cfg)
          end
          if then_cb then then_cb() end
        end
      )
    end)
  end)
end

-- ── Detail view ───────────────────────────────────────────────────────────────

---@param run table
---@param cfg table
local function show_detail(run, cfg)
  local info    = run.info or {}
  local params  = client.params(run)
  local metrics = client.last_metrics(run)
  local status, _ = client.run_status(run)

  local lines = {
    "",
    "  Run ID : " .. (info.run_id or "?"),
    "  Name   : " .. (info.run_name or "—"),
    "  Status : " .. status,
    "  Start  : " .. tostring(info.start_time or "?"),
    "  End    : " .. tostring(info.end_time   or "—"),
    "",
    "  ── Params ──────────────────────────────────────────",
  }
  for k, v in pairs(params) do
    lines[#lines + 1] = string.format("    %-28s  %s", k, v)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  ── Metrics (last value) ──────────────────────────"
  for k, v in pairs(metrics) do
    lines[#lines + 1] = string.format("    %-28s  %.6g", k, v)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  [q] back"

  local w = math.max(60, cfg.width or 76)
  local h = math.min(#lines + 2, cfg.height or 36)
  local dbuf, dwin = ui.float({
    title  = "  Run Detail",
    width  = w,
    height = h,
    border = cfg.border,
  })
  ui.set_lines(dbuf, lines)
  vim.bo[dbuf].filetype = "mlbuddy_mlflow_detail"

  ui.map(dbuf, "q", function()
    if vim.api.nvim_win_is_valid(dwin) then
      vim.api.nvim_win_close(dwin, true)
    end
  end, "Close detail")
end

-- ── Toggle ────────────────────────────────────────────────────────────────────

---@param cfg table
function M.toggle(cfg)
  if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
    if ctx.timer then ctx.timer:stop(); ctx.timer = nil end
    vim.api.nvim_win_close(ctx.win, true)
    ctx.win = nil
    return
  end

  -- Initial render with placeholder
  ctx.state = { experiments = {}, runs = {}, sparklines = {}, active_exp = nil }
  local buf, win = renderer.open(ctx.state, cfg)
  ctx.buf = buf
  ctx.win = win

  ui.set_lines(buf, { "", "  Loading…" })

  -- Keymaps
  local km = cfg.mlflow.keymaps

  ui.map(buf, km.close or "q", function()
    if ctx.timer then ctx.timer:stop(); ctx.timer = nil end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
      ctx.win = nil
    end
  end, "Close MLflow panel")

  ui.map(buf, km.refresh or "R", function()
    fetch_all(cfg)
    vim.notify("[mlbuddy] MLflow refreshed", vim.log.levels.INFO)
  end, "Refresh runs")

  -- <CR> → open detail for run under cursor
  ui.map(buf, km.select or "<CR>", function()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    -- Runs start after header (experiments + 3 header lines + 1-indexed)
    local run_offset = #ctx.state.experiments + 7
    local idx = row - run_offset
    if idx >= 1 and idx <= #ctx.state.runs then
      show_detail(ctx.state.runs[idx], cfg)
    end
  end, "Open run detail")

  -- [e] → cycle active experiment
  ui.map(buf, "e", function()
    local exps = ctx.state.experiments
    if #exps == 0 then return end
    local cur = ctx.state.active_exp
    local next_idx = 1
    for i, exp in ipairs(exps) do
      if exp.experiment_id == cur then
        next_idx = (i % #exps) + 1
        break
      end
    end
    ctx.state.active_exp = exps[next_idx].experiment_id
    fetch_all(cfg)
  end, "Cycle experiment")

  -- Auto-close cleanup
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer  = buf,
    once    = true,
    callback = function()
      if ctx.timer then ctx.timer:stop(); ctx.timer = nil end
      ctx.win = nil
    end,
  })

  -- Start data fetch + refresh timer
  fetch_all(cfg, function()
    if not (ctx.win and vim.api.nvim_win_is_valid(ctx.win)) then return end
    local interval = cfg.mlflow.refresh_interval or 5000
    if interval > 0 then
      ctx.timer = util.timer(interval, function()
        if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
          fetch_all(cfg)
        else
          ctx.timer:stop()
          ctx.timer = nil
        end
      end)
    end
  end)
end

return M
