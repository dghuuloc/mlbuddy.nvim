-- ftplugin/python.lua
-- Loaded for every Python buffer. Sets up mlbuddy keymaps.
--
-- IMPORTANT: This file is intentionally conservative.
-- It does NOT set <F5> (common debugpy keybind) or any key that might
-- conflict with a normal Python debugging workflow.
-- Keymaps here are only triggered by explicit user action.

if not vim.g.mlbuddy_loaded then return end

local buf = vim.api.nvim_get_current_buf()
if vim.b[buf].mlbuddy_python_setup then return end
vim.b[buf].mlbuddy_python_setup = true

local function cfg()
  return require("mlbuddy")._cfg or require("mlbuddy.config").defaults
end

local function bmap(lhs, rhs, desc)
  if not lhs or lhs == "" then return end
  vim.keymap.set("n", lhs, rhs, { buffer=buf, silent=true, desc="[mlbuddy] "..desc })
end

-- ── Notebook cell keymaps ─────────────────────────────────────────────────
-- Only <leader>-prefixed or ]n/[n — safe, no conflicts.

local nb = (require("mlbuddy.config").defaults.notebook or {}).keymaps or {}
bmap(nb.run_cell       or "<leader>mn",  function() require("mlbuddy").notebook_run()           end, "Run cell")
bmap(nb.run_all        or "<leader>mN",  function() require("mlbuddy").notebook_run_all()       end, "Run all cells")
bmap(nb.run_above      or "<leader>mA",  function() require("mlbuddy").notebook_run_above()     end, "Run cells above cursor")
bmap(nb.next_cell      or "]n",          function() require("mlbuddy").notebook_next()          end, "Next cell")
bmap(nb.prev_cell      or "[n",          function() require("mlbuddy").notebook_prev()          end, "Prev cell")
bmap(nb.new_cell_below or "<leader>mo",  function() require("mlbuddy").notebook_new()           end, "Insert cell below")
bmap(nb.interrupt      or "<leader>mi",  function() require("mlbuddy").notebook_interrupt()     end, "Interrupt kernel")
bmap(nb.restart        or "<leader>mk",  function() require("mlbuddy").notebook_restart()       end, "Restart kernel")
bmap(nb.toggle_output  or "<leader>mO",  function() require("mlbuddy").notebook_toggle_output() end, "Toggle cell output")

-- ── Tensor inspection ─────────────────────────────────────────────────────

local dl = (require("mlbuddy.config").defaults.dataloader or {}).keymaps or {}
bmap(dl.inspect_word or "<leader>mt",    function() require("mlbuddy").inspect_tensor()         end, "Inspect tensor under cursor")

-- ── Model debug ───────────────────────────────────────────────────────────

local dbg = (require("mlbuddy.config").defaults.debugger or {}).keymaps or {}
bmap(dbg.debug_expr or "<leader>mdi",    function() require("mlbuddy").debug_model()            end, "Debug model under cursor")
bmap(dbg.check_nan  or "<leader>mdn",    function() require("mlbuddy").debug_nan()              end, "Check NaN")
bmap(dbg.gradients  or "<leader>mdg",    function() require("mlbuddy").debug_gradients()        end, "Gradient flow")

-- ── TorchView ─────────────────────────────────────────────────────────────

local tv = (require("mlbuddy.config").defaults.torchview or {}).keymaps or {}
bmap(tv.toggle or "<leader>mv",          function() require("mlbuddy").torchview()              end, "TorchView model architecture")

-- ── Runner  ───────────────────────────────────────────────────────────────
-- NOTE: <F5> is intentionally NOT set here.
-- Many users bind <F5> to DAP continue. Use <leader>mr instead.

local rn = (require("mlbuddy.config").defaults.runner or {}).keymaps or {}
bmap(rn.run or "<leader>mr",             function() require("mlbuddy").run()                    end, "Run with Training Monitor")

-- ── %% insert-mode shortcut ───────────────────────────────────────────────
-- Type %% on a blank line in insert mode to insert a # %% cell marker.

vim.keymap.set("i", "%%", function()
  local line = vim.api.nvim_get_current_line()
  if line:gsub("%s", "") == "" then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_buf_set_lines(0, row-1, row, false, { "# %%", "" })
    vim.api.nvim_win_set_cursor(0, { row+1, 0 })
  else
    vim.api.nvim_feedkeys("%%", "n", false)
  end
end, { buffer=buf, silent=true, desc="[mlbuddy] Cell separator shortcut" })

-- ── Cell signs ───────────────────────────────────────────────────────────

vim.defer_fn(function()
  if not vim.api.nvim_buf_is_valid(buf) then return end
  require("mlbuddy.notebook").decorate_cells(buf)
end, 100)

vim.api.nvim_create_autocmd("BufWritePost", {
  buffer=buf,
  callback=function()
    require("mlbuddy.notebook").decorate_cells(buf)
  end,
})
