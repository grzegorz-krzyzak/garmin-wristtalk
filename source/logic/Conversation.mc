import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

enum State {
    STATE_PAIRING,      // no key: showing the pairing code, or waiting for "Add watch" in HA
    STATE_CONNECTING,   // the key is checked before the microphone opens
    STATE_IDLE,
    STATE_LISTENING,
    STATE_RECOGNIZING,
    STATE_SENDING,
    STATE_LOADING_VOICE,  // the reply text is on screen, its voice is on the way (a stall too)
    STATE_PLAYING,
    STATE_ERROR
}

//! What a popup says - the view picks its icon
enum PopupKind {
    POPUP_PAIRED,
    POPUP_VOICE,
    POPUP_TEXT_ONLY,
    POPUP_NOT_HEARD,
    POPUP_VOICE_FAILED, // the voice did not arrive, or was cut off - the text is there
    POPUP_COMMAND_SENT  // BACK after the command reached Home Assistant: it runs anyway
}

enum EntryKind {
    ENTRY_EXCHANGE,
    ENTRY_DIVIDER       // "new conversation": Home Assistant forgot the earlier one (5 min)
}

//! The logic of the app: states, the conversation on screen, settings, timers, decisions. It knows
//! neither the screen nor how a request travels - the client, recorder and player are passed in,
//! so the tests can use fakes.
class Conversation {

    const KEY_REREAD_MS = 300;           // no key at the start: read once more before pairing (shorter
                                         // than ShownState.SHOW_MS: "Connecting…" must not show meanwhile)
    const CONNECTING_CAP_MS = 10500;     // no answer: a connection error
    const NO_SPEECH_MS = 12000;          // from the first audio: nothing said -> "nothing heard"; 5 s was
                                         // too short through the phone (speech reached HA after 5-7 s)
    const LISTEN_CAP_MS = 25000;         // the integration closes at 20 s; this only guards the watch
    // From the end of listening to the reply text at most this long, whatever the house answers on
    // the way ("listening", "waiting" reset NO_ANSWER_MS, not this)
    const ANSWER_CAP_MS = 60000;
    // "listening" to the empty "final" (the text not there yet): asked again after a moment, at most
    // this many times
    const FINAL_AGAIN_MS = 300;
    const FINALS_AGAIN = 10;
    const REST_WAIT_MS = 1500;           // after START: the microphone's last audio, then "final"
    const CHUNK_TRIES = 3;               // a chunk lost on the way is sent again; after 3 tries an error
    const CHUNK_ANSWER_MS = 10000;       // no answer by then: counted as lost (the phone path can keep
                                         // a request without an answer)
    const CHUNKS_IN_FLIGHT = 2;          // through the phone one chunk takes 1.5-3.5 s: the next one
                                         // goes meanwhile (the integration takes them in any order)
    const CONVERSATION_TIMEOUT_MS = 300000;  // Home Assistant's chat session: 5 minutes
    const HISTORY_SIZE = 6;
    const TICK_MS = 100;
    const PULSE_MS = 800;                // the START arc blinking while the app waits for START: on
                                         // 800 ms, off 800 ms (the breathing width was hard to see)
    const POPUP_MS = 1500;               // a confirmation; a problem stays until START or BACK
    const NO_ANSWER_MS = 15000;          // "Recognising" / "Thinking" with no answer from the house this
                                         // long: an error, not a wait without end. Home Assistant answers
                                         // every request within 4 s, the phone adds up to 3.5 s. Seen on
                                         // the fēnix 8: requests reached the house, the answers never
                                         // came back, the app stayed in "Recognising"; reopening the
                                         // app helped
    const VOICE_POPUP_MS = 2000;         // the voice failed: a note over the reply, then the reply

    var state as State = STATE_IDLE;
    var heard as String = "";
    var reply as String = "";
    var error as String = "";
    //! Under the error, what to do: START to try again, the app closing, or "" (the message says it)
    var errorHint as String = "";
    //! The error on screen goes away with another try (START); false: something is to be done
    //! elsewhere, so START does nothing and has no arc
    var canRetry as Boolean = true;
    var popup as String = "";
    var popupKind as PopupKind = POPUP_PAIRED;
    //! What the screen shows of `state` - waiting states without flashing by (ShownState)
    var shown as ShownState = new ShownState();
    //! Idle with nothing in the conversation: the START arc pulses (ticks every PULSE_MS)
    var pulsing as Boolean = false;
    //! While pulsing: the START arc on (true) or off. Switched by the clock every PULSE_MS, not by
    //! counting ticks - the fast ticks (a popup, the screen catching up) may come in between
    var pulseOn as Boolean = true;
    var tick as Number = 0;
    //! Counts the commands begun (and a cleared conversation): the view scrolls back to the latest
    var commandCount as Number = 0;
    //! Earlier entries, oldest first: [kind, command, reply, isError]
    var history as Array<Array> = [] as Array<Array>;

