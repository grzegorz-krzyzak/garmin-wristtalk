import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.Test;
import Toybox.WatchUi;

//! Unit tests of the logic (Run No Evil): fakes of the connection, the microphone and the speaker.
//! Built only with --unit-test (test.jungle), never in a device build.

(:test)
class FakeClient extends HaClient {

    var calls as Array<String> = [] as Array<String>;
    var last as Method(result as Result) as Void or Null;
    var lastChunk as Array = [];

    function initialize() {
        HaClient.initialize("test");
    }

    function pair(info as Dictionary<Object, Object>, done as Method(result as Result) as Void) as Void {
        calls.add("pair");
        last = done;
    }

    function pollPairing(pairId as String, done as Method(result as Result) as Void) as Void {
        calls.add("poll:" + pairId);
        last = done;
    }

    function ping(done as Method(result as Result) as Void) as Void {
        calls.add("ping");
        last = done;
    }

    function sendChunk(session as String, offset as Number, audio as ByteArray, textOnly as Boolean,
            final as Boolean, done as Method(result as Result) as Void) as Void {
        calls.add("chunk");
        lastChunk = [offset, audio.size(), textOnly, final];
        last = done;
    }

    function reply(session as String, done as Method(result as Result) as Void) as Void {
        calls.add("reply");
        last = done;
    }

    function audio(session as String, done as Method(result as Result) as Void) as Void {
        calls.add("audio");
        last = done;
    }

    function answer(kind as ResultKind, code as Number, data as Dictionary or ByteArray or Null) as Void {
        var done = last;
        last = null;
        (done as Method(result as Result) as Void).invoke(new Result(kind, code, data));
    }
}

(:test)
class FakeRecorder extends Recorder {

    var started as Boolean = false;

    function initialize() {
        Recorder.initialize();
    }

    function start(onData as Method(data as ByteArray) as Void, onDone as Method(ok as Boolean) as Void) as Boolean {
        started = true;
        return true;
    }

    function stop() as Void {
        started = false;
    }
}

(:test)
class FakePlayer extends Player {

    var played as Number = 0;

    function initialize() {
        Player.initialize();
    }

    function play(data as ByteArray, volume as Number, onDone as Method() as Void) as Boolean {
        played = data.size();
        return true;
    }

    function stop() as Void {
    }
}

(:test)
module ConversationTests {

    // What the dev build keeps in the simulator (pairing with the house, settings): saved before
    // a test and put back after it, so a test run does not unpair the app
    const STORAGE_KEYS = ["key", "pairedUrl"];
    const PROPERTY_KEYS = ["houseUrl", "replyMode", "afterReply", "listenOnOpen"];
    var saved as Array = [];

    function setUp(paired as Boolean) as Array {
        saved = [];
        for (var i = 0; i < STORAGE_KEYS.size(); i++) {
            saved.add(Application.Storage.getValue(STORAGE_KEYS[i]));
        }
        for (var i = 0; i < PROPERTY_KEYS.size(); i++) {
            saved.add(Application.Properties.getValue(PROPERTY_KEYS[i]));
        }
        Application.Properties.setValue("houseUrl", "https://home.example.org");
        Application.Properties.setValue("replyMode", 0);
        Application.Properties.setValue("afterReply", 0);
        Application.Properties.setValue("listenOnOpen", true);
        Settings.clearKey();
        if (paired) {
            Settings.setKey("k1");
        }
        var client = new FakeClient();
        var recorder = new FakeRecorder();
        var player = new FakePlayer();
        return [new Conversation(client, recorder, player), client, recorder, player];
    }

    //! Open the app and let Home Assistant accept the key at once
    function open(c as Conversation, client as FakeClient) as Void {
        c.startOnce();
        client.answer(RESULT_OK, 200, {});
    }

    //! The tests share the simulator's app storage with the dev build: put back what was there
    function tearDown(c as Conversation) as Void {
        c.shutdown();
        for (var i = 0; i < STORAGE_KEYS.size(); i++) {
            var value = saved[i];
            if (value == null) {
                Application.Storage.deleteValue(STORAGE_KEYS[i]);
            } else {
                Application.Storage.setValue(STORAGE_KEYS[i], value as Application.PropertyValueType);
            }
        }
        for (var i = 0; i < PROPERTY_KEYS.size(); i++) {
            var value = saved[STORAGE_KEYS.size() + i];
            if (value != null) {
                Application.Properties.setValue(PROPERTY_KEYS[i], value as Application.PropertyValueType);
            }
        }
    }
}

