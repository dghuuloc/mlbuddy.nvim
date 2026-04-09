--- mlbuddy/env/init.lua
--- Detects Python environments (venv, conda, poetry, pyenv) and shows packages.
local ui   = require("mlbuddy.ui")
local util = require("mlbuddy.util")
local M    = {}

local NS = vim.api.nvim_create_namespace("mlbuddy_env")

-- ── Detection ─────────────────────────────────────────────────────────────────

---@class EnvInfo
---@field name      string
---@field type      string   "venv"|"conda"|"poetry"|"pyenv"|"system"
---@field python    string   path to python executable
---@field version   string
---@field prefix    string   env directory
---@field packages  {name:string, version:string}[]
---@field active    boolean

--- Detect all known environments for the current workspace.
---@return EnvInfo[]
function M.detect_envs()
  local envs = {}
  local cwd  = vim.fn.getcwd()

  -- Helper: get Python version
  local function py_ver(py)
    local r = vim.system({ py, "--version" }, { text=true }):wait()
    return r.code==0 and r.stdout:gsub("\n",""):gsub("^Python ","") or "?"
  end

  -- 1. Active conda env
  local conda_prefix = vim.env.CONDA_PREFIX
  local conda_name   = vim.env.CONDA_DEFAULT_ENV
  if conda_prefix and conda_name then
    local py = conda_prefix .. "/bin/python"
    if vim.fn.executable(py) == 1 then
      envs[#envs+1] = {
        name="conda:" .. conda_name, type="conda",
        python=py, version=py_ver(py), prefix=conda_prefix, active=true, packages={},
      }
    end
  end

  -- 2. Local .venv / venv / .env
  for _, vname in ipairs({ ".venv", "venv", ".env", "env" }) do
    local py = cwd .. "/" .. vname .. "/bin/python"
    if vim.fn.executable(py) == 1 then
      envs[#envs+1] = {
        name=vname, type="venv",
        python=py, version=py_ver(py),
        prefix=cwd.."/"..vname,
        active=(vim.env.VIRTUAL_ENV == cwd.."/"..vname), packages={},
      }
    end
  end

  -- 3. Poetry env (if pyproject.toml exists)
  if vim.fn.filereadable(cwd.."/pyproject.toml") == 1 then
    local r = vim.system({ "poetry", "env", "info", "--path" }, { text=true }):wait()
    if r.code == 0 then
      local prefix = r.stdout:gsub("\n","")
      local py     = prefix .. "/bin/python"
      if vim.fn.executable(py) == 1 then
        envs[#envs+1] = {
          name="poetry", type="poetry",
          python=py, version=py_ver(py), prefix=prefix, active=false, packages={},
        }
      end
    end
  end

  -- 4. pyenv current version
  local r = vim.system({ "pyenv", "which", "python" }, { text=true }):wait()
  if r.code == 0 then
    local py = r.stdout:gsub("\n","")
    if vim.fn.executable(py) == 1 then
      local ver = vim.system({ "pyenv", "version-name" }, { text=true }):wait()
      envs[#envs+1] = {
        name="pyenv:" .. (ver.code==0 and ver.stdout:gsub("\n","") or "?"),
        type="pyenv", python=py, version=py_ver(py),
        prefix=vim.fn.fnamemodify(py, ":h:h"), active=false, packages={},
      }
    end
  end

  -- 5. System Python fallback
  local sys_py = vim.fn.exepath("python3")
  if sys_py == "" then sys_py = vim.fn.exepath("python") end
  if sys_py ~= "" then
    envs[#envs+1] = {
      name="system", type="system",
      python=sys_py, version=py_ver(sys_py),
      prefix=vim.fn.fnamemodify(sys_py, ":h:h"),
      active=true, packages={},
    }
  end

  return envs
end

