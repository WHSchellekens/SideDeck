#pragma once

/* Dart FFI resolves these via dlsym on the main executable. They must stay
 * globally visible and must not be stripped from Release/TestFlight builds. */
#if defined(__GNUC__) || defined(__clang__)
#define DJ_FFI_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#else
#define DJ_FFI_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef void* DjEngine;

DJ_FFI_EXPORT DjEngine dj_create(void);
DJ_FFI_EXPORT void dj_destroy(DjEngine engine);

DJ_FFI_EXPORT int dj_start(DjEngine engine);
DJ_FFI_EXPORT void dj_stop(DjEngine engine);

/** Output mode: 0 = internal stereo (phone), 1 = external 4ch USB (deck A 1-2, B 3-4).
 *  Android: mode 1 stops Oboe; Java USB AudioTrack is the sink.
 *  iOS: mode 1 opens a 4-channel RemoteIO stream on the current USB route. */
DJ_FFI_EXPORT int dj_set_output_mode(DjEngine engine, int mode);
DJ_FFI_EXPORT int dj_get_output_mode(DjEngine engine);
DJ_FFI_EXPORT int dj_get_output_channels(DjEngine engine);

DJ_FFI_EXPORT int dj_load(DjEngine engine, int deck, const char* path);
DJ_FFI_EXPORT void dj_unload(DjEngine engine, int deck);

DJ_FFI_EXPORT void dj_play(DjEngine engine, int deck, int playing);

/** Quantized start (default on): a deck that starts while the other deck plays is moved,
 *  by at most half a beat, onto the playing deck's beat phase. Applied at the top of the
 *  next render callback, so it is sample-accurate and independent of output latency. */
DJ_FFI_EXPORT void dj_set_quantize(DjEngine engine, int enabled);
DJ_FFI_EXPORT int dj_get_quantize(DjEngine engine);

/** On-air detection (external mixer): compares what each deck sends with the mixer's
 *  master return on USB inputs 7-8 (fed by the Android capture thread). Share of the
 *  master explained by a deck, 0..1, or -1 while unknown; lag is the render-to-capture
 *  delay in ms (phone to mixer and back into the phone), -1 until found. */
DJ_FFI_EXPORT void dj_onair_enable(DjEngine engine, int enabled);
DJ_FFI_EXPORT float dj_onair_share(DjEngine engine, int deck);
DJ_FFI_EXPORT float dj_onair_lag_ms(DjEngine engine);
DJ_FFI_EXPORT float dj_onair_fit(DjEngine engine);
/** Captured USB input channels and their peak levels (0..1), for the check screen. */
DJ_FFI_EXPORT int dj_input_channels(DjEngine engine);
DJ_FFI_EXPORT float dj_input_level(DjEngine engine, int channel);
DJ_FFI_EXPORT void dj_seek(DjEngine engine, int deck, double seconds);
DJ_FFI_EXPORT void dj_set_cue(DjEngine engine, int deck);
DJ_FFI_EXPORT void dj_jump_cue(DjEngine engine, int deck);

DJ_FFI_EXPORT double dj_position(DjEngine engine, int deck);
DJ_FFI_EXPORT double dj_duration(DjEngine engine, int deck);
DJ_FFI_EXPORT int dj_playing(DjEngine engine, int deck);
DJ_FFI_EXPORT int dj_loaded(DjEngine engine, int deck);

DJ_FFI_EXPORT void dj_set_gain(DjEngine engine, int deck, float linear);
DJ_FFI_EXPORT void dj_set_eq(DjEngine engine, int deck, float low_db, float mid_db, float high_db);
DJ_FFI_EXPORT void dj_set_filter(DjEngine engine, int deck, float amount);
DJ_FFI_EXPORT void dj_set_fader(DjEngine engine, int deck, float linear);
DJ_FFI_EXPORT void dj_set_xfader(DjEngine engine, float x);
DJ_FFI_EXPORT void dj_set_master(DjEngine engine, float linear);
DJ_FFI_EXPORT void dj_set_rate(DjEngine engine, int deck, float rate);
DJ_FFI_EXPORT void dj_set_keylock(DjEngine engine, int deck, int enabled);

DJ_FFI_EXPORT float dj_get_bpm(DjEngine engine, int deck);
DJ_FFI_EXPORT int dj_get_key(DjEngine engine, int deck);
DJ_FFI_EXPORT float dj_get_beat_offset(DjEngine engine, int deck);
DJ_FFI_EXPORT void dj_nudge_grid(DjEngine engine, int deck, float seconds);

DJ_FFI_EXPORT void dj_set_loop(DjEngine engine, int deck, int enabled, float bars);
DJ_FFI_EXPORT double dj_loop_start(DjEngine engine, int deck);
DJ_FFI_EXPORT double dj_loop_end(DjEngine engine, int deck);
DJ_FFI_EXPORT void dj_set_hotcue(DjEngine engine, int deck, int index, double seconds);
DJ_FFI_EXPORT void dj_jump_hotcue(DjEngine engine, int deck, int index);
DJ_FFI_EXPORT double dj_get_hotcue(DjEngine engine, int deck, int index);
DJ_FFI_EXPORT void dj_clear_hotcue(DjEngine engine, int deck, int index);
DJ_FFI_EXPORT void dj_beat_jump(DjEngine engine, int deck, int beats);

DJ_FFI_EXPORT int dj_waveform_bins(void);
/** Waveform bins of a loaded deck (fixed 2.5 ms each, see dj_waveform_bin_seconds). */
DJ_FFI_EXPORT int dj_waveform_length(DjEngine engine, int deck);
DJ_FFI_EXPORT double dj_waveform_bin_seconds(DjEngine engine, int deck);
DJ_FFI_EXPORT int dj_waveform_copy(DjEngine engine, int deck, float* min_out, float* max_out, int bins);
/** RMS per waveform bin in the EQ's low (<246 Hz), mid and high (>2484 Hz) bands. */
DJ_FFI_EXPORT int dj_waveform_bands_copy(DjEngine engine, int deck, float* low_out, float* mid_out,
                                         float* high_out, int bins);

/** Decode a 60s prefix (22 kHz mono) + BPM/key/grid. Uses ID3 TBPM/TKEY when present. */
DJ_FFI_EXPORT int dj_analyze_file(const char* path, float* bpm, int* key, float* beat_offset);

/** Length in seconds from the file header / decoder. Does not decode PCM. */
DJ_FFI_EXPORT double dj_file_duration(const char* path);

/** Load PCM and apply previously cached analysis (skips BPM/key). bpm<=0 runs a full analyze. */
DJ_FFI_EXPORT int dj_load_with_analysis(DjEngine engine, int deck, const char* path, float bpm, int key,
                                        float beat_offset);

/** Null-terminated reason for the last failed dj_load / open, or "". */
DJ_FFI_EXPORT const char* dj_last_error(void);

#ifdef __cplusplus
}
#endif
