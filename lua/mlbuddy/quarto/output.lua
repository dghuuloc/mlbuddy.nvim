--- mlbuddy/quarto/output.lua
--- Virtual-text enrichment for Quarto code cells:
---   • Tensor shapes inline after `x = ` assignments
---   • Activation shapes from debugger module
---   • Training metrics summary at end of training cell
---   • Model param counts from TorchView parser
local ui    = require("mlbuddy.ui")
local util  = require("mlbuddy.util")
local plat  = require("mlbuddy.platform")
local M     = {}

local NS = vim.api.nvim_create_namespace("mlbuddy_qmd_enrich")

-- ── TorchView enrichment ──────────────────────────────────────────────────

--- Attach model architecture virtual text to model-definition cells.
---@param bufnr integer  .qmd buffer
---@param cell  QuartoCell
local function attach_torchview(bufnr, cell)
  -- Create a temporary Python file from the cell contents
  -- and run the TorchView parser on it.
  -- We re-use the existing torchview parser by creating a scratch buffer.

  local ok_ts = pcall(vim.treesitter.language.inspect, "python")
  if not ok_ts then return end

  local tmp_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[tmp_buf].filetype = "python"
  vim.api.nvim_buf_set_lines(tmp_buf, 0, -1, false, cell.lines)

  local classes = require("mlbuddy.torchview.parser").parse(tmp_buf)
  vim.api.nvim_buf_delete(tmp_buf, { force = true })

  if #classes == 0 then return end

  -- Summarise total params
  for _, cls in ipairs(classes) do
    local total = 0
    for _, layer in ipairs(cls.layers) do
      if layer.params > 0 then total = total + layer.params end
    end
    -- Find the class definition line within the cell
    for i, line in ipairs(cell.lines) do
      if line:match("class%s+"..cls.class_name) then
        local abs_line = cell.code_start + i - 2  -- 0-indexed
        if abs_line >= 0 then
          ui.virt(bufnr, NS, abs_line,
            string.format("  󰊠 %s  params: %s", cls.class_name, util.fmt_num(total)),
            "MlbuddyDim")
        end
      end
    end
  end
end

-- ── Activation shape enrichment ───────────────────────────────────────────

--- Attach activation shapes from the debugger module (if available).
---@param bufnr  integer
---@param cell   QuartoCell
---@param data   table   debugger JSON result
function M.attach_debug_shapes(bufnr, cell, data)
  if not data or not data.layers then return end

  local layer_shapes = {}
  for _, l in ipairs(data.layers) do
    if l.type == "activation" and l.activation then
      layer_shapes[l.name] = l.activation
    end
  end

  for i, line in ipairs(cell.lines) do
    local attr = line:match("self%.([%w_]+)%s*%(")
    if attr then
      local info = layer_shapes[attr] or layer_shapes["features."..attr]
      if info then
        local abs_line = cell.code_start + i - 2
        if abs_line >= 0 then
          local shape_txt = "→ " .. table.concat(info.shape or {}, "×")
          local hl = "MlbuddyDim"
          if info.has_nan or info.has_inf then
            shape_txt = shape_txt .. " ⚠NaN"
            hl = "MlbuddyError"
          elseif (info.zeros_pct or 0) > 80 then
            shape_txt = shape_txt .. string.format(" ⚠%.0f%%dead", info.zeros_pct)
            hl = "MlbuddyWarn"
          end
          ui.virt(bufnr, NS, abs_line, "  " .. shape_txt, hl)
        end
      end
    end
  end
end

-- ── Training metrics summary ──────────────────────────────────────────────

--- Show a one-line training summary at the end of a training cell.
---@param bufnr integer
---@param cell  QuartoCell
---@param hist  MetricHistory
function M.attach_train_summary(bufnr, cell, hist)
  local parser = require("mlbuddy.trainer.parser")
  local parts  = {}
  for _, k in ipairs({ "loss", "val_loss", "acc", "val_acc" }) do
    local st = parser.stats(hist, k)
    if st then
      parts[#parts+1] = string.format("%s=%.4g", k, st.last)
    end
  end
  if #parts == 0 then return end
  -- Place at the closing fence line
  local abs_line = cell.end_line - 1  -- 0-indexed
  if abs_line >= 0 then
    ui.virt(bufnr, NS, abs_line,
      "  ✓ " .. table.concat(parts, "  "),
      "MlbuddyMetric")
  end
end

-- ── Cell decoration (signs + language badge) ──────────────────────────────

--- Add sign/badge decorations to all cells in the buffer.
---@param bufnr  integer
---@param cells  QuartoCell[]
function M.decorate_cells(bufnr, cells)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  -- Only clear the sign portion (col 0, sign_text extmarks)
  -- Use a separate namespace so we don't wipe output virtual text
  local ns_sign = vim.api.nvim_create_namespace("mlbuddy_qmd_signs")
  vim.api.nvim_buf_clear_namespace(bufnr, ns_sign, 0, -1)

  local LANG_ICON = {
    python = "󰌠", r = "󰟔", julia = "⋋", bash = "", lua = "󰢱",
  }

  for _, cell in ipairs(cells) do
    local icon = LANG_ICON[cell.lang] or "⌨"
    local hl   = cell.lang == "python" and "MlbuddyCellRun"
              or "MlbuddyDim"

    -- Sign on the opening fence
    vim.api.nvim_buf_set_extmark(bufnr, ns_sign, cell.start_line-1, 0, {
      sign_text     = "▶",
      sign_hl_group = hl,
      priority      = 10,
    })

    -- Language badge as EOL virt text on the fence line
    vim.api.nvim_buf_set_extmark(bufnr, ns_sign, cell.start_line-1, 0, {
      virt_text     = { { "  " .. icon .. " " .. cell.lang
        .. (cell.label and ("  #"..cell.label) or "")
        .. (cell.is_train and "  󱘖 train" or "")
        .. (cell.is_model and "  󰊠 model" or ""), hl } },
      virt_text_pos = "eol",
    })
  end
end

-- ── Enrich a full buffer ───────────────────────────────────────────────────

--- Run all enrichments on a .qmd buffer after parse.
---@param bufnr  integer
---@param cells  QuartoCell[]
---@param cfg    table
function M.enrich(bufnr, cells, cfg)
  if not (cfg.quarto and cfg.quarto.enabled) then return end

  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

  -- TorchView virtual text on model cells
  if cfg.quarto.torchview_virt then
    for _, cell in ipairs(cells) do
      if cell.lang == "python" and cell.is_model then
        attach_torchview(bufnr, cell)
      end
    end
  end

  -- Cell decorations
  M.decorate_cells(bufnr, cells)
end

return M
