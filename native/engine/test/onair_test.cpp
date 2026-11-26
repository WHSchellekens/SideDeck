// Host unit test for onair.hpp: band split, and the whole tracker on two
// synthetic beatmatched tracks mixed the way a hardware mixer would, returned
// with a delay as if from the Sidekick's USB inputs 7-8.
//
//   g++ -std=c++17 -O2 -Wall -Wextra -I native/engine native/engine/test/onair_test.cpp -o onair_test
//   ./onair_test

#include "onair.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

int failures = 0;
constexpr float kSr = 48000.0f;
constexpr double kPi = 3.14159265358979323846;

void expect(const char* what, bool ok, double got) {
  if (!ok) {
    std::printf("FAIL %s (got %.4f)\n", what, got);
    ++failures;
  } else {
    std::printf("ok   %s (%.4f)\n", what, got);
  }
}

struct Noise {
  unsigned s = 1u;
  float next() {
    s = s * 1664525u + 1013904223u;
    return (float)((s >> 8) & 0xFFFF) / 32768.0f - 1.0f;
  }
};

// Track A: deep kick on every beat, offbeat hats, a rolling bassline.
std::vector<float> trackA(int frames) {
  std::vector<float> x((size_t)frames);
  Noise n{7u};
  const double beat = 60.0 / 124.0;
  for (int i = 0; i < frames; ++i) {
    const double t = i / (double)kSr;
    const double bp = t / beat;
    const double f = bp - std::floor(bp);
    const double tb = f * beat;
    const double kick = std::exp(-tb / 0.06) * std::sin(2 * kPi * 55.0 * tb);
    const double off = std::fabs(f - 0.5) * beat;
    const double hat = (off < 0.03 ? std::exp(-off / 0.008) : 0.0) * n.next();
    const double bass = 0.4 * std::sin(2 * kPi * 110.0 * t) * (0.3 + 0.7 * f);
    x[(size_t)i] = (float)(0.6 * kick + 0.25 * hat + 0.25 * bass);
  }
  return x;
}

// Track B, beatmatched to A: kicks on the same beats (the hard case), claps on
// 2 and 4, a mid-range arpeggio, sixteenth hats.
std::vector<float> trackB(int frames) {
  std::vector<float> x((size_t)frames);
  Noise n{99u};
  const double beat = 60.0 / 124.0;
  const double notes[4] = {440.0, 660.0, 550.0, 880.0};
  for (int i = 0; i < frames; ++i) {
    const double t = i / (double)kSr;
    const double bp = t / beat;
    const double f = bp - std::floor(bp);
    const double tb = f * beat;
    const long beatIdx = (long)std::floor(bp);
    const double kick = std::exp(-tb / 0.05) * std::sin(2 * kPi * 48.0 * tb);
    const double clap = (beatIdx % 2 == 1 ? std::exp(-tb / 0.03) : 0.0) * n.next();
    const double s16 = std::fmod(bp * 4.0, 1.0) * beat / 4.0;
    const double hat = std::exp(-s16 / 0.004) * n.next();
    const int step = (int)std::floor(bp * 4.0) % 4;
    const double arp = std::exp(-s16 / 0.05) * std::sin(2 * kPi * notes[step] * t);
    x[(size_t)i] = (float)(0.5 * kick + 0.3 * clap + 0.12 * hat + 0.3 * arp);
  }
  return x;
}

struct Scenario {
  const char* name;
  double gainA, gainB;
  double delayMs;
};

void runScenario(const Scenario& sc, const std::vector<float>& a, const std::vector<float>& b,
                 double& shareA, double& shareB, double& lag) {
  onair::Tracker tr;
  tr.enable(kSr);
  const int frames = (int)a.size();
  const int delay = (int)std::lround(sc.delayMs * kSr / 1000.0);
  const int render = 256;
  const int capture = 480;
  int rendered = 0;
  std::vector<float> inter((size_t)capture * 8);
  for (int cap = 0; cap + capture <= frames; cap += capture) {
    // Decks are rendered ahead of what comes back from the mixer.
    while (rendered < std::min(frames, cap + capture + 4800)) {
      const int n = std::min(render, frames - rendered);
      const float* pa = a.data() + rendered;
      const float* pb = b.data() + rendered;
      tr.feedDecks(pa, pa, pb, pb, n, (int64_t)(rendered * 1.0e9 / kSr));
      rendered += n;
    }
    for (int i = 0; i < capture; ++i) {
      const int src = cap + i - delay;
      const float m = src >= 0 ? (float)(sc.gainA * a[(size_t)src] + sc.gainB * b[(size_t)src]) : 0.0f;
      for (int c = 0; c < 8; ++c) {
        inter[(size_t)i * 8 + c] = c >= 6 ? m : 0.0f;
      }
    }
    const int64_t end = (int64_t)((cap + capture - 1) * 1.0e9 / kSr);
    tr.feedCapture(inter.data(), capture, 8, end);
  }
  shareA = tr.share(0);
  shareB = tr.share(1);
  lag = tr.lagMs();
  std::printf("-- %s: A %.3f  B %.3f  lag %.1f ms  fit %.2f\n", sc.name, shareA, shareB, lag,
              tr.fit());
}

