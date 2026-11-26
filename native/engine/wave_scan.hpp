#pragma once

// Waveform overview data for a whole track: min/max per bin (the shape) and
// RMS in the mixer's three EQ bands per bin (what it is made of: kicks and
// bass are low, vocals and synths mid, hats high). The UI lights the waveform
// by the low band, so kicks stand out, and can show where a track drops.
//
// Bins arrive in order, so each bin's sums are flushed when the next starts;
// no per-bin accumulators. Host-tested in native/engine/test/wave_scan_test.cpp.

#include "biquad.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

// Same split as the mixer's EQ (dj_engine.cpp kEqLowHz / kEqHighHz).
constexpr float kWaveLowHz = 246.0f;
constexpr float kWaveHighHz = 2484.0f;

class WaveScan {
 public:
  std::vector<float> min, max;        // per bin, mono
  std::vector<float> low, mid, high;  // per bin, RMS per band

  void begin(int bins, uint64_t totalFrames, float sampleRate) {
    bins_ = std::max(1, bins);
    total_ = totalFrames;
    min.assign((size_t)bins_, 0.0f);
    max.assign((size_t)bins_, 0.0f);
    low.assign((size_t)bins_, 0.0f);
    mid.assign((size_t)bins_, 0.0f);
    high.assign((size_t)bins_, 0.0f);
    const float sr = std::max(1.0f, sampleRate);
    lowPass_.lowPass(sr, kWaveLowHz);
    lowPass_.reset();
    highPass_.highPass(sr, kWaveHighHz, LR4::kButterQ);
    highPass_.reset();
    bin_ = -1;
    clearSums();
  }

  // Interleaved stereo frames starting at file frame `start`.
  void feed(const float* stereo, uint64_t frames, uint64_t start) {
    if (total_ == 0) {
      return;
    }
    for (uint64_t i = 0; i < frames; ++i) {
      const int b = (int)std::min<uint64_t>((uint64_t)bins_ - 1, (start + i) * (uint64_t)bins_ / total_);
      if (b != bin_) {
        flush();
        bin_ = b;
      }
      const float s = 0.5f * (stereo[(size_t)i * 2] + stereo[(size_t)i * 2 + 1]);
      lo_ = std::min(lo_, s);
      hi_ = std::max(hi_, s);
      const float l = lowPass_.process(s);
      const float h = highPass_.process(s);
      eAll_ += (double)s * s;
      eLow_ += (double)l * l;
      eHigh_ += (double)h * h;
      ++count_;
    }
  }

  void finish() { flush(); }

 private:
  void clearSums() {
    lo_ = 0.0f;
    hi_ = 0.0f;
    eAll_ = eLow_ = eHigh_ = 0.0;
    count_ = 0;
  }

  void flush() {
    if (bin_ >= 0 && count_ > 0) {
      const size_t b = (size_t)bin_;
      min[b] = lo_;
      max[b] = hi_;
      const double n = (double)count_;
      // The mid band is what the other two leave: the crossover sums flat, so
      // energies roughly add.
      low[b] = (float)std::sqrt(eLow_ / n);
      high[b] = (float)std::sqrt(eHigh_ / n);
      mid[b] = (float)std::sqrt(std::max(0.0, eAll_ - eLow_ - eHigh_) / n);
    }
    clearSums();
  }

  int bins_ = 1;
  uint64_t total_ = 0;
  int bin_ = -1;
  LR4 lowPass_;
  Biquad highPass_;
  float lo_ = 0.0f, hi_ = 0.0f;
  double eAll_ = 0.0, eLow_ = 0.0, eHigh_ = 0.0;
  int64_t count_ = 0;
};
