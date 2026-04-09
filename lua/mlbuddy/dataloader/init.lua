--- mlbuddy.dataloader
--- Tensor / DataLoader inspection:
---   1. DAP integration: auto-inspect on breakpoint hit
---   2. Cursor-word inspection: run a Python subprocess to evaluate the expression
---   3. Toggle panel
local renderer = require("mlbuddy.dataloader.renderer")
local ui       = require("mlbuddy.ui")
local M        = {}

-- ── State ─────────────────────────────────────────────────────────────────────

local ctx = {
  win     = nil,
  buf     = nil,
  tensors = {},
}

-- ── Python helper script ──────────────────────────────────────────────────────
-- We write a one-shot Python script to a temp file, run it, and parse stdout.
-- This avoids depending on a persistent Python REPL.

local INSPECT_PY = [[
import sys, json, math

def _fmt(v):
    try:
        return float(v)
    except Exception:
        return None

expr = sys.argv[1]
try:
    import torch
    import numpy as np

    obj = eval(expr, {"__builtins__": __builtins__}, {})

    if isinstance(obj, torch.Tensor):
        flat = obj.detach().cpu().float().numpy().flatten()
        sample = flat[:2048].tolist()
        result = {
            "name":    expr,
            "shape":   list(obj.shape),
            "dtype":   str(obj.dtype),
            "min":     float(flat.min())  if len(flat) > 0 else None,
            "max":     float(flat.max())  if len(flat) > 0 else None,
            "mean":    float(flat.mean()) if len(flat) > 0 else None,
            "std":     float(flat.std())  if len(flat) > 0 else None,
            "has_nan": bool(torch.isnan(obj).any()),
            "has_inf": bool(torch.isinf(obj).any()),
            "values":  sample,
            "source":  "python_eval",
        }
    elif isinstance(obj, np.ndarray):
        flat = obj.flatten().astype(float)
        sample = flat[:2048].tolist()
        result = {
            "name":    expr,
            "shape":   list(obj.shape),
            "dtype":   str(obj.dtype),
            "min":     float(flat.min())  if len(flat) > 0 else None,
            "max":     float(flat.max())  if len(flat) > 0 else None,
            "mean":    float(flat.mean()) if len(flat) > 0 else None,
            "std":     float(flat.std())  if len(flat) > 0 else None,
            "has_nan": bool(np.isnan(flat).any()),
            "has_inf": bool(np.isinf(flat).any()),
            "values":  sample,
            "source":  "python_eval",
        }
    else:
        result = {"error": "not a tensor or ndarray", "name": expr}
except Exception as e:
    result = {"error": str(e), "name": expr}

print(json.dumps(result))
]]

-- ── Python evaluation ─────────────────────────────────────────────────────────

--- Write helper script to a temp file.
---@return string path
local function get_script()
  local tmp = vim.fn.tempname() .. "_mlbuddy_inspect.py"
  vim.fn.writefile(vim.split(INSPECT_PY, "\n"), tmp)
  return tmp
end

