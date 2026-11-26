#pragma once

// On-air detection for external-mixer mode.
//
// The EP-136 K.O. Sidekick returns its master output on USB inputs 7-8. We
// know exactly what each deck sends it, so comparing the two tells which decks
// are audible in the main mix (fader up) and which are only in the
// headphones, whatever the Sidekick's MIDI mode.
//
// Everything works on 10 ms hops of band energy in four bands, which is
// robust to timing jitter, EQ and compression on the mixer:
//  1. Find the delay between rendering a deck and hearing it come back, by
//     correlating the master with the sum of both decks over 0-500 ms. That
//     delay is also the phone-to-Sidekick latency, measured while you play.
//  2. At that delay, solve  master ~= a * deckA + b * deckB  with a, b >= 0
//     (energies of unrelated tracks add) over the last few seconds.
//  3. Each deck's share of the master energy says whether it is on air.
//
// Pure C++ with no engine state; native/engine/test/onair_test.cpp covers it.

#include "biquad.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <vector>

namespace onair {

constexpr int kBands = 4;
constexpr double kHopSec = 0.01;
constexpr int kMaxInputs = 8;

// Four bands: < 200 Hz, 200 Hz-1 kHz, 1-5 kHz, > 5 kHz.
struct BandSplit {
  LR4 lp200, hp200, lp1k, hp1k, lp5k, hp5k;

  void setup(float sr) {
    lp200.lowPass(sr, 200.0f);
    hp200.highPass(sr, 200.0f);
    lp1k.lowPass(sr, 1000.0f);
    hp1k.highPass(sr, 1000.0f);
    lp5k.lowPass(sr, 5000.0f);
    hp5k.highPass(sr, 5000.0f);
    lp200.reset();
    hp200.reset();
    lp1k.reset();
    hp1k.reset();
    lp5k.reset();
    hp5k.reset();
  }

  void process(float x, float out[kBands]) {
    out[0] = lp200.process(x);
    const float above200 = hp200.process(x);
    out[1] = lp1k.process(above200);
    const float above1k = hp1k.process(above200);
    out[2] = lp5k.process(above1k);
    out[3] = hp5k.process(above1k);
  }
};

struct Hop {
  int64_t timeNs = 0; // first sample of the hop, CLOCK_MONOTONIC
  float e[kBands] = {0, 0, 0, 0};
};

struct DeckHop {
  int64_t timeNs = 0;
  float a[kBands] = {0, 0, 0, 0};
  float b[kBands] = {0, 0, 0, 0};
};

// Mean-square energy per band per hop of a mono signal.
class BandMeter {
 public:
  void setup(float sr) {
    sr_ = std::max(1.0f, sr);
    hopFrames_ = std::max(1, (int)std::lround(sr_ * kHopSec));
    split_.setup(sr_);
    count_ = 0;
    std::fill(acc_, acc_ + kBands, 0.0);
  }

  // timeNs is the time of x[0]. Calls emit(const Hop&) per completed hop.
  template <class Emit>
  void feed(const float* x, int n, int64_t timeNs, Emit&& emit) {
    float bands[kBands];
    for (int i = 0; i < n; ++i) {
      if (count_ == 0) {
        hopStart_ = timeNs + (int64_t)((double)i * 1.0e9 / sr_);
      }
      split_.process(x[i], bands);
      for (int k = 0; k < kBands; ++k) {
        acc_[k] += (double)bands[k] * bands[k];
      }
      if (++count_ == hopFrames_) {
        Hop h;
        h.timeNs = hopStart_;
        for (int k = 0; k < kBands; ++k) {
          h.e[k] = (float)(acc_[k] / count_);
          acc_[k] = 0.0;
        }
        count_ = 0;
        emit(h);
      }
    }
  }

 private:
  BandSplit split_;
  float sr_ = 48000.0f;
  int hopFrames_ = 480;
  int count_ = 0;
  int64_t hopStart_ = 0;
  double acc_[kBands] = {0, 0, 0, 0};
};

// Single producer, single consumer. The reader copies the newest hops; the
// writer is always hundreds of slots away from them.
template <class T, int N>
class Ring {
 public:
  void push(const T& v) {
    const int64_t w = written_.load(std::memory_order_relaxed);
    buf_[w % N] = v;
    written_.store(w + 1, std::memory_order_release);
  }

