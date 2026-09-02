# Memory

Memory is user-scoped. Profile facts, conversation events, audit records, and KAIROS candidates are stored beneath the authenticated user's namespace; one user's records are never used as another user's context.

Redis database assignments and encryption are defined in `config/db_config.yaml`. Official storage uses AES for usernames and contents when enabled, with the key kept outside this repository. QA launchers use disposable isolated stores.

KAIROS produces reviewable candidates from the user's own cache. It does not promote inferred or retrieval-only material into durable profile facts.
