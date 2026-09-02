# Training

`train.py` runs the local adapter/SFT workflow and `data.py` loads the frozen training records. Training outputs and checkpoints are intentionally not included in this repository package.

Before training, set the base model, output directory, device, and batch/sequence limits in `config/train_config.yaml` or environment overrides. Checkpoints are written under the configured output directory.
