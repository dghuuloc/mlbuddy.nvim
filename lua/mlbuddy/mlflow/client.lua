--- mlbuddy.mlflow.client
--- Thin async wrapper around the MLflow REST API v2.
local util = require("mlbuddy.util")
local M    = {}

-- ── Experiments ────────────────────────────────────────────────────────────────

--- Fetch all experiments (max 200).
---@param uri string   tracking URI, e.g. "http://localhost:5000"
---@param cb  fun(ok:boolean, exps:table[])
function M.list_experiments(uri, cb)
  util.http_get(
    uri .. "/api/2.0/mlflow/experiments/search?max_results=200",
    function(ok, body)
      if not ok then return cb(false, {}) end
      local d = util.json_decode(body)
      cb(true, d and d.experiments or {})
    end
  )
end

-- ── Runs ───────────────────────────────────────────────────────────────────────

--- Search runs across one or more experiments.
---@param uri     string
---@param exp_ids string[]
---@param max     integer
---@param cb      fun(ok:boolean, runs:table[])
function M.search_runs(uri, exp_ids, max, cb)
  util.http_post(
    uri .. "/api/2.0/mlflow/runs/search",
    {
      experiment_ids = exp_ids,
      max_results    = max,
      order_by       = { "attributes.start_time DESC" },
    },
    function(ok, body)
      if not ok then return cb(false, {}) end
      local d = util.json_decode(body)
      cb(true, d and d.runs or {})
    end
  )
end

--- Get full run info by ID.
---@param uri    string
---@param run_id string
---@param cb     fun(ok:boolean, run:table|nil)
function M.get_run(uri, run_id, cb)
  util.http_get(
    uri .. "/api/2.0/mlflow/runs/get?run_id=" .. run_id,
    function(ok, body)
      if not ok then return cb(false, nil) end
      local d = util.json_decode(body)
      cb(true, d and d.run or nil)
    end
  )
end

-- ── Metric history ─────────────────────────────────────────────────────────────

--- Fetch metric history for one metric of a run → list of {step,value,timestamp}.
---@param uri    string
---@param run_id string
---@param key    string
---@param cb     fun(ok:boolean, pts:table[])
function M.metric_history(uri, run_id, key, cb)
  local url = string.format(
    "%s/api/2.0/mlflow/metrics/get-history?run_id=%s&metric_key=%s",
    uri, run_id, vim.uri_encode and vim.uri_encode(key) or key
  )
  util.http_get(url, function(ok, body)
    if not ok then return cb(false, {}) end
    local d = util.json_decode(body)
    cb(true, d and d.metrics or {})
  end)
end

-- ── Artifacts ─────────────────────────────────────────────────────────────────

--- List artifacts in a run.
---@param uri    string
---@param run_id string
---@param cb     fun(ok:boolean, files:table[])
function M.list_artifacts(uri, run_id, cb)
  util.http_get(
    string.format("%s/api/2.0/mlflow/artifacts/list?run_id=%s", uri, run_id),
    function(ok, body)
      if not ok then return cb(false, {}) end
      local d = util.json_decode(body)
      cb(true, d and d.files or {})
    end
  )
end

-- ── Status helpers ─────────────────────────────────────────────────────────────

---@param run table  raw run object from MLflow API
---@return string status, string hl
function M.run_status(run)
  local s = run and run.info and run.info.status or "UNKNOWN"
  local map = {
    FINISHED = { "DONE",    "MlbuddyGood"  },
    RUNNING  = { "RUN ",    "MlbuddyWarn"  },
    FAILED   = { "FAIL",    "MlbuddyError" },
    KILLED   = { "KILL",    "MlbuddyError" },
  }
  local entry = map[s] or { s:sub(1,4), "MlbuddyDim" }
  return entry[1], entry[2]
end

--- Extract a map of metric keys → last value from a run.
---@param run table
---@return table<string,number>
function M.last_metrics(run)
  local out = {}
  local metrics = run and run.data and run.data.metrics or {}
  for _, m in ipairs(metrics) do
    out[m.key] = m.value
  end
  return out
end

--- Extract params map.
---@param run table
---@return table<string,string>
function M.params(run)
  local out = {}
  local params = run and run.data and run.data.params or {}
  for _, p in ipairs(params) do
    out[p.key] = p.value
  end
  return out
end

return M
