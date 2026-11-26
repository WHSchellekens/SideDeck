import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/state/played_tracks.dart';

void main() {
  test('PlayClock fires once at the threshold', () {
    final clock = PlayClock(thresholdSec: 30);
    var fired = 0;
    // Quarter seconds add up exactly in binary floating point.
    for (var i = 0; i < 119; i++) {
      if (clock.add(0.25)) fired++;
    }
    expect(fired, 0, reason: '29.75 s is a preview, not a play');
    expect(clock.add(0.25), isTrue);
    expect(clock.add(10), isFalse, reason: 'only once per load');
    clock.reset();
    expect(clock.seconds, 0);
    expect(clock.add(31), isTrue);
  });

  test('PlayClock ignores zero and negative steps', () {
    final clock = PlayClock(thresholdSec: 1);
    expect(clock.add(0), isFalse);
    expect(clock.add(-5), isFalse);
    expect(clock.seconds, 0);
  });

  test('PlayedTracks survives a restart and clears on a new set', () async {
    SharedPreferences.setMockInitialValues({});
    final when = DateTime(2026, 11, 26, 22, 4);
    final played = PlayedTracks();
    await played.mark('/music/DJ/Warm-up/a.mp3', when);
    expect(played.contains('/music/DJ/Warm-up/a.mp3'), isTrue);

    final reopened = PlayedTracks();
    await reopened.load();
    expect(reopened.at('/music/DJ/Warm-up/a.mp3'), when);
    expect(reopened.countIn(['/music/DJ/Warm-up/a.mp3', '/music/DJ/Warm-up/b.mp3']), 1);

    await reopened.clear();
    final again = PlayedTracks();
    await again.load();
    expect(again.length, 0);
  });

  test('formatPlayedAt', () {
    expect(formatPlayedAt(DateTime(2026, 1, 1, 9, 5)), '09:05');
  });
}
