import Toybox.Lang;
import Toybox.WatchUi;

//! The app's menu (hold UP): "Text only" where the watch has a speaker, "Pair again" when paired,
//! and the app's version (to read only)
module AppMenu {

    function build(session as Conversation) as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({ :title => Settings.text(Rez.Strings.AppName) });
        if (Capabilities.hasSpeaker()) {
            menu.addItem(new WatchUi.ToggleMenuItem(Settings.text(Rez.Strings.ModeTextOnly), null,
                :textOnly, Settings.textOnly(), {}));
        }
        if (session.canPairAgain()) {
            menu.addItem(new WatchUi.MenuItem(Settings.text(Rez.Strings.PairAgain), null, :pairAgain, {}));
        }
        menu.addItem(new WatchUi.MenuItem(Settings.text(Rez.Strings.Version), Settings.APP_VERSION, :version, {}));
        return menu;
    }
}

class AppMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _session as Conversation;

    function initialize(session as Conversation) {
        Menu2InputDelegate.initialize();
        _session = session;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        if (item.getId() == :textOnly) {
            // The switch flips in place and the menu stays, as in Garmin's own menus; BACK closes it
            _session.setTextOnly((item as WatchUi.ToggleMenuItem).isEnabled());
        } else if (item.getId() == :pairAgain) {
            // The question over the menu: NO comes back to the menu, as in Garmin's own menus
            WatchUi.pushView(new WatchUi.Confirmation(Settings.text(Rez.Strings.PairAgainQuestion)),
                new PairAgainDelegate(_session), WatchUi.SLIDE_IMMEDIATE);
        }
    }
}

class PairAgainDelegate extends WatchUi.ConfirmationDelegate {

    private var _session as Conversation;

    function initialize(session as Conversation) {
        ConfirmationDelegate.initialize();
        _session = session;
    }

    //! YES: the pairing starts and the menu goes too - the question closes itself after this, so
    //! the pop here takes the menu under it and the code shows at once. NO: back to the menu
    function onResponse(response as WatchUi.Confirm) as Boolean {
        if (response == WatchUi.CONFIRM_YES) {
            _session.pairAgain();
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        }
        return true;
    }
}