  // Newest n entries, oldest first.
  int latest(std::vector<T>& out, int n) const {
    const int64_t w = written_.load(std::memory_order_acquire);
    const int64_t from = std::max<int64_t>(0, w - std::min(n, N - 64));
    out.resize((size_t)(w - from));
    for (int64_t i = from; i < w; ++i) {
      out[(size_t)(i - from)] = buf_[i % N];
    }
    return (int)out.size();
  }

  void clear() { written_.store(0, std::memory_order_release); }

 private:
  T buf_[N];
  std::atomic<int64_t> written_{0};
};

struct Result {
  bool valid = false;  // shares are meaningful (master silent counts: both 0)
  double shareA = 0.0; // share of the master explained by deck A (0..1)
  double shareB = 0.0;
  double lagMs = -1.0; // render-to-capture delay; -1 when not found
  double corr = 0.0;   // correlation at that delay
  double fit = 0.0;    // 1 - residual / total
};

// Master quieter than this (mean square, about -60 dBFS) counts as silence.
constexpr double kSilence = 1.0e-6;
constexpr double kLagStepMs = 5.0;
constexpr double kMinCorr = 0.3;

namespace detail {

// Index of the deck hop nearest to time t; -1 outside the deck history.
inline int nearest(const std::vector<DeckHop>& d, int64_t t) {
  if (d.size() < 2 || t < d.front().timeNs || t > d.back().timeNs) {
    return -1;
  }
  auto it = std::lower_bound(d.begin(), d.end(), t,
                             [](const DeckHop& h, int64_t v) { return h.timeNs < v; });
  int i = (int)(it - d.begin());
  if (i > 0 && (i == (int)d.size() || t - d[(size_t)i - 1].timeNs < d[(size_t)i].timeNs - t)) {
    --i;
  }
  return i;
}

// Pearson correlation of master energy with one deck's energy (deck 0 = A,
// 1 = B) at one delay.
inline double corrAt(const std::vector<Hop>& m, const std::vector<DeckHop>& d,
                     const double w[kBands], double lagMs, int deck) {
  const int64_t lag = (int64_t)(lagMs * 1.0e6);
  double sx = 0, sy = 0, sxx = 0, syy = 0, sxy = 0;
  int n = 0;
  for (const Hop& h : m) {
    // Interpolate between the two deck hops around the target time, so the
    // correlation varies smoothly with the delay (sub-hop precision).
    const int64_t t = h.timeNs - lag;
    if (d.size() < 2 || t < d.front().timeNs || t >= d.back().timeNs) {
      continue;
    }
    auto it = std::upper_bound(d.begin(), d.end(), t,
                               [](int64_t v, const DeckHop& e) { return v < e.timeNs; });
    const size_t j1 = (size_t)(it - d.begin());
    const size_t j0 = j1 - 1;
    const double span = (double)(d[j1].timeNs - d[j0].timeNs);
    const double frac = span > 0.0 ? (double)(t - d[j0].timeNs) / span : 0.0;
    const float* s0 = deck == 0 ? d[j0].a : d[j0].b;
    const float* s1 = deck == 0 ? d[j1].a : d[j1].b;
    double x = 0, y = 0;
    for (int k = 0; k < kBands; ++k) {
      x += w[k] * h.e[k];
      y += w[k] * ((1.0 - frac) * s0[k] + frac * s1[k]);
    }
    sx += x;
    sy += y;
    sxx += x * x;
    syy += y * y;
    sxy += x * y;
    ++n;
  }
  if (n < 50) {
    return 0.0;
  }
  const double vx = sxx - sx * sx / n;
  const double vy = syy - sy * sy / n;
  if (vx <= 1.0e-18 || vy <= 1.0e-18) {
    return 0.0;
  }
  return (sxy - sx * sy / n) / std::sqrt(vx * vy);
}

} // namespace detail

// Best render-to-capture delay in [0, maxLagMs], refined between steps.
// Each deck is matched on its own: a deck that is not in the mix would only
// blur the sum (and, with beatmatched tracks, pull the peak to a half beat).
// Returns -1 when nothing correlates well enough.
inline double findLag(const std::vector<Hop>& m, const std::vector<DeckHop>& d,
                      const double w[kBands], double maxLagMs, double* bestCorr = nullptr) {
  const int steps = (int)(maxLagMs / kLagStepMs) + 1;
  std::vector<double> ca((size_t)steps), cb((size_t)steps);
  for (int s = 0; s < steps; ++s) {
    ca[(size_t)s] = detail::corrAt(m, d, w, s * kLagStepMs, 0);
    cb[(size_t)s] = detail::corrAt(m, d, w, s * kLagStepMs, 1);
  }
  const auto peakA = std::max_element(ca.begin(), ca.end());
  const auto peakB = std::max_element(cb.begin(), cb.end());
  const std::vector<double>& c = *peakA >= *peakB ? ca : cb;
  int best = -1;
  for (int s = 0; s < steps; ++s) {
    if (best < 0 || c[(size_t)s] > c[(size_t)best]) {
      best = s;
    }
  }
  if (bestCorr != nullptr) {
    *bestCorr = best >= 0 ? c[(size_t)best] : 0.0;
  }
  if (best < 0 || c[(size_t)best] < kMinCorr) {
    return -1.0;
  }
  double lag = best * kLagStepMs;
  if (best > 0 && best + 1 < steps) {
    const double l = c[(size_t)best - 1], m0 = c[(size_t)best], r = c[(size_t)best + 1];
    const double den = l - 2.0 * m0 + r;
    if (den < 0.0) {
      lag += 0.5 * (l - r) / den * kLagStepMs;
    }
  }
  return lag;
}

// master ~= a * A + b * B with a, b >= 0, at a known delay. Band weights make
// every band count, not just the bass.
inline Result solveShares(const std::vector<Hop>& m, const std::vector<DeckHop>& d,
                          const double w[kBands], double lagMs) {
  Result r;
  r.lagMs = lagMs;
  const int64_t lag = (int64_t)(lagMs * 1.0e6);
  double saa = 0, sbb = 0, sab = 0, sam = 0, sbm = 0, smm = 0, ta = 0, tb = 0, tm = 0;
  int n = 0;
  for (const Hop& h : m) {
    const int j = detail::nearest(d, h.timeNs - lag);
    if (j < 0) {
      continue;
    }
    for (int k = 0; k < kBands; ++k) {
      const double x = w[k] * h.e[k];
      const double a = w[k] * d[(size_t)j].a[k];
      const double b = w[k] * d[(size_t)j].b[k];
      saa += a * a;
      sbb += b * b;
      sab += a * b;
      sam += a * x;
      sbm += b * x;
      smm += x * x;
      ta += a;
      tb += b;
      tm += x;
    }
    ++n;
  }
  if (n < 50 || tm <= 0.0) {
    return r;
  }
  r.valid = true;
  auto residual = [&](double a, double b) {
    return smm - 2.0 * a * sam - 2.0 * b * sbm + a * a * saa + 2.0 * a * b * sab + b * b * sbb;
  };
  double a = 0.0, b = 0.0;
  const double det = saa * sbb - sab * sab;
  if (det > 1.0e-12 * std::max(1.0, saa * sbb)) {
    a = (sam * sbb - sbm * sab) / det;
    b = (sbm * saa - sam * sab) / det;
  }
  if (!(det > 1.0e-12 * std::max(1.0, saa * sbb)) || a < 0.0 || b < 0.0) {
    // One deck alone, whichever fits better.
    const double aOnly = saa > 0.0 ? std::max(0.0, sam / saa) : 0.0;
    const double bOnly = sbb > 0.0 ? std::max(0.0, sbm / sbb) : 0.0;
    if (residual(aOnly, 0.0) <= residual(0.0, bOnly)) {
      a = aOnly;
      b = 0.0;
    } else {
      a = 0.0;
      b = bOnly;
    }
  }
  r.shareA = std::min(1.0, a * ta / tm);
  r.shareB = std::min(1.0, b * tb / tm);
  r.fit = smm > 0.0 ? 1.0 - residual(a, b) / smm : 0.0;
  return r;
}

// One estimate from the newest hops: weights, delay, shares.
inline Result estimate(const std::vector<Hop>& master, const std::vector<DeckHop>& decks,
                       double maxLagMs) {
  Result r;
  if (master.size() < 100 || decks.size() < 100) {
    return r;
  }
  double mean[kBands] = {0, 0, 0, 0};
  for (const Hop& h : master) {
    for (int k = 0; k < kBands; ++k) {
      mean[k] += h.e[k];
    }
  }
  double total = 0.0;
  double w[kBands];
  for (int k = 0; k < kBands; ++k) {
    mean[k] /= (double)master.size();
    total += mean[k];
    w[k] = 1.0 / (mean[k] + 1.0e-9);
  }
  if (total < kSilence) {
    // Master silent: nothing is on air (faders down or master turned down).
    r.valid = true;
    return r;
  }
  double corr = 0.0;
  const double lag = findLag(master, decks, w, maxLagMs, &corr);
  if (lag < 0.0) {
    // Something plays but doesn't line up with the decks (another source,
    // or music without clear transients): don't guess.
    r.corr = corr;
    return r;
  }
  r = solveShares(master, decks, w, lag);
  r.corr = corr;
  return r;
}

// Glue for the engine: the render thread feeds deck audio, the capture thread
// feeds the Sidekick's inputs and re-estimates twice a second. Results are
// atomics any thread can read.
class Tracker {
 public:
  static constexpr int kDeckHistory = 700;  // 7 s
  static constexpr int kMasterWindow = 400; // 4 s
  static constexpr double kMaxLagMs = 500.0;

