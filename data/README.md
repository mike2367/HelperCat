# Data

`cat_tone_sft.jsonl` is the frozen local tone-training set. `deepseek_examples/` contains the selected, hand-edited content examples used to extend the DeepSeek stage. Retrieval seed records and vectors live under `retrieval/biomedical_rag/`.

These files are versioned inputs. `deepseek_examples/` feeds the DeepSeek content stage, `retrieval/biomedical_rag/` holds retrieval seed records and vectors, and training outputs are written under the configured output directory.

> [!NOTE]
> I did not write most of the data myself or have the time to go through all of them, some of them may be odd, but was proved sufficient for SFT training. Please contact me if you know any high quality dataset, would be really helpful.