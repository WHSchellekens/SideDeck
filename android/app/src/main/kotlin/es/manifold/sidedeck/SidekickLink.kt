package es.manifold.sidedeck

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.MediaRecorder
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Read-only links back from an external mixer such as the EP-136 K.O. Sidekick:
 *
 *  - MIDI in: the Sidekick sends CC 7 per fader and CC 3 per cue button on MIDI
 *    channels 1-2, and the force pad / mod stick on channel 3 (guide, 8.1). Every
 *    CC, pitch bend and note goes to Flutter on the "sidedeck/midi" event channel.
 *  - Audio in: its USB inputs 7-8 mirror the master output. All inputs are captured
 *    and handed to the engine with their capture time, which compares the master
 *    with what each deck sent (on-air detection, latency). Nothing is stored.
 */
object SidekickLink : EventChannel.StreamHandler {
    init {
        System.loadLibrary("dj_engine")
    }

    @JvmStatic
    external fun usbCapture(handle: Long, buffer: ByteBuffer, frames: Int, channels: Int, endTimeNs: Long)

    private const val SAMPLE_RATE = 48000
    private const val BLOCK = 480 // 10 ms

    private val main = Handler(Looper.getMainLooper())
    private var appContext: Context? = null
    @Volatile
    private var sink: EventChannel.EventSink? = null

    private var midiManager: MidiManager? = null
    private var midiDevice: MidiDevice? = null
    private var midiPort: MidiOutputPort? = null
    private var midiDeviceId = -1
    private var midiCallbackRegistered = false

    @Volatile
    private var capturing = false
    private var captureThread: Thread? = null
    private var record: AudioRecord? = null

    fun attach(context: Context) {
        appContext = context.applicationContext
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        startMidi()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        stopMidi()
    }

    fun shutdown() {
        stopCapture()
        stopMidi()
        sink = null
    }

    private fun emit(payload: Map<String, Any>) {
        main.post { sink?.success(payload) }
    }

    // ---------------------------------------------------------------- MIDI

    private val deviceCallback = object : MidiManager.DeviceCallback() {
        override fun onDeviceAdded(device: MidiDeviceInfo) {
            if (midiDevice == null && midiDeviceId < 0 && isCandidate(device)) open(device)
        }

        override fun onDeviceRemoved(device: MidiDeviceInfo) {
            if (device.id == midiDeviceId) {
                closeMidi()
                emit(mapOf("kind" to "device", "name" to ""))
            }
        }
    }

