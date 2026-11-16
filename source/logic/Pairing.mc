import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

//! Pairing with the house: the code to compare in Home Assistant, polling for the key. Runs only
//! while the app has no key; the conversation starts it and is told when the key is there.
class Pairing {

    const POLL_MS = 2000;
    const CLOSED_RETRY_MS = 5000;        // "Add watch" not open yet: ask again
    // Pairing asks the house this long at most (Home Assistant's window is 3 minutes; codes come
    // again while it is open), then stops with a note - START starts it again
    const CAP_MS = 600000;
    const KEY_MIN_LENGTH = 16;           // a key shorter than this is not one Home Assistant made
    const CONFIRM_TRIES = 3;             // the confirming ping, sent again when lost on the way

    //! The six digits to compare in Home Assistant; "" until Home Assistant gives them
    var code as String = "";
    //! What to do, while there is no code (no address, open "Add watch", a connection error)
    var notice as String = "";

    private var _client as HaClient;
    private var _onPaired as Method() as Void;
    private var _timer as Timer.Timer;
    private var _pairId as String = "";
    private var _active as Boolean = false;
    // The one request on its way (pair or poll): a second is not sent, a late answer of an abandoned
    // one is ignored
    private var _request as AnswerRequest?;
    private var _url as String = "";         // the address this pairing asks
    private var _since as Number = 0;        // 0: not started; then when this pairing began
    private var _confirmTries as Number = 0;
    private var _onGaveUp as Method() as Void;

    //! timer: the conversation's wait timer - pairing and a command never wait at the same time,
    //! and watches limit how many timers may run
    function initialize(client as HaClient, timer as Timer.Timer, onPaired as Method() as Void,
            onGaveUp as Method() as Void) {
        _client = client;
        _timer = timer;
        _onPaired = onPaired;
        _onGaveUp = onGaveUp;
    }

    //! Also the retry while "Add watch" is not open yet: the hint stays on screen until Home
    //! Assistant answers something new (clearing it flashed the waiting dots every 5 s)
    function begin() as Void {
        // START, a resume, a settings change while a request is on its way to the same address:
        // its answer is awaited, not a second request sent
        if (_active && _request != null && Settings.houseUrl().equals(_url)) {
            return;
        }
        abandon();
        if (_since == 0) {
            _since = System.getTimer();
        } else if (System.getTimer() - _since > CAP_MS) {
            giveUp();
            return;
        }
        _active = true;
        _timer.stop();
        code = "";
        _pairId = "";
        _url = Settings.houseUrl();
        if (Settings.houseUrl().length() == 0) {
            notice = Settings.text(Rez.Strings.PairNoAddress);
            WatchUi.requestUpdate();
            return;
        }
        // A pairing kept from before (the app closed meanwhile): the same code, and its key if the
        // code was typed in Home Assistant meanwhile
        var kept = Settings.pairingInProgress();
        if (kept != null) {
            _pairId = kept[0];
            code = kept[1];
            notice = "";
            poll();
            WatchUi.requestUpdate();
            return;
        }
        // What to do shows from the first moment - no passing "connecting" state that flashes by;
        // "set the address" is stale once there is one
        if (notice.length() == 0 || notice.equals(Settings.text(Rez.Strings.PairNoAddress))) {
            notice = Settings.text(Rez.Strings.PairOpenInHa);
        }
        send(method(:onPair));
        _client.pair(Settings.watchInfo(), (_request as AnswerRequest).method(:onResult));
        WatchUi.requestUpdate();
    }

    //! For the tests only: when this pairing began (the cap is minutes, which a test cannot wait)
    function setSince(time as Number) as Void {
        _since = time;
    }

    //! The address this pairing asks ("" before it starts)
    function address() as String {
        return _url;
    }

    //! A new address while pairing: the pairing kept for the old one is dropped, a new one starts
    function restart() as Void {
        abandon();
        _active = false;
        Settings.clearPairingInProgress();
        begin();
    }

    private function send(callback as Method(result as Result) as Void) as Void {
        _request = new AnswerRequest(callback);
    }

