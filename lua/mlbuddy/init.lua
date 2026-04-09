--- mlbuddy/init.lua  ── Enterprise ML Plugin for Neovim 0.12
---
--- 13 modules, all optional, independently usable:
---   torchview    Model architecture inspector (Treesitter + virtual text)
---   mlflow       MLflow experiment tracker   (REST API + sparklines)
---   dataloader   Tensor inspector            (DAP + Python subprocess + heatmap)
---   trainer      Live training dashboard     (stdout parse + 2D charts + ETA)
---   gpu          GPU monitor                 (nvidia-smi / rocm-smi + statusline)
---   runner       Training launcher           (Lightning / HF / torchrun / accelerate)
---   checkpoint   Checkpoint manager          (pt/ckpt/safetensors scan + inspect)
---   notebook     Jupyter cell runner         (# %% cells + IPython kernel + virt output)
---   dataset      Dataset explorer            (HF / torch / numpy introspection)
---   profiler     PyTorch profiler viewer     (chrome trace JSON + flame bars)
---   env          Environment manager         (venv/conda/poetry/pyenv)
---   wandb        W&B integration             (REST API + sparklines)
---   statusline   Statusline components       (GPU + env + job for lualine/heirline)
---
--- Minimum: Neovim 0.10.  Full feature set: Neovim 0.12.
--- See :checkhealth mlbuddy for dependency status.

local config = require("mlbuddy.config")
local ui     = require("mlbuddy.ui")
local M      = {}

--- Resolved config (set by setup()).
M._cfg = nil

-- ── setup() ──────────────────────────────────────────────────────────────────

---@param opts table|nil  deep-merged onto config.defaults
function M.setup(opts)
  local cfg  = vim.tbl_deep_extend("force", config.defaults, opts or {})
  M._cfg     = cfg

  ui.define_highlights()

  -- ── Per-module autocmds / background setup ──────────────────────────────
  if cfg.torchview.enabled then
    require("mlbuddy.torchview").setup_autocmds(cfg)
  end
  if cfg.dataloader.enabled then
    require("mlbuddy.dataloader").setup_autocmds(cfg)
  end
  if cfg.notebook.enabled then
    require("mlbuddy.notebook").setup_autocmds(cfg)
  end
  if cfg.statusline.enabled then
    require("mlbuddy.statusline").setup(cfg)
  end

  -- ── Global keymaps ──────────────────────────────────────────────────────

  local function nmap(lhs, fn, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { silent=true, desc="[mlbuddy] "..desc })
    end
  end

  -- TorchView
  nmap(cfg.torchview.keymaps.toggle,        function() M.torchview()      end, "TorchView toggle")

  -- MLflow
  nmap(cfg.mlflow.keymaps.toggle,           function() M.mlflow()         end, "MLflow toggle")

  -- DataLoader
  nmap(cfg.dataloader.keymaps.toggle,       function() M.dataloader()     end, "DataLoader toggle")
  nmap(cfg.dataloader.keymaps.inspect_word, function() M.inspect_tensor() end, "Inspect tensor")

  -- Trainer
  nmap(cfg.trainer.keymaps.toggle,          function() M.trainer()        end, "Trainer toggle")

  -- GPU
  nmap(cfg.gpu.keymaps.toggle,              function() M.gpu()            end, "GPU monitor toggle")

  -- Runner
  nmap(cfg.runner.keymaps.run,              function() M.run()            end, "Run current file")
  nmap(cfg.runner.keymaps.toggle,           function() M.runner()         end, "Runner picker")

  -- Checkpoint
  nmap(cfg.checkpoint.keymaps.toggle,       function() M.checkpoint()     end, "Checkpoint manager")

  -- Notebook
  nmap(cfg.notebook.keymaps.run_cell,       function() M.notebook_run()   end, "Run cell")
  nmap(cfg.notebook.keymaps.run_all,        function() M.notebook_run_all() end, "Run all cells")
  nmap(cfg.notebook.keymaps.run_above,      function() M.notebook_run_above() end, "Run above")
  nmap(cfg.notebook.keymaps.next_cell,      function() M.notebook_next()  end, "Next cell")
  nmap(cfg.notebook.keymaps.prev_cell,      function() M.notebook_prev()  end, "Prev cell")
  nmap(cfg.notebook.keymaps.new_cell_below, function() M.notebook_new()   end, "New cell below")
  nmap(cfg.notebook.keymaps.interrupt,      function() M.notebook_interrupt() end, "Interrupt kernel")
  nmap(cfg.notebook.keymaps.restart,        function() M.notebook_restart()   end, "Restart kernel")
  nmap(cfg.notebook.keymaps.toggle_output,  function() M.notebook_toggle_output() end, "Toggle output")

  -- Dataset
  nmap(cfg.dataset.keymaps.toggle,          function() M.dataset()        end, "Dataset explorer")

  -- Profiler
  nmap(cfg.profiler.keymaps.toggle,         function() M.profiler()       end, "Profiler toggle")

  -- Env
  nmap(cfg.env.keymaps.toggle,              function() M.env()            end, "Env manager")

  -- W&B
  nmap(cfg.wandb.keymaps.toggle,            function() M.wandb()          end, "W&B toggle")
end

-- ── Public module toggles ─────────────────────────────────────────────────────

local function cfg() return M._cfg or config.defaults end

function M.torchview()        require("mlbuddy.torchview").toggle(cfg())                     end
function M.mlflow()           require("mlbuddy.mlflow").toggle(cfg())                        end
function M.dataloader()       require("mlbuddy.dataloader").toggle(cfg())                    end
function M.inspect_tensor()   require("mlbuddy.dataloader").inspect_cursor(cfg())            end
function M.trainer()          require("mlbuddy.trainer").toggle(cfg())                       end
function M.gpu()              require("mlbuddy.gpu").toggle(cfg())                           end
function M.runner()           require("mlbuddy.runner").toggle(cfg())                        end
function M.run()              require("mlbuddy.runner").run(cfg())                           end
function M.checkpoint()       require("mlbuddy.checkpoint").toggle(cfg())                    end
function M.dataset()          require("mlbuddy.dataset").toggle(cfg())                       end
function M.profiler()         require("mlbuddy.profiler").toggle(cfg())                      end
function M.profiler_load(p)   require("mlbuddy.profiler").load(p, cfg())                     end
function M.env()              require("mlbuddy.env").toggle(cfg())                           end
function M.wandb()            require("mlbuddy.wandb").toggle(cfg())                         end

-- Notebook sub-commands
function M.notebook_run()            require("mlbuddy.notebook").run_cell(cfg())             end
function M.notebook_run_all()        require("mlbuddy.notebook").run_all(cfg())              end
function M.notebook_run_above()      require("mlbuddy.notebook").run_above(cfg())            end
function M.notebook_next()           require("mlbuddy.notebook").next_cell(cfg())            end
function M.notebook_prev()           require("mlbuddy.notebook").prev_cell(cfg())            end
function M.notebook_new()            require("mlbuddy.notebook").new_cell_below()            end
function M.notebook_interrupt()      require("mlbuddy.notebook").interrupt(cfg())            end
function M.notebook_restart()        require("mlbuddy.notebook").restart(cfg())              end
function M.notebook_toggle_output()  require("mlbuddy.notebook").toggle_output(cfg())        end

--- Launch a command with the trainer monitor.
---@param cmd string[]
function M.train(cmd)         require("mlbuddy.trainer").launch(cmd, cfg())                  end

--- Open all panels in a tiled layout (best on wide monitors).
function M.dashboard()
  M.torchview()
  vim.cmd("wincmd l")
  M.trainer()
  vim.cmd("wincmd l")
  M.gpu()
end

-- ── Statusline exports ────────────────────────────────────────────────────────

--- For lualine:
---   sections = { lualine_x = { require("mlbuddy").lualine_component() } }
function M.lualine_component()    return require("mlbuddy.statusline").lualine_component() end
function M.lualine_gpu()          return require("mlbuddy.statusline").lualine_gpu()       end
function M.lualine_env()          return require("mlbuddy.statusline").lualine_env()       end
function M.lualine_job()          return require("mlbuddy.statusline").lualine_job()       end

--- For heirline:
---   { require("mlbuddy").heirline_component() }
function M.heirline_component()   return require("mlbuddy.statusline").heirline_component() end

--- For plain %{} statusline:
---   vim.opt.statusline = ... .. require("mlbuddy").statusline_expr()
function M.statusline_expr()      return require("mlbuddy.statusline").raw_expr()          end

-- ── Health check ──────────────────────────────────────────────────────────────

function M.health() require("mlbuddy.health").check() end

return M
