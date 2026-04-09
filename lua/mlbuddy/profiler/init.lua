--- mlbuddy/profiler/init.lua
--- Views PyTorch Profiler output: chrome trace JSON, .pt.trace.json, tensorboard logs.
local ui   = require("mlbuddy.ui")
local util = require("mlbuddy.util")
local M    = {}

local NS = vim.api.nvim_create_namespace("mlbuddy_prof")

-- ── Parse chrome trace JSON ───────────────────────────────────────────────────

---@class ProfilerOp
---@field name     string
---@field cat      string
---@field dur_us   number   microseconds
---@field self_us  number
---@field mem_b    number
---@field count    integer
---@field is_cuda  boolean

---@param trace_data table  parsed JSON
---@return ProfilerOp[]
local function parse_chrome_trace(trace_data)
  local events = trace_data.traceEvents or trace_data
  if not events then return {} end

  -- Aggregate by op name
  local ops = {}  -- name → ProfilerOp
  for _, e in ipairs(events) do
    if type(e) ~= "table" then goto skip end
    local dur  = e.dur   or 0
    local name = e.name  or ""
    local cat  = e.cat   or ""
    local args = e.args  or {}

    if dur <= 0 or name == "" then goto skip end
    if cat ~= "cpu_op" and cat ~= "cuda_runtime"
       and cat ~= "kernel" and cat ~= "user_annotation"
       and not name:match("^aten::") then goto skip end

    if not ops[name] then
      ops[name] = {
        name    = name, cat=cat,
        dur_us  = 0, self_us=0, mem_b=0, count=0,
        is_cuda = (cat == "kernel" or cat == "cuda_runtime"),
      }
    end
    local op = ops[name]
    op.dur_us = op.dur_us + dur
    op.count  = op.count  + 1
    if args.bytes_allocated then op.mem_b = op.mem_b + args.bytes_allocated end

    ::skip::
  end

  local list = {}
  for _, v in pairs(ops) do list[#list+1] = v end
  -- Compute self_us (approximate; no call-graph in chrome trace)
  for _, op in ipairs(list) do op.self_us = op.dur_us end
  return list
end

-- ── Sort helpers ──────────────────────────────────────────────────────────────

local SORT_KEYS = { "cuda_time", "cpu_time", "memory", "count" }

local function sort_ops(ops, by)
  local key
  if by == "cuda_time" or by == "cpu_time" then key = "dur_us"
  elseif by == "memory" then key = "mem_b"
  else key = "count" end

  local sorted = vim.deepcopy(ops)
  table.sort(sorted, function(a, b) return (a[key] or 0) > (b[key] or 0) end)
  return sorted
end

-- ── Build display lines ───────────────────────────────────────────────────────

local function fmt_us(us)
  if us >= 1e9 then return ("%.2fs"):format(us/1e6/1000) end
  if us >= 1e6 then return ("%.2fms"):format(us/1000) end
  return ("%.0fμs"):format(us)
end

local function build_lines(ops, sort_by, top_n, cfg)
  local W = (cfg.width or 84) - 4
  local lines = {}
  local hls   = {}

  local function push(text, hl_list)
    local row = #lines
    lines[#lines+1] = text
    if hl_list then for _, h in ipairs(hl_list) do h.row=row; hls[#hls+1]=h end end
  end

  push("  " .. (cfg.icons.profiler or "󰅱") .. "  Profiler  —  sort: " .. sort_by,
    { {c0=0, c1=-1, hl="MlbuddyTitle"} })
  push(string.rep("─", W))

  if #ops == 0 then
    push("  (no profile data — load a .pt.trace.json file with :MlbuddyProfiler <path>)",
      { {c0=0, c1=-1, hl="MlbuddyDim"} })
  else
    local sorted = sort_ops(ops, sort_by)
    local total_us = 0
    for _, op in ipairs(sorted) do total_us = total_us + op.dur_us end

    -- Header
    push(string.format("  %-40s  %8s  %8s  %8s  %6s",
      "Op", "TotalTime", "Count", "Memory", "Share"),
      { {c0=0, c1=-1, hl="MlbuddyDim"} })
    push(string.rep("─", W))

    -- Rows
    for i = 1, math.min(top_n, #sorted) do
      local op    = sorted[i]
      local pct   = total_us > 0 and (op.dur_us / total_us) or 0
      local bar_w = 8
      local bar   = util.progress_bar(pct, bar_w, "block")
      local hl    = op.is_cuda and "MlbuddyWarn" or "MlbuddyMetric"

      local line = string.format("  %-40s  %8s  %8d  %8s  %s %.0f%%",
        op.name:sub(1,40),
        fmt_us(op.dur_us),
        op.count,
        op.mem_b > 0 and util.fmt_bytes(op.mem_b) or "—",
        bar,
        pct * 100
      )
      push(line, {
        { c0=2,  c1=42, hl=hl },
        { c0=44, c1=-1, hl="MlbuddyDim" },
      })
    end

    push(""); push(string.rep("─", W))
    push(string.format("  %d total ops  ·  total time: %s",
      #ops, fmt_us(total_us)), { {c0=0, c1=-1, hl="MlbuddyDim"} })
  end

  push(""); push(string.rep("─", W))
  push("  [s] cycle sort  [q] close  :MlbuddyProfiler <path> to load",
    { {c0=0, c1=-1, hl="MlbuddyDim"} })
  return lines, hls
end

-- ── State + toggle ────────────────────────────────────────────────────────────

local ctx = {
  win=nil, buf=nil, ops={}, sort_idx=1, trace_path=nil,
}

local function render(cfg)
  if not (ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf)) then return end
  local sort_by = SORT_KEYS[ctx.sort_idx] or "cuda_time"
  local lines, hls = build_lines(ctx.ops, sort_by, cfg.profiler.top_n or 20, cfg)
  ui.set_lines(ctx.buf, lines)
  vim.api.nvim_buf_clear_namespace(ctx.buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    local c1 = (h.c1==-1) and (lines[h.row+1] and #lines[h.row+1] or 0) or h.c1
    vim.api.nvim_buf_add_highlight(ctx.buf, NS, h.hl, h.row, h.c0, c1)
  end
end

--- Load a chrome trace JSON file and open the profiler view.
---@param path string
---@param cfg  table
function M.load(path, cfg)
  if not path or path == "" then
    -- Try current buffer if it looks like a trace
    local cur = vim.fn.expand("%:p")
    if cur:match("%.json$") or cur:match("%.trace") then
      path = cur
    else
      ui.warn("Usage: :MlbuddyProfiler <path-to-trace.json>"); return
    end
  end

  local content = vim.fn.readfile(path)
  if #content == 0 then ui.error("Cannot read: " .. path); return end

  local data, err = util.json_decode(table.concat(content, "\n"))
  if err or not data then ui.error("JSON parse error: " .. tostring(err)); return end

  ctx.ops        = parse_chrome_trace(data)
  ctx.trace_path = path
  ctx.sort_idx   = 1

  if not (ctx.win and vim.api.nvim_win_is_valid(ctx.win)) then
    M.toggle(cfg)
  else
    render(cfg)
  end
  ui.info(string.format("Loaded %d ops from %s", #ctx.ops, vim.fn.fnamemodify(path, ":t")))
end

function M.toggle(cfg)
  if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
    vim.api.nvim_win_close(ctx.win, true); ctx.win=nil; return
  end
  local buf, win = ui.float({
    title  = (cfg.icons.profiler or "󰅱") .. "  Profiler",
    width  = cfg.width or 84, height = cfg.height or 40, border = cfg.border,
  })
  ctx.buf=buf; ctx.win=win

  ui.map(buf, cfg.profiler.keymaps.close or "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true); ctx.win=nil
    end
  end, "Close")

  ui.map(buf, cfg.profiler.keymaps.sort_cycle or "s", function()
    ctx.sort_idx = ctx.sort_idx % #SORT_KEYS + 1; render(cfg)
  end, "Cycle sort key")

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer=buf, once=true, callback=function() ctx.win=nil end,
  })

  render(cfg)
end

return M
