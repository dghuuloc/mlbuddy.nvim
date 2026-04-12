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

--- Inspect a Python expression in the given virtual env / interpreter.
---@param expr    string    Python expression to evaluate
---@param python  string    Python executable
---@param cb      fun(info: TensorInfo|nil)
local function inspect_expr(expr, python, cb)
  local script = require("mlbuddy.util").write_py_script(INSPECT_PY, "_mlbuddy_inspect.py")
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
--- Only fires when the DataLoader panel is already open AND
--- the session is debugging an ML file.
---@param cfg table
local function setup_dap_hooks(cfg)
  local guard = require("mlbuddy.guard")

  guard.register_dap_listener(
    "mlbuddy_dataloader",
    cfg,
    cfg.dataloader.auto_inspect,  -- must be explicitly true
    "dataloader",                 -- panel must be open
    function(session, _)
      -- Extra check: panel window must still be valid
      if not (ctx.win and vim.api.nvim_win_is_valid(ctx.win)) then return end

      local word = vim.fn.expand("<cword>")
      if word == "" then return end

      local frame = session.current_frame or {}
      session:request("evaluate", {
        expression = string.format(
          "__import__('json').dumps({'shape': list(%s.shape), 'dtype': str(%s.dtype), "
          .. "'min': float(%s.min()), 'max': float(%s.max()), "
          .. "'mean': float(%s.mean()), 'std': float(%s.std()), "
          .. "'has_nan': bool(__import__('torch').isnan(%s).any()), "
          .. "'has_inf': bool(__import__('torch').isinf(%s).any()), "
          .. "'values': %s.detach().cpu().flatten()[:2048].tolist()})",
          word, word, word, word, word, word, word, word, word
        ),
        context = "repl",
        frameId = frame.id,
      }, function(err, response)
        if err or not (response and response.result) then return end
        local raw = response.result:gsub('^"',""):gsub('"$',""):gsub('\\"','"')
        local d   = require("mlbuddy.util").json_decode(raw)
        if not d then return end
        d.name = word; d.source = "DAP"
        ctx.tensors = { d }
        if ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf) then
          renderer.redraw(ctx.buf, ctx.tensors, cfg)
        end
      end)
    end
  )
end

-- ── Toggle ────────────────────────────────────────────────────────────────────

---@param cfg table
function M.toggle(cfg)
  local guard = require("mlbuddy.guard")

  if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
    vim.api.nvim_win_close(ctx.win, true)
    ctx.win = nil
    guard.panel_closed("dataloader")
    return
  end

  local buf, win = renderer.open(ctx.tensors, cfg)
  ctx.buf = buf
  ctx.win = win
  guard.panel_opened("dataloader")

  local km = cfg.dataloader.keymaps
  ui.map(buf, km.close or "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
      ctx.win = nil
      guard.panel_closed("dataloader")
    end
  end, "Close DataLoader panel")

  ui.map(buf, "R", function()
    renderer.redraw(buf, ctx.tensors, cfg)
  end, "Re-render")

  ui.map(buf, "<Tab>", function()
    if #ctx.tensors == 0 then return end
    local first = table.remove(ctx.tensors, 1)
    ctx.tensors[#ctx.tensors + 1] = first
    renderer.redraw(buf, ctx.tensors, cfg)
  end, "Next tensor")

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer  = buf,
    once    = true,
    callback = function()
      ctx.win = nil
      guard.panel_closed("dataloader")
    end,
  })
end

-- ── Cursor-word inspect ───────────────────────────────────────────────────────

---@param cfg table
function M.inspect_cursor(cfg)
  local word = vim.fn.expand("<cword>")
  if word == "" then
    vim.notify("[mlbuddy] No word under cursor", vim.log.levels.WARN)
    return
  end

  local python = require("mlbuddy.platform").find_python()
  vim.notify("[mlbuddy] Inspecting: " .. word, vim.log.levels.INFO)

  inspect_expr(word, python, function(info)
    if not info then return end
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
  local ag = vim.api.nvim_create_augroup("MlbuddyDataLoader", { clear = true })

  -- Clean up guard cache on buffer delete
  vim.api.nvim_create_autocmd("BufDelete", {
    group   = ag,
    pattern = "*.py",
    callback = function(ev)
      require("mlbuddy.guard").clear_cache(ev.buf)
    end,
  })

  -- Only register DAP hooks if auto_inspect is explicitly enabled.
  -- With auto_inspect=false (default), mlbuddy never touches DAP sessions.
  if cfg.dataloader.auto_inspect then
    local function register()
      setup_dap_hooks(cfg)
    end
    -- Wait for DapAttach so we don't pollute the dap.listeners table at startup
    vim.api.nvim_create_autocmd("User", {
      group   = ag,
      pattern = "DapAttach",
      once    = false,
      callback = register,
    })
    -- Also register if DAP is already loaded
    if package.loaded["dap"] then register() end
  end
end

return M