  void enable(float sampleRate) {
    sr_.store(std::max(1.0f, sampleRate));
    resetDecks_.store(true);
    resetMaster_.store(true);
    shareA_.store(-1.0f);
    shareB_.store(-1.0f);
    lagMs_.store(-1.0f);
    fit_.store(0.0f);
    inputChannels_.store(0);
    for (auto& l : levels_) {
      l.store(0.0f);
    }
    enabled_.store(true);
  }

  void disable() { enabled_.store(false); }
  bool enabled() const { return enabled_.load(std::memory_order_relaxed); }

  // Render thread: what the decks send this callback (before the master gain
  // and clip, which are the same for both).
  void feedDecks(const float* aL, const float* aR, const float* bL, const float* bR, int n,
                 int64_t timeNs) {
    if (!enabled()) {
      return;
    }
    if (resetDecks_.exchange(false)) {
      const float sr = sr_.load();
      deckA_.setup(sr);
      deckB_.setup(sr);
      deckRing_.clear();
      pendingA_ = false;
    }
    float monoA[256];
    float monoB[256];
    for (int off = 0; off < n; off += 256) {
      const int c = std::min(256, n - off);
      for (int i = 0; i < c; ++i) {
        monoA[i] = 0.5f * (aL[off + i] + aR[off + i]);
        monoB[i] = 0.5f * (bL[off + i] + bR[off + i]);
      }
      const int64_t t = timeNs + (int64_t)((double)off * 1.0e9 / sr_.load());
      // Both meters run in lockstep, so their hops pair up one to one.
      deckA_.feed(monoA, c, t, [this](const Hop& h) {
        pendingHop_ = h;
        pendingA_ = true;
      });
      deckB_.feed(monoB, c, t, [this](const Hop& h) {
        if (!pendingA_) {
          return;
        }
        DeckHop d;
        d.timeNs = pendingHop_.timeNs;
        std::copy(pendingHop_.e, pendingHop_.e + kBands, d.a);
        std::copy(h.e, h.e + kBands, d.b);
        deckRing_.push(d);
        pendingA_ = false;
      });
    }
  }

