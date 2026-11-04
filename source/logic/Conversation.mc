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
    STATE_PLAYING,
    STATE_ERROR
}

enum EntryKind {
    ENTRY_EXCHANGE,
    ENTRY_DIVIDER       // "new conversation": Home Assistant forgot the earlier one (5 min)
}

//! The logic of the app: states, the conversation on screen, settings, timers, decisions. It knows
//! neither the screen nor how a request travels - the client, recorder and player are passed in,
//! so the tests can use fakes.
class Conversation {

    const CONNECTING_SHOW_MS = 500;      // "Connecting…" only when the check takes longer than this,
    const CONNECTING_MIN_MS = 1000;      // and then on screen at least this long - no flash
    const CONNECTING_CAP_MS = 10000;     // no answer: a connection error
    const NO_SPEECH_MS = 5000;           // from the first audio: nothing said -> "nothing heard"
    const LISTEN_CAP_MS = 25000;         // the integration closes at 20 s; this only guards the watch
    const MAX_FAILURES = 2;
    const GIVE_UP_EXIT_MS = 5000;
    const CONVERSATION_TIMEOUT_MS = 300000;  // Home Assistant's chat session: 5 minutes
    const HISTORY_SIZE = 6;
    const TICK_MS = 100;
    const PULSE_MS = 500;                // the START arc on an empty idle screen: a slow pulse
    const POPUP_MS = 1500;               // a confirmation; a problem stays until START or BACK

    var state as State = STATE_IDLE;
    var heard as String = "";
    var reply as String = "";
    var error as String = "";
    var popup as String = "";
    var connectingShown as Boolean = false;
    //! Idle with nothing in the conversation: the START arc pulses (ticks every PULSE_MS)
    var pulsing as Boolean = false;
    var tick as Number = 0;
    //! Counts the commands begun (and a cleared conversation): the view scrolls back to the latest
    var commandCount as Number = 0;
    //! Earlier entries, oldest first: [kind, command, reply, isError]
    var history as Array<Array> = [] as Array<Array>;

    private var _client as HaClient;
    private var _recorder as Recorder;
    private var _player as Player;
    private var _started as Boolean = false;
    private var _failures as Number = 0;
    private var _lastCommandAt as Number?;
    // The current command
    private var _session as String = "";
    private var _audio as ByteArray = []b;
    private var _sent as Number = 0;
    private var _chunkInFlight as Boolean = false;
    private var _finalPending as Boolean = false;
    private var _speech as Boolean = false;
    private var _textOnly as Boolean = false;
    private var _connectingShownAt as Number = 0;
    private var _pingResult as Result?;
    // Timers (watches limit how many may run): one for ticks and the popup, one for waits (pairing
    // shares it), one for closing on idle
    private var _tickTimer as Timer.Timer = new Timer.Timer();
    private var _waitTimer as Timer.Timer = new Timer.Timer();
    private var _animating as Boolean = false;
    private var _ticking as Boolean = false;
    private var _popupUntil as Number = 0;   // 0 = stays until dismissed

    var pairing as Pairing;
    var idle as IdleClose;

