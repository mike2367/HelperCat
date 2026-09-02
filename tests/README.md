# Tests and QA

For interactive WebUI QA, run `src/server/start_UI_testing.bat reset-memory`. The launcher creates disposable WebUI and Redis state, checks service health, and removes its temporary state on exit. Terminal-only checks use `src/server/start_terminal_testing.bat`.

Only the test matrix and acceptance criteria are in `docs/isolated_qa_test_matrix.md` and `docs/QA_test_protocol.md`, such 
documents are for Agents to perform automatic QA tests.

> [!NOTE]
> I did not preserve the code for smoke tests because all of them are vibe-coded without being reviewed, some of them caused problems during development and most of them are useless.
