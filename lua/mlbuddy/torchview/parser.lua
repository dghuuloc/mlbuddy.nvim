--- mlbuddy.torchview.parser
--- Treesitter-based parser for PyTorch nn.Module subclasses.
--- Extracts layers, estimated parameter counts, and source locations.
local M = {}

-- ── Known layer → param-count estimators ─────────────────────────────────────
-- Each value is a function(args: int[]) → integer param count.
-- `args` are the positional integer arguments passed to the constructor.

local PARAM_EST = {
  Linear              = function(a) return (a[1] or 0) * (a[2] or 0) + (a[2] or 0) end,
  Bilinear            = function(a) return (a[1] or 0) * (a[2] or 0) * (a[3] or 0) + (a[3] or 0) end,
  Embedding           = function(a) return (a[1] or 0) * (a[2] or 0) end,
  EmbeddingBag        = function(a) return (a[1] or 0) * (a[2] or 0) end,
  Conv1d              = function(a) return (a[1] or 0) * (a[2] or 0) * (a[3] or 1) + (a[2] or 0) end,
  Conv2d              = function(a) return (a[1] or 0) * (a[2] or 0) * (a[3] or 1) * (a[3] or 1) + (a[2] or 0) end,
  Conv3d              = function(a) return (a[1] or 0) * (a[2] or 0) * (a[3] or 1)^3 + (a[2] or 0) end,
  ConvTranspose1d     = function(a) return (a[1] or 0) * (a[2] or 0) * (a[3] or 1) end,
  ConvTranspose2d     = function(a) return (a[1] or 0) * (a[2] or 0) * (a[3] or 1)^2 end,
  LayerNorm           = function(a) return 2 * (a[1] or 0) end,
  BatchNorm1d         = function(a) return 2 * (a[1] or 0) end,
  BatchNorm2d         = function(a) return 2 * (a[1] or 0) end,
  BatchNorm3d         = function(a) return 2 * (a[1] or 0) end,
  GroupNorm           = function(a) return 2 * (a[2] or 0) end,
  InstanceNorm1d      = function(a) return 2 * (a[1] or 0) end,
  InstanceNorm2d      = function(a) return 2 * (a[1] or 0) end,
  MultiheadAttention  = function(a) return 4 * (a[1] or 0) * (a[1] or 0) end,
  TransformerEncoder  = function(_) return -1 end,
  TransformerDecoder  = function(_) return -1 end,
  GRU                 = function(a)
    local i, h = a[1] or 0, a[2] or 0
    return 3 * (i * h + h * h + h)
  end,
  LSTM                = function(a)
    local i, h = a[1] or 0, a[2] or 0
    return 4 * (i * h + h * h + h)
  end,
  RNN                 = function(a)
    local i, h = a[1] or 0, a[2] or 0
    return i * h + h * h + h
  end,
}

-- Layers with 0 trainable params
local NO_PARAM = {
  ReLU=1, LeakyReLU=1, PReLU=1, ELU=1, SELU=1, GELU=1,
  Sigmoid=1, Tanh=1, Softmax=1, LogSoftmax=1, Mish=1, SiLU=1,
  Dropout=1, Dropout2d=1, AlphaDropout=1,
  MaxPool1d=1, MaxPool2d=1, MaxPool3d=1,
  AvgPool1d=1, AvgPool2d=1, AvgPool3d=1,
  AdaptiveAvgPool1d=1, AdaptiveAvgPool2d=1,
  AdaptiveMaxPool1d=1, AdaptiveMaxPool2d=1,
  Flatten=1, Unflatten=1, Identity=1,
  Upsample=1, PixelShuffle=1,
  ZeroPad2d=1, ReflectionPad2d=1,
}

-- ── Public API ────────────────────────────────────────────────────────────────

---@class MlbuddyLayer
---@field name       string     e.g. "self.fc1"
---@field layer_type string     e.g. "Linear"
---@field args       integer[]  positional int args
---@field params     integer    estimated param count; -1 = unknown
---@field line       integer    1-indexed source line

---@class MlbuddyClass
---@field class_name string
---@field base_name  string|nil  e.g. "nn.Module"
---@field layers     MlbuddyLayer[]
---@field line       integer

