import Toybox.Application;
import Toybox.Lang;
import Toybox.Test;

// What the first public release (1.6.0) kept on the watch is read the same by every later version:
// the key and the address it belongs to, a pairing in progress, the settings from the phone. A new
// version that reads them differently makes the owner pair again or lose a setting - this is where
// that shows. The values are synthetic; each test starts from an empty storage and puts back what
// was there.

const STORED_URL = "https://home.example.org";
const STORED_KEYS = ["key", "pairedUrl", "pairId", "pairCode", "pairUrl"];
const STORED_PROPERTIES = ["houseUrl", "listenOnOpen", "afterReply", "replyMode", "volume", "vibration", "idleExitS"];

function keepStored() as Dictionary<String, Object?> {
    var kept = {} as Dictionary<String, Object?>;
    for (var i = 0; i < STORED_KEYS.size(); i++) {
        kept["s:" + STORED_KEYS[i]] = Application.Storage.getValue(STORED_KEYS[i]);
    }
    for (var i = 0; i < STORED_PROPERTIES.size(); i++) {
        kept["p:" + STORED_PROPERTIES[i]] = Application.Properties.getValue(STORED_PROPERTIES[i]);
    }
    // Nothing left by other tests: only what 1.6.0 stored is read
    Application.Storage.clearValues();
    return kept;
}

function putBack(kept as Dictionary<String, Object?>) as Void {
    for (var i = 0; i < STORED_KEYS.size(); i++) {
        var value = kept["s:" + STORED_KEYS[i]];
        if (value == null) {
            Application.Storage.deleteValue(STORED_KEYS[i]);
        } else {
            Application.Storage.setValue(STORED_KEYS[i], value as Application.PropertyValueType);
        }
    }
    for (var i = 0; i < STORED_PROPERTIES.size(); i++) {
        var value = kept["p:" + STORED_PROPERTIES[i]];
        if (value != null) {
            Application.Properties.setValue(STORED_PROPERTIES[i], value as Application.PropertyValueType);
        }
    }
}

(:test)
function theStoredKeyStillBelongsToItsAddress(logger as Test.Logger) as Boolean {
    var kept = keepStored();
    // 1.6.0 stores the key under "key" and the address it was paired for, without the trailing
    // slash, under "pairedUrl"; the owner's setting may still end with one
    Application.Properties.setValue("houseUrl", STORED_URL + "/");
    Application.Storage.setValue("key", "stored-key-of-the-watch");
    Application.Storage.setValue("pairedUrl", STORED_URL);
    var key = Settings.key();
    // Another address in the settings: the key is not sent there
    Application.Properties.setValue("houseUrl", "https://other.example.org");
    var elsewhere = Settings.key();
    putBack(kept);
    Test.assertEqual(key, "stored-key-of-the-watch");
    Test.assert(elsewhere == null);
    return true;
}

(:test)
function aStoredPairingInProgressGoesOn(logger as Test.Logger) as Boolean {
    var kept = keepStored();
    Application.Properties.setValue("houseUrl", STORED_URL);
    Application.Storage.setValue("pairId", "stored-pair-id");
    Application.Storage.setValue("pairCode", "123456");
    Application.Storage.setValue("pairUrl", STORED_URL);
    var pairing = Settings.pairingInProgress();
    putBack(kept);
    Test.assert(pairing != null);
    Test.assertEqual((pairing as Array<String>)[0], "stored-pair-id");
    Test.assertEqual((pairing as Array<String>)[1], "123456");
    return true;
}

(:test)
function theStoredSettingsKeepTheirMeaning(logger as Test.Logger) as Boolean {
    var kept = keepStored();
    // The values a 1.6.0 owner may have set in the Connect IQ app, each away from its default
    Application.Properties.setValue("listenOnOpen", false);
    Application.Properties.setValue("afterReply", 1);
    Application.Properties.setValue("volume", 2);
    Application.Properties.setValue("vibration", 0);
    Application.Properties.setValue("idleExitS", 60);
    var listenOnOpen = Settings.listenOnOpen();
    var listenAfterReply = Settings.listenAfterReply();
    var volume = Settings.volume();
    var vibration = Settings.number("vibration", 1);
    var idleExitS = Settings.number("idleExitS", 30);
    Application.Properties.setValue("volume", 0);
    var quiet = Settings.volume();
    putBack(kept);
    Test.assertEqual(listenOnOpen, false);
    Test.assertEqual(listenAfterReply, true);
    Test.assertEqual(volume, 95);
    Test.assertEqual(quiet, 30);
    Test.assertEqual(vibration, 0);
    Test.assertEqual(idleExitS, 60);
    return true;
}

(:test)
function aStoredTextOnlyChoiceStays(logger as Test.Logger) as Boolean {
    var kept = keepStored();
    // "Text only" from the watch menu is stored as replyMode 1
    Application.Properties.setValue("replyMode", 1);
    var textOnly = Settings.textOnly();
    putBack(kept);
    Test.assertEqual(textOnly, true);
    return true;
}
