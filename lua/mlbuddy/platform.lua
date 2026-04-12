--- mlbuddy/platform.lua
--- Cross-platform compatibility layer for Windows / macOS / Linux.
--- Every OS-specific decision in mlbuddy goes through this module.

local M = {}

-- ── OS detection ─────────────────────────────────────────────────────────────

M.is_win   = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
M.is_mac   = vim.fn.has("mac")   == 1
M.is_linux = not M.is_win and not M.is_mac

-- ── Path utilities ────────────────────────────────────────────────────────────

--- OS-native path separator
M.sep = M.is_win and "\\" or "/"

--- Join path components with the native separator.
---@param ...  string
---@return string
function M.join(...)
  local parts = { ... }
  -- Use vim.fs.joinpath when available (Neovim 0.10+), fallback otherwise
  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end
  -- Manual join: normalise each part then concatenate
  local out = {}
  for _, p in ipairs(parts) do
    if p and p ~= "" then
      -- normalise to forward slashes internally; Neovim accepts both on Windows
      out[#out + 1] = p:gsub("[\\/]+$", "")
    end
  end
  return table.concat(out, "/")
end

--- Convert a path to the native OS separator (for display only).
---@param p string
---@return string
function M.native(p)
  if M.is_win then return p:gsub("/", "\\") end
  return p
end

--- Expand ~ to the home directory cross-platform.
---@param p string
---@return string
function M.expand(p)
  return vim.fn.expand(p)
end

--- Check whether a file path exists and is executable.
---@param p string
---@return boolean
function M.executable(p)
  return vim.fn.executable(p) == 1
end

-- ── Python binary resolution ──────────────────────────────────────────────────

--- Return the python executable name for a given prefix directory.
--- On Windows: prefix\Scripts\python.exe
--- On Unix:    prefix/bin/python
---@param prefix string   virtualenv or conda prefix
---@return string
function M.python_in_prefix(prefix)
  if M.is_win then
    return M.join(prefix, "Scripts", "python.exe")
  else
    return M.join(prefix, "bin", "python")
  end
end

--- Return the path to a named script installed in a venv/conda prefix.
--- e.g. M.script_in_prefix(prefix, "ipython") →
---       Windows: prefix\Scripts\ipython.exe
---       Unix:    prefix/bin/ipython
---@param prefix string
---@param name   string  script name (without .exe)
---@return string
function M.script_in_prefix(prefix, name)
  if M.is_win then
    return M.join(prefix, "Scripts", name .. ".exe")
  else
    return M.join(prefix, "bin", name)
  end
end

--- Find the best Python executable for the current project.
--- Checks (in order):
---   1. CONDA_PREFIX\Scripts\python.exe  (active conda env)
---   2. VIRTUAL_ENV\Scripts\python.exe   (active venv)
---   3. .venv / venv / .env / env        (local directories)
---   4. python3 / python3.exe in PATH
---   5. python / python.exe in PATH
---@return string
function M.find_python()
  local cwd = vim.fn.getcwd()

  -- Active conda
  local conda = vim.env.CONDA_PREFIX
  if conda then
    local py = M.python_in_prefix(conda)
    if M.executable(py) then return py end
  end

  -- Active venv
  local venv = vim.env.VIRTUAL_ENV
  if venv then
    local py = M.python_in_prefix(venv)
    if M.executable(py) then return py end
  end

  -- Local virtualenvs
  local local_envs = { ".venv", "venv", ".env", "env" }
  for _, name in ipairs(local_envs) do
    local py = M.python_in_prefix(M.join(cwd, name))
    if M.executable(py) then return py end
  end

  -- PATH lookup
  local names = M.is_win
    and { "python.exe", "python3.exe", "python" }
    or  { "python3", "python" }

  for _, n in ipairs(names) do
    if vim.fn.exepath(n) ~= "" then return n end
  end

  return "python"
end

-- ── Shell / terminal helpers ───────────────────────────────────────────────────

--- Return a shell-command list that wraps `cmd_str` for the current OS.
--- On Windows: { "cmd.exe", "/C", cmd_str }  (for simple one-liners)
--- On Unix:    { "sh", "-c", cmd_str }
---@param cmd_str string
---@return string[]
function M.shell_wrap(cmd_str)
  if M.is_win then
    return { "cmd.exe", "/C", cmd_str }
  else
    return { "sh", "-c", cmd_str }
  end
end

--- Return the correct terminal command list for `vim.fn.termopen`.
--- On Windows, Neovim's :terminal needs the cmd passed differently.
---@param cmd string[]
---@return string[]
function M.term_cmd(cmd)
  -- On Windows, wrap in cmd /C when the first element isn't already cmd.exe
  if M.is_win and cmd[1] ~= "cmd.exe" and cmd[1] ~= "powershell.exe" then
    local inner = {}
    for _, c in ipairs(cmd) do
      -- quote args that contain spaces
      if c:find(" ") then
        inner[#inner + 1] = '"' .. c .. '"'
      else
        inner[#inner + 1] = c
      end
    end
    return { "cmd.exe", "/C", table.concat(inner, " ") }
  end
  return cmd
end

--- Find a script/executable by checking common names (with/without .exe).
---@param name string  base name, e.g. "torchrun"
---@return string|nil
function M.find_exe(name)
  -- On Windows also check name.exe, name.cmd, name.bat
  local candidates = M.is_win
    and { name, name .. ".exe", name .. ".cmd", name .. ".bat" }
    or  { name }
  for _, c in ipairs(candidates) do
    if vim.fn.exepath(c) ~= "" then return c end
  end
  return nil
end

-- ── Environment variable helpers ──────────────────────────────────────────────

--- Return the PATH separator for the current OS.
M.path_sep = M.is_win and ";" or ":"

--- Prepend a directory to PATH for this Neovim session.
---@param dir string
function M.prepend_path(dir)
  vim.env.PATH = dir .. M.path_sep .. (vim.env.PATH or "")
end

--- Set VIRTUAL_ENV and update PATH to activate a venv.
---@param prefix string  venv root directory
function M.activate_venv(prefix)
  local bin = M.is_win and M.join(prefix, "Scripts") or M.join(prefix, "bin")
  vim.env.VIRTUAL_ENV = prefix
  M.prepend_path(bin)
end

-- ── Temp file helpers ─────────────────────────────────────────────────────────

--- Create a named temp file with `content` and return its path.
--- The caller is responsible for deleting it (vim.fn.delete(path)).
---@param content  string[]   lines
---@param suffix   string     e.g. "_mlb.py"
---@return string
function M.write_tmpfile(content, suffix)
  local path = vim.fn.tempname() .. (suffix or ".tmp")
  -- On Windows, tempname() returns something like C:\...\nvimXXXXX
  vim.fn.writefile(type(content) == "string"
    and vim.split(content, "\n")
    or  content,
    path)
  return path
end

-- ── nvidia-smi detection ──────────────────────────────────────────────────────

--- Return the full path to nvidia-smi (handles Windows Program Files location).
---@return string|nil
function M.find_nvidia_smi()
  -- First check PATH
  local p = vim.fn.exepath("nvidia-smi")
  if p ~= "" then return p end
  if M.is_win then
    -- Common Windows install locations
    local candidates = {
      "C:\\Windows\\System32\\nvidia-smi.exe",
      "C:\\Program Files\\NVIDIA Corporation\\NVSMI\\nvidia-smi.exe",
      vim.env.PROGRAMFILES and
        (vim.env.PROGRAMFILES .. "\\NVIDIA Corporation\\NVSMI\\nvidia-smi.exe"),
    }
    for _, c in ipairs(candidates) do
      if c and vim.fn.filereadable(c) == 1 then return c end
    end
  end
  return nil
end

--- Return the full path to rocm-smi (Linux/WSL only).
---@return string|nil
function M.find_rocm_smi()
  if M.is_win then return nil end  -- ROCm not supported on Windows
  local p = vim.fn.exepath("rocm-smi")
  return p ~= "" and p or nil
end

-- ── Conda detection ───────────────────────────────────────────────────────────

--- Return the conda base directory (Windows-aware).
---@return string|nil
function M.conda_base()
  -- CONDA_EXE is set by conda on all platforms
  local exe = vim.env.CONDA_EXE
  if exe then
    -- Windows: ...\Scripts\conda.exe  → parent of Scripts is base
    -- Unix:    .../bin/conda          → parent of bin is base
    return vim.fn.fnamemodify(vim.fn.fnamemodify(exe, ":h"), ":h")
  end
  return nil
end

-- ── Platform info string ──────────────────────────────────────────────────────

function M.info_str()
  local os_name = M.is_win and "Windows" or (M.is_mac and "macOS" or "Linux")
  return string.format("%s  sep='%s'  python=%s",
    os_name, M.sep, M.find_python())
end

return M
