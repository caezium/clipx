# Clipx AI — plan (re-scoped)

Status: **planned, not started.**

**Decisions locked:**
- Backend: **local-first, cloud opt-in.**
- Feature set: all 5 workstreams; **auto-clip / moment detection is the flagship**
  (sequenced last because it builds on the others, but it's the headline).
- Auto-clip delivery: **`clipsmith` agent-assisted first** (works today), **native
  in-app pipeline later** — these can run as parallel tracks.
- Suggestions never silent writes; cache by source hash; background, off-main.

## North star

Clipx's loop is **find → mark → tag → (review) → export.** AI should accelerate
every step, not bolt on a chatbot:

| Step | Today | With AI |
|------|-------|---------|
| find | scroll calendar/grid, keyword FTS | **semantic search** + **auto-surfaced good moments** |
| mark | scrub + I/O by hand | **suggested in/out ranges** (auto-clip) |
| tag  | one-tap purpose/tags | **auto-purpose/tags** from your labels + what's on screen |
| review | manual notes | transcripts, captions, on-screen text |

Everything is **suggestions, never silent writes** (matches the app's explicit-
action ethos), **local-first**, background, and cached by source hash.

---

## Shared foundation (Workstream 0)

Both the search and the classify/clip features need the same plumbing, so build
this first.

- **`AIProvider` protocol** — capabilities, each optional per backend:
  `textEmbedding`, `imageEmbedding`, `vision(caption/detect/OCR)`,
  `transcribe`, `chat`/`classify`.
- **Backends (local-first, cloud opt-in):**
  - Apple **Vision** + **Speech** + **NaturalLanguage** — on-device, zero-setup
    OCR / objects / scene / faces, speech-to-text, and text embeddings.
  - **LM Studio / Ollama** — OpenAI-compatible HTTP at `localhost` for stronger
    embeddings + chat/classify (LM Studio already installed). Base URL in Settings.
  - CoreML CLIP / Whisper — optional heavier on-device models.
  - **Cloud (opt-in only):** Anthropic / OpenAI key in Settings, off by default.
- **`EnrichmentQueue`** — a new `AppEnvironment` service beside `thumbnailEngine`
  / `markerStore`: background actor, batched, cancellable, idempotent, **cached
  by `source.hash`**. Reuses the sprite frames `ThumbnailEngine.generateSprite`
  already samples (~10 frames @ 240×135) → no new media pipeline for vision.
- **Settings → AI tab** — backend pick (Local / Cloud), localhost base URL,
  optional cloud key, per-capability enable toggles, "(re)run on library".

### Data model (new migrations)

- `source_enrichment(source_id PK, transcript TEXT, transcript_segments JSON,
  caption TEXT, ocr_text TEXT, objects JSON, scene TEXT, model TEXT, updated_at)`
  — per-source because vision/transcription analyze the *file*, not each clip.
- `clip_embeddings(clip_id, kind TEXT, vector BLOB, dim INT, model TEXT)`
  — kind ∈ {text, visual, transcript}. (Could also embed at source/frame level.)
- `candidate_clips(id PK, source_id, in_ms, out_ms, score REAL, reason TEXT,
  kind TEXT, status TEXT, model TEXT, created_at)` — auto-clip suggestions the
  user accepts/rejects (status: suggested / accepted / dismissed).

---

## Workstreams

### 1. What's-on-screen (vision enrichment) — **S/M, zero setup**
Run Apple Vision over the sprite frames → caption + objects + scene + **on-screen
text (OCR)**. Optional LLM caption via LM Studio for richer descriptions.
- **Stores:** `source_enrichment`.
- **UX:** inspector "What's here" section; feeds search; powers OCR search
  ("find the clip where the scoreboard says 3-1").
- **Depends on:** Workstream 0. No model install (Vision is built in).

### 2. Transcription — **M, cross-cutting**
Apple **Speech** (on-device) or Whisper (CoreML/LM Studio) → transcript +
timed segments per source.
- **Stores:** `source_enrichment.transcript(_segments)`.
- **UX:** searchable transcript; transcript embeddings for semantic search;
  segments feed auto-clip (sentence/topic boundaries) and Stint review.
- **Depends on:** Workstream 0. Enables 3, 5.

### 3. Semantic search — **M**
Embed clip **text** (name+notes+tags+purpose) → then **visual** frames → then
**transcript**. Cosine rank; **hybrid** with the existing FTS (`SearchEngine`)
via reciprocal-rank fusion so it's strictly better than today.
- **Stores:** `clip_embeddings`. Brute-force cosine in Swift is fine to ~10k
  clips; adopt sqlite-vec only if it outgrows that.
- **UX:** search field gains Keyword / Semantic / Hybrid; "Find similar to this
  clip" in the inspector.
- **Depends on:** 0 (+1/2 for visual/transcript signals; text-only ships first).

### 4. Auto-tag / learn-from-labels — **M**
- *Zero-shot:* model picks from the user's **active Purposes + existing tag
  vocabulary**, given captions/transcript.
- *Learn-from-your-labels:* lightweight classifier (kNN / logistic regression)
  over `clip_embeddings` trained on the purposes & tags already assigned —
  improves as the user marks (the find→mark→tag loop becomes self-reinforcing).
- **UX:** pre-fill the capture card; accept/reject "Suggested" chips in the
  inspector; bulk "Auto-tag library" job. Suggestions only.
- **Depends on:** 0, 1/3 (embeddings).

### 5. Auto-clip / moment detection — **L, FLAGSHIP** *(new)*
Automate the **find→mark** step: propose in/out ranges for the good moments in a
source instead of scrubbing by hand. The headline AI feature.
- **Delivery (decided): two tracks.**
  - **Track A — `clipsmith` agent-assisted (now):** the `clipsmith` Claude skill
    already composes ffmpeg + scene/motion/audio analysis + agent judgment and can
    cut a reel from footage today. Usable immediately, no app changes; great for
    validating what "good moment" detection should feel like.
  - **Track B — native in-app pipeline (later):** bring it into Clipx so it's a
    one-click in-app action with accept/reject, not an external agent run.
- **Signals (native):** scene cuts (ffmpeg `select='gt(scene,…)'`), motion/energy,
  audio peaks/laughter/silence removal, transcript topic/sentence boundaries (WS2),
  and an LLM/vision pass to *judge* which candidates are actually good.
- **Stores:** `candidate_clips` (user accepts → real `clips` via `MarkerStore`).
- **UX (native):** "Suggest clips" on a source in the Cut Room → candidate pins on
  the filmstrip + a review list; accept promotes to a clip, dismiss hides it.
  Purpose-aware ("find Reel-worthy moments").
- **Depends on:** 0; better with 2 (transcript) and 1 (vision judging).

---

## Dependency graph & recommended sequencing

```
0 Foundation ─┬─> 1 What's-on-screen ─┐
              ├─> 2 Transcription ─────┼─> 3 Semantic search
              │                        ├─> 4 Auto-tag / learn-from-labels
              └────────────────────────┴─> 5 Auto-clip (also uses 1,2)
```

1. **0 + 1** — foundation + Vision "what's on screen" (zero setup, fast payoff,
   builds the queue + tables everything else uses).
2. **3 (text-only)** — semantic search on text signals; cheap, immediately useful.
3. **2 transcription** — unlocks transcript search + better auto-clip.
4. **4 auto-tag** + **3 visual/transcript embeddings** — richer search + suggestions.
5. **5 auto-clip** — the big one; lands last but is the headline feature.

## Cross-cutting principles

- **Privacy:** on-device/local default; cloud strictly opt-in per Settings.
- **Perf/cost:** background, batched, idle/on-demand; cache by source hash; never
  block the main thread or startup (follow the `ThumbnailEngine` pattern).
- **Suggestions only:** AI never writes tags/clips/notes silently.
- **No silent caps:** if a job samples/limits, surface it.

## Open decisions (implementation-time, defer until each workstream starts)

1. **Embedding source:** Apple NaturalLanguage (zero-setup, weaker) vs LM Studio
   embeddings (better, needs it running) vs CoreML model bundled.
2. **Transcription engine:** Apple Speech (free, on-device, English-strong) vs
   Whisper (better multilingual, heavier).
3. **Vector store:** brute-force Swift (simple, fine ≤10k) vs sqlite-vec now.
4. **Scope of "what's on screen":** OCR + objects/scene only, or full LLM captions?
5. **Per-source vs per-clip enrichment granularity** (current model: per-source
   for vision/transcript, per-clip for embeddings — confirm).

Resolved in re-scope: feature set (all 5), auto-clip is flagship, auto-clip
delivery is clipsmith-first then native, backend is local-first/cloud-opt-in.
</content>
