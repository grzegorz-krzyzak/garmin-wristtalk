import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class AssistDelegate extends WatchUi.BehaviorDelegate {

    private var _session as Conversation;
    private var _scroller as Scroller;

    function initialize(session as Conversation, scroller as Scroller) {
        BehaviorDelegate.initialize();
        _session = session;
        _scroller = scroller;
    }

    // A physical button was pressed just now: a "select" right after it is START, a "select" without
    // it is a tap on the screen (the fēnix 8 turns both into the same select, measured 2026-11-04;
    // onKey never gets START - key 4, KEY_ENTER - only onKeyPressed does)
    private var _keyAt as Number = -10000;
    const SWIPE_LINES = 4;

    function onKeyPressed(keyEvent as WatchUi.KeyEvent) as Boolean {
        _keyAt = System.getTimer();
        return false;
    }

    private function fromButton() as Boolean {
        return System.getTimer() - _keyAt < 1500;
    }

    //! START, or a tap: only START starts a command - touching the dimmed screen to wake it does
    //! nothing
    function onSelect() as Boolean {
        if (fromButton()) {
            _session.onSelect();
        }
        return true;
    }

    //! BACK cancels the current step; on the idle screen the default closes the app
    function onBack() as Boolean {
        return _session.onBack();
    }

    //! Hold UP: switch "text only" on/off at once - no menu
    function onMenu() as Boolean {
        _session.toggleTextOnly();
        return true;
    }

    // A drag: the conversation follows the finger and glides after it (as the system lists do)
    private var _dragY as Number = 0;
    private var _dragAt as Number = 0;
    private var _dragV as Float = 0.0;
    private var _draggedAt as Number = -10000;

    function onDrag(dragEvent as WatchUi.DragEvent) as Boolean {
        var y = dragEvent.getCoordinates()[1];
        var now = System.getTimer();
        var type = dragEvent.getType();
        if (type == WatchUi.DRAG_TYPE_START) {
            _scroller.stop();
        } else if (type == WatchUi.DRAG_TYPE_CONTINUE) {
            var dy = y - _dragY;
            var dt = now - _dragAt;
            if (dt > 0) {
                _dragV = 0.6 * _dragV + 0.4 * (dy * 1000.0 / dt);
            }
            if (!_session.onScrollInput()) {
                _scroller.drag(dy);
            }
        } else {
            _scroller.glide(_dragV);
            _dragV = 0.0;
        }
        _dragY = y;
        _dragAt = now;
        _draggedAt = now;
        return true;
    }

    private function dragged() as Boolean {
        return System.getTimer() - _draggedAt < 600;
    }

    //! DOWN / UP scroll a line; a swipe (the same event, without a key pressed) half a screen -
    //! one line per swipe felt stiff on the fēnix 8
    function onNextPage() as Boolean {
        scrollLines(fromButton() ? 1 : SWIPE_LINES);
        return true;
    }

    function onPreviousPage() as Boolean {
        scrollLines(fromButton() ? -1 : -SWIPE_LINES);
        return true;
    }

    //! DOWN further into a long reply, UP back to earlier messages; a swipe right after a drag is
    //! the same finger - the drag has scrolled already
    private function scrollLines(count as Number) as Void {
        if (!dragged() && !_session.onScrollInput()) {
            _scroller.lines(count);
        }
    }
}
