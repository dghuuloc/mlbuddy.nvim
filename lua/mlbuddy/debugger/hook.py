"""
mlbuddy_debug_hook.py
Attach forward + backward hooks to a PyTorch model and emit per-layer stats as JSON.

Usage (from Lua via vim.system):
    python mlbuddy_debug_hook.py <expr> [mode]

mode = "activations" | "gradients" | "shapes" | "weights" | "nan" | "full"
expr = Python expression that evaluates to an nn.Module
"""
import sys, json, math

expr = sys.argv[1] if len(sys.argv) > 1 else "model"
mode = sys.argv[2] if len(sys.argv) > 2 else "full"

result = {
    "expr":   expr,
    "mode":   mode,
    "layers": [],
    "issues": [],
    "error":  None,
}

def safe(v):
    """Convert tensor stat to a plain Python float, handling NaN/Inf."""
    try:
        f = float(v)
        if math.isnan(f): return "nan"
        if math.isinf(f): return "inf" if f > 0 else "-inf"
        return round(f, 6)
    except Exception:
        return None

def tensor_stats(t, name=""):
    """Return a dict of statistics for a single tensor."""
    import torch
    if not isinstance(t, torch.Tensor):
        return None
    t = t.detach().float()
    n    = t.numel()
    flat = t.reshape(-1)
    s = {
        "shape":     list(t.shape),
        "dtype":     str(t.dtype).replace("torch.", ""),
        "numel":     n,
        "mean":      safe(t.mean()),
        "std":       safe(t.std()) if n > 1 else 0.0,
        "min":       safe(t.min()),
        "max":       safe(t.max()),
        "norm":      safe(t.norm()),
        "has_nan":   bool(torch.isnan(t).any()),
        "has_inf":   bool(torch.isinf(t).any()),
        "zeros_pct": round(float((flat == 0).sum()) / n * 100, 2) if n > 0 else 0,
        "neg_pct":   round(float((flat < 0).sum())  / n * 100, 2) if n > 0 else 0,
    }
    # Gradient norm (for weight analysis)
    if hasattr(t, "grad") and t.grad is not None:
        g = t.grad.detach().float()
        s["grad_norm"] = safe(g.norm())
        s["grad_max"]  = safe(g.abs().max())
        s["grad_has_nan"] = bool(torch.isnan(g).any())
    return s