    function initialize(client as HaClient, recorder as Recorder, player as Player) {
        _client = client;
        _recorder = recorder;
        _player = player;
        pairing = new Pairing(client, _waitTimer, method(:onPaired));
        idle = new IdleClose(method(:onIdleWarning));
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
            beginPairing();
            return;
        }
        if (Settings.listenOnOpen()) {
            state = STATE_CONNECTING;
            connectingShown = false;
            _pingResult = null;
            waitThen(CONNECTING_SHOW_MS, method(:onConnectingSlow));
        } else {
            armIdleExit(Settings.idleExitMs());
        }
        _client.ping(method(:onPing));
    }

    function onPing(result as Result) as Void {
        if (state != STATE_CONNECTING) {
            // The check in the background (not listening on open), or one that came too late
            if (result.kind == RESULT_UNAUTHORIZED) {
                reconnect();
            }
            return;
        }
        _pingResult = result;
        var left = connectingShown ? CONNECTING_MIN_MS - (System.getTimer() - _connectingShownAt) : 0;
        if (left > 0) {
            waitThen(left, method(:onConnected));
        } else {
            onConnected();
        }
    }

    function onConnectingSlow() as Void {
        if (state != STATE_CONNECTING) {
            return;
        }
        connectingShown = true;
        _connectingShownAt = System.getTimer();
        waitThen(CONNECTING_CAP_MS, method(:onConnectingTimeout));
        WatchUi.requestUpdate();
    }

    function onConnectingTimeout() as Void {
        if (state == STATE_CONNECTING) {
            fail(Messages.describe(new Result(RESULT_TIMEOUT, 0, null)));
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

    //! Settings changed in Garmin Connect: "Reconnect" on, or a new address
    function onSettingsChanged() as Void {
        if (Settings.takeReconnect() || Settings.key() == null) {
            reconnect();
        }
        WatchUi.requestUpdate();
    }

    function shutdown() as Void {
        _waitTimer.stop();
        idle.stop();
        _tickTimer.stop();
        _recorder.stop();
        _player.stop();
    }

    // --- pairing ------------------------------------------------------------------------------

    private function reconnect() as Void {
        Settings.clearKey();
        stopCommand();
        pairing.notice = "";
        beginPairing();
    }

    private function beginPairing() as Void {
        state = STATE_PAIRING;
        error = "";
        idle.stop();
        stopPulse();
        pairing.begin();
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
        state = STATE_IDLE;
        buzz(BUZZ_REPLY);
        showPopup(Settings.text(Rez.Strings.PairDone), POPUP_MS);
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
        } else if (state == STATE_PLAYING) {
            _player.stop();
            listen();
        } else if (state == STATE_IDLE || state == STATE_ERROR) {
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
                || state == STATE_PLAYING) {
            stopCommand();
            state = STATE_IDLE;
            armIdleExit(Settings.idleExitMs());
            WatchUi.requestUpdate();
            return true;
        }
        return false;
    }

    //! UP / DOWN or a drag during the countdown only keeps the app open (true); otherwise the view
    //! scrolls the conversation
    function inputKeepsOpen() as Boolean {
        if (idle.countdown > 0) {
            keepOpen();
            return true;
        }
        return false;
    }

    //! Hold UP: "text only" on/off (also the setting in Garmin Connect)
    function toggleTextOnly() as Void {
        if (inputKeepsOpen()) {
            return;
        }
        if (!Capabilities.hasSpeaker()) {
            return;
        }
        var on = !Settings.textOnly();
        Settings.setTextOnly(on);
        if (on && state == STATE_PLAYING) {
            _player.stop();
            done();
        }
        showPopup(Settings.text(on ? Rez.Strings.ModeTextOnly : Rez.Strings.ModeVoiceText), POPUP_MS);
    }

    // --- a command ----------------------------------------------------------------------------

    function listen() as Void {
        idle.stop();
        stopPulse();
        _waitTimer.stop();
        keepCurrentInHistory();
        heard = "";
        reply = "";
        error = "";
        popup = "";
        commandCount++;
        _audio = []b;
        _sent = 0;
        _chunkInFlight = false;
        _finalPending = false;
        _speech = false;
        _textOnly = Settings.textOnly();
        _session = System.getTimer().format("%x") + Math.rand().format("%x");
        buzz(BUZZ_LISTEN);  // before the microphone opens - not in the recording
        if (!_recorder.start(method(:onAudioData), method(:onRecordingDone))) {
            fail(Settings.text(Rez.Strings.ErrMicStart));
            return;
        }
        state = STATE_LISTENING;
        startTicks();
        waitThen(LISTEN_CAP_MS, method(:finishListening));
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
        if (_audio.size() == 0) {
            waitThen(NO_SPEECH_MS, method(:onNoSpeech));
        }
        _audio.addAll(data);
        sendChunk(false);
    }

    function onRecordingDone(ok as Boolean) as Void {
        if (!ok && state == STATE_LISTENING) {
            fail(Settings.text(Rez.Strings.ErrMicStopped));
        }
    }

    //! START or the watch's own cap: the rest of the audio goes with "final". "Recognising" at once:
    //! the press shows, not only when the text comes back
    function finishListening() as Void {
        if (state != STATE_LISTENING) {
            return;
        }
        _recorder.stop();
        _finalPending = true;
        state = STATE_RECOGNIZING;
        WatchUi.requestUpdate();
        sendChunk(true);
    }

    //! One chunk request at a time; what comes meanwhile goes with the next one
    private function sendChunk(final as Boolean) as Void {
        if (!takingAudio() || _chunkInFlight) {
            return;
        }
        if (_audio.size() <= _sent && !final) {
            return;
        }
        var offset = _sent;
        _sent = _audio.size();
        _chunkInFlight = true;
        _client.sendChunk(_session, offset, _audio.slice(offset, _sent), _textOnly && offset == 0, final,
            method(:onChunk));
    }

    function onChunk(result as Result) as Void {
        _chunkInFlight = false;
        if (!takingAudio()) {
            return;
        }
        if (!result.ok()) {
            failRequest(result);
            return;
        }
        if (result.flag("speech")) {
            _speech = true;
        }
        var answer = result.text("state");
        if (answer.equals("heard")) {
            heard = result.text("heard");
            _recorder.stop();
            _waitTimer.stop();
            buzz(BUZZ_SENT);
            state = STATE_SENDING;
            _client.reply(_session, method(:onReply));
        } else if (answer.equals("nothing")) {
            notHeard();
        } else if (_finalPending) {
            sendChunk(true);
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

    function onReply(result as Result) as Void {
        if (state != STATE_SENDING) {
            return;
        }
        if (!result.ok()) {
            failRequest(result);
            return;
        }
        if (result.text("state").equals("waiting")) {
            _client.reply(_session, method(:onReply));
            return;
        }
        if (result.text("state").equals("nothing")) {
            notHeard();
            return;
        }
        _failures = 0;
        reply = result.text("reply");
        stopTicks();
        buzz(BUZZ_REPLY);
        WatchUi.requestUpdate();
        if (result.flag("audio") && !Settings.textOnly()) {
            _client.audio(_session, method(:onAudio));
        } else {
            done();
        }
    }

    function onAudio(result as Result) as Void {
        if (state != STATE_SENDING) {
            return;
        }
        if (result.kind == RESULT_UNAUTHORIZED) {
            // The watch was removed meanwhile: pair now, or the next START would open the
            // microphone only to be refused
            reconnect();
            return;
        }
        // Any other failure: the reply text is on screen already - only the voice is missing
        if (result.ok() && result.data instanceof ByteArray
                && _player.play(result.data as ByteArray, Settings.volume(), method(:onPlayed))) {
            state = STATE_PLAYING;
            WatchUi.requestUpdate();
        } else {
            done();
        }
    }

    function onPlayed() as Void {
        if (state == STATE_PLAYING) {
            done();
        }
    }

    private function stopCommand() as Void {
        _waitTimer.stop();
        _recorder.stop();
        _player.stop();
        stopTicks();
    }

    // --- endings ------------------------------------------------------------------------------

    private function done() as Void {
        state = STATE_IDLE;
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
        state = STATE_IDLE;
        // A popup, not a note in the conversation, where it would fall below the anchored command,
        // out of sight; it stays until START (which listens again) or BACK
        showPopup(Settings.text(Rez.Strings.NotHeard), 0);
        armIdleExit(Settings.idleExitMs());
        WatchUi.requestUpdate();
    }

    private function failRequest(result as Result) as Void {
        if (result.kind == RESULT_UNAUTHORIZED) {
            reconnect();
            return;
        }
        fail(Messages.describe(result));
    }

    //! After MAX_FAILURES in a row retrying will not help - give up
    private function fail(message as String) as Void {
        _failures++;
        stopCommand();
        buzz(BUZZ_ERROR);
        state = STATE_ERROR;
        if (_failures >= MAX_FAILURES) {
            error = message + " " + Settings.text(Rez.Strings.GiveUp);
            closeAfter(GIVE_UP_EXIT_MS);
        } else {
            error = message;
            armIdleExit(Settings.idleExitMs());
        }
        WatchUi.requestUpdate();
    }

    // --- timers -------------------------------------------------------------------------------

    private function waitThen(ms as Number, callback as Method() as Void) as Void {
        _waitTimer.stop();
        _waitTimer.start(callback, ms, false);
    }

    private function armIdleExit(ms as Number) as Void {
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
        armIdleExit(Settings.idleExitMs());
        WatchUi.requestUpdate();
    }

    private function closeAfter(ms as Number) as Void {
        idle.closeAfter(ms);
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

    //! The START arc pulses while the app waits for START: an empty conversation, "nothing heard",
    //! an error; it shines steadily where START only may be pressed
    function waitingForStart() as Boolean {
        return (state == STATE_IDLE && (isEmpty() || (popup.length() > 0 && _popupUntil == 0)))
            || state == STATE_ERROR;
    }

    private function updatePulse() as Void {
        if (waitingForStart()) {
            startPulse();
        } else {
            stopPulse();
        }
    }

    private function startPulse() as Void {
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
            if (popup.length() > 0 && _popupUntil > 0) {
                runTicks();  // a timed popup still has to go
            }
        }
    }

    private function startTicks() as Void {
        tick = 0;
        _animating = true;
        runTicks();
    }

    private function stopTicks() as Void {
        _animating = false;
        if (popup.length() == 0 || _popupUntil == 0) {
            _tickTimer.stop();
            _ticking = false;
        }
    }

    private function runTicks() as Void {
        if (!_ticking) {
            _ticking = true;
            _tickTimer.start(method(:onTick), TICK_MS, true);
        }
    }

    function onTick() as Void {
        tick++;
        if (popup.length() > 0 && _popupUntil > 0 && System.getTimer() >= _popupUntil) {
            popup = "";
            if (!_animating) {
                _tickTimer.stop();
                _ticking = false;
                if (pulsing) {
                    // The popup ran the fast ticks; the pulse goes on at its own pace
                    _ticking = true;
                    _tickTimer.start(method(:onTick), PULSE_MS, true);
                }
            }
        }
        WatchUi.requestUpdate();
    }

    //! A small framed note in the middle for `ms`, or until dismissed when `ms` is 0
    private function showPopup(text as String, ms as Number) as Void {
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