(:test)
function pairingShowsTheCodeAndStoresTheKey(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(false);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    c.startOnce();
    Test.assertEqual(c.state, STATE_PAIRING);
    Test.assertEqual(client.calls[0], "pair");
    client.answer(RESULT_OK, 200, { "pair_id" => "p1", "code" => "482913" });
    Test.assertEqual(c.pairing.code, "482913");
    c.pairing.poll();
    client.answer(RESULT_OK, 200, { "state" => "pending" });
    Test.assertEqual(c.state, STATE_PAIRING);
    c.pairing.poll();
    client.answer(RESULT_OK, 200, { "state" => "paired", "key" => "secret" });
    Test.assertEqual(c.state, STATE_IDLE);
    Test.assertEqual(Settings.key(), "secret");
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.PairDone));
    Test.assert(c.isEmpty() && c.pulsing);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aLostConnectionKeepsThePairingCode(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(false);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    c.startOnce();
    client.answer(RESULT_OK, 200, { "pair_id" => "p1", "code" => "482913" });
    c.pairing.poll();
    client.answer(RESULT_NO_PHONE, -104, null);
    Test.assertEqual(c.pairing.code, "482913");
    // The owner confirmed meanwhile: the next poll still gets the key
    c.pairing.poll();
    Test.assertEqual(client.calls[client.calls.size() - 1], "poll:p1");
    client.answer(RESULT_OK, 200, { "state" => "paired", "key" => "secret" });
    Test.assertEqual(c.state, STATE_IDLE);
    ConversationTests.tearDown(c);
    // An expired pairing starts over
    t = ConversationTests.setUp(false);
    c = t[0] as Conversation;
    client = t[1] as FakeClient;
    c.startOnce();
    client.answer(RESULT_OK, 200, { "pair_id" => "p1", "code" => "482913" });
    c.pairing.poll();
    client.answer(RESULT_EXPIRED, 410, null);
    Test.assertEqual(c.pairing.code, "");
    Test.assertEqual(client.calls[client.calls.size() - 1], "pair");
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function pairingWaitsForAddWatchInHomeAssistant(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(false);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    c.startOnce();
    client.answer(RESULT_PAIRING_CLOSED, 403, { "error" => "pairing_closed" });
    Test.assertEqual(c.state, STATE_PAIRING);
    Test.assertEqual(c.pairing.notice, Settings.text(Rez.Strings.PairOpenInHa));
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function noAddressAsksForTheSetting(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(false);
    Application.Properties.setValue("houseUrl", "");
    var c = t[0] as Conversation;
    c.startOnce();
    Test.assertEqual(c.pairing.notice, Settings.text(Rez.Strings.PairNoAddress));
    Test.assertEqual((t[1] as FakeClient).calls.size(), 0);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aCommandFromAudioToTheSpokenReply(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var player = t[3] as FakePlayer;
    ConversationTests.open(c, client);
    Test.assertEqual(c.state, STATE_LISTENING);
    Test.assert((t[2] as FakeRecorder).started);
    c.onAudioData([1, 2, 3]b);
    Test.assertEqual(client.lastChunk[0], 0);
    client.answer(RESULT_OK, 200, { "state" => "listening", "speech" => true });
    c.onAudioData([4, 5]b);
    Test.assertEqual(client.lastChunk[0], 3);
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "Która jest godzina?" });
    Test.assertEqual(c.heard, "Która jest godzina?");
    Test.assertEqual(c.state, STATE_SENDING);
    client.answer(RESULT_OK, 200, { "state" => "waiting" });
    Test.assertEqual(client.calls[client.calls.size() - 1], "reply");
    client.answer(RESULT_OK, 200, { "reply" => "Jest 21:37.", "audio" => true });
    Test.assertEqual(c.reply, "Jest 21:37.");
    client.answer(RESULT_OK, 200, [9, 9, 9, 9]b);
    Test.assertEqual(player.played, 4);
    Test.assertEqual(c.state, STATE_PLAYING);
    c.onPlayed();
    Test.assertEqual(c.state, STATE_IDLE);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function startEndsTheCommandWithFinal(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1, 2, 3]b);
    client.answer(RESULT_OK, 200, { "state" => "listening", "speech" => true });
    c.onSelect();
    Test.assertEqual(c.state, STATE_RECOGNIZING);
    Test.assertEqual(client.lastChunk[3], true);
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "x" });
    Test.assertEqual(c.state, STATE_SENDING);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function textOnlyAsksNoAudio(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    Settings.setTextOnly(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    Test.assertEqual(client.lastChunk[2], true);
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "x" });
    client.answer(RESULT_OK, 200, { "reply" => "y", "audio" => true });
    Test.assertEqual(client.calls.indexOf("audio"), -1);
    Test.assertEqual(c.state, STATE_IDLE);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aRejectedKeyPairsAgain(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_UNAUTHORIZED, 401, { "error" => "unauthorized" });
    Test.assertEqual(c.state, STATE_PAIRING);
    Test.assert(Settings.key() == null);
    Test.assertEqual(client.calls[client.calls.size() - 1], "pair");
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aRemovedWatchPairsWithoutListening(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    c.startOnce();
    Test.assertEqual(c.state, STATE_CONNECTING);
    Test.assert(!c.connectingShown);
    client.answer(RESULT_UNAUTHORIZED, 401, { "error" => "unauthorized" });
    Test.assertEqual(c.state, STATE_PAIRING);
    Test.assert(!(t[2] as FakeRecorder).started);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aKeyRevokedWhileThinkingOrBeforeTheVoicePairs(logger as Test.Logger) as Boolean {
    // Revoked while the agent thinks: the reply poll is refused
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "a" });
    client.answer(RESULT_UNAUTHORIZED, 401, null);
    Test.assertEqual(c.state, STATE_PAIRING);
    ConversationTests.tearDown(c);
    // Revoked after the reply text, before its audio
    t = ConversationTests.setUp(true);
    c = t[0] as Conversation;
    client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "a" });
    client.answer(RESULT_OK, 200, { "reply" => "b", "audio" => true });
    client.answer(RESULT_UNAUTHORIZED, 401, null);
    Test.assertEqual(c.state, STATE_PAIRING);
    Test.assertEqual((t[3] as FakePlayer).played, 0);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function pairingAgainClearsTheConversation(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "a" });
    client.answer(RESULT_OK, 200, { "reply" => "b", "audio" => false });
    c.onSelect();
    Test.assertEqual(c.history.size(), 1);
    // The watch removed in Home Assistant: refused, paired again
    c.onAudioData([1]b);
    client.answer(RESULT_UNAUTHORIZED, 401, null);
    client.answer(RESULT_OK, 200, { "pair_id" => "p1", "code" => "482913" });
    c.pairing.poll();
    client.answer(RESULT_OK, 200, { "state" => "paired", "key" => "k2" });
    Test.assert(c.isEmpty());
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function nothingHeardIsANoteNotAFailure(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_OK, 200, { "state" => "nothing" });
    Test.assertEqual(c.state, STATE_IDLE);
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.NotHeard));
    Test.assertEqual(c.pairing.notice, "");
    Test.assert(c.waitingForStart() && c.pulsing);
    // BACK closes only the popup, the app stays
    Test.assert(c.onBack());
    Test.assertEqual(c.popup, "");
    // One connection error after it still asks again (the note did not count as a failure)
    c.onSelect();
    c.onAudioData([1]b);
    client.answer(RESULT_NO_PHONE, -104, null);
    Test.assertEqual(c.error, Settings.text(Rez.Strings.ErrNoPhone));
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function startDismissesThePopupAndListens(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_OK, 200, { "state" => "nothing" });
    Test.assert(c.popup.length() > 0);
    c.onSelect();
    Test.assertEqual(c.popup, "");
    Test.assertEqual(c.state, STATE_LISTENING);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function startKeepsTheAppOpenDuringTheCountdown(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    Application.Properties.setValue("listenOnOpen", false);
    var c = t[0] as Conversation;
    c.startOnce();
    c.idle.onWarning();
    Test.assertEqual(c.idle.countdown, 10);
    c.idle.onCountdown();
    Test.assertEqual(c.idle.countdown, 9);
    // START only stops the countdown - it does not start listening
    c.onSelect();
    Test.assertEqual(c.idle.countdown, 0);
    Test.assertEqual(c.state, STATE_IDLE);
    // BACK during the countdown closes the app (the default action)
    c.idle.onWarning();
    Test.assert(!c.onBack());
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function anEmptyIdleScreenPulsesUntilStart(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    Application.Properties.setValue("listenOnOpen", false);
    var c = t[0] as Conversation;
    c.startOnce();
    Test.assert(c.isEmpty());
    Test.assert(c.pulsing);
    c.onSelect();
    Test.assert(!c.pulsing);
    Test.assertEqual(c.state, STATE_LISTENING);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function twoConnectionErrorsGiveUp(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_NO_PHONE, -104, null);
    c.onSelect();
    c.onAudioData([1]b);
    client.answer(RESULT_NO_PHONE, -104, null);
    Test.assertEqual(c.error, Settings.text(Rez.Strings.ErrNoPhone) + " " + Settings.text(Rez.Strings.GiveUp));
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function historyKeepsTheEarlierExchange(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "a" });
    client.answer(RESULT_OK, 200, { "reply" => "b", "audio" => false });
    c.onSelect();
    Test.assertEqual(c.history.size(), 1);
    Test.assertEqual(c.history[0][1], "a");
    Test.assertEqual(c.history[0][2], "b");
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function protocolErrorsAreClassified(logger as Test.Logger) as Boolean {
    Test.assertEqual(HaClient.classify(200, null), RESULT_OK);
    Test.assertEqual(HaClient.classify(401, null), RESULT_UNAUTHORIZED);
    Test.assertEqual(HaClient.classify(426, null), RESULT_UPDATE_APP);
    Test.assertEqual(HaClient.classify(501, null), RESULT_UPDATE_INTEGRATION);
    Test.assertEqual(HaClient.classify(424, null), RESULT_STT_FAILED);
    Test.assertEqual(HaClient.classify(503, null), RESULT_SERVER);
    Test.assertEqual(HaClient.classify(-1001, null), RESULT_HTTPS);
    Test.assertEqual(HaClient.classify(-104, null), RESULT_NO_PHONE);
    return true;
}

(:test)
function aTapDoesNotStartOnlyTheStartButtonDoes(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    Application.Properties.setValue("listenOnOpen", false);
    var c = t[0] as Conversation;
    var delegate = new AssistDelegate(c, new Scroller());
    c.startOnce();
    // A tap on the screen arrives as a select without a key pressed before it
    delegate.onSelect();
    Test.assertEqual(c.state, STATE_IDLE);
    // START: the key press comes first, then the select
    delegate.onKeyPressed(new WatchUi.KeyEvent(WatchUi.KEY_ENTER, WatchUi.PRESS_TYPE_DOWN));
    delegate.onSelect();
    Test.assertEqual(c.state, STATE_LISTENING);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function theScrollerGlidesAndStopsAtTheEnd(logger as Test.Logger) as Boolean {
    var s = new Scroller();
    s.lineHeight = 20;
    s.lines(2);
    Test.assertEqual(s.scroll, -40);
    s.drag(15);
    Test.assertEqual(s.scroll, -25);
    // A glide moves on and slows down
    s.glide(1000.0);
    var now = System.getTimer();
    Test.assert(s.advance(now + 100));
    Test.assert(s.scroll > -25);
    Test.assert(s.gliding());
    // The end of the conversation stops it where the conversation allows
    s.limitTo(30);
    Test.assertEqual(s.scroll, 30);
    Test.assert(!s.gliding());
    // A slow glide stops by itself
    s.glide(30.0);
    Test.assert(!s.advance(System.getTimer() + 100));
    s.reset();
    Test.assertEqual(s.scroll, 0);
    return true;
}
