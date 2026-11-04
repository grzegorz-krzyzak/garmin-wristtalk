import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

//! Where the conversation is scrolled to, in pixels from the latest command (positive = back to
//! earlier messages). A drag moves it with the finger and it glides on after the finger lets go,
//! slowing down, as the system lists do; UP / DOWN move a line. Presentation only - the logic
//! does not know the screen scrolls.
class Scroller {

    const HALF_LIFE_MS = 250.0;          // the glide loses half its speed every 250 ms
    const STOP_PX_S = 40;

    var scroll as Number = 0;
    var lineHeight as Number = 24;       // the view sets it from the font

    private var _speed as Float = 0.0;   // px/s
    private var _at as Number = 0;

    function lines(count as Number) as Void {
        _speed = 0.0;
        scroll = scroll - count * lineHeight;
        WatchUi.requestUpdate();
    }

    function drag(dy as Number) as Void {
        _speed = 0.0;
        scroll = scroll + dy;
        WatchUi.requestUpdate();
    }

    function glide(pxPerSecond as Float) as Void {
        _speed = pxPerSecond;
        _at = System.getTimer();
        WatchUi.requestUpdate();
    }

    function stop() as Void {
        _speed = 0.0;
    }

    //! Back to the latest command (a new command)
    function reset() as Void {
        _speed = 0.0;
        scroll = 0;
    }

    //! One frame of the glide; true while it moves
    function advance(now as Number) as Boolean {
        if (_speed == 0.0) {
            return false;
        }
        var dt = now - _at;
        _at = now;
        scroll = scroll + (_speed * dt / 1000).toNumber();
        _speed = _speed * Math.pow(0.5, dt / HALF_LIFE_MS).toFloat();
        if (_speed.abs() < STOP_PX_S) {
            _speed = 0.0;
            return false;
        }
        return true;
    }

    //! The value the conversation allows; reaching its end stops the glide
    function limitTo(allowed as Number) as Void {
        if (allowed != scroll) {
            _speed = 0.0;
            scroll = allowed;
        }
    }

    function gliding() as Boolean {
        return _speed != 0.0;
    }
}
