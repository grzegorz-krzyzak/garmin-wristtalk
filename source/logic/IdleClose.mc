import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! Closing on idle: quiet for the set time minus the countdown, then "Closing in 10..1" - START
//! (or UP/DOWN) keeps the app open, BACK closes it at once. After giving up on errors the app
//! closes without the countdown (the error says so).
class IdleClose {

    const COUNTDOWN_MS = 10000;          // the warning, or a third of a short idle time

    //! Seconds left; 0 = no countdown on screen
    var countdown as Number = 0;

    private var _timer as Timer.Timer = new Timer.Timer();
    private var _warnMs as Number = 0;
    private var _onWarning as Method() as Void;

    //! onWarning: the countdown starts (the conversation clears a popup and vibrates)
    function initialize(onWarning as Method() as Void) {
        _onWarning = onWarning;
    }

    function arm(ms as Number) as Void {
        _timer.stop();
        countdown = 0;
        _warnMs = ms >= 2 * COUNTDOWN_MS ? COUNTDOWN_MS : ms / 3;
        _timer.start(method(:onWarning), ms - _warnMs, false);
    }

    function closeAfter(ms as Number) as Void {
        _timer.stop();
        countdown = 0;
        _timer.start(method(:exit), ms, false);
    }

    function stop() as Void {
        _timer.stop();
        countdown = 0;
    }

    function onWarning() as Void {
        countdown = _warnMs / 1000;
        _onWarning.invoke();
        _timer.start(method(:onCountdown), 1000, true);
        WatchUi.requestUpdate();
    }

    function onCountdown() as Void {
        countdown--;
        if (countdown <= 0) {
            exit();
        }
        WatchUi.requestUpdate();
    }

    function exit() as Void {
        System.exit();
    }
}
