--- mlbuddy/notebook/init.lua  (cross-platform)
--- # %% cell runner with IPython kernel. Windows-compatible terminal launching.
local ui   = require("mlbuddy.ui")
local util = require("mlbuddy.util")
local plat = require("mlbuddy.platform")
local M    = {}

local NS_CELL   = vim.api.nvim_create_namespace("mlbuddy_nb_cell")
local NS_OUTPUT = vim.api.nvim_create_namespace("mlbuddy_nb_out")

-- ── Cell detection ────────────────────────────────────────────────────────────

local CELL_PATTERNS = { "^# %%%%", "^# In%[", "^# <<<", "^# %-%-%-%-" }

local function find_cells(bufnr)
  local lines   = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local markers = {}
  for i, line in ipairs(lines) do
    for _, pat in ipairs(CELL_PATTERNS) do
      if line:match(pat) then markers[#markers+1]=i; break end
    end
  end
  if #markers == 0 then
    return { { start_line=1, end_line=#lines, content=lines } }
  end
  local cells = {}
  for mi, m in ipairs(markers) do
    local s = m
    local e = markers[mi+1] and (markers[mi+1]-1) or #lines
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

local function cell_at_line(cells, line)
  for i, c in ipairs(cells) do
    if line >= c.start_line and line <= c.end_line then return i end
  end
  return nil
end

-- ── Kernel management ─────────────────────────────────────────────────────────

local _kernels  = {}  -- bufnr → Kernel
local _kern_seq = 0   -- monotonic counter so each kernel gets a unique buf name

-- Show the hidden kernel terminal in a split on demand
function M.show_kernel(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  local k     = _kernels[bufnr]
  if not k or not vim.api.nvim_buf_is_valid(k.buf) then
    ui.warn("No kernel running — start one with <leader>mn"); return
  end
  local h = (cfg.notebook and cfg.notebook.output_height) or 15
  vim.cmd("botright " .. h .. "split")
  vim.api.nvim_win_set_buf(0, k.buf)
end

local function start_kernel(bufnr, cfg)
  if _kernels[bufnr] then return _kernels[bufnr] end

  local python  = cfg.runner and cfg.runner.python or plat.find_python()
  local ipython = plat.script_in_prefix(
    vim.env.VIRTUAL_ENV or vim.env.CONDA_PREFIX or "", "ipython")
  if not plat.executable(ipython) then ipython = plat.find_exe("ipython") end

  local kernel_cmd
  if cfg.notebook.kernel_cmd then
    kernel_cmd = cfg.notebook.kernel_cmd
  elseif ipython then
    kernel_cmd = { ipython, "--no-banner", "--no-confirm-exit", "--simple-prompt" }
  else
    kernel_cmd = { python, "-c",
      "import IPython; IPython.start_ipython(['--no-banner','--no-confirm-exit','--simple-prompt'])" }
  end

  -- Create terminal buffer WITHOUT showing a split.
  -- We need a window temporarily so termopen() can run, then close it.
  local save_win = vim.api.nvim_get_current_win()
  local buf      = vim.api.nvim_create_buf(false, true)

  vim.cmd("split")                          -- open a temporary split
  local tmp_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(tmp_win, buf)

  local output_lines = {}
  local job_id = vim.fn.termopen(plat.term_cmd(kernel_cmd), {
    on_stdout = function(_, lines)
      for _, l in ipairs(lines) do
        if l and l ~= "" then output_lines[#output_lines + 1] = l end
      end
    end,
    on_exit = function()
      vim.schedule(function()
        _kernels[bufnr] = nil
        ui.info("IPython kernel stopped (buf " .. bufnr .. ")")
      end)
    end,
  })

  -- Close the temporary window — buffer + job stay alive
  vim.api.nvim_win_close(tmp_win, false)
  vim.api.nvim_set_current_win(save_win)

  -- Unique name to avoid E95 on restart
  _kern_seq = _kern_seq + 1
  pcall(vim.api.nvim_buf_set_name, buf,
    string.format("[mlbuddy] IPython:%d#%d", bufnr, _kern_seq))

  local k = { job_id=job_id, buf=buf, bufnr=bufnr, output_lines=output_lines }
  _kernels[bufnr] = k
  return k
end

local function send_cell(kernel, cell, cell_idx, bufnr, cfg)
  if not kernel then return end

  local code_lines = {}
  for _, line in ipairs(cell.content) do
    code_lines[#code_lines + 1] = line
  end
  while #code_lines > 0 and code_lines[1]:match("^%s*$") do
    table.remove(code_lines, 1)
  end
  if #code_lines == 0 then return end

  local script = plat.write_tmpfile(code_lines, "_mlb_cell.py")

  vim.api.nvim_buf_clear_namespace(bufnr, NS_OUTPUT, cell.start_line-1, cell.end_line)
  vim.api.nvim_buf_set_extmark(bufnr, NS_CELL, cell.start_line-1, 0, {
    virt_text = { { " ⏳ Running…", "MlbuddyCellRun" } },
    virt_text_pos = "eol", id = cell_idx,
  })

  local before    = #kernel.output_lines
  local MAX_WAIT  = 30000
  local start_t   = vim.uv.now()
  local PROMPT     = "^In %[%d+%]:%s*$"
  local INPUT_ECHO = "^In %[%d+%]:"

  vim.fn.chansend(kernel.job_id, string.format("%%run -i %q\n", script))

  local timer = vim.uv.new_timer()
  timer:start(120, 200, vim.schedule_wrap(function()
    for i = before+1, #kernel.output_lines do
      local l = kernel.output_lines[i]:gsub("\27%[[%d;]*[mK]",""):gsub("\r","")
      if l:match(PROMPT) then
        timer:stop()
        vim.fn.delete(script)

        local out = {}
        for j = before+1, i-1 do
          local ol = kernel.output_lines[j]:gsub("\27%[[%d;]*[mK]",""):gsub("\r","")
          if not ol:match("^%%run ") and not ol:match(INPUT_ECHO)   -- hide "In [N]: <command>" echo lines
             and not ol:match("^Out%[%d+%]:") then
             out[#out+1] = ol
          end
        end
        while #out > 0 and out[#out]:match("^%s*$") do table.remove(out) end

        vim.api.nvim_buf_del_extmark(bufnr, NS_CELL, cell_idx)
        vim.api.nvim_buf_set_extmark(bufnr, NS_CELL, cell.start_line-1, 0, {
          virt_text = { { " ✓ done", "MlbuddyGood" } },
          virt_text_pos = "eol", id = cell_idx,
        })

        if #out > 0 then
          local max_out = cfg.notebook and cfg.notebook.output_height or 15
          local virt = {}
          for oi = 1, math.min(#out, max_out) do
            local hl = out[oi]:match("^[A-Z][a-zA-Z]*Error") and "MlbuddyError" or "MlbuddyDim"
            virt[#virt+1] = { { "  " .. out[oi]:sub(1, 130), hl } }
          end
          if #out > max_out then
            virt[#virt+1] = { { "  … " .. (#out-max_out) .. " more lines", "MlbuddyWarn" } }
          end
          vim.api.nvim_buf_set_extmark(bufnr, NS_OUTPUT, cell.end_line-1, 0, {
            virt_lines = virt, virt_lines_above = false,
          })
        end
        return
      end
    end
    if vim.uv.now() - start_t > MAX_WAIT then
      timer:stop()
      vim.fn.delete(script)
      vim.api.nvim_buf_del_extmark(bufnr, NS_CELL, cell_idx)
      vim.api.nvim_buf_set_extmark(bufnr, NS_CELL, cell.start_line-1, 0, {
        virt_text = { { " ⚠ timeout — use <leader>mi to interrupt", "MlbuddyError" } },
        virt_text_pos = "eol", id = cell_idx,
      })
    end
  end))
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.run_cell(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "python" then ui.warn("Not a Python buffer"); return end
  local kernel = _kernels[bufnr]
  local cells  = find_cells(bufnr)
  local line   = vim.api.nvim_win_get_cursor(0)[1]
  local ci     = cell_at_line(cells, line) or 1
  if not kernel then
    kernel = start_kernel(bufnr, cfg)
    vim.defer_fn(function() send_cell(kernel, cells[ci], ci, bufnr, cfg) end, 1400)
    return
  end
  send_cell(kernel, cells[ci], ci, bufnr, cfg)
end

function M.run_all(cfg)
  local bufnr  = vim.api.nvim_get_current_buf()
  local cells  = find_cells(bufnr)
  local kernel = _kernels[bufnr] or start_kernel(bufnr, cfg)
  local delay  = _kernels[bufnr] and 0 or 1400
  vim.defer_fn(function()
    for ci, cell in ipairs(cells) do
      vim.defer_fn(function() send_cell(kernel, cell, ci, bufnr, cfg) end, (ci-1)*50)
    end
  end, delay)
end

function M.run_above(cfg)
  local bufnr  = vim.api.nvim_get_current_buf()
  local cells  = find_cells(bufnr)
  local line   = vim.api.nvim_win_get_cursor(0)[1]
  local ci     = cell_at_line(cells, line) or #cells
  local kernel = _kernels[bufnr] or start_kernel(bufnr, cfg)
  for i = 1, ci do
    vim.defer_fn(function() send_cell(kernel, cells[i], i, bufnr, cfg) end, (i-1)*50)
  end
end

function M.interrupt(cfg)
  local k = _kernels[vim.api.nvim_get_current_buf()]
  if k then vim.fn.chansend(k.job_id, "\x03"); ui.info("Kernel interrupted") end
end

function M.restart(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  local k = _kernels[bufnr]
  if k then
    vim.fn.jobstop(k.job_id); _kernels[bufnr]=nil
    vim.api.nvim_buf_clear_namespace(bufnr, NS_OUTPUT, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, NS_CELL,   0, -1)
  end
  start_kernel(bufnr, cfg); ui.info("Kernel restarted")
end

function M.toggle_output(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  local cells = find_cells(bufnr)
  local line  = vim.api.nvim_win_get_cursor(0)[1]
  local ci    = cell_at_line(cells, line) or 1
  local cell  = cells[ci]
  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr, NS_OUTPUT, {cell.end_line-1,0}, {cell.end_line-1,-1}, {})
  if #marks > 0 then
    vim.api.nvim_buf_del_extmark(bufnr, NS_OUTPUT, marks[1][1])
  end
end

function M.next_cell(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  local cells = find_cells(bufnr)
  local line  = vim.api.nvim_win_get_cursor(0)[1]
  for _, c in ipairs(cells) do
    if c.start_line > line then vim.api.nvim_win_set_cursor(0,{c.start_line,0}); return end
  end
end

function M.prev_cell(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  local cells = find_cells(bufnr)
  local line  = vim.api.nvim_win_get_cursor(0)[1]
  local prev  = nil
  for _, c in ipairs(cells) do if c.start_line<line then prev=c.start_line end end
  if prev then vim.api.nvim_win_set_cursor(0,{prev,0}) end
end

function M.new_cell_below()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), row, row, false, {"","# %%",""})
  vim.api.nvim_win_set_cursor(0,{row+2,0})
end

function M.decorate_cells(bufnr)
  if vim.bo[bufnr].filetype ~= "python" then return end
  vim.api.nvim_buf_clear_namespace(bufnr, NS_CELL, 0, -1)
  local cells = find_cells(bufnr)
  for _, c in ipairs(cells) do
    vim.api.nvim_buf_set_extmark(bufnr, NS_CELL, c.start_line-1, 0, {
      sign_text="▶", sign_hl_group="MlbuddyCellRun", priority=10,
    })
  end
end

function M.setup_autocmds(cfg)
  local ag = vim.api.nvim_create_augroup("MlbuddyNotebook", {clear=true})
  vim.api.nvim_create_autocmd({"BufReadPost","BufWritePost"},{
    group=ag, pattern="*.py",
    callback=function(ev) M.decorate_cells(ev.buf) end,
  })
end

return M
