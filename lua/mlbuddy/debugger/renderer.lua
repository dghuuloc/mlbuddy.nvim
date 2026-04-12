--- mlbuddy/debugger/renderer.lua
--- Renders the model debug panel: activations, gradients, shapes, weight stats, issues.
local ui   = require("mlbuddy.ui")
local util = require("mlbuddy.util")
local M    = {}

local NS = vim.api.nvim_create_namespace("mlbuddy_debug")

-- ── Helpers ────────────────────────────────────────────────────────────────

local function fmt(v, prec)
  if v == nil then return "?" end
  if v == "nan" then return "NaN" end
  if v == "inf" then return "+Inf" end
  if v == "-inf" then return "-Inf" end
  prec = prec or 5
  local n = tonumber(v)
  if not n then return tostring(v) end
  if math.abs(n) >= 1e4 or (math.abs(n) < 1e-3 and n ~= 0) then
    return ("%.2e"):format(n)
  end
  return ("%." .. prec .. "g"):format(n)
end

local function shape_str(shape)
  if not shape or #shape == 0 then return "[]" end
  return "[" .. table.concat(shape, "×") .. "]"
end

-- Severity colour
local function issue_hl(text)
  if text:match("[Nn]a[Nn]") or text:match("[Ii]nf") or text:match("explod") then
    return "MlbuddyError"
  elseif text:match("vanish") or text:match("dead") or text:match("large") then
    return "MlbuddyWarn"
  end
  return "MlbuddyDim"
end

-- Mini bar (0..1)
local function mini_bar(v, w)
  if type(v) ~= "number" then return string.rep("░", w) end
  local filled = math.floor(util.clamp(v, 0, 1) * w + 0.5)
  return string.rep("█", filled) .. string.rep("░", w - filled)
end

local function truncate_text(text, limit)
  if not text or text == "" then return nil end
  local clean = tostring(text):gsub("\r\n", "\n"):gsub("\r", "\n")
  if limit and #clean > limit then
    return clean:sub(1, limit) .. " …"
  end
  return clean
end

-- ── Section builders ────────────────────────────────────────────────────────