--- Inspect a Python expression in the given virtual env / interpreter.
---@param expr    string    Python expression to evaluate
---@param python  string    Python executable (e.g. "python3")
---@param cb      fun(info: TensorInfo|nil)
local function inspect_expr(expr, python, cb)
  local script = get_script()
  local out    = {}

  vim.system(
    { python, script, expr },
    { text = true, stdout = function(_, d) if d then out[#out + 1] = d end end },
    function(res)
      vim.fn.delete(script)
      vim.schedule(function()
        if res.code ~= 0 then return cb(nil) end
        local body = table.concat(out)
        local d    = require("mlbuddy.util").json_decode(body)
        if not d or d.error then
          if d and d.error then
            vim.notify("[mlbuddy] Inspect error: " .. d.error, vim.log.levels.WARN)
          end
          return cb(nil)
        end
        cb(d)
      end)
    end
  )
end

-- ── DAP integration ───────────────────────────────────────────────────────────

--- Hook into nvim-dap to auto-inspect tensors at breakpoints.
---@param cfg table
local function setup_dap_hooks(cfg)
  local ok, dap = pcall(require, "dap")
  if not ok then return end

  -- When DAP stops (breakpoint / step), grab the REPL evaluation
  dap.listeners.after.event_stopped["mlbuddy_dataloader"] = function(session, body)
    if not cfg.dataloader.auto_inspect then return end
    if not (ctx.win and vim.api.nvim_win_is_valid(ctx.win)) then return end

    -- Get word under cursor (most likely a tensor variable)
    local word = vim.fn.expand("<cword>")
    if word == "" then return end

    -- Use DAP's evaluate request to inspect in the current frame
    local frame = session.current_frame or {}
    session:request("evaluate", {
      expression  = string.format(
        "__import__('json').dumps({'shape': list(%s.shape), 'dtype': str(%s.dtype), "
        .. "'min': float(%s.min()), 'max': float(%s.max()), "
        .. "'mean': float(%s.mean()), 'std': float(%s.std()), "
        .. "'has_nan': bool(__import__('torch').isnan(%s).any()), "
        .. "'has_inf': bool(__import__('torch').isinf(%s).any()), "
        .. "'values': %s.detach().cpu().flatten()[:2048].tolist()})",
        word, word, word, word, word, word, word, word, word
      ),
      context     = "repl",
      frameId     = frame.id,
    }, function(err, response)
      if err or not (response and response.result) then return end

      -- DAP returns the JSON as a Python string repr; strip outer quotes
      local raw = response.result:gsub('^"', ""):gsub('"$', ""):gsub('\\"', '"')
      local d   = require("mlbuddy.util").json_decode(raw)
      if not d then return end

      d.name   = word
      d.source = "DAP"
      ctx.tensors = { d }

      if ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf) then
        renderer.redraw(ctx.buf, ctx.tensors, cfg)
      end
    end)
  end
end

-- ── Toggle ────────────────────────────────────────────────────────────────────

---@param cfg table
function M.toggle(cfg)
  if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
    vim.api.nvim_win_close(ctx.win, true)
    ctx.win = nil
    return
  end

  local buf, win = renderer.open(ctx.tensors, cfg)
  ctx.buf = buf
  ctx.win = win

  local km = cfg.dataloader.keymaps
  ui.map(buf, km.close or "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
      ctx.win = nil
    end
  end, "Close DataLoader panel")

  ui.map(buf, "R", function()
    renderer.redraw(buf, ctx.tensors, cfg)
  end, "Re-render")

  ui.map(buf, "<Tab>", function()
    if #ctx.tensors == 0 then return end
    -- Rotate tensor list
    local first = table.remove(ctx.tensors, 1)
    ctx.tensors[#ctx.tensors + 1] = first
    renderer.redraw(buf, ctx.tensors, cfg)
  end, "Next tensor")

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer  = buf,
    once    = true,
    callback = function() ctx.win = nil end,
  })
end

-- ── Cursor-word inspect ───────────────────────────────────────────────────────

--- Inspect the expression under the cursor using a Python subprocess.
---@param cfg table
function M.inspect_cursor(cfg)
  local word = vim.fn.expand("<cword>")
  if word == "" then
    vim.notify("[mlbuddy] No word under cursor", vim.log.levels.WARN)
    return
  end

  -- Detect virtualenv python
  local python = vim.fn.exepath("python3") ~= "" and "python3" or "python"
  local venv_py = vim.fn.getcwd() .. "/.venv/bin/python"
  if vim.fn.executable(venv_py) == 1 then python = venv_py end

  vim.notify("[mlbuddy] Inspecting: " .. word, vim.log.levels.INFO)

  inspect_expr(word, python, function(info)
    if not info then return end
    -- Prepend to tensor list
    table.insert(ctx.tensors, 1, info)
    if #ctx.tensors > 8 then table.remove(ctx.tensors) end

    if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
      renderer.redraw(ctx.buf, ctx.tensors, cfg)
    else
      M.toggle(cfg)
    end
  end)
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param cfg table
function M.setup_autocmds(cfg)
  if cfg.dataloader.auto_inspect then
    -- Lazy-setup DAP hooks once DAP is actually loaded
    vim.api.nvim_create_autocmd("User", {
      pattern  = "DapAttach",
      once     = false,
      callback = function() setup_dap_hooks(cfg) end,
      group    = vim.api.nvim_create_augroup("MlbuddyDataLoader", { clear = true }),
    })
    -- Also try immediately if DAP is already loaded
    if package.loaded["dap"] then setup_dap_hooks(cfg) end
  end
end

return M
