--- mlbuddy/checkpoint/init.lua
--- Scans workspace for model checkpoints, inspects metadata, supports resume/delete.
local ui   = require("mlbuddy.ui")
local util = require("mlbuddy.util")
local M    = {}

local NS = vim.api.nvim_create_namespace("mlbuddy_ckpt")

-- ── Python inspector ──────────────────────────────────────────────────────────

local INSPECT_PY = [[
import sys, json, os

path = sys.argv[1]
result = {"path": path, "error": None, "keys": [], "metadata": {}}

try:
    ext = os.path.splitext(path)[1].lower()
    if ext in (".pt", ".pth"):
        import torch
        obj = torch.load(path, map_location="cpu", weights_only=False)
        if isinstance(obj, dict):
            result["keys"] = list(obj.keys())[:20]
            # Try to extract common metadata
            for k in ("epoch", "step", "global_step", "loss", "val_loss",
                       "train_loss", "accuracy", "args", "config", "hparams"):
                if k in obj:
                    v = obj[k]
                    if isinstance(v, (int, float, str, bool)):
                        result["metadata"][k] = v
                    elif hasattr(v, "item"):
                        result["metadata"][k] = float(v.item())
            # Estimate total params if model_state_dict present
            sd_key = next((k for k in obj if "state_dict" in k.lower()), None)
            if sd_key and isinstance(obj[sd_key], dict):
                total = sum(p.numel() for p in obj[sd_key].values()
                            if hasattr(p, "numel"))
                result["metadata"]["total_params"] = total
        result["type"] = "checkpoint"
    elif ext == ".safetensors":
        try:
            from safetensors import safe_open
            with safe_open(path, framework="pt", device="cpu") as f:
                keys = list(f.keys())
                result["keys"] = keys[:20]
                result["metadata"]["num_tensors"] = len(keys)
        except ImportError:
            result["metadata"]["note"] = "safetensors not installed"
        result["type"] = "safetensors"
    elif ext == ".ckpt":
        import torch
        obj = torch.load(path, map_location="cpu", weights_only=False)
        if isinstance(obj, dict):
            result["keys"] = list(obj.keys())[:20]
            for k in ("epoch", "global_step", "hyper_parameters", "callbacks"):
                if k in obj:
                    v = obj[k]
                    if isinstance(v, (int, float, str)):
                        result["metadata"][k] = v
        result["type"] = "lightning_checkpoint"
    elif ext == ".bin":
        import torch
        obj = torch.load(path, map_location="cpu", weights_only=True)
        if isinstance(obj, dict):
            result["keys"] = list(obj.keys())[:20]
            total = sum(p.numel() for p in obj.values() if hasattr(p, "numel"))
            result["metadata"]["total_params"] = total
        result["type"] = "huggingface_weights"
except Exception as e:
    result["error"] = str(e)

result["size_bytes"] = os.path.getsize(path)
print(json.dumps(result))
]]

---@class CheckpointInfo
---@field path      string
---@field type      string
---@field keys      string[]
---@field metadata  table<string,any>
---@field size_bytes integer
---@field error     string|nil