local function push_rule(lines, hls, W, ch)
  local row = #lines
  lines[#lines+1] = string.rep(ch or "─", W)
  hls[#hls+1] = { row = row, c0 = 0, c1 = -1, hl = "MlbuddyDim" }
end

local function push(lines, hls, text, hl_list)
  local row = #lines
  lines[#lines+1] = text
  if hl_list then
    for _, h in ipairs(hl_list) do
      h.row=row
      hls[#hls+1]=h
    end
  end
end

local function push_block(lines, hls, title, text, title_hl, body_hl, W)
  local content = truncate_text(text, W * 12)
  if not content then return end
  push(lines, hls, "  " .. title, { { c0 = 0, c1 = -1, hl = title_hl or "MlbuddyWarn" } })
  for line in (content .. "\n"):gmatch("(.-)\n") do
    push(lines, hls, "    " .. line, { { c0 = 0, c1 = -1, hl = body_hl or "MlbuddyDim" } })
  end
end

-- ── Issues summary ──────────────────────────────────────────────────────────

local function section_issues(data, lines, hls, W)
  local issues = data.issues or {}
  if #issues == 0 then
    push(lines, hls, "  ✓  No issues detected",
      { { c0=2, c1=4, hl="MlbuddyGood" } })
    return
  end
  push(lines, hls, string.format("  ⚠  %d issue%s found:", #issues, #issues==1 and "" or "s"),
    { { c0=0, c1=-1, hl="MlbuddyWarn" } })
  for _, issue in ipairs(issues) do
    push(lines, hls, "    • " .. issue,
      { { c0=0, c1=-1, hl=issue_hl(issue) } })
  end
end

-- ── Activation / shape table ────────────────────────────────────────────────

local function section_activations(data, lines, hls, W)
  local layers = data.layers or {}
  local act_layers = {}
  for _, l in ipairs(layers) do
    if l.type == "activation" and l.activation then
      act_layers[#act_layers+1] = l
    end
  end
  if #act_layers == 0 then
    push(lines, hls, "  (no forward pass data — model needed a dummy input)",
      { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
    return
  end

  -- Header
  push(lines, hls,
    string.format("  %-24s  %-16s  %8s  %8s  %8s  %6s  %s",
      "Layer", "Shape", "Mean", "Std", "Norm", "0%", "Issues"),
    { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
  push_rule(lines, hls, W, "╌")

  for _, l in ipairs(act_layers) do
    local a      = l.activation
    local shape  = shape_str(a.shape)
    local issues = ""
    local hl     = "Normal"
    if a.has_nan then issues="NaN!"; hl="MlbuddyError"
    elseif a.has_inf then issues="Inf!"; hl="MlbuddyError"
    elseif (a.zeros_pct or 0) > 80 then issues=string.format("dead %.0f%%", a.zeros_pct); hl="MlbuddyWarn"
    end

    local line = string.format("  %-24s  %-16s  %8s  %8s  %8s  %5.1f%%  %s",
      l.name:sub(1,24),
      shape:sub(1,16),
      fmt(a.mean), fmt(a.std), fmt(a.norm),
      a.zeros_pct or 0,
      issues)
    push(lines, hls, line, {
      { c0 = 2, c1 = 26, hl = "MlbuddyIdent" },
      { c0 = 28, c1 = 44, hl = "MlbuddyLayer" },
      { c0 = 44, c1 = -1, hl = hl ~= "Normal" and hl or "MlbuddyMetric" },
    })
  end
end

-- ── Gradient flow ───────────────────────────────────────────────────────────

local function section_gradients(data, lines, hls, W)
  local gf = data.gradient_flow
  if not gf or #gf == 0 then
    push(lines, hls, "  (no gradients — run a backward pass first or use :MlbuddyDebugStep)",
      { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
    return
  end

  -- Find max norm for bar scaling
  local max_norm = 1e-10
  for _, g in ipairs(gf) do
    if type(g.grad_norm) == "number" and g.grad_norm > max_norm then
      max_norm = g.grad_norm
    end
  end

  push(lines, hls,
    string.format("  %-32s  %10s  %10s  %8s  %s", "Parameter", "Grad Norm", "Grad Max", "Bar", "Status"),
    { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
  push_rule(lines, hls, W, "╌")

  for _, g in ipairs(gf) do
    local gn    = type(g.grad_norm) == "number" and g.grad_norm or 0
    local bar = mini_bar(max_norm > 0 and (gn / max_norm) or 0, 10)
    local status, hl = "", "MlbuddyGood"
    if #(g.issues or {}) > 0 then
      status = g.issues[1]
      hl = issue_hl(status)
    end
    local line = string.format("  %-32s  %10s  %10s  %s  %s",
      g.name:sub(1,32), fmt(g.grad_norm), fmt(g.grad_max), bar, status)
    push(lines, hls, line, {
      { c0=2, c1=34, hl="MlbuddyIdent" },
      { c0=34, c1=55, hl="MlbuddyParam" },
      { c0=55, c1=-1, hl=hl },
    })
  end
end

-- ── Weight statistics ────────────────────────────────────────────────────────

local function section_weights(data, lines, hls, W)
  local layers = data.layers or {}
  for _, l in ipairs(layers) do
    if l.type ~= "activation" and l.params and next(l.params) then
      local type_str = l.type or "?"
      push(lines, hls, string.format("  %s  (%s)", l.name ~= "" and l.name or type_str, type_str),
        { { c0 = 2, c1 = -1, hl = "MlbuddyLayer" } })
      for pname, s in pairs(l.params) do
        local issues_str = #(s.issues or {}) > 0 and ("  ⚠ "..table.concat(s.issues,", ")) or ""
        local grad_str = s.grad_norm and ("  ∇"..fmt(s.grad_norm)) or ""
        local line = string.format("    %-12s  %-16s  mean=%8s  std=%8s  norm=%8s%s%s",
          pname, shape_str(s.shape),
          fmt(s.mean), fmt(s.std), fmt(s.norm),
          grad_str, issues_str)
        local hl = #(s.issues or {}) > 0 and "MlbuddyWarn" or "MlbuddyMetric"
        push(lines, hls, line, {
          { c0=4, c1=16, hl="MlbuddyDim" },
          { c0=16, c1=-1, hl=hl },
        })
      end
    end
  end
end

-- ── section_diagnostics ──────────────────────────────────────────────────────

local function section_diagnostics(data, lines, hls, W, cfg)
  local dbg_cfg = cfg.debugger or {}
  local limit = dbg_cfg.max_stderr_chars or 1200
  local shown = false

  local notes = data.notes or {}
  if #notes > 0 then
    shown = true
    push(lines, hls, "  ─── Notes ────────────────────────────────────────────────",
      { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
    for _, note in ipairs(notes) do
      push(lines, hls, "    • " .. note, { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
    end
  end

  local diagnostic_pairs = {
    { "Forward pass failed", data.forward_error, "MlbuddyWarn" },
    { "Run error", data.run_error, "MlbuddyWarn" },
    { "stderr", data.stderr, "MlbuddyWarn" },
    { "stdout", data.stdout, "MlbuddyDim" },
    { "Traceback", data.traceback, "MlbuddyError" },
  }

  for _, item in ipairs(diagnostic_pairs) do
    local title, text, hl = item[1], item[2], item[3]
    local truncated = truncate_text(text, limit)
    if truncated then
      if not shown then
        push(lines, hls, "  ─── Diagnostics ─────────────────────────────────────────",
          { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
        shown = true
      end
      push_block(lines, hls, title .. ":", truncated, hl, hl == "MlbuddyDim" and hl or "Normal", W)
    end
  end
end

-- ── Public: build_lines ──────────────────────────────────────────────────────

-- view: "summary" | "activations" | "gradients" | "weights"
---@param data  table    parsed JSON from hook.py
---@param view  string
---@param cfg   table
---@return string[], table[]
function M.build_lines(data, view, cfg)
  local W     = (cfg.width or 84) - 2
  local icons = cfg.icons or {}
  local lines, hls = {}, {}

  -- Header
  local model_info = data.model_class or "?"
  local total_p    = data.total_params and util.fmt_num(data.total_params) or "?"
  local train_p    = data.trainable_params and util.fmt_num(data.trainable_params) or "?"
  push(lines, hls,
    string.format("  󰃤  Model Debugger  ─  %s  (total: %s  trainable: %s)", model_info, total_p, train_p),
    { { c0=0, c1=-1, hl="MlbuddyTitle" } })

  push_rule(lines, hls, W)

  -- Error / forward-pass warning
  if data.error then
    push(lines, hls, "  Error: " .. tostring(data.error), { { c0 = 0, c1 = -1, hl = "MlbuddyError" } })
    section_diagnostics(data, lines, hls, W, cfg)
    goto footer
  end

  -- Tab header
  push(lines, hls, string.format(
    "  %s  %s  %s  %s",
    view=="summary"     and "[1 Summary▶]"    or " 1 Summary  ",
    view=="activations" and "[2 Activations▶]" or " 2 Activations",
    view=="gradients"   and "[3 Gradients▶]"  or " 3 Gradients",
    view=="weights"     and "[4 Weights▶]"    or " 4 Weights"
  ), { { c0=0, c1=-1, hl="MlbuddyDim" }, })
  push_rule(lines, hls, W, "╌")

  -- Section content
  if view == "summary" then
    push(lines, hls, "  ─── Issues ──────────────────────────────────────────────",
      { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
    section_issues(data, lines, hls, W)
    push(lines, hls, "")
    push(lines, hls, "  ─── Quick stats ──────────────────────────────────────────",
      { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
    local act_count = 0
    for _, l in ipairs(data.layers or {}) do
      if l.type == "activation" then act_count=act_count+1 end
    end
    push(lines, hls, string.format("  Layers with hooks:  %d", act_count),
      { { c0 = 0, c1 = -1, hl = "MlbuddyMetric" } })
    push(lines, hls, string.format("  Total params:       %s", total_p),
      { { c0 = 0, c1 = -1, hl = "MlbuddyMetric" } })
    push(lines, hls, string.format("  Trainable params:   %s", train_p),
      { { c0 = 0, c1 = -1, hl = "MlbuddyMetric" } })
    push(lines, hls, string.format("  Gradient flow data: %s",
      data.gradient_flow and (#data.gradient_flow .. " params") or "none (run backward first)"),
      { { c0 = 0, c1 = -1, hl = "MlbuddyMetric" } })
    section_diagnostics(data, lines, hls, W, cfg)

  elseif view == "activations" then
    push(lines, hls, "  ─── Activation stats (forward pass) ──────────────────────",
      { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
    section_activations(data, lines, hls, W)
    section_diagnostics(data, lines, hls, W, cfg)

  elseif view == "gradients" then
    push(lines, hls, "  ─── Gradient flow ─────────────────────────────────────────",
      { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
    section_gradients(data, lines, hls, W)
    section_diagnostics(data, lines, hls, W, cfg)

  elseif view == "weights" then
    push(lines, hls, "  ─── Weight statistics ─────────────────────────────────────",
      { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
    section_weights(data, lines, hls, W)
    section_diagnostics(data, lines, hls, W, cfg)
  end

  ::footer::
  push(lines, hls, "")
  push_rule(lines, hls, W)
  push(lines, hls,
    "  [1-4] switch view  [R] re-run  [q] close  [e] change expression",
    { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })

  return lines, hls
end

-- ── Public: open / redraw ───────────────────────────────────────────────────

---@param data  table
---@param view  string
---@param cfg   table
---@return integer buf, integer win
function M.open(data, view, cfg)
  local buf, win = ui.float({
    title  = "󰃤  Model Debugger",
    width  = cfg.width  or 84,
    height = cfg.height or 44,
    border = cfg.border,
  })
  M.redraw(buf, data, view, cfg)
  vim.bo[buf].filetype = "mlbuddy_debug"
  return buf, win
end

function M.redraw(buf, data, view, cfg)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local lines, hls = M.build_lines(data, view, cfg)
  ui.set_lines(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    local c1 = (h.c1 == -1) and (lines[h.row+1] and #lines[h.row+1] or 0) or h.c1
    vim.api.nvim_buf_add_highlight(buf, NS, h.hl, h.row, h.c0, c1)
  end
end

return M
