--- mlbuddy/health.lua
--- :checkhealth mlbuddy  —  verifies all dependencies for every module.
local M = {}

local function h()
  return vim.health or require("health")
end

local function check_exe(name, purpose)
  -- Use platform-aware find_exe so .exe/.cmd/.bat are found on Windows
  local plat = require("mlbuddy.platform")
  local found = plat.find_exe(name)
  if found then
    h().ok(name .. " ✓  (" .. purpose .. ")  →  " .. found)
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
  local hc   = h()
  local plat = require("mlbuddy.platform")

  -- ── Platform ──────────────────────────────────────────────────────────────
  hc.start("mlbuddy.nvim  — Platform")
  local os_name = plat.is_win and "Windows" or (plat.is_mac and "macOS" or "Linux")
  hc.ok("OS: " .. os_name)
  hc.ok("Platform info: " .. plat.info_str())
  if plat.is_win then
    hc.info("Windows mode: Scripts\\ paths, cmd.exe wrapping, CRLF stripping all enabled")
    -- Check Windows Terminal for best experience
    if vim.env.WT_SESSION then
      hc.ok("Windows Terminal ✓  (best Neovim terminal experience)")
    else
      hc.info("Windows Terminal not detected  — recommended for best rendering")
    end
    -- Check if running inside WSL
    if vim.env.WSL_DISTRO_NAME then
      hc.info("WSL detected (" .. vim.env.WSL_DISTRO_NAME .. ") — Linux paths are available")
    end
  end

  -- ── Neovim core ────────────────────────────────────────────────────────────
  hc.start("mlbuddy.nvim  — Neovim Core")
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
  local smi      = plat.find_nvidia_smi()
  local rocm_smi = plat.find_rocm_smi()
  local nvidia_ok = smi ~= nil
  local rocm_ok   = rocm_smi ~= nil
  if nvidia_ok then
    hc.ok("nvidia-smi ✓  →  " .. smi)
  else
    hc.warn("nvidia-smi not found")
    if plat.is_win then
      hc.info("Windows: ensure NVIDIA drivers are installed; nvidia-smi.exe is usually at")
      hc.info("  C:\\Program Files\\NVIDIA Corporation\\NVSMI\\nvidia-smi.exe")
    end
  end
  if rocm_ok then
    hc.ok("rocm-smi ✓  →  " .. rocm_smi)
  elseif not plat.is_win then
    hc.info("rocm-smi not found  (only needed for AMD GPUs on Linux)")
  end
  if not nvidia_ok and not rocm_ok then
    hc.info("Set gpu.backend = 'mock' in config to test the GPU panel without hardware")
  else
    local smi_cmd = smi or rocm_smi
    local r = vim.system(
      smi and { smi, "--query-gpu=name,memory.total", "--format=csv,noheader" }
          or  { rocm_smi, "--showproductname" },
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

  -- ── Quarto ─────────────────────────────────────────────────────────────────
  hc.start("mlbuddy  — Quarto Integration")
  local quarto_cli = plat.find_exe("quarto")
  if quarto_cli then
    local r_q = vim.system({ quarto_cli, "--version" }, { text=true }):wait()
    hc.ok("quarto CLI ✓  →  " .. quarto_cli
      .. "  v" .. (r_q.stdout:gsub("%s+","") or "?"))
  else
    hc.warn("quarto CLI not found  — install from https://quarto.org/docs/get-started/")
    hc.info(":MlbuddyQuartoPreview and :MlbuddyQuartoRender will not work without it")
  end
  local ok_qnvim = pcall(require, "quarto")
  if ok_qnvim then
    hc.ok("quarto-nvim ✓  (codeRunner integration active)")
  else
    hc.info("quarto-nvim not installed  — mlbuddy will use its own IPython kernel for .qmd")
    hc.info("To install: add { 'quarto-dev/quarto-nvim' } to your plugin list")
  end
  local py_for_qmd = require("mlbuddy.util").find_python()
  if vim.fn.executable(py_for_qmd) == 1 then
    local r_nb = vim.system({ py_for_qmd, "-c",
      "import nbformat; print(nbformat.__version__)" }, { text=true }):wait()
    if r_nb.code == 0 then
      hc.ok("nbformat " .. r_nb.stdout:gsub("%s","") .. " ✓")
    else
      hc.info("nbformat not installed (optional)  — pip install nbformat")
    end
  end

  -- ── Summary ─────────────────────────────────────────────────────────────────
  hc.start("mlbuddy  — Summary")
  local modules = {
    "platform", "torchview", "mlflow", "dataloader", "trainer", "gpu",
    "runner", "checkpoint", "notebook", "dataset", "profiler",
    "env", "wandb", "statusline", "debugger", "quarto",
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
