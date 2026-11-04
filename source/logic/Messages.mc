import Toybox.Lang;

//! Plain words for a request that failed (the code only in the text where it helps support)
module Messages {

    function describe(result as Result) as String {
        switch (result.kind) {
            case RESULT_NO_PHONE: return Settings.text(Rez.Strings.ErrNoPhone);
            case RESULT_TIMEOUT: return Settings.text(Rez.Strings.ErrTimeout);
            case RESULT_TOO_LARGE: return Settings.text(Rez.Strings.ErrTooLong);
            case RESULT_TOO_MANY: return Settings.text(Rez.Strings.ErrTooMany);
            case RESULT_BUSY: return Settings.text(Rez.Strings.ErrBusy);
            case RESULT_STT_FAILED: return Settings.text(Rez.Strings.ErrSttFailed);
            case RESULT_UPDATE_APP: return Settings.text(Rez.Strings.ErrUpdateApp);
            case RESULT_UPDATE_INTEGRATION: return Settings.text(Rez.Strings.ErrUpdateIntegration);
            case RESULT_HTTPS: return Settings.text(Rez.Strings.ErrHttps);
            case RESULT_NO_ADDRESS: return Settings.text(Rez.Strings.PairNoAddress);
            case RESULT_SERVER:
                // The status: Connect IQ drops the body (and the integration's error code) of a 5xx
                return Lang.format(Settings.text(Rez.Strings.ErrRejected), [result.code]);
        }
        return Lang.format(Settings.text(Rez.Strings.ErrConnection), [result.code]);
    }
}
