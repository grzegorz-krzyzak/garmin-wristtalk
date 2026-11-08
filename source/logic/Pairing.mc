import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

//! Pairing with the house: the code to compare in Home Assistant, polling for the key. Runs only
//! while the app has no key; the conversation starts it and is told when the key is there.
class Pairing {

    const POLL_MS = 2000;
    const CLOSED_RETRY_MS = 5000;        // "Add watch" not open yet: ask again

    //! The six digits to compare in Home Assistant; "" until Home Assistant gives them
    var code as String = "";
    //! What to do, while there is no code (no address, open "Add watch", a connection error)
    var notice as String = "";

    private var _client as HaClient;
    private var _onPaired as Method() as Void;
    private var _timer as Timer.Timer;
    private var _pairId as String = "";
    private var _active as Boolean = false;

    //! timer: the conversation's wait timer - pairing and a command never wait at the same time,
    //! and watches limit how many timers may run
    function initialize(client as HaClient, timer as Timer.Timer, onPaired as Method() as Void) {
        _client = client;
        _timer = timer;
        _onPaired = onPaired;
    }

    //! Also the retry while "Add watch" is not open yet: the hint stays on screen until Home
    //! Assistant answers something new (clearing it flashed the waiting dots every 5 s)
    function begin() as Void {
        _active = true;
        _timer.stop();
        code = "";
        _pairId = "";
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
        // What to do shows from the first moment - no passing "connecting" state that flashes by
        if (notice.length() == 0) {
            notice = Settings.text(Rez.Strings.PairOpenInHa);
        }
        _client.pair(Settings.watchInfo(), method(:onPair));
        WatchUi.requestUpdate();
    }

    //! The app went to the background: nothing asks the house until it is back (resume)
    function pause() as Void {
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
        _active = false;
        _timer.stop();
    }

    function onPair(result as Result) as Void {
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
            _timer.start(method(:begin), CLOSED_RETRY_MS, false);
        }
        WatchUi.requestUpdate();
    }

    function poll() as Void {
        if (_active && _pairId.length() > 0) {
            _client.pollPairing(_pairId, method(:onPoll));
        }
    }

    function onPoll(result as Result) as Void {
        if (!_active) {
            return;
        }
        if (result.ok() && result.text("state").equals("paired")) {
            Settings.setKey(result.text("key"));
            Settings.clearPairingInProgress();
            // The proof for Home Assistant: a request signed with the new key - it stores the watch
            // only then (integration 0.1.7)
            _client.ping(method(:onKeyConfirmed));
            code = "";
            notice = "";
            stop();
            _onPaired.invoke();
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

    //! Nothing to do with the answer: the key is stored either way
    function onKeyConfirmed(result as Result) as Void {
    }

    //! Home Assistant answered that this pairing is over (expired, closed, refused)
    private function ended(result as Result) as Boolean {
        return result.kind == RESULT_EXPIRED || result.kind == RESULT_PAIRING_CLOSED
            || result.kind == RESULT_NOT_FOUND || result.kind == RESULT_TOO_MANY;
    }
}
