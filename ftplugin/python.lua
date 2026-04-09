-- ftplugin/python.lua
-- Loaded automatically by Neovim for every Python buffer.
-- Sets up buffer-local keymaps and triggers mlbuddy's Python-specific features.

if not vim.g.mlbuddy_loaded then return end

local buf = vim.api.nvim_get_current_buf()

-- Guard: only run once per buffer
if vim.b[buf].mlbuddy_python_setup then return end
vim.b[buf].mlbuddy_python_setup = true

local function cfg()
  return require("mlbuddy")._cfg or require("mlbuddy.config").defaults
end

local function bmap(lhs, rhs, desc)
  vim.keymap.set("n", lhs, rhs, {
    buffer  = buf,
    silent  = true,
    desc    = "[mlbuddy] " .. desc,
  })
end
local function bmap_i(lhs, rhs, desc)
  vim.keymap.set("i", lhs, rhs, {
    buffer  = buf,
    silent  = true,
    expr    = false,
    desc    = "[mlbuddy] " .. desc,
  })
end

-- ── Notebook cell navigation ──────────────────────────────────────────────────
-- These are set even without setup() so notebooks "just work" out of the box.

local nb_keymaps = (require("mlbuddy.config").defaults.notebook or {}).keymaps or {}

bmap(nb_keymaps.run_cell       or "<leader>mn",  function() require("mlbuddy").notebook_run()           end, "Run cell")
bmap(nb_keymaps.run_all        or "<leader>mN",  function() require("mlbuddy").notebook_run_all()       end, "Run all cells")
bmap(nb_keymaps.run_above      or "<leader>mA",  function() require("mlbuddy").notebook_run_above()     end, "Run cells above cursor")
bmap(nb_keymaps.next_cell      or "]n",           function() require("mlbuddy").notebook_next()          end, "Next cell")
bmap(nb_keymaps.prev_cell      or "[n",           function() require("mlbuddy").notebook_prev()          end, "Prev cell")
bmap(nb_keymaps.new_cell_below or "<leader>mo",  function() require("mlbuddy").notebook_new()           end, "Insert cell below")
bmap(nb_keymaps.interrupt      or "<leader>mi",  function() require("mlbuddy").notebook_interrupt()     end, "Interrupt kernel")
bmap(nb_keymaps.restart        or "<leader>mk",  function() require("mlbuddy").notebook_restart()       end, "Restart kernel")
bmap(nb_keymaps.toggle_output  or "<leader>mO",  function() require("mlbuddy").notebook_toggle_output() end, "Toggle cell output")

-- ── Tensor inspection ────────────────────────────────────────────────────────

local dl_keymaps = (require("mlbuddy.config").defaults.dataloader or {}).keymaps or {}
bmap(dl_keymaps.inspect_word or "<leader>mt",    function() require("mlbuddy").inspect_tensor() end, "Inspect tensor under cursor")

-- ── Quick run ────────────────────────────────────────────────────────────────

bmap("<leader>mr",  function() require("mlbuddy").run() end,    "Run this file with training monitor")
bmap("<F5>",        function() require("mlbuddy").run() end,    "Run this file (mlbuddy)")

-- ── TorchView toggle ─────────────────────────────────────────────────────────

bmap(
  (require("mlbuddy.config").defaults.torchview.keymaps or {}).toggle or "<leader>mv",
  function() require("mlbuddy").torchview() end,
  "TorchView model architecture"
)

-- ── Cell markers – insert mode shortcut ──────────────────────────────────────
-- Type `%%` on a blank line to insert a # %% cell separator.

bmap_i("%%", function()
  local line = vim.api.nvim_get_current_line()
  if line:gsub("%s","") == "" then
    return "<Esc>cc# %%<CR>"
  end
  return "%%"
end, "Cell separator shortcut")

-- ── Signs: mark # %% cell boundaries ─────────────────────────────────────────

vim.defer_fn(function()
  if not vim.api.nvim_buf_is_valid(buf) then return end
  require("mlbuddy.notebook").decorate_cells(buf)
end, 100)

-- Re-decorate on save
vim.api.nvim_create_autocmd("BufWritePost", {
  buffer   = buf,
  callback = function()
    require("mlbuddy.notebook").decorate_cells(buf)
  end,
})
