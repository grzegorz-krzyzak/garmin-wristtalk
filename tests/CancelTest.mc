import Toybox.Lang;
import Toybox.System;
import Toybox.Test;

//! BACK while listening or recognising cancels the command in Home Assistant and says what came of it
//! (protocol 7); "final" goes only from START or the listening cap - layer 2 in the integration rests
//! on "final" meaning "run it"

(:test)
function backWhileListeningCancelsAndSaysSo(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    Test.assert(c.onBack());
    Test.assertEqual(client.last(), "cancel");
    Test.assertEqual(client.finals, 0);
    Test.assertEqual(c.state, STATE_IDLE);
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.Cancelling));
    client.answerLast(RESULT_OK, 200, { "state" => "cancelled" });
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.Cancelled));
    Test.assertEqual(c.popupKind, POPUP_CANCELLED);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function backRightAfterStartSendsNoFinal(logger as Test.Logger) as Boolean {
    // START, then BACK while the watch waits for the microphone's rest: stopping the microphone
    // reported its end and that sent "final" - "run it" right after the user cancelled
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var recorder = t[2] as FakeRecorder;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    recorder.rest = [2]b;
    recorder.reportsDone = false;
    c.onSelect();
    Test.assertEqual(c.state, STATE_RECOGNIZING);
    recorder.reportsDone = true;
    recorder.started = true;
    Test.assert(c.onBack());
    Test.assertEqual(client.finals, 0);
    Test.assertEqual(client.last(), "cancel");
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function tooLateSaysSoThenTheReplyComes(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    c.onBack();
    client.answerLast(RESULT_OK, 200, { "state" => "too_late", "heard" => "open the gate" });
    // "Too late" on its own first: the reply, usually there already, waits for it
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.TooLate));
    Test.assertEqual(c.heard, "open the gate");
    Test.assertEqual(c.state, STATE_IDLE);
    Test.assertEqual(client.last(), "cancel");
    c.afterTooLate();  // what the wait after the popup calls
    Test.assertEqual(c.popup, "");
    Test.assertEqual(c.state, STATE_SENDING);
    Test.assertEqual(client.last(), "reply");
    client.answerLast(RESULT_OK, 200, { "reply" => "Opening.", "audio" => false });
    Test.assertEqual(c.reply, "Opening.");
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function noConfirmationInTimeSaysSo(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    c.onBack();
    var now = System.getTimer();
    c.checkCancel(now + Conversation.CANCEL_CONFIRM_MS - 200);
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.Cancelling));
    c.checkCancel(now + Conversation.CANCEL_CONFIRM_MS + 200);
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.CancelNotConfirmed));
    // A late answer changes nothing
    client.answerLast(RESULT_OK, 200, { "state" => "cancelled" });
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.CancelNotConfirmed));
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aCancelFailingAtOnceIsSentAgain(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    c.onBack();
    var asked = client.calls.size();
    client.answerLast(RESULT_ERROR, -101, null);
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.Cancelling));
    c.sendCancel();  // what the wait after a failure calls
    Test.assertEqual(client.calls.size(), asked + 1);
    Test.assertEqual(client.last(), "cancel");
    client.answerLast(RESULT_OK, 200, { "state" => "cancelled" });
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.Cancelled));
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function anUnknownCancelAnswerIsNotAConfirmation(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    c.onBack();
    client.answerLast(RESULT_OK, 200, { "state" => "maybe" });
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.CancelNotConfirmed));
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function theMenuTheBackgroundAndClosingSendNoFinal(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    c.onCovered();
    Test.assertEqual(client.finals, 0);
    c.onUncovered();
    c.onSelect();
    c.onAudioData([1]b);
    c.onBackground();
    Test.assertEqual(client.finals, 0);
    c.onForeground();
    c.onSelect();
    c.onAudioData([1]b);
    c.shutdown();
    Test.assertEqual(client.finals, 0);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function theListeningCapSendsFinal(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    client.answer(RESULT_OK, 200, { "state" => "listening", "speech" => true });
    c.checkListening(System.getTimer() + 20100);
    Test.assertEqual(c.state, STATE_RECOGNIZING);
    Test.assertEqual(client.finals, 1);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function backWhileTheVoicePlaysSaysStopped(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    VoiceTests.toPlaying(c, client);
    Test.assert(c.onBack());
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.Stopped));
    Test.assertEqual(c.popupKind, POPUP_STOPPED);
    Test.assertEqual(client.last() == "cancel", false);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function startWhileCancellingWaitsForTheAnswer(logger as Test.Logger) as Boolean {
    // A new command would drop the cancel's answer: a command too late to stop would run unsaid
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    c.onBack();
    c.onSelect();
    Test.assertEqual(c.state, STATE_IDLE);
    Test.assertEqual(client.last(), "cancel");
    client.answerLast(RESULT_OK, 200, { "state" => "cancelled" });
    // Its answer on the screen: START would take it away at once
    c.onSelect();
    Test.assertEqual(c.state, STATE_IDLE);
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.Cancelled));
    // Once it is gone (read, or BACK), START starts the next command
    c.onBack();
    c.onSelect();
    Test.assertEqual(c.state, STATE_LISTENING);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function tooLateKeepsWatchingForTheReply(logger as Test.Logger) as Boolean {
    // BACK stopped the ticks; "Thinking" after "too late" needs them, and the house just answered
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    c.setAnsweredAt(System.getTimer() - c.NO_ANSWER_MS);
    c.onBack();
    Test.assert(!c.animating());
    client.answerLast(RESULT_OK, 200, { "state" => "too_late", "heard" => "open the gate" });
    c.afterTooLate();
    Test.assert(c.animating());
    c.checkAnswers(System.getTimer() + 1000);
    Test.assertEqual(c.state, STATE_SENDING);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aNewPairingEndsThePendingCancel(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    ConversationTests.open(c, client);
    c.onAudioData([1]b);
    c.onBack();
    Settings.clearKey();
    c.onSettingsChanged();
    Test.assertEqual(c.state, STATE_PAIRING);
    c.checkCancel(System.getTimer() + Conversation.CANCEL_CONFIRM_MS + 200);
    Test.assert(!c.popup.equals(Settings.text(Rez.Strings.CancelNotConfirmed)));
    Test.assertEqual(c.state, STATE_PAIRING);
    ConversationTests.tearDown(c);
    return true;
}
