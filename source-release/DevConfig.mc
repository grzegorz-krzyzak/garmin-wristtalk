import Toybox.Lang;
import Toybox.WatchUi;

//! Release build: no default house address - it comes from Garmin Connect only
function devHouseUrl() as String {
    return "";
}

//! Release build: the "close when idle" setting applies
function devIdleExitMs() as Number {
    return 0;
}

//! Release build: the app itself (the probe build shows its test first)
function startView() as [WatchUi.Views, WatchUi.InputDelegates] or Null {
    return null;
}

//! Release build: no trace
function devTrace(line as String) as Void {
}
