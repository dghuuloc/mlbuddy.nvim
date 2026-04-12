--- mlbuddy/quarto/init.lua
--- Main entry point for mlbuddy's Quarto integration.
---
--- Enhances quarto-nvim with:
---   1. mlbuddy IPython kernel as a custom quarto codeRunner
---   2. Tensor inspection (`<leader>mt`) inside .qmd Python cells
---   3. Training Monitor for training-loop cells
---   4. TorchView architecture display inside model-definition cells
---   5. Model debugger integration
---   6. quarto preview / render with live progress
---   7. Virtual text: activation shapes, training metrics, model params
---   8. Statusline: kernel status + preview URL + render progress

local cells_mod  = require("mlbuddy.quarto.cells")
local runner_mod = require("mlbuddy.quarto.runner")
local output_mod = require("mlbuddy.quarto.output")
local preview_mod= require("mlbuddy.quarto.preview")
local ui         = require("mlbuddy.ui")
local util       = require("mlbuddy.util")
local plat       = require("mlbuddy.platform")
local M          = {}

-- ── Activate quarto-nvim integration ──────────────────────────────────────

--- Patch the running quarto-nvim instance to use mlbuddy as codeRunner.
---@param cfg table
local function patch_quarto_runner(cfg)
  local ok, quarto = pcall(require, "quarto")
  if not ok then return end

  local mode = (cfg.quarto and cfg.quarto.runner) or "auto"
  if mode == "quarto" then return end  -- user wants quarto-nvim's own runner

  -- quarto.setup accepts codeRunner.default_method = <function>
  -- We call it again with our custom runner to override.
  pcall(quarto.setup, {
    codeRunner = {
      enabled        = true,
      default_method = runner_mod.make_quarto_runner(cfg),
    },
  })
end

-- ── Public: cell operations ────────────────────────────────────────────────

function M.run_cell(cfg)    runner_mod.run_cell(cfg)    end
function M.run_all(cfg)     runner_mod.run_all(cfg)     end
function M.run_above(cfg)   runner_mod.run_above(cfg)   end
function M.run_as_trainer(cfg) runner_mod.run_as_trainer(cfg) end

function M.interrupt(cfg)
  runner_mod.interrupt(vim.api.nvim_get_current_buf())
end

function M.restart(cfg)
  runner_mod.restart(vim.api.nvim_get_current_buf(), cfg)
end

function M.toggle_output(cfg)
  runner_mod.toggle_output(vim.api.nvim_get_current_buf())
end

function M.clear_output(cfg)
  runner_mod.clear_output(vim.api.nvim_get_current_buf())
end

-- ── Public: preview/render ─────────────────────────────────────────────────

function M.preview(cfg)          preview_mod.start_preview(cfg)   end
function M.close_preview(cfg)    preview_mod.close_preview(vim.api.nvim_get_current_buf()) end
function M.open_browser(cfg)     preview_mod.open_browser(vim.api.nvim_get_current_buf())  end
function M.render(cfg, fmt)      preview_mod.render(cfg, fmt)     end

-- ── Public: ML features ────────────────────────────────────────────────────

--- Inspect tensor under cursor in the current .qmd cell.
---@param cfg table
function M.inspect_tensor(cfg)
  -- Reuse the dataloader cursor inspect
  require("mlbuddy.dataloader").inspect_cursor(cfg)
end

--- Show TorchView for the model defined in the cell under cursor.
---@param cfg table
function M.torchview_cell(cfg)
  local bufnr     = vim.api.nvim_get_current_buf()
  local all_cells = cells_mod.parse(bufnr)
  local line      = vim.api.nvim_win_get_cursor(0)[1]
  local cell      = cells_mod.cell_at_line(all_cells, line)

  if not cell or cell.lang ~= "python" or not cell.is_model then
    -- Try TorchView on the whole buffer via a temp scratch buffer
    require("mlbuddy.torchview").toggle(cfg)
    return
  end

  -- Create a scratch Python buffer from the cell contents only
  local tmp = vim.api.nvim_create_buf(false, true)
  vim.bo[tmp].filetype = "python"
  vim.api.nvim_buf_set_lines(tmp, 0, -1, false, cell.lines)

  local classes = require("mlbuddy.torchview.parser").parse(tmp)
  vim.api.nvim_buf_delete(tmp, { force=true })

  if #classes == 0 then
    ui.warn("[mlbuddy/quarto] No nn.Module found in this cell")
    require("mlbuddy.torchview").toggle(cfg)
    return
  end

  local renderer = require("mlbuddy.torchview.renderer")
  renderer.open(classes, cfg)
