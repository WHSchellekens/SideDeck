// Host unit test for quantize.hpp. No framework, no engine, no audio.
//
//   cmake -S native/engine -B build/native-tests && cmake --build build/native-tests
//   ctest --test-dir build/native-tests --output-on-failure
//
// or directly:
//
//   g++ -std=c++17 -Wall -Wextra -I native/engine native/engine/test/quantize_test.cpp -o quantize_test
//   ./quantize_test

#include "quantize.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace {

int failures = 0;

void expectNear(const char* what, double got, double want, double tol = 1.0e-9) {
  if (std::fabs(got - want) > tol) {
    std::printf("FAIL %s: got %.12f, want %.12f\n", what, got, want);
    ++failures;
  }
}

void expectTrue(const char* what, bool ok) {
  if (!ok) {
    std::printf("FAIL %s\n", what);
    ++failures;
  }
}

// Phase distance on the circle, in beats.
double phaseGap(double a, double b) {
  double d = std::fabs(a - b);
  return std::min(d, 1.0 - d);
}

void testBeatPhase() {
  // 120 BPM: one beat is 0.5 s.
  expectNear("phase at offset", quantize::beatPhase(0.25, 120.0, 0.25), 0.0);
  expectNear("phase quarter beat", quantize::beatPhase(0.375, 120.0, 0.25), 0.25);
  expectNear("phase before offset wraps", quantize::beatPhase(0.0, 120.0, 0.125), 0.75);
}

void testShiftForward() {
  // Same tempo and grid; master is 0.1 beat ahead of the starting deck.
  const double beat = 0.5;
  const double shift = quantize::alignShiftSec(10.0 + 0.3 * beat, 120.0, 0.0, 20.0 + 0.2 * beat,
                                               120.0, 0.0);
  expectNear("shift forward", shift, 0.1 * beat);
}

void testShiftWrapsAcrossBeat() {
  // Master just past a beat (0.05), starting deck just before one (0.95):
  // the short way is +0.1 beat through the beat line, not -0.9.
  const double beat = 0.5;
  const double shift = quantize::alignShiftSec(0.05 * beat, 120.0, 0.0, 0.95 * beat, 120.0, 0.0);
  expectNear("shift wraps forward", shift, 0.1 * beat);
  const double back = quantize::alignShiftSec(0.95 * beat, 120.0, 0.0, 0.05 * beat, 120.0, 0.0);
  expectNear("shift wraps backward", back, -0.1 * beat);
}

void testDifferentTempoAndOffsets() {
  // Master 128 BPM with its grid at 0.11 s; starting deck 122 BPM, grid at 0.37 s.
  const double mPos = 31.7, sPos = 64.2;
  const double shift = quantize::alignShiftSec(mPos, 128.0, 0.11, sPos, 122.0, 0.37);
  const double sBeat = 60.0 / 122.0;
  expectTrue("shift within half a beat", shift >= -0.5 * sBeat && shift < 0.5 * sBeat);
  const double after = quantize::beatPhase(sPos + shift, 122.0, 0.37);
  const double master = quantize::beatPhase(mPos, 128.0, 0.11);
  expectNear("phases match after shift", phaseGap(after, master), 0.0, 1.0e-9);
}

void testManyCases() {
  // Deterministic sweep: after the shift the phases always match, and the
  // shift never exceeds half a beat of the starting deck.
  unsigned seed = 12345u;
  auto next = [&seed]() {
    seed = seed * 1664525u + 1013904223u;
    return (double)(seed >> 8) / (double)(1u << 24);
  };
  for (int i = 0; i < 10000; ++i) {
    const double mBpm = 70.0 + next() * 110.0;
    const double sBpm = 70.0 + next() * 110.0;
    const double mOff = next() * 2.0 - 0.5;
    const double sOff = next() * 2.0 - 0.5;
    const double mPos = next() * 400.0;
    const double sPos = next() * 400.0;
    const double shift = quantize::alignShiftSec(mPos, mBpm, mOff, sPos, sBpm, sOff);
    const double sBeat = 60.0 / sBpm;
    if (!(shift >= -0.5 * sBeat - 1.0e-12 && shift < 0.5 * sBeat + 1.0e-12)) {
      std::printf("FAIL sweep %d: shift %.9f outside half a beat %.9f\n", i, shift, 0.5 * sBeat);
      ++failures;
      return;
    }
    const double gap = phaseGap(quantize::beatPhase(sPos + shift, sBpm, sOff),
                                quantize::beatPhase(mPos, mBpm, mOff));
    if (gap > 1.0e-7) {
      std::printf("FAIL sweep %d: phase gap %.12f\n", i, gap);
      ++failures;
      return;
    }
  }
}

void testUnknownTempo() {
  expectNear("no master bpm", quantize::alignShiftSec(1.0, 0.0, 0.0, 2.0, 120.0, 0.0), 0.0);
  expectNear("no slave bpm", quantize::alignShiftSec(1.0, 120.0, 0.0, 2.0, 0.0, 0.0), 0.0);
}

void testPlaceStart() {
  const double beat = 0.5;
  // Cued at the very start; a backward shift would land before the file, so
  // go one beat later instead (same phase).
  expectNear("before start goes a beat later",
             quantize::placeStart(0.0, -0.1, beat, 300.0, false, 0.0, 0.0), 0.4);
  // Near the end; a forward shift past the end goes a beat earlier.
  expectNear("past end goes a beat earlier",
             quantize::placeStart(299.95, 0.1, beat, 300.0, false, 0.0, 0.0), 299.55);
  // Plain case.
  expectNear("plain shift", quantize::placeStart(12.0, -0.2, beat, 300.0, false, 0.0, 0.0), 11.8);
  // A 4-beat loop from 10.0 to 12.0: a shift that leaves the loop wraps into it.
  expectNear("loop wraps forward",
             quantize::placeStart(11.9, 0.2, beat, 300.0, true, 10.0, 12.0), 10.1);
  expectNear("loop wraps backward",
             quantize::placeStart(10.05, -0.2, beat, 300.0, true, 10.0, 12.0), 11.85);
  // Cued before the loop: start where you cued, the loop comes later.
  expectNear("cued before loop stays put",
             quantize::placeStart(5.0, -0.1, beat, 300.0, true, 10.0, 12.0), 4.9);
  expectNear("shift into loop start is not wrapped",
             quantize::placeStart(9.95, 0.1, beat, 300.0, true, 10.0, 12.0), 10.05);
  // Wrapping by the loop length keeps the phase.
  const double before = quantize::beatPhase(11.9 + 0.2, 120.0, 0.0);
  const double after = quantize::beatPhase(10.1, 120.0, 0.0);
  expectNear("loop wrap keeps phase", phaseGap(before, after), 0.0, 1.0e-9);
}

} // namespace

int main() {
  testBeatPhase();
  testShiftForward();
  testShiftWrapsAcrossBeat();
  testDifferentTempoAndOffsets();
  testManyCases();
  testUnknownTempo();
  testPlaceStart();
  if (failures != 0) {
    std::printf("%d failure(s)\n", failures);
    return EXIT_FAILURE;
  }
  std::printf("quantize: all tests passed\n");
  return EXIT_SUCCESS;
}
