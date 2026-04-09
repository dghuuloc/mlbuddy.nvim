# mlbuddy.nvim — Enterprise ML/DL Plugin for Neovim 0.12

A comprehensive, production-quality Neovim companion for PyTorch machine learning development. 13 independent modules covering the complete ML research and production workflow.

---

## Modules at a glance

| # | Module | Command | Key | What it does |
|---|--------|---------|-----|--------------|
| 1 | **TorchView** | `:MlbuddyTorchView` | `<leader>mv` | Model architecture inspector with Treesitter parsing and inline param-count virtual text |
| 2 | **MLflow** | `:MlbuddyMLflow` | `<leader>me` | Live experiment tracker: run table, ASCII sparklines, detail view, auto-refresh |
| 3 | **DataLoader** | `:MlbuddyDataLoader` | `<leader>md` | Tensor inspector: heatmap, stats, NaN/Inf detection, DAP integration |
| 4 | **Trainer** | `:MlbuddyRun` | `<leader>mT` | Live training dashboard: 2-D ASCII charts, ETA, multi-job, stdout parsing |
| 5 | **GPU** | `:MlbuddyGpu` | `<leader>mG` | Real-time GPU monitor: nvidia-smi/rocm-smi, VRAM bars, alerts, statusline |
| 6 | **Runner** | `:MlbuddyRun` | `<leader>mr` | Smart launcher: auto-detects Lightning/HF/Accelerate/torchrun |
| 7 | **Checkpoint** | `:MlbuddyCheckpoint` | `<leader>mC` | Checkpoint browser: scan, inspect metadata, delete, resume |
| 8 | **Notebook** | `:MlbuddyNotebook` | `<leader>mn` | Jupyter-free cell runner: `# %%` cells → IPython kernel → virtual output |
| 9 | **Dataset** | `:MlbuddyDataset` | `<leader>mD` | Dataset explorer: HuggingFace/torch/numpy introspection from cursor |
| 10 | **Profiler** | `:MlbuddyProfiler` | `<leader>mP` | PyTorch profiler viewer: chrome trace JSON, top-N ops, flame bars |
| 11 | **Env** | `:MlbuddyEnv` | `<leader>mE` | Environment manager: venv/conda/poetry/pyenv, package list, activation |
| 12 | **W&B** | `:MlbuddyWandB` | `<leader>mw` | Weights & Biases run browser with sparklines and auto-refresh |
| 13 | **Statusline** | — | — | Components for lualine/heirline/raw: GPU%, env name, active job |

---

## Requirements

| Dependency | Required for |
|---|---|
| Neovim ≥ 0.10 | Core (`vim.system`, `vim.uv`) |
| Neovim 0.12 | Full `vim.uv`, `virt_lines`, `ui2` |
| Treesitter Python parser | TorchView parsing |
| `curl` | MLflow, W&B REST clients |
| Python 3.8+ | DataLoader, Checkpoint, Dataset, Notebook |
| `torch` | Most Python-side features |
| `numpy` | NumPy tensor inspection |
| `nvidia-smi` / `rocm-smi` | GPU monitor |
| `torchrun` / `accelerate` | Multi-GPU training |
| `IPython` | Notebook cell kernel |
| `safetensors` (pip) | `.safetensors` checkpoint reading |
| `nvim-dap` | Auto tensor inspection at breakpoints |
| `WANDB_API_KEY` | W&B integration |

Run `:checkhealth mlbuddy` to verify.

---

## Installation

### lazy.nvim

```lua
{
  "yourusername/mlbuddy.nvim",
  ft        = "python",
  config    = function()
    require("mlbuddy").setup({
      -- all keys optional; see Configuration below
    })
  end,
}
```

### Minimal setup

```lua
require("mlbuddy").setup()
```

### Full example

```lua
require("mlbuddy").setup({
  border = "rounded",
  width  = 88,

  mlflow = {
    tracking_uri = vim.env.MLFLOW_TRACKING_URI or "http://localhost:5000",
  },

  trainer = {
    chart_series  = { "loss", "val_loss", "acc", "val_acc", "lr" },
    smooth_window = 10,
  },

  gpu = {
    backend          = "auto",      -- or "mock" for testing
    refresh_interval = 1000,
    alert_vram_pct   = 85,
    alert_temp_c     = 82,
  },

  runner = {
    python          = nil,          -- auto-detect .venv / conda / system
    split_direction = "right",
    torchrun_args   = { "--nproc_per_node=2" },
  },

  checkpoint = {
    scan_roots = { ".", "checkpoints", "outputs", "lightning_logs" },
    deep_scan  = true,
  },

  notebook = {
    output_height = 20,
  },

  wandb = {
    entity  = "myteam",
    project = "gpt4-finetune",
  },

  statusline = {
    update_ms = 1000,
  },
})
```

---

## Lualine integration

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      require("mlbuddy").lualine_gpu(),   -- 󰊗 GPU0 71% 14.1GiB 67°C
      require("mlbuddy").lualine_env(),   -- 󰏗 .venv
      require("mlbuddy").lualine_job(),   -- ⠙ training step 1240
    },
  },
})
```

---

## Heirline integration

```lua
local MlbuddyStatus = require("mlbuddy").heirline_component()
-- add to your heirline StatusLine definition
```

---

## Workflow examples

### Train and monitor

```
:MlbuddyRun train.py --lr 1e-3 --epochs 100
```

Or from Lua:
```lua
require("mlbuddy").train({ "python", "train.py", "--lr", "1e-3" })
```

### Jupyter-style cells without Jupyter

```python
# %% Imports
import torch
import torch.nn as nn

