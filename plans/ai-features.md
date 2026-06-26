# Clipx AI features — plan (semantic search + auto-classify / "what's on screen")

Status: **planned, not started** (decided 2026-06-25).
Backend decision: **local-first, cloud opt-in.**

Both features share one foundation; build that first, then layer features on top.
Everything follows the app's existing patterns: GRDB models + migrations, a
background job actor (like `ExportPipeline` / `ThumbnailEngine`), a bridge-style
connector configured in Settings, and **suggestions never silent writes**.

---

## Foundation — `AIConnector` + enrichment queue

- **Provider abstraction** `AIProvider` with capabilities:
  `textEmbedding`, `imageEmbedding`, `vision` (caption / detect / OCR),
  `transcribe`, `chat`/`classify`.
- **Backends (local-first, cloud opt-in):**
  - Apple **Vision** framework — on-device, zero-setup OCR / objects / scene /
    faces. The no-config baseline.
  - **LM Studio / Ollama** — OpenAI-compatible HTTP at `localhost` for
    embeddings + chat/classify (LM Studio already installed). Base URL in
    Settings, mirroring the Stint server field.
  - CoreML CLIP / Whisper — optional on-device embeddings + transcription.
  - **Cloud (opt-in only):** Anthropic / OpenAI key in Settings, off by default;
    used only when the user enables it for higher-quality vision/embeddings.
- **Enrichment queue:** background actor — batched, cancellable, idempotent,
  cached by **source hash** (same as thumbnails). Reuses the sprite frames
  `ThumbnailEngine` already samples → no new media pipeline.
- **New data model (migrations):**
  - `clip_embeddings(clip_id, kind, vector BLOB, dim, model)` — kind ∈
    {text, visual, transcript}.
  - `clip_enrichment(clip_id, transcript, caption, objects_json, ocr_text,
    updated_at, model)`.
- **Settings → AI tab:** backend pick (Local / Cloud), localhost base URL,
  optional cloud key, enable/disable enrichment, "re-run on library".

## Feature 1 — Semantic search

- Embed clip **text** (name + notes + tags + purpose) first, then **visual**
  frames, then **transcript** — in that priority order.
- Store vectors in SQLite; rank by cosine. Brute-force in Swift is fine to
  ~10k clips; adopt sqlite-vec only if the library outgrows that.
- **Hybrid ranking:** fuse existing FTS keyword search with vector similarity
  via reciprocal-rank fusion — strictly better than today's search.
- **UI:** search field gains Keyword / Semantic / Hybrid (or hybrid-by-default);
  "Find similar to this clip" action in the inspector / right-click.
- **Phasing:** P1 text-only (cheap) → P2 visual frames → P3 transcript.

## Feature 2 — AI connector: auto-classify + what's-on-screen

- **What's on screen:** vision over sampled frames → caption + objects + scene +
  on-screen text (OCR). Shown in the inspector, fed into search. Apple Vision
  gives a useful baseline with **no model install**.
- **Auto-tag / auto-purpose, two ways:**
  - *Zero-shot:* model picks from the user's **active Purposes + existing tag
    vocabulary**, given captions/transcript.
  - *Learn-from-your-labels:* lightweight classifier (kNN / logistic regression)
    over clip embeddings, trained on the purposes & tags already assigned —
    improves as the user marks, making the find→mark→tag loop self-reinforcing.
- **Surfacing (suggestions only):** pre-fill the capture card, accept/reject
  "Suggested" chips in the inspector, and a bulk "Auto-tag library" job. Never
  writes labels silently — matches the app's explicit-action ethos.

## Cross-cutting

- **Privacy:** local/on-device default; cloud strictly opt-in per Settings.
- **Performance/cost:** background, batched, on-demand or idle; cache by source
  hash; never block the main thread or startup.
- **No silent caps:** if a job samples/limits, surface it.

## Suggested build order

1. Foundation + Apple Vision baseline → instant "what's on screen", zero config.
2. Text semantic search (P1).
3. "Find similar" + learn-from-labels suggestions.
4. Visual + transcript embeddings → richer semantic search.

## Open questions for when we start

- Embedding model + dim (local CLIP/text model via LM Studio vs CoreML).
- Transcription: Whisper via CoreML vs LM Studio vs cloud.
- Vector store: keep brute-force vs adopt sqlite-vec — depends on library size.