--- Asynchronously inspect a checkpoint file.
---@param path   string
---@param python string
---@param cb     fun(info: CheckpointInfo)
local function inspect_ckpt(path, python, cb)
  local script = vim.fn.tempname() .. "_mlb_ckpt.py"
  vim.fn.writefile(vim.split(INSPECT_PY, "\n"), script)
  local out = {}
  vim.system({ python, script, path }, {
    text=true, stdout=function(_, d) if d then out[#out+1] = d end end,
  }, function(r)
    vim.fn.delete(script)
    vim.schedule(function()
      local d = util.json_decode(table.concat(out))
      cb(d or { path=path, error="parse failed", keys={}, metadata={}, size_bytes=0 })
    end)
  end)
end

-- ── Build display lines ───────────────────────────────────────────────────────

local function fmt_meta(meta)
  local parts = {}
  local order = { "epoch", "global_step", "step", "loss", "val_loss", "total_params" }
  local shown = {}
  for _, k in ipairs(order) do
    if meta[k] ~= nil then
      local v = meta[k]
      local s = type(v) == "number" and
        (v > 1e4 and util.fmt_num(v) or ("%.5g"):format(v)) or tostring(v)
      parts[#parts+1] = k .. "=" .. s
      shown[k] = true
    end
  end
  for k, v in pairs(meta) do
    if not shown[k] then
      parts[#parts+1] = k .. "=" .. tostring(v):sub(1,20)
    end
  end
  return table.concat(parts, "  ")
end

local function build_list_lines(files, selected, cfg)
  local W     = (cfg.width or 84) - 4
  local lines = {}
  local hls   = {}

  local function push(text, hl_list)
    local row = #lines
    lines[#lines+1] = text
    if hl_list then
      for _, h in ipairs(hl_list) do h.row = row; hls[#hls+1] = h end
    end
  end

  push("  " .. (cfg.icons.ckpt or "󰆓") .. "  Checkpoint Manager  (" .. #files .. " found)",
    { {c0=0, c1=-1, hl="MlbuddyTitle"} })
  push(string.rep("─", W))
  push(string.format("  %-40s  %-10s  %-18s", "Name", "Size", "Modified"),
    { {c0=0, c1=-1, hl="MlbuddyDim"} })
  push(string.rep("─", W))

  if #files == 0 then
    push("  (no checkpoints found in scan roots)", { {c0=0, c1=-1, hl="MlbuddyDim"} })
  end

  for i, f in ipairs(files) do
    local name = vim.fn.fnamemodify(f, ":~:.")
    if #name > 50 then name = "…" .. name:sub(-49) end
    local size  = util.file_size_str(f)
    local mtime = util.mtime_str(f)
    local sel   = (i == selected)
    local line  = string.format("  %s %-48s  %-10s  %-18s",
      sel and "▶" or " ", name, size, mtime)
    push(line, { {c0=0, c1=-1, hl=sel and "MlbuddyMetric" or "Normal"} })
  end

  push(""); push(string.rep("─", W))
  push("  [<CR>] inspect  [r] resume from  [dd] delete  [R] rescan  [q] close",
    { {c0=0, c1=-1, hl="MlbuddyDim"} })

  return lines, hls
end

local function build_detail_lines(info, cfg)
  local W     = (cfg.width or 84) - 4
  local lines = {}
  local hls   = {}

  local function push(text, hl_list)
    local row = #lines
    lines[#lines+1] = text
    if hl_list then
      for _, h in ipairs(hl_list) do h.row = row; hls[#hls+1] = h end
    end
  end

  push("  " .. (cfg.icons.ckpt or "󰆓") .. "  " .. vim.fn.fnamemodify(info.path, ":t"),
    { {c0=0, c1=-1, hl="MlbuddyTitle"} })
  push(string.rep("─", W))
  push("  Path   " .. info.path, { {c0=0, c1=9, hl="MlbuddyDim"} })
  push("  Type   " .. (info.type or "?"), { {c0=0, c1=9, hl="MlbuddyDim"} })
  push("  Size   " .. util.fmt_bytes(info.size_bytes or 0), { {c0=0, c1=9, hl="MlbuddyDim"} })
  if info.error then
    push("  Error  " .. info.error, { {c0=0, c1=-1, hl="MlbuddyError"} })
  else
    push("")
    push("  ─── Metadata " .. string.rep("─", W-15), { {c0=0, c1=-1, hl="MlbuddyDim"} })
    push("  " .. fmt_meta(info.metadata or {}), { {c0=0, c1=-1, hl="MlbuddyMetric"} })
    push("")
    push("  ─── Keys (" .. #(info.keys or {}) .. ") " .. string.rep("─", W-20),
      { {c0=0, c1=-1, hl="MlbuddyDim"} })
    local row = "  "
    for _, k in ipairs(info.keys or {}) do
      local part = k .. "  "
      if #row + #part > W then push(row); row = "  " end
      row = row .. part
    end
    if row ~= "  " then push(row) end
  end

  push(""); push(string.rep("─", W))
  push("  [<BS>] back  [r] resume from this checkpoint  [q] close",
    { {c0=0, c1=-1, hl="MlbuddyDim"} })

  return lines, hls
end

-- ── Module state + toggle ─────────────────────────────────────────────────────

local ctx = {
  win=nil, buf=nil, files={}, selected=1, mode="list", detail=nil,
}

local function refresh_render(cfg)
  if not (ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf)) then return end
  local lines, hls
  if ctx.mode == "detail" and ctx.detail then
    lines, hls = build_detail_lines(ctx.detail, cfg)
  else
    lines, hls = build_list_lines(ctx.files, ctx.selected, cfg)
  end
  ui.set_lines(ctx.buf, lines)
  vim.api.nvim_buf_clear_namespace(ctx.buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    local c1 = (h.c1==-1) and (lines[h.row+1] and #lines[h.row+1] or 0) or h.c1
    vim.api.nvim_buf_add_highlight(ctx.buf, NS, h.hl, h.row, h.c0, c1)
  end
end

function M.toggle(cfg)
  if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
    vim.api.nvim_win_close(ctx.win, true); ctx.win=nil; return
  end

  local buf, win = ui.float({
    title  = (cfg.icons.ckpt or "󰆓") .. "  Checkpoints",
    width  = cfg.width  or 84,
    height = cfg.height or 40,
    border = cfg.border,
  })
  ctx.buf=buf; ctx.win=win; ctx.mode="list"; ctx.selected=1

  local km = cfg.checkpoint.keymaps

  ui.map(buf, km.close or "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true); ctx.win=nil
    end
  end, "Close")

  ui.map(buf, "j", function()
    ctx.selected = math.min(ctx.selected+1, #ctx.files)
    refresh_render(cfg)
  end, "Down")

  ui.map(buf, "k", function()
    ctx.selected = math.max(ctx.selected-1, 1)
    refresh_render(cfg)
  end, "Up")

  ui.map(buf, km.inspect or "<CR>", function()
    if ctx.mode == "list" and #ctx.files >= ctx.selected then
      local path   = ctx.files[ctx.selected]
      local python = cfg.runner and cfg.runner.python or util.find_python()
      ctx.mode = "loading"
      ui.set_lines(buf, { "", "  Loading checkpoint…" })
      inspect_ckpt(path, python, function(info)
        ctx.detail = info
        ctx.mode   = "detail"
        refresh_render(cfg)
      end)
    elseif ctx.mode == "detail" then
      ctx.mode = "list"; refresh_render(cfg)
    end
  end, "Inspect / back")

  ui.map(buf, "<BS>", function()
    ctx.mode="list"; refresh_render(cfg)
  end, "Back to list")

  ui.map(buf, "R", function()
    ctx.files = util.scan_files(
      cfg.checkpoint.scan_roots  or { ".", "checkpoints" },
      cfg.checkpoint.extensions  or { ".pt", ".ckpt", ".safetensors", ".bin" },
      cfg.checkpoint.deep_scan
    )
    ctx.selected = 1; ctx.mode = "list"
    refresh_render(cfg)
  end, "Rescan")

  ui.map(buf, "dd", function()
    if #ctx.files == 0 then return end
    local path = ctx.files[ctx.selected]
    vim.ui.select({ "Yes, delete", "No, cancel" },
      { prompt = "Delete " .. vim.fn.fnamemodify(path, ":t") .. "?" },
      function(ch)
        if ch and ch:match("^Yes") then
          vim.fn.delete(path)
          table.remove(ctx.files, ctx.selected)
          ctx.selected = math.min(ctx.selected, #ctx.files)
          refresh_render(cfg)
          ui.info("Deleted " .. path)
        end
      end)
  end, "Delete checkpoint")

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer=buf, once=true, callback=function() ctx.win=nil end,
  })

  -- Initial scan
  ctx.files = util.scan_files(
    cfg.checkpoint.scan_roots or { ".", "checkpoints", "outputs", "runs" },
    cfg.checkpoint.extensions or { ".pt", ".ckpt", ".safetensors", ".bin" },
    cfg.checkpoint.deep_scan
  )
  refresh_render(cfg)
end

return M
