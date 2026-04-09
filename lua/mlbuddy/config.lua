--- mlbuddy/config.lua  ── Enterprise defaults
local M = {}

M.defaults = {
  -- ── Global ──────────────────────────────────────────────────────────────
  border        = "rounded",
  width         = 84,
  height        = 40,
  tab_width     = 84,   -- unified tab-panel width
  log_level     = vim.log.levels.INFO,

  icons = {
    module   = "󰊠", layer    = "󱓿", param    = "󰒻",
    run      = "󰓄", metric   = "󰄵", tensor   = "󱄽",
    nan      = "󰅙", ok       = "󰄬", warn     = "󰀦", error    = "󰅚",
    gpu      = "󰊗", vram     = "󰍛", temp     = "󰔅", util     = "󰓿",
    ckpt     = "󰆓", dataset  = "󰙬", notebook = "󰠮", profiler = "󰅱",
    env      = "󰢱", train    = "󱘖", runner   = "󰐊", wandb    = "󰒊",
    spinner  = { "⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏" },
    progress = { "▏","▎","▍","▌","▋","▊","▉","█" },
  },

  -- ── TorchView ────────────────────────────────────────────────────────────
  torchview = {
    enabled      = true,
    virtual_text = true,
    auto_attach  = true,
    show_params  = true,
    show_shapes  = true,
    show_grad    = true,
    keymaps      = { toggle = "<leader>mv", close = "q" },
  },

  -- ── MLflow ───────────────────────────────────────────────────────────────
  mlflow = {
    enabled          = true,
    tracking_uri     = vim.env.MLFLOW_TRACKING_URI or "http://localhost:5000",
    refresh_interval = 5000,
    max_runs         = 25,
    sparkline_width  = 20,
    keymaps          = { toggle = "<leader>me", refresh = "R", select = "<CR>", close = "q" },
  },

  -- ── DataLoader ───────────────────────────────────────────────────────────
  dataloader = {
    enabled      = true,
    auto_inspect = true,
    heatmap_cols = 32,
    heatmap_rows = 8,
    precision    = 4,
    keymaps      = { toggle = "<leader>md", inspect_word = "<leader>mt", close = "q" },
  },

  -- ── Trainer ──────────────────────────────────────────────────────────────
  trainer = {
    enabled          = true,
    chart_width      = 60,
    chart_height     = 16,
    chart_series     = { "loss", "val_loss", "acc", "val_acc" },   -- tracked metrics
    max_history      = 2000,   -- max data points per metric
    smooth_window    = 5,      -- EMA smoothing window for chart
    show_lr          = true,
    show_eta         = true,
    show_gpu         = true,
    -- Metric parsers: patterns to detect key=value or key: value in stdout
    extra_patterns   = {},     -- user-defined { pattern, key_group, val_group }
    keymaps = {
      toggle        = "<leader>mT",
      close         = "q",
      pause_resume  = "p",
      cycle_metric  = "<Tab>",
      kill          = "K",
    },
  },

  -- ── GPU Monitor ──────────────────────────────────────────────────────────
  gpu = {
    enabled          = true,
    backend          = "auto",   -- "auto" | "nvidia" | "rocm" | "mock"
    refresh_interval = 1000,
    alert_vram_pct   = 90,       -- warn when VRAM > N%
    alert_temp_c     = 85,       -- warn when temp > N°C
    statusline       = true,
    keymaps          = { toggle = "<leader>mG", close = "q" },
  },

  -- ── Runner ───────────────────────────────────────────────────────────────
  runner = {
    enabled         = true,
    python          = nil,        -- nil = auto-detect (.venv, conda, system)
    split_direction = "right",    -- "right" | "bottom" | "tab" | "float"
    split_size      = 55,
    scroll_follow   = true,       -- auto-scroll terminal to bottom
    -- torchrun / accelerate overrides
    torchrun_args   = {},
    accelerate_args = {},
    keymaps = {
      run    = "<leader>mr",
      stop   = "<leader>mS",
      toggle = "<leader>mR",
    },
  },

  -- ── Checkpoint Manager ───────────────────────────────────────────────────
  checkpoint = {
    enabled      = true,
    scan_roots   = { ".", "checkpoints", "outputs", "runs", "lightning_logs" },
    extensions   = { ".pt", ".pth", ".ckpt", ".safetensors", ".bin" },
    deep_scan    = false,   -- scan recursively (slower)
    show_size    = true,
    show_mtime   = true,
    keymaps = {
      toggle  = "<leader>mC",
      inspect = "<CR>",
      delete  = "dd",
      resume  = "r",
      close   = "q",
    },
  },

  -- ── Notebook (# %% cell runner) ──────────────────────────────────────────
  notebook = {
    enabled        = true,
    kernel_cmd     = nil,   -- nil = auto-detect (ipython, jupyter kernel)
    output_height  = 15,
    image_protocol = "auto",  -- "kitty" | "iterm2" | "sixel" | "none" | "auto"
    keymaps = {
      run_cell       = "<leader>mn",
      run_all        = "<leader>mN",
      run_above      = "<leader>mA",
      next_cell      = "]n",
      prev_cell      = "[n",
      new_cell_below = "<leader>mo",
      interrupt      = "<leader>mi",
      restart        = "<leader>mk",
      toggle_output  = "<leader>mO",
    },
  },

  -- ── Dataset Explorer ─────────────────────────────────────────────────────
  dataset = {
    enabled       = true,
    sample_size   = 5,
    max_str_len   = 80,
    show_stats    = true,
    keymaps       = { toggle = "<leader>mD", close = "q", next = "j", prev = "k" },
  },

  -- ── Profiler Viewer ──────────────────────────────────────────────────────
  profiler = {
    enabled    = true,
    top_n      = 20,
    sort_by    = "cuda_time",   -- "cuda_time" | "cpu_time" | "memory"
    keymaps    = { toggle = "<leader>mP", close = "q", sort_cycle = "s" },
  },

  -- ── Environment Manager ──────────────────────────────────────────────────
  env = {
    enabled     = true,
    show_pkgs   = true,
    pkg_limit   = 30,
    keymaps     = { toggle = "<leader>mE", close = "q", activate = "<CR>" },
  },

  -- ── W&B Integration ──────────────────────────────────────────────────────
  wandb = {
    enabled          = true,
    api_key_env      = "WANDB_API_KEY",
    base_url         = "https://api.wandb.ai",
    refresh_interval = 10000,
    max_runs         = 20,
    keymaps          = { toggle = "<leader>mw", close = "q", refresh = "R" },
  },

  -- ── Statusline ───────────────────────────────────────────────────────────
  statusline = {
    enabled       = true,
    show_gpu      = true,
    show_env      = true,
    show_job      = true,   -- active training job
    update_ms     = 2000,
  },
}

return M
