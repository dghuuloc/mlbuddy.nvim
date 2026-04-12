--- mlbuddy/quarto/runner.lua
--- Bridges mlbuddy's IPython kernel with quarto-nvim's codeRunner system.
---
--- Three modes:
---   "mlbuddy"  — always use mlbuddy's own IPython kernel (independent of quarto-nvim)
---   "quarto"   — delegate entirely to quarto-nvim's configured runner (molten/slime/iron)
---   "auto"     — use quarto-nvim if available, else fall back to mlbuddy kernel
---
--- When mode = "mlbuddy", this module registers as a custom runner in quarto-nvim
--- via the codeRunner.default_method = <function> API.

local cells_mod = require("mlbuddy.quarto.cells")
local ui        = require("mlbuddy.ui")
local plat      = require("mlbuddy.platform")
local M         = {}

-- ── Kernel registry (one kernel per .qmd buffer) ──────────────────────────

local _kernels = {}   -- bufnr → kernel state (same structure as notebook module)
local NS_OUT   = vim.api.nvim_create_namespace("mlbuddy_qmd_out")
local NS_CELL  = vim.api.nvim_create_namespace("mlbuddy_qmd_cell")

-- ── Start / get kernel ─────────────────────────────────────────────────────

---@param bufnr integer  the .qmd buffer
---@param cfg   table
---@return table  kernel
local function get_or_start_kernel(bufnr, cfg)
  if _kernels[bufnr] then return _kernels[bufnr] end

  local python  = (cfg.quarto and cfg.quarto.python) or plat.find_python()
  local ipython = plat.script_in_prefix(
    vim.env.VIRTUAL_ENV or vim.env.CONDA_PREFIX or "", "ipython")
  if not plat.executable(ipython) then ipython = plat.find_exe("ipython") end

  local kernel_cmd
  if cfg.quarto and cfg.quarto.kernel_cmd then
    kernel_cmd = cfg.quarto.kernel_cmd
  elseif ipython then
    kernel_cmd = { ipython, "--no-banner", "--no-confirm-exit", "--simple-prompt" }
  else
    kernel_cmd = { python, "-c",
      "import IPython; IPython.start_ipython(['--no-banner','--no-confirm-exit','--simple-prompt'])" }
  end

  local split_h = (cfg.quarto and cfg.quarto.output_height) or 12
  vim.cmd("botright " .. split_h .. "split")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)

  local output_lines = {}
  local job_id = vim.fn.termopen(plat.term_cmd(kernel_cmd), {
    on_stdout = function(_, lines)
      for _, l in ipairs(lines) do
        if l and l ~= "" then output_lines[#output_lines+1] = l end
      end
    end,
    on_exit = function()
      vim.schedule(function()
        _kernels[bufnr] = nil
        ui.info("Quarto kernel stopped (buf "..bufnr..")")
      end)
    end,
  })

  vim.api.nvim_buf_set_name(buf, "[mlbuddy] Quarto kernel:"..bufnr)
  vim.wo[win].number = false; vim.wo[win].signcolumn = "no"
  vim.cmd("wincmd p")

  local k = { job_id=job_id, buf=buf, win=win, bufnr=bufnr, output_lines=output_lines }
  _kernels[bufnr] = k
  return k
end

-- ── Send a cell to the kernel and collect output ────────────────────────────

---@param bufnr  integer  source .qmd buffer
---@param cell   QuartoCell
---@param cfg    table
local function send_cell(bufnr, cell, cfg)
  local k = get_or_start_kernel(bufnr, cfg)
  if not k then return end

  local code = table.concat(cell.lines, "\n")
  if code:gsub("%s", "") == "" then return end

  -- Clear previous output for this cell range
  vim.api.nvim_buf_clear_namespace(bufnr, NS_OUT, cell.start_line-1, cell.end_line)

  -- Mark cell as running
  vim.api.nvim_buf_set_extmark(bufnr, NS_CELL, cell.start_line-1, 0, {
    virt_text = { { " ⏳ Running…", "MlbuddyCellRun" } },
    virt_text_pos = "eol",
  })

  local before = #k.output_lines
  local delim  = "__MLBUDDY_QMD_END_"..math.floor(vim.uv.now()).."__"
  vim.fn.chansend(k.job_id, code.."\nprint('"..delim.."')\n")

  local timer = vim.uv.new_timer()
  local start = vim.uv.now()
  local MAX_WAIT = 60000  -- 60s for training cells

  timer:start(100, 250, vim.schedule_wrap(function()
    for i = before+1, #k.output_lines do
      if k.output_lines[i]:find(delim, 1, true) then
        timer:stop()

        -- Collect output
        local out = {}
        for j = before+1, i-1 do
          local l = k.output_lines[j]
          l = l:gsub("\27%[[%d;]*[mK]",""):gsub("\r","")
          if not l:match("^In %[%d+%]:") and not l:match("^Out%[%d+%]:") then
            out[#out+1] = l
          end
        end

        -- Clear running indicator
        vim.api.nvim_buf_clear_namespace(bufnr, NS_CELL, cell.start_line-1, cell.start_line)
        vim.api.nvim_buf_set_extmark(bufnr, NS_CELL, cell.start_line-1, 0, {
          virt_text = { { " ✓ done", "MlbuddyGood" } },
          virt_text_pos = "eol",
        })

        -- Show output as virtual lines
        local max_lines = (cfg.quarto and cfg.quarto.output_height) or 12
        if #out > 0 then
          local virt = {}
          for oi = 1, math.min(#out, max_lines) do
            virt[#virt+1] = { { "  " .. out[oi]:sub(1,120), "MlbuddyDim" } }
          end
          if #out > max_lines then
            virt[#virt+1] = { { "  … "..(#out-max_lines).." more lines", "MlbuddyWarn" } }
          end
          vim.api.nvim_buf_set_extmark(bufnr, NS_OUT, cell.end_line-1, 0, {
            virt_lines = virt, virt_lines_above = false,
          })
        end

        -- If this was a training cell, open the Trainer dashboard
        if cell.is_train and (cfg.quarto and cfg.quarto.auto_trainer) then
          local trainer = require("mlbuddy.trainer")
          -- Parse output lines for metrics
          local parser = require("mlbuddy.trainer.parser")
          local hist = parser.MetricHistory()
          for _, line in ipairs(out) do
            local ev = parser.parse_line(line, {})
            if ev then parser.update_history(hist, ev, 2000) end
          end
          -- If we found training metrics, show them
          if next(hist.data) then
            ui.info("[mlbuddy] Training metrics detected — check :MlbuddyTrainer")
          end
        end

        return
      end
    end
    if vim.uv.now() - start > MAX_WAIT then
      timer:stop()
      vim.api.nvim_buf_set_extmark(bufnr, NS_CELL, cell.start_line-1, 0, {
        virt_text = { { " ⚠ timeout", "MlbuddyError" } },
        virt_text_pos = "eol",
      })
    end
  end))
end

-- ── Public runner functions ────────────────────────────────────────────────

---@param cfg table
---@return fun(code:string)  function that sends code to the mlbuddy kernel
function M.make_quarto_runner(cfg)
  -- This function is passed as codeRunner.default_method to quarto.setup()
  return function(code)
    local bufnr = vim.api.nvim_get_current_buf()
    if not _kernels[bufnr] then
      get_or_start_kernel(bufnr, cfg)
      vim.defer_fn(function()
        local k = _kernels[bufnr]
        if k then vim.fn.chansend(k.job_id, code.."\n") end
      end, 1400)
    else
      local k = _kernels[bufnr]
      vim.fn.chansend(k.job_id, code.."\n")
    end
  end
end

--- Run the cell under the cursor in the .qmd buffer.
---@param cfg table
function M.run_cell(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  local mode  = (cfg.quarto and cfg.quarto.runner) or "auto"

  -- "quarto" mode: delegate to quarto-nvim's runner
  if mode == "quarto" then
    local ok, runner = pcall(require, "quarto.runner")
    if ok then runner.run_cell(); return end
    ui.warn("quarto-nvim not available — falling back to mlbuddy kernel")
  end

  -- "mlbuddy" or "auto" fallback: use our IPython kernel
  local all_cells = cells_mod.parse(bufnr)
  local line      = vim.api.nvim_win_get_cursor(0)[1]
  local cell      = cells_mod.cell_at_line(all_cells, line)
  if not cell then
    ui.warn("[mlbuddy/quarto] No code cell at cursor")
    return
  end
  if cell.lang ~= "python" then
    -- For non-Python cells, try quarto runner
    local ok, runner = pcall(require, "quarto.runner")
    if ok then runner.run_cell(); return end
    ui.warn("[mlbuddy/quarto] Only Python cells supported without quarto-nvim")
    return
  end

  -- Auto-start kernel if needed
  if not _kernels[bufnr] then
    get_or_start_kernel(bufnr, cfg)
    vim.defer_fn(function() send_cell(bufnr, cell, cfg) end, 1500)
  else
    send_cell(bufnr, cell, cfg)
  end
end

--- Run all Python cells in the document.
---@param cfg table
function M.run_all(cfg)
  local bufnr     = vim.api.nvim_get_current_buf()
  local mode      = (cfg.quarto and cfg.quarto.runner) or "auto"

  if mode == "quarto" then
    local ok, runner = pcall(require, "quarto.runner")
    if ok then runner.run_all(); return end
  end

  local all_cells = cells_mod.parse(bufnr)
  local py_cells  = cells_mod.cells_by_lang(all_cells, "python")

  if not _kernels[bufnr] then
    get_or_start_kernel(bufnr, cfg)
    vim.defer_fn(function()
      for i, cell in ipairs(py_cells) do
        vim.defer_fn(function() send_cell(bufnr, cell, cfg) end, (i-1)*80)
      end
    end, 1500)
  else
    for i, cell in ipairs(py_cells) do
      vim.defer_fn(function() send_cell(bufnr, cell, cfg) end, (i-1)*80)
    end
  end
end

--- Run all cells above (and including) cursor.
---@param cfg table
function M.run_above(cfg)
  local bufnr     = vim.api.nvim_get_current_buf()
  local mode      = (cfg.quarto and cfg.quarto.runner) or "auto"

  if mode == "quarto" then
    local ok, runner = pcall(require, "quarto.runner")
    if ok then runner.run_above(); return end
  end

  local all_cells = cells_mod.parse(bufnr)
  local line      = vim.api.nvim_win_get_cursor(0)[1]
  local above     = cells_mod.cells_above(all_cells, line, "python")

  if not _kernels[bufnr] then
    get_or_start_kernel(bufnr, cfg)
    vim.defer_fn(function()
      for i, cell in ipairs(above) do
        vim.defer_fn(function() send_cell(bufnr, cell, cfg) end, (i-1)*80)
      end
    end, 1500)
  else
    for i, cell in ipairs(above) do
      vim.defer_fn(function() send_cell(bufnr, cell, cfg) end, (i-1)*80)
    end
  end
end

--- Run current cell with the training monitor dashboard.
---@param cfg table
function M.run_as_trainer(cfg)
  local bufnr     = vim.api.nvim_get_current_buf()
  local all_cells = cells_mod.parse(bufnr)
  local line      = vim.api.nvim_win_get_cursor(0)[1]
  local cell      = cells_mod.cell_at_line(all_cells, line)

  if not cell or cell.lang ~= "python" then
    ui.warn("[mlbuddy/quarto] No Python cell at cursor"); return
  end

  -- Write cell code to a temp file and launch with trainer monitor
  local python = (cfg.quarto and cfg.quarto.python) or plat.find_python()
  local script = require("mlbuddy.util").write_py_script(cell.lines, "_mlb_qmd_cell.py")
  local trainer = require("mlbuddy.trainer")
  trainer.launch({ python, script }, cfg)
  ui.info("[mlbuddy/quarto] Running cell with Training Monitor")
end

--- Interrupt the kernel for a buffer.
---@param bufnr integer
function M.interrupt(bufnr)
  local k = _kernels[bufnr]
  if k then
    vim.fn.chansend(k.job_id, "\x03")
    ui.info("[mlbuddy/quarto] Kernel interrupted")
  end
end

--- Restart the kernel for a buffer.
---@param bufnr integer
---@param cfg   table
function M.restart(bufnr, cfg)
  local k = _kernels[bufnr]
  if k then
    vim.fn.jobstop(k.job_id)
    _kernels[bufnr] = nil
    vim.api.nvim_buf_clear_namespace(bufnr, NS_OUT,  0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, NS_CELL, 0, -1)
  end
  get_or_start_kernel(bufnr, cfg)
  ui.info("[mlbuddy/quarto] Kernel restarted")
end

--- Toggle output visibility for the cell at cursor.
---@param bufnr integer
function M.toggle_output(bufnr)
  local all_cells = cells_mod.parse(bufnr)
  local line  = vim.api.nvim_win_get_cursor(0)[1]
  local cell  = cells_mod.cell_at_line(all_cells, line)
  if not cell then return end
  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr, NS_OUT, {cell.end_line-1,0}, {cell.end_line-1,-1}, {})
  if #marks > 0 then
    for _, m in ipairs(marks) do
      vim.api.nvim_buf_del_extmark(bufnr, NS_OUT, m[1])
    end
  end
end

--- Clear all output virtual text from the buffer.
---@param bufnr integer
function M.clear_output(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, NS_OUT,  0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, NS_CELL, 0, -1)
end

--- Kernel status string for statusline.
---@param bufnr integer
---@return string
function M.kernel_status(bufnr)
  if not bufnr then return "" end
  local k = _kernels[bufnr]
  if not k then return "󰠮 idle" end
  return "󰠮 kernel active"
end

return M
