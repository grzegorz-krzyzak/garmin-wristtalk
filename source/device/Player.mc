import Toybox.Audio;
import Toybox.Lang;

//! The speaker: plays the reply (Ogg/Opus 16 kHz mono) received at run time.
class Player {

    private var _onDone as Method() as Void or Null;
    private var _playing as Boolean = false;

    function initialize() {
    }

    //! Returns false when the audio cannot be played (the reply text stays on screen)
    function play(data as ByteArray, volume as Number, onDone as Method() as Void) as Boolean {
        if (!Capabilities.hasSpeaker()) {
            return false;
        }
        try {
            var builder = new Audio.Output.DynamicAudioSourceBuilder({
                :format => {
                    :containerFormat => Audio.CONTAINER_OGG,
                    :codec => Audio.CODEC_OPUS,
                    :frequency => Audio.FREQ_16_KHZ,
                    :channels => Audio.CHANNEL_MONO
                }
            });
            builder.append(data);
            _onDone = onDone;
            Audio.Output.registerStateChangeHandler(method(:onState));
            Audio.Output.setVolume(volume);
            Audio.Output.play(builder.complete(), 0);
            _playing = true;
        } catch (e) {
            return false;
        }
        return true;
    }

    function stop() as Void {
        if (_playing) {
            _playing = false;
            Audio.Output.stop();
        }
    }

    function onState(state as Audio.Output.PlaybackState) as Void {
        if (_playing && (state == Audio.Output.PLAYBACK_STOPPED || state == Audio.Output.PLAYBACK_ERROR)) {
            _playing = false;
            if (_onDone != null) {
                _onDone.invoke();
            }
        }
    }
}
