import Toybox.Attention;
import Toybox.Lang;

enum Buzz {
    BUZZ_LISTEN,
    BUZZ_SENT,
    BUZZ_REPLY,
    BUZZ_WARNING,
    BUZZ_ERROR
}

//! Vibration cues: one short when the microphone opens, two when the command is sent, one when the
//! reply is ready (the wrist can go down), one before closing on idle, one long on an error.
//! Which cues the setting allows the conversation decides; this only vibrates.
module Haptics {

    function vibrate(kind as Buzz) as Void {
        if (!Capabilities.hasVibration()) {
            return;
        }
        var pattern = [];
        if (kind == BUZZ_LISTEN) {
            pattern = [new Attention.VibeProfile(60, 80)];
        } else if (kind == BUZZ_SENT) {
            pattern = [new Attention.VibeProfile(50, 60), new Attention.VibeProfile(0, 80),
                new Attention.VibeProfile(50, 60)];
        } else if (kind == BUZZ_REPLY || kind == BUZZ_WARNING) {
            pattern = [new Attention.VibeProfile(50, 120)];
        } else {
            pattern = [new Attention.VibeProfile(80, 400)];
        }
        Attention.vibrate(pattern);
    }
}