    private var _client as HaClient;
    private var _recorder as Recorder;
    private var _player as Player;
    private var _started as Boolean = false;
    private var _idleWhenShown as Boolean = false;  // the idle time was stopped by the menu
    private var _covered as Boolean = false;        // the menu (or its YES / NO) is on top
    private var _inBackground as Boolean = false;   // the system took the app away (watch face)
    private var _lastCommandAt as Number?;
    // The current command
    private var _session as String = "";
    private var _audio as ByteArray = []b;
    private var _sent as Number = 0;
    private var _inFlight as Array<ChunkRequest> = [] as Array<ChunkRequest>;
    private var _finalPending as Boolean = false;
    // Home Assistant said "recognizing": the command has ended there, more audio is not sent
    private var _inputEnded as Boolean = false;
    //! After START until the microphone has handed over all it holds (up to a second of speech)
    private var _awaitingRest as Boolean = false;
    private var _speech as Boolean = false;
    private var _textOnly as Boolean = false;
    private var _fastTicks as Boolean = false;
    private var _voice as Voice?;
    // The open reply poll and ping - abandoned when their command or key is given up
    private var _replyRequest as AnswerRequest?;
    // The command's end ("final") has been sent: from then on Home Assistant runs it
    private var _finalSent as Boolean = false;
    private var _pingRequest as AnswerRequest?;
    private var _answeredAt as Number = 0;   // the house's last answer in this command
    private var _listenUntil as Number = 0;  // listening ends by itself then
    private var _answerUntil as Number = 0;  // 0: listening; then the reply text is due by then
    private var _finalsAgain as Number = 0;
    private var _noAnswers as Number = 0;    // NO_ANSWER_MS errors in a row
    private var _pingResult as Result?;
    // Timers (watches limit how many may run): one for ticks and the popup, one for waits (pairing
    // shares it), one for closing on idle
    private var _tickTimer as Timer.Timer = new Timer.Timer();
    private var _waitTimer as Timer.Timer = new Timer.Timer();
    private var _animating as Boolean = false;
    private var _ticking as Boolean = false;
    private var _popupUntil as Number = 0;   // 0 = stays until dismissed
    private var _pulseAt as Number = 0;      // when pulseOn last switched

    var pairing as Pairing;
    var idle as IdleClose;

    function initialize(client as HaClient, recorder as Recorder, player as Player) {
        _client = client;
        _recorder = recorder;
        _player = player;
        pairing = new Pairing(client, _waitTimer, method(:onPaired), method(:onPairingGaveUp));
        idle = new IdleClose(method(:onIdleWarning));
        Deferred.wake = method(:onDeferred);
    }

    //! A request's answer waits for a tick (net/Deferred)
    function onDeferred() as Void {
        runTicks();
    }

    // --- app lifecycle ------------------------------------------------------------------------

    //! Once, when the view shows: pair, or check the key and listen. The microphone opens only
    //! after Home Assistant has accepted the key - a removed watch goes straight to pairing instead
    //! of flashing "Listening"
    function startOnce() as Void {
        if (_started) {
            return;
        }
        _started = true;
        if (Settings.key() == null) {
            // A paired watch once opened on pairing with its key still stored: the key
            // is read once more after a moment; nothing shows meanwhile
            setState(STATE_CONNECTING, SHOW_WAITING);
            waitThen(KEY_REREAD_MS, method(:onKeyReread));
            return;
        }
        startWithKey();
    }

    //! The second read of the key at the start: still none - pairing
    function onKeyReread() as Void {
        if (state != STATE_CONNECTING) {
            return;
        }
        if (Settings.key() == null) {
            beginPairing();
        } else {
            startWithKey();
        }
    }

    private function startWithKey() as Void {
        if (Settings.listenOnOpen()) {
            setState(STATE_CONNECTING, SHOW_WAITING);
            _pingResult = null;
            waitThen(CONNECTING_CAP_MS, method(:onConnectingTimeout));
        } else {
            setState(STATE_IDLE, SHOW_AFTER_HOLD);
            armIdleExit(Settings.idleExitMs());
        }
        abandon(_pingRequest);
        var ping = new AnswerRequest(method(:onPing));
        _pingRequest = ping;
        _client.ping(ping.method(:onResult));
    }

    function onPing(result as Result) as Void {
        _pingRequest = null;
        if (state != STATE_CONNECTING) {
            // The check in the background (not listening on open), or one that came too late
            if (result.kind == RESULT_UNAUTHORIZED) {
                reconnect();
            }
            return;
        }
        _pingResult = result;
        // "Connecting…" on screen stays its minimum: the microphone opens when "Listening" shows
        var left = shown.holdLeft(System.getTimer());
        if (left > 0) {
            waitThen(left, method(:onConnected));
        } else {
            onConnected();
        }
    }

    function onConnectingTimeout() as Void {
        if (state == STATE_CONNECTING) {
            fail(Messages.describe(new Result(RESULT_TIMEOUT, 0, null)), true);
        }
    }

    function onConnected() as Void {
        var result = _pingResult;
        if (state != STATE_CONNECTING || result == null) {
            return;
        }
        _waitTimer.stop();
        if (result.ok()) {
            listen();
        } else {
            failRequest(result);
        }
    }