# %% Model
model = nn.Linear(128, 10)
print(model)

# %% Train
for epoch in range(10):
    loss = criterion(model(x), y)
    ...
```

Press `<leader>mn` to run the cell under the cursor. Output appears as virtual text below.

### Inspect a tensor at a breakpoint

1. Set a breakpoint with nvim-dap (`<leader>db`)
2. Run with `:MlbuddyRun`
3. When stopped, position cursor on `x` → `<leader>mt`
4. The DataLoader panel opens with shape, dtype, heatmap, stats

### View GPU memory before/during training

```
:MlbuddyGpu
```

Real-time VRAM bars, temperature, power draw, sparkline history.

### Browse checkpoints

```
:MlbuddyCheckpoint
```

Scans `./checkpoints`, `./outputs`, etc. Press `<CR>` to inspect epoch/step/loss/params.

### View a profiler trace

```python
with torch.profiler.profile(...) as p:
    model(x)
p.export_chrome_trace("trace.json")
```

```
:MlbuddyProfiler trace.json
```

---

## Architecture

```
mlbuddy.nvim/
├── lua/mlbuddy/
│   ├── init.lua              ← setup(), all public API
│   ├── config.lua            ← complete defaults for all 13 modules
│   ├── ui.lua                ← floats, TabPanel, terminal splits, spinner, highlights
│   ├── util.lua              ← chart2d engine, sparkline, heatmap, async http, timers
│   ├── health.lua            ← :checkhealth mlbuddy
│   │
│   ├── torchview/            ← Treesitter model parser + virtual text
│   │   ├── parser.lua        25+ layer types, nested blocks, kwargs
│   │   ├── renderer.lua      param bars, tree connectors, float
│   │   └── init.lua          toggle, autocmds, virt text attachment
│   │
│   ├── mlflow/               ← MLflow REST API v2
│   │   ├── client.lua        curl/vim.system async HTTP
│   │   ├── renderer.lua      run table, sparklines, redraw
│   │   └── init.lua          toggle, timer, experiment cycle, detail view
│   │
│   ├── dataloader/           ← Tensor inspector
│   │   ├── renderer.lua      heatmap, stats table, sparkline distribution
│   │   └── init.lua          cursor inspect, DAP hooks, rotate history
│   │
│   ├── trainer/              ← Live training monitor
│   │   ├── parser.lua        Lightning/HF/tqdm/JSON/kv stdout parsers
│   │   ├── renderer.lua      2-D ASCII chart, progress bar, metrics table
│   │   └── init.lua          multi-job registry, jobstart capture, timer
│   │
│   ├── gpu/                  ← GPU monitor
│   │   ├── nvidia.lua        nvidia-smi + rocm-smi parsers, GpuInfo struct
│   │   └── init.lua          renderer, toggle, statusline(), background poll
│   │
│   ├── runner/               ← Training launcher
│   │   └── init.lua          5-framework detector, build_cmd, terminal/monitor modes
│   │
│   ├── checkpoint/           ← Checkpoint manager
│   │   └── init.lua          scan, Python inspector, list+detail views, delete/resume
│   │
│   ├── notebook/             ← # %% cell runner
│   │   └── init.lua          cell detection, IPython kernel, virt_lines output, signs
│   │
│   ├── dataset/              ← Dataset explorer
│   │   └── init.lua          HF/torch/numpy Python inspector, sample display
│   │
│   ├── profiler/             ← PyTorch profiler viewer
│   │   └── init.lua          chrome trace JSON parser, top-N table, sort
│   │
│   ├── env/                  ← Environment manager
│   │   └── init.lua          detect venv/conda/poetry/pyenv, pkg list, activate
│   │
│   ├── wandb/                ← W&B integration
│   │   └── init.lua          REST client, run table, sparklines, auto-refresh
│   │
│   └── statusline/           ← Statusline components
│       └── init.lua          lualine/heirline/raw, GPU/env/job strings
│
├── plugin/
│   └── mlbuddy.lua           ← all :Mlbuddy* commands, checkhealth provider
├── ftplugin/
│   └── python.lua            ← buffer-local keymaps, %% insert shortcut, cell signs
└── doc/
    └── mlbuddy.txt           ← :help mlbuddy
```

---

## Commands reference

| Command | Description |
|---|---|
| `:MlbuddyTorchView` | Toggle model architecture panel |
| `:MlbuddyMLflow` | Toggle MLflow tracker |
| `:MlbuddyDataLoader` | Toggle tensor inspector |
| `:MlbuddyInspect` | Inspect expression under cursor |
| `:MlbuddyTrainer` | Toggle training dashboard |
| `:MlbuddyRun [file] [args]` | Run with Training Monitor |
| `:MlbuddyRunTerminal [file]` | Run in terminal split |
| `:MlbuddyGpu` | Toggle GPU monitor |
| `:MlbuddyCheckpoint` | Toggle checkpoint browser |
| `:MlbuddyNotebook` | Run cell under cursor |
| `:MlbuddyNotebookAll` | Run all cells |
| `:MlbuddyKernel restart\|interrupt` | Kernel management |
| `:MlbuddyDataset` | Toggle dataset explorer |
| `:MlbuddyProfiler [path]` | Load + view profiler trace |
| `:MlbuddyEnv` | Toggle environment manager |
| `:MlbuddyWandB` | Toggle W&B run browser |
| `:MlbuddyDashboard` | Open TorchView + Trainer + GPU tiled |
| `:MlbuddyHealth` | Run dependency health check |
| `:checkhealth mlbuddy` | Standard Neovim health check |

---

## License

MIT