    private function abandon() as Void {
        if (_request != null) {
            (_request as AnswerRequest).abandoned = true;
            _request = null;
        }
    }

    //! Asked long enough: stopped, with a note; START starts it again
    private function giveUp() as Void {
        stop();
        code = "";
        _pairId = "";
        notice = Settings.text(Rez.Strings.PairGaveUp);
        _onGaveUp.invoke();
        WatchUi.requestUpdate();
    }

    //! The app went to the background: nothing asks the house until it is back (resume)
    function pause() as Void {
        abandon();
        _active = false;
        _timer.stop();
    }

    //! Back from the background: the same pairing goes on (its id is kept on the watch)
    function resume() as Void {
        if (!_active) {
            begin();
        }
    }

    function stop() as Void {
        abandon();
        _active = false;
        _since = 0;
        _timer.stop();
    }

    function onPair(result as Result) as Void {
        _request = null;
        if (!_active) {
            return;
        }
        if (result.ok()) {
            _pairId = result.text("pair_id");
            code = result.text("code");
            notice = "";
            Settings.setPairingInProgress(_pairId, code);
            _timer.start(method(:poll), POLL_MS, false);
        } else {
            notice = result.kind == RESULT_PAIRING_CLOSED || result.kind == RESULT_BUSY
                ? Settings.text(Rez.Strings.PairOpenInHa) : Messages.describe(result);
            // Not worth asking again when something is to be done elsewhere (an update, https):
            // the note says what, START asks again
            if (Messages.retryHelps(result)) {
                _timer.start(method(:begin), CLOSED_RETRY_MS, false);
            } else {
                stop();
            }
        }
        WatchUi.requestUpdate();
    }

    function poll() as Void {
        if (!_active || _pairId.length() == 0 || _request != null) {
            return;
        }
        if (System.getTimer() - _since > CAP_MS) {
            giveUp();
            return;
        }
        send(method(:onPoll));
        _client.pollPairing(_pairId, (_request as AnswerRequest).method(:onResult));
    }

    function onPoll(result as Result) as Void {
        _request = null;
        if (!_active) {
            return;
        }
        var key = result.ok() ? result.text("key") : "";
        if (result.ok() && result.text("state").equals("paired") && key.length() < KEY_MIN_LENGTH) {
            // Not a key Home Assistant made: this pairing is useless - a new one starts
            Settings.clearPairingInProgress();
            begin();
        } else if (result.ok() && result.text("state").equals("paired")) {
            Settings.setKey(key);
            Settings.clearPairingInProgress();
            // The proof for Home Assistant: a request signed with the new key - it stores the watch
            // only then; sent again when lost on the way
            _confirmTries = 1;
            _client.ping(method(:onKeyConfirmed));
            code = "";
            notice = "";
            stop();
            _onPaired.invoke();
        } else if (!result.ok() && !Messages.retryHelps(result)) {
            notice = Messages.describe(result);
            stop();
        } else if (result.ok() || !ended(result)) {
            // Pending, or the connection failed for a moment: the code stays on screen - Home
            // Assistant still shows it, and a key confirmed meanwhile can still be collected
            _timer.start(method(:poll), POLL_MS, false);
        } else {
            // Over (expired, closed): a kept pairing is gone too - a new one starts
            Settings.clearPairingInProgress();
            begin();
        }
        WatchUi.requestUpdate();
    }

    //! Home Assistant stores the watch once this arrives: lost on the way, it is sent again a few
    //! times; refused (401), the next command finds out and pairing starts again
    function onKeyConfirmed(result as Result) as Void {
        if (!result.ok() && result.kind != RESULT_UNAUTHORIZED && _confirmTries < CONFIRM_TRIES) {
            _confirmTries++;
            _client.ping(method(:onKeyConfirmed));
        }
    }

    //! Home Assistant answered that this pairing is over (expired, closed, refused)
    private function ended(result as Result) as Boolean {
        return result.kind == RESULT_EXPIRED || result.kind == RESULT_PAIRING_CLOSED
            || result.kind == RESULT_NOT_FOUND || result.kind == RESULT_TOO_MANY;
    }
}