    //! Settings changed in the Connect IQ app: a new address (the key belongs to the old one). While
    //! pairing without a code yet (no address, "Add watch" not open) it starts again with the new
    //! settings - before, the address asked for stayed on screen until START, which nothing showed
    function onSettingsChanged() as Void {
        if (Settings.key() == null && state != STATE_PAIRING) {
            reconnect();
        } else if (state == STATE_PAIRING && !_inBackground) {
            if (!Settings.houseUrl().equals(pairing.address())) {
                // A new address drops the pairing (and the code) kept for the old one
                pairing.restart();
            } else if (pairing.code.length() == 0) {
                pairing.begin();
            }
        }
        WatchUi.requestUpdate();
    }

    function shutdown() as Void {
        Deferred.clear();
        _waitTimer.stop();
        idle.stop();
        _tickTimer.stop();
        _recorder.stop();
        stopVoice();
        _player.stop();
    }

    // --- pairing ------------------------------------------------------------------------------

    //! The menu offers "Pair again" only to a paired watch
    function canPairAgain() as Boolean {
        return Settings.key() != null && state != STATE_PAIRING;
    }

    //! "Pair again" from the menu: Home Assistant is told first, with the key - it revokes the key
    //! and shows that the watch needs pairing (protocol 3); then the key goes and the code shows.
    //! Told or not (no phone at the moment), typing the code replaces the key in Home Assistant
    function pairAgain() as Void {
        if (!canPairAgain()) {
            return;
        }
        _client.repair(method(:onRepairSent));
        reconnect();
    }

    //! Nothing to do with the answer: the pairing has started either way
    function onRepairSent(result as Result) as Void {
    }

    private function reconnect() as Void {
        // A late answer of the old key must not reach the new pairing (a 401 would delete the new key)
        abandon(_pingRequest);
        _pingRequest = null;
        Settings.clearKey();
        Settings.clearPairingInProgress();
        stopCommand();
        pairing.notice = "";
        beginPairing();
    }

    private function beginPairing() as Void {
        setState(STATE_PAIRING, SHOW_NOW);
        error = "";
        stopPulse();
        idle.stop();  // no idle time while pairing: in the background it asks nothing anyway
        pairing.begin();
    }

    //! Pairing asked long enough: the note stays, the app closes after its idle time
    function onPairingGaveUp() as Void {
        armIdleExit(Settings.idleExitMs());
    }

    //! A new watch for Home Assistant, with a new conversation: the old one goes from the screen
    //! too (it may show the house to whoever holds a removed watch)
    function onPaired() as Void {
        history = [] as Array<Array>;
        heard = "";
        reply = "";
        error = "";
        commandCount++;
        _lastCommandAt = null;
        setState(STATE_IDLE, SHOW_NOW);
        buzz(BUZZ_REPLY);
        showPopup(POPUP_PAIRED, Settings.text(Rez.Strings.PairDone), POPUP_MS);
        armIdleExit(Settings.idleExitMs());
    }

    // --- input --------------------------------------------------------------------------------

    //! START: send the command, interrupt the reply and speak, or the next command
    function onSelect() as Void {
        if (idle.countdown > 0) {
            keepOpen();
            return;
        }
        if (state == STATE_PAIRING) {
            if (pairing.code.length() == 0) {
                pairing.begin();
            }
        } else if (state == STATE_LISTENING) {
            finishListening();
        } else if (state == STATE_PLAYING || state == STATE_LOADING_VOICE) {
            stopVoice();
            listen();
        } else if (state == STATE_IDLE || (state == STATE_ERROR && canRetry)) {
            listen();
        }
    }

    //! BACK cancels the current step; on the idle screen it closes the app (returns false)
    function onBack() as Boolean {
        if (idle.countdown > 0) {
            return false;  // "BACK: close now" - the default closes the app
        }
        if (popup.length() > 0) {
            dismissPopup();
            return true;
        }
        if (state == STATE_LISTENING || state == STATE_RECOGNIZING || state == STATE_SENDING
                || state == STATE_LOADING_VOICE || state == STATE_PLAYING) {
            // Once the end of the command is in Home Assistant, BACK only stops waiting for the
            // reply - the command runs (a gate, a lock, the car): it must not look like a cancel
            var sent = state == STATE_RECOGNIZING || state == STATE_SENDING || _finalSent;
            stopCommand();
            setState(STATE_IDLE, SHOW_NOW);
            if (sent) {
                showPopup(POPUP_COMMAND_SENT, Settings.text(Rez.Strings.CommandSent), VOICE_POPUP_MS);
            }
            armIdleExit(Settings.idleExitMs());
            WatchUi.requestUpdate();
            return true;
        }
        return false;
    }

