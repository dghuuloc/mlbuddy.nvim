--- mlbuddy/health.lua
--- :checkhealth mlbuddy  —  verifies all dependencies for every module.
local M = {}

local function h()
  return vim.health or require("health")
end

local function check_exe(name, purpose)
  if vim.fn.executable(name) == 1 then
    h().ok(name .. " ✓  (" .. purpose .. ")")
    return true
  else
    h().warn(name .. " not found  (" .. purpose .. ")")
    return false
  end
end

local function py_import(python, mod)
  local r = vim.system({ python, "-c", "import " .. mod .. "; print(" .. mod .. ".__version__)" },
    { text=true }):wait()
  if r.code == 0 then
    h().ok(mod .. " " .. (r.stdout:gsub("%s+$","")) .. " ✓")
    return true
  else
    h().warn(mod .. " not importable — some features disabled")
    return false
  end
end

function M.check()
  local hc = h()

  -- ── Neovim version ──────────────────────────────────────────────────────────
  hc.start("mlbuddy.nvim  — Core")
  local v = vim.version()
  if v.major > 0 or v.minor >= 10 then
    hc.ok(("Neovim %d.%d.%d ✓ (0.10+ required, 0.12 recommended)"):format(v.major, v.minor, v.patch))
  else
    hc.error("Neovim ≥ 0.10 required  (have " .. v.major.."."..v.minor.."."..v.patch..")")
  end

  -- vim.uv
  if vim.uv then
    hc.ok("vim.uv ✓  (async timers, fs operations)")
  else
    hc.warn("vim.uv not available — upgrade to Neovim 0.10+")
  end

  -- vim.system
  if vim.system then
    hc.ok("vim.system ✓  (async subprocess)")
  else
    hc.error("vim.system not available — most features will fail")
  end

  -- ── TorchView ───────────────────────────────────────────────────────────────
  hc.start("mlbuddy  — TorchView")
  local ts_ok = pcall(vim.treesitter.language.inspect, "python")
  if ts_ok then
    hc.ok("Treesitter Python parser ✓  (model architecture parsing)")
  else
    hc.warn("Treesitter Python parser not installed  — run :TSInstall python")
    hc.info("TorchView will still work but without virtual-text annotations")
  end

  -- ── MLflow ──────────────────────────────────────────────────────────────────
  hc.start("mlbuddy  — MLflow")
  local curl_ok = check_exe("curl", "MLflow REST API client")
  if not curl_ok then
    hc.error("MLflow module requires curl")
  end
  local mlflow_uri = vim.env.MLFLOW_TRACKING_URI or "http://localhost:5000"
  hc.info("Tracking URI: " .. mlflow_uri .. "  (set MLFLOW_TRACKING_URI to override)")

  -- ── Python + core ML libs ───────────────────────────────────────────────────
  hc.start("mlbuddy  — Python / ML Libraries")
  local python = require("mlbuddy.util").find_python()
  if vim.fn.executable(python) == 1 then
    local r = vim.system({ python, "--version" }, { text=true }):wait()
    hc.ok(python .. "  →  " .. (r.stdout:gsub("%s+$","") or "?"))
    py_import(python, "torch")
    py_import(python, "numpy")
    py_import(python, "transformers")
    py_import(python, "lightning")
    py_import(python, "accelerate")
    py_import(python, "datasets")
    py_import(python, "safetensors")
    py_import(python, "wandb")
    py_import(python, "IPython")
  else
    hc.error("Python not found  — DataLoader, Checkpoint, Dataset, Notebook modules disabled")
    hc.info("Install Python 3.8+ and set runner.python in config if needed")
  end

  -- ── GPU ─────────────────────────────────────────────────────────────────────
  hc.start("mlbuddy  — GPU Monitor")
  local nvidia_ok = check_exe("nvidia-smi", "NVIDIA GPU monitoring")
  local rocm_ok   = check_exe("rocm-smi",   "AMD ROCm GPU monitoring")
  if not nvidia_ok and not rocm_ok then
    hc.warn("Neither nvidia-smi nor rocm-smi found  — GPU monitor will show no data")
    hc.info("Set gpu.backend = 'mock' in config to use synthetic data for testing")
  else
    -- Quick GPU query
    local backend = nvidia_ok and "nvidia" or "rocm"
    local r = vim.system(
      nvidia_ok
        and { "nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader" }
        or  { "rocm-smi", "--showproductname" },
      { text=true }
    ):wait()
    if r.code == 0 then
      for line in r.stdout:gmatch("[^\n]+") do
        if line ~= "" then hc.ok("  " .. line) end
      end
    end
  end

  -- ── Runner ──────────────────────────────────────────────────────────────────
  hc.start("mlbuddy  — Runner / Training Launcher")
  hc.info("Python: " .. python)
  check_exe("torchrun",   "DDP / multi-GPU training")
  check_exe("accelerate", "HuggingFace Accelerate launcher")
  check_exe("deepspeed",  "DeepSpeed launcher")

  -- ── Checkpoint ──────────────────────────────────────────────────────────────
  hc.start("mlbuddy  — Checkpoint Manager")
  if vim.fn.executable(python) == 1 then
    py_import(python, "torch")
    local r2 = vim.system({ python, "-c",
      "from safetensors import safe_open; print('ok')" }, { text=true }):wait()
    if r2.code == 0 then
      hc.ok("safetensors ✓  (.safetensors checkpoint support)")
    else
      hc.info("safetensors not installed  — pip install safetensors")
    end
  end

  -- ── Notebook ────────────────────────────────────────────────────────────────
  hc.start("mlbuddy  — Notebook (# %% cell runner)")
  if vim.fn.executable(python) == 1 then
    local r3 = vim.system({ python, "-c",
      "import IPython; print(IPython.__version__)" }, { text=true }):wait()
    if r3.code == 0 then
      hc.ok("IPython " .. r3.stdout:gsub("%s","") .. " ✓  (cell kernel)")
    else
      hc.warn("IPython not installed  — pip install ipython")
    end
  end
  -- Image protocol for tensor/plot display
  local term = vim.env.TERM or ""
  local term_prog = vim.env.TERM_PROGRAM or ""
  if term == "xterm-kitty" then
    hc.ok("Kitty terminal ✓  (image display supported)")
  elseif term_prog == "iTerm.app" or term_prog == "iTerm2" then
    hc.ok("iTerm2 ✓  (image display via iTerm2 protocol)")
  else
    hc.info("Terminal: " .. term .. "  — image display may be limited")
  end

  -- ── DAP integration ──────────────────────────────────────────────────────────
  hc.start("mlbuddy  — DAP Integration (DataLoader auto-inspect)")
  if package.loaded["dap"] or pcall(require, "dap") then
    hc.ok("nvim-dap ✓  (auto tensor inspection at breakpoints)")
    local ok_py, _ = pcall(require, "dap-python")
    if ok_py then
      hc.ok("nvim-dap-python ✓")
    else
      hc.info("nvim-dap-python not loaded  (optional)")
    end
  else
    hc.info("nvim-dap not installed  — manual tensor inspection still works via <leader>mt")
    hc.info("Install nvim-dap for breakpoint-triggered auto-inspection")
  end

  -- ── W&B ─────────────────────────────────────────────────────────────────────
  hc.start("mlbuddy  — Weights & Biases")
  local wandb_key = vim.env.WANDB_API_KEY
  if wandb_key and wandb_key ~= "" then
    hc.ok("WANDB_API_KEY set ✓  (length: " .. #wandb_key .. ")")
  else
    hc.warn("WANDB_API_KEY not set  — set it in your shell or .env")
    hc.info("W&B module works read-only without a key for public projects")
  end
  check_exe("curl", "W&B REST API")

  -- ── Summary ─────────────────────────────────────────────────────────────────
  hc.start("mlbuddy  — Summary")
  local modules = {
    "torchview", "mlflow", "dataloader", "trainer", "gpu",
    "runner", "checkpoint", "notebook", "dataset", "profiler",
    "env", "wandb", "statusline",
  }
  for _, mod in ipairs(modules) do
    local ok, _ = pcall(require, "mlbuddy." .. mod)
    if ok then
      hc.ok("mlbuddy." .. mod .. " loaded ✓")
    else
      hc.error("mlbuddy." .. mod .. " failed to load")
    end
  end
end

return M
