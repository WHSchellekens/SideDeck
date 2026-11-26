import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/engine/usb_output.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/ui_settings.dart';
import 'package:sidedeck/subsonic/subsonic_client.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/sidekick_check_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.dj, required this.ui});

  final DjController dj;
  final UiSettings ui;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _status;
  bool _busy = false;
  Timer? _usbPoll;
  UsbStats? _usbStats;
  final List<double> _latency = [];

  @override
  void initState() {
    super.initState();
    _load();
    if (Platform.isAndroid) {
      _usbPoll = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _pollUsb(),
      );
    }
  }

  Future<void> _pollUsb() async {
    if (!widget.dj.externalMixer) {
      if (_usbStats != null && mounted) {
        setState(() {
          _usbStats = null;
          _latency.clear();
        });
      }
      return;
    }
    final s = await UsbOutput.stats();
    if (!mounted) return;
    if (s != null && s.bufferMode != _usbStats?.bufferMode) _latency.clear();
    if (s != null && s.latencyMs >= 0 && s.latencyMs < 1000) {
      _latency.add(s.latencyMs);
      if (_latency.length > 8) _latency.removeAt(0);
    }
    setState(() => _usbStats = s);
  }

  /// Median of the last few readings; single timestamps jitter by a block.
  double? get _latencyMs {
    if (_latency.isEmpty) return null;
    final sorted = [..._latency]..sort();
    return sorted[sorted.length ~/ 2];
  }

  String _usbStatusLine() {
    if (!widget.dj.externalMixer) {
      return 'Applies while the external mixer is on.';
    }
    final s = _usbStats;
    if (s == null) return 'Waiting for USB output…';
    final lat = _latencyMs;
    final latency = lat == null ? '—' : '≈ ${lat.round()} ms';
    final fast = s.lowLatencyGranted ? ', low-latency track' : '';
    return 'Running ${s.bufferMode.label}: buffer ${s.bufferFrames} frames '
        '(${s.bufferMs.toStringAsFixed(1)} ms$fast)\n'
        'Underruns ${s.underruns}   ·   Output latency $latency';
  }

  String _onAirStatus() {
    final dj = widget.dj;
    final lines = <String>[
      dj.midiDevice.isEmpty ? 'MIDI: no port from the mixer' : 'MIDI: ${dj.midiDevice}',
    ];
    if (!dj.externalMixer) {
      lines.add('Applies while the external mixer is on.');
    } else {
      for (var i = 0; i < 2; i++) {
        final how = switch (dj.onAirSource(i)) {
          OnAirSource.midi => 'mixer fader (MIDI)',
          OnAirSource.listening => 'heard in the master',
          OnAirSource.none => 'no signal yet; counts while playing',
        };
        lines.add('Deck ${i == 0 ? 'A' : 'B'}: $how');
      }
      final lat = dj.mixerLatencyMs;
      if (lat != null) lines.add('Phone → mixer → phone: ≈ ${lat.round()} ms');
    }
    if (dj.listenNote.isNotEmpty) lines.add(dj.listenNote);
    return lines.join('\n');
  }

  Future<void> _setUsbBuffer(UsbBufferMode mode) async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.dj.setUsbBuffer(mode);
    if (!mounted) return;
    setState(() {
      _usbStats = null;
      _latency.clear();
    });
    final err = widget.dj.engineError;
    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(err)));
      widget.dj.clearError();
    }
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _url.text = prefs.getString('subsonic_url') ?? '';
    _user.text = prefs.getString('subsonic_user') ?? '';
    _pass.text = prefs.getString('subsonic_pass') ?? '';
    setState(() {});
  }

  Future<void> _saveAndTest() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await SubsonicClient.savePrefs(
        url: _url.text.trim(),
        user: _user.text.trim(),
        pass: _pass.text,
      );
      final client = SubsonicClient(
        baseUrl: _url.text.trim(),
        username: _user.text.trim(),
        password: _pass.text,
      );
      await client.ping();
      setState(() => _status = 'Connected OK');
    } catch (e) {
      setState(() => _status = 'Failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _usbPoll?.cancel();
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = SideDeckColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'External mixer',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            'Turn this on with a USB mixer plugged into the phone. Deck A and Deck B '
            'go out as separate channels so you mix and cue on the hardware — the '
            'on-screen EQ/crossfader hides. Works with devices such as the EP-136 '
            '(set USB mode to Multi). iPhone needs USB-C or a Lightning camera adapter.',
            style: TextStyle(color: pal.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use external mixer'),
            subtitle: Text(
              widget.dj.externalMixer
                  ? 'ON — Deck A → USB 1–2, Deck B → USB 3–4 on the '
                      '${UsbOutput.deviceLabel(widget.dj.usbDeviceName)}'
                  : 'OFF — audio stays on the phone',
            ),
            value: widget.dj.externalMixer,
            onChanged: (v) async {
              final messenger = ScaffoldMessenger.of(context);
              await widget.dj.setExternalMixer(v);
              if (!mounted) return;
              setState(() {});
              final err = widget.dj.engineError;
              if (err != null) {
                messenger.showSnackBar(SnackBar(content: Text(err)));
                widget.dj.clearError();
              }
            },
          ),
          if (Platform.isAndroid) ...[
            const SizedBox(height: 12),
            const Text(
              'USB buffer',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              'Smaller responds faster when you start a track or nudge, but can '
              'crackle. Try Ultra, play for a while and watch the underruns; if '
              'they climb, step back to Low or Safe.',
              style: TextStyle(color: pal.muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 8),
            SegmentedButton<UsbBufferMode>(
              showSelectedIcon: false,
              segments: [
                for (final m in UsbBufferMode.values)
                  ButtonSegment(
                    value: m,
                    label: Text('${m.label} · ${m.targetMs} ms'),
                  ),
              ],
              selected: {widget.dj.usbBuffer},
              onSelectionChanged: (s) => _setUsbBuffer(s.first),
            ),
            const SizedBox(height: 8),
            Text(
              _usbStatusLine(),
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            if (widget.dj.usbDetails.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'USB details',
                style: TextStyle(fontSize: 12, color: pal.muted),
              ),
              SelectableText(
                widget.dj.usbDetails,
                style: TextStyle(fontSize: 11, height: 1.4, color: pal.muted),
              ),
            ],
            const SizedBox(height: 16),
            const Text(
              'On air',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              'Played marks and the ON AIR tag follow the Sidekick’s faders when it '
              'sends them over MIDI. Otherwise SideDeck can listen to its master '
              'output (USB inputs 7–8) to tell which deck you hear. Without either, '
              'a playing deck counts as on air.',
              style: TextStyle(color: pal.muted, fontSize: 12, height: 1.4),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Read the faders over MIDI'),
              subtitle: const Text(
                'Opens the Sidekick’s MIDI port (MIDI set to ON on the Sidekick). '
                'If its audio stops when you turn this on, turn it off and replug '
                'the cable: some phones cut USB audio while the port is open.',
              ),
              value: widget.dj.readMixerMidi,
              onChanged: (v) async {
                await widget.dj.setReadMixerMidi(v);
                if (mounted) setState(() {});
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Listen to the mixer'),
              subtitle: const Text(
                'Asks for microphone access. Only the mixer’s USB inputs are read; '
                'nothing is recorded or stored.',
              ),
              value: widget.dj.listenToMixer,
              onChanged: (v) async {
                await widget.dj.setListenToMixer(v);
                if (mounted) setState(() {});
              },
            ),
            Text(
              _onAirStatus(),
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => SidekickCheckPage(dj: widget.dj)),
                ),
                child: const Text('Sidekick check'),
              ),
            ),
          ],
          const Divider(height: 32),
          const Text(
            'Playback',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Quantize'),
            subtitle: const Text(
              'A deck you start while the other one plays lands on its beat. '
              'It moves at most half a beat.',
            ),
            value: widget.dj.quantize,
            onChanged: (v) async {
              await widget.dj.setQuantize(v);
              if (mounted) setState(() {});
            },
          ),
          const Divider(height: 32),
          const Text(
            'Display',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Outdoor mode'),
            subtitle: const Text(
              'Light screen that stays readable in daylight. Dark is easier '
              'on the eyes in a club.',
            ),
            value: widget.ui.outdoor,
            onChanged: (v) async {
              await widget.ui.setOutdoor(v);
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 8),
          const Text(
            'Waveform',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(height: 4),
          Text(
            'Solid lines, the Sidekick’s dot matrix, or a filled curve with a '
            'line along the peaks.',
            style: TextStyle(color: pal.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 8),
          SegmentedButton<WaveStyle>(
            showSelectedIcon: false,
            segments: [
              for (final s in WaveStyle.values)
                ButtonSegment(value: s, label: Text(s.label)),
            ],
            selected: {widget.ui.waveStyle},
            onSelectionChanged: (s) async {
              await widget.ui.setWaveStyle(s.first);
              if (mounted) setState(() {});
            },
          ),
          const Divider(height: 32),
          const Text(
            'Subsonic server',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            'Optional. Tracks download to a local cache, then play like local files. '
            'Use http:// for a server on your LAN. Use https:// if the server is '
            'on the internet — otherwise the login token travels in the clear.',
            style: TextStyle(color: pal.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'http://192.168.1.10:4533',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _user,
            decoration: const InputDecoration(
              labelText: 'Username',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pass,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _saveAndTest,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save & ping'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!),
          ],
          const Divider(height: 32),
          const Text(
            'About',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            'SideDeck 1.1.0\n'
            'Copyright © 2026 SideDeck contributors\n\n'
            'This program is free software under the GNU GPL v3 or later. '
            'There is no warranty.\n\n'
            'Support & issues: github.com/manueljpy/SideDeck',
            style: TextStyle(color: pal.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () {
              showLicensePage(
                context: context,
                applicationName: 'SideDeck',
                applicationVersion: '1.1.0',
                applicationLegalese:
                    'Copyright © 2026 SideDeck contributors\n\n'
                    'GNU GPL v3 or later. See LICENSE and NOTICE in the '
                    'source repository.',
              );
            },
            child: const Text('Open-source licenses'),
          ),
        ],
      ),
    );
  }
}