    //! UP / DOWN or a drag: during the countdown it only keeps the app open (true); otherwise the
    //! view scrolls the conversation, and reading counts as use - the idle time starts again
    function onScrollInput() as Boolean {
        if (idle.countdown > 0) {
            keepOpen();
            return true;
        }
        if (state == STATE_IDLE || state == STATE_ERROR) {
            idle.arm(Settings.idleExitMs());
        }
        return false;
    }

    //! "Text only" from the menu: the switch shows the state, so no popup - as Garmin's own menus;
    //! the speaker sign above the status shows the mode afterwards
    function setTextOnly(on as Boolean) as Void {
        onScrollInput();
        applyTextOnly(on);
        WatchUi.requestUpdate();
    }

    //! A quick switch without a view to show it (for a long press on the status line, later): with
    //! a popup
    function toggleTextOnly() as Void {
        if (onScrollInput()) {
            return;
        }
        var on = !Settings.textOnly();
        if (applyTextOnly(on)) {
            showPopup(on ? POPUP_TEXT_ONLY : POPUP_VOICE,
                Settings.text(on ? Rez.Strings.ModeTextOnly : Rez.Strings.ModeVoiceText), POPUP_MS);
        }
    }

    //! Also the setting in the Connect IQ app; a voice playing stops at once. False without a speaker
    private function applyTextOnly(on as Boolean) as Boolean {
        if (!Capabilities.hasSpeaker()) {
            return false;
        }
        Settings.setTextOnly(on);
        if (on && (state == STATE_PLAYING || state == STATE_LOADING_VOICE)) {
            stopVoice();
            done();
        }
        return true;
    }

    // --- a command ----------------------------------------------------------------------------

    function listen() as Void {
        // Opening the app or "keep listening" after a reply while the menu is on top: no microphone
        // under the menu - idle until START
        if (_covered) {
            setState(STATE_IDLE, SHOW_NOW);
            _idleWhenShown = true;
            WatchUi.requestUpdate();
            return;
        }
        idle.stop();
        stopPulse();
        _waitTimer.stop();
        keepCurrentInHistory();
        heard = "";
        reply = "";
        error = "";
        errorHint = "";
        popup = "";
        commandCount++;
        _audio = []b;
        _sent = 0;
        abandonChunks();
        abandon(_replyRequest);
        _replyRequest = null;
        _finalPending = false;
        _finalSent = false;
        _awaitingRest = false;
        _inputEnded = false;
        _speech = false;
        _textOnly = Settings.textOnly();
        _session = System.getTimer().format("%x") + Math.rand().format("%x");
        buzz(BUZZ_LISTEN);  // before the microphone opens - not in the recording
        if (!_recorder.start(method(:onAudioData), method(:onRecordingDone))) {
            fail(Settings.text(Rez.Strings.ErrMicStart), true);
            return;
        }
        setState(STATE_LISTENING, SHOW_NOW);
        startTicks();
        // Its own deadline, not the wait timer: the first audio re-arms that one for "nothing said"
        _listenUntil = System.getTimer() + LISTEN_CAP_MS;
        _answerUntil = 0;
        _finalsAgain = 0;
        WatchUi.requestUpdate();
    }

    //! "New conversation" after 5 minutes: Home Assistant has forgotten the earlier one
    private function keepCurrentInHistory() as Void {
        if (heard.length() > 0) {
            history.add([ENTRY_EXCHANGE, heard, state == STATE_ERROR ? error : reply, state == STATE_ERROR]);
        }
        var now = System.getTimer();
        if (_lastCommandAt != null && now - _lastCommandAt > CONVERSATION_TIMEOUT_MS && history.size() > 0
                && history[history.size() - 1][0] != ENTRY_DIVIDER) {
            history.add([ENTRY_DIVIDER, "", "", false]);
        }
        _lastCommandAt = now;
        while (history.size() > HISTORY_SIZE) {
            history = history.slice(1, null);
        }
    }

    //! Listening, or after START until the integration has the command
    private function takingAudio() as Boolean {
        return state == STATE_LISTENING || state == STATE_RECOGNIZING;
    }

    function onAudioData(data as ByteArray) as Void {
        // What the microphone still hands over after the command is known stays on the watch:
        // sent, it took the phone's bandwidth from the reply (up to 16 kB)
        if (!takingAudio() || _inputEnded) {
            return;
        }
        if (_audio.size() == 0) {
            waitThen(NO_SPEECH_MS, method(:onNoSpeech));
        }
        _audio.addAll(data);
        sendChunk(false);
    }

    function onRecordingDone(ok as Boolean) as Void {
        if (!ok && state == STATE_LISTENING) {
            fail(Settings.text(Rez.Strings.ErrMicStopped), true);
        } else if (_awaitingRest && state == STATE_RECOGNIZING) {
            sendFinal();
        }
    }

    //! START or the watch's own cap. "Recognising" at once - the press shows, not only when the text
    //! comes back; "final" only once the microphone has handed over what it still holds: sent at
    //! once, the last words of a command were cut
    function finishListening() as Void {
        if (state != STATE_LISTENING) {
            return;
        }
        _finalPending = true;
        _awaitingRest = true;
        _answeredAt = System.getTimer();
        startAnswerDeadline();
        setState(STATE_RECOGNIZING, SHOW_NOW);
        WatchUi.requestUpdate();
        // The flags first: stopping may hand over the rest and report the end at once
        waitThen(REST_WAIT_MS, method(:sendFinal));
        _recorder.stop();
    }

