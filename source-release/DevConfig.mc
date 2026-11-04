import Toybox.Lang;

//! Release build: no default house address - it comes from Garmin Connect only
function devHouseUrl() as String {
    return "";
}

//! Release build: the "close when idle" setting applies
function devIdleExitMs() as Number {
    return 0;
}