void testBandSplit() {
  onair::BandMeter m;
  m.setup(kSr);
  std::vector<float> tone((size_t)4800);
  for (double f : {80.0, 3000.0}) {
    for (size_t i = 0; i < tone.size(); ++i) {
      tone[i] = (float)std::sin(2 * kPi * f * (double)i / kSr);
    }
    onair::Hop last;
    m.feed(tone.data(), (int)tone.size(), 0, [&](const onair::Hop& h) { last = h; });
    const int expectBand = f < 200 ? 0 : 2;
    int best = 0;
    for (int k = 1; k < onair::kBands; ++k) {
      if (last.e[k] > last.e[best]) best = k;
    }
    expect(f < 200 ? "80 Hz lands in the low band" : "3 kHz lands in the 1-5 kHz band",
           best == expectBand, best);
  }
}

void testSolveSharesExact() {
  // master = 0.5 * A exactly; B unrelated.
  std::vector<onair::Hop> m;
  std::vector<onair::DeckHop> d;
  Noise n{3u};
  for (int i = 0; i < 300; ++i) {
    onair::DeckHop h;
    h.timeNs = (int64_t)i * 10000000;
    for (int k = 0; k < onair::kBands; ++k) {
      h.a[k] = 0.5f + 0.5f * n.next();
      h.b[k] = 0.5f + 0.5f * n.next();
    }
    d.push_back(h);
    onair::Hop mh;
    mh.timeNs = h.timeNs;
    for (int k = 0; k < onair::kBands; ++k) mh.e[k] = 0.5f * h.a[k];
    m.push_back(mh);
  }
  const double w[onair::kBands] = {1, 1, 1, 1};
  const onair::Result r = onair::solveShares(m, d, w, 0.0);
  expect("exact: A explains the master", r.shareA > 0.95, r.shareA);
  expect("exact: B explains nothing", r.shareB < 0.02, r.shareB);
  expect("exact: fit", r.fit > 0.99, r.fit);
}

} // namespace

int main() {
  testBandSplit();
  testSolveSharesExact();

  const int frames = (int)(9.0 * kSr);
  const auto a = trackA(frames);
  const auto b = trackB(frames);
  double sa = 0, sb = 0, lag = 0;

  runScenario({"A up, B down, 120 ms", 0.8, 0.0, 120.0}, a, b, sa, sb, lag);
  expect("A on air", sa > 0.6, sa);
  expect("B off air", sb < 0.1, sb);
  expect("lag found near 120 ms", std::fabs(lag - 120.0) < 8.0, lag);

  runScenario({"B up, A down, 40 ms", 0.0, 0.8, 40.0}, a, b, sa, sb, lag);
  expect("B on air", sb > 0.6, sb);
  expect("A off air", sa < 0.1, sa);
  expect("lag found near 40 ms", std::fabs(lag - 40.0) < 8.0, lag);

  runScenario({"both up (blend), 75 ms", 0.6, 0.6, 75.0}, a, b, sa, sb, lag);
  expect("A on air in blend", sa > 0.25, sa);
  expect("B on air in blend", sb > 0.25, sb);

  runScenario({"B quiet under A, 60 ms", 0.8, 0.15, 60.0}, a, b, sa, sb, lag);
  expect("A dominant", sa > sb, sa - sb);

  runScenario({"both down (master silent)", 0.0, 0.0, 50.0}, a, b, sa, sb, lag);
  expect("A off air when silent", sa == 0.0, sa);
  expect("B off air when silent", sb == 0.0, sb);

  if (failures != 0) {
    std::printf("%d failure(s)\n", failures);
    return EXIT_FAILURE;
  }
  std::printf("onair: all tests passed\n");
  return EXIT_SUCCESS;
}
