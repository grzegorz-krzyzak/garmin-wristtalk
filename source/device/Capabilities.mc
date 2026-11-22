import Toybox.Attention;
import Toybox.Audio;
import Toybox.Graphics;
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

    //! Smooth edges for the arcs and round shapes where the watch can draw them (Connect IQ 3.2+);
    //! without it the MIP screen shows every stair step
    function smoothEdges(dc as Graphics.Dc) as Void {
        if (dc has :setAntiAlias) {
            dc.setAntiAlias(true);
        }
    }

    //! Watch faces can show WristTalk as a complication (Connect IQ 4.2)
    function canPublishComplication() as Boolean {
        return Toybox has :Complications;
    }

    function hasNoiseFilter() as Boolean {
        return Audio.Capture.getSupportedFilters().indexOf(Audio.Capture.FILTER_NREC) >= 0;
    }
}
