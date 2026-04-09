--- mlbuddy/runner/init.lua
--- Detects training framework and builds the correct launch command.
--- Supports: plain torch, Lightning, HuggingFace Trainer, Accelerate, torchrun, DDP.
local ui      = require("mlbuddy.ui")
local util    = require("mlbuddy.util")
local trainer = require("mlbuddy.trainer")
local M       = {}

-- ── Framework detection ───────────────────────────────────────────────────────

---@class FrameworkInfo
---@field name        string   "lightning"|"huggingface"|"accelerate"|"torchrun"|"plain"
---@field description string
---@field launcher    fun(script:string, args:string[], python:string, cfg:table) → string[]

local FRAMEWORKS = {}

-- 1. PyTorch Lightning
FRAMEWORKS[#FRAMEWORKS+1] = {
  name = "lightning",
  detect = function(script_path)
    local content = vim.fn.join(vim.fn.readfile(script_path, "", 50), "\n")
    return content:match("from lightning") or content:match("import lightning")
        or content:match("pl%.Trainer") or content:match("L%.Trainer")
  end,
  launcher = function(script, args, python, cfg)
    local cmd = { python, script }
    vim.list_extend(cmd, args)
    return cmd
  end,
  description = "PyTorch Lightning (detected from imports)",
}

-- 2. HuggingFace Trainer
FRAMEWORKS[#FRAMEWORKS+1] = {
  name = "huggingface",
  detect = function(script_path)
    local content = vim.fn.join(vim.fn.readfile(script_path, "", 50), "\n")
    return content:match("from transformers") or content:match("Trainer%(")
        or content:match("TrainingArguments")
  end,
  launcher = function(script, args, python, cfg)
    local cmd = { python, script }
    vim.list_extend(cmd, args)
    return cmd
  end,
  description = "HuggingFace Transformers Trainer",
}

-- 3. Accelerate
FRAMEWORKS[#FRAMEWORKS+1] = {
  name = "accelerate",
  detect = function(script_path)
    local content = vim.fn.join(vim.fn.readfile(script_path, "", 50), "\n")
    return content:match("from accelerate") or content:match("Accelerator%(")
  end,
  launcher = function(script, args, python, cfg)
    local acc = vim.fn.exepath("accelerate")
    if acc == "" then
      -- fallback
      return vim.list_extend({ python, script }, args)
    end
    local cmd = { acc, "launch" }
    vim.list_extend(cmd, cfg.runner.accelerate_args or {})
    cmd[#cmd+1] = script
    vim.list_extend(cmd, args)
    return cmd
  end,
  description = "HuggingFace Accelerate",
}

-- 4. torchrun (DDP / multi-GPU)
FRAMEWORKS[#FRAMEWORKS+1] = {
  name = "torchrun",
  detect = function(script_path)
    local content = vim.fn.join(vim.fn.readfile(script_path, "", 50), "\n")
    return content:match("dist%.init_process_group") or content:match("LOCAL_RANK")
        or content:match("torch%.distributed")
  end,
  launcher = function(script, args, python, cfg)
    local torchrun = vim.fn.exepath("torchrun")
    if torchrun == "" then
      -- python -m torch.distributed.run
      local cmd = { python, "-m", "torch.distributed.run" }
      vim.list_extend(cmd, cfg.runner.torchrun_args or {})
      cmd[#cmd+1] = script
      vim.list_extend(cmd, args)
      return cmd
    end
    local cmd = { torchrun }
    vim.list_extend(cmd, cfg.runner.torchrun_args or {})
    cmd[#cmd+1] = script
    vim.list_extend(cmd, args)
    return cmd
  end,
  description = "torchrun (DDP / multi-GPU)",
}

-- 5. Plain Python fallback
FRAMEWORKS[#FRAMEWORKS+1] = {
  name = "plain",
  detect = function(_) return true end,  -- always matches
  launcher = function(script, args, python, _)
    local cmd = { python, script }
    vim.list_extend(cmd, args)
    return cmd
  end,
  description = "Plain Python script",
}

-- ── Detect framework ──────────────────────────────────────────────────────────

---@param script_path string
---@return FrameworkInfo
function M.detect(script_path)
  for _, fw in ipairs(FRAMEWORKS) do
    if fw.detect(script_path) then return fw end
  end
  return FRAMEWORKS[#FRAMEWORKS]  -- plain
end

-- ── Build command ─────────────────────────────────────────────────────────────

---@param script string
---@param args   string[]
---@param cfg    table
---@return string[], FrameworkInfo
function M.build_cmd(script, args, cfg)
  local python = cfg.runner.python or util.find_python()
  local fw     = M.detect(script)
  local cmd    = fw.launcher(script, args, python, cfg)
  return cmd, fw
end

-- ── Run in terminal split ─────────────────────────────────────────────────────

---@param script string
---@param args   string[]|nil
---@param cfg    table
function M.run_terminal(script, args, cfg)
  args = args or {}
  local cmd, fw = M.build_cmd(script, args, cfg)
  ui.info(string.format("Running %s via %s", script, fw.description))

  ui.terminal_split(cmd, {
    direction = cfg.runner.split_direction or "right",
    size      = cfg.runner.split_size      or 55,
    title     = vim.fn.fnamemodify(script, ":t"),
  })
end

-- ── Run with trainer monitor ──────────────────────────────────────────────────

---@param script string
---@param args   string[]|nil
---@param cfg    table
function M.run_with_monitor(script, args, cfg)
  args = args or {}
  local cmd, fw = M.build_cmd(script, args, cfg)
  ui.info(string.format("Launching monitor for %s via %s", script, fw.description))
  trainer.launch(cmd, cfg)
end

-- ── Toggle / interactive launcher ────────────────────────────────────────────

local _last_script = nil

---@param cfg table
function M.toggle(cfg)
  -- If no script selected, prompt
  local script = _last_script or vim.fn.expand("%:p")
  if not script:match("%.py$") then
    vim.ui.input({ prompt = "Training script: ", default = "" }, function(s)
      if s and s ~= "" then
        _last_script = s
        M._launch_ui(s, cfg)
      end
    end)
    return
  end
  M._launch_ui(script, cfg)
end

function M._launch_ui(script, cfg)
  _last_script = script
  local fw = M.detect(script)

  vim.ui.select(
    { "Launch with Training Monitor", "Launch in Terminal Split", "Cancel" },
    { prompt = "Run " .. vim.fn.fnamemodify(script, ":t") .. " [" .. fw.name .. "]:" },
    function(choice)
      if not choice or choice == "Cancel" then return end
      vim.ui.input(
        { prompt = "Extra args (space-separated): ", default = "" },
        function(arg_str)
          local args = arg_str and vim.split(arg_str, "%s+") or {}
          if choice:match("Monitor") then
            M.run_with_monitor(script, args, cfg)
          else
            M.run_terminal(script, args, cfg)
          end
        end
      )
    end
  )
end

--- Quick run: run the current file with monitor (no prompts).
---@param cfg table
function M.run(cfg)
  local script = vim.fn.expand("%:p")
  if not script:match("%.py$") then
    ui.warn("Current buffer is not a Python file")
    return
  end
  M.run_with_monitor(script, {}, cfg)
end

--- Stop the last terminal job.
function M.stop()
  vim.cmd("bdelete!")
end

return M
