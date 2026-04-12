--- mlbuddy/env/init.lua  (cross-platform)
local ui   = require("mlbuddy.ui")
local util = require("mlbuddy.util")
local plat = require("mlbuddy.platform")
local M    = {}
local NS   = vim.api.nvim_create_namespace("mlbuddy_env")

local function py_ver(py)
  local r = vim.system({ py, "--version" }, { text=true }):wait()
  local out = r.code==0 and (r.stdout~="" and r.stdout or r.stderr) or "?"
  return out:gsub("\n",""):gsub("^Python ","")
end

function M.detect_envs()
  local envs = {}
  local cwd  = vim.fn.getcwd()

  -- 1. Active conda
  local conda_prefix = vim.env.CONDA_PREFIX
  local conda_name   = vim.env.CONDA_DEFAULT_ENV
  if conda_prefix and conda_name then
    local py = plat.python_in_prefix(conda_prefix)
    if plat.executable(py) then
      envs[#envs+1]={name="conda:"..conda_name,type="conda",python=py,
        version=py_ver(py),prefix=conda_prefix,active=true,packages={}}
    end
  end

  -- 2. Active VIRTUAL_ENV
  local active_venv = vim.env.VIRTUAL_ENV
  if active_venv then
    local py = plat.python_in_prefix(active_venv)
    if plat.executable(py) then
      envs[#envs+1]={name=vim.fn.fnamemodify(active_venv,":t"),type="venv",
        python=py,version=py_ver(py),prefix=active_venv,active=true,packages={}}
    end
  end

  -- 3. Local venvs
  for _, vname in ipairs({".venv","venv",".env","env"}) do
    local prefix = plat.join(cwd, vname)
    local py     = plat.python_in_prefix(prefix)
    if plat.executable(py) and prefix~=active_venv then
      envs[#envs+1]={name=vname,type="venv",python=py,version=py_ver(py),
        prefix=prefix,active=false,packages={}}
    end
  end

  -- 4. Poetry
  if vim.fn.filereadable(plat.join(cwd,"pyproject.toml"))==1 then
    local poetry = plat.find_exe("poetry")
    if poetry then
      local r=vim.system({poetry,"env","info","--path"},{text=true}):wait()
      if r.code==0 then
        local prefix=r.stdout:gsub("%s+$","")
        local py=plat.python_in_prefix(prefix)
        if plat.executable(py) then
          envs[#envs+1]={name="poetry",type="poetry",python=py,version=py_ver(py),
            prefix=prefix,active=false,packages={}}
        end
      end
    end
  end

  -- 5. pyenv (all platforms, handles pyenv-win too)
  local pyenv = plat.find_exe("pyenv")
  if pyenv then
    local r=vim.system({pyenv,"which","python"},{text=true}):wait()
    if r.code==0 then
      local py=r.stdout:gsub("%s+$","")
      if plat.executable(py) then
        local ver=vim.system({pyenv,"version-name"},{text=true}):wait()
        local label=plat.is_win and "pyenv-win" or "pyenv"
        envs[#envs+1]={name=label.."  "..(ver.code==0 and ver.stdout:gsub("%s","") or "?"),
          type="pyenv",python=py,version=py_ver(py),
          prefix=vim.fn.fnamemodify(py,":h:h"),active=false,packages={}}
      end
    end
  end

  -- 6. System Python
  local sys_names=plat.is_win and {"python.exe","python3.exe","python"} or {"python3","python"}
  for _, n in ipairs(sys_names) do
    local p=vim.fn.exepath(n)
    if p and p~="" then
      envs[#envs+1]={name="system ("..n..")",type="system",python=p,version=py_ver(p),
        prefix=vim.fn.fnamemodify(p,":h:h"),active=true,packages={}}
      break
    end
  end

  return envs
end

