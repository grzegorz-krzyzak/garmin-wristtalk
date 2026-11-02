import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Shown in the glance list - DOWN, START opens the app and it starts listening
(:glance)
class AssistGlance extends WatchUi.GlanceView {

    function initialize() {
        GlanceView.initialize();
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(0, dc.getHeight() / 2, Graphics.FONT_SMALL, WatchUi.loadResource(Rez.Strings.AppName) as String,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