    //! The microphone is done (or did not say so in time): the rest with "final"
    function sendFinal() as Void {
        if (!_awaitingRest || state != STATE_RECOGNIZING) {
            return;
        }
        _awaitingRest = false;
        _waitTimer.stop();
        sendChunk(true);
    }

    //! Up to CHUNKS_IN_FLIGHT chunk requests at a time; what comes meanwhile goes with the next one.
    //! "final" goes as soon as the microphone is done, past the chunks still on their way - the
    //! integration closes the input once everything up to its end is in (protocol 4); one at a time
    private function sendChunk(final as Boolean) as Void {
        if (!takingAudio() || (final ? finalInFlight() : _inFlight.size() >= CHUNKS_IN_FLIGHT)) {
            return;
        }
        if (_audio.size() <= _sent && !final) {
            return;
        }
        var offset = _sent;
        _sent = _audio.size();
        if (final) {
            _finalSent = true;
        }
        send(new ChunkRequest(offset, _sent - offset, final, 1, method(:onChunk)));
    }

    private function finalInFlight() as Boolean {
        for (var i = 0; i < _inFlight.size(); i++) {
            if (_inFlight[i].final) {
                return true;
            }
        }
        return false;
    }

    private function send(request as ChunkRequest) as Void {
        _inFlight.add(request);
        _client.sendChunk(_session, request.offset, _audio.slice(request.offset, request.offset + request.size),
            _textOnly && request.offset == 0, request.final, request.method(:onResult));
    }

    //! A chunk that did not arrive goes again while tries are left; true when it went
    private function resend(request as ChunkRequest) as Boolean {
        if (request.tries >= CHUNK_TRIES) {
            return false;
        }
        send(request.next());
        return true;
    }

    //! Lost on the way through the phone - not refused by Home Assistant. Not "no phone": that
    //! answer comes at once (0.02 s) and stays until Bluetooth is back
    private function lost(result as Result) as Boolean {
        return result.kind == RESULT_TIMEOUT || result.kind == RESULT_ERROR;
    }

    //! A chunk request without an answer for CHUNK_ANSWER_MS counts as lost (from the ticks while
    //! listening; `now` from the caller, so the tests need not wait)
    function checkChunks(now as Number) as Void {
        if (!takingAudio()) {
            return;
        }
        for (var i = 0; i < _inFlight.size(); i++) {
            var request = _inFlight[i];
            if (now - request.sentAt > CHUNK_ANSWER_MS) {
                request.abandoned = true;
                _inFlight.remove(request);
                if (!resend(request)) {
                    fail(Messages.describe(new Result(RESULT_TIMEOUT, 0, null)), true);
                }
                return;
            }
        }
    }

    //! "Recognising" or "Thinking" with no answer from the house for NO_ANSWER_MS: a connection
    //! error START may fix; the second in a row says to reopen the app (what helped on the watch).
    //! From the ticks; `now` from the caller, so the tests need not wait
    function checkAnswers(now as Number) as Void {
        if (state != STATE_RECOGNIZING && state != STATE_SENDING) {
            return;
        }
        if (now - _answeredAt <= NO_ANSWER_MS && (_answerUntil == 0 || now < _answerUntil)) {
            return;
        }
        _noAnswers++;
        fail(Settings.text(Rez.Strings.ErrTimeout), true);
        if (_noAnswers >= 2) {
            errorHint = Settings.text(Rez.Strings.ReopenToRetry);
        }
    }

    //! For the tests only: the house's last answer at a given time (the answers themselves take
    //! the clock, which a test cannot move)
    function setAnsweredAt(time as Number) as Void {
        _answeredAt = time;
    }

    //! Listening ends by itself at LISTEN_CAP_MS, even while speech goes on (a radio, wind)
    function checkListening(now as Number) as Void {
        if (state == STATE_LISTENING && now >= _listenUntil) {
            finishListening();
        }
    }

    //! The end of listening, by START, the cap or Home Assistant: the reply text is due within
    //! ANSWER_CAP_MS, answers on the way do not move it
    private function startAnswerDeadline() as Void {
        if (_answerUntil == 0) {
            _answerUntil = System.getTimer() + ANSWER_CAP_MS;
        }
    }

    //! The empty "final" again, once its moment has passed
    function sendFinalAgain() as Void {
        if (state == STATE_RECOGNIZING && _finalPending && !_awaitingRest) {
            sendChunk(true);
        }
    }

    private function abandonChunks() as Void {
        for (var i = 0; i < _inFlight.size(); i++) {
            _inFlight[i].abandoned = true;
        }
        _inFlight = [] as Array<ChunkRequest>;
    }

