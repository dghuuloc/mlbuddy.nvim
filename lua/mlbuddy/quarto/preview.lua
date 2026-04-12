--- mlbuddy/quarto/preview.lua
--- Integrates `quarto preview` and `quarto render` with mlbuddy.
---
--- Features:
---   • Start/stop quarto preview in a terminal split
---   • Run `quarto render` and capture output in the Trainer dashboard
---   • Show render progress as a virtual status line in the document
---   • Auto-open browser on render completion

local ui    = require("mlbuddy.ui")
local util  = require("mlbuddy.util")
local plat  = require("mlbuddy.platform")
local M     = {}

local NS      = vim.api.nvim_create_namespace("mlbuddy_qmd_preview")
local _preview = {}  -- bufnr → { job_id, buf, win, url, status }
local _render  = {}  -- bufnr → trainer job id

-- ── Find quarto CLI ───────────────────────────────────────────────────────

local function find_quarto()
  return plat.find_exe("quarto") or vim.fn.exepath("quarto")
end

-- ── Preview ───────────────────────────────────────────────────────────────

--- Start `quarto preview` for the current .qmd file.
---@param cfg table
function M.start_preview(cfg)
  local bufnr  = vim.api.nvim_get_current_buf()
  local path   = vim.api.nvim_buf_get_name(bufnr)

  if not path:match("%.qmd$") then
    ui.warn("[mlbuddy/quarto] Not a .qmd file"); return
  end

  -- If quarto-nvim is available, prefer its quartoPreview
  if (cfg.quarto and cfg.quarto.prefer_quarto_nvim) then
    local ok, q = pcall(require, "quarto")
    if ok and q.quartoPreview then q.quartoPreview(); return end
  end

  local quarto = find_quarto()
  if not quarto or quarto == "" then
    ui.error("[mlbuddy/quarto] quarto CLI not found — install quarto-cli"); return
  end

  -- Close existing preview for this buffer
  if _preview[bufnr] then M.close_preview(bufnr) end

  local cmd    = { quarto, "preview", path, "--no-browser" }
  local out    = {}

  -- Parse the preview URL from quarto's stdout
  local url = nil

  local job_id = vim.fn.jobstart(cmd, {
    on_stdout = function(_, lines)
      for _, l in ipairs(lines) do
        if l and l ~= "" then
          out[#out+1] = l
          -- Quarto prints: "Browse at http://localhost:XXXX/"
          local u = l:match("Browse at (https?://%S+)")
          if u and not url then
            url = u
            _preview[bufnr].url = url
            -- Update status annotation
            vim.schedule(function()
              M._set_status(bufnr, "preview", "● Preview: " .. url, "MlbuddyGood")
            end)
            ui.info("[mlbuddy/quarto] Preview at " .. url)
          end
        end
      end
    end,
    on_stderr = function(_, lines)
      for _, l in ipairs(lines) do
        if l and l:match("ERROR") then
          vim.schedule(function()
            M._set_status(bufnr, "preview", "⚠ Preview error", "MlbuddyError")
          end)
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if _preview[bufnr] then
          M._set_status(bufnr, "preview",
            code == 0 and "● Preview stopped" or "⚠ Preview exited ("..code..")",
            code == 0 and "MlbuddyDim" or "MlbuddyWarn")
          _preview[bufnr] = nil
        end
      end)
    end,
    stdout_buffered = false,
    stderr_buffered = false,
  })

  _preview[bufnr] = { job_id=job_id, url=nil, status="starting" }
  M._set_status(bufnr, "preview", "⏳ Starting preview…", "MlbuddyWarn")
  ui.info("[mlbuddy/quarto] Starting quarto preview…")
end

--- Close the preview for a buffer.
---@param bufnr integer
function M.close_preview(bufnr)
  local p = _preview[bufnr]
  if not p then return end
  if p.job_id then pcall(vim.fn.jobstop, p.job_id) end
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  _preview[bufnr] = nil
  ui.info("[mlbuddy/quarto] Preview closed")
end

--- Open the preview URL in the default browser.
---@param bufnr integer
function M.open_browser(bufnr)
  local p = _preview[bufnr]
  if not (p and p.url) then
    ui.warn("[mlbuddy/quarto] No preview URL — start preview first"); return
  end
  local open_cmd = plat.is_win and "start" or (plat.is_mac and "open" or "xdg-open")
  vim.fn.jobstart({ open_cmd, p.url }, { detach=true })
end

-- ── Render ────────────────────────────────────────────────────────────────

--- Run `quarto render` and show progress in the Trainer dashboard.
---@param cfg    table
---@param format string|nil  e.g. "html", "pdf", "docx" (nil = default)
function M.render(cfg, format)
  local bufnr = vim.api.nvim_get_current_buf()
  local path  = vim.api.nvim_buf_get_name(bufnr)

  if not path:match("%.qmd$") then
    ui.warn("[mlbuddy/quarto] Not a .qmd file"); return
  end

  local quarto = find_quarto()
  if not quarto or quarto == "" then
    ui.error("[mlbuddy/quarto] quarto CLI not found"); return
  end

  -- Save first
  vim.cmd("write")

  local cmd = { quarto, "render", path }
  if format then vim.list_extend(cmd, { "--to", format }) end

  M._set_status(bufnr, "render", "⏳ Rendering…", "MlbuddyWarn")

  -- Launch via trainer monitor so we get live output + timing
  local trainer = require("mlbuddy.trainer")
  local job_id = trainer.launch(cmd, cfg)
  _render[bufnr] = job_id

  ui.info("[mlbuddy/quarto] Rendering " .. vim.fn.fnamemodify(path, ":t")
    .. (format and (" → "..format) or ""))
end

-- ── Status virtual text ───────────────────────────────────────────────────

--- Set a status annotation at the top of the document.
---@param bufnr  integer
---@param key    string   "preview" | "render"
---@param text   string
---@param hl     string
function M._set_status(bufnr, key, text, hl)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- Use extmark id 1=preview, 2=render so they don't stomp each other
  local eid = key == "preview" and 1 or 2
  local ok = pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, eid)

  vim.api.nvim_buf_set_extmark(bufnr, NS, 0, 0, {
    id            = eid,
    virt_text     = { { "  " .. text, hl } },
    virt_text_pos = "eol",
    hl_mode       = "combine",
  })
end

--- Return the preview URL for a buffer (for statusline).
---@param bufnr integer
---@return string
function M.preview_status(bufnr)
  local p = _preview[bufnr]
  if not p then return "" end
  if p.url then return "󰖟 " .. p.url end
  return "󰖟 starting…"
end

return M
