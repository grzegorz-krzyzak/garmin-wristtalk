import Toybox.Lang;
import Toybox.System;
import Toybox.Test;

//! The reply's voice in pieces (protocol 6): Ogg pages made here, the fakes of ConversationTest

(:test)
module VoiceTests {

    //! Ogg pages numbered from `first`, one per speech end (ms; 0 for the two header pages); the
    //! last with the end-of-stream flag when `eos`
    function pages(first as Number, endsMs as Array<Number>, eos as Boolean) as ByteArray {
        var data = []b;
        for (var i = 0; i < endsMs.size(); i++) {
            data.addAll(page(first + i, endsMs[i], eos && i == endsMs.size() - 1));
        }
        return data;
    }

    function page(sequence as Number, endMs as Number, eos as Boolean) as ByteArray {
        var page = new [27 + 1 + 10]b;
        page[0] = 0x4f;
        page[1] = 0x67;
        page[2] = 0x67;
        page[3] = 0x53;
        page[5] = eos ? 0x04 : 0;
        page.encodeNumber(endMs * 48, Lang.NUMBER_FORMAT_SINT32, { :offset => 6, :endianness => Lang.ENDIAN_LITTLE });
        page.encodeNumber(sequence, Lang.NUMBER_FORMAT_SINT32, { :offset => 18, :endianness => Lang.ENDIAN_LITTLE });
        page[26] = 1;
        page[27] = 10;
        return page;
    }

    //! A command up to its reply with a voice: the voice's first request on its way
    function toVoice(c as Conversation, client as FakeClient) as Void {
        ConversationTests.open(c, client);
        c.onAudioData([1]b);
        client.answer(RESULT_OK, 200, { "state" => "heard", "heard" => "a" });
        client.answer(RESULT_OK, 200, { "reply" => "b", "audio" => true });
    }

    //! Playing with 3 s in hand (the header pages and three 1 s pages, no end yet)
    function toPlaying(c as Conversation, client as FakeClient) as Number {
        toVoice(c, client);
        var voice = pages(0, [0, 0, 1000, 2000, 3000] as Array<Number>, false);
        client.answer(RESULT_OK, 200, voice);
        Test.assertEqual(c.state, STATE_PLAYING);
        return voice.size();
    }
}