    function onChunk(request as ChunkRequest, result as Result) as Void {
        _inFlight.remove(request);
        if (!takingAudio()) {
            return;
        }
        if (!result.ok()) {
            if (!(lost(result) && resend(request))) {
                failRequest(result);
            }
            return;
        }
        _answeredAt = System.getTimer();
        if (result.flag("speech")) {
            _speech = true;
        }
        var answer = result.text("state");
        if (answer.equals("heard")) {
            startAnswerDeadline();
            // The recording is in Home Assistant: not kept for the rest of the command, and chunks
            // still on their way are not resent
            abandonChunks();
            _audio = []b;
            heard = result.text("heard");
            // The state first: stopping the microphone hands over what it still holds
            setState(STATE_SENDING, SHOW_WAITING);
            _recorder.stop();
            _waitTimer.stop();
            buzz(BUZZ_SENT);
            askReply();
        } else if (answer.equals("nothing")) {
            notHeard();
        } else if (answer.equals("recognizing")) {
            // Home Assistant has ended the command (silence) and another request waits for the
            // text (protocol 5): stop listening now; a "listening" without the text later asks
            // again with an empty "final"
            if (state == STATE_LISTENING) {
                startAnswerDeadline();
                setState(STATE_RECOGNIZING, SHOW_WAITING);
                _finalPending = true;
                _awaitingRest = false;
                _inputEnded = true;
                _waitTimer.stop();
                _recorder.stop();
            }
        } else if (_finalPending && !_awaitingRest && !request.final) {
            sendChunk(true);
        } else if (_finalPending && !_awaitingRest) {
            // "final" answered without the text: the empty "final" again after a moment, a few
            // times only - the answer deadline ends it anyway
            _finalsAgain++;
            if (_finalsAgain > FINALS_AGAIN) {
                fail(Settings.text(Rez.Strings.ErrTimeout), true);
                return;
            }
            waitThen(FINAL_AGAIN_MS, method(:sendFinalAgain));
        } else {
            sendChunk(false);
        }
        WatchUi.requestUpdate();
    }

    //! Only when the integration answers and has heard no speech
    function onNoSpeech() as Void {
        if (state == STATE_LISTENING && !_speech && _sent > 0) {
            notHeard();
        }
    }

    //! The reply poll of this command; the one before it, if any, is given up
    private function askReply() as Void {
        abandon(_replyRequest);
        var request = new AnswerRequest(method(:onReply));
        _replyRequest = request;
        _client.reply(_session, request.method(:onResult));
    }

    private function abandon(request as AnswerRequest?) as Void {
        if (request != null) {
            request.abandoned = true;
        }
    }

    function onReply(result as Result) as Void {
        _replyRequest = null;
        if (state != STATE_SENDING) {
            return;
        }
        if (!result.ok()) {
            failRequest(result);
            return;
        }
        _answeredAt = System.getTimer();
        if (result.text("state").equals("waiting")) {
            askReply();
            return;
        }
        _noAnswers = 0;
        if (result.text("state").equals("nothing")) {
            notHeard();
            return;
        }
        reply = result.text("reply");
        stopTicks();
        buzz(BUZZ_REPLY);
        WatchUi.requestUpdate();
        if (result.flag("audio") && !Settings.textOnly()) {
            setState(STATE_LOADING_VOICE, SHOW_WAITING);
            var voice = new Voice(_client, _player, _session, Settings.volume(), method(:onVoicePlaying),
                method(:onVoiceWaiting), method(:onVoiceEnd), method(:voiceHoldLeft));
            _voice = voice;
            voice.start(System.getTimer());
            runTicks();
        } else {
            done();
        }
    }

    //! The voice plays (or plays on after a stall that showed)
    function onVoicePlaying() as Void {
        setState(STATE_PLAYING, SHOW_AFTER_HOLD);
        WatchUi.requestUpdate();
    }

    //! A stall that lasted: "Loading voice" again; the reply stays on screen
    function onVoiceWaiting() as Void {
        setState(STATE_LOADING_VOICE, SHOW_NOW);
        WatchUi.requestUpdate();
    }

    //! The voice starts, and plays on after a stall, with its screen: after the waiting look's minimum
    function voiceHoldLeft(now as Number) as Number {
        return shown.holdLeft(now);
    }

    //! A voice that failed is not a failed command: the reply is on screen - a short note and the
    //! error vibration (the user may be listening, not looking), then as after any reply
    function onVoiceEnd(end as VoiceEnd) as Void {
        _voice = null;
        if (end == VOICE_UNAUTHORIZED) {
            // The watch was removed meanwhile: pair now, or the next START would open the
            // microphone only to be refused
            reconnect();
            return;
        }
        done();
        if (end == VOICE_NOT_ARRIVED || end == VOICE_CUT_OFF) {
            buzz(BUZZ_ERROR);
            showPopup(POPUP_VOICE_FAILED, Settings.text(end == VOICE_NOT_ARRIVED
                ? Rez.Strings.VoiceNotArrived : Rez.Strings.VoiceCutOff), VOICE_POPUP_MS);
        }
    }

