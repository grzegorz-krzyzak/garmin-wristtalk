import Toybox.Application;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

//! The app settings (the Connect IQ app on the phone; "text only" also by holding UP) and the pairing
//! kept on the watch (the key, the address it belongs to).
module Settings {

    //! The same as the version in manifest.xml (tools/build.sh release checks it): shown in the menu and
    //! sent to Home Assistant, whose watch card shows it
    const APP_VERSION = "1.6.1";

    function number(key as String, fallback as Number) as Number {
        var value = Application.Properties.getValue(key);
        return value instanceof Number ? value : fallback;
    }

    //! The house address from the Connect IQ app, without a trailing slash; a dev build may bring a
    //! default for the simulator (devHouseUrl, see dev.jungle)
    function houseUrl() as String {
        var value = Application.Properties.getValue("houseUrl");
        var url = value instanceof String && value.length() > 0 ? value : devHouseUrl();
        while (url.length() > 0 && "/".equals(url.substring(url.length() - 1, url.length()))) {
            url = url.substring(0, url.length() - 1) as String;
        }
        // The setting starts as "https://", so the field shows in the Connect IQ app: no host yet = no address
        if (url.equals("https:") || url.equals("http:")) {
            return devHouseUrl();
        }
        return url;
    }

    function flag(key as String, fallback as Boolean) as Boolean {
        var value = Application.Properties.getValue(key);
        return value instanceof Boolean ? value : fallback;
    }

    function listenOnOpen() as Boolean {
        return flag("listenOnOpen", true);
    }

    function listenAfterReply() as Boolean {
        return number("afterReply", 0) == 1;
    }

    function textOnly() as Boolean {
        return !Capabilities.hasSpeaker() || number("replyMode", 0) == 1;
    }

    function setTextOnly(on as Boolean) as Void {
        Application.Properties.setValue("replyMode", on ? 1 : 0);
    }

    function volume() as Number {
        var level = number("volume", 1);
        return level == 0 ? 30 : (level == 2 ? 95 : 60);
    }

    function idleExitMs() as Number {
        var dev = devIdleExitMs();
        return dev > 0 ? dev : number("idleExitS", 30) * 1000;
    }

    function text(id as ResourceId) as String {
        return WatchUi.loadResource(id) as String;
    }

    // --- pairing ---

    //! The watch's key, if paired for the current address
    function key() as String? {
        var key = Application.Storage.getValue("key");
        var pairedUrl = Application.Storage.getValue("pairedUrl");
        if (key instanceof String && pairedUrl instanceof String && pairedUrl.equals(houseUrl())) {
            return key;
        }
        return null;
    }

    function setKey(key as String) as Void {
        Application.Storage.setValue("key", key);
        Application.Storage.setValue("pairedUrl", houseUrl());
    }

    function clearKey() as Void {
        Application.Storage.deleteValue("key");
        Application.Storage.deleteValue("pairedUrl");
    }

    //! The pairing in progress ([pair id, code]): kept on the watch, so the app closed and opened
    //! again during pairing goes on with the same pairing - it collects a key confirmed meanwhile
    function pairingInProgress() as Array<String>? {
        var id = Application.Storage.getValue("pairId");
        var code = Application.Storage.getValue("pairCode");
        var url = Application.Storage.getValue("pairUrl");
        if (id instanceof String && code instanceof String && url instanceof String && url.equals(houseUrl())) {
            return [id, code] as Array<String>;
        }
        return null;
    }

    function setPairingInProgress(id as String, code as String) as Void {
        Application.Storage.setValue("pairId", id);
        Application.Storage.setValue("pairCode", code);
        Application.Storage.setValue("pairUrl", houseUrl());
    }

    function clearPairingInProgress() as Void {
        Application.Storage.deleteValue("pairId");
        Application.Storage.deleteValue("pairCode");
        Application.Storage.deleteValue("pairUrl");
    }

    //! What the integration shows when pairing: the watch's identity
    function watchInfo() as Dictionary<Object, Object> {
        var id = System.getDeviceSettings().uniqueIdentifier;
        if (id == null) {
            var stored = Application.Storage.getValue("fallbackId");
            if (stored instanceof String) {
                id = stored;
            } else {
                id = System.getTimer().format("%x") + Math.rand().format("%x");
                Application.Storage.setValue("fallbackId", id);
            }
        }
        return { "unique_id" => id, "model" => text(Rez.Strings.ModelName), "app" => APP_VERSION } as Dictionary<Object, Object>;
    }
}
