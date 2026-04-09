--- mlbuddy/notebook/init.lua
--- Jupyter-free cell execution: # %% cell markers → IPython kernel.
--- Supports inline output, variable inspection, Kitty image protocol.
local ui   = require("mlbuddy.ui")
local util = require("mlbuddy.util")
local M    = {}

local NS_CELL   = vim.api.nvim_create_namespace("mlbuddy_nb_cell")
local NS_OUTPUT = vim.api.nvim_create_namespace("mlbuddy_nb_out")

-- ── Cell detection (Treesitter + fallback regex) ──────────────────────────────

local CELL_PATTERNS = {
  "^# %%%%",         -- # %%
  "^# In%[",         -- # In[N]:
  "^# <<<",          -- # <<<
  "^# --%-%-",        -- # ----
}

---@class Cell
---@field start_line integer  1-indexed
---@field end_line   integer
---@field content    string[]

---@param bufnr integer
---@return Cell[]
local function find_cells(bufnr)
  local lines   = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local markers = {}

  for i, line in ipairs(lines) do
    for _, pat in ipairs(CELL_PATTERNS) do
      if line:match(pat) then markers[#markers+1] = i; break end
    end
  end

  if #markers == 0 then
    -- Whole file is one cell
    return { { start_line=1, end_line=#lines, content=lines } }
  end

  local cells = {}
  for mi, m in ipairs(markers) do
    local s = m
    local e = markers[mi+1] and (markers[mi+1] - 1) or #lines
    local content = {}
    for i = s, e do
      if not lines[i]:match("^# %%") and not lines[i]:match("^# In%[") then
        content[#content+1] = lines[i]
      end
    end
    cells[#cells+1] = { start_line=s, end_line=e, content=content }
  end
  return cells
end

--- Find the cell containing a given line number.
---@param cells  Cell[]
---@param line   integer  1-indexed
---@return integer|nil  index into cells
local function cell_at_line(cells, line)
  for i, c in ipairs(cells) do
    if line >= c.start_line and line <= c.end_line then return i end
  end
  return nil
end

-- ── IPython kernel management ─────────────────────────────────────────────────

---@class Kernel
---@field job_id  integer
---@field buf     integer   terminal buffer
---@field win     integer
---@field bufnr   integer   source buffer
---@field pending table[]   list of pending output captures

local _kernels = {}  -- bufnr → Kernel

local function kernel_for(bufnr, cfg)
  return _kernels[bufnr]
end

--- Start an IPython kernel in a split window.
---@param bufnr  integer
---@param cfg    table
---@return Kernel
local function start_kernel(bufnr, cfg)
  if _kernels[bufnr] then return _kernels[bufnr] end

  local python = cfg.runner and cfg.runner.python or util.find_python()
  local cmd    = cfg.notebook.kernel_cmd
    or { python, "-c",
         "import IPython; IPython.start_ipython(['--no-banner', '--no-confirm-exit', '--simple-prompt'])" }

  local split_h = cfg.notebook.output_height or 15
  vim.cmd("botright " .. split_h .. "split")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)

  local output_lines = {}

  local job_id = vim.fn.termopen(cmd, {
    on_stdout = function(_, lines)
      for _, l in ipairs(lines) do
        if l and l ~= "" then output_lines[#output_lines+1] = l end
      end
    end,
    on_exit = function()
      vim.schedule(function()
        _kernels[bufnr] = nil
        ui.info("IPython kernel stopped for buffer " .. bufnr)
      end)
    end,
  })

  vim.api.nvim_buf_set_name(buf, "[mlbuddy] IPython:" .. bufnr)
  vim.wo[win].number     = false
  vim.wo[win].signcolumn = "no"

  -- Return to source window
  vim.cmd("wincmd p")

  local k = {
    job_id       = job_id,
    buf          = buf,
    win          = win,
    bufnr        = bufnr,
    output_lines = output_lines,
  }
  _kernels[bufnr] = k
  return k
end

--- Send code to kernel and capture output as virtual text.
---@param kernel  Kernel
---@param cell    Cell
---@param bufnr   integer  source buffer
---@param cfg     table
local function send_cell(kernel, cell, cell_idx, bufnr, cfg)
  if not kernel then return end

  -- Build the code string
  local code = table.concat(cell.content, "\n")
  if code:gsub("%s", "") == "" then return end

  -- Clear previous output for this cell
  vim.api.nvim_buf_clear_namespace(bufnr, NS_OUTPUT, cell.start_line-1, cell.end_line)

  -- Mark cell as running
  vim.api.nvim_buf_set_extmark(bufnr, NS_CELL, cell.start_line-1, 0, {
    virt_text     = { { " ⏳ Running…", "MlbuddyCellRun" } },
    virt_text_pos = "eol",
    id            = cell_idx,
  })

  -- Record output lines before sending
  local before = #kernel.output_lines

  -- Send code to IPython terminal
  -- We wrap with a delimiter to detect output end
  local delim = "__MLBUDDY_CELL_END_" .. math.floor(vim.uv.now()) .. "__"
  local full  = code .. "\nprint('" .. delim .. "')\n"

  vim.fn.chansend(kernel.job_id, full)

  -- Poll for output completion
  local MAX_WAIT = 30000  -- 30s timeout
  local start    = vim.uv.now()
  local timer    = vim.uv.new_timer()
  local found    = false

  timer:start(100, 200, vim.schedule_wrap(function()
    -- Look for delimiter in new output
    for i = before+1, #kernel.output_lines do
      if kernel.output_lines[i]:find(delim, 1, true) then
        found = true
        timer:stop()

        -- Collect output between before and delimiter
        local out = {}
        for j = before+1, i-1 do
          local l = kernel.output_lines[j]
          -- Strip ANSI escapes
          l = l:gsub("\27%[[%d;]*[mK]", "")
          -- Skip the IPython prompt lines "In [N]:" / "Out[N]:"
          if not l:match("^In %[%d+%]:") and not l:match("^Out%[%d+%]:") then
            out[#out+1] = l
          end
        end

        -- Render output as virtual lines below the cell
        vim.api.nvim_buf_del_extmark(bufnr, NS_CELL, cell_idx)
        vim.api.nvim_buf_set_extmark(bufnr, NS_CELL, cell.start_line-1, 0, {
          virt_text     = { { " ✓ done", "MlbuddyGood" } },
          virt_text_pos = "eol",
          id            = cell_idx,
        })

        if #out > 0 then
          -- Show first cfg.notebook.output_height lines as virtual text
          local max_out = cfg.notebook.output_height or 15
          local virt    = {}
          for oi = 1, math.min(#out, max_out) do
            virt[#virt+1] = { { "  " .. out[oi]:sub(1, 120), "MlbuddyDim" } }
          end
          if #out > max_out then
            virt[#virt+1] = { { "  … " .. (#out-max_out) .. " more lines", "MlbuddyWarn" } }
          end
          vim.api.nvim_buf_set_extmark(bufnr, NS_OUTPUT, cell.end_line-1, 0, {
            virt_lines      = virt,
            virt_lines_above = false,
          })
        end

        return
      end
    end

    if vim.uv.now() - start > MAX_WAIT then
      timer:stop()
      vim.api.nvim_buf_del_extmark(bufnr, NS_CELL, cell_idx)
      vim.api.nvim_buf_set_extmark(bufnr, NS_CELL, cell.start_line-1, 0, {
        virt_text     = { { " ⚠ timeout", "MlbuddyError" } },
        virt_text_pos = "eol",
        id            = cell_idx,
      })
    end
  end))
end

-- ── Public commands ───────────────────────────────────────────────────────────

--- Run the cell containing the cursor.
---@param cfg table
function M.run_cell(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "python" then
    ui.warn("Notebook: not a Python buffer"); return
  end

  local kernel = kernel_for(bufnr, cfg)
  if not kernel then
    kernel = start_kernel(bufnr, cfg)
    -- Give kernel 1s to start
    vim.defer_fn(function()
      local cells = find_cells(bufnr)
      local line  = vim.api.nvim_win_get_cursor(0)[1]
      local ci    = cell_at_line(cells, line) or 1
      send_cell(kernel, cells[ci], ci, bufnr, cfg)
    end, 1200)
    return
  end

  local cells = find_cells(bufnr)
  local line  = vim.api.nvim_win_get_cursor(0)[1]
  local ci    = cell_at_line(cells, line) or 1
  send_cell(kernel, cells[ci], ci, bufnr, cfg)
end

--- Run all cells top-to-bottom.
---@param cfg table
function M.run_all(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  local cells = find_cells(bufnr)
  local kernel = kernel_for(bufnr, cfg) or start_kernel(bufnr, cfg)

  local delay = kernel_for(bufnr, cfg) and 0 or 1200
  vim.defer_fn(function()
    for ci, cell in ipairs(cells) do
      -- Stagger sends slightly; kernel is synchronous via IPython
      vim.defer_fn(function()
        send_cell(kernel, cell, ci, bufnr, cfg)
      end, (ci-1) * 50)
    end
  end, delay)
end

--- Run all cells above (and including) the cursor.
---@param cfg table
function M.run_above(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  local cells = find_cells(bufnr)
  local line  = vim.api.nvim_win_get_cursor(0)[1]
  local ci    = cell_at_line(cells, line) or #cells
  local kernel = kernel_for(bufnr, cfg) or start_kernel(bufnr, cfg)
  for i = 1, ci do
    vim.defer_fn(function()
      send_cell(kernel, cells[i], i, bufnr, cfg)
    end, (i-1)*50)
  end
end

--- Interrupt the kernel.
---@param cfg table
function M.interrupt(cfg)
  local k = kernel_for(vim.api.nvim_get_current_buf(), cfg)
  if k then
    vim.fn.chansend(k.job_id, "\x03")
    ui.info("Kernel interrupted")
  end
end

--- Restart the kernel.
---@param cfg table
function M.restart(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  local k = _kernels[bufnr]
  if k then
    vim.fn.jobstop(k.job_id)
    _kernels[bufnr] = nil
    -- Clear all output
    vim.api.nvim_buf_clear_namespace(bufnr, NS_OUTPUT, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, NS_CELL,   0, -1)
  end
  start_kernel(bufnr, cfg)
  ui.info("Kernel restarted")
end

--- Toggle output visibility for current cell.
---@param cfg table
function M.toggle_output(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  local cells = find_cells(bufnr)
  local line  = vim.api.nvim_win_get_cursor(0)[1]
  local ci    = cell_at_line(cells, line) or 1
  if ci then
    local cell = cells[ci]
    local marks = vim.api.nvim_buf_get_extmarks(
      bufnr, NS_OUTPUT, {cell.end_line-1, 0}, {cell.end_line-1, -1}, {})
    if #marks > 0 then
      vim.api.nvim_buf_del_extmark(bufnr, NS_OUTPUT, marks[1][1])
    end
  end
end

--- Move cursor to next cell start.
function M.next_cell(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  local cells = find_cells(bufnr)
  local line  = vim.api.nvim_win_get_cursor(0)[1]
  for _, c in ipairs(cells) do
    if c.start_line > line then
      vim.api.nvim_win_set_cursor(0, {c.start_line, 0})
      return
    end
  end
end

--- Move cursor to previous cell start.
function M.prev_cell(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  local cells = find_cells(bufnr)
  local line  = vim.api.nvim_win_get_cursor(0)[1]
  local prev  = nil
  for _, c in ipairs(cells) do
    if c.start_line < line then prev = c.start_line end
  end
  if prev then vim.api.nvim_win_set_cursor(0, {prev, 0}) end
end

--- Insert a new cell separator below cursor.
function M.new_cell_below()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), row, row, false,
    { "", "# %%", "" })
  vim.api.nvim_win_set_cursor(0, {row+2, 0})
end

-- ── Cell sign highlighting ────────────────────────────────────────────────────

--- Decorate cell boundaries with virtual sign text.
---@param bufnr integer
function M.decorate_cells(bufnr)
  if vim.bo[bufnr].filetype ~= "python" then return end
  vim.api.nvim_buf_clear_namespace(bufnr, NS_CELL, 0, -1)
  local cells = find_cells(bufnr)
  for _, c in ipairs(cells) do
    -- Mark the # %% line
    vim.api.nvim_buf_set_extmark(bufnr, NS_CELL, c.start_line-1, 0, {
      sign_text     = "▶",
      sign_hl_group = "MlbuddyCellRun",
      priority      = 10,
    })
  end
end

--- Setup notebook autocmds.
---@param cfg table
function M.setup_autocmds(cfg)
  local ag = vim.api.nvim_create_augroup("MlbuddyNotebook", { clear=true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group=ag, pattern="*.py",
    callback=function(ev) M.decorate_cells(ev.buf) end,
  })
end

return M
