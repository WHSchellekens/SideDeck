// Host unit test for wave_scan.hpp: bins, min/max and the three EQ bands.
//
//   g++ -std=c++17 -Wall -Wextra -I native/engine native/engine/test/wave_scan_test.cpp -o wave_scan_test
//   ./wave_scan_test

#include "wave_scan.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

int failures = 0;
constexpr double kPi = 3.14159265358979323846;
constexpr float kSr = 44100.0f;

void expect(const char* what, bool ok, double got) {
  std::printf("%s %s (%.3f)\n", ok ? "ok  " : "FAIL", what, got);
  if (!ok) ++failures;
}

// Scans a two-second stereo sine and returns the band shares of a middle bin.
void scanTone(double hz, double& low, double& mid, double& high, float& mn, float& mx) {
  const uint64_t frames = (uint64_t)(2 * kSr);
  std::vector<float> st(frames * 2);
  for (uint64_t i = 0; i < frames; ++i) {
    const float s = (float)(0.8 * std::sin(2 * kPi * hz * (double)i / kSr));
    st[i * 2] = st[i * 2 + 1] = s;
  }
  WaveScan w;
  w.begin(200, frames, kSr);
  // Feed in uneven blocks, like the decoder does.
  uint64_t pos = 0;
  while (pos < frames) {
    const uint64_t n = std::min<uint64_t>(frames - pos, 3000 + pos % 777);
    w.feed(st.data() + pos * 2, n, pos);
    pos += n;
  }
  w.finish();
  const size_t b = 120;
  const double sum = w.low[b] + w.mid[b] + w.high[b];
  low = w.low[b] / sum;
  mid = w.mid[b] / sum;
  high = w.high[b] / sum;
  mn = w.min[b];
  mx = w.max[b];
}

} // namespace

int main() {
  double l, m, h;
  float mn, mx;
  scanTone(60.0, l, m, h, mn, mx);
  expect("60 Hz kick range is mostly low band", l > 0.8, l);
  scanTone(900.0, l, m, h, mn, mx);
  expect("900 Hz is mostly mid band", m > 0.7, m);
  // A 10 ms bin holds several 900 Hz cycles, so it reaches both peaks.
  expect("min/max follow the sine", mn < -0.7f && mx > 0.7f, mx);
  scanTone(7000.0, l, m, h, mn, mx);
  expect("7 kHz is mostly high band", h > 0.8, h);

  // Every bin gets data, including the last one.
  WaveScan w;
  const uint64_t frames = 10000;
  std::vector<float> st(frames * 2, 0.25f);
  w.begin(64, frames, kSr);
  w.feed(st.data(), frames, 0);
  w.finish();
  bool all = true;
  for (int b = 0; b < 64; ++b) {
    all = all && w.max[(size_t)b] > 0.2f;
  }
  expect("all bins filled", all, w.max.back());

  if (failures != 0) {
    std::printf("%d failure(s)\n", failures);
    return EXIT_FAILURE;
  }
  std::printf("wave_scan: all tests passed\n");
  return EXIT_SUCCESS;
}
