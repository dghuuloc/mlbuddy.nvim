--- mlbuddy/wandb/init.lua
--- Weights & Biases integration: run list, metrics, sweep viewer.
local ui   = require("mlbuddy.ui")
local util = require("mlbuddy.util")
local M    = {}

local NS = vim.api.nvim_create_namespace("mlbuddy_wandb")

-- ── W&B REST API client ───────────────────────────────────────────────────────

local function api_get(path, token, cb)
  util.http_get_auth("https://api.wandb.ai" .. path, token, cb)
end

--- Fetch runs for a project via the W&B GraphQL API (simplified REST).
---@param entity  string
---@param project string
---@param token   string
---@param max     integer
---@param cb      fun(ok:boolean, runs:table[])
local function fetch_runs(entity, project, token, max, cb)
  local url = string.format(
    "https://api.wandb.ai/api/v1/runs?entity=%s&project=%s&per_page=%d",
    entity, project, max
  )
  util.http_get_auth(url, token, function(ok, body)
    if not ok then return cb(false, {}) end
    local d = util.json_decode(body)
    cb(true, d and d.runs or {})
  end)
end

--- Fetch run history (sampled metrics).
---@param entity  string
---@param project string
---@param run_id  string
---@param token   string
---@param cb      fun(ok:boolean, history:table[])
local function fetch_history(entity, project, run_id, token, cb)
  local url = string.format(
    "https://api.wandb.ai/api/v1/runs/%s/%s/%s/history?samples=200",
    entity, project, run_id
  )
  util.http_get_auth(url, token, function(ok, body)
    if not ok then return cb(false, {}) end
    local d = util.json_decode(body)
    cb(true, type(d) == "table" and d or {})
  end)
end

-- ── Build lines ───────────────────────────────────────────────────────────────

local function run_state_hl(state)
  if state == "finished" then return "DONE", "MlbuddyGood"
  elseif state == "running" then return "RUN ", "MlbuddyWarn"
  elseif state == "failed"  then return "FAIL", "MlbuddyError"
  else return state:sub(1,4):upper(), "MlbuddyDim" end
end

