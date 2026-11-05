import Toybox.Audio;
import Toybox.Lang;

//! The microphone: Ogg/Opus 16 kHz mono - the smallest upload; Home Assistant decodes it.
//! Recording works only while the app is in the foreground.
class Recorder {

    private var _onData as Method(data as ByteArray) as Void or Null;
    private var _onDone as Method(ok as Boolean) as Void or Null;

    function initialize() {
    }

    //! Returns false when the microphone cannot start
    function start(onData as Method(data as ByteArray) as Void, onDone as Method(ok as Boolean) as Void) as Boolean {
        _onData = onData;
        _onDone = onDone;
        try {
            var settings = {
                :format => {
                    :containerFormat => Audio.CONTAINER_OGG,
                    :codec => Audio.CODEC_OPUS,
                    :frequency => Audio.FREQ_16_KHZ,
                    :channels => Audio.CHANNEL_MONO
                },
                // The audio comes about once a second on the fēnix 8 whatever the window; 512 bytes only
                // doubled the requests, and the phone lost some (measured 2026-11-05)
                :windowSize => 1024,
                :windowFilledBehavior => Audio.Capture.WINDOW_FILLED_CONTINUE
            };
            if (Capabilities.hasNoiseFilter()) {
                settings[:filters] = [Audio.Capture.FILTER_NREC];
            }
            Audio.Capture.initializeAudioCapture(self, settings);
            Audio.Capture.start();
        } catch (e) {
            return false;
        }
        return true;
    }

    function stop() as Void {
        if (isRecording()) {
            // stop() hands over the rest to onData, then onComplete
            Audio.Capture.stop();
        }
    }

    function isRecording() as Boolean {
        return Audio.Capture.getState() == Audio.Capture.CAPTURE_CAPTURING;
    }

    // --- Audio.Capture.Callbacks ---

    function onData(audioData as ByteArray) as Void {
        if (_onData != null) {
            _onData.invoke(audioData);
        }
    }

    function onError(captureError as Audio.Capture.Error) as Void {
        if (_onDone != null) {
            _onDone.invoke(false);
        }
    }

    function onComplete() as Void {
        if (_onDone != null) {
            _onDone.invoke(true);
        }
    }
}
