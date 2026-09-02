import gc


MODEL_RESOURCE_NAMES = (
    "base_model",
    "model",
    "tokenizer",
    "quantization",
    "inputs",
    "output",
)


def release_model_resources(namespace=None, names=MODEL_RESOURCE_NAMES):
    removed = []
    if namespace is not None:
        for name in names:
            if name in namespace:
                namespace.pop(name, None)
                removed.append(name)

    gc.collect()

    try:
        import torch

        if torch.cuda.is_available():
            torch.cuda.empty_cache()
            torch.cuda.ipc_collect()
    except Exception:
        pass

    return removed
