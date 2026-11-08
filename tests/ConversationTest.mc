import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Test;
import Toybox.WatchUi;

//! Unit tests of the logic (Run No Evil): fakes of the connection, the microphone and the speaker.
//! Built only with --unit-test (test.jungle), never in a device build.

(:test)
class FakeClient extends HaClient {

    var calls as Array<String> = [] as Array<String>;
    //! The callbacks of the requests not answered yet, oldest first
    var pending as Array<Method(result as Result) as Void> = [] as Array<Method(result as Result) as Void>;
    var lastChunk as Array = [];

    function initialize() {
        HaClient.initialize("test");
    }

    function pair(info as Dictionary<Object, Object>, done as Method(result as Result) as Void) as Void {
        calls.add("pair");
        pending.add(done);
    }

    function pollPairing(pairId as String, done as Method(result as Result) as Void) as Void {
        calls.add("poll:" + pairId);
        pending.add(done);
    }

    function ping(done as Method(result as Result) as Void) as Void {
        calls.add("ping");
        pending.add(done);
    }

    function repair(done as Method(result as Result) as Void) as Void {
        calls.add("repair:" + Settings.key());
        pending.add(done);
    }

    function sendChunk(session as String, offset as Number, audio as ByteArray, textOnly as Boolean,
            final as Boolean, done as Method(result as Result) as Void) as Void {
        calls.add("chunk");
        lastChunk = [offset, audio.size(), textOnly, final];
        pending.add(done);
    }

    function reply(session as String, done as Method(result as Result) as Void) as Void {
        calls.add("reply");
        pending.add(done);
    }

    function audio(session as String, done as Method(result as Result) as Void) as Void {
        calls.add("audio");
        pending.add(done);
    }

    function answer(kind as ResultKind, code as Number, data as Dictionary or ByteArray or Null) as Void {
        var done = pending[0];
        pending = pending.slice(1, null);
        done.invoke(new Result(kind, code, data));
    }
}

(:test)
class FakeRecorder extends Recorder {

    var started as Boolean = false;
    //! What the microphone still holds when it is stopped (handed over on stop, as on the watch)
    var rest as ByteArray = []b;
    private var _onData as Method(data as ByteArray) as Void or Null;
    private var _onDone as Method(ok as Boolean) as Void or Null;
    //! false: the microphone does not report its end (the app falls back after a moment)
    var reportsDone as Boolean = true;

    function initialize() {
        Recorder.initialize();
    }

    function start(onData as Method(data as ByteArray) as Void, onDone as Method(ok as Boolean) as Void) as Boolean {
        started = true;
        _onData = onData;
        _onDone = onDone;
        return true;
    }

