import Toybox.Application;
import Toybox.Lang;
import Toybox.Test;

// The watch face complication's text from the settings: the owner's text as typed, cut at 12
// characters, empty = the icon alone.

(:test)
function theComplicationTextIsTheOwnersUpToTwelveCharacters(logger as Test.Logger) as Boolean {
    var kept = Application.Properties.getValue("complicationText");
    Application.Properties.setValue("complicationText", "HA Talk");
    var short = Settings.complicationText();
    Application.Properties.setValue("complicationText", "WristTalk Home Assistant");
    var long = Settings.complicationText();
    Application.Properties.setValue("complicationText", "");
    var empty = Settings.complicationText();
    Application.Properties.setValue("complicationText", "Mów do domu");
    var polish = Settings.complicationText();
    if (kept != null) {
        Application.Properties.setValue("complicationText", kept as Application.PropertyValueType);
    }
    Test.assertEqual(short, "HA Talk");
    Test.assertEqual(long, "WristTalk Ho");
    Test.assertEqual(empty, "");
    // Typed as is - no letters replaced
    Test.assertEqual(polish, "Mów do domu");
    return true;
}
