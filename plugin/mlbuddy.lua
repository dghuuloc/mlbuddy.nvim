-- plugin/mlbuddy.lua
-- Loaded automatically by Neovim via runtimepath.
-- Registers all :Mlbuddy* user commands and :checkhealth mlbuddy.
-- Actual initialization happens lazily on first M.setup() call.

if vim.g.mlbuddy_loaded then return end
vim.g.mlbuddy_loaded = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("[mlbuddy] Neovim ≥ 0.10 required", vim.log.levels.ERROR)
  return
end

local function m() return require("mlbuddy") end
local function cfg() return m()._cfg or require("mlbuddy.config").defaults end

-- ── Core panels ──────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("MlbuddyTorchView",
  function() m().torchview() end,
  { desc = "mlbuddy: toggle TorchView model architecture inspector" })

vim.api.nvim_create_user_command("MlbuddyMLflow",
  function() m().mlflow() end,
  { desc = "mlbuddy: toggle MLflow experiment tracker" })

vim.api.nvim_create_user_command("MlbuddyDataLoader",
  function() m().dataloader() end,
  { desc = "mlbuddy: toggle DataLoader tensor inspector" })

vim.api.nvim_create_user_command("MlbuddyInspect",
  function() m().inspect_tensor() end,
  { desc = "mlbuddy: inspect tensor / variable under cursor" })

-- ── Trainer ───────────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("MlbuddyTrainer",
  function() m().trainer() end,
  { desc = "mlbuddy: toggle Training Monitor dashboard" })

vim.api.nvim_create_user_command("MlbuddyRun",
  function(opts)
    local args = opts.args and opts.args ~= "" and vim.split(opts.args, "%s+") or nil
    local script = vim.fn.expand("%:p")
    if args and args[1] and args[1]:match("%.py$") then
      script = args[1]
      table.remove(args, 1)
    end
    require("mlbuddy.runner").run_with_monitor(script, args or {}, cfg())
  end,
  { nargs="*", complete="file", desc = "mlbuddy: run script with training monitor" })

vim.api.nvim_create_user_command("MlbuddyRunTerminal",
  function(opts)
    local args   = opts.args ~= "" and vim.split(opts.args, "%s+") or {}
    local script = vim.fn.expand("%:p")
    if args[1] and args[1]:match("%.py$") then script = args[1]; table.remove(args, 1) end
    require("mlbuddy.runner").run_terminal(script, args, cfg())
  end,
  { nargs="*", complete="file", desc = "mlbuddy: run script in terminal split" })

-- ── GPU ───────────────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("MlbuddyGpu",
  function() m().gpu() end,
  { desc = "mlbuddy: toggle GPU monitor (nvidia/rocm)" })

-- ── Checkpoint ────────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("MlbuddyCheckpoint",
  function() m().checkpoint() end,
  { desc = "mlbuddy: toggle Checkpoint manager" })

-- ── Notebook ──────────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("MlbuddyNotebook",
  function() m().notebook_run() end,
  { desc = "mlbuddy: run # %% cell under cursor" })

vim.api.nvim_create_user_command("MlbuddyNotebookAll",
  function() m().notebook_run_all() end,
  { desc = "mlbuddy: run all # %% cells" })

vim.api.nvim_create_user_command("MlbuddyKernel",
  function(opts)
    local sub = opts.args
    if sub == "restart" then m().notebook_restart()
    elseif sub == "interrupt" then m().notebook_interrupt()
    else
      vim.notify("[mlbuddy] :MlbuddyKernel restart|interrupt", vim.log.levels.INFO)
    end
  end,
  { nargs="?", desc = "mlbuddy: kernel management (restart|interrupt)" })

-- ── Dataset ───────────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("MlbuddyDataset",
  function() m().dataset() end,
  { desc = "mlbuddy: toggle Dataset explorer" })

-- ── Profiler ──────────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("MlbuddyProfiler",
  function(opts)
    m().profiler_load(opts.args ~= "" and opts.args or nil)
  end,
  { nargs="?", complete="file", desc = "mlbuddy: load + view PyTorch profiler trace" })

-- ── Environment ───────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("MlbuddyEnv",
  function() m().env() end,
  { desc = "mlbuddy: toggle Python environment manager" })

-- ── W&B ───────────────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("MlbuddyWandB",
  function() m().wandb() end,
  { desc = "mlbuddy: toggle Weights & Biases run browser" })

-- ── Multi-panel ───────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("MlbuddyDashboard",
  function() m().dashboard() end,
  { desc = "mlbuddy: open TorchView + Trainer + GPU side by side" })

-- ── Health ────────────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("MlbuddyHealth",
  function() m().health() end,
  { desc = "mlbuddy: run dependency health check" })

-- :checkhealth mlbuddy provider
vim.api.nvim_create_autocmd("User", {
  pattern  = "CheckHealth",
  callback = function() require("mlbuddy.health").check() end,
})
