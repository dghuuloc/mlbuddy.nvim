--- mlbuddy/util.lua  ── Enterprise utilities (cross-platform)
local M = {}
local _plat = nil   -- lazy-loaded platform module

local function plat()
  if not _plat then _plat = require("mlbuddy.platform") end
  return _plat
end

-- ── Numbers ──────────────────────────────────────────────────────────────────

function M.fmt_num(n)
  n = tonumber(n) or 0
  if n >= 1e9  then return ("%.2fB"):format(n/1e9)  end
  if n >= 1e6  then return ("%.2fM"):format(n/1e6)  end
  if n >= 1e3  then return ("%.1fK"):format(n/1e3)  end
  return tostring(math.floor(n))
end

function M.fmt_bytes(b)
  b = tonumber(b) or 0
  if b >= 1073741824 then return ("%.2f GiB"):format(b/1073741824) end
  if b >= 1048576    then return ("%.1f MiB"):format(b/1048576)    end
  if b >= 1024       then return ("%.0f KiB"):format(b/1024)       end
  return b .. " B"
end

function M.fmt_secs(s)
  s = math.floor(s or 0)
  if s < 60    then return s .. "s"
  elseif s < 3600 then return ("%dm%02ds"):format(math.floor(s/60), s%60)
  else              return ("%dh%02dm"):format(math.floor(s/3600), math.floor((s%3600)/60))
  end
end

function M.clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

function M.pad(s, w, align)
  s = tostring(s)
  local len = vim.fn.strdisplaywidth(s)
  if len >= w then return s:sub(1, w-1).."…" end
  local sp = string.rep(" ", w-len)
  if align == "right"  then return sp..s end
  if align == "center" then local l=math.floor((w-len)/2); return string.rep(" ",l)..s..string.rep(" ",w-len-l) end
  return s..sp
end

-- ── EMA / smoothing ──────────────────────────────────────────────────────────

---@param values number[]
---@param window integer
---@return number[]
function M.smooth_ema(values, window)
  if window <= 1 or #values == 0 then return values end
  local alpha = 2 / (window + 1)
  local out   = { values[1] }
  for i = 2, #values do
    out[i] = alpha * values[i] + (1 - alpha) * out[i-1]
  end
  return out
end

-- ── Progress bar ─────────────────────────────────────────────────────────────

---@param pct   number   0..1
---@param width integer
---@param style "block"|"arrow"|"dots"
---@return string
function M.progress_bar(pct, width, style)
  pct = M.clamp(pct, 0, 1)
  style = style or "block"
  local filled = math.floor(pct * width + 0.5)
  local empty  = width - filled

  if style == "arrow" then
    local f = string.rep("━", math.max(0, filled-1))
    local h = filled > 0 and "▶" or ""
    return f .. h .. string.rep("─", empty)
  elseif style == "dots" then
    return string.rep("●", filled) .. string.rep("○", empty)
  else  -- block
    local BLOCKS = {"▏","▎","▍","▌","▋","▊","▉","█"}
    local full_cells = math.floor(pct * width)
    local frac       = (pct * width) - full_cells
    local bar = string.rep("█", full_cells)
    if frac > 0.1 and full_cells < width then
      bar = bar .. BLOCKS[math.floor(frac * 8) + 1]
      bar = bar .. string.rep("░", width - full_cells - 1)
    else
      bar = bar .. string.rep("░", width - full_cells)
    end
    return bar
  end
end

-- ── Sparkline ─────────────────────────────────────────────────────────────────

