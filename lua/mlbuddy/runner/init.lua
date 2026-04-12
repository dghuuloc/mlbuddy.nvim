--- mlbuddy/runner/init.lua  (cross-platform)
--- Detects training framework and builds the correct launch command.
--- Fully cross-platform: Windows .exe/.cmd/.bat detection, cmd.exe wrapping.
local ui      = require("mlbuddy.ui")
local util    = require("mlbuddy.util")
local plat    = require("mlbuddy.platform")
local trainer = require("mlbuddy.trainer")
local M       = {}

local function find_exe(name) return plat.find_exe(name) end

local FRAMEWORKS = {}

FRAMEWORKS[#FRAMEWORKS+1] = {
  name = "lightning",
  detect = function(p)
    local ok, lines = pcall(vim.fn.readfile, p, "", 60)
    if not ok then return false end
    local c = table.concat(lines, "\n")
    return c:match("from lightning") or c:match("import lightning")
        or c:match("pl%.Trainer")   or c:match("L%.Trainer")
  end,
  launcher = function(s, a, py, _) local c={py,s}; vim.list_extend(c,a); return c end,
  description = "PyTorch Lightning",
}

FRAMEWORKS[#FRAMEWORKS+1] = {
  name = "huggingface",
  detect = function(p)
    local ok, lines = pcall(vim.fn.readfile, p, "", 60)
    if not ok then return false end
    local c = table.concat(lines, "\n")
    return c:match("from transformers") or c:match("Trainer%(") or c:match("TrainingArguments")
  end,
  launcher = function(s, a, py, _) local c={py,s}; vim.list_extend(c,a); return c end,
  description = "HuggingFace Transformers Trainer",
}

FRAMEWORKS[#FRAMEWORKS+1] = {
  name = "accelerate",
  detect = function(p)
    local ok, lines = pcall(vim.fn.readfile, p, "", 60)
    if not ok then return false end
    local c = table.concat(lines, "\n")
    return c:match("from accelerate") or c:match("Accelerator%(")
  end,
  launcher = function(script, args, python, cfg)
    local acc = find_exe("accelerate")
    local cmd = acc and { acc, "launch" }
             or { python, "-m", "accelerate.commands.launch" }
    vim.list_extend(cmd, cfg.runner.accelerate_args or {})
    cmd[#cmd+1] = script
    vim.list_extend(cmd, args)
    return cmd
  end,
  description = "HuggingFace Accelerate",
}

FRAMEWORKS[#FRAMEWORKS+1] = {
  name = "torchrun",
  detect = function(p)
    local ok, lines = pcall(vim.fn.readfile, p, "", 60)
    if not ok then return false end
    local c = table.concat(lines, "\n")
    return c:match("dist%.init_process_group") or c:match("LOCAL_RANK")
        or c:match("torch%.distributed")
  end,
  launcher = function(script, args, python, cfg)
    local tr  = find_exe("torchrun")
    local cmd = tr and { tr }
             or { python, "-m", "torch.distributed.run" }
    vim.list_extend(cmd, cfg.runner.torchrun_args or {})
    cmd[#cmd+1] = script
    vim.list_extend(cmd, args)
    return cmd
  end,
  description = "torchrun / DDP multi-GPU",
}

FRAMEWORKS[#FRAMEWORKS+1] = {
  name = "plain",
  detect = function(_) return true end,
  launcher = function(s, a, py, _) local c={py,s}; vim.list_extend(c,a); return c end,
  description = "Plain Python",
}

function M.detect(script_path)
  for _, fw in ipairs(FRAMEWORKS) do
    local ok, r = pcall(fw.detect, script_path)
    if ok and r then return fw end
  end
  return FRAMEWORKS[#FRAMEWORKS]
end

function M.build_cmd(script, args, cfg)
  local python = cfg.runner.python or plat.find_python()
  local fw     = M.detect(script)
  return fw.launcher(script, args, python, cfg), fw
end

function M.run_terminal(script, args, cfg)
  args = args or {}
  local cmd, fw = M.build_cmd(script, args, cfg)
  ui.info(("Running %s via %s"):format(vim.fn.fnamemodify(script,":t"), fw.description))
  ui.terminal_split(cmd, {
    direction = cfg.runner.split_direction or "right",
    size      = cfg.runner.split_size      or 55,
    title     = vim.fn.fnamemodify(script, ":t"),
  })
end

function M.run_with_monitor(script, args, cfg)
  args = args or {}
  local cmd, fw = M.build_cmd(script, args, cfg)
  ui.info(("Launching monitor for %s via %s"):format(vim.fn.fnamemodify(script,":t"), fw.description))
  trainer.launch(cmd, cfg)
end

local _last_script = nil

function M.toggle(cfg)
  local script = _last_script or vim.fn.expand("%:p")
  if not script:match("%.py$") then
    vim.ui.input({ prompt = "Training script: ", default = "" }, function(s)
      if s and s ~= "" then _last_script = s; M._launch_ui(s, cfg) end
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
    { prompt = "Run " .. vim.fn.fnamemodify(script,":t") .. " [" .. fw.name .. "]:" },
    function(choice)
      if not choice or choice == "Cancel" then return end
      vim.ui.input({ prompt = "Extra args: ", default = "" }, function(arg_str)
        local args = arg_str and arg_str ~= "" and vim.split(arg_str, "%s+") or {}
        if choice:match("Monitor") then M.run_with_monitor(script, args, cfg)
        else M.run_terminal(script, args, cfg) end
      end)
    end)
end

function M.run(cfg)
  local script = vim.fn.expand("%:p")
  if not script:match("%.py$") then ui.warn("Not a Python file"); return end
  M.run_with_monitor(script, {}, cfg)
end

function M.stop() vim.cmd("bdelete!") end

return M
