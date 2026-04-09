--- mlbuddy/trainer/parser.lua
--- Parses training stdout lines into structured metric events.
--- Handles: PyTorch Lightning, HuggingFace Trainer, tqdm progress,
---          raw key=value / key: value, JSON logs, CSV logs.
local M = {}

-- ── Pattern library ──────────────────────────────────────────────────────────

-- Each entry: { pattern, fn(match) → event|nil }
-- An "event" is: { type, step, epoch, metrics, raw }

local PATTERNS = {}

-- 1. PyTorch Lightning: "Epoch 5/10:  73%|███████▎  | 73/100 [00:14<00:05, loss=0.2341, val_loss=0.2891]"
PATTERNS[#PATTERNS+1] = {
  pat = "Epoch (%d+)/(%d+):.*%[([^%]]+)%]",
  fn  = function(m)
    local epoch, total_epochs, kv_str = m[1], m[2], m[3]
    local metrics = { epoch = tonumber(epoch), total_epochs = tonumber(total_epochs) }
    for k, v in kv_str:gmatch("([%w_]+)=([%d%.%-eE+]+)") do
      metrics[k] = tonumber(v)
    end
    -- also capture step from the bar portion e.g. "73/100"
    local step, total_steps = kv_str:match("(%d+)/(%d+)")
    if step then
      metrics.step = tonumber(step)
      metrics.total_steps = tonumber(total_steps)
    end
    return { type="step", metrics=metrics }
  end,
}

-- 2. HuggingFace Trainer JSON-style log: "{'loss': 0.3456, 'learning_rate': 5e-05, 'epoch': 1.0}"
PATTERNS[#PATTERNS+1] = {
  pat = "^%s*{(.+)}%s*$",
  fn  = function(m)
    local inner = m[1]
    local metrics = {}
    -- Parse key: value pairs (Python dict format)
    for k, v in inner:gmatch([['([%w_]+)'%s*:%s*([%d%.%-eE+]+)]]) do
      metrics[k] = tonumber(v)
    end
    if next(metrics) then return { type="log", metrics=metrics } end
    return nil
  end,
}

-- 3. JSON log line: {"loss": 0.345, "step": 100, ...}
PATTERNS[#PATTERNS+1] = {
  pat = "^%s*{.*}%s*$",
  fn  = function(m)
    local ok, d = pcall(vim.json.decode, m[0])
    if not ok or type(d) ~= "table" then return nil end
    local metrics = {}
    for k, v in pairs(d) do
      if type(v) == "number" then metrics[k] = v end
    end
    return next(metrics) and { type="json", metrics=metrics } or nil
  end,
}

-- 4. "step 100/500, loss: 0.2341, acc: 0.9123"
PATTERNS[#PATTERNS+1] = {
  pat = "step (%d+)/(%d+)",
  fn  = function(m, line)
    local metrics = { step=tonumber(m[1]), total_steps=tonumber(m[2]) }
    for k, v in line:gmatch("([%w_]+):%s*([%d%.%-eE+]+)") do
      metrics[k] = tonumber(v)
    end
    for k, v in line:gmatch("([%w_]+)=([%d%.%-eE+]+)") do
      metrics[k] = tonumber(v)
    end
    return { type="step", metrics=metrics }
  end,
}

-- 5. "epoch 5, step 100, loss 0.234"  (bare numeric pairs)
PATTERNS[#PATTERNS+1] = {
  pat = "epoch[s]?%s+(%d+)",
  fn  = function(m, line)
    local metrics = { epoch=tonumber(m[1]) }
    for k, v in line:gmatch("([%w_]+)[:%s=]+([%d%.%-eE+]+)") do
      if k ~= "epoch" then metrics[k] = tonumber(v) end
    end
    return next(metrics) and { type="step", metrics=metrics } or nil
  end,
}

-- 6. tqdm bare: "100%|████| 500/500 [01:23<00:00,  6.02it/s]"
PATTERNS[#PATTERNS+1] = {
  pat = "(%d+)%%|.-%| (%d+)/(%d+) %[(%d+):(%d+)<",
  fn  = function(m)
    local pct     = tonumber(m[1])
    local step    = tonumber(m[2])
    local total   = tonumber(m[3])
    local elapsed = tonumber(m[4])*60 + tonumber(m[5])
    local eta     = (pct > 0 and pct < 100)
      and elapsed * (100 - pct) / pct or 0
    return { type="progress", metrics={
      pct=pct/100, step=step, total_steps=total,
      elapsed=elapsed, eta=eta,
    }}
  end,
}