    @Suppress("DEPRECATION") // getDevices / registerDeviceCallback(handler): API 33 adds transport variants
    private fun startMidi() {
        val ctx = appContext ?: return
        if (!ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_MIDI)) return
        val mm = ctx.getSystemService(Context.MIDI_SERVICE) as? MidiManager ?: return
        midiManager = mm
        if (!midiCallbackRegistered) {
            mm.registerDeviceCallback(deviceCallback, main)
            midiCallbackRegistered = true
        }
        if (midiDevice != null || midiDeviceId >= 0) return
        val pick = mm.devices.filter { isCandidate(it) }.maxByOrNull { score(it) } ?: return
        open(pick)
    }

    private fun isCandidate(info: MidiDeviceInfo) =
        info.type == MidiDeviceInfo.TYPE_USB && info.outputPortCount > 0

    private fun nameOf(info: MidiDeviceInfo): String {
        val p = info.properties
        return p.getString(MidiDeviceInfo.PROPERTY_PRODUCT)
            ?: p.getString(MidiDeviceInfo.PROPERTY_NAME)
            ?: "USB MIDI"
    }

    private fun score(info: MidiDeviceInfo): Int {
        val n = nameOf(info).lowercase()
        return if ("ep-136" in n || "ep136" in n || "sidekick" in n || "k.o" in n) 2 else 1
    }

    private fun open(info: MidiDeviceInfo) {
        val mm = midiManager ?: return
        midiDeviceId = info.id
        mm.openDevice(info, object : MidiManager.OnDeviceOpenedListener {
            override fun onDeviceOpened(device: MidiDevice?) {
                if (device == null) {
                    midiDeviceId = -1
                    return
                }
                val port = device.openOutputPort(0)
                if (port == null) {
                    try {
                        device.close()
                    } catch (_: Exception) {
                    }
                    midiDeviceId = -1
                    return
                }
                port.connect(receiver)
                midiDevice = device
                midiPort = port
                Log.i("sidedeck", "midi in: ${nameOf(info)}")
                emit(mapOf("kind" to "device", "name" to nameOf(info)))
            }
        }, main)
    }

    private fun closeMidi() {
        try {
            midiPort?.disconnect(receiver)
        } catch (_: Exception) {
        }
        try {
            midiPort?.close()
        } catch (_: Exception) {
        }
        try {
            midiDevice?.close()
        } catch (_: Exception) {
        }
        midiPort = null
        midiDevice = null
        midiDeviceId = -1
    }

    private fun stopMidi() {
        closeMidi()
        val mm = midiManager
        if (mm != null && midiCallbackRegistered) {
            mm.unregisterDeviceCallback(deviceCallback)
            midiCallbackRegistered = false
        }
    }

    /** Byte-stream parser with running status; realtime and system messages are skipped. */
    private val receiver = object : MidiReceiver() {
        private var status = 0
        private val data = IntArray(2)
        private var have = 0

        override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
            for (i in offset until offset + count) {
                val b = msg[i].toInt() and 0xFF
                if (b >= 0xF8) continue
                if (b >= 0x80) {
                    status = if (b >= 0xF0) 0 else b
                    have = 0
                    continue
                }
                if (status == 0) continue
                data[have++] = b
                val needed = when (status and 0xF0) {
                    0xC0, 0xD0 -> 1
                    else -> 2
                }
                if (have < needed) continue
                have = 0
                dispatch(status, data[0], if (needed > 1) data[1] else 0)
            }
        }
    }

    private fun dispatch(status: Int, d1: Int, d2: Int) {
        val ch = status and 0x0F
        val kind = when (status and 0xF0) {
            0xB0 -> "cc"
            0xE0 -> "bend"
            0x90 -> if (d2 > 0) "noteOn" else "noteOff"
            0x80 -> "noteOff"
            0xC0 -> "program"
            else -> return
        }
        val value = if (kind == "bend") ((d2 shl 7) or d1) - 8192 else d2
        val number = if (kind == "bend") 0 else d1
        emit(mapOf("kind" to kind, "channel" to ch, "number" to number, "value" to value))
    }

    // --------------------------------------------------------------- Audio

    @Synchronized
    fun startCapture(context: Context, handle: Long): Map<String, Any> {
        stopCapture()
        if (handle == 0L) return captureFailure("Engine not ready")
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val device = am.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .filter { isUsbInput(it) }
            .maxByOrNull { it.channelCounts.maxOrNull() ?: 0 }
            ?: return captureFailure("No USB audio input found")
        // All 8 inputs first: 7-8 carry the master. Two is still useful for the meters.
        for (channels in intArrayOf(8, 2)) {
            val rec = buildRecord(device, channels) ?: continue
            try {
                rec.startRecording()
            } catch (e: Exception) {
                Log.w("sidedeck", "capture start ${channels}ch: $e")
                rec.release()
                continue
            }
            if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                rec.release()
                continue
            }
            val ch = rec.channelCount
            record = rec
            capturing = true
            captureThread = Thread({ captureLoop(handle, rec, ch) }, "sidedeck-capture").apply {
                priority = Thread.MAX_PRIORITY
                start()
            }
            val name = device.productName?.toString() ?: ""
            Log.i("sidedeck", "capture: ${ch}ch float @${rec.sampleRate}Hz from $name")
            return mapOf("ok" to true, "channels" to ch, "device" to name, "error" to "")
        }
        return captureFailure("Android would not record from the USB input")
    }

    @Synchronized
    fun stopCapture() {
        capturing = false
        val rec = record
        record = null
        try {
            rec?.stop()
        } catch (_: Exception) {
        }
        captureThread?.join(500)
        captureThread = null
        rec?.release()
    }

    private fun captureFailure(message: String): Map<String, Any> {
        Log.w("sidedeck", "capture: $message")
        return mapOf("ok" to false, "channels" to 0, "device" to "", "error" to message)
    }

    private fun isUsbInput(d: AudioDeviceInfo) =
        d.isSource && (d.type == AudioDeviceInfo.TYPE_USB_DEVICE || d.type == AudioDeviceInfo.TYPE_USB_HEADSET)

    // Flutter asks for RECORD_AUDIO before it starts listening.
    @SuppressLint("MissingPermission")
    private fun buildRecord(device: AudioDeviceInfo, channels: Int): AudioRecord? {
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelIndexMask((1 shl channels) - 1)
            .build()
        val bytes = BLOCK * channels * 4 * 8
        // UNPROCESSED skips any voice processing; not every phone offers it.
        val sources = intArrayOf(
            MediaRecorder.AudioSource.UNPROCESSED,
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            MediaRecorder.AudioSource.MIC,
        )
        for (source in sources) {
            val rec = try {
                AudioRecord.Builder()
                    .setAudioSource(source)
                    .setAudioFormat(format)
                    .setBufferSizeInBytes(bytes)
                    .build()
            } catch (e: Exception) {
                null
            } ?: continue
            if (rec.state != AudioRecord.STATE_INITIALIZED || rec.channelCount < channels) {
                rec.release()
                continue
            }
            rec.setPreferredDevice(device)
            return rec
        }
        return null
    }

    private fun captureLoop(handle: Long, rec: AudioRecord, channels: Int) {
        val bytesPerFrame = channels * 4
        val buffer = ByteBuffer.allocateDirect(BLOCK * bytesPerFrame).order(ByteOrder.nativeOrder())
        val ts = AudioTimestamp()
        val rate = rec.sampleRate.toLong()
        var framesRead = 0L
        while (capturing) {
            val bytes = rec.read(buffer, BLOCK * bytesPerFrame, AudioRecord.READ_BLOCKING)
            if (bytes < 0) {
                Log.w("sidedeck", "capture read error $bytes")
                break
            }
            val frames = bytes / bytesPerFrame
            if (frames == 0) continue
            framesRead += frames
            // When the block's last frame was captured, from the input timestamp if Android
            // has one; otherwise now (a little late by the input buffering).
            var endNs = System.nanoTime()
            if (rate > 0 && rec.getTimestamp(ts, AudioTimestamp.TIMEBASE_MONOTONIC) == AudioRecord.SUCCESS) {
                endNs = ts.nanoTime + (framesRead - 1 - ts.framePosition) * 1_000_000_000L / rate
            }
            usbCapture(handle, buffer, frames, channels, endNs)
        }
    }
}
