"""
mlbuddy_debug_hook.py
Attach forward + backward hooks to a PyTorch model and emit per-layer stats as JSON.

Usage (from Lua via vim.system):
    python mlbuddy_debug_hook.py <expr> [mode]

mode = "activations" | "gradients" | "shapes" | "weights" | "nan" | "full"
expr = Python expression that evaluates to an nn.Module
"""
import inspect
import json
import math
import os
import sys
import traceback

expr = sys.argv[1] if len(sys.argv) > 1 else "model"
mode = sys.argv[2] if len(sys.argv) > 2 else "full"

DUMMY_BATCH_SIZE = int(os.getenv("MLBUDDY_DUMMY_BATCH_SIZE", "1"))
DUMMY_SEQ_LEN = int(os.getenv("MLBUDDY_DUMMY_SEQ_LEN", "16"))
DUMMY_IMAGE_SIZE = int(os.getenv("MLBUDDY_DUMMY_IMAGE_SIZE", "224"))

result = {
    "expr": expr,
    "mode": mode,
    "layers": [],
    "issues": [],
    "notes": [],
    "error": None,
}


def safe(v):
    try:
        f = float(v)
        if math.isnan(f):
            return "nan"
        if math.isinf(f):
            return "inf" if f > 0 else "-inf"
        return round(f, 6)
    except Exception:
        return None


def tensor_stats(t):
    import torch

    if not isinstance(t, torch.Tensor):
        return None
    base = t.detach()
    work = base.float()
    n = work.numel()
    flat = work.reshape(-1)
    s = {
        "shape": list(base.shape),
        "dtype": str(base.dtype).replace("torch.", ""),
        "device": str(base.device),
        "numel": n,
        "mean": safe(work.mean()) if n > 0 else None,
        "std": safe(work.std()) if n > 1 else 0.0,
        "min": safe(work.min()) if n > 0 else None,
        "max": safe(work.max()) if n > 0 else None,
        "norm": safe(work.norm()) if n > 0 else None,
        "has_nan": bool(torch.isnan(work).any()) if n > 0 else False,
        "has_inf": bool(torch.isinf(work).any()) if n > 0 else False,
        "zeros_pct": round(float((flat == 0).sum()) / n * 100, 2) if n > 0 else 0,
        "neg_pct": round(float((flat < 0).sum()) / n * 100, 2) if n > 0 else 0,
    }
    if hasattr(base, "grad") and base.grad is not None:
        g = base.grad.detach().float()
        s["grad_norm"] = safe(g.norm())
        s["grad_max"] = safe(g.abs().max())
        s["grad_has_nan"] = bool(torch.isnan(g).any())
    return s


def short_traceback(exc):
    tb = traceback.format_exc().strip()
    return "\n".join(tb.splitlines()[-20:]) or str(exc)


def infer_device(model):
    import torch

    for p in model.parameters():
      return p.device
    for b in model.buffers():
      return b.device
    return torch.device("cpu")


def dummy_from_signature(model, device):
    import torch
    import torch.nn as nn

    for _, module in model.named_modules():
        if isinstance(module, nn.Conv2d):
            return torch.zeros(DUMMY_BATCH_SIZE, module.in_channels, DUMMY_IMAGE_SIZE, DUMMY_IMAGE_SIZE, device=device)
        if isinstance(module, nn.Conv1d):
            return torch.zeros(DUMMY_BATCH_SIZE, module.in_channels, DUMMY_SEQ_LEN, device=device)
        if isinstance(module, nn.Conv3d):
            return torch.zeros(DUMMY_BATCH_SIZE, module.in_channels, 8, 8, 8, device=device)
        if isinstance(module, nn.Linear):
            return torch.zeros(DUMMY_BATCH_SIZE, module.in_features, device=device)
        if isinstance(module, nn.Embedding):
            return torch.zeros(DUMMY_BATCH_SIZE, DUMMY_SEQ_LEN, dtype=torch.long, device=device)

    try:
        sig = inspect.signature(model.forward)
        params = list(sig.parameters.values())[1:]
        if len(params) == 1:
            return torch.zeros(DUMMY_BATCH_SIZE, 3, DUMMY_IMAGE_SIZE, DUMMY_IMAGE_SIZE, device=device)
    except Exception:
        pass

    return None


def run_forward(model):
    import torch

    dummy = dummy_from_signature(model, infer_device(model))
    if dummy is None:
        result["notes"].append(
            "Could not infer a safe dummy input. Forward activations may be unavailable for multi-input or highly custom models."
        )
        return None

    model.eval()
    with torch.no_grad():
        return model(dummy)


