--- mlbuddy/dataset/init.lua
--- Dataset explorer: introspects HuggingFace datasets, torch Dataset, numpy arrays.
local ui   = require("mlbuddy.ui")
local util = require("mlbuddy.util")
local M    = {}

local NS = vim.api.nvim_create_namespace("mlbuddy_ds")

-- ── Python inspector ──────────────────────────────────────────────────────────

local INSPECT_PY = [[
import sys, json

expr = sys.argv[1]
sample_size = int(sys.argv[2]) if len(sys.argv) > 2 else 5

result = {"name": expr, "type": "unknown", "info": {}, "samples": [], "error": None}

try:
    import builtins
    obj = eval(expr, {"__builtins__": builtins.__dict__}, {})

    def serialize(v):
        if isinstance(v, (int, float, bool, str)):
            return v
        try:
            import numpy as np
            if isinstance(v, np.ndarray):
                return f"ndarray{list(v.shape)} {v.dtype}"
        except ImportError:
            pass
        try:
            import torch
            if isinstance(v, torch.Tensor):
                return f"tensor{list(v.shape)} {v.dtype}"
        except ImportError:
            pass
        return str(type(v).__name__)

    # HuggingFace Dataset
    try:
        from datasets import Dataset, DatasetDict
        if isinstance(obj, (Dataset, DatasetDict)):
            if isinstance(obj, DatasetDict):
                result["type"] = "DatasetDict"
                result["info"]["splits"] = list(obj.keys())
                result["info"]["sizes"]  = {k: len(v) for k, v in obj.items()}
                obj = obj[list(obj.keys())[0]]  # use first split for samples
            else:
                result["type"] = "HuggingFace Dataset"
                result["info"]["size"]     = len(obj)
                result["info"]["features"] = {k: str(v) for k, v in obj.features.items()}
            for i in range(min(sample_size, len(obj))):
                row = {k: serialize(v) for k, v in obj[i].items()}
                result["samples"].append(row)
            raise StopIteration
    except StopIteration:
        pass
    except Exception:
        pass

    # Torch Dataset
    try:
        import torch
        from torch.utils.data import Dataset as TorchDataset
        if isinstance(obj, TorchDataset):
            result["type"] = "PyTorch Dataset"
            result["info"]["size"] = len(obj)
            for i in range(min(sample_size, len(obj))):
                item = obj[i]
                if isinstance(item, (list, tuple)):
                    result["samples"].append([serialize(v) for v in item])
                elif isinstance(item, dict):
                    result["samples"].append({k: serialize(v) for k, v in item.items()})
                else:
                    result["samples"].append(serialize(item))
            raise StopIteration
    except StopIteration:
        pass
    except Exception:
        pass

    # NumPy array
    try:
        import numpy as np
        if isinstance(obj, np.ndarray):
            result["type"] = "numpy.ndarray"
            result["info"] = {
                "shape": list(obj.shape), "dtype": str(obj.dtype),
                "min": float(obj.min()), "max": float(obj.max()),
                "mean": float(obj.mean()), "std": float(obj.std()),
            }
            flat = obj.flatten()
            for i in range(min(sample_size, len(flat))):
                result["samples"].append(float(flat[i]))
            raise StopIteration
    except StopIteration:
        pass
    except Exception:
        pass

    # Generic iterable
    try:
        it = iter(obj)
        result["type"] = "iterable"
        for _ in range(sample_size):
            item = next(it)
            result["samples"].append(serialize(item))
    except Exception as e:
        result["error"] = str(e)

except Exception as e:
    result["error"] = str(e)

print(json.dumps(result))
]]