local function build_lines(runs, sparklines, cfg)
  local W     = (cfg.width or 84) - 4
  local icons = cfg.icons or {}
  local lines = {}
  local hls   = {}

  local function push(text, hl_list)
    local row = #lines
    lines[#lines+1] = text
    if hl_list then for _, h in ipairs(hl_list) do h.row=row; hls[#hls+1]=h end end
  end

  push("  " .. (icons.wandb or "󰒊") .. "  W&B  —  " ..
    (cfg.wandb.entity or "?") .. "/" .. (cfg.wandb.project or "?"),
    { {c0=0, c1=-1, hl="MlbuddyTitle"} })
  push(string.rep("─", W))

  if #runs == 0 then
    push("  (no runs — check WANDB_API_KEY and entity/project config)",
      { {c0=0, c1=-1, hl="MlbuddyWarn"} })
  else
    push(string.format("  %-6s  %-22s  %-28s  %-22s  %-10s",
      "State", "Run", "Metrics", "Trend", "Age"),
      { {c0=0, c1=-1, hl="MlbuddyDim"} })
    push(string.rep("─", W))

    for _, run in ipairs(runs) do
      local state_str, state_hl = run_state_hl(run.state or "?")
      local name   = (run.displayName or run.name or run.id or "?"):sub(1, 21)
      local config = run.config or {}
      local summ   = run.summary or {}

      -- Metrics summary
      local metric_parts = {}
      for k, v in pairs(summ) do
        if type(v) == "number" and not k:match("^_") then
          metric_parts[#metric_parts+1] = string.format("%s=%.4g", k, v)
          if #metric_parts >= 2 then break end
        end
      end
      local metric_str = #metric_parts > 0 and table.concat(metric_parts, "  ") or "—"

      local spark = sparklines and sparklines[run.id]
        or string.rep("─", cfg.wandb.sparkline_width or 20)

      -- Age
      local age = "?"
      if run.createdAt then
        local ts = run.createdAt:match("^(%d+)")
        if ts then
          local sec = os.time() - tonumber(ts)
          age = util.fmt_secs(sec) .. " ago"
        end
      end

      local line = string.format("  %-6s  %-22s  %-28s  %-22s  %-10s",
        state_str, name:sub(1,21), metric_str:sub(1,27), spark, age:sub(1,9))
      push(line, {
        { c0=2,  c1=8,  hl=state_hl },
        { c0=10, c1=32, hl="MlbuddyIdent" },
        { c0=34, c1=62, hl="MlbuddyMetric" },
        { c0=64, c1=86, hl="MlbuddySparkline" },
        { c0=88, c1=-1, hl="MlbuddyDim" },
      })
    end
  end

  push(""); push(string.rep("─", W))
  push("  [<CR>] detail  [R] refresh  [q] close  — set wandb.entity/project in config",
    { {c0=0, c1=-1, hl="MlbuddyDim"} })
  return lines, hls
end

-- ── State + toggle ────────────────────────────────────────────────────────────

local ctx = { win=nil, buf=nil, runs={}, sparklines={}, timer=nil }

local function get_token(cfg)
  return vim.env[cfg.wandb.api_key_env or "WANDB_API_KEY"] or ""
end

local function do_fetch(cfg, cb)
  local token = get_token(cfg)
  if token == "" then
    ui.warn("WANDB_API_KEY not set"); if cb then cb() end; return
  end
  local entity  = cfg.wandb.entity  or vim.env.WANDB_ENTITY  or ""
  local project = cfg.wandb.project or vim.env.WANDB_PROJECT or ""
  if entity == "" or project == "" then
    ui.warn("Set wandb.entity and wandb.project in mlbuddy config"); if cb then cb() end; return
  end

  fetch_runs(entity, project, token, cfg.wandb.max_runs or 20, function(ok, runs)
    ctx.runs = ok and runs or {}
    -- Fetch sparklines for top runs
    local sparks = {}
    local pending = 0
    for _, run in ipairs(ctx.runs) do
      if run.id then
        pending = pending + 1
        fetch_history(entity, project, run.id, token, function(_, hist)
          if #hist > 0 then
            -- find first numeric metric
            local vals = {}
            local first_key
            for k, v in pairs(hist[1] or {}) do
              if type(v) == "number" and not k:match("^_") then first_key=k; break end
            end
            if first_key then
              for _, row in ipairs(hist) do
                if type(row[first_key]) == "number" then vals[#vals+1] = row[first_key] end
              end
            end
            if #vals > 0 then
              sparks[run.id] = util.sparkline(vals, cfg.wandb.sparkline_width or 20)
            end
          end
          pending = pending - 1
          if pending == 0 then
            ctx.sparklines = sparks
            if ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf) then
              local lines, hls = build_lines(ctx.runs, ctx.sparklines, cfg)
              ui.set_lines(ctx.buf, lines)
              vim.api.nvim_buf_clear_namespace(ctx.buf, NS, 0, -1)
              for _, h in ipairs(hls) do
                local c1=(h.c1==-1) and (lines[h.row+1] and #lines[h.row+1] or 0) or h.c1
                vim.api.nvim_buf_add_highlight(ctx.buf, NS, h.hl, h.row, h.c0, c1)
              end
            end
            if cb then cb() end
          end
        end)
      end
    end
    if pending == 0 then
      if ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf) then
        local lines, hls = build_lines(ctx.runs, ctx.sparklines, cfg)
        ui.set_lines(ctx.buf, lines)
        vim.api.nvim_buf_clear_namespace(ctx.buf, NS, 0, -1)
        for _, h in ipairs(hls) do
          local c1=(h.c1==-1) and (lines[h.row+1] and #lines[h.row+1] or 0) or h.c1
          vim.api.nvim_buf_add_highlight(ctx.buf, NS, h.hl, h.row, h.c0, c1)
        end
      end
      if cb then cb() end
    end
  end)
end

function M.toggle(cfg)
  if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
    if ctx.timer then ctx.timer:stop(); ctx.timer=nil end
    vim.api.nvim_win_close(ctx.win, true); ctx.win=nil; return
  end
  local buf, win = ui.float({
    title=(cfg.icons.wandb or "󰒊").."  W&B",
    width=cfg.width or 84, height=cfg.height or 40, border=cfg.border,
  })
  ctx.buf=buf; ctx.win=win
  ui.set_lines(buf, { "", "  Loading W&B runs…" })

  ui.map(buf, cfg.wandb.keymaps.close or "q", function()
    if ctx.timer then ctx.timer:stop(); ctx.timer=nil end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true); ctx.win=nil
    end
  end, "Close")
  ui.map(buf, cfg.wandb.keymaps.refresh or "R", function()
    do_fetch(cfg)
  end, "Refresh")

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer=buf, once=true,
    callback=function()
      if ctx.timer then ctx.timer:stop(); ctx.timer=nil end
      ctx.win=nil
    end,
  })

  do_fetch(cfg, function()
    local iv = cfg.wandb.refresh_interval or 10000
    if iv > 0 then
      ctx.timer = util.timer(iv, function()
        if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then do_fetch(cfg)
        else if ctx.timer then ctx.timer:stop(); ctx.timer=nil end end
      end)
    end
  end)
end

return M
