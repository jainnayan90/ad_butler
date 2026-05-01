---
title: "HNSW pgvector kNN test order: use partial-match (orthogonal-direction) vectors, not magnitude-shifted ones"
module: "AdButler.EmbeddingsTest"
date: "2026-04-30"
problem_type: flaky_test
component: pgvector_hnsw
symptoms:
  - "Test asserting `Embeddings.nearest/3` returns rows in a specific order is flaky under parallel test load"
  - "Closest row matches but second-closest flips — HNSW returns row C before row B even though B has smaller cosine distance"
  - "Test passes when run alone, fails when run with other test files"
---

## Root cause

HNSW (`m=16, ef_construction=64` defaults) is an **approximate** nearest-neighbor index. For vectors that differ only in magnitude (uniformly scaled all-positive components), cosine distance is dominated by the relative direction; tiny per-component variations get lost in 1536-D and HNSW's recall on near-ties fluctuates non-deterministically.

```elixir
# BROKEN — all three vectors point in nearly the same direction.
defp shifted_vector(dim, offset) do
  for i <- 1..dim, do: 1.0 - (rem(i, 7) + offset) * 0.0001
end

shifted_vector(1536, 1)    # cos_sim to ones ≈ 1.0
shifted_vector(1536, 50)   # cos_sim to ones ≈ 1.0
shifted_vector(1536, 500)  # cos_sim to ones ≈ 0.99 — still essentially parallel
```

Because all three share the same direction, cosine distance differences are below HNSW's recall floor and the index returns whichever row it traverses first.

## Fix

Use vectors whose **direction** to the anchor differs by a clearly distinguishable amount — not just their magnitude. The `partial_ones` helper produces vectors at strictly increasing cosine distance to `ones_vector()`:

```elixir
defp partial_ones(dim, ones_count) do
  for i <- 1..dim, do: if(i <= ones_count, do: 1.0, else: 0.0)
end

# Cosine sim to ones_vector(1536):
# partial_ones(1536, 1535) ≈ 0.9997  (closest)
# partial_ones(1536, 1336) ≈ 0.9322
# partial_ones(1536, 1036) ≈ 0.8208  (farthest)
```

The cosine-distance gaps (~0.07 between mid and far) are wide enough that even an approximate HNSW search ranks them deterministically.

## Why this matters generally

For any pgvector kNN test where ordering across more than two rows matters:

1. Don't rely on small-magnitude perturbations of a single template vector.
2. Make the rows differ by clearly different cosine angles to the query.
3. The `partial_ones` shape (matching prefix of ones, zero suffix) is reliable because dot product = ones_count and norms are sqrt(ones_count) — closed-form cosine sim of `1535/sqrt(1536·1535) ≈ 0.9997`.
4. For tests that need a runtime jitter (random rows + at least one expected row), still pin the expected row with a partial-ones-style vector and use `random_vector/1` for filler.

## Reference

- v0.3 / week 8 fix S2 in `.claude/plans/week8-fixes/plan.md` (P4-T5).
- Test: `test/ad_butler/embeddings_test.exs:respects the limit and returns the closest+second-closest rows`.
- pgvector HNSW docs: index recall is approximate by design — exact order is not guaranteed for near-tie distances.