    //! The voice's limits, a stall and its revival (from the ticks; `now` from the caller, so the
    //! tests need not wait)
    function checkVoice(now as Number) as Void {
        if (_voice != null) {
            (_voice as Voice).check(now);
        }
    }

    private function stopVoice() as Void {
        if (_voice != null) {
            (_voice as Voice).stop();
            _voice = null;
        }
    }

    private function stopCommand() as Void {
        abandonChunks();
        _audio = []b;
        // A reply poll still open belongs to this command: its late answer must not land on the next
        abandon(_replyRequest);
        _replyRequest = null;
        _waitTimer.stop();
        _recorder.stop();
        stopVoice();
        _player.stop();
        stopTicks();
    }

    // --- endings ------------------------------------------------------------------------------

    private function done() as Void {
        setState(STATE_IDLE, SHOW_AFTER_HOLD);
        stopTicks();
        if (Settings.listenAfterReply()) {
            listen();
            return;
        }
        armIdleExit(Settings.idleExitMs());
        WatchUi.requestUpdate();
    }

    //! Nothing said: a note, not a failure - the app waits for START
    private function notHeard() as Void {
        stopCommand();
        buzz(BUZZ_REPLY);
        setState(STATE_IDLE, SHOW_AFTER_HOLD);
        // A popup, not a note in the conversation, where it would fall below the anchored command,
        // out of sight; it stays until START (which listens again) or BACK
        showPopup(POPUP_NOT_HEARD, Settings.text(Rez.Strings.NotHeard), 0);
        armIdleExit(Settings.idleExitMs());
        WatchUi.requestUpdate();
    }

    private function failRequest(result as Result) as Void {
        if (result.kind == RESULT_UNAUTHORIZED) {
            reconnect();
            return;
        }
        fail(Messages.describe(result), Messages.retryHelps(result));
    }

    //! The app stays open after any number of errors - the idle countdown closes it, as always
    //! (closing by itself after two errors came before the message could be read)
    private function fail(message as String, retryHelps as Boolean) as Void {
        stopCommand();
        buzz(BUZZ_ERROR);
        setState(STATE_ERROR, SHOW_AFTER_HOLD);
        error = message;
        errorHint = retryHelps ? Settings.text(Rez.Strings.StartToRetry) : "";
        canRetry = retryHelps;
        armIdleExit(Settings.idleExitMs());
        WatchUi.requestUpdate();
    }

    // --- timers -------------------------------------------------------------------------------

    //! The state at once; the screen by ShownState's rules - the ticks run until it has caught up
    private function setState(next as State, kind as ShowKind) as Void {
        state = next;
        shown.change(next, kind, System.getTimer());
        if (!shown.settled()) {
            runTicks();
        }
    }

    private function waitThen(ms as Number, callback as Method() as Void) as Void {
        _waitTimer.stop();
        _waitTimer.start(callback, ms, false);
    }

    //! The menu (or its YES / NO) covers the app. Listening ends quietly, as with BACK - no
    //! "nothing heard"; a command already sent goes on (the house has it), its reply shows on return.
    //! Under the menu nothing starts listening and the idle time stands still - its countdown would
    //! vibrate unseen and close the app while the menu is in use (seen on the fēnix 8)
    function onCovered() as Void {
        _covered = true;
        if (state == STATE_LISTENING) {
            stopCommand();
            setState(STATE_IDLE, SHOW_NOW);
            _idleWhenShown = true;
        }
        if (idle.armed) {
            idle.stop();
            _idleWhenShown = true;
        }
    }

    //! Back on the app's screen: the idle time starts again, in full (while pairing: its limit)
    function onUncovered() as Void {
        _covered = false;
        if (_idleWhenShown) {
            _idleWhenShown = false;
            armIdle();
        }
    }

    //! The idle time of the setting - not while pairing, which has none
    private function armIdle() as Void {
        if (state != STATE_PAIRING) {
            armIdleExit(Settings.idleExitMs());
        }
    }

    //! The system took the app to the background (the watch face, the app switcher): nothing goes
    //! on unseen - pairing stops asking the house, listening ends quietly. A command already sent
    //! goes on; the idle time keeps running, so the app also closes in the background
    function onBackground() as Void {
        if (_inBackground) {
            return;
        }
        _inBackground = true;
        if (state == STATE_PAIRING) {
            pairing.pause();
        } else if (state == STATE_LISTENING) {
            stopCommand();
            setState(STATE_IDLE, SHOW_NOW);
            armIdle();
        }
    }

    //! Back on screen: pairing goes on with the same pairing
    function onForeground() as Void {
        if (!_inBackground) {
            return;
        }
        _inBackground = false;
        if (state == STATE_PAIRING) {
            pairing.resume();
        }
    }

    //! True while our own menu (or its YES / NO) covers the app - not the system
    function menuOpen() as Boolean {
        return _covered;
    }

    private function armIdleExit(ms as Number) as Void {
        if (_covered) {
            _idleWhenShown = true;  // starts when the menu closes
            return;
        }
        idle.arm(ms);
        updatePulse();
    }