-- 7. CSV-style header + values: "epoch,loss,val_loss\n1,0.34,0.41"
-- Handled as stateful multi-line; tracked via parser state (see below)

-- 8. Generic key=value or key: value anywhere in line
PATTERNS[#PATTERNS+1] = {
  pat = "([%w_]+)[=%s:]+([%d%.%-][%d%.%-eE+]*)",
  fn  = function(_, line)
    local metrics = {}
    local KNOWN = {
      loss=1, val_loss=1, train_loss=1, test_loss=1,
      acc=1, accuracy=1, val_acc=1,
      f1=1, precision=1, recall=1, auc=1,
      lr=1, learning_rate=1,
      epoch=1, step=1, batch=1, iteration=1,
      perplexity=1, bleu=1, rouge=1,
      reward=1, kl=1, entropy=1,
      mse=1, mae=1, rmse=1, r2=1,
    }
    for k, v in line:gmatch("([%w_]+)[=%s:]+([%d%.%-][%d%.%-eE+]*)") do
      if KNOWN[k:lower()] then
        metrics[k:lower()] = tonumber(v)
      end
    end
    return next(metrics) and { type="kv", metrics=metrics } or nil
  end,
}

-- ── Public: parse a single line ───────────────────────────────────────────────

---@class TrainerEvent
---@field type    string   "step"|"log"|"json"|"progress"|"kv"
---@field metrics table<string,number>
---@field raw     string

---@param line string
---@param extra_patterns table[]  user-defined additional patterns
---@return TrainerEvent|nil
function M.parse_line(line, extra_patterns)
  if not line or line == "" then return nil end

  -- Try extra patterns first
  for _, ep in ipairs(extra_patterns or {}) do
    local m = { line:match(ep.pattern) }
    if m[1] then
      local ok, ev = pcall(ep.fn, m, line)
      if ok and ev then ev.raw = line; return ev end
    end
  end

  for _, p in ipairs(PATTERNS) do
    local m = { line:match(p.pat) }
    -- For pattern 3 (json), pass the whole line
    if p.pat == "^%s*{.*}%s*$" then m[0] = line end
    if m[1] or (p.pat == "^%s*{.*}%s*$" and line:match(p.pat)) then
      local ok, ev = pcall(p.fn, m, line)
      if ok and ev then ev.raw = line; return ev end
    end
  end

  return nil
end

-- ── Public: rolling metric accumulator ───────────────────────────────────────

---@class MetricHistory
---@field data table<string, number[]>  metric_key → list of values

function M.MetricHistory()
  return { data = {} }
end

---@param hist MetricHistory
---@param ev   TrainerEvent
---@param max_pts integer
function M.update_history(hist, ev, max_pts)
  if not ev or not ev.metrics then return end
  for k, v in pairs(ev.metrics) do
    if type(v) == "number" then
      if not hist.data[k] then hist.data[k] = {} end
      local arr = hist.data[k]
      arr[#arr+1] = v
      if #arr > max_pts then table.remove(arr, 1) end
    end
  end
end

--- Get last N values for a metric key (or all if n is nil).
---@param hist MetricHistory
---@param key  string
---@param n    integer|nil
---@return number[]
function M.get_series(hist, key, n)
  local arr = hist.data[key] or {}
  if not n or n >= #arr then return arr end
  local out = {}
  for i = #arr - n + 1, #arr do out[#out+1] = arr[i] end
  return out
end

--- Compute latest stats for a metric.
---@param hist MetricHistory
---@param key  string
---@return {last:number, min:number, max:number, delta:number}|nil
function M.stats(hist, key)
  local arr = hist.data[key]
  if not arr or #arr == 0 then return nil end
  local mn, mx = arr[1], arr[1]
  for _, v in ipairs(arr) do
    if v < mn then mn = v end
    if v > mx then mx = v end
  end
  return {
    last  = arr[#arr],
    min   = mn, max = mx,
    delta = #arr > 1 and (arr[#arr] - arr[#arr-1]) or 0,
  }
end

return M
