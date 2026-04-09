--- mlbuddy/trainer/init.lua
--- Manages live training jobs: captures stdout, parses metrics, drives dashboard.
local parser   = require("mlbuddy.trainer.parser")
local renderer = require("mlbuddy.trainer.renderer")
local ui       = require("mlbuddy.ui")
local M        = {}

-- ── Job registry ──────────────────────────────────────────────────────────────
-- Supports multiple concurrent jobs (e.g. parallel sweeps)

---@class TrainingJob
---@field id         integer
---@field cmd        string[]
---@field state      TrainerState
---@field job_id     integer        vim job id
---@field buf        integer|nil    output float buf
---@field win        integer|nil
---@field timer      uv_timer_t|nil

local _jobs   = {}   -- id → TrainingJob
local _next_id = 1

local function new_state()
  return {
    running    = false,
    exit_code  = nil,
    start_time = nil,
    history    = parser.MetricHistory(),
    active_key = nil,
    log_tail   = {},
  }
end

-- ── Internal: job spawn ───────────────────────────────────────────────────────

---@param job  TrainingJob
---@param cfg  table
local function start_job(job, cfg)
  local state = job.state
  state.running    = true
  state.start_time = os.time()

  local LOG_TAIL = 8
  local extra_pats = cfg.trainer.extra_patterns or {}
  local max_pts    = cfg.trainer.max_history    or 2000

  job.job_id = vim.fn.jobstart(job.cmd, {
    on_stdout = function(_, lines)
      for _, line in ipairs(lines) do
        if line and line ~= "" then
          -- rolling log tail
          state.log_tail[#state.log_tail+1] = line
          while #state.log_tail > LOG_TAIL do table.remove(state.log_tail, 1) end

          -- parse metrics
          local ev = parser.parse_line(line, extra_pats)
          if ev then
            parser.update_history(state.history, ev, max_pts)
            -- set default active key
            if not state.active_key then
              for _, k in ipairs(cfg.trainer.chart_series or {}) do
                if state.history.data[k] then
                  state.active_key = k
                  break
                end
              end
            end
          end
        end
      end
    end,
    on_stderr = function(_, lines)
      for _, line in ipairs(lines) do
        if line and line ~= "" then
          state.log_tail[#state.log_tail+1] = "STDERR: " .. line
          while #state.log_tail > LOG_TAIL do table.remove(state.log_tail, 1) end
          -- many frameworks print to stderr too
          local ev = parser.parse_line(line, extra_pats)
          if ev then parser.update_history(state.history, ev, max_pts) end
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        state.running   = false
        state.exit_code = code
        if job.timer then job.timer:stop(); job.timer = nil end
        if code == 0 then
          ui.info("Training job #" .. job.id .. " finished ✓")
        else
          ui.warn("Training job #" .. job.id .. " exited with code " .. code)
        end
        -- Final render
        if job.buf and vim.api.nvim_buf_is_valid(job.buf) then
          renderer.render(job.buf, state, cfg)
        end
      end)
    end,
    stdout_buffered = false,
    stderr_buffered = false,
  })

  if job.job_id <= 0 then
    state.running   = false
    state.exit_code = -1
    ui.error("Failed to start training job: " .. vim.inspect(job.cmd))
    return
  end

  -- Refresh timer
  local interval = 1000
  job.timer = vim.uv.new_timer()
  job.timer:start(500, interval, vim.schedule_wrap(function()
    if job.buf and vim.api.nvim_buf_is_valid(job.buf) and
       job.win and vim.api.nvim_win_is_valid(job.win) then
      renderer.render(job.buf, state, cfg)
    elseif not state.running then
      if job.timer then job.timer:stop(); job.timer = nil end
    end
  end))
end

-- ── Public: launch ────────────────────────────────────────────────────────────

--- Launch a training command and open the monitor dashboard.
---@param cmd string[]  e.g. { "python", "train.py", "--lr", "1e-3" }
---@param cfg table
---@return integer job_id
function M.launch(cmd, cfg)
  local id  = _next_id; _next_id = _next_id + 1
  local job = {
    id    = id,
    cmd   = cmd,
    state = new_state(),
  }
  _jobs[id] = job

  -- Open dashboard
  local buf, win = renderer.open(job.state, cfg)
  job.buf = buf
  job.win = win

  M._install_keymaps(job, cfg)

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer   = buf,
    once     = true,
    callback = function() job.win = nil end,
  })

  -- Start job after a tick so the window is fully ready
  vim.defer_fn(function() start_job(job, cfg) end, 50)
  return id