    //! The countdown before closing on idle starts: it covers a popup
    function onIdleWarning() as Void {
        popup = "";
        buzz(BUZZ_WARNING);
    }

    //! A button during the countdown only stops it; the next press does what it does
    private function keepOpen() as Void {
        armIdle();
        WatchUi.requestUpdate();
    }

    //! Vibration cues by the "vibration" setting: 0 full, 1 minimal (reply, error, the countdown -
    //! the default), 2 off
    private function buzz(kind as Buzz) as Void {
        var level = Settings.number("vibration", 1);
        if (level == 2 || (level == 1 && (kind == BUZZ_LISTEN || kind == BUZZ_SENT))) {
            return;
        }
        Haptics.vibrate(kind);
    }

    //! Nothing said or answered yet: the screen shows only "Press START to speak"
    function isEmpty() as Boolean {
        return history.size() == 0 && heard.length() == 0 && reply.length() == 0 && error.length() == 0;
    }

    //! The START arc: it blinks where nothing is to be read or heard
    //! and START is the only step - an empty conversation, "nothing heard", an error START may fix;
    //! it shines where START works but is not the only step; none where START does nothing
    function waitingForStart() as Boolean {
        return (state == STATE_IDLE && (isEmpty() || (popup.length() > 0 && _popupUntil == 0)))
            || (state == STATE_ERROR && canRetry);
    }

    private function updatePulse() as Void {
        if (waitingForStart()) {
            startPulse();
        } else {
            stopPulse();
        }
    }

    //! The blink: on, then off, PULSE_MS each; on again whenever the pulse is not running. Half a
    //! tick of slack - a timer may fire a little early
    function stepPulse(now as Number) as Void {
        if (!pulsing) {
            pulseOn = true;
            _pulseAt = now;
        } else if (now - _pulseAt >= PULSE_MS - TICK_MS / 2) {
            pulseOn = !pulseOn;
            _pulseAt = now;
        }
    }

    private function startPulse() as Void {
        if (!pulsing) {
            pulseOn = true;
            _pulseAt = System.getTimer();
        }
        if (!_ticking) {
            _ticking = true;
            _tickTimer.start(method(:onTick), PULSE_MS, true);
        }
        pulsing = true;
    }

    private function stopPulse() as Void {
        if (pulsing) {
            pulsing = false;
            _tickTimer.stop();
            _ticking = false;
            _fastTicks = false;
            if (fastTicksNeeded()) {
                runTicks();  // a timed popup still has to go, or the screen has to catch up
            }
        }
    }

    //! The fast ticks: an animation, a timed popup, the screen catching up with the state, the
    //! voice (its limits, a stall and its revival), or a request's answer waiting (net/Deferred)
    private function fastTicksNeeded() as Boolean {
        return _animating || (popup.length() > 0 && _popupUntil > 0) || !shown.settled() || _voice != null
            || Deferred.pending();
    }

    private function startTicks() as Void {
        tick = 0;
        _animating = true;
        runTicks();
    }

    private function stopTicks() as Void {
        _animating = false;
        if (!fastTicksNeeded()) {
            _tickTimer.stop();
            _ticking = false;
            _fastTicks = false;
        }
    }

    private function runTicks() as Void {
        if (!_ticking || !_fastTicks) {
            _tickTimer.stop();
            _ticking = true;
            _fastTicks = true;
            _tickTimer.start(method(:onTick), TICK_MS, true);
        }
    }

    function onTick() as Void {
        Deferred.flush();
        var now = System.getTimer();
        tick++;
        stepPulse(now);
        checkChunks(now);
        checkListening(now);
        checkAnswers(now);
        checkVoice(now);
        var changed = shown.update(now);
        if (popup.length() > 0 && _popupUntil > 0 && now >= _popupUntil) {
            popup = "";
            changed = true;
        }
        if (_fastTicks && !fastTicksNeeded()) {
            _tickTimer.stop();
            _ticking = false;
            _fastTicks = false;
            if (pulsing) {
                // The fast ticks are done; the pulse goes on at its own pace
                _ticking = true;
                _tickTimer.start(method(:onTick), PULSE_MS, true);
            }
        }
        // While the voice plays the ticks only watch it: the screen is drawn when something on it
        // changes (the voice's states ask for it themselves) - not ten times a second over the
        // playing, which crackled now and then on long replies on the fēnix 8
        if (changed || _animating || pulsing || _voice == null) {
            WatchUi.requestUpdate();
        }
    }

    //! A small framed note in the middle for `ms`, or until dismissed when `ms` is 0
    private function showPopup(kind as PopupKind, text as String, ms as Number) as Void {
        popupKind = kind;
        popup = text;
        _popupUntil = ms > 0 ? System.getTimer() + ms : 0;
        if (ms > 0) {
            runTicks();
        }
        WatchUi.requestUpdate();
    }

    private function dismissPopup() as Void {
        popup = "";
        _popupUntil = 0;
        updatePulse();
        WatchUi.requestUpdate();
    }
}