try:
    import torch
    import torch.nn as nn

    globs = {"torch": torch, "nn": nn}
    try:
        import torchvision.models as tvm
        globs["tvm"] = tvm
    except Exception:
        pass
    try:
        import transformers
        globs["transformers"] = transformers
    except Exception:
        pass

    try:
        model = eval(expr, globs)
    except Exception as exc:
        result["error"] = (
            f"Could not evaluate expression '{expr}' in the helper Python process: {exc}. "
            "If this symbol only exists in the paused DAP frame, the standalone hook process cannot access it. "
            "Use an importable expression or construct the model in a normal Python module scope."
        )
        result["traceback"] = short_traceback(exc)
        print(json.dumps(result))
        sys.exit(0)

    if not isinstance(model, nn.Module):
        result["error"] = f"'{expr}' is not an nn.Module (got {type(model).__name__})"
        print(json.dumps(result))
        sys.exit(0)

    result["model_class"] = type(model).__name__
    result["device"] = str(infer_device(model))

    if mode in ("weights", "full"):
        for name, module in model.named_modules():
            if not list(module.parameters(recurse=False)):
                continue
            layer_info = {
                "name": name or type(module).__name__,
                "type": type(module).__name__,
                "params": {},
            }
            for pname, param in module.named_parameters(recurse=False):
                s = tensor_stats(param)
                if not s:
                    continue
                issues = []
                if s["has_nan"]:
                    issues.append("NaN in weights")
                    result["issues"].append(f"{name}.{pname}: NaN weights")
                if s["has_inf"]:
                    issues.append("Inf in weights")
                    result["issues"].append(f"{name}.{pname}: Inf weights")
                if isinstance(s.get("std"), float):
                    if s["std"] < 1e-7:
                        issues.append("dead weights (std≈0)")
                        result["issues"].append(f"{name}.{pname}: dead weights (std={s['std']:.2e})")
                    if s["std"] > 100:
                        issues.append("exploding weights")
                        result["issues"].append(f"{name}.{pname}: large weights (std={s['std']:.2e})")
                s["issues"] = issues
                layer_info["params"][pname] = s
            result["layers"].append(layer_info)

    if mode in ("activations", "shapes", "nan", "full"):
        hooks = []
        activations = {}

        def make_hook(name):
            def hook(module, inp, out):
                if isinstance(out, torch.Tensor):
                    activations[name] = {
                        "output": tensor_stats(out),
                        "input": tensor_stats(inp[0]) if inp and isinstance(inp[0], torch.Tensor) else None,
                    }
                elif isinstance(out, (tuple, list)):
                    for i, o in enumerate(out):
                        if isinstance(o, torch.Tensor):
                            activations[f"{name}[{i}]"] = {"output": tensor_stats(o), "input": None}
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

        try:
            try:
                _ = run_forward(model)
            except Exception as exc:
                result["forward_error"] = str(exc)
                result["traceback"] = short_traceback(exc)
                result["notes"].append(
                    "Forward pass failed while running a generated dummy input. This often happens for multi-input models, token/mask based models, or device-sensitive code."
                )

            for act_name, act_data in activations.items():
                out_stat = act_data.get("output")
                if not out_stat:
                    continue
                if out_stat.get("has_nan"):
                    result["issues"].append(f"{act_name}: NaN in activations")
                if out_stat.get("has_inf"):
                    result["issues"].append(f"{act_name}: Inf in activations")
                if out_stat.get("zeros_pct", 0) > 80:
                    result["issues"].append(f"{act_name}: {out_stat['zeros_pct']:.0f}% dead neurons (zeros)")
                result["layers"].append({
                    "name": act_name,
                    "type": "activation",
                    "activation": out_stat,
                })
        except Exception as exc:
            result["run_error"] = str(exc)
            result["traceback"] = short_traceback(exc)
        finally:
            for h in hooks:
                try:
                    h.remove()
                except Exception:
                    pass

    if mode in ("gradients", "full"):
        grad_layers = []
        any_grad = False
        for name, param in model.named_parameters():
            if param.grad is not None:
                any_grad = True
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
                    "name": name,
                    "grad_norm": round(gn, 6),
                    "grad_max": safe(param.grad.abs().max()),
                    "issues": issues,
                })
        if grad_layers:
            result["gradient_flow"] = grad_layers
        elif mode in ("gradients", "full"):
            result["notes"].append(
                "No gradients were present on model parameters. This helper does not run a real training step, so gradient flow is only visible when the provided model already has .grad values."
            )

    result["total_params"] = sum(p.numel() for p in model.parameters())
    result["trainable_params"] = sum(p.numel() for p in model.parameters() if p.requires_grad)

except Exception as exc:
    result["error"] = str(exc)
    result["traceback"] = short_traceback(exc)

print(json.dumps(result))
