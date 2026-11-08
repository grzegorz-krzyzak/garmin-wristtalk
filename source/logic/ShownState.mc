import Toybox.Lang;

enum ShowKind {
    SHOW_NOW,           // what the user did (START, BACK, the menu), pairing: on screen at once
    SHOW_WAITING,       // a waiting state: its look only once it has lasted SHOW_MS
    SHOW_AFTER_HOLD     // the next screen (a text, the reply, an error): after a shown waiting look's MIN_MS
}

//! What the screen shows of the conversation's state, so that nothing flashes by: a waiting state
//! ("Connecting", "Recognising" after Home Assistant's signal, "Thinking", "Loading voice") shows
//! its look only once it has lasted SHOW_MS, and once shown it stays MIN_MS - the next screen waits
//! for that, the logic does not. The state itself changes at once; only the screen follows.
class ShownState {

    // 700 ms from the measured end of the VAD to the text (39-1257 ms, median 562
    // in 9 commands: "Recognising" shows only where the wait is noticeable); 500 ms is enough to
    // read one word (an eye fixation is about 200-250 ms) and one pulse of the dots
    const SHOW_MS = 700;
    const MIN_MS = 500;

    //! On screen: the state, and whether a waiting state's own look (status, dots) shows yet -
    //! before that the screen shows the state's content without it
    var state as State = STATE_IDLE;
    var revealed as Boolean = true;

    private var _target as State = STATE_IDLE;
    private var _kind as ShowKind = SHOW_NOW;
    private var _since as Number = 0;
    private var _shownAt as Number = -1;  // when a waiting look went on screen; -1 none

    function initialize() {
    }

    function change(target as State, kind as ShowKind, now as Number) as Void {
        _target = target;
        _kind = kind;
        _since = now;
        if (kind == SHOW_NOW) {
            state = target;
            revealed = true;
            _shownAt = isWaiting(target) ? now : -1;
            return;
        }
        update(now);
    }

    //! True when the screen changed
    function update(now as Number) as Boolean {
        if (settled()) {
            return false;
        }
        if (holdLeft(now) > 0) {
            return false;  // the waiting look on screen stays
        }
        if (_kind == SHOW_WAITING && now - _since < SHOW_MS) {
            if (state == _target && !revealed) {
                return false;
            }
            state = _target;
            revealed = false;
            _shownAt = -1;
            return true;
        }
        state = _target;
        revealed = true;
        _shownAt = isWaiting(_target) ? now : -1;
        return true;
    }

    //! The screen shows what the state asks for - nothing left to wait for
    function settled() as Boolean {
        return state == _target && revealed;
    }

    //! How long the waiting look on screen still has to stay (ms)
    function holdLeft(now as Number) as Number {
        if (_shownAt < 0) {
            return 0;
        }
        var left = MIN_MS - (now - _shownAt);
        return left > 0 ? left : 0;
    }

    static function isWaiting(s as State) as Boolean {
        return s == STATE_CONNECTING || s == STATE_RECOGNIZING || s == STATE_SENDING || s == STATE_LOADING_VOICE;
    }
}
