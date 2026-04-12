--- mlbuddy/quarto/cells.lua
--- Parses Quarto Markdown (.qmd) code chunks.
---
--- Quarto cells look like:
---   ```{python}
---   import torch
---   ...
---   ```
---
--- Each chunk can have options:
---   ```{python}
---   #| label: train-loop
---   #| echo: false
---   model.fit(...)
---   ```
local M = {}

-- ── Cell data types ────────────────────────────────────────────────────────

---@class QuartoCell
---@field lang        string        "python" | "r" | "julia" | "bash" | ...
---@field start_line  integer       1-indexed line of the opening fence
---@field end_line    integer       1-indexed line of the closing ```
---@field code_start  integer       first line of actual code (after options)
---@field lines       string[]      all code lines (excluding options)
---@field options     table<string,string>  #| key: value pairs
---@field label       string|nil    #| label: value
---@field is_train    boolean       heuristic: contains training loop code
---@field is_model    boolean       heuristic: defines an nn.Module
---@field has_tensor  boolean       heuristic: uses torch tensors

-- ── Parsers ────────────────────────────────────────────────────────────────

local FENCE_OPEN  = "^%s*```%{(%w+)"    -- ```{python}, ```{r} etc.
local FENCE_CLOSE = "^%s*```%s*$"       -- bare ``` closing fence
local OPTION_LINE = "^%s*#|%s*(.-)%s*:%s*(.+)$"  -- #| key: value

-- Heuristics to classify cells
local TRAIN_PATTERNS = {
  "%.fit%(", "%.train%(", "trainer%.fit", "Trainer(",
  "for.*epoch", "for.*batch", "optimizer%.step",
  "loss%.backward", "backward%(", "train_step",
}
local MODEL_PATTERNS = {
  "class%s+%w+%(nn%.Module%)", "nn%.Sequential",
  "nn%.Linear", "nn%.Conv2d", "nn%.Transformer",
  "AutoModel", "AutoModelFor",
}
local TENSOR_PATTERNS = {
  "torch%.tensor", "torch%.zeros", "torch%.ones",
  "%.to%(device", "cuda%(", "numpy()",
  "DataLoader%(", "Dataset",
}

local function classify(lines)
  local code = table.concat(lines, "\n")
  local is_train, is_model, has_tensor = false, false, false
  for _, p in ipairs(TRAIN_PATTERNS) do
    if code:match(p) then is_train = true; break end
  end
  for _, p in ipairs(MODEL_PATTERNS) do
    if code:match(p) then is_model = true; break end
  end
  for _, p in ipairs(TENSOR_PATTERNS) do
    if code:match(p) then has_tensor = true; break end
  end
  return is_train, is_model, has_tensor
end

-- ── Public: parse buffer ───────────────────────────────────────────────────

---@param bufnr integer
---@return QuartoCell[]
function M.parse(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return {} end
  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cells     = {}
  local i         = 1

  while i <= #all_lines do
    local lang = all_lines[i]:match(FENCE_OPEN)
    if lang then
      local cell_start = i
      local options    = {}
      local code_lines = {}
      local code_start = i + 1
      i = i + 1

      -- Collect #| options
      while i <= #all_lines and all_lines[i]:match("^%s*#|") do
        local k, v = all_lines[i]:match(OPTION_LINE)
        if k then options[k] = v end
        code_start = i + 1
        i = i + 1
      end

      -- Collect code lines until closing fence
      while i <= #all_lines and not all_lines[i]:match(FENCE_CLOSE) do
        code_lines[#code_lines + 1] = all_lines[i]
        i = i + 1
      end

      local cell_end = i  -- line of the closing ```
      local is_train, is_model, has_tensor = classify(code_lines)

      cells[#cells + 1] = {
        lang       = lang:lower(),
        start_line = cell_start,
        end_line   = cell_end,
        code_start = code_start,
        lines      = code_lines,
        options    = options,
        label      = options.label,
        is_train   = is_train,
        is_model   = is_model,
        has_tensor = has_tensor,
      }
    end
    i = i + 1
  end

  return cells
end

--- Find the cell that contains a given line number.
---@param cells QuartoCell[]
---@param line  integer  1-indexed
---@return QuartoCell|nil, integer|nil  cell, index
function M.cell_at_line(cells, line)
  for i, c in ipairs(cells) do
    if line >= c.start_line and line <= c.end_line then
      return c, i
    end
  end
  return nil, nil
end

--- Get all cells of a given language.
---@param cells QuartoCell[]
---@param lang  string
---@return QuartoCell[]
function M.cells_by_lang(cells, lang)
  local out = {}
  for _, c in ipairs(cells) do
    if c.lang == lang then out[#out + 1] = c end
  end
  return out
end

--- Return only cells above (and including) the given line, in order.
---@param cells QuartoCell[]
---@param line  integer
---@param lang  string|nil  filter by language (nil = all)
---@return QuartoCell[]
function M.cells_above(cells, line, lang)
  local out = {}
  for _, c in ipairs(cells) do
    if c.start_line <= line and (not lang or c.lang == lang) then
      out[#out + 1] = c
    end
  end
  return out
end

return M
