import Toybox.Lang;

//! One request whose answer goes to one callback, unless the request was abandoned meanwhile - a
//! late answer of a request given up (a new command, BACK, pairing again) is then ignored instead
//! of landing on whatever runs now
class AnswerRequest {

    var abandoned as Boolean = false;
    private var _onResult as Method(result as Result) as Void;

    function initialize(onResult as Method(result as Result) as Void) {
        _onResult = onResult;
    }

    function onResult(result as Result) as Void {
        if (!abandoned) {
            _onResult.invoke(result);
        }
    }
}
