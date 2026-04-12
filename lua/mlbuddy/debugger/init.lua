--- mlbuddy/debugger/init.lua
--- Model debugger: activations, gradients, weight stats, NaN detection.
--- Integrates with DAP (auto-debug on breakpoint) and manual <leader>mdb.
local renderer = require("mlbuddy.debugger.renderer")
local ui       = require("mlbuddy.ui")
local util     = require("mlbuddy.util")
local plat     = require("mlbuddy.platform")
local M        = {}

local NS_VIRT = vim.api.nvim_create_namespace("mlbuddy_debug_virt")

-- ── State ─────────────────────────────────────────────────────────────────

local ctx = {
  win  = nil,
  buf  = nil,
  data = nil,   -- last JSON result from hook.py
  view = "summary",
  expr = nil,   -- last inspected expression
}

-- ── Hook script path ──────────────────────────────────────────────────────

--- Return path to the bundled hook.py.
--- Works whether the plugin is in runtimepath or loaded via lazy.nvim.
local function hook_script()
  -- 1. Try to find via the Lua module path (reliable)
  local info = debug.getinfo(1, "S")
  if info and info.source then
    local dir = info.source:match("^@(.+)/lua/")
    if dir then
      local p = dir .. "/lua/mlbuddy/debugger/hook.py"
      if vim.fn.filereadable(p) == 1 then return p end
    end
  end
  -- 2. Search runtimepath
  for _, rtp in ipairs(vim.api.nvim_list_runtime_paths()) do
    local p = rtp .. "/lua/mlbuddy/debugger/hook.py"
    if vim.fn.filereadable(p) == 1 then return p end
  end
  -- 3. Relative fallback (development layout)
  local cwd_p = vim.fn.getcwd() .. "/lua/mlbuddy/debugger/hook.py"
  if vim.fn.filereadable(cwd_p) == 1 then return cwd_p end
  return nil
end

-- ── Run hook.py ───────────────────────────────────────────────────────────

