-- ftplugin/quarto.lua
-- Loaded for every .qmd buffer.
-- Installs mlbuddy keymaps for Quarto ML notebooks.

if not vim.g.mlbuddy_loaded then return end

local buf = vim.api.nvim_get_current_buf()
if vim.b[buf].mlbuddy_quarto_setup then return end
vim.b[buf].mlbuddy_quarto_setup = true

local function cfg()
  return require("mlbuddy")._cfg or require("mlbuddy.config").defaults
end

local function bmap(lhs, rhs, desc)
  if not lhs or lhs == "" then return end
  vim.keymap.set("n", lhs, rhs, { buffer=buf, silent=true, desc="[mlbuddy/quarto] "..desc })
end
local function vmap(lhs, rhs, desc)
  if not lhs or lhs == "" then return end
  vim.keymap.set("v", lhs, rhs, { buffer=buf, silent=true, desc="[mlbuddy/quarto] "..desc })
end

local qkm = (require("mlbuddy.config").defaults.quarto or {}).keymaps or {}
local q   = require("mlbuddy.quarto")

-- ── Cell execution ────────────────────────────────────────────────────────
bmap(qkm.run_cell      or "<leader>qr",  function() q.run_cell(cfg())       end, "Run cell")
bmap(qkm.run_all       or "<leader>qR",  function() q.run_all(cfg())        end, "Run all cells")
bmap(qkm.run_above     or "<leader>qa",  function() q.run_above(cfg())      end, "Run above")
bmap(qkm.train_cell    or "<leader>qT",  function() q.run_as_trainer(cfg()) end, "Run cell as training job")
bmap(qkm.toggle_output or "<leader>qo",  function() q.toggle_output(cfg())  end, "Toggle cell output")
bmap(qkm.clear_output  or "<leader>qO",  function() q.clear_output(cfg())   end, "Clear all output")
bmap(qkm.interrupt     or "<leader>qi",  function() q.interrupt(cfg())      end, "Interrupt kernel")
bmap(qkm.restart       or "<leader>qk",  function() q.restart(cfg())        end, "Restart kernel")

-- ── Navigation ────────────────────────────────────────────────────────────
bmap("]q",                               function() q.next_cell()            end, "Next cell")
bmap("[q",                               function() q.prev_cell()            end, "Prev cell")
bmap(qkm.insert_cell   or "<leader>qn",  function() q.insert_cell_below()    end, "Insert cell below")

-- ── Preview / render ──────────────────────────────────────────────────────
bmap(qkm.preview       or "<leader>qp",  function() q.preview(cfg())         end, "quarto preview")
bmap(qkm.close_preview or "<leader>qP",  function() q.close_preview(cfg())   end, "Close preview")
bmap(qkm.open_browser  or "<leader>qb",  function() q.open_browser(cfg())    end, "Open in browser")
bmap(qkm.render        or "<leader>qB",  function() q.render(cfg())          end, "quarto render")
bmap(qkm.render_html   or "<leader>qH",  function() q.render(cfg(), "html")  end, "Render → HTML")
bmap(qkm.render_pdf    or "<leader>qF",  function() q.render(cfg(), "pdf")   end, "Render → PDF")

-- ── ML features ───────────────────────────────────────────────────────────
bmap(qkm.inspect_tensor or "<leader>qt", function() q.inspect_tensor(cfg())  end, "Inspect tensor")
bmap(qkm.torchview      or "<leader>qv", function() q.torchview_cell(cfg())  end, "TorchView model")
bmap(qkm.debug          or "<leader>qd", function() q.debug_cell(cfg())      end, "Debug model")
bmap("<leader>mt",                        function() q.inspect_tensor(cfg())  end, "Inspect tensor (shared)")

-- ── Visual range cell (works alongside quarto-nvim runner) ───────────────
vmap("r",  function()
  local ok, runner = pcall(require, "quarto.runner")
  if ok then runner.run_range()
  else
    -- Fallback: get selected lines and send to mlbuddy kernel
    local start_line = vim.fn.line("'<")
    local end_line   = vim.fn.line("'>")
    local bufnr      = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line-1, end_line, false)
    local k_mod  = require("mlbuddy.quarto.runner")
    -- Synthetic cell
    local cell = { lines=lines, start_line=start_line, end_line=end_line,
                   code_start=start_line, lang="python", is_train=false, is_model=false, options={} }
    -- Start/use kernel
    local runner_fn = k_mod.make_quarto_runner(cfg())
    runner_fn(table.concat(lines, "\n"))
  end
end, "Run visual selection")

-- ── %% shortcut: insert code chunk from blank line ───────────────────────
vim.keymap.set("i", "```", function()
  local line = vim.api.nvim_get_current_line()
  if line:gsub("%s","") == "" then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_buf_set_lines(0, row-1, row, false, { "```{python}", "", "```" })
    vim.api.nvim_win_set_cursor(0, { row+1, 0 })
    vim.cmd("startinsert!")
  else
    vim.api.nvim_feedkeys("```", "n", false)
  end
end, { buffer=buf, silent=true, desc="[mlbuddy] Quick code chunk" })

-- ── Initial enrichment ────────────────────────────────────────────────────
vim.defer_fn(function()
  if not vim.api.nvim_buf_is_valid(buf) then return end
  require("mlbuddy.quarto").enrich(buf, cfg())
end, 150)

vim.api.nvim_create_autocmd("BufWritePost", {
  buffer   = buf,
  callback = function()
    require("mlbuddy.quarto").enrich(buf, cfg())
  end,
})
