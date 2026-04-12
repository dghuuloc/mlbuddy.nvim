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
  win     = nil,
  buf     = nil,
  data    = nil,            -- last JSON result from hook.py
  view    = "summary",
  expr    = nil,            -- last inspected expression
  src_buf = nil,
  req_id  = 0,
}

local function close_panel()
  local guard = require("mlbuddy.guard")

  if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
    pcall(vim.api.nvim_win_close, ctx.win, true)
  end

  ctx.win = nil
  ctx.buf = nil
  guard.panel_closed("debugger")
end

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

---@param expr string   Python expression for the model
---@param mode string   "full"|"activations"|"gradients"|"weights"|"nan"|"shapes"
---@param python string
---@param cfg table
---@param cb fun(data:table)
local function run_hook(expr, mode, python, cfg, cb)
  if not python or python == "" then
    vim.schedule(function()
      cb({ error = "Python executable not found" })
    end)
    return
  end

  local script = hook_script()
  local temp_script = false

  if not script then
    local init_path = debug.getinfo(1, "S").source:match("^@(.+)$")
    local hook_src = init_path and init_path:gsub("init%.lua$", "hook.py") or nil
    if not hook_src or vim.fn.filereadable(hook_src) ~= 1 then
      vim.schedule(function()
        cb({ error = "hook.py not found" })
      end)
      return
    end

    local src_lines = vim.fn.readfile(hook_src)
    script = util.write_py_script(src_lines, "_mlb_debug_hook.py")
    temp_script = true
  end

  local dbg_cfg = cfg.debugger or {}
  local out, err = {}, {}
  vim.system({ python, script, expr, mode }, {
    text = true,
    env = {
      MLBUDDY_DUMMY_BATCH_SIZE = tostring(dbg_cfg.dummy_batch_size or 1),
      MLBUDDY_DUMMY_SEQ_LEN = tostring(dbg_cfg.dummy_seq_len or 16),
      MLBUDDY_DUMMY_IMAGE_SIZE = tostring(dbg_cfg.dummy_image_size or 224),
    },
    stdout = function(_, d) if d then out[#out + 1] = d end end,
    stderr = function(_, d) if d then err[#err + 1] = d end end,
  }, function(r)
    if temp_script then
      pcall(vim.fn.delete, script)
    end

    vim.schedule(function()
      local body = table.concat(out)
      local stderr_body = table.concat(err):gsub("%s+$", "")

      if r.code ~= 0 then
        cb({
          error = ("hook.py exited with code %d"):format(r.code),
          stderr = stderr_body ~= "" and stderr_body or nil,
          stdout = body ~= "" and body:sub(1, 1000) or nil,
          expr = expr,
          mode = mode,
        })
        return
      end

      local data = util.json_decode(body)
      if type(data) ~= "table" then
        cb({
          error = "parse failed: " .. body:sub(1, 300),
          stderr = stderr_body ~= "" and stderr_body or nil,
          stdout = body ~= "" and body:sub(1, 1000) or nil,
          expr = expr,
          mode = mode,
        })
        return
      end

      if stderr_body ~= "" then
        data.stderr = stderr_body
      end
      cb(data)
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
    -- vim.api.nvim_win_close(ctx.win, true)
    -- ctx.win = nil
    -- guard.panel_closed("debugger")
    close_panel()
    return
  end

  if ctx.data then
    local buf, win = renderer.open(ctx.data, ctx.view, cfg)
    ctx.buf = buf
    ctx.win = win
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
  mode = mode or (cfg.debugger and cfg.debugger.default_mode) or "full"
  if expr == "" then
    ui.warn("No model expression — position cursor on a model variable")
    return
  end

  ctx.expr = expr
  local python = cfg.debugger and cfg.debugger.python or plat.find_python()
  if not python or python == "" then
    ui.warn("No Python executable found for model debugger")
    return
  end

  ctx.req_id = ctx.req_id + 1
  local req_id = ctx.req_id

  local current_buf = vim.api.nvim_get_current_buf()
  ctx.src_buf = vim.bo[current_buf].filetype == "python" and current_buf or nil

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
    ctx.buf = buf
    ctx.win = win
    ui.set_lines(buf, { "", "  Inspecting model '" .. expr .. "'  mode=" .. mode .. " …" })
    M._install_keymaps(cfg)
  end

  local guard = require("mlbuddy.guard")
  guard.panel_opened("debugger")

  run_hook(expr, mode, python, cfg, function(data)
    if req_id ~= ctx.req_id then
      return
    end

    ctx.data = data
    ctx.view = "summary"

    if ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf) then
      renderer.redraw(ctx.buf, data, ctx.view, cfg)
    end

    if cfg.debugger == nil or cfg.debugger.virt_text ~= false then
      local src_buf = ctx.src_buf
      if src_buf and vim.api.nvim_buf_is_valid(src_buf) and vim.bo[src_buf].filetype == "python" then
        attach_virt(src_buf, data)
      end
    end

    if data.error then
      ui.warn(string.format("Model '%s' inspection failed: %s", expr, tostring(data.error)))
      return
    end

    local issues = data.issues or {}
    if #issues > 0 then
      ui.warn(string.format("Model '%s': %d issue%s found — check debugger panel", expr, #issues, #issues == 1 and "" or "s"))
    elseif cfg.debugger and cfg.debugger.notify_on_success then
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
      local eval_req_id = ctx.req_id + 1
      local matched = false

      ctx.req_id = eval_req_id

      for _, var in ipairs(candidates) do
        session:request("evaluate", {
          expression = ("isinstance(%s, __import__('torch').nn.Module)"):format(var),
          context    = "repl",
          frameId    = frame.id,
        }, function(err, resp)
          if matched or eval_req_id ~= ctx.req_id then
            return
          end

          if not err and resp and resp.result then
            local result = tostring(resp.result):gsub("^%s+", ""):gsub("%s+$", "")
            if result == "True" then
              matched = true
              M.debug_expr(cfg, var, "full")
            end
          end
        end)
      end
    end
  )
end

-- ── Keymaps inside the float ──────────────────────────────────────────────

function M._install_keymaps(cfg)
  local buf   = ctx.buf
  -- local guard = require("mlbuddy.guard")
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local km = cfg.debugger and cfg.debugger.keymaps or {}

  local function switch_view(v)
    ctx.view = v
    if ctx.data then renderer.redraw(buf, ctx.data, v, cfg) end
  end

  ui.map(buf, km.close or "q", function()
    -- if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
    --   vim.api.nvim_win_close(ctx.win, true)
    --   ctx.win = nil
    --   guard.panel_closed("debugger")
    -- end
    close_panel()
  end, "Close debugger")

  ui.map(buf, "1", function() switch_view("summary")     end, "Summary view")
  ui.map(buf, "2", function() switch_view("activations") end, "Activations view")
  ui.map(buf, "3", function() switch_view("gradients")   end, "Gradients view")
  ui.map(buf, "4", function() switch_view("weights")     end, "Weights view")

  ui.map(buf, "R", function()
    if ctx.expr then
      M.debug_expr(cfg, ctx.expr, (cfg.debugger and cfg.debugger.default_mode) or "full")
    else
      ui.warn("No expression stored — use :MlbuddyDebug <expr>")
    end
  end, "Re-run hook")

  ui.map(buf, "e", function()
    vim.ui.input({ prompt = "Model expression: ", default = ctx.expr or "model" }, function(s)
      if s and s ~= "" then M.debug_expr(cfg, s, "full") end
    end)
  end, "Change expression")

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = buf,
    once = true,
    callback = function()
      close_panel()
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
    if package.loaded["dap"] then
      register()
    else
      vim.api.nvim_create_autocmd("User", {
        group=ag,
        pattern="DapAttach",
        once=false,
        callback=register,
      })
    end
  end
end

return M