---@param expr   string   Python expression for the model
---@param mode   string   "full"|"activations"|"gradients"|"weights"|"nan"|"shapes"
---@param python string
---@param cb     fun(data:table)
local function run_hook(expr, mode, python, cb)
  local script = hook_script()
  local temp_script = false

  if not script then
    -- Copy bundled script to temp file
    local src_lines = vim.fn.readfile(
      debug.getinfo(1,"S").source:match("^@(.+)$"):gsub("init%.lua$","") .. "hook.py")
    script = util.write_py_script(src_lines, "_mlb_debug_hook.py")
    temp_script = true
  end

  local out = {}
  vim.system({ python, script, expr, mode }, {
    text = true,
    stdout = function(_, d) if d then out[#out+1] = d end end,
  }, function(r)
    if temp_script then
      vim.fn.delete(script)
    end
    vim.schedule(function()
      local body = table.concat(out)
      local data = util.json_decode(body)
      cb(data or { error = "parse failed: " .. body:sub(1,200) })
    end)
  end)
end

-- ── Virtual text annotations ──────────────────────────────────────────────

--- Attach per-layer activation shapes as virtual EOL text on source lines.
---@param bufnr integer   Python source buffer
---@param data  table     hook.py result
local function attach_virt(bufnr, data)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, NS_VIRT, 0, -1)

  -- Build a quick lookup: layer name → output shape string
  local layer_shapes = {}
  for _, l in ipairs(data.layers or {}) do
    if l.type == "activation" and l.activation then
      layer_shapes[l.name] = {
        shape   = l.activation.shape,
        has_nan = l.activation.has_nan,
        has_inf = l.activation.has_inf,
        zeros   = l.activation.zeros_pct,
      }
    end
  end

  -- Walk source lines looking for `self.xxx(` patterns
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for lnum, line in ipairs(lines) do
    -- Match  self.layer_name(  or  self.layer_name (
    local attr = line:match("self%.([%w_]+)%s*%(")
    if attr then
      local info = layer_shapes[attr]
        or layer_shapes["features." .. attr]
        or layer_shapes["backbone." .. attr]
      if info then
        local shape_txt = "→ " .. table.concat(info.shape or {}, "×")
        local hl = "MlbuddyDim"
        if info.has_nan or info.has_inf then
          shape_txt = shape_txt .. " ⚠NaN"
          hl = "MlbuddyError"
        elseif (info.zeros or 0) > 80 then
          shape_txt = shape_txt .. string.format(" ⚠%.0f%%dead", info.zeros)
          hl = "MlbuddyWarn"
        end
        ui.virt(bufnr, NS_VIRT, lnum - 1, "  " .. shape_txt, hl)
      end
    end
  end
end

-- ── Toggle ────────────────────────────────────────────────────────────────

---@param cfg table
function M.toggle(cfg)
  local guard = require("mlbuddy.guard")

  if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
    vim.api.nvim_win_close(ctx.win, true)
    ctx.win = nil
    guard.panel_closed("debugger")
    return
  end

  if ctx.data then
    local buf, win = renderer.open(ctx.data, ctx.view, cfg)
    ctx.buf = buf; ctx.win = win
    guard.panel_opened("debugger")
    M._install_keymaps(cfg)
    return
  end

  M.debug_cursor(cfg)
end

--- Inspect the model expression under the cursor.
---@param cfg  table
---@param expr string|nil  override expression
---@param mode string|nil  override mode
function M.debug_expr(cfg, expr, mode)
  expr = expr or vim.fn.expand("<cword>")
  mode = mode or "full"
  if expr == "" then
    ui.warn("No model expression — position cursor on a model variable"); return
  end

  ctx.expr = expr
  local python = cfg.debugger and cfg.debugger.python or plat.find_python()

  -- Placeholder
  if ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf) then
    ui.set_lines(ctx.buf, { "", "  Inspecting model '" .. expr .. "'  mode=" .. mode .. " …" })
  else
    local buf, win = ui.float({
      title  = "󰃤  Model Debugger",
      width  = cfg.width  or 84,
      height = cfg.height or 44,
      border = cfg.border,
    })
    ctx.buf = buf; ctx.win = win
    ui.set_lines(buf, { "", "  Inspecting model '" .. expr .. "'  mode=" .. mode .. " …" })
    M._install_keymaps(cfg)
  end

  run_hook(expr, mode, python, function(data)
    ctx.data = data
    ctx.view = "summary"
    renderer.redraw(ctx.buf, data, ctx.view, cfg)

    -- Attach virtual text to current Python buffer
    local src_buf = vim.api.nvim_get_current_buf()
    if vim.bo[src_buf].filetype == "python" then
      attach_virt(src_buf, data)
    end

    -- Notify about issues
    local issues = data.issues or {}
    if #issues > 0 then
      ui.warn(string.format("Model '%s': %d issue%s found — check debugger panel",
        expr, #issues, #issues == 1 and "" or "s"))
    else
      ui.info(string.format("Model '%s' looks healthy ✓", expr))
    end
  end)
end

--- Alias for ergonomic use from keymaps
function M.debug_cursor(cfg)
  M.debug_expr(cfg, nil, "full")
end

--- Quick NaN-only check (faster).
function M.check_nan(cfg)
  M.debug_expr(cfg, nil, "nan")
end

--- Show only gradient flow.
function M.debug_gradients(cfg)
  M.debug_expr(cfg, nil, "gradients")
end

-- ── DAP integration ───────────────────────────────────────────────────────

--- Hook into nvim-dap: auto-debug model at breakpoints.
--- Only fires when auto_inspect=true AND the debugger panel is already open
--- AND the session is debugging an ML file.
---@param cfg table
function M.setup_dap(cfg)
  local guard = require("mlbuddy.guard")

  guard.register_dap_listener(
    "mlbuddy_debugger",
    cfg,
    cfg.debugger and cfg.debugger.auto_inspect or false,
    "debugger",   -- only when debugger panel is open
    function(session, _)
      if not (ctx.win and vim.api.nvim_win_is_valid(ctx.win)) then return end

      local candidates = (cfg.debugger and cfg.debugger.model_vars)
        or { "model", "self", "net", "module" }
      local frame = session.current_frame or {}

      for _, var in ipairs(candidates) do
        session:request("evaluate", {
          expression = "type(" .. var .. ").__name__",
          context    = "repl",
          frameId    = frame.id,
        }, function(err, resp)
          if not err and resp and resp.result and resp.result:match("Module") then
            M.debug_expr(cfg, var, "full")
          end
        end)
      end
    end
  )
end

-- ── Keymaps inside the float ──────────────────────────────────────────────

function M._install_keymaps(cfg)
  local buf   = ctx.buf
  local guard = require("mlbuddy.guard")
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local km = cfg.debugger and cfg.debugger.keymaps or {}

  local function switch_view(v)
    ctx.view = v
    if ctx.data then renderer.redraw(buf, ctx.data, v, cfg) end
  end

  ui.map(buf, km.close or "q", function()
    if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
      vim.api.nvim_win_close(ctx.win, true)
      ctx.win = nil
      guard.panel_closed("debugger")
    end
  end, "Close debugger")

  ui.map(buf, "1", function() switch_view("summary")     end, "Summary view")
  ui.map(buf, "2", function() switch_view("activations") end, "Activations view")
  ui.map(buf, "3", function() switch_view("gradients")   end, "Gradients view")
  ui.map(buf, "4", function() switch_view("weights")     end, "Weights view")

  ui.map(buf, "R", function()
    if ctx.expr then M.debug_expr(cfg, ctx.expr, "full")
    else ui.warn("No expression stored — use :MlbuddyDebug <expr>") end
  end, "Re-run hook")

  ui.map(buf, "e", function()
    vim.ui.input({ prompt="Model expression: ", default=ctx.expr or "model" }, function(s)
      if s and s ~= "" then M.debug_expr(cfg, s, "full") end
    end)
  end, "Change expression")

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer=buf, once=true,
    callback=function()
      ctx.win = nil
      guard.panel_closed("debugger")
    end,
  })
end

-- ── Setup ─────────────────────────────────────────────────────────────────

---@param cfg table
function M.setup_autocmds(cfg)
  local ag = vim.api.nvim_create_augroup("MlbuddyDebugger", { clear=true })

  vim.api.nvim_create_autocmd("BufDelete", {
    group   = ag,
    pattern = "*.py",
    callback = function(ev)
      if vim.api.nvim_buf_is_valid(ev.buf) then
        vim.api.nvim_buf_clear_namespace(ev.buf, NS_VIRT, 0, -1)
      end
      require("mlbuddy.guard").clear_cache(ev.buf)
    end,
  })

  -- DAP hooks only when explicitly enabled (default: false — does NOT touch
  -- regular Python debugging sessions)
  if cfg.debugger and cfg.debugger.auto_inspect then
    local function register() M.setup_dap(cfg) end
    if package.loaded["dap"] then register()
    else
      vim.api.nvim_create_autocmd("User", {
        group=ag, pattern="DapAttach", once=false,
        callback=register,
      })
    end
  end
end

return M
