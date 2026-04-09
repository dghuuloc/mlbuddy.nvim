--- mlbuddy.dataloader.renderer
--- Renders tensor inspection panels: summary stats + block-char heatmap.
local ui   = require("mlbuddy.ui")
local util = require("mlbuddy.util")
local M    = {}

local NS = vim.api.nvim_create_namespace("mlbuddy_dl_render")

-- ── Stat helpers ──────────────────────────────────────────────────────────────

local function mean(t)
  if #t == 0 then return 0 end
  local s = 0
  for _, v in ipairs(t) do s = s + v end
  return s / #t
end

local function std(t, m)
  if #t < 2 then return 0 end
  local s = 0
  for _, v in ipairs(t) do s = s + (v - m)^2 end
  return math.sqrt(s / (#t - 1))
end

local function has_nan(t)
  for _, v in ipairs(t) do
    if v ~= v then return true end   -- NaN != NaN
  end
  return false
end

local function has_inf(t)
  for _, v in ipairs(t) do
    if math.abs(v) == math.huge then return true end
  end
  return false
end

-- ── Heatmap builder ───────────────────────────────────────────────────────────

--- Build a 2-D heatmap from a flat list of values.
---@param values  number[]
---@param rows    integer
---@param cols    integer
---@return string[]   display lines (one per row)
local function build_heatmap(values, rows, cols)
  if #values == 0 then
    return { string.rep("?", cols) }
  end

  local mn, mx = math.huge, -math.huge
  for _, v in ipairs(values) do
    if v == v then   -- skip NaN
      if v < mn then mn = v end
      if v > mx then mx = v end
    end
  end

  local SHADE = { " ", "░", "▒", "▓", "█" }
  local NAN_C = "✗"
  local out   = {}

  for r = 1, rows do
    local row_chars = {}
    for c = 1, cols do
      -- sample values from flat array
      local total  = rows * cols
      local idx    = math.floor((r - 1) * cols + c)
      local v_idx  = math.max(1, math.floor((idx - 1) * #values / total + 1))
      local v      = values[v_idx]

      if v ~= v then
        -- NaN
        row_chars[c] = NAN_C
      else
        local norm = (mx == mn) and 0.5 or (v - mn) / (mx - mn)
        local si   = util.clamp(math.floor(norm * 5) + 1, 1, 5)
        row_chars[c] = SHADE[si]
      end
    end
    out[#out + 1] = table.concat(row_chars)
  end

  return out
end

-- ── Line builder ──────────────────────────────────────────────────────────────

---@class TensorInfo
---@field name     string
---@field shape    integer[]
---@field dtype    string
---@field values   number[]|nil    flattened sample (may be nil if unavailable)
---@field min      number|nil
---@field max      number|nil
---@field mean     number|nil
---@field std      number|nil
---@field has_nan  boolean
---@field has_inf  boolean
---@field source   string|nil      e.g. "DAP" | "cursor"

---@param tensors  TensorInfo[]
---@param cfg      table
---@return string[], table[]
function M.build_lines(tensors, cfg)
  local icons  = cfg.icons or {}
  local W      = (cfg.width or 76) - 2
  local HM_C   = cfg.dataloader.heatmap_cols or 32
  local HM_R   = cfg.dataloader.heatmap_rows or 8
  local PREC   = cfg.dataloader.precision    or 4
  local fmt    = "%." .. PREC .. "g"

  local lines = {}
  local hls   = {}

  local function push(text, hl_list)
    local row = #lines
    lines[#lines + 1] = text
    if hl_list then
      for _, h in ipairs(hl_list) do
        h.row = row
        hls[#hls + 1] = h
      end
    end
  end

  local function rule(ch) push(string.rep(ch or "─", W)) end

  push(
    string.format("  %s  DataLoader Inspector  (%d tensor%s)",
      icons.tensor or "󱄽",
      #tensors,
      #tensors == 1 and "" or "s"),
    { { c0 = 0, c1 = -1, hl = "MlbuddyTitle" } }
  )
  rule()

  if #tensors == 0 then
    push("  (no tensors to inspect — use <leader>mt over a variable name or attach DAP)",
      { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
    push("")
  end

  for ti, t in ipairs(tensors) do
    push("")

    -- Tensor title
    local shape_str = "[" .. table.concat(t.shape or {}, "×") .. "]"
    local hdr = string.format("  %s %s  %s  dtype: %s  src: %s",
      icons.tensor or "󱄽",
      t.name or "tensor",
      shape_str,
      t.dtype or "?",
      t.source or "?")

    push(hdr, {
      { c0 = 4,
        c1 = 4 + #(t.name or "tensor"),
        hl = "MlbuddyIdent" },
      { c0 = 4 + #(t.name or "tensor") + 2,
        c1 = 4 + #(t.name or "tensor") + 2 + #shape_str,
        hl = "MlbuddyLayer" },
    })

    rule("╌")

    -- Statistics
    local mn   = t.min  or (t.values and math.min(table.unpack(t.values)) or nil)
    local mx   = t.max  or (t.values and math.max(table.unpack(t.values)) or nil)
    local mu   = t.mean or (t.values and mean(t.values) or nil)
    local sg   = t.std  or (t.values and mu and std(t.values, mu) or nil)
    local nnan = t.has_nan or (t.values and has_nan(t.values) or false)
    local ninf = t.has_inf or (t.values and has_inf(t.values) or false)

    local stat_line = string.format(
      "  min=%-12s  max=%-12s  mean=%-12s  std=%-12s",
      mn  and fmt:format(mn) or "?",
      mx  and fmt:format(mx) or "?",
      mu  and fmt:format(mu) or "?",
      sg  and fmt:format(sg) or "?"
    )
    push(stat_line, { { c0 = 0, c1 = -1, hl = "MlbuddyMetric" } })

    -- NaN / Inf warnings
    if nnan or ninf then
      local warn_parts = {}
      if nnan then warn_parts[#warn_parts + 1] = (icons.nan or "󰅙") .. " NaN detected" end
      if ninf then warn_parts[#warn_parts + 1] = "∞  Inf detected" end
      push("  " .. table.concat(warn_parts, "   "),
        { { c0 = 0, c1 = -1, hl = "MlbuddyNaN" } })
    end

    -- Heatmap
    if t.values and #t.values > 0 then
      push("")
      push("  Heatmap  (░ low → █ high):",
        { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })

      local hm_lines = build_heatmap(t.values, HM_R, HM_C)
      local mn_str = mn and fmt:format(mn) or "?"
      local mx_str = mx and fmt:format(mx) or "?"
      for ri, rl in ipairs(hm_lines) do
        local prefix = ri == 1 and string.format("  %-8s │", mn_str)
                    or ri == HM_R and string.format("  %-8s │", mx_str)
                    or "           │"
        push(prefix .. rl, {
          { c0 = #prefix, c1 = #prefix + #rl, hl = "MlbuddyBar" },
          { c0 = 0, c1 = #prefix, hl = "MlbuddyDim" },
        })
      end

      -- Distribution sparkline (histogram-style)
      push("")
      push("  Value distribution  (left=low, right=high):",
        { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
      push("  " .. util.sparkline(t.values, math.min(HM_C * 2, W - 4)),
        { { c0 = 2, c1 = -1, hl = "MlbuddySparkline" } })
    else
      push("  (no value sample available)",
        { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })
    end

    if ti < #tensors then
      push("")
      rule("╌")
    end
  end

  push("")
  rule("─")
  push("  [q] close   [R] re-inspect   [<Tab>] next tensor",
    { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })

  return lines, hls
end

-- ── Public: open float ────────────────────────────────────────────────────────

---@param tensors TensorInfo[]
---@param cfg     table
---@return integer buf, integer win
function M.open(tensors, cfg)
  local buf, win = ui.float({
    title  = (cfg.icons and cfg.icons.tensor or "󱄽") .. "  DataLoader Inspector",
    width  = cfg.width  or 76,
    height = cfg.height or 36,
    border = cfg.border,
  })

  M.redraw(buf, tensors, cfg)
  vim.bo[buf].filetype = "mlbuddy_dataloader"
  return buf, win
end

---@param buf     integer
---@param tensors TensorInfo[]
---@param cfg     table
function M.redraw(buf, tensors, cfg)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local lines, hls = M.build_lines(tensors, cfg)
  ui.set_lines(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    local c1 = (h.c1 == -1) and #lines[h.row + 1] or h.c1
    vim.api.nvim_buf_add_highlight(buf, NS, h.hl, h.row, h.c0, c1)
  end
end

return M