    //! As on the watch: what the microphone still holds comes after the stop, then its end
    function stop() as Void {
        var wasStarted = started;
        started = false;
        if (wasStarted && rest.size() > 0) {
            (_onData as Method(data as ByteArray) as Void).invoke(rest);
            rest = []b;
        }
        if (wasStarted && reportsDone) {
            (_onDone as Method(ok as Boolean) as Void).invoke(true);
        }
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
    const STORAGE_KEYS = ["key", "pairedUrl", "pairId", "pairCode", "pairUrl"];
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
        Settings.clearPairingInProgress();
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
    c.onKeyReread();  // no key at the second read either
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
    // The proof for Home Assistant: the first request signed with the new key
    Test.assertEqual(client.calls[client.calls.size() - 1], "ping");
    Test.assert(Settings.pairingInProgress() == null);
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
    c.onKeyReread();  // no key at the second read either
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
    c.onKeyReread();
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
    c.onKeyReread();  // no key at the second read either
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
    c.onKeyReread();  // no key at the second read either
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
function pairAgainTellsHomeAssistantThenShowsACode(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    Test.assert(c.canPairAgain());
    // Asked under the YES / NO (it covers the app), answered yes: the pairing's long limit, not the
    // idle time of the setting
    c.onCovered();
    c.pairAgain();
    c.onUncovered();
    Test.assert(!c.idle.armed);
    // Told with the key, before the key goes
    Test.assert(client.calls.indexOf("repair:k1") >= 0);
    Test.assertEqual(client.calls[client.calls.size() - 1], "pair");
    Test.assertEqual(c.state, STATE_PAIRING);
    Test.assert(Settings.key() == null);
    Test.assert(!c.canPairAgain());
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function textOnlyFromTheMenuShowsNoPopup(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    ConversationTests.open(c, t[1] as FakeClient);
    c.setTextOnly(true);
    Test.assert(Settings.textOnly());
    Test.assertEqual(c.popup, "");
    c.setTextOnly(false);
    Test.assert(!Settings.textOnly());
    Test.assertEqual(c.popup, "");
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function theMenuStopsTheIdleTimeUntilTheAppShowsAgain(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    Application.Properties.setValue("listenOnOpen", false);
    var c = t[0] as Conversation;
    ConversationTests.open(c, t[1] as FakeClient);
    Test.assert(c.idle.armed);
    c.onCovered();
    Test.assert(!c.idle.armed);
    Test.assertEqual(c.idle.countdown, 0);
    c.onUncovered();
    Test.assert(c.idle.armed);
    // Covered while nothing counted (a command running): nothing starts afterwards
    c.idle.stop();
    c.onCovered();
    c.onUncovered();
    Test.assert(!c.idle.armed);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function theMenuEndsListeningQuietly(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var recorder = t[2] as FakeRecorder;
    ConversationTests.open(c, t[1] as FakeClient);
    Test.assertEqual(c.state, STATE_LISTENING);
    c.onCovered();
    Test.assertEqual(c.state, STATE_IDLE);
    Test.assert(!recorder.started);
    Test.assertEqual(c.popup, "");
    Test.assert(!c.idle.armed);
    c.onUncovered();
    Test.assert(c.idle.armed);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function nothingStartsListeningUnderTheMenu(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    c.startOnce();
    Test.assertEqual(c.state, STATE_CONNECTING);
    c.onCovered();
    client.answer(RESULT_OK, 200, {});
    Test.assertEqual(c.state, STATE_IDLE);
    Test.assert(!(t[2] as FakeRecorder).started);
    Test.assert(!c.idle.armed);
    c.onUncovered();
    Test.assert(c.idle.armed);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function pairingHasNoIdleTime(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(false);
    var c = t[0] as Conversation;
    c.startOnce();
    c.onKeyReread();  // no key at the second read either
    Test.assertEqual(c.state, STATE_PAIRING);
    Test.assert(!c.idle.armed);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aKeptPairingCollectsTheKeyAfterTheAppOpensAgain(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(false);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    c.startOnce();
    c.onKeyReread();  // no key at the second read either
    client.answer(RESULT_OK, 200, { "pair_id" => "p1", "code" => "482913" });
    // The app closes (BACK); the code is typed in Home Assistant; the app opens again
    c.shutdown();
    var client2 = new FakeClient();
    var c2 = new Conversation(client2, new FakeRecorder(), new FakePlayer());
    c2.startOnce();
    c2.onKeyReread();
    Test.assertEqual(client2.calls[0], "poll:p1");
    Test.assertEqual(c2.pairing.code, "482913");
    client2.answer(RESULT_OK, 200, { "state" => "paired", "key" => "secret" });
    Test.assertEqual(Settings.key(), "secret");
    Test.assertEqual(client2.calls[client2.calls.size() - 1], "ping");
    ConversationTests.tearDown(c2);
    return true;
}

(:test)
function aKeptPairingThatEndedStartsANewOne(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(false);
    Settings.setPairingInProgress("old", "111111");
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    c.startOnce();
    c.onKeyReread();  // no key at the second read either
    Test.assertEqual(client.calls[0], "poll:old");
    client.answer(RESULT_EXPIRED, 410, null);
    Test.assert(Settings.pairingInProgress() == null);
    Test.assertEqual(client.calls[client.calls.size() - 1], "pair");
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function nothingAsksTheHouseInTheBackground(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(false);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    c.startOnce();
    c.onKeyReread();  // no key at the second read either
    client.answer(RESULT_OK, 200, { "pair_id" => "p1", "code" => "482913" });
    c.onBackground();
    var before = client.calls.size();
    c.pairing.poll();
    Test.assertEqual(client.calls.size(), before);
    // Back: the same pairing goes on
    c.onForeground();
    Test.assertEqual(client.calls[client.calls.size() - 1], "poll:p1");
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function theBackgroundEndsListeningQuietly(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    ConversationTests.open(c, t[1] as FakeClient);
    Test.assertEqual(c.state, STATE_LISTENING);
    c.onBackground();
    Test.assertEqual(c.state, STATE_IDLE);
    Test.assertEqual(c.popup, "");
    // The idle time runs on in the background: the app closes there too
    Test.assert(c.idle.armed);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function anUnpairedWatchHasNoPairAgain(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(false);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    c.startOnce();
    c.onKeyReread();  // no key at the second read either
    Test.assert(!c.canPairAgain());
    c.pairAgain();
    Test.assertEqual(client.calls.indexOf("repair:null"), -1);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
class ResultBox {
    var kind as ResultKind? = null;

    function initialize() {
    }

    function done(result as Result) as Void {
        kind = result.kind;
    }
}

(:test)
function anHttpAddressSendsNothing(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    Application.Properties.setValue("houseUrl", "http://home.example.org");
    var box = new ResultBox();
    new HaClient("test").ping(box.method(:done));
    Test.assertEqual(box.kind, RESULT_HTTPS);
    ConversationTests.tearDown(t[0] as Conversation);
    return true;
}

(:test)
function aRemovedWatchPairsWithoutListening(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    c.startOnce();
    Test.assertEqual(c.state, STATE_CONNECTING);
    Test.assert(!c.shown.revealed);
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
function errorsInARowKeepTheAppOpen(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_NO_PHONE, -104, null);
    c.onSelect();
    c.onAudioData([1]b);
    client.answer(RESULT_NO_PHONE, -104, null);
    Test.assertEqual(c.error, Settings.text(Rez.Strings.ErrNoPhone));
    Test.assertEqual(c.errorHint, Settings.text(Rez.Strings.StartToRetry));
    // START still tries again
    c.onSelect();
    Test.assertEqual(c.state, STATE_LISTENING);
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

(:test)
function theRestOfTheRecordingStaysOnTheWatchAfterHeard(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var recorder = t[2] as FakeRecorder;
    ConversationTests.open(c, client);
    c.onAudioData([1, 2, 3]b);
    recorder.rest = [4, 5, 6, 7]b;
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "a" });
    Test.assertEqual(c.state, STATE_SENDING);
    // Only the reply poll went out after "heard", no chunk with the rest
    Test.assertEqual(client.calls[client.calls.size() - 1], "reply");
    Test.assertEqual(client.calls.indexOf("chunk"), client.calls.size() - 2);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function twoChunksTravelAtOnceAndFinalDoesNotWaitForThem(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1, 2]b);
    c.onAudioData([3, 4]b);
    Test.assertEqual(client.pending.size(), 2);
    Test.assertEqual(client.lastChunk[0], 2);
    // A third waits for one of them
    c.onAudioData([5]b);
    Test.assertEqual(client.pending.size(), 2);
    // START: "final" takes the rest at once, past the two on the way (protocol 4)
    c.onSelect();
    Test.assertEqual(c.state, STATE_RECOGNIZING);
    Test.assertEqual(client.pending.size(), 3);
    // Arrays compare by reference in Monkey C: field by field
    Test.assertEqual(client.lastChunk[0], 4);
    Test.assertEqual(client.lastChunk[1], 1);
    Test.assertEqual(client.lastChunk[3], true);
    // The answers to the earlier chunks send no second "final"
    client.answer(RESULT_OK, 200, { "state" => "listening", "speech" => true });
    client.answer(RESULT_OK, 200, { "state" => "listening", "speech" => true });
    Test.assertEqual(client.pending.size(), 1);
    Test.assertEqual(client.calls.size(), 4);  // ping, two chunks, final
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "a" });
    Test.assertEqual(c.state, STATE_SENDING);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aChunkLostAfterFinalIsSentAgain(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1, 2]b);
    c.onSelect();
    Test.assertEqual(client.pending.size(), 2);
    Test.assertEqual(client.lastChunk[3], true);
    // The chunk before "final" is lost on the way: it goes again, "final" stays on its way
    client.answer(RESULT_TIMEOUT, -2, null);
    Test.assertEqual(client.calls[client.calls.size() - 1], "chunk");
    Test.assertEqual(client.lastChunk[0], 0);
    Test.assertEqual(client.lastChunk[3], false);
    Test.assertEqual(client.pending.size(), 2);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function scrollingRestartsTheIdleTime(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    Application.Properties.setValue("listenOnOpen", false);
    var c = t[0] as Conversation;
    c.startOnce();
    c.idle.armedAt = 0;
    Test.assert(!c.onScrollInput());
    Test.assert(c.idle.armedAt > 0);
    // During the countdown a scroll only keeps the app open
    c.idle.onWarning();
    Test.assert(c.onScrollInput());
    Test.assertEqual(c.idle.countdown, 0);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function onlyATimeoutIsSentAgainAndOnce(logger as Test.Logger) as Boolean {
    Test.assert(PendingRequest.shouldRetry(Communications.NETWORK_REQUEST_TIMED_OUT, 1));
    Test.assert(!PendingRequest.shouldRetry(Communications.NETWORK_REQUEST_TIMED_OUT, 0));
    Test.assert(!PendingRequest.shouldRetry(Communications.BLE_CONNECTION_UNAVAILABLE, 1));
    Test.assert(!PendingRequest.shouldRetry(401, 1));
    return true;
}

(:test)
function theVoiceIsAskedForAgainWhileItIsMade(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "a" });
    client.answer(RESULT_OK, 200, { "reply" => "b", "audio" => true });
    client.answer(RESULT_WAITING, 202, null);
    Test.assertEqual(client.calls[client.calls.size() - 1], "audio");
    Test.assertEqual(c.state, STATE_LOADING_VOICE);
    client.answer(RESULT_OK, 200, [9, 9]b);
    Test.assertEqual(c.state, STATE_PLAYING);
    Test.assertEqual(HaClient.classify(202, null), RESULT_WAITING);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aLostChunkIsSentAgain(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1, 2]b);
    // Lost on the phone (code 0): the same chunk again, the command goes on
    client.answer(RESULT_ERROR, 0, null);
    Test.assertEqual(c.state, STATE_LISTENING);
    Test.assertEqual(client.lastChunk[0], 0);
    Test.assertEqual(client.lastChunk[1], 2);
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "a" });
    Test.assertEqual(c.state, STATE_SENDING);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aChunkLostThreeTimesIsAConnectionError(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_ERROR, 0, null);
    client.answer(RESULT_TIMEOUT, -300, null);
    Test.assertEqual(c.state, STATE_LISTENING);
    client.answer(RESULT_ERROR, 0, null);
    Test.assertEqual(c.state, STATE_ERROR);
    Test.assertEqual(c.error, Lang.format(Settings.text(Rez.Strings.ErrConnection), [0]));
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aChunkWithoutAnAnswerIsSentAgainAndItsLateAnswerIgnored(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1, 2, 3]b);
    var chunks = client.calls.size();
    c.checkChunks(System.getTimer() + 5000);
    Test.assertEqual(client.calls.size(), chunks);
    // No answer for more than 10 s: counted as lost, the same chunk again
    c.checkChunks(System.getTimer() + 11000);
    Test.assertEqual(client.calls.size(), chunks + 1);
    Test.assertEqual(client.lastChunk[0], 0);
    // The first try answers late: ignored; the new try's answer counts
    client.answer(RESULT_OK, 200, { "state" => "nothing" });
    Test.assertEqual(c.state, STATE_LISTENING);
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "a" });
    Test.assertEqual(c.state, STATE_SENDING);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function startSendsFinalWithTheLastWords(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var recorder = t[2] as FakeRecorder;
    ConversationTests.open(c, client);
    c.onAudioData([1, 2]b);
    client.answer(RESULT_OK, 200, { "state" => "listening", "speech" => true });
    // START while the microphone still holds the last word
    recorder.rest = [3, 4, 5]b;
    c.onSelect();
    Test.assertEqual(c.state, STATE_RECOGNIZING);
    // The rest went on its way first; "final" follows once nothing else is on the way
    client.answer(RESULT_OK, 200, { "state" => "listening", "speech" => true });
    Test.assertEqual(client.lastChunk[3], true);
    var sent = client.lastChunk[0] + client.lastChunk[1];
    Test.assertEqual(sent, 5);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function finalGoesEvenWhenTheMicrophoneDoesNotReportItsEnd(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var recorder = t[2] as FakeRecorder;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_OK, 200, { "state" => "listening", "speech" => true });
    recorder.reportsDone = false;
    var calls = client.calls.size();
    c.onSelect();
    Test.assertEqual(client.calls.size(), calls);
    // After REST_WAIT_MS (the timer, called here)
    c.sendFinal();
    Test.assertEqual(client.lastChunk[3], true);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function loadingVoiceOnlyWhenTheVoiceComes(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "a" });
    Test.assertEqual(c.state, STATE_SENDING);
    client.answer(RESULT_OK, 200, { "reply" => "b", "audio" => true });
    Test.assertEqual(c.state, STATE_LOADING_VOICE);
    // START while the voice is on its way: the next command
    c.onSelect();
    Test.assertEqual(c.state, STATE_LISTENING);
    // The voice of the earlier reply answers late: ignored
    client.answer(RESULT_OK, 200, [9]b);
    Test.assertEqual(c.state, STATE_LISTENING);
    // No audio from Home Assistant: straight to idle, no "loading voice"
    c.onAudioData([1]b);
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "c" });
    client.answer(RESULT_OK, 200, { "reply" => "d", "audio" => false });
    Test.assertEqual(c.state, STATE_IDLE);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function anErrorSaysWhetherStartHelps(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_NO_PHONE, -104, null);
    Test.assertEqual(c.errorHint, Settings.text(Rez.Strings.StartToRetry));
    ConversationTests.tearDown(c);
    t = ConversationTests.setUp(true);
    c = t[0] as Conversation;
    client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_UPDATE_INTEGRATION, 501, null);
    Test.assertEqual(c.error, Settings.text(Rez.Strings.ErrUpdateIntegration));
    Test.assertEqual(c.errorHint, "");
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function theHttpsStartOfTheAddressIsNoAddressYet(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(false);
    Application.Properties.setValue("houseUrl", "https://");
    var c = t[0] as Conversation;
    c.startOnce();
    c.onKeyReread();  // no key at the second read either
    Test.assertEqual(c.pairing.notice, Settings.text(Rez.Strings.PairNoAddress));
    Test.assertEqual((t[1] as FakeClient).calls.size(), 0);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aKeyFoundAtTheSecondReadStartsAsUsual(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(false);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    c.startOnce();
    // Nothing yet: no pairing, no request, nothing on screen
    Test.assertEqual(c.state, STATE_CONNECTING);
    Test.assert(!c.shown.revealed);
    Test.assertEqual(client.calls.size(), 0);
    Settings.setKey("k1");
    c.onKeyReread();
    Test.assertEqual(c.state, STATE_CONNECTING);
    Test.assertEqual(client.calls[0], "ping");
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function noKeyAtTheSecondReadPairs(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(false);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    c.startOnce();
    Test.assertEqual(client.calls.size(), 0);
    c.onKeyReread();
    Test.assertEqual(c.state, STATE_PAIRING);
    Test.assertEqual(client.calls[0], "pair");
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function recognizingStopsListeningAndTheTextFollows(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var recorder = t[2] as FakeRecorder;
    ConversationTests.open(c, client);
    c.onAudioData([1, 2]b);
    c.onAudioData([3, 4]b);
    Test.assertEqual(client.pending.size(), 2);
    // The VAD ended the command: one request waits for the text, the other says so at once
    client.answer(RESULT_OK, 200, { "state" => "recognizing" });
    Test.assertEqual(c.state, STATE_RECOGNIZING);
    Test.assert(!recorder.started);
    Test.assertEqual(client.pending.size(), 1);
    // What the microphone still hands over is not sent
    c.onAudioData([5]b);
    Test.assertEqual(client.pending.size(), 1);
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "a" });
    Test.assertEqual(c.state, STATE_SENDING);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function recognizingThenNoTextAsksAgainWithFinal(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1, 2]b);
    c.onAudioData([3, 4]b);
    client.answer(RESULT_OK, 200, { "state" => "recognizing" });
    // The one waiting ran out of time without the text: an empty "final" asks again
    client.answer(RESULT_OK, 200, { "state" => "listening", "speech" => true });
    Test.assertEqual(client.pending.size(), 1);
    Test.assertEqual(client.lastChunk[0], 4);
    Test.assertEqual(client.lastChunk[1], 0);
    Test.assertEqual(client.lastChunk[3], true);
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "a" });
    Test.assertEqual(c.state, STATE_SENDING);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function recognizingFromHomeAssistantShowsNoLookAtFirst(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1, 2]b);
    c.onAudioData([3, 4]b);
    client.answer(RESULT_OK, 200, { "state" => "recognizing" });
    // The logic has stopped listening; the screen keeps the listening look for now
    Test.assertEqual(c.state, STATE_RECOGNIZING);
    Test.assertEqual(c.shown.state, STATE_RECOGNIZING);
    Test.assert(!c.shown.revealed);
    // The text comes quickly: no "Recognising" was shown, so nothing is held
    client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "a" });
    Test.assertEqual(c.shown.state, STATE_SENDING);
    Test.assertEqual(c.shown.holdLeft(System.getTimer()), 0);
    ConversationTests.tearDown(c);
    return true;
}