--- Parse a Python buffer and return all nn.Module subclasses found.
---@param bufnr integer
---@return MlbuddyClass[]
function M.parse(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return {} end
  local ok_lang = pcall(vim.treesitter.get_parser, bufnr, "python")
  if not ok_lang then return {} end

  local parser = vim.treesitter.get_parser(bufnr, "python")
  local tree   = parser:parse()[1]
  if not tree then return {} end
  local root = tree:root()

  -- Query: find class definitions and their __init__ bodies
  local q_src = [[
    (class_definition
      name:      (identifier)        @class_name
      superclasses: (argument_list)? @bases
      body: (block
        (function_definition
          name: (identifier) @fn_name
          (#eq? @fn_name "__init__")
          body: (block) @init_body
        )
      )
    )
  ]]

  local ok_q, query = pcall(vim.treesitter.query.parse, "python", q_src)
  if not ok_q then return {} end

  local results = {}

  for _, match in query:iter_matches(root, bufnr, 0, -1, { all = false }) do
    local cn_node   = match[1]   -- @class_name
    local base_node = match[2]   -- @bases  (may be nil)
    local body_node = match[4]   -- @init_body

    if not (cn_node and body_node) then goto next_match end

    local class_name = vim.treesitter.get_node_text(cn_node, bufnr)
    local base_str   = base_node
      and vim.treesitter.get_node_text(base_node, bufnr)
      or ""

    -- Only process if base includes Module-like parent (or unknown)
    -- We include all classes but mark non-Module ones as "unconfirmed"
    local layers = M._parse_body(body_node, bufnr)
    if #layers > 0 then
      local row = cn_node:start()
      results[#results + 1] = {
        class_name = class_name,
        base_name  = base_str ~= "" and base_str or nil,
        layers     = layers,
        line       = row + 1,
      }
    end

    ::next_match::
  end

  return results
end

-- ── Internal helpers ──────────────────────────────────────────────────────────

--- Walk an __init__ body for `self.attr = nn.XXX(...)` assignments.
function M._parse_body(body_node, bufnr)
  local layers = {}

  for child in body_node:iter_children() do
    local t = child:type()

    if t == "expression_statement" then
      local inner = child:named_child(0)
      if inner and inner:type() == "assignment" then
        local layer = M._try_layer(inner, bufnr)
        if layer then layers[#layers + 1] = layer end
      end

    elseif t == "if_statement" or t == "for_statement" or t == "with_statement" then
      -- recurse into nested blocks (e.g. conditional layer construction)
      for sub in child:iter_children() do
        if sub:type() == "block" then
          local sub_layers = M._parse_body(sub, bufnr)
          for _, l in ipairs(sub_layers) do layers[#layers + 1] = l end
        end
      end
    end
  end

  return layers
end

--- Try to parse an assignment node as a layer assignment.
---@return MlbuddyLayer|nil
function M._try_layer(assign_node, bufnr)
  local lhs = assign_node:named_child(0)
  local rhs = assign_node:named_child(1)
  if not (lhs and rhs) then return nil end

  -- LHS must be `self.something`
  if lhs:type() ~= "attribute" then return nil end
  local obj  = lhs:named_child(0)
  local attr = lhs:named_child(1)
  if not (obj and attr) then return nil end
  if vim.treesitter.get_node_text(obj, bufnr) ~= "self" then return nil end

  -- RHS must be a call
  if rhs:type() ~= "call" then return nil end
  local fn_node = rhs:named_child(0)
  if not fn_node then return nil end

  local fn_text    = vim.treesitter.get_node_text(fn_node, bufnr)
  local layer_type = fn_text:match("%.([A-Za-z][A-Za-z0-9_]*)$")
                  or fn_text:match("^([A-Za-z][A-Za-z0-9_]*)$")
  if not layer_type then return nil end

  local attr_name = vim.treesitter.get_node_text(attr, bufnr)
  local args      = M._int_args(rhs, bufnr)
  local est       = PARAM_EST[layer_type]
  local params    = est and est(args) or (NO_PARAM[layer_type] and 0 or -1)
  local row       = assign_node:start()

  return {
    name       = "self." .. attr_name,
    layer_type = layer_type,
    args       = args,
    params     = params,
    line       = row + 1,
  }
end

--- Extract leading integer positional arguments from a call node.
function M._int_args(call_node, bufnr)
  local args     = {}
  local arg_list = call_node:named_child(1)
  if not arg_list then return args end

  for child in arg_list:iter_children() do
    local ct = child:type()
    if ct == "integer" then
      args[#args + 1] = tonumber(vim.treesitter.get_node_text(child, bufnr)) or 0
    elseif ct == "unary_operator" then
      -- e.g. -1
      local operand = child:named_child(0)
      local op_text = vim.treesitter.get_node_text(child:child(0), bufnr)
      if operand and operand:type() == "integer" and op_text == "-" then
        args[#args + 1] = -(tonumber(vim.treesitter.get_node_text(operand, bufnr)) or 0)
      end
    elseif ct == "keyword_argument" then
      local val = child:named_child(1)
      if val and val:type() == "integer" then
        args[#args + 1] = tonumber(vim.treesitter.get_node_text(val, bufnr)) or 0
      end
    end
    if #args >= 8 then break end  -- enough for any known layer
  end

  return args
end

return M
