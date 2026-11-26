#pragma once

// Quantized start: when a deck starts while the other deck is playing, move
// the starting deck so its beat phase matches the playing deck's phase at the
// same output sample. Both decks are read at the top of one render callback,
// so the playback rate does not enter the phase at that instant; it only sets
// how fast the decks drift apart afterwards, which is the DJ's job.
//
// Pure functions, no engine state, so they can be unit tested on the host
// (native/engine/test/quantize_test.cpp).

#include <algorithm>
#include <cmath>

namespace quantize {

// Fractional beat position in [0, 1) at file time posSec.
inline double beatPhase(double posSec, double bpm, double beatOffsetSec) {
  const double beats = (posSec - beatOffsetSec) * bpm / 60.0;
  return beats - std::floor(beats);
}

// Seconds (in the starting deck's file time) to move the starting deck so its
// phase equals the playing deck's. Always the smallest move: the result lies
// in [-half a beat, +half a beat) of the starting deck. Returns 0 when either
// tempo is unknown.
inline double alignShiftSec(double masterPosSec, double masterBpm, double masterOffsetSec,
                            double slavePosSec, double slaveBpm, double slaveOffsetSec) {
  if (!(masterBpm > 0.0) || !(slaveBpm > 0.0)) {
    return 0.0;
  }
  const double target = beatPhase(masterPosSec, masterBpm, masterOffsetSec);
  const double current = beatPhase(slavePosSec, slaveBpm, slaveOffsetSec);
  double beats = target - current; // (-1, 1)
  beats -= std::floor(beats + 0.5); // [-0.5, 0.5)
  return beats * 60.0 / slaveBpm;
}

// Where the starting deck begins after a shift. A whole-beat correction keeps
// the phase, so:
//  - inside (or past) an active loop, wrap into the loop (SideDeck loops are
//    whole beats long). Cued before the loop, the deck plays into it as usual;
//  - before the start of the file, go one beat later instead;
//  - past the end, go one beat earlier.
inline double placeStart(double posSec, double shiftSec, double beatSec, double durationSec,
                         bool loopOn, double loopStartSec, double loopEndSec) {
  double t = posSec + shiftSec;
  const double loopLen = loopEndSec - loopStartSec;
  if (loopOn && loopLen > 1.0e-6 && std::max(posSec, t) >= loopStartSec) {
    double rel = std::fmod(t - loopStartSec, loopLen);
    if (rel < 0.0) {
      rel += loopLen;
    }
    return loopStartSec + rel;
  }
  if (t < 0.0) {
    t += beatSec;
  }
  if (durationSec > 0.0 && t >= durationSec) {
    t -= beatSec;
  }
  return std::max(0.0, t);
}

} // namespace quantize
