#!/bin/sh

# Deterministic dogfood summarizer: the app and bundled CLI still exercise the
# real auto-naming hook/session/socket path; only the external model response is
# fixed so the visible title is reproducible.
/bin/echo "Compaction Proof Title"
