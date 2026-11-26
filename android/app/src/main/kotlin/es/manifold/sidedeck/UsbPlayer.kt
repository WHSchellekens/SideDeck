package es.manifold.sidedeck

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioMixerAttributes
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.RequiresApi
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max

/**
 * Multi-channel USB playback: deck A on USB 1-2, deck B on USB 3-4.
 *
 * Two paths, best first:
 *  1. Android 14+ preferred mixer attributes, which reconfigure the USB output
 *     stream itself. Without this the stream is usually opened as stereo and
 *     AudioFlinger silently drops channels 3-4.
 *  2. A plain AudioTrack with a channel index mask, which addresses USB channels
 *     by number rather than by speaker position.
 *
 * Not Oboe/AAudio: some devices still drive only the front pair of a 4ch stream
 * (google/oboe#2204), and before Android 17 AAudio treats the output reopen caused
 * by preferred mixer attributes as a disconnect, where AudioTrack restores itself
 * (google/oboe#2343).
 *
 * Buffer modes (Settings > USB buffer): SAFE is the original path. LOW and ULTRA
 * ask for PERFORMANCE_MODE_LOW_LATENCY and shrink the buffer after start. A low
 * mode that does not come up falls back to SAFE.
 */
object UsbPlayer {
    init {
        System.loadLibrary("dj_engine")
    }

    @JvmStatic
    external fun usbRender(handle: Long, buffer: ByteBuffer, frames: Int, channels: Int)

    enum class BufferMode(val key: String, val targetMs: Int, val lowLatency: Boolean) {
        SAFE("safe", 50, false),
        LOW("low", 20, true),
        ULTRA("ultra", 10, true);

        companion object {
            fun from(key: String?): BufferMode = values().firstOrNull { it.key == key } ?: SAFE
        }
    }

    private const val FRAMES = 256
    private const val LOW_LATENCY_BLOCK = 128
    private const val SAMPLE_RATE = 48000
    private const val VERIFY_TIMEOUT_NS = 500_000_000L
    private const val MAX_STALLS = 200
    private const val STALL_SLEEP_MS = 5L

    @Volatile
    private var running = false
    private var thread: Thread? = null
    @Volatile
    private var track: AudioTrack? = null
    private var audioManager: AudioManager? = null
    private var preferredDevice: AudioDeviceInfo? = null
    private var preferredAttributes: AudioAttributes? = null
    private var activeDeviceId = 0
    private var activeDeviceName = ""
    @Volatile
    private var unexpectedStopListener: ((Int, String) -> Unit)? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // What the running track ended up with, for Settings.
    @Volatile
    private var activeMode = BufferMode.SAFE
    @Volatile
    private var activeBurst = 0
    @Volatile
    private var activeBlock = FRAMES
    @Volatile
    private var activeChannels = 0
    @Volatile
    private var samplesWritten = 0L
    // Silent frames startAndVerify() wrote into the last track it accepted. They count
    // in the track's frame position, so the latency estimate has to count them too.
    private var verifyFrames = 0L

    private fun mediaAttributes() = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .build()

    fun setUnexpectedStopListener(listener: ((id: Int, name: String) -> Unit)?) {
        unexpectedStopListener = listener
    }

    @Synchronized
    fun start(context: Context, handle: Long, deviceId: Int, channels: Int, bufferMode: String?): Map<String, Any> {
        val requested = BufferMode.from(bufferMode)
        if (!requested.lowLatency) return startWith(context, handle, deviceId, channels, BufferMode.SAFE)
        val low = startWith(context, handle, deviceId, channels, requested)
        if (low["ok"] == true) return low
        Log.w("sidedeck", "usb ${requested.key} buffer not accepted; falling back to safe")
        val safe = startWith(context, handle, deviceId, channels, BufferMode.SAFE)
        return safe + ("fallback" to (safe["ok"] == true))
    }

