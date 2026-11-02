import Toybox.Lang;
import Toybox.WatchUi;

class AssistDelegate extends WatchUi.BehaviorDelegate {

    private var _session as Conversation;

    function initialize(session as Conversation) {
        BehaviorDelegate.initialize();
        _session = session;
    }

    //! START (or a tap): send the command, interrupt the reply, or the next command
    function onSelect() as Boolean {
        _session.onSelect();
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

    function onNextPage() as Boolean {
        _session.onScroll(1);
        return true;
    }

    function onPreviousPage() as Boolean {
        _session.onScroll(-1);
        return true;
    }
}