try:
    import torch
    import torch.nn as nn

    # Try to get the model from the expression
    # We try importing common names first
    globs = {"torch": torch, "nn": nn}
    try:
        import torchvision.models as tvm
        globs["tvm"] = tvm
    except ImportError:
        pass
    try:
        import transformers
        globs["transformers"] = transformers
    except ImportError:
        pass

    model = eval(expr, globs)

    if not isinstance(model, nn.Module):
        result["error"] = f"'{expr}' is not an nn.Module (got {type(model).__name__})"
        print(json.dumps(result)); sys.exit(0)

    result["model_class"] = type(model).__name__

    # ── 1. Weight statistics ──────────────────────────────────────────────────
    if mode in ("weights", "full"):
        for name, module in model.named_modules():
            if not list(module.parameters(recurse=False)):
                continue
            layer_info = {
                "name":   name or type(module).__name__,
                "type":   type(module).__name__,
                "params": {},
            }
            for pname, param in module.named_parameters(recurse=False):
                s = tensor_stats(param)
                if s:
                    # Detect weight issues
                    issues = []
                    if s["has_nan"]:
                        issues.append("NaN in weights")
                        result["issues"].append(f"{name}.{pname}: NaN weights")
                    if s["has_inf"]:
                        issues.append("Inf in weights")
                        result["issues"].append(f"{name}.{pname}: Inf weights")
                    if s.get("std") is not None and isinstance(s["std"], float):
                        if s["std"] < 1e-7:
                            issues.append("dead weights (std≈0)")
                            result["issues"].append(f"{name}.{pname}: dead weights (std={s['std']:.2e})")
                        if s["std"] > 100:
                            issues.append("exploding weights")
                            result["issues"].append(f"{name}.{pname}: large weights (std={s['std']:.2e})")
                    s["issues"] = issues
                    layer_info["params"][pname] = s
            result["layers"].append(layer_info)

    # ── 2. Forward hook – capture activation shapes + stats ───────────────────
    if mode in ("activations", "shapes", "nan", "full"):
        hooks      = []
        activations = {}

        def make_hook(name):
            def hook(module, inp, out):
                if isinstance(out, torch.Tensor):
                    activations[name] = {
                        "output": tensor_stats(out, name),
                        "input":  tensor_stats(inp[0], name) if inp and isinstance(inp[0], torch.Tensor) else None,
                    }
                elif isinstance(out, (tuple, list)):
                    # e.g. LSTM returns (output, (h, c))
                    for i, o in enumerate(out):
                        if isinstance(o, torch.Tensor):
                            activations[f"{name}[{i}]"] = {"output": tensor_stats(o, name), "input": None}
                            break
            return hook

        for name, module in model.named_modules():
            if isinstance(module, (
                nn.Linear, nn.Conv1d, nn.Conv2d, nn.Conv3d,
                nn.BatchNorm1d, nn.BatchNorm2d, nn.BatchNorm3d,
                nn.LayerNorm, nn.MultiheadAttention,
                nn.LSTM, nn.GRU, nn.RNN,
                nn.ReLU, nn.GELU, nn.SiLU, nn.Sigmoid, nn.Tanh,
                nn.Dropout, nn.MaxPool2d, nn.AvgPool2d,
                nn.Embedding, nn.Transformer,
            )):
                hooks.append(module.register_forward_hook(make_hook(name or type(module).__name__)))

        # Build a dummy input to run a forward pass
        try:
            # Try to infer input shape from first Conv or Linear layer
            dummy = None
            for name, module in model.named_modules():
                if isinstance(module, nn.Conv2d):
                    c = module.in_channels
                    dummy = torch.zeros(1, c, 224, 224)
                    break
                elif isinstance(module, nn.Linear):
                    dummy = torch.zeros(1, module.in_features)
                    break
                elif isinstance(module, nn.Embedding):
                    dummy = torch.zeros(1, 16, dtype=torch.long)
                    break

            if dummy is not None:
                model.eval()
                with torch.no_grad():
                    try:
                        _ = model(dummy)
                    except Exception as fwd_err:
                        result["forward_error"] = str(fwd_err)

                # Merge activation info into layers list
                for act_name, act_data in activations.items():
                    out_stat = act_data.get("output")
                    if out_stat:
                        # Mark NaN activations as issues
                        if out_stat.get("has_nan"):
                            result["issues"].append(f"{act_name}: NaN in activations")
                        if out_stat.get("has_inf"):
                            result["issues"].append(f"{act_name}: Inf in activations")
                        # Dead neuron detection (ReLU with >80% zeros)
                        if out_stat.get("zeros_pct", 0) > 80:
                            result["issues"].append(
                                f"{act_name}: {out_stat['zeros_pct']:.0f}% dead neurons (zeros)")
                        # Append to result
                        result["layers"].append({
                            "name":       act_name,
                            "type":       "activation",
                            "activation": out_stat,
                        })
        except Exception as run_err:
            result["run_error"] = str(run_err)
        finally:
            for h in hooks:
                h.remove()

    # ── 3. Gradient flow ──────────────────────────────────────────────────────
    if mode in ("gradients", "full"):
        grad_layers = []
        for name, param in model.named_parameters():
            if param.grad is not None:
                gn = float(param.grad.norm())
                issues = []
                if math.isnan(gn):
                    issues.append("NaN gradient")
                    result["issues"].append(f"{name}: NaN gradient")
                elif gn < 1e-7:
                    issues.append("vanishing gradient")
                    result["issues"].append(f"{name}: vanishing gradient (norm={gn:.2e})")
                elif gn > 100:
                    issues.append("exploding gradient")
                    result["issues"].append(f"{name}: exploding gradient (norm={gn:.2e})")
                grad_layers.append({
                    "name":      name,
                    "grad_norm": round(gn, 6),
                    "grad_max":  safe(param.grad.abs().max()),
                    "issues":    issues,
                })
        if grad_layers:
            result["gradient_flow"] = grad_layers

    result["total_params"] = sum(p.numel() for p in model.parameters())
    result["trainable_params"] = sum(p.numel() for p in model.parameters() if p.requires_grad)

except Exception as e:
    import traceback
    result["error"] = str(e)
    result["traceback"] = traceback.format_exc()

print(json.dumps(result))
