--- mlbuddy.torchview.renderer
--- Builds and renders the TorchView float window.
local ui   = require("mlbuddy.ui")
local util = require("mlbuddy.util")
local M    = {}

local NS = vim.api.nvim_create_namespace("mlbuddy_tv_render")

-- ── Bar drawing ────────────────────────────────────────────────────────────────

local BAR_FULL  = "█"
local BAR_EMPTY = "░"

local function param_bar(n, max_n, w)
  w = w or 8
  if max_n == 0 or n < 0 then return string.rep(BAR_EMPTY, w) end
  local cells = math.floor(n / max_n * w + 0.5)
  cells = math.max(0, math.min(w, cells))
  return string.rep(BAR_FULL, cells) .. string.rep(BAR_EMPTY, w - cells)
end

-- ── Line builder ───────────────────────────────────────────────────────────────

---@class HlSpec
---@field row  integer   0-indexed
---@field c0   integer
---@field c1   integer   -1 = eol
---@field hl   string

---@param classes  MlbuddyClass[]
---@param cfg      table
---@return string[], HlSpec[]
function M.build_lines(classes, cfg)
  local W       = (cfg.width or 76) - 4
  local icons   = cfg.icons or {}
  local lines   = {}
  local hls     = {}

  local function push(text, hl_ranges)
    local row = #lines
    lines[#lines + 1] = text
    if hl_ranges then
      for _, r in ipairs(hl_ranges) do
        r.row = row
        hls[#hls + 1] = r
      end
    end
  end

  local function rule(ch) push(string.rep(ch or "─", W)) end

  -- Header
  push(
    string.format("  %s  Model Architecture  (%d class%s found)",
      icons.module or "󰊠",
      #classes,
      #classes == 1 and "" or "es"),
    { { c0 = 0, c1 = -1, hl = "MlbuddyTitle" } }
  )
  rule("─")

  for ci, cls in ipairs(classes) do
    push("")

    -- Class header
    local base = cls.base_name and ("  inherits " .. cls.base_name) or ""
    local cls_line = string.format("  class %s%s  (line %d)",
      cls.class_name, base, cls.line)
    push(cls_line, {
      { c0 = 8, c1 = 8 + #cls.class_name, hl = "MlbuddyLayer" },
      { c0 = 8 + #cls.class_name, c1 = -1, hl = "MlbuddyDim" },
    })

    -- Compute max params for bar scaling
    local max_p, total_p = 0, 0
    for _, l in ipairs(cls.layers) do
      if l.params > max_p then max_p = l.params end
    end

    for li, layer in ipairs(cls.layers) do
      local is_last = (li == #cls.layers)
      local prefix  = is_last and "    └─ " or "    ├─ "
      local pipe    = is_last and "       " or "    │  "

      local args_str = #layer.args > 0
        and "(" .. table.concat(layer.args, ", ") .. ")"
        or  "()"

      -- Param annotation
      local param_info, param_hl
      if layer.params < 0 then
        param_info = "  ?"
        param_hl   = "MlbuddyDim"
      elseif layer.params == 0 then
        param_info = "  —"
        param_hl   = "MlbuddyDim"
      else
        total_p    = total_p + layer.params
        local bar  = param_bar(layer.params, max_p, 8)
        param_info = string.format("  %s %s", bar, util.fmt_num(layer.params))
        param_hl   = "MlbuddyBar"
      end

      local name_part  = prefix .. layer.name
      local type_part  = "  " .. layer.layer_type
      local args_part  = args_str
      local param_part = param_info

      local row_text = name_part .. type_part .. args_part .. param_part
      local nc = #name_part
      local tc = nc + #type_part
      local ac = tc + #args_part
      push(row_text, {
        { c0 = #prefix, c1 = nc,          hl = "MlbuddyIdent" },
        { c0 = nc + 2,  c1 = tc,          hl = "MlbuddyLayer" },
        { c0 = tc,      c1 = ac,          hl = "MlbuddyDim"   },
        { c0 = ac,      c1 = -1,          hl = param_hl       },
      })
    end

    push(string.format("    %s  Total trainable params: %s",
      string.rep(" ", 6),
      util.fmt_num(total_p)),
      { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } }
    )

    if ci < #classes then
      push("")
      rule("╌")
    end
  end

  push("")
  rule("─")
  push("  [q] close   [zo/zc] fold   [R] re-parse",
    { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })

  return lines, hls
end

-- ── Public: open float ─────────────────────────────────────────────────────────

---@param classes  MlbuddyClass[]
---@param cfg      table
---@return integer buf, integer win
function M.open(classes, cfg)
  local width  = cfg.width  or 76
  local height = math.min(cfg.height or 40, #classes * 12 + 8)

  local buf, win = ui.float({
    title  = (cfg.icons and cfg.icons.module or "󰊠") .. "  TorchView",
    width  = width,
    height = height,
    border = cfg.border,
  })

  local lines, hls = M.build_lines(classes, cfg)
  ui.set_lines(buf, lines)

  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    local c1 = (h.c1 == -1) and #lines[h.row + 1] or h.c1
    vim.api.nvim_buf_add_highlight(buf, NS, h.hl, h.row, h.c0, c1)
  end

  vim.bo[buf].filetype = "mlbuddy_torchview"
  return buf, win
end

return M