end

--- Debug the model in the cell under cursor.
---@param cfg table
function M.debug_cell(cfg)
  local bufnr     = vim.api.nvim_get_current_buf()
  local all_cells = cells_mod.parse(bufnr)
  local line      = vim.api.nvim_win_get_cursor(0)[1]
  local cell      = cells_mod.cell_at_line(all_cells, line)

  if not cell or cell.lang ~= "python" then
    ui.warn("[mlbuddy/quarto] No Python cell at cursor"); return
  end

  -- Write cell to temp .py and run debugger
  local word = vim.fn.expand("<cword>")
  local expr = (word ~= "" and word) or "model"
  require("mlbuddy.debugger").debug_expr(cfg, expr, "full")
end

-- ── Enrich buffer ──────────────────────────────────────────────────────────

--- Refresh all virtual text enrichments for the current .qmd buffer.
---@param bufnr integer
---@param cfg   table
function M.enrich(bufnr, cfg)
  if not (cfg.quarto and cfg.quarto.enabled) then return end
  local all_cells = cells_mod.parse(bufnr)
  output_mod.enrich(bufnr, all_cells, cfg)
end

-- ── Navigate cells ────────────────────────────────────────────────────────

function M.next_cell()
  local bufnr = vim.api.nvim_get_current_buf()
  local cells = cells_mod.parse(bufnr)
  local line  = vim.api.nvim_win_get_cursor(0)[1]
  for _, c in ipairs(cells) do
    if c.start_line > line then
      vim.api.nvim_win_set_cursor(0, { c.code_start, 0 }); return
    end
  end
end

function M.prev_cell()
  local bufnr = vim.api.nvim_get_current_buf()
  local cells = cells_mod.parse(bufnr)
  local line  = vim.api.nvim_win_get_cursor(0)[1]
  local prev  = nil
  for _, c in ipairs(cells) do
    if c.start_line < line then prev = c.code_start end
  end
  if prev then vim.api.nvim_win_set_cursor(0, { prev, 0 }) end
end

function M.insert_cell_below()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(0, row, row, false, { "", "```{python}", "", "```", "" })
  vim.api.nvim_win_set_cursor(0, { row+3, 0 })
end

-- ── Statusline ────────────────────────────────────────────────────────────

--- Status string for statusline (kernel + preview).
---@param bufnr integer|nil
---@return string
function M.statusline(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local parts = {}
  local ks = runner_mod.kernel_status(bufnr)
  if ks ~= "" then parts[#parts+1] = ks end
  local ps = preview_mod.preview_status(bufnr)
  if ps ~= "" then parts[#parts+1] = ps end
  return table.concat(parts, "  ")
end

-- ── Setup ─────────────────────────────────────────────────────────────────

---@param cfg table
function M.setup_autocmds(cfg)
  if not (cfg.quarto and cfg.quarto.enabled) then return end

  local ag = vim.api.nvim_create_augroup("MlbuddyQuarto", { clear=true })

  -- Enrich .qmd buffers on open/write
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group   = ag,
    pattern = "*.qmd",
    callback = function(ev)
      vim.defer_fn(function()
        if not vim.api.nvim_buf_is_valid(ev.buf) then return end
        M.enrich(ev.buf, cfg)
      end, 120)
    end,
  })

  -- Close preview when qmd buffer closes
  if cfg.quarto.close_preview_on_exit then
    vim.api.nvim_create_autocmd("BufDelete", {
      group   = ag,
      pattern = "*.qmd",
      callback = function(ev)
        preview_mod.close_preview(ev.buf)
      end,
    })
  end

  -- Patch quarto-nvim runner after it loads
  vim.api.nvim_create_autocmd("User", {
    group    = ag,
    pattern  = "LazyLoad",
    callback = function(ev)
      if ev.data == "quarto-nvim" or ev.data == "quarto.nvim" then
        patch_quarto_runner(cfg)
      end
    end,
  })
  -- Also try immediately
  if package.loaded["quarto"] then patch_quarto_runner(cfg) end
end

return M