    private fun startWith(
        context: Context,
        handle: Long,
        deviceId: Int,
        channels: Int,
        mode: BufferMode,
    ): Map<String, Any> {
        stop()
        val notes = ArrayList<String>()
        notes.add("buffer mode: ${mode.key}")
        if (handle == 0L) return failure("Engine not ready", notes)

        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager = am
        val device = findDevice(am, deviceId)
        if (device == null) notes.add("no USB output device in AudioManager")

        var t: AudioTrack? = null
        if (Build.VERSION.SDK_INT >= 34 && device != null) {
            t = openViaMixerAttributes(am, device, mode, notes)
        } else if (device != null) {
            notes.add("Android ${Build.VERSION.SDK_INT}: preferred mixer attributes need API 34")
        }
        if (t == null) t = openViaDirectTrack(device, channels, mode, notes)
        if (t == null) return failure("Android refused a multi-channel USB track", notes)

        // Already playing: candidates are only accepted once startAndVerify() saw them consume audio.
        track = t
        val actual = t.channelCount
        val routed = t.routedDevice
        val encoding = t.audioFormat
        val burst = if (mode.lowLatency) burstFrames(am) else 0
        val block = if (!mode.lowLatency) {
            FRAMES
        } else if (burst in 64..FRAMES) {
            burst
        } else {
            LOW_LATENCY_BLOCK
        }
        if (mode.lowLatency) shrinkBuffer(t, mode, burst, notes)
        activeMode = mode
        activeBurst = burst
        activeBlock = block
        activeChannels = actual
        samplesWritten = verifyFrames * actual
        activeDeviceId = routed?.id ?: deviceId
        activeDeviceName = routed?.productName?.toString() ?: ""
        running = true
        thread = Thread({ loop(handle, actual, encoding, block) }, "sidedeck-usb").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
        notes.add("track: ${actual}ch ${encodingName(encoding)} @${t.sampleRate}Hz")
        notes.add("routed to: ${routed?.productName ?: "unknown"} (type ${routed?.type ?: -1})")
        notes.add("buffer ${t.bufferSizeInFrames}/${t.bufferCapacityInFrames} frames, block $block, burst $burst")
        Log.i("sidedeck", "usb start: ${notes.joinToString(" | ")}")

        val ok = actual >= 4
        return mapOf(
            "ok" to ok,
            "channels" to actual,
            "routedId" to activeDeviceId,
            "routedName" to activeDeviceName,
            "error" to if (ok) "" else "Only $actual channels available over USB",
            "bufferMode" to mode.key,
            "bufferFrames" to t.bufferSizeInFrames,
            "fallback" to false,
        )
    }

    @Synchronized
    fun stop() {
        running = false
        thread?.join(500)
        thread = null
        val t = track
        track = null
        try {
            t?.pause()
            t?.flush()
            t?.stop()
        } catch (_: Exception) {
        }
        t?.release()
        activeDeviceId = 0
        activeDeviceName = ""
        clearPreferred()
    }

    /**
     * Live figures for Settings: underruns since the track started, and an output
     * latency estimate from AudioTrack.getTimestamp() (when the frame written last
     * will reach the device, minus now). Safe to call from any thread.
     */
    fun stats(): Map<String, Any> {
        val t = track ?: return mapOf("active" to false)
        return try {
            val rate = t.sampleRate
            val ch = max(1, activeChannels)
            var latencyMs = -1.0
            val ts = AudioTimestamp()
            if (rate > 0 && t.getTimestamp(ts)) {
                val written = samplesWritten / ch
                val presentAtNs = ts.nanoTime + (written - ts.framePosition) * 1_000_000_000L / rate
                latencyMs = (presentAtNs - System.nanoTime()) / 1_000_000.0
            }
            val lowLatencyGranted = Build.VERSION.SDK_INT >= 26 &&
                t.performanceMode == AudioTrack.PERFORMANCE_MODE_LOW_LATENCY
            mapOf(
                "active" to true,
                "underruns" to t.underrunCount,
                "latencyMs" to latencyMs,
                "bufferFrames" to t.bufferSizeInFrames,
                "capacityFrames" to t.bufferCapacityInFrames,
                "sampleRate" to rate,
                "bufferMode" to activeMode.key,
                "burstFrames" to activeBurst,
                "blockFrames" to activeBlock,
                "lowLatencyGranted" to lowLatencyGranted,
            )
        } catch (e: Exception) {
            // Released under us by stop() on the control thread.
            mapOf("active" to false)
        }
    }

    /** Write-loop failure (not an intentional [stop]). Notifies Flutter on the main thread. */
    private fun signalUnexpectedStop() {
        if (!running) return
        running = false
        val id = activeDeviceId
        val name = activeDeviceName
        val listener = unexpectedStopListener ?: return
        mainHandler.post { listener(id, name) }
    }

