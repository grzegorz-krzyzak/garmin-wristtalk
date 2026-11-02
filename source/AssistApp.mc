import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

//! WristTalk: voice commands for Home Assistant. The watch records, the WristTalk integration runs
//! the Assist pipeline, the watch shows the command and the reply and plays it.
class AssistApp extends Application.AppBase {

    private var _conversation as Conversation?;

    function initialize() {
        AppBase.initialize();
    }

    // Foreground only - the glance never runs it
    (:typecheck([disableGlanceCheck]))
    function onStop(state as Dictionary?) as Void {
        if (_conversation != null) {
            _conversation.shutdown();
        }
    }

    // Foreground only - the glance never runs it
    (:typecheck([disableGlanceCheck]))
    function getInitialView() as [Views] or [Views, InputDelegates] {
        var probe = startView();
        if (probe != null) {
            return probe;
        }
        var conversation = new Conversation(new HaClient(Settings.APP_VERSION), new Recorder(), new Player());
        _conversation = conversation;
        return [new AssistView(conversation), new AssistDelegate(conversation)];
    }

    //! Garmin Connect sent new settings: "Reconnect", or a new house address
    // Foreground only - the glance never runs it
    (:typecheck([disableGlanceCheck]))
    function onSettingsChanged() as Void {
        if (_conversation != null) {
            _conversation.onSettingsChanged();
        }
    }

    (:glance)
    function getGlanceView() as [GlanceView] or [GlanceView, GlanceViewDelegate] or Null {
        return [new AssistGlance()];
    }
}
