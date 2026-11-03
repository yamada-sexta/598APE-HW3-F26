#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#ifdef _OPENMP
#include <omp.h>
#endif

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#define MIN(a, b) (((a) < (b)) ? (a) : (b))
#define MAX(a, b) (((a) > (b)) ? (a) : (b))

static void die(const char *s) {
  fprintf(stderr, "%s\n", s);
  exit(1);
}

int N = 801;
static size_t stride;
static int *grid, *emission, *row_lo, *row_hi;
static int serial_backend;

static void *allocate(size_t count, size_t bytes) {
  if (bytes && count > SIZE_MAX / bytes)
    die("allocation size overflow");
  void *p = calloc(count, bytes);
  if (!p)
    die("allocation failed");
  return p;
}

static size_t index_at(int i, int j) {
  return (size_t)(i + 1) * stride + (size_t)(j + 1);
}

static void setup(void) {
  stride = (size_t)N + 2;
  if (stride > SIZE_MAX / stride)
    die("grid size overflow");
  grid = allocate(stride * stride, sizeof(*grid));
  emission = allocate(stride * stride, sizeof(*emission));
  row_lo = allocate(N, sizeof(*row_lo));
  row_hi = allocate(N, sizeof(*row_hi));
  int64_t r = N / 2;
  for (int i = 0; i < N; ++i) {
    row_lo[i] = N;
    row_hi[i] = -1;
    for (int j = 0; j <= MAX(i, N - 1 - i); ++j) {
      int64_t y = i - r, x = j - r;
      if (y * y + x * x <= r * r) {
        row_lo[i] = MIN(row_lo[i], j);
        row_hi[i] = j;
      }
    }
  }
}

static void teardown(void) {
  free(row_hi);
  free(row_lo);
  free(emission);
  free(grid);
}

// you can also use this function to debug print your sandpile
static void render(char *filename) {
  int chan = 3;
  unsigned char *pixels = allocate((size_t)N * N, (size_t)chan);
  int stride = N * chan;
  if (!pixels)
    die("malloc failed for PNG pixel buffer");
#pragma omp parallel for
  for (int i = 0; i < N; ++i) {
    for (int j = 0; j < N; ++j) {
      unsigned char r = 0, g = 0, b = 0;
      switch (grid[index_at(i, j)]) {
      case 0: // obsidian
        r = 15;
        g = 15;
        b = 25;
        break;
      case 1: // electric cyan
        r = 0;
        g = 210;
        b = 255;
        break;
      case 2: // vibrant magenta
        r = 230;
        g = 30;
        b = 130;
        break;
      case 3: // bright gold
        r = 255;
        g = 200;
        b = 0;
        break;
      default: // white
        r = 0;
        g = 0;
        b = 0;
      }

      size_t pid = ((size_t)i * N + j) * chan;
      pixels[pid] = r;
      pixels[pid + 1] = g;
      pixels[pid + 2] = b;
    }
  }
  if (stbi_write_png(filename, N, N, chan, pixels, stride)) {
    printf("Successfully saved sandpile identity to: %s\n", filename);
  } else {
    die("Error: stb_image_write failed to save png file\n");
  }
  free(pixels);
}

static void stabilize_serial(void) {
  int changed;
  do {
    changed = 0;
    for (int i = 0; i < N; ++i) {
      for (int j = row_lo[i]; j <= row_hi[i]; ++j) {
        size_t k = index_at(i, j);
        int q = grid[k] >= 4 ? grid[k] / 4 : 0;
        if (!q)
          continue;
        changed = 1; // topple it
        grid[k] -= 4 * q;
        grid[k - stride] += q;
        grid[k - 1] += q;
        grid[k + stride] += q;
        grid[k + 1] += q;
      }
    }
  } while (changed);
}

static void stabilize(void) {
  if (serial_backend) {
    stabilize_serial();
    return;
  }
  int changed = 0;
#pragma omp parallel shared(changed)
  {
    for (;;) {
#pragma omp single
      changed = 0;
      for (int color = 0; color < 2; ++color) {
#pragma omp for schedule(static) reduction(| : changed)
        for (int i = 0; i < N; ++i) {
          for (int j = color ^ (i & 1); j < N; j += 2) {
            size_t k = index_at(i, j);
            int h = grid[k] + emission[k - stride] + emission[k - 1]
                + emission[k + stride] + emission[k + 1];
            int q = j >= row_lo[i] && j <= row_hi[i] && h >= 4 ? h / 4 : 0;
            grid[k] = h - 4 * q;
            emission[k] = q;
            changed |= q != 0;
          }
        }
      }
      if (!changed)
        break;
#pragma omp barrier
    }
  }
}

void find_identity() {
#pragma omp parallel for
  for (int i = 0; i < N; ++i) {
    for (int j = 0; j < N; ++j) {
      grid[index_at(i, j)] = 6;
    }
  }
  stabilize();
#pragma omp parallel for
  for (int i = 0; i < N; ++i) {
    for (int j = 0; j < N; ++j) {
      grid[index_at(i, j)] = 6 - grid[index_at(i, j)];
    }
  }
  stabilize();
}

static void configure(void) {
  const char *value = getenv("SANDPILE_BACKEND");
  if (value && strcmp(value, "omp") && strcmp(value, "serial"))
    die("SANDPILE_BACKEND must be omp or serial");
  serial_backend = value && !strcmp(value, "serial");
#ifdef _OPENMP
  if (!getenv("OMP_NUM_THREADS"))
    omp_set_num_threads(MIN(4, omp_get_num_procs()));
#endif
}

int main(int argc, char **argv) {
  if (argc < 2 || argc > 2) {
    fprintf(stderr, "Usage: %s N\n", argv[0]);
    return EXIT_FAILURE;
  }
  char *end;
  uintmax_t parsed = strtoumax(argv[1], &end, 10);
  if (errno || argv[1][0] < '0' || argv[1][0] > '9' || *end || !parsed ||
      parsed > INT_MAX / 3)
    die("grid size must be a positive int");
  N = (int)parsed;
  configure();
  setup();

  find_identity();

  render("identity.png");
  teardown();
  return EXIT_SUCCESS;
}
