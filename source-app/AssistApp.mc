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
        var conversation = new Conversation(new HaClient(Settings.APP_VERSION), new Recorder(), new Player());
        _conversation = conversation;
        publishComplication();
        var scroller = new Scroller();
        return [new AssistView(conversation, scroller), new AssistDelegate(conversation, scroller)];
    }

    //! The system took the app to the background or brought it back (the app switcher, the watch
    //! face) - API 4.2; the view's hide / show covers the same without it
    (:typecheck([disableGlanceCheck]))
    function onInactive(state as Dictionary?) as Void {
        if (_conversation != null) {
            _conversation.onBackground();
        }
    }

    (:typecheck([disableGlanceCheck]))
    function onActive(state as Dictionary?) as Void {
        if (_conversation != null) {
            _conversation.onForeground();
        }
    }

    //! Garmin Connect sent new settings: a new house address
    // Foreground only - the glance never runs it
    (:typecheck([disableGlanceCheck]))
    function onSettingsChanged() as Void {
        publishComplication();
        if (_conversation != null) {
            _conversation.onSettingsChanged();
        }
    }

    //! The watch face complication's text: at each start and after new settings (the face keeps the
    //! last one). A build without the complication record (the unit tests) throws - the app goes on.
    (:typecheck([disableGlanceCheck]))
    private function publishComplication() as Void {
        if (!Capabilities.canPublishComplication()) {
            return;
        }
        try {
            Toybox.Complications.updateComplication(0, {:value => Settings.complicationText()});
        } catch (e) {
        }
    }

    (:glance)
    function getGlanceView() as [GlanceView] or [GlanceView, GlanceViewDelegate] or Null {
        return [new AssistGlance()];
    }
}
