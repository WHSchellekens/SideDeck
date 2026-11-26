package es.manifold.sidedeck

import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import kotlin.math.max

object UsbDevices {
    const val MIN_MIXER_CHANNELS = 4

    private fun isUsbType(type: Int) =
        type == AudioDeviceInfo.TYPE_USB_DEVICE ||
            type == AudioDeviceInfo.TYPE_USB_HEADSET ||
            type == AudioDeviceInfo.TYPE_USB_ACCESSORY

    fun isUsbOutput(d: AudioDeviceInfo) = d.isSink && isUsbType(d.type)

    /**
     * Android keeps a media volume per output device. In external mixer mode media
     * goes to the USB mixer, and at 0 the mixer gets silence from every app (SideDeck
     * included) while the phone's own volume looks fine. "usb" is false when Android
     * says media goes elsewhere (API 33+; older phones assume the USB mixer).
     */
    fun mediaVolume(am: AudioManager): Map<String, Any> {
        var usb = true
        if (Build.VERSION.SDK_INT >= 33) {
            try {
                val attrs = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build()
                usb = am.getAudioDevicesForAttributes(attrs).any { isUsbType(it.type) }
            } catch (_: Exception) {
            }
        }
        return mapOf(
            "volume" to am.getStreamVolume(AudioManager.STREAM_MUSIC),
            "max" to am.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
            "fixed" to am.isVolumeFixed,
            "usb" to usb,
        )
    }

    /** Media volume to max, with Android's volume slider shown so the change is visible. */
    fun raiseMediaVolume(am: AudioManager) {
        try {
            am.setStreamVolume(
                AudioManager.STREAM_MUSIC,
                am.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
                AudioManager.FLAG_SHOW_UI,
            )
        } catch (_: Exception) {
        }
    }

    /**
     * [AudioDeviceInfo.getChannelCounts] already includes position and index
     * masks. An empty list means arbitrary counts, not "unknown" — treated as 0
     * here so we only offer devices that actually advertise 4+ channels.
     * On API 34+, mixer attributes are the configs the USB stream can open.
     */
    fun maxChannels(am: AudioManager, d: AudioDeviceInfo): Int {
        var n = d.channelCounts.maxOrNull() ?: 0
        if (Build.VERSION.SDK_INT >= 34) {
            try {
                for (attr in am.getSupportedMixerAttributes(d)) {
                    n = max(n, attr.format.channelCount)
                }
            } catch (_: Exception) {
                // Some OEM USB stacks throw here; channelCounts still apply.
            }
        }
        return n
    }

    fun payload(d: AudioDeviceInfo, channels: Int, event: String): Map<String, Any> = mapOf(
        "event" to event,
        "id" to d.id,
        "channels" to channels,
        "name" to (d.productName?.toString() ?: ""),
    )

    fun findBest(am: AudioManager): Pair<AudioDeviceInfo, Int>? {
        var best: AudioDeviceInfo? = null
        var bestCh = 0
        for (d in am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            if (!isUsbOutput(d)) continue
            val ch = maxChannels(am, d)
            val preferDevice = d.type == AudioDeviceInfo.TYPE_USB_DEVICE &&
                best?.type != AudioDeviceInfo.TYPE_USB_DEVICE
            if (ch > bestCh || (ch == bestCh && preferDevice)) {
                best = d
                bestCh = ch
            }
        }
        return best?.let { it to bestCh }
    }
}
