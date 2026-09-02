# Conversation

`query_API.py` exposes the OpenAI-compatible proxy used by Open WebUI. A request is associated with the authenticated user, classified for scope, enriched with that user's memory and bounded retrieval context, sent to the configured backend, and recorded with usage metadata.

`config/` contains route and model settings. `deepseek_client.py` reads the backend endpoint and API key from environment/configuration; keep credentials out of source control.

Start the proxy through `src/server/start_all.bat` so host, port, and per-run storage are configured consistently.
