--- mlbuddy/gpu/nvidia.lua
--- Parses nvidia-smi and rocm-smi output into unified GPU structs.
local M = {}

-- ── Unified GPU info ──────────────────────────────────────────────────────────

---@class GpuInfo
---@field index        integer
---@field name         string
---@field util_pct     number      0-100
---@field mem_used_mib number
---@field mem_total_mib number
---@field mem_pct      number      0-100
---@field temp_c       number
---@field power_w      number
---@field fan_pct      number
---@field clock_mhz    number
---@field driver       string
---@field cuda_ver     string|nil

-- ── NVIDIA ────────────────────────────────────────────────────────────────────

local NVIDIA_QUERY = table.concat({
  "index", "name",
  "utilization.gpu", "memory.used", "memory.total",
  "temperature.gpu", "power.draw", "fan.speed",
  "clocks.current.graphics", "driver_version",
}, ",")

local function parse_nvidia(stdout)
  local gpus = {}
  for line in stdout:gmatch("[^\n]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" or line:match("^index") then goto next_line end
    local fields = vim.split(line, ", ", { plain=true })
    if #fields < 9 then goto next_line end

    local function num(s)
      s = s and s:match("[%d%.]+") or "0"
      return tonumber(s) or 0
    end

    local mem_used  = num(fields[4])
    local mem_total = num(fields[5])
    gpus[#gpus+1] = {
      index         = tonumber(fields[1]) or 0,
      name          = fields[2] or "GPU",
      util_pct      = num(fields[3]),
      mem_used_mib  = mem_used,
      mem_total_mib = mem_total,
      mem_pct       = mem_total > 0 and (mem_used / mem_total * 100) or 0,
      temp_c        = num(fields[6]),
      power_w       = num(fields[7]),
      fan_pct       = num(fields[8]),
      clock_mhz     = num(fields[9]),
      driver        = fields[10] or "?",
    }
    ::next_line::
  end
  return gpus
end

--- Query all NVIDIA GPUs asynchronously.
---@param cb fun(gpus: GpuInfo[])
function M.query_nvidia(cb)
  local out = {}
  vim.system(
    { "nvidia-smi", "--query-gpu=" .. NVIDIA_QUERY, "--format=csv" },
    { text=true, stdout=function(_, d) if d then out[#out+1] = d end end },
    function(r)
      vim.schedule(function()
        cb(r.code == 0 and parse_nvidia(table.concat(out)) or {})
      end)
    end
  )
end

-- ── ROCm ──────────────────────────────────────────────────────────────────────

local function parse_rocm(stdout)
  local gpus = {}
  local cur  = nil

  for line in stdout:gmatch("[^\n]+") do
    local idx = line:match("^GPU%[(%d+)%]")
    if idx then
      if cur then gpus[#gpus+1] = cur end
      cur = { index=tonumber(idx), name="ROCm GPU "..idx,
              util_pct=0, mem_used_mib=0, mem_total_mib=0, mem_pct=0,
              temp_c=0, power_w=0, fan_pct=0, clock_mhz=0, driver="ROCm" }
    elseif cur then
      local k, v = line:match("^%s+(.-)%s*:%s*(.+)$")
      if k and v then
        if k:match("GPU use") then cur.util_pct = tonumber(v:match("%d+")) or 0
        elseif k:match("VRAM Total") then cur.mem_total_mib = tonumber(v:match("%d+")) or 0
        elseif k:match("VRAM Used") then cur.mem_used_mib  = tonumber(v:match("%d+")) or 0
        elseif k:match("Temperature") then cur.temp_c       = tonumber(v:match("[%d%.]+")) or 0
        elseif k:match("Average Power") then cur.power_w    = tonumber(v:match("[%d%.]+")) or 0
        elseif k:match("Current Clock") then cur.clock_mhz  = tonumber(v:match("%d+")) or 0
        elseif k:match("Card series") then cur.name = v end
      end
    end
  end
  if cur then gpus[#gpus+1] = cur end

  for _, g in ipairs(gpus) do
    if g.mem_total_mib > 0 then
      g.mem_pct = g.mem_used_mib / g.mem_total_mib * 100
    end
  end
  return gpus
end

function M.query_rocm(cb)
  local out = {}
  vim.system(
    { "rocm-smi", "--showuse", "--showmeminfo", "vram", "--showtemp",
      "--showpower", "--showclocks" },
    { text=true, stdout=function(_, d) if d then out[#out+1] = d end end },
    function(r)
      vim.schedule(function()
        cb(r.code == 0 and parse_rocm(table.concat(out)) or {})
      end)
    end
  )
end

-- ── Backend auto-detection ────────────────────────────────────────────────────

function M.detect_backend()
  if vim.fn.executable("nvidia-smi") == 1 then return "nvidia" end
  if vim.fn.executable("rocm-smi")   == 1 then return "rocm"   end
  return nil
end

--- Query GPUs with auto-detected backend.
---@param backend string  "auto"|"nvidia"|"rocm"|"mock"
---@param cb      fun(gpus: GpuInfo[])
function M.query(backend, cb)
  if backend == "mock" then
    -- Synthetic data for testing without GPU
    cb({
      {
        index=0, name="Mock RTX 4090", util_pct=math.random(20,80),
        mem_used_mib=math.random(4000,20000), mem_total_mib=24576,
        mem_pct=0, temp_c=math.random(45,75), power_w=math.random(100,350),
        fan_pct=math.random(30,70), clock_mhz=2520, driver="999.00",
      }
    })
    local g = ...  -- fix mem_pct
    return
  end

  local resolved = backend == "auto" and M.detect_backend() or backend
  if resolved == "nvidia" then M.query_nvidia(cb)
  elseif resolved == "rocm" then M.query_rocm(cb)
  else cb({}) end
end

return M