function M.load_packages(env, cb)
  local out={}
  vim.system({env.python,"-m","pip","list","--format=json"},{
    text=true,stdout=function(_,d) if d then out[#out+1]=d end end,
  },function(r)
    vim.schedule(function()
      if r.code~=0 then cb({}); return end
      local d=util.json_decode(table.concat(out))
      local pkgs={}
      for _,p in ipairs(d or {}) do pkgs[#pkgs+1]={name=p.name or "?",version=p.version or "?"} end
      table.sort(pkgs,function(a,b) return a.name:lower()<b.name:lower() end)
      cb(pkgs)
    end)
  end)
end

local ENV_ICONS={venv="󰏗",conda="󰊕",poetry="󰏗",pyenv="󰏗",system="󱀷"}

local function build_lines(envs,selected,show_pkgs,cfg)
  local W=(cfg.width or 84)-4
  local lines,hls={},{}
  local function push(text,hl_list)
    local row=#lines; lines[#lines+1]=text
    if hl_list then for _,h in ipairs(hl_list) do h.row=row; hls[#hls+1]=h end end
  end
  local os_tag=plat.is_win and "[Windows]" or (plat.is_mac and "[macOS]" or "[Linux]")
  push("  "..(cfg.icons.env or "󰢱").."  Env Manager  "..os_tag.."  ("..#envs.." found)",
    {{c0=0,c1=-1,hl="MlbuddyTitle"}})
  push(string.rep("─",W))
  for i,env in ipairs(envs) do
    local sel=(i==selected)
    local icon=ENV_ICONS[env.type] or "󰏗"
    local line=string.format("  %s %s %-22s  Python %-8s%s",
      sel and "▶" or " ",icon,env.name:sub(1,22),env.version,env.active and "  ● active" or "")
    push(line,{{c0=0,c1=-1,hl=sel and "MlbuddyMetric" or (env.active and "MlbuddyGood" or "Normal")}})
    push("    "..plat.native(env.prefix):sub(1,W-6),{{c0=0,c1=-1,hl="MlbuddyDim"}})
    push("    "..env.python,{{c0=0,c1=-1,hl="MlbuddyDim"}})
    if sel and show_pkgs and #(env.packages or {})>0 then
      push(""); push("    ─── Packages ───────────────────────────",{{c0=0,c1=-1,hl="MlbuddyDim"}})
      local col_w=math.floor((W-4)/3); local row2,c="",0; local limit=cfg.env.pkg_limit or 30
      for pi,pkg in ipairs(env.packages) do
        if pi>limit then push("    … "..( #env.packages-limit).." more",{{c0=0,c1=-1,hl="MlbuddyDim"}}); break end
        local s=util.pad(pkg.name.."  "..pkg.version,col_w)
        row2=row2..s; c=c+1
        if c>=3 then push("    "..row2); row2=""; c=0 end
      end
      if row2~="" then push("    "..row2) end
    end
    push("")
  end
  push(string.rep("─",W))
  push("  [<CR>] activate  [p] packages  [R] rescan  [q] close",{{c0=0,c1=-1,hl="MlbuddyDim"}})
  return lines,hls
end

local ctx={win=nil,buf=nil,envs={},selected=1,show_pkgs=false}

local function render(cfg)
  if not(ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf)) then return end
  local lines,hls=build_lines(ctx.envs,ctx.selected,ctx.show_pkgs,cfg)
  ui.set_lines(ctx.buf,lines)
  vim.api.nvim_buf_clear_namespace(ctx.buf,NS,0,-1)
  for _,h in ipairs(hls) do
    local c1=(h.c1==-1) and (lines[h.row+1] and #lines[h.row+1] or 0) or h.c1
    vim.api.nvim_buf_add_highlight(ctx.buf,NS,h.hl,h.row,h.c0,c1)
  end
end

function M.toggle(cfg)
  if ctx.win and vim.api.nvim_win_is_valid(ctx.win) then
    vim.api.nvim_win_close(ctx.win,true); ctx.win=nil; return
  end
  local buf,win=ui.float({title=(cfg.icons.env or "󰢱").."  Env Manager",
    width=cfg.width or 84,height=cfg.height or 40,border=cfg.border})
  ctx.buf=buf; ctx.win=win
  ui.map(buf,cfg.env.keymaps.close or "q",function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win,true); ctx.win=nil end
  end,"Close")
  ui.map(buf,"j",function() ctx.selected=math.min(ctx.selected+1,#ctx.envs); render(cfg) end,"Down")
  ui.map(buf,"k",function() ctx.selected=math.max(ctx.selected-1,1); render(cfg) end,"Up")
  ui.map(buf,"p",function()
    ctx.show_pkgs=not ctx.show_pkgs
    local env=ctx.envs[ctx.selected]
    if ctx.show_pkgs and env and #(env.packages or {})==0 then
      ui.set_lines(buf,{"","  Loading packages…"})
      M.load_packages(env,function(pkgs) env.packages=pkgs; render(cfg) end)
    else render(cfg) end
  end,"Toggle packages")
  ui.map(buf,"R",function() ctx.envs=M.detect_envs(); ctx.selected=1; render(cfg) end,"Rescan")
  ui.map(buf,cfg.env.keymaps.activate or "<CR>",function()
    local env=ctx.envs[ctx.selected]
    if not env then return end
    plat.activate_venv(env.prefix)
    for _,e in ipairs(ctx.envs) do e.active=(e==env) end
    render(cfg); ui.info("Activated "..env.name)
  end,"Activate")
  vim.api.nvim_create_autocmd("WinClosed",{buffer=buf,once=true,callback=function() ctx.win=nil end})
  ctx.envs=M.detect_envs(); ctx.selected=1; render(cfg)
end

function M.active_name()
  if vim.env.CONDA_DEFAULT_ENV then return "conda:"..vim.env.CONDA_DEFAULT_ENV end
  if vim.env.VIRTUAL_ENV then return vim.fn.fnamemodify(vim.env.VIRTUAL_ENV,":t") end
  return ""
end

return M