  // Capture thread: one block of the Sidekick's USB inputs, interleaved.
  // endTimeNs is when the block's last frame was captured.
  void feedCapture(const float* x, int frames, int channels, int64_t endTimeNs) {
    if (!enabled() || x == nullptr || frames <= 0 || channels <= 0) {
      return;
    }
    const float sr = sr_.load();
    if (resetMaster_.exchange(false)) {
      master_.setup(sr);
      masterHist_.clear();
      sinceUpdate_ = 0;
      invalid_ = 0;
    }
    inputChannels_.store(channels);
    // Peak meters for the check page, falling about 20 dB per second.
    const float fall = std::pow(10.0f, -20.0f / 20.0f * (float)frames / sr);
    for (int c = 0; c < std::min(channels, kMaxInputs); ++c) {
      float peak = 0.0f;
      for (int i = 0; i < frames; ++i) {
        peak = std::max(peak, std::fabs(x[(size_t)i * channels + c]));
      }
      levels_[c].store(std::max(peak, levels_[c].load() * fall));
    }
    if (channels < 8) {
      return; // no master return (inputs 7-8)
    }
    mono_.resize((size_t)frames);
    for (int i = 0; i < frames; ++i) {
      mono_[(size_t)i] = 0.5f * (x[(size_t)i * channels + 6] + x[(size_t)i * channels + 7]);
    }
    const int64_t start = endTimeNs - (int64_t)((double)(frames - 1) * 1.0e9 / sr);
    master_.feed(mono_.data(), frames, start, [this](const Hop& h) {
      masterHist_.push_back(h);
      ++sinceUpdate_;
    });
    if (masterHist_.size() > (size_t)kMasterWindow) {
      masterHist_.erase(masterHist_.begin(),
                        masterHist_.begin() + (std::ptrdiff_t)(masterHist_.size() - kMasterWindow));
    }
    if (sinceUpdate_ >= 50) {
      sinceUpdate_ = 0;
      update();
    }
  }

