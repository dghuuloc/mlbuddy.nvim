--- mlbuddy/statusline/init.lua
--- Statusline components for lualine, heirline, feline, or raw statusline.
local M = {}

-- ── State cache (updated by background timers) ────────────────────────────────

local _cache = {
  gpu_str  = "",
  env_str  = "",
  job_str  = "",
  updated  = 0,
}

-- ── Component builders ────────────────────────────────────────────────────────

--- GPU component: "󰊗 GPU0 72% 14.2GiB/24GiB 68°C"
---@return string
function M.gpu()
  -- gpu module updates ctx.gpus via its background timer
  local ok, gpu_mod = pcall(require, "mlbuddy.gpu")
  if not ok then return "" end
  return gpu_mod.statusline()
end

--- Active Python env: "󰢱 .venv" or "󰊕 conda:base"
---@return string
function M.env()
  local ok, env_mod = pcall(require, "mlbuddy.env")
  if not ok then return "" end
  local name = env_mod.active_name()
  if name == "" then return "" end
  -- Pick icon based on type
  local icon = name:match("^conda:") and "󰊕" or "󰏗"
  return icon .. " " .. name
end

--- Active training job: "󱘖 training step 1240 loss=0.234"
---@return string
function M.job()
  local ok, trainer = pcall(require, "mlbuddy.trainer")
  if not ok then return "" end
  local jobs = trainer.list_jobs()
  for _, j in ipairs(jobs) do
    if j.running then
      local icons = (require("mlbuddy.config").defaults.icons)
      local sp = (icons.spinner or {"⠋"})[math.floor(vim.uv.now()/100) % #(icons.spinner or {"⠋"}) + 1]
      return sp .. " training  step " .. j.steps
    end
  end
  -- Show last finished job
  for _, j in ipairs(jobs) do
    return "󰄬 done  step " .. j.steps
  end
  return ""
end

--- Combined component (all three).
---@return string
function M.all()
  local parts = {}
  local gpu = M.gpu()
  local env = M.env()
  local job = M.job()
  if gpu ~= "" then parts[#parts+1] = gpu end
  if env ~= "" then parts[#parts+1] = env end
  if job ~= "" then parts[#parts+1] = job end
  return table.concat(parts, "  ")
end

-- ── lualine component ─────────────────────────────────────────────────────────

---@return table  lualine component spec
function M.lualine_component()
  return {
    M.all,
    color = "MlbuddyStatus",
    cond  = function() return M.all() ~= "" end,
  }
end

--- Individual lualine components
function M.lualine_gpu()
  return { M.gpu, color="MlbuddyGpu", cond=function() return M.gpu() ~= "" end }
end
function M.lualine_env()
  return { M.env, color="MlbuddyMetric", cond=function() return M.env() ~= "" end }
end
function M.lualine_job()
  return { M.job, color="MlbuddyWarn", cond=function() return M.job() ~= "" end }
end

-- ── heirline component ────────────────────────────────────────────────────────

---@return table  heirline component spec
function M.heirline_component()
  return {
    provider = function() return " " .. M.all() .. " " end,
    hl       = "MlbuddyStatus",
    update   = { "User", pattern = "MlbuddyStatusUpdate" },
  }
end

-- ── Raw %{} statusline expression ─────────────────────────────────────────────

--- For use in a plain vim.opt.statusline:
---   vim.opt.statusline = "%f  " .. require("mlbuddy.statusline").raw_expr()
---@return string
function M.raw_expr()
  return "%{%v:lua.require('mlbuddy.statusline').all()%}"
end

-- ── Setup: background update timer ───────────────────────────────────────────

---@param cfg table
function M.setup(cfg)
  if not cfg.statusline.enabled then return end

  -- Start GPU background polling if enabled
  if cfg.statusline.show_gpu and cfg.gpu.enabled then
    local ok, gpu_mod = pcall(require, "mlbuddy.gpu")
    if ok then gpu_mod.start_background(cfg) end
  end

  -- Trigger statusline redraw periodically
  local ms = cfg.statusline.update_ms or 2000
  local t  = vim.uv.new_timer()
  t:start(ms, ms, vim.schedule_wrap(function()
    -- Signal heirline / custom statuslines to update
    vim.api.nvim_exec_autocmds("User", { pattern="MlbuddyStatusUpdate" })
    -- For plain statusline
    vim.cmd.redrawstatus()
  end))

  -- Expose timer for cleanup
  M._timer = t
end

function M.teardown()
  if M._timer then M._timer:stop(); M._timer = nil end
  local ok, gpu_mod = pcall(require, "mlbuddy.gpu")
  if ok then gpu_mod.stop_background() end
end

return M