(:test)
function theVoiceStartsWithThreeSecondsInHand(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var player = t[3] as FakePlayer;
    VoiceTests.toVoice(c, client);
    var first = VoiceTests.pages(0, [0, 0, 1000] as Array<Number>, false);
    client.answer(RESULT_OK, 200, first);
    // 1 s: still loading, the next piece asked from where this one ended
    Test.assertEqual(c.state, STATE_LOADING_VOICE);
    Test.assert(!player.started);
    Test.assertEqual(client.last(), "audio:" + first.size());
    var more = VoiceTests.pages(3, [2000, 3000] as Array<Number>, false);
    client.answer(RESULT_OK, 200, more);
    Test.assertEqual(c.state, STATE_PLAYING);
    Test.assertEqual(player.played, first.size() + more.size());
    Test.assert(!player.whole);
    Test.assert(!player.finished);
    // The rest comes while it plays; the end flag: nothing more asked, the player told
    var rest = VoiceTests.pages(5, [4000] as Array<Number>, true);
    client.answer(RESULT_OK, 200, rest);
    Test.assertEqual(player.played, first.size() + more.size() + rest.size());
    Test.assert(player.finished);
    Test.assertEqual(client.pending.size(), 0);
    player.end(true);
    Test.assertEqual(c.state, STATE_IDLE);
    Test.assertEqual(c.popup, "");
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aStallShowsLoadingVoiceAndPlaysOnWithPauseAndResume(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var player = t[3] as FakePlayer;
    var size = VoiceTests.toPlaying(c, client);
    var now = System.getTimer();
    // The position at the end of what came: a stall - not shown at once (a short one is a gap)
    player.pos = 2800;
    c.checkVoice(now);
    Test.assertEqual(c.state, STATE_PLAYING);
    c.checkVoice(now + 700);
    Test.assertEqual(c.state, STATE_LOADING_VOICE);
    // 3 s more in hand: after "Loading voice" stayed its minimum, pause, a moment, resume
    client.answer(RESULT_OK, 200, VoiceTests.pages(5, [4000, 5000, 6000] as Array<Number>, false));
    var later = System.getTimer() + 1000;
    c.checkVoice(later);
    Test.assertEqual(player.pauses, 1);
    Test.assertEqual(player.resumes, 0);
    c.checkVoice(later + 300);
    Test.assertEqual(player.resumes, 1);
    Test.assertEqual(c.state, STATE_PLAYING);
    // Moving again: the stall is over, no new stream
    player.pos = 3100;
    c.checkVoice(later + 1400);
    Test.assertEqual(player.restarts, 0);
    Test.assert(size > 0);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aShortStallIsOnlyAGap(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var player = t[3] as FakePlayer;
    VoiceTests.toPlaying(c, client);
    player.pos = 2900;
    c.checkVoice(System.getTimer());
    client.answer(RESULT_OK, 200, VoiceTests.pages(5, [4000, 5000, 6000] as Array<Number>, false));
    var now = System.getTimer();
    c.checkVoice(now);
    c.checkVoice(now + 300);
    // Revived before it showed: the status never changed
    Test.assertEqual(player.resumes, 1);
    Test.assertEqual(c.state, STATE_PLAYING);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function resumedButStillStalledStartsANewStream(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var player = t[3] as FakePlayer;
    VoiceTests.toPlaying(c, client);
    player.pos = 2900;
    c.checkVoice(System.getTimer());
    client.answer(RESULT_OK, 200, VoiceTests.pages(5, [4000, 5000, 6000] as Array<Number>, false));
    var now = System.getTimer();
    c.checkVoice(now);
    c.checkVoice(now + 300);
    // Not moving a second after resume: a new stream from the stalled page
    c.checkVoice(now + 1300);
    Test.assertEqual(player.restarts, 1);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function laterStallsWaitLonger(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var player = t[3] as FakePlayer;
    VoiceTests.toPlaying(c, client);
    var seq = 5;
    var endMs = 3000;
    // Stall 1: 3 s more is enough
    player.pos = endMs - 100;
    c.checkVoice(System.getTimer());
    client.answer(RESULT_OK, 200, VoiceTests.pages(seq, [endMs + 3000] as Array<Number>, false));
    seq++;
    endMs += 3000;
    var now = System.getTimer();
    c.checkVoice(now);
    c.checkVoice(now + 300);
    Test.assertEqual(player.resumes, 1);
    player.pos = endMs - 2900;
    c.checkVoice(now + 400);
    // Stall 2: 3 s more is not enough - 6 s
    player.pos = endMs - 100;
    c.checkVoice(now + 500);
    client.answer(RESULT_OK, 200, VoiceTests.pages(seq, [endMs + 3000] as Array<Number>, false));
    seq++;
    endMs += 3000;
    now = System.getTimer() + 1000;
    c.checkVoice(now);
    Test.assertEqual(player.pauses, 1);
    client.answer(RESULT_OK, 200, VoiceTests.pages(seq, [endMs + 3000] as Array<Number>, false));
    seq++;
    endMs += 3000;
    c.checkVoice(now + 100);
    c.checkVoice(now + 400);
    Test.assertEqual(player.resumes, 2);
    player.pos = endMs - 5000;
    c.checkVoice(now + 500);
    // Stall 3: only the whole voice
    player.pos = endMs - 100;
    c.checkVoice(now + 600);
    client.answer(RESULT_OK, 200, VoiceTests.pages(seq, [endMs + 9000] as Array<Number>, false));
    seq++;
    now = System.getTimer() + 2000;
    c.checkVoice(now);
    Test.assertEqual(player.pauses, 2);
    client.answer(RESULT_OK, 200, VoiceTests.pages(seq, [endMs + 10000] as Array<Number>, true));
    c.checkVoice(now + 100);
    Test.assertEqual(player.pauses, 3);
    Test.assert(player.finished);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aVoiceCutMidwayPlaysWhatCameThenSaysSo(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var player = t[3] as FakePlayer;
    VoiceTests.toPlaying(c, client);
    client.answer(RESULT_EXPIRED, 410, null);
    Test.assert(player.finished);
    Test.assertEqual(client.pending.size(), 0);
    player.end(true);
    Test.assertEqual(c.state, STATE_IDLE);
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.VoiceCutOff));
    Test.assertEqual(c.popupKind, POPUP_VOICE_FAILED);
    // The reply stays: a timed note over it
    Test.assertEqual(c.reply, "b");
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aCutBeforeThreeSecondsPlaysWhatCame(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var player = t[3] as FakePlayer;
    VoiceTests.toVoice(c, client);
    client.answer(RESULT_OK, 200, VoiceTests.pages(0, [0, 0, 1000] as Array<Number>, false));
    client.answer(RESULT_EXPIRED, 410, null);
    Test.assertEqual(c.state, STATE_PLAYING);
    Test.assert(player.whole);
    player.end(true);
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.VoiceCutOff));
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function noVoiceSaysItDidNotArrive(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    VoiceTests.toVoice(c, client);
    client.answer(RESULT_NOT_FOUND, 404, null);
    Test.assertEqual(c.state, STATE_IDLE);
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.VoiceNotArrived));
    Test.assert(!(t[3] as FakePlayer).started);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function noByteInSixSecondsIsNoVoice(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    VoiceTests.toVoice(c, client);
    var now = System.getTimer();
    c.checkVoice(now + 5000);
    Test.assertEqual(c.state, STATE_LOADING_VOICE);
    c.checkVoice(now + 6100);
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.VoiceNotArrived));
    // The request still on its way answers late: ignored
    client.answer(RESULT_OK, 200, VoiceTests.pages(0, [0, 0, 1000] as Array<Number>, true));
    Test.assert(!(t[3] as FakePlayer).started);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aFailedRequestIsAskedAgainThenGivenUp(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    VoiceTests.toVoice(c, client);
    client.answer(RESULT_NO_PHONE, -104, null);
    Test.assertEqual(client.last(), "audio:0");
    Test.assertEqual(c.state, STATE_LOADING_VOICE);
    client.answer(RESULT_TIMEOUT, -300, null);
    Test.assertEqual(c.state, STATE_IDLE);
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.VoiceNotArrived));
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function fiveSecondsWithoutBytesMidwayCutsTheVoice(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var player = t[3] as FakePlayer;
    VoiceTests.toPlaying(c, client);
    var now = System.getTimer();
    // 202s keep coming: not failures, but no bytes
    client.answer(RESULT_WAITING, 202, null);
    c.checkVoice(now + 4000);
    Test.assert(!player.finished);
    c.checkVoice(now + 5100);
    Test.assert(player.finished);
    player.end(true);
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.VoiceCutOff));
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aStalledVoiceCutWithNothingLeftEndsAtOnce(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var player = t[3] as FakePlayer;
    VoiceTests.toPlaying(c, client);
    player.pos = 2950;
    c.checkVoice(System.getTimer());
    // A stalled stream does not end by itself: stopped, "cut off"
    client.answer(RESULT_EXPIRED, 410, null);
    Test.assert(player.stopped);
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.VoiceCutOff));
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function aPieceSkippingAPageIsAskedAgain(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    VoiceTests.toVoice(c, client);
    var first = VoiceTests.pages(0, [0, 0, 1000] as Array<Number>, false);
    client.answer(RESULT_OK, 200, first);
    // Page 4 where 3 is due: dropped, the same offset asked again
    client.answer(RESULT_OK, 200, VoiceTests.pages(4, [3000] as Array<Number>, false));
    Test.assertEqual(client.last(), "audio:" + first.size());
    client.answer(RESULT_OK, 200, VoiceTests.pages(3, [3000] as Array<Number>, false));
    Test.assertEqual(c.state, STATE_PLAYING);
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function thePlayerFailingSaysTheVoiceWasCut(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var player = t[3] as FakePlayer;
    VoiceTests.toPlaying(c, client);
    player.end(false);
    Test.assertEqual(c.state, STATE_IDLE);
    Test.assertEqual(c.popup, Settings.text(Rez.Strings.VoiceCutOff));
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function backStopsTheVoiceAndItsRequests(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    var client = t[1] as FakeClient;
    var player = t[3] as FakePlayer;
    VoiceTests.toPlaying(c, client);
    Test.assert(c.onBack());
    Test.assertEqual(c.state, STATE_IDLE);
    Test.assert(player.stopped);
    var asked = client.calls.size();
    client.answer(RESULT_OK, 200, VoiceTests.pages(5, [4000] as Array<Number>, true));
    Test.assertEqual(client.calls.size(), asked);
    Test.assertEqual(c.popup, "");
    ConversationTests.tearDown(c);
    return true;
}

(:test)
function oggPagesCountTheSpeechAndFindAPage(logger as Test.Logger) as Boolean {
    var pages = new OggPages();
    // Not whole pages: refused, nothing taken
    var data = VoiceTests.pages(0, [0, 0, 1000, 2000] as Array<Number>, false);
    Test.assert(!pages.add(data.slice(0, data.size() - 1)));
    Test.assertEqual(pages.size, 0);
    Test.assert(pages.add(data));
    Test.assertEqual(pages.speechMs(), 2000);
    Test.assert(!pages.ended);
    // A page with no packet end (granule -1) keeps the speech so far
    var open = VoiceTests.page(4, 0, false);
    open.encodeNumber(-1, Lang.NUMBER_FORMAT_SINT32, { :offset => 6, :endianness => Lang.ENDIAN_LITTLE });
    Test.assert(pages.add(open));
    Test.assertEqual(pages.speechMs(), 2000);
    Test.assert(pages.add(VoiceTests.pages(5, [3000] as Array<Number>, true)));
    Test.assert(pages.ended);
    // Nothing after the end
    Test.assert(!pages.add(VoiceTests.pages(6, [4000] as Array<Number>, false)));
    // From 1.5 s: the header pages, then the page ending at 2 s and the rest; it starts at 1 s
    var from = pages.fromPosition(1500) as ByteArray;
    Test.assertEqual(from.size(), 2 * 38 + 3 * 38);
    Test.assertEqual(pages.startMs(1500), 1000);
    Test.assertEqual(pages.startMs(0), 0);
    Test.assert(pages.fromPosition(5000) == null);
    return true;
}
