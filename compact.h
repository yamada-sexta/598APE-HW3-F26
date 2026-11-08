struct compact_boundary {
  size_t k;
  int i, j;
  uint64_t count;
};

struct compact_receipt {
  size_t k;
  uint64_t count;
};

static int compact_active(int i, int j) {
  return i >= 0 && i < N && j >= 0 && j < N && j >= row_lo[i] && j <= row_hi[i];
}

static int compact_observed(int i, int j) {
  const int di[4] = {-1, 1, 0, 0}, dj[4] = {0, 0, -1, 1};
  for (int d = 0; d < 4; ++d) {
    int a = i + di[d], b = j + dj[d];
    if (a >= 0 && a < N && b >= 0 && b < N && !compact_active(a, b))
      return 1;
  }
  return 0;
}

static unsigned compact_step(uint8_t *restrict h, uint8_t *restrict out,
    const uint8_t *restrict in, size_t pitch, size_t first, size_t past, int parity) {
  uint8_t activity = 0;
  size_t west = parity ? 0 : 1, east = parity ? 1 : 0;
#pragma omp simd reduction(| : activity)
  for (size_t k = first; k < past; ++k) {
    uint8_t value = h[k] + in[k - pitch] + in[k + pitch] + in[k - west] + in[k + east];
    uint8_t q = value >> 2;
    h[k] = value & 3;
    out[k] = q;
    activity |= q;
  }
  return activity;
}

static int compact_receipt_order(const void *a, const void *b) {
  size_t x = ((const struct compact_receipt *)a)->k;
  size_t y = ((const struct compact_receipt *)b)->k;
  return (x > y) - (x < y);
}

static int stabilize_compact(void) {

  if (chaos)
    return 0;
  size_t count = 0;
  for (int i = 0; i < N; ++i)
    for (int j = row_lo[i]; j <= row_hi[i]; ++j) {
      int h = grid[index_at(i, j)];
      if (h < 0 || h > 7)
        return 0;
      count += compact_observed(i, j);
    }

  size_t pitch = ((size_t)N + 1) / 2 + 2;
  if (pitch > SIZE_MAX / ((size_t)N + 2))
    die("compact grid size overflow");
  size_t cells = pitch * ((size_t)N + 2), rows = (size_t)N * 2;
  uint8_t *h[2], *q[2];
  for (int c = 0; c < 2; ++c) {
    h[c] = allocate(cells, 1);
    q[c] = allocate(cells, 1);
  }
  size_t *first = allocate(rows, sizeof(*first)), *past = allocate(rows, sizeof(*past));
  size_t *boundary_first = allocate(rows, sizeof(*boundary_first));
  size_t *boundary_past = allocate(rows, sizeof(*boundary_past));
  struct compact_boundary *boundary = allocate(count ? count : 1, sizeof(*boundary));
  size_t used = 0;
  for (int c = 0; c < 2; ++c)
    for (int i = 0; i < N; ++i) {
      size_t row = (size_t)c * N + i, base = (size_t)(i + 1) * pitch;
      int parity = c ^ (i & 1);
      int lo = row_lo[i] + ((row_lo[i] ^ parity) & 1);
      int hi = row_hi[i] - ((row_hi[i] ^ parity) & 1);
      first[row] = base + 1;
      past[row] = first[row];
      if (lo <= hi) {
        first[row] = base + (size_t)lo / 2 + 1;
        past[row] = base + (size_t)hi / 2 + 2;
      }
      boundary_first[row] = used;
      for (int j = lo; j <= hi; j += 2) {
        size_t k = base + (size_t)j / 2 + 1;
        h[c][k] = (uint8_t)grid[index_at(i, j)];
        if (compact_observed(i, j))
          boundary[used++] = (struct compact_boundary){.k = k, .i = i, .j = j};
      }
      boundary_past[row] = used;
    }
  if (used != count)
    die("compact boundary count mismatch");

  unsigned changed = 0;
  uint64_t round = 0;
#pragma omp parallel shared(changed, round)
  {
    for (;;) {
#pragma omp single
      changed = 0;
      for (int c = 0; c < 2; ++c) {
#pragma omp for schedule(static) reduction(| : changed)
        for (int i = 0; i < N; ++i) {
          size_t row = (size_t)c * N + i;
          changed |= compact_step(h[c], q[c], q[1-c], pitch, first[row], past[row], c ^ (i & 1));

          for (size_t b = boundary_first[row]; b < boundary_past[row]; ++b) {
            unsigned amount = q[c][boundary[b].k];
            if (boundary[b].count > UINT64_MAX - amount)
              die("compact counter overflow");
            boundary[b].count += amount;
          }
        }
      }
      if (!changed)
        break;
#pragma omp single
      ++round;
    }
  }

  if (count > SIZE_MAX / 4)
    die("compact receipt size overflow");
  struct compact_receipt *receipts = allocate(count ? 4 * count : 1, sizeof(*receipts));
  size_t length = 0;
  const int di[4] = {-1, 1, 0, 0}, dj[4] = {0, 0, -1, 1};
  for (size_t b = 0; b < count; ++b)
    for (int d = 0; d < 4; ++d) {
      int i = boundary[b].i + di[d], j = boundary[b].j + dj[d];
      if (i >= 0 && i < N && j >= 0 && j < N && !compact_active(i, j))
        receipts[length++] = (struct compact_receipt){index_at(i, j), boundary[b].count};
    }
  qsort(receipts, length, sizeof(*receipts), compact_receipt_order);
  size_t groups = 0;
  for (size_t b = 0; b < length;) {
    size_t k = receipts[b].k;
    uint64_t total = 0, limit = (uint64_t)((int64_t)INT_MAX - grid[k]);
    do {
      if (receipts[b].count > limit - total)
        die("physical sink height overflow");
      total += receipts[b++].count;
    } while (b < length && receipts[b].k == k);
    receipts[groups++] = (struct compact_receipt){k, total};
  }
  for (int i = 0; i < N; ++i)
    for (int j = row_lo[i]; j <= row_hi[i]; ++j)
      grid[index_at(i, j)] = h[(i ^ j) & 1][(size_t)(i + 1) * pitch + (size_t)j / 2 + 1];
  for (size_t b = 0; b < groups; ++b) {
    size_t k = receipts[b].k;
    grid[k] = (int)((int64_t)grid[k] + (int64_t)receipts[b].count);
  }
  free(receipts);
  free(boundary);
  free(boundary_past);
  free(boundary_first);
  free(past);
  free(first);
  for (int c = 0; c < 2; ++c) {
    free(q[c]);
    free(h[c]);
  }
  last_rounds = round + 1;
  return 1;
}