--- Load installed packages for an environment asynchronously.
---@param env EnvInfo
---@param cb  fun(pkgs: {name:string, version:string}[])
function M.load_packages(env, cb)
  local out = {}
  vim.system(
    { env.python, "-m", "pip", "list", "--format=json" },
    { text=true, stdout=function(_, d) if d then out[#out+1] = d end end },
    function(r)
      vim.schedule(function()
        if r.code ~= 0 then cb({}); return end
        local d = util.json_decode(table.concat(out))
        local pkgs = {}
        for _, p in ipairs(d or {}) do
          pkgs[#pkgs+1] = { name=p.name or "?", version=p.version or "?" }
        end
        table.sort(pkgs, function(a,b) return a.name:lower() < b.name:lower() end)
        cb(pkgs)
      end)
    end
  )
end

-- ── Build lines ───────────────────────────────────────────────────────────────

local ENV_ICONS = { venv="󰏗", conda="󰊕", poetry="󰏗", pyenv="󰏗", system="󱀷" }

local function build_lines(envs, selected, show_pkgs, cfg)
  local W = (cfg.width or 84) - 4
  local lines = {}
  local hls   = {}

  local function push(text, hl_list)
    local row = #lines
    lines[#lines+1] = text
    if hl_list then for _, h in ipairs(hl_list) do h.row=row; hls[#hls+1]=h end end
  end

  push("  " .. (cfg.icons.env or "󰢱") .. "  Environment Manager  (" .. #envs .. " found)",
    { {c0=0, c1=-1, hl="MlbuddyTitle"} })
  push(string.rep("─", W))

  for i, env in ipairs(envs) do
    local sel  = (i == selected)
    local icon = ENV_ICONS[env.type] or "󰏗"
    local mark = env.active and " ●" or "  "
    local line = string.format("  %s %s %s  Python %s  %s",
      sel and "▶" or " ", icon, env.name, env.version,
      mark .. (env.active and " active" or ""))
    push(line, {
      { c0=0, c1=-1, hl=sel and "MlbuddyMetric" or (env.active and "MlbuddyGood" or "Normal") },
    })
    push("    " .. env.prefix:sub(1, W-6), { {c0=0, c1=-1, hl="MlbuddyDim"} })

    -- Show packages for selected env
    if sel and show_pkgs and #(env.packages or {}) > 0 then
      push("")
      push("    ─── Installed Packages ─────────────────────────────",
        { {c0=0, c1=-1, hl="MlbuddyDim"} })
      local ncol  = 3
      local col_w = math.floor((W - 4) / ncol)
      local row   = ""
      local c     = 0
      local limit = cfg.env.pkg_limit or 30
      for pi, pkg in ipairs(env.packages) do
        if pi > limit then
          push("    … " .. (#env.packages - limit) .. " more",
            { {c0=0, c1=-1, hl="MlbuddyDim"} })
          break
        end
        local s = util.pad(pkg.name .. "  " .. pkg.version, col_w)
        row = row .. s; c = c + 1
        if c >= ncol then push("    "..row); row=""; c=0 end
      end
      if row ~= "" then push("    "..row) end
    end
    push("")
  end

  push(string.rep("─", W))
  push("  [<CR>] activate  [p] toggle packages  [R] rescan  [q] close",
    { {c0=0, c1=-1, hl="MlbuddyDim"} })
  return lines, hls
end

-- ── State + toggle ────────────────────────────────────────────────────────────

local ctx = { win=nil, buf=nil, envs={}, selected=1, show_pkgs=false }

local function render(cfg)
  if not (ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf)) then return end
  local lines, hls = build_lines(ctx.envs, ctx.selected, ctx.show_pkgs, cfg)
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
    title=(cfg.icons.env or "󰢱").."  Environment Manager",
    width=cfg.width or 84, height=cfg.height or 40, border=cfg.border,
  })
  ctx.buf=buf; ctx.win=win

  ui.map(buf, cfg.env.keymaps.close or "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true); ctx.win=nil
    end
  end, "Close")

  ui.map(buf, "j", function()
    ctx.selected=math.min(ctx.selected+1,#ctx.envs); render(cfg)
  end, "Down")
  ui.map(buf, "k", function()
    ctx.selected=math.max(ctx.selected-1,1); render(cfg)
  end, "Up")

  ui.map(buf, "p", function()
    ctx.show_pkgs = not ctx.show_pkgs
    local env = ctx.envs[ctx.selected]
    if ctx.show_pkgs and env and #(env.packages or {}) == 0 then
      ui.set_lines(buf, { "", "  Loading packages…" })
      M.load_packages(env, function(pkgs)
        env.packages = pkgs; render(cfg)
      end)
    else
      render(cfg)
    end
  end, "Toggle packages")

  ui.map(buf, "R", function()
    ctx.envs = M.detect_envs(); ctx.selected=1; render(cfg)
  end, "Rescan")

  ui.map(buf, cfg.env.keymaps.activate or "<CR>", function()
    local env = ctx.envs[ctx.selected]
    if not env then return end
    -- Update PATH for this Neovim session
    local bin = env.prefix .. "/bin"
    vim.env.PATH = bin .. ":" .. vim.env.PATH
    vim.env.VIRTUAL_ENV = env.prefix
    for _, e in ipairs(ctx.envs) do e.active = (e == env) end
    render(cfg)
    ui.info("Activated " .. env.name)
  end, "Activate env")

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer=buf, once=true, callback=function() ctx.win=nil end,
  })

  ctx.envs    = M.detect_envs()
  ctx.selected = 1
  render(cfg)
end

--- Return active environment name (for statusline).
---@return string
function M.active_name()
  if vim.env.CONDA_DEFAULT_ENV then return "conda:" .. vim.env.CONDA_DEFAULT_ENV end
  if vim.env.VIRTUAL_ENV then
    return vim.fn.fnamemodify(vim.env.VIRTUAL_ENV, ":t")
  end
  return ""
end

return M
