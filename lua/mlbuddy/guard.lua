--- mlbuddy/guard.lua
--- Guards that prevent mlbuddy from interfering with normal Python debugging.
---
--- Core rule: mlbuddy's DAP hooks and auto-features ONLY activate when:
---   1. The current buffer looks like an ML/DL file (has torch/tf/keras imports), OR
---   2. The user has explicitly opened an mlbuddy panel in this session, OR
---   3. The option is explicitly set to true by the user in their config.
---
--- This ensures that debugpy + nvim-dap on a regular Python file is completely
--- unaffected by mlbuddy.

local M = {}

-- ── ML file detection ─────────────────────────────────────────────────────

--- List of import patterns that indicate an ML/DL file.
local ML_PATTERNS = {
  "import%s+torch",
  "from%s+torch",
  "import%s+tensorflow",
  "from%s+tensorflow",
  "import%s+keras",
  "from%s+keras",
  "import%s+jax",
  "from%s+jax",
  "import%s+sklearn",
  "from%s+sklearn",
  "import%s+numpy%s+as%s+np",   -- numpy alone isn't ML, but "as np" is common
  "import%s+paddle",
  "from%s+paddle",
  "import%s+lightning",
  "from%s+lightning",
  "from%s+transformers",
  "import%s+transformers",
  "from%s+accelerate",
  "import%s+accelerate",
  "import%s+diffusers",
  "from%s+diffusers",
}

--- Cache to avoid re-scanning buffers repeatedly.
local _cache = {}   -- bufnr → { result:bool, tick:integer }

--- Return true if the given buffer contains ML library imports.
---@param bufnr integer
---@return boolean
function M.is_ml_file(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end

  -- Check cache (invalidate when buffer changes)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = _cache[bufnr]
  if cached and cached.tick == tick then return cached.result end

  -- Scan first 40 lines only (imports are always at the top)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local scan_to    = math.min(40, line_count)
  local lines      = vim.api.nvim_buf_get_lines(bufnr, 0, scan_to, false)
  local content    = table.concat(lines, "\n")

  local result = false
  for _, pat in ipairs(ML_PATTERNS) do
    if content:match(pat) then
      result = true
      break
    end
  end

  _cache[bufnr] = { result = result, tick = tick }
  return result
end

--- Invalidate the cache for a buffer (call on BufDelete).
---@param bufnr integer
function M.clear_cache(bufnr)
  _cache[bufnr] = nil
end

-- ── DAP session guard ─────────────────────────────────────────────────────

--- Return true if the current DAP session is debugging an ML file.
--- Checks the source file of the current stopped frame.
---@param session table  nvim-dap session object
---@return boolean
function M.is_ml_session(session)
  if not session then return false end

  -- Try the stopped frame's source file first
  local frame = session.current_frame
  if frame and frame.source and frame.source.path then
    local path = frame.source.path
    -- Find a buffer for this path
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
      return M.is_ml_file(bufnr)
    end
    -- Buffer not loaded — do a quick file read
    local ok, lines = pcall(vim.fn.readfile, path, "", 40)
    if ok and #lines > 0 then
      local content = table.concat(lines, "\n")
      for _, pat in ipairs(ML_PATTERNS) do
        if content:match(pat) then return true end
      end
    end
    return false
  end

  -- Fall back to current buffer
  local bufnr = vim.api.nvim_get_current_buf()
  return vim.bo[bufnr].filetype == "python" and M.is_ml_file(bufnr)
end

-- ── Panel-open guard ──────────────────────────────────────────────────────

--- A simple registry of currently-open mlbuddy panels.
--- Used to check "is the user actively using mlbuddy right now?"
local _open_panels = {}   -- name → true/false

function M.panel_opened(name) _open_panels[name] = true  end
function M.panel_closed(name) _open_panels[name] = nil   end

--- Return true if any mlbuddy panel is currently open.
function M.any_panel_open()
  return next(_open_panels) ~= nil
end

--- Return true if the named panel is open.
---@param name string
---@return boolean
function M.panel_open(name)
  return _open_panels[name] == true
end

-- ── DAP listener management ───────────────────────────────────────────────

--- Register a guarded DAP event_stopped listener.
--- The callback only fires when ALL of the following are true:
---   • The session is debugging an ML file  (unless force=true)
---   • `enabled` flag is true in cfg  (the relevant auto_inspect option)
---   • `panel_guard` is nil, or the named panel is currently open
---
---@param key         string   listener name (unique per feature)
---@param cfg         table    mlbuddy config
---@param enabled     boolean  the auto_inspect option value
---@param panel_guard string|nil  if set, only fires when this panel is open
---@param cb          fun(session:table, body:table)
function M.register_dap_listener(key, cfg, enabled, panel_guard, cb)
  local ok, dap = pcall(require, "dap")
  if not ok then return end

  dap.listeners.after.event_stopped[key] = function(session, body)
    -- Gate 1: feature must be enabled in config
    if not enabled then return end

    -- Gate 2: panel must be open (if panel_guard is specified)
    if panel_guard and not M.panel_open(panel_guard) then return end

    -- Gate 3: must be an ML debugging session (or any panel is open)
    -- Gate 3: fixed- strict mode: only real ML debugging sessions
    -- if not M.any_panel_open() and not M.is_ml_session(session) then return end
    if not M.is_ml_seesion(session) then return end

    cb(session, body)
  end
end

--- Remove a DAP listener registered by this module.
---@param key string
function M.remove_dap_listener(key)
  local ok, dap = pcall(require, "dap")
  if not ok then return end
  if dap.listeners.after.event_stopped then
    dap.listeners.after.event_stopped[key] = nil
  end
end

return M
