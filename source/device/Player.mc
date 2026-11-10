import Toybox.Audio;
import Toybox.Lang;
import Toybox.System;

//! The speaker: plays the reply's voice (Ogg/Opus 16 kHz mono) while it is still coming - a
//! streaming source takes the bytes as it has room. Measured on the fēnix 8 (2026-11-10): an Ogg
//! cut anywhere plays; a source that runs dry stops for good without telling (no error, no state) -
//! `pause()` and `resume()` start it again from where it stopped; a new stream from a page works
//! too and repeats that page. Which to do and when the voice logic decides; this only plays.
class Player {

    const BUFFER = 8192;   // as tested on the watch
    // A stopped stream's "stopped" comes late - after the next one started (seen on the fēnix 8)
    const LATE_STOP_MS = 1500;

    private var _onDone as Method(ok as Boolean) as Void or Null;
    private var _source as VoiceSource?;
    private var _playing as Boolean = false;
    private var _restartedAt as Number = -LATE_STOP_MS;

    function initialize() {
    }

    //! Starts playing `data`; false when it cannot (the reply text stays). `whole`: that is all of
    //! it - played as one source, as 0.5.x did (a stream ended before it started playing stayed
    //! silent on the fēnix 8, 2026-11-10: a short reply fits the buffer whole); otherwise more comes
    //! with add, and finish() ends it. onDone(true): played to the end; onDone(false): the player failed
    function start(data as ByteArray, volume as Number, whole as Boolean,
            onDone as Method(ok as Boolean) as Void) as Boolean {
        if (!Capabilities.hasSpeaker()) {
            return false;
        }
        try {
            _onDone = onDone;
            Audio.Output.registerStateChangeHandler(method(:onState));
            Audio.Output.setVolume(volume);
            if (whole) {
                playWhole(data);
            } else {
                play(data, false);
            }
        } catch (e) {
            _playing = false;
            _source = null;
            return false;
        }
        return true;
    }

    //! More of the voice
    function add(data as ByteArray) as Void {
        if (_source != null) {
            (_source as VoiceSource).add(data);
        }
    }

    //! Nothing more comes: the source ends once the player has taken the rest
    function finish() as Void {
        if (_source != null) {
            (_source as VoiceSource).finish();
        }
    }

    //! Where the playing is in the current stream (ms)
    function position() as Number {
        return _playing ? Audio.Output.getPosition() : 0;
    }

    function pause() as Void {
        if (_playing) {
            Audio.Output.pause();
        }
    }

    function resume() as Void {
        if (_playing) {
            Audio.Output.resume();
        }
    }

    //! A new stream in place of the current one (`data` begins with the header pages)
    function restart(data as ByteArray) as Void {
        if (!_playing) {
            return;
        }
        var finished = _source != null && (_source as VoiceSource).finishing;
        _restartedAt = System.getTimer();
        Audio.Output.stop();
        play(data, finished);
    }

    function stop() as Void {
        _source = null;
        if (_playing) {
            _playing = false;
            Audio.Output.stop();
        }
    }

    private function playWhole(data as ByteArray) as Void {
        var builder = new Audio.Output.DynamicAudioSourceBuilder({
            :format => VoiceSource.FORMAT
        });
        builder.append(data);
        _source = null;
        _playing = true;
        Audio.Output.play(builder.complete(), 0);
    }

    private function play(data as ByteArray, finished as Boolean) as Void {
        var source = new VoiceSource(BUFFER, method(:onSourceError));
        source.add(data);
        if (finished) {
            source.finish();
        }
        _source = source;
        _playing = true;
        Audio.Output.play(source, 0);
    }

    function onSourceError() as Void {
        end(false);
    }

    function onState(state as Audio.Output.PlaybackState) as Void {
        if (state == Audio.Output.PLAYBACK_STOPPED && System.getTimer() - _restartedAt < LATE_STOP_MS) {
            return;  // the replaced stream's own end
        }
        if (state == Audio.Output.PLAYBACK_STOPPED || state == Audio.Output.PLAYBACK_ERROR) {
            end(state == Audio.Output.PLAYBACK_STOPPED);
        }
    }

    private function end(ok as Boolean) as Void {
        if (!_playing) {
            return;
        }
        _playing = false;
        _source = null;
        if (_onDone != null) {
            (_onDone as Method(ok as Boolean) as Void).invoke(ok);
        }
    }
}

//! The voice's bytes waiting for the player: handed over as it has room
class VoiceSource extends Audio.Output.StreamingAudioSource {

    static const FORMAT = {
        :containerFormat => Audio.CONTAINER_OGG,
        :codec => Audio.CODEC_OPUS,
        :frequency => Audio.FREQ_16_KHZ,
        :channels => Audio.CHANNEL_MONO
    } as Audio.AudioFormat;

    var finishing as Boolean = false;

    private var _waiting as ByteArray = []b;
    private var _taken as Number = 0;          // of _waiting, handed to the player already
    private var _ended as Boolean = false;
    private var _onError as Method() as Void;

    function initialize(buffer as Number, onError as Method() as Void) {
        StreamingAudioSource.initialize({ :format => FORMAT, :bufferSize => buffer });
        _onError = onError;
    }

    function add(data as ByteArray) as Void {
        if (_taken > 0) {
            _waiting = _waiting.slice(_taken, null);
            _taken = 0;
        }
        _waiting.addAll(data);
        hand(getBufferSize());
    }

    function finish() as Void {
        finishing = true;
        hand(getBufferSize());
    }

    function onReadyForData(freeSpace as Number) as Void {
        hand(freeSpace);
    }

    function onError(error as Audio.Output.Error) as Void {
        _onError.invoke();
    }

    //! As much as the player takes - only that much is copied, not the rest each time (a large
    //! piece is handed over in many calls while it plays); the end once everything is taken
    private function hand(room as Number) as Void {
        var left = _waiting.size() - _taken;
        if (left > 0 && room > 0) {
            var count = left < room ? left : room;
            _taken += append(_waiting.slice(_taken, _taken + count));
        }
        if (finishing && _taken >= _waiting.size() && !_ended) {
            _ended = true;
            end();
        }
    }
}
