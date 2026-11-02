import Toybox.Attention;
import Toybox.Audio;
import Toybox.Lang;
import Toybox.System;

//! What this watch can do - the only place that checks the model or `has`. The logic and the UI
//! ask here.
module Capabilities {

    function hasSpeaker() as Boolean {
        return Toybox has :Audio && Audio has :Output;
    }

    function hasVibration() as Boolean {
        return Attention has :vibrate;
    }

    //! Touch can be switched off on the watch, so this is asked while running
    function hasTouch() as Boolean {
        return System.getDeviceSettings().isTouchScreen;
    }

    function hasNoiseFilter() as Boolean {
        return Audio.Capture.getSupportedFilters().indexOf(Audio.Capture.FILTER_NREC) >= 0;
    }
}