function M.sparkline(values, width)
  if #values == 0 then return string.rep("─", width) end
  local B = {"▁","▂","▃","▄","▅","▆","▇","█"}
  local mn, mx = math.huge, -math.huge
  for _, v in ipairs(values) do if v==v then if v<mn then mn=v end; if v>mx then mx=v end end end
  if mn == mx then return string.rep("▄", width) end
  local out = {}
  for i = 1, width do
    local idx  = math.max(1, math.floor((i-1)*(#values-1)/(width-1)+1))
    local v    = values[idx]
    local bi   = v ~= v and 1 or M.clamp(math.floor((v-mn)/(mx-mn)*8)+1, 1, 8)
    out[i] = B[bi]
  end
  return table.concat(out)
end

-- ── 2D ASCII Chart Engine ────────────────────────────────────────────────────
-- Renders a proper cartesian chart with labelled axes, grid, and N series.
--
-- opts = {
--   width     = 60,
--   height    = 14,
--   title     = "Training Loss",
--   x_label   = "step",
--   y_label   = "loss",
--   y_min     = nil,   -- auto
--   y_max     = nil,
--   series    = {
--     { name = "train", values = {…}, color = "MlbuddyGood" },
--     { name = "val",   values = {…}, color = "MlbuddyWarn" },
--   }
-- }
-- Returns: { lines = string[], hls = {{row,c0,c1,hl}} }

local BRAILLE = {
  [0]  = "⠀", [1]  = "⠁", [2]  = "⠂", [3]  = "⠃",
  [4]  = "⠄", [5]  = "⠅", [6]  = "⠆", [7]  = "⠇",
  [8]  = "⠈", [9]  = "⠉", [10] = "⠊", [11] = "⠋",
  [12] = "⠌", [13] = "⠍", [14] = "⠎", [15] = "⠏",
  [16] = "⠐", [17] = "⠑", [18] = "⠒", [19] = "⠓",
  [20] = "⠔", [21] = "⠕", [22] = "⠖", [23] = "⠗",
  [24] = "⠘", [25] = "⠙", [26] = "⠚", [27] = "⠛",
  [28] = "⠜", [29] = "⠝", [30] = "⠞", [31] = "⠟",
  [32] = "⠠", [33] = "⠡", [34] = "⠢", [35] = "⠣",
  [36] = "⠤", [37] = "⠥", [38] = "⠦", [39] = "⠧",
  [40] = "⠨", [41] = "⠩", [42] = "⠪", [43] = "⠫",
  [44] = "⠬", [45] = "⠭", [46] = "⠮", [47] = "⠯",
  [48] = "⠰", [49] = "⠱", [50] = "⠲", [51] = "⠳",
  [52] = "⠴", [53] = "⠵", [54] = "⠶", [55] = "⠷",
  [56] = "⠸", [57] = "⠹", [58] = "⠺", [59] = "⠻",
  [60] = "⠼", [61] = "⠽", [62] = "⠾", [63] = "⠿",
}

---@param opts table
---@return {lines:string[], hls:table[]}
function M.chart2d(opts)
  opts = opts or {}
  local W        = opts.width  or 60
  local H        = opts.height or 14
  local series   = opts.series or {}
  local title    = opts.title
  local x_label  = opts.x_label or "step"
  local YLABW    = 8     -- y-axis label column width

  -- Gather all values for range
  local mn, mx = math.huge, -math.huge
  local max_pts = 0
  for _, s in ipairs(series) do
    for _, v in ipairs(s.values or {}) do
      if v == v then   -- not NaN
        if v < mn then mn = v end
        if v > mx then mx = v end
      end
    end
    if #(s.values or {}) > max_pts then max_pts = #s.values end
  end
  if opts.y_min then mn = opts.y_min end
  if opts.y_max then mx = opts.y_max end
  if mn == math.huge  then mn = 0 end
  if mx == -math.huge then mx = 1 end
  if mn == mx then mn = mn - 0.5; mx = mx + 0.5 end

  local PLOTW = W - YLABW - 1   -- plot area width in chars

  -- Build 2D char grid (rows = H, cols = PLOTW)
  -- grid[row][col] = char_index (0 = empty, 1..N = series index)
  local grid = {}
  for r = 1, H do
    grid[r] = {}
    for c = 1, PLOTW do grid[r][c] = 0 end
  end
  local grid_hl = {}  -- grid[r][c] = hl group string

  for si, s in ipairs(series) do
    local vals = s.values or {}
    if #vals == 0 then goto skip_series end
    for c = 1, PLOTW do
      local idx = math.max(1, math.floor((c-1) * (#vals-1) / (PLOTW-1) + 1))
      local v   = vals[idx]
      if v == v then  -- not NaN
        local row_frac = (v - mn) / (mx - mn)
        local row      = H - M.clamp(math.floor(row_frac * H + 0.5), 0, H-1)
        row = M.clamp(row, 1, H)
        if grid[row][c] == 0 then
          grid[row][c] = si
          if not grid_hl[row] then grid_hl[row] = {} end
          grid_hl[row][c] = s.color or "Normal"
        end
      end
    end
    ::skip_series::
  end

  -- Series line chars
  local SERIES_CHARS = { "─", "┄", "╌", "·" }

  -- Build output lines
  local lines = {}
  local hls   = {}

  local function push(text, hl_list)
    local row = #lines
    lines[#lines + 1] = text
    if hl_list then
      for _, h in ipairs(hl_list) do h.row = row; hls[#hls + 1] = h end
    end
  end

  -- Title
  if title then
    push(string.rep(" ", YLABW + 1) .. title,
      { { c0 = YLABW + 1, c1 = -1, hl = "MlbuddyTitle" } })
  end

  -- Chart rows
  local y_step = (mx - mn) / H
  for r = 1, H do
    local y_val  = mx - (r - 1) * (mx - mn) / H
    local y_str  = M.pad(("%.3g"):format(y_val), YLABW, "right")
    local sep    = r == H and "└" or "│"

    local row_chars = {}
    local row_hls   = {}
    local c_offset  = YLABW + 1  -- byte offset after y-label+sep

    for c = 1, PLOTW do
      local si = grid[r][c]
      if si > 0 then
        local ch = SERIES_CHARS[si] or "·"
        row_chars[c] = ch
        row_hls[#row_hls+1] = {
          c0 = c_offset + c - 1,
          c1 = c_offset + c,
          hl = (grid_hl[r] and grid_hl[r][c]) or "Normal",
        }
      else
        row_chars[c] = " "
      end
    end

    local line = y_str .. sep .. table.concat(row_chars)
    local hl_list = { { c0 = 0, c1 = YLABW, hl = "MlbuddyDim" } }
    for _, h in ipairs(row_hls) do hl_list[#hl_list+1] = h end
    push(line, hl_list)
  end

  -- X axis
  local x_axis = string.rep(" ", YLABW) .. "└" .. string.rep("─", PLOTW)
  push(x_axis, { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })

  -- X labels (step 0 .. max_pts)
  local x_lab_line = string.rep(" ", YLABW + 1)
  local step_w = math.floor(PLOTW / 4)
  for i = 0, 3 do
    local pts  = math.floor(max_pts * i / 3)
    local lab  = M.pad(tostring(pts), step_w, i == 3 and "right" or "left")
    x_lab_line = x_lab_line .. lab
  end
  push(x_lab_line .. "  " .. x_label, { { c0 = 0, c1 = -1, hl = "MlbuddyDim" } })

  -- Legend
  if #series > 0 then
    local leg = string.rep(" ", YLABW + 1)
    for si, s in ipairs(series) do
      local marker = SERIES_CHARS[si] or "·"
      leg = leg .. marker .. " " .. (s.name or "s"..si) .. "  "
    end
    push(leg)
  end

  return { lines = lines, hls = hls }
end

-- ── HTTP ─────────────────────────────────────────────────────────────────────

function M.http_get(url, cb)
  local out = {}
  vim.system({ "curl", "-sf", "--max-time", "10", url }, {
    text = true, stdout = function(_, d) if d then out[#out+1] = d end end,
  }, function(r)
    vim.schedule(function() cb(r.code==0, table.concat(out)) end)
  end)
end

function M.http_post(url, payload, cb)
  local tmp = vim.fn.tempname()..".json"
  vim.fn.writefile({ vim.json.encode(payload) }, tmp)
  local out = {}
  vim.system({ "curl", "-sf", "--max-time", "10", "-X", "POST",
               "-H", "Content-Type: application/json", "-d", "@"..tmp, url }, {
    text = true, stdout = function(_, d) if d then out[#out+1] = d end end,
  }, function(r)
    vim.fn.delete(tmp)
    vim.schedule(function() cb(r.code==0, table.concat(out)) end)
  end)
end

function M.http_get_auth(url, token, cb)
  local out = {}
  vim.system({ "curl", "-sf", "--max-time", "10",
               "-H", "Authorization: Bearer "..token, url }, {
    text = true, stdout = function(_, d) if d then out[#out+1] = d end end,
  }, function(r)
    vim.schedule(function() cb(r.code==0, table.concat(out)) end)
  end)
end

function M.json_decode(s)
  local ok, v = pcall(vim.json.decode, s)
  return ok and v or nil, ok and nil or v
end

-- ── Timers ────────────────────────────────────────────────────────────────────

function M.timer(ms, fn)
  local t = vim.uv.new_timer()
  t:start(0, ms, vim.schedule_wrap(fn))
  return t
end

function M.defer(ms, fn)
  vim.defer_fn(fn, ms)
end

-- ── Python detection ──────────────────────────────────────────────────────────

--- Find the best Python executable for the current project (cross-platform).
--- Delegates to platform.lua which handles Windows Scripts\ vs Unix bin/ paths.
---@return string
function M.find_python()
  return plat().find_python()
end

--- Run a Python one-liner and return stdout synchronously (blocking, short cmd).
---@param code string
---@param python string|nil
---@return string|nil
function M.python_eval(code, python)
  python = python or M.find_python()
  local r = vim.system({ python, "-c", code }, { text = true }):wait()
  return r.code == 0 and r.stdout:gsub("%s+$", "") or nil
end

--- Write a temp Python script to disk and return its path.
--- Uses platform.lua for the temp file path.
---@param lines string|string[]
---@param suffix string|nil
---@return string path
function M.write_py_script(lines, suffix)
  return plat().write_tmpfile(lines, suffix or "_mlb.py")
end

-- ── Heatmap ───────────────────────────────────────────────────────────────────

function M.heatmap_row(row, width)
  local S = {" ","░","▒","▓","█"}
  local out = {}
  for i = 1, width do
    local idx = math.max(1, math.floor((i-1)*(#row-1)/(width-1)+1))
    local v   = M.clamp(row[idx] or 0, 0, 1)
    out[i] = S[M.clamp(math.floor(v*4)+1, 1, 5)]
  end
  return table.concat(out)
end

-- ── File helpers ──────────────────────────────────────────────────────────────

function M.file_size_str(path)
  local stat = vim.uv.fs_stat(path)
  return stat and M.fmt_bytes(stat.size) or "?"
end

function M.mtime_str(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then return "?" end
  return os.date("%Y-%m-%d %H:%M", stat.mtime.sec)
end

function M.scan_files(roots, exts, deep)
  local results = {}
  local ext_set = {}
  for _, e in ipairs(exts) do ext_set[e] = true end

  local function scan(dir, depth)
    if depth and depth > 4 then return end
    local handle = vim.uv.fs_scandir(dir)
    if not handle then return end
    while true do
      local name, type = vim.uv.fs_scandir_next(handle)
      if not name then break end
      -- Use forward slashes internally (works on Windows too via Neovim)
      local full = dir .. "/" .. name
      if type == "file" then
        local ext = name:match("(%.[^.]+)$") or ""
        if ext_set[ext] then results[#results+1] = full end
      elseif type == "directory" and deep then
        scan(full, (depth or 0) + 1)
      end
    end
  end

  local cwd = vim.fn.getcwd()
  for _, root in ipairs(roots) do
    -- Accept both absolute paths and cwd-relative paths
    local path = (root:sub(1,1) == "/" or root:match("^[A-Za-z]:"))
      and root
      or  (cwd .. "/" .. root)
    scan(path, 0)
  end
  return results
end

return M
