import Toybox.Lang;
import Toybox.Test;

// What the screen shows of a state: waiting looks only after SHOW_MS, then at least MIN_MS. The
// times are given, so nothing waits.

(:test)
function aShortWaitingStateShowsNoLook(logger as Test.Logger) as Boolean {
    var s = new ShownState();
    var show = s.SHOW_MS;
    s.change(STATE_SENDING, SHOW_WAITING, 0);
    s.update(show - 1);
    // Its content (the command's text) without "Thinking"
    Test.assertEqual(s.state, STATE_SENDING);
    Test.assert(!s.revealed);
    // The reply comes before SHOW_MS: at once, nothing held
    s.change(STATE_IDLE, SHOW_AFTER_HOLD, show - 1);
    Test.assertEqual(s.state, STATE_IDLE);
    Test.assert(s.settled());
    return true;
}

(:test)
function aShownWaitingLookStaysItsMinimum(logger as Test.Logger) as Boolean {
    var s = new ShownState();
    var show = s.SHOW_MS;
    var min = s.MIN_MS;
    s.change(STATE_SENDING, SHOW_WAITING, 0);
    Test.assert(s.update(show));
    Test.assert(s.revealed);
    // The reply right after: "Thinking" stays until its minimum is over
    s.change(STATE_IDLE, SHOW_AFTER_HOLD, show + 1);
    Test.assertEqual(s.state, STATE_SENDING);
    Test.assertEqual(s.holdLeft(show + 1), min - 1);
    Test.assert(!s.update(show + min - 1));
    Test.assert(s.update(show + min));
    Test.assertEqual(s.state, STATE_IDLE);
    return true;
}

(:test)
function whatTheUserDidShowsAtOnce(logger as Test.Logger) as Boolean {
    var s = new ShownState();
    s.change(STATE_SENDING, SHOW_WAITING, 0);
    s.update(s.SHOW_MS);
    // BACK or START during "Thinking": no minimum
    s.change(STATE_LISTENING, SHOW_NOW, s.SHOW_MS + 1);
    Test.assertEqual(s.state, STATE_LISTENING);
    Test.assert(s.settled());
    return true;
}

(:test)
function recognisingAfterStartHoldsAndThinkingFollows(logger as Test.Logger) as Boolean {
    var s = new ShownState();
    var min = s.MIN_MS;
    // START: "Recognising" at once, and it is a waiting look - it stays its minimum
    s.change(STATE_RECOGNIZING, SHOW_NOW, 0);
    Test.assert(s.revealed);
    s.change(STATE_SENDING, SHOW_WAITING, 100);
    Test.assertEqual(s.state, STATE_RECOGNIZING);
    // When the minimum is over, "Thinking" has waited long enough itself only if SHOW_MS has passed
    s.update(min);
    Test.assertEqual(s.state, STATE_SENDING);
    Test.assertEqual(s.revealed, min - 100 >= s.SHOW_MS);
    return true;
}