end

-- ── Toggle most recent job ────────────────────────────────────────────────────

---@param cfg table
function M.toggle(cfg)
  -- Find latest job
  local latest
  for id, j in pairs(_jobs) do
    if not latest or id > latest.id then latest = j end
  end

  if not latest then
    ui.warn("No training jobs yet. Use :MlbuddyRun or MlbuddyTrainer.launch(cmd, cfg)")
    return
  end

  if latest.win and vim.api.nvim_win_is_valid(latest.win) then
    vim.api.nvim_win_close(latest.win, true)
    latest.win = nil
    return
  end

  -- Reopen
  if latest.buf and vim.api.nvim_buf_is_valid(latest.buf) then
    -- buf still alive, just open a new win
    local win = vim.api.nvim_open_win(latest.buf, true, {
      relative="editor",
      width=cfg.width or 84, height=cfg.height or 40,
      col=math.floor((vim.o.columns - (cfg.width or 84))/2),
      row=math.floor((vim.o.lines   - (cfg.height or 40))/2),
      style="minimal", border=cfg.border or "rounded",
    })
    latest.win = win
    renderer.render(latest.buf, latest.state, cfg)
  else
    -- buf gone; create fresh panel (data still in state)
    local buf, win = renderer.open(latest.state, cfg)
    latest.buf = buf; latest.win = win
    M._install_keymaps(latest, cfg)
  end
end

-- ── Keymaps ───────────────────────────────────────────────────────────────────

function M._install_keymaps(job, cfg)
  local buf = job.buf
  local km  = cfg.trainer.keymaps

  ui.map(buf, km.close or "q", function()
    if job.win and vim.api.nvim_win_is_valid(job.win) then
      vim.api.nvim_win_close(job.win, true)
      job.win = nil
    end
  end, "Close trainer")

  ui.map(buf, km.kill or "K", function()
    if job.state.running and job.job_id then
      vim.fn.jobstop(job.job_id)
      job.state.running   = false
      job.state.exit_code = 130
      ui.warn("Training job #"..job.id.." killed")
    end
  end, "Kill training job")

  ui.map(buf, km.pause_resume or "p", function()
    if job.state.running and job.job_id then
      vim.fn.jobsend(job.job_id, vim.api.nvim_replace_termcodes("<C-c>", true, false, true))
    end
  end, "Interrupt (Ctrl-C) training")

  ui.map(buf, km.cycle_metric or "<Tab>", function()
    local series   = cfg.trainer.chart_series or {}
    local hist     = job.state.history
    local avail    = {}
    for _, k in ipairs(series) do
      if hist.data[k] then avail[#avail+1] = k end
    end
    for k in pairs(hist.data) do
      if not vim.tbl_contains(avail, k) and k ~= "pct" then avail[#avail+1] = k end
    end
    if #avail == 0 then return end
    local cur = job.state.active_key
    local idx = 1
    for i, k in ipairs(avail) do if k == cur then idx = i % #avail + 1; break end end
    job.state.active_key = avail[idx]
    renderer.render(buf, job.state, cfg)
  end, "Cycle metric")

  ui.map(buf, "R", function()
    job.state.history  = parser.MetricHistory()
    job.state.log_tail = {}
    renderer.render(buf, job.state, cfg)
  end, "Clear history")
end

-- ── List jobs ─────────────────────────────────────────────────────────────────

function M.list_jobs()
  local out = {}
  for id, j in pairs(_jobs) do
    out[#out+1] = {
      id      = id,
      cmd     = table.concat(j.cmd, " "):sub(1, 60),
      running = j.state.running,
      steps   = j.state.history.data.step and #j.state.history.data.step or 0,
    }
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

return M