---@param expr    string
---@param python  string
---@param n       integer  sample count
---@param cb      fun(info: table)
local function inspect_dataset(expr, python, n, cb)
  local script = vim.fn.tempname() .. "_mlb_ds.py"
  vim.fn.writefile(vim.split(INSPECT_PY, "\n"), script)
  local out = {}
  vim.system({ python, script, expr, tostring(n) }, {
    text=true, stdout=function(_, d) if d then out[#out+1] = d end end,
  }, function(r)
    vim.fn.delete(script)
    vim.schedule(function()
      local d = util.json_decode(table.concat(out))
      cb(d or { name=expr, type="?", info={}, samples={}, error="parse failed" })
    end)
  end)
end

-- ── Line builder ──────────────────────────────────────────────────────────────

local function build_lines(info, cfg)
  local W     = (cfg.width or 84) - 4
  local lines = {}
  local hls   = {}

  local function push(text, hl_list)
    local row = #lines
    lines[#lines+1] = text
    if hl_list then
      for _, h in ipairs(hl_list) do h.row=row; hls[#hls+1]=h end
    end
  end

  push("  " .. (cfg.icons.dataset or "󰙬") .. "  Dataset Explorer  ─  " .. (info.name or "?"),
    { {c0=0, c1=-1, hl="MlbuddyTitle"} })
  push(string.rep("─", W))

  if info.error then
    push("  Error: " .. info.error, { {c0=0, c1=-1, hl="MlbuddyError"} })
    push("")
    push("  Tip: position cursor on a dataset variable and press <leader>mD",
      { {c0=0, c1=-1, hl="MlbuddyDim"} })
  else
    push("  Type: " .. (info.type or "?"), { {c0=8, c1=-1, hl="MlbuddyMetric"} })
    push("")
    push("  ─── Info " .. string.rep("─", W-11), { {c0=0, c1=-1, hl="MlbuddyDim"} })
    for k, v in pairs(info.info or {}) do
      local val_str = type(v) == "table" and vim.inspect(v):gsub("\n", "") or tostring(v)
      push(string.format("  %-20s  %s", k, val_str:sub(1, W-24)),
        { {c0=2, c1=22, hl="MlbuddyIdent"}, {c0=24, c1=-1, hl="MlbuddyMetric"} })
    end
    push("")
    push("  ─── Samples (" .. #(info.samples or {}) .. ") " .. string.rep("─", W-20),
      { {c0=0, c1=-1, hl="MlbuddyDim"} })
    for i, s in ipairs(info.samples or {}) do
      local s_str = type(s) == "table"
        and vim.inspect(s):gsub("\n%s*", " "):sub(1, W-10)
        or  tostring(s)
      push(string.format("  [%d]  %s", i, s_str),
        { {c0=2, c1=5, hl="MlbuddyDim"}, {c0=7, c1=-1, hl="Normal"} })
    end
  end

  push(""); push(string.rep("─", W))
  push("  [q] close  [R] re-inspect  — cursor on variable + <leader>mD to inspect",
    { {c0=0, c1=-1, hl="MlbuddyDim"} })
  return lines, hls
end

-- ── Toggle ────────────────────────────────────────────────────────────────────

local ctx = { win=nil, buf=nil, info={name="?", type="?", info={}, samples={}} }

local function render(cfg)
  if not (ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf)) then return end
  local lines, hls = build_lines(ctx.info, cfg)
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
    title  = (cfg.icons.dataset or "󰙬") .. "  Dataset Explorer",
    width  = cfg.width or 84, height = cfg.height or 40, border = cfg.border,
  })
  ctx.buf=buf; ctx.win=win

  ui.map(buf, cfg.dataset.keymaps.close or "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true); ctx.win=nil
    end
  end, "Close")

  ui.map(buf, "R", function()
    local word = vim.fn.expand("<cword>")
    if word == "" then return end
    local python = cfg.runner and cfg.runner.python or util.find_python()
    inspect_dataset(word, python, cfg.dataset.sample_size or 5, function(info)
      ctx.info = info; render(cfg)
    end)
  end, "Re-inspect")

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer=buf, once=true, callback=function() ctx.win=nil end,
  })

  -- Inspect word under cursor immediately
  local word = vim.fn.expand("<cword>")
  if word ~= "" then
    local python = cfg.runner and cfg.runner.python or util.find_python()
    ui.set_lines(buf, { "", "  Inspecting '" .. word .. "'…" })
    inspect_dataset(word, python, cfg.dataset.sample_size or 5, function(info)
      ctx.info = info; render(cfg)
    end)
  else
    render(cfg)
  end
end

return M