    private fun clearPreferred() {
        val am = audioManager
        val device = preferredDevice
        val attrs = preferredAttributes
        preferredDevice = null
        preferredAttributes = null
        if (Build.VERSION.SDK_INT < 34 || am == null || device == null || attrs == null) return
        try {
            am.clearPreferredMixerAttributes(attrs, device)
        } catch (e: Exception) {
            Log.w("sidedeck", "clearPreferredMixerAttributes: $e")
        }
    }

    private fun failure(message: String, notes: List<String>): Map<String, Any> {
        Log.e("sidedeck", "usb start failed: $message | ${notes.joinToString(" | ")}")
        return mapOf(
            "ok" to false,
            "channels" to 0,
            "routedId" to 0,
            "routedName" to "",
            "error" to message,
            "bufferMode" to "",
            "bufferFrames" to 0,
            "fallback" to false,
        )
    }

    private fun findDevice(am: AudioManager, deviceId: Int): AudioDeviceInfo? {
        val outputs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        return outputs.firstOrNull { it.id == deviceId }
            ?: outputs.filter { UsbDevices.isUsbOutput(it) }
                .maxByOrNull { UsbDevices.maxChannels(am, it) }
    }

    /**
     * The phone's native output burst. AudioTrack has no per-device burst query, so this
     * is the primary output's figure; it is still the granularity the mixer works in.
     * 0 when the device does not report one.
     */
    private fun burstFrames(am: AudioManager): Int =
        am.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)?.toIntOrNull()?.takeIf { it > 0 } ?: 0

    /**
     * Shrink a started low-latency track to its target, rounded up to whole bursts. A burst
     * larger than the target is ignored rather than rounding Ultra up to a slow device's
     * 20 ms burst; AudioTrack still clamps to what it can do.
     */
    private fun shrinkBuffer(t: AudioTrack, mode: BufferMode, burst: Int, notes: MutableList<String>) {
        val want = max(64, mode.targetMs * t.sampleRate / 1000)
        val target = if (burst in 1..want) ((want + burst - 1) / burst) * burst else want
        val got = try {
            t.setBufferSizeInFrames(target)
        } catch (e: Exception) {
            notes.add("setBufferSizeInFrames threw: $e")
            return
        }
        notes.add("asked $target frames, got $got")
    }

    @RequiresApi(34)
    private fun openViaMixerAttributes(
        am: AudioManager,
        device: AudioDeviceInfo,
        mode: BufferMode,
        notes: MutableList<String>,
    ): AudioTrack? {
        val supported = try {
            am.getSupportedMixerAttributes(device)
        } catch (e: Exception) {
            notes.add("getSupportedMixerAttributes failed: $e")
            return null
        }
        if (supported.isEmpty()) {
            notes.add("device offers no mixer attributes")
            return null
        }
        for (m in supported) notes.add("offered: ${describe(m.format)} behavior=${m.mixerBehavior}")

        val multi = supported.filter { it.format.channelCount >= 4 }
        if (multi.isEmpty()) {
            notes.add("device offers no >=4ch mixer attribute")
            return null
        }
        val pick = multi.filter { isSupportedEncoding(it.format.encoding) }.maxByOrNull { score(it.format) }
        if (pick == null) {
            notes.add("4ch offered but encodings unsupported: ${multi.joinToString { encodingName(it.format.encoding) }}")
            return null
        }

        val attrs = mediaAttributes()
        val applied = try {
            am.setPreferredMixerAttributes(attrs, device, pick)
        } catch (e: Exception) {
            notes.add("setPreferredMixerAttributes threw: $e")
            false
        }
        if (!applied) {
            notes.add("setPreferredMixerAttributes rejected")
            return null
        }
        preferredDevice = device
        preferredAttributes = attrs

        notes.add("forced USB mixer to ${describe(pick.format)}")

        // A track in exactly the mixer format can be matched to a DIRECT output profile
        // instead of the reconfigured mixer. On Samsung/QTI that direct_pcm output dies on
        // start (status -32), so ask for float + channel index mask first: that only fits
        // the mixer thread, which converts to the USB format itself.
        val ch = pick.format.channelCount
        val candidates = listOf(
            AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                .setSampleRate(if (pick.format.sampleRate > 0) pick.format.sampleRate else SAMPLE_RATE)
                .setChannelIndexMask((1 shl ch) - 1)
                .build(),
            pick.format,
        )
        for (format in candidates) {
            val t = build(attrs, format, device, mode) ?: continue
            if (t.channelCount >= 4 && startAndVerify(t)) {
                notes.add("mixer track: ${describe(format)}")
                return t
            }
            notes.add("mixer track did not start: ${describe(format)}")
            t.release()
        }
        clearPreferred()
        return null
    }

    /**
     * Fallback when the mixer cannot be reconfigured. Devices that report no channel
     * index masks (the EP-136 is one) only accept a channel position mask, where QUAD
     * lays out as front L/R then back L/R, i.e. USB 1-2 then USB 3-4.
     */
    private fun openViaDirectTrack(
        device: AudioDeviceInfo?,
        channels: Int,
        mode: BufferMode,
        notes: MutableList<String>,
    ): AudioTrack? {
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val encodings = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                add(AudioFormat.ENCODING_PCM_32BIT)
            }
            add(AudioFormat.ENCODING_PCM_FLOAT)
            add(AudioFormat.ENCODING_PCM_16BIT)
        }
        val hasIndexMasks = device?.channelIndexMasks?.isNotEmpty() == true
        val counts = linkedSetOf(if (channels >= 8) 8 else 4, 4, 8)

        val candidates = ArrayList<AudioFormat>()
        fun addPositionQuad() {
            for (e in encodings) {
                candidates.add(
                    AudioFormat.Builder()
                        .setEncoding(e)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_QUAD)
                        .build(),
                )
            }
        }
        fun addIndexMasks() {
            for (ch in counts) {
                for (e in encodings) {
                    candidates.add(
                        AudioFormat.Builder()
                            .setEncoding(e)
                            .setSampleRate(SAMPLE_RATE)
                            .setChannelIndexMask((1 shl ch) - 1)
                            .build(),
                    )
                }
            }
        }
        if (hasIndexMasks) {
            addIndexMasks()
            addPositionQuad()
        } else {
            notes.add("device reports no channel index masks; using position masks")
            addPositionQuad()
            addIndexMasks()
        }

        for (format in candidates) {
            val t = build(attrs, format, device, mode)
            if (t != null && t.channelCount >= 4) {
                if (startAndVerify(t)) {
                    notes.add("direct track: ${describe(format)}")
                    return t
                }
                notes.add("direct track did not start: ${describe(format)}")
            }
            t?.release()
        }
        notes.add("no 4ch track configuration was accepted")
        return null
    }

    private fun build(
        attrs: AudioAttributes,
        format: AudioFormat,
        device: AudioDeviceInfo?,
        mode: BufferMode,
    ): AudioTrack? {
        val rate = if (format.sampleRate > 0) format.sampleRate else SAMPLE_RATE
        val bytesPerFrame = format.channelCount * bytesPerSample(format.encoding)
        // SAFE keeps the original sizing. Low modes get room to grow (4x the target);
        // the effective size is set after start with setBufferSizeInFrames.
        val bufBytes = if (mode.lowLatency) {
            bytesPerFrame * max(mode.targetMs * rate / 1000 * 4, FRAMES * 4)
        } else {
            max(bytesPerFrame * (rate / 20), bytesPerFrame * FRAMES * 4)
        }
        return try {
            val builder = AudioTrack.Builder()
                .setAudioAttributes(attrs)
                .setAudioFormat(format)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(bufBytes)
            if (Build.VERSION.SDK_INT >= 26) {
                builder.setPerformanceMode(
                    if (mode.lowLatency) AudioTrack.PERFORMANCE_MODE_LOW_LATENCY else AudioTrack.PERFORMANCE_MODE_NONE,
                )
            }
            val t = builder.build()
            if (t.state != AudioTrack.STATE_INITIALIZED) {
                t.release()
                return null
            }
            if (device != null) t.preferredDevice = device
            t
        } catch (e: Exception) {
            Log.e("sidedeck", "track build ${describe(format)} (${mode.key}): $e")
            null
        }
    }

    /**
     * AudioTrack.play() swallows native start failures (logcat shows "start(): status -32"
     * while playState still says PLAYING), so only trust a track whose head actually moves.
     */
    private fun startAndVerify(t: AudioTrack): Boolean {
        val bytesPerFrame = t.channelCount * bytesPerSample(t.audioFormat)
        val silence = ByteBuffer.allocateDirect(bytesPerFrame * FRAMES).order(ByteOrder.nativeOrder())
        verifyFrames = 0L
        return try {
            t.play()
            val deadline = System.nanoTime() + VERIFY_TIMEOUT_NS
            while (System.nanoTime() < deadline) {
                silence.position(0)
                val bytes = t.write(silence, silence.capacity(), AudioTrack.WRITE_NON_BLOCKING)
                if (bytes < 0) return false
                verifyFrames += (bytes / bytesPerFrame).toLong()
                if (t.playbackHeadPosition > 0) return true
                Thread.sleep(10)
            }
            Log.w("sidedeck", "usb track never advanced after play()")
            false
        } catch (e: Exception) {
            Log.w("sidedeck", "usb track start: $e")
            false
        }
    }

    private fun loop(handle: Long, channels: Int, encoding: Int, frames: Int) {
        val t = track ?: return
        val samples = frames * channels
        // The engine always renders float; convert in place where the device wants integers.
        val buffer = ByteBuffer.allocateDirect(samples * 4).order(ByteOrder.nativeOrder())
        val floats = buffer.asFloatBuffer()
        val ints = buffer.asIntBuffer()
        val shorts = if (encoding == AudioFormat.ENCODING_PCM_16BIT) ShortArray(samples) else null
        var stalls = 0
        while (running) {
            usbRender(handle, buffer, frames, channels)
            when (encoding) {
                AudioFormat.ENCODING_PCM_32BIT -> {
                    for (i in 0 until samples) {
                        val v = floats.get(i).coerceIn(-1f, 1f).toDouble()
                        ints.put(i, (v * 2147483647.0).toInt())
                    }
                }
                AudioFormat.ENCODING_PCM_16BIT -> {
                    val s = shorts!!
                    for (i in 0 until samples) {
                        s[i] = (floats.get(i) * 32767f).toInt().coerceIn(-32767, 32767).toShort()
                    }
                }
            }
            // Never render the next block until this one is consumed: a write that returns 0
            // (dead or unstarted track) must not let the decks run ahead at CPU speed.
            var done = 0
            while (running && done < samples) {
                val written = if (shorts != null) {
                    t.write(shorts, done, samples - done, AudioTrack.WRITE_BLOCKING)
                } else {
                    buffer.position(done * 4)
                    val bytes = t.write(buffer, (samples - done) * 4, AudioTrack.WRITE_BLOCKING)
                    if (bytes < 0) bytes else bytes / 4
                }
                if (written < 0) {
                    Log.e("sidedeck", "usb write error $written")
                    signalUnexpectedStop()
                    return
                }
                if (written == 0) {
                    if (++stalls >= MAX_STALLS) {
                        Log.e("sidedeck", "usb track stopped consuming audio; giving up")
                        signalUnexpectedStop()
                        return
                    }
                    Thread.sleep(STALL_SLEEP_MS)
                } else {
                    stalls = 0
                    done += written
                    samplesWritten += written
                }
            }
        }
    }

    private fun isSupportedEncoding(encoding: Int) =
        encoding == AudioFormat.ENCODING_PCM_FLOAT ||
            encoding == AudioFormat.ENCODING_PCM_32BIT ||
            encoding == AudioFormat.ENCODING_PCM_16BIT

    private fun bytesPerSample(encoding: Int) =
        if (encoding == AudioFormat.ENCODING_PCM_16BIT) 2 else 4

    private fun encodingName(encoding: Int) = when (encoding) {
        AudioFormat.ENCODING_PCM_16BIT -> "pcm16"
        AudioFormat.ENCODING_PCM_FLOAT -> "float"
        AudioFormat.ENCODING_PCM_24BIT_PACKED -> "pcm24packed"
        AudioFormat.ENCODING_PCM_32BIT -> "pcm32"
        else -> "enc$encoding"
    }

    private fun score(format: AudioFormat): Int {
        var s = format.channelCount * 1000
        if (format.sampleRate == SAMPLE_RATE) s += 100
        s += when (format.encoding) {
            AudioFormat.ENCODING_PCM_FLOAT -> 30
            AudioFormat.ENCODING_PCM_32BIT -> 20
            else -> 10
        }
        return s
    }

    private fun describe(format: AudioFormat): String {
        val index = if (Build.VERSION.SDK_INT >= 23) format.channelIndexMask else 0
        return "${format.channelCount}ch ${encodingName(format.encoding)} sr=${format.sampleRate} " +
            "mask=0x${Integer.toHexString(format.channelMask)} idx=0x${Integer.toHexString(index)}"
    }
}