  float share(int deck) const { return deck == 0 ? shareA_.load() : shareB_.load(); }
  float lagMs() const { return lagMs_.load(); }
  float fit() const { return fit_.load(); }
  int inputChannels() const { return inputChannels_.load(); }
  float inputLevel(int c) const { return c >= 0 && c < kMaxInputs ? levels_[c].load() : 0.0f; }

 private:
  void update() {
    deckRing_.latest(deckScratch_, kDeckHistory);
    const Result r = estimate(masterHist_, deckScratch_, kMaxLagMs);
    if (!r.valid) {
      // No judgement for ~3 s: report unknown, so callers fall back.
      if (++invalid_ >= 6) {
        shareA_.store(-1.0f);
        shareB_.store(-1.0f);
      }
      return;
    }
    invalid_ = 0;
    // Light smoothing; the controller adds hysteresis on top.
    auto smooth = [](std::atomic<float>& s, double v) {
      const float old = s.load();
      s.store(old < 0.0f ? (float)v : 0.5f * old + 0.5f * (float)v);
    };
    smooth(shareA_, r.shareA);
    smooth(shareB_, r.shareB);
    if (r.lagMs >= 0.0) {
      smooth(lagMs_, r.lagMs);
      fit_.store((float)r.fit);
    }
  }

  std::atomic<bool> enabled_{false};
  std::atomic<bool> resetDecks_{true};
  std::atomic<bool> resetMaster_{true};
  std::atomic<float> sr_{48000.0f};

  // Render thread only.
  BandMeter deckA_, deckB_;
  Hop pendingHop_;
  bool pendingA_ = false;
  Ring<DeckHop, 1024> deckRing_;

  // Capture thread only.
  BandMeter master_;
  std::vector<float> mono_;
  std::vector<Hop> masterHist_;
  std::vector<DeckHop> deckScratch_;
  int sinceUpdate_ = 0;
  int invalid_ = 0;

  std::atomic<float> shareA_{-1.0f}, shareB_{-1.0f}, lagMs_{-1.0f}, fit_{0.0f};
  std::atomic<int> inputChannels_{0};
  std::atomic<float> levels_[kMaxInputs] = {};
};

} // namespace onair
