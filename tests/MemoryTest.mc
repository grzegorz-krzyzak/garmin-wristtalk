import Toybox.Lang;
import Toybox.System;
import Toybox.Test;

//! A player keeping what it is handed, as the real one's source does until the speaker has taken it
//! (the worst case: the phone faster than the speech, nothing played yet) - the pieces themselves,
//! as the source keeps them, not a copy
(:test)
class KeepingPlayer extends FakePlayer {

    var kept as Array<ByteArray> = [] as Array<ByteArray>;
    var keptBytes as Number = 0;

    function initialize() {
        FakePlayer.initialize();
    }

    function start(data as ByteArray, volume as Number, whole as Boolean,
            onDone as Method(ok as Boolean) as Void) as Boolean {
        kept.add(data);
        keptBytes += data.size();
        return FakePlayer.start(data, volume, whole, onDone);
    }

    function add(data as ByteArray) as Void {
        kept.add(data);
        keptBytes += data.size();
        FakePlayer.add(data);
    }
}

(:test)
function memoryWithTheLongestReply(logger as Test.Logger) as Boolean {
    // The memory peak while the longest reply the integration sends (256 kB of voice) comes in
    // 8 kB pieces and nothing of it has played yet - the watch's own copies at their largest
    var t = ConversationTests.setUp(true);
    var client = t[1] as FakeClient;
    var player = new KeepingPlayer();
    var c = new Conversation(client, t[2] as FakeRecorder, player);
    var before = System.getSystemStats().usedMemory;
    VoiceTests.toPlaying(c, client);
    var peak = 0;
    var sequence = 5;
    var speech = 3000;
    var received = 0;
    while (client.pending.size() > 0) {
        // Pages of about 1 kB (0.8 s of speech at 10 kbit/s), eight to a piece
        var piece = []b;
        for (var i = 0; i < 8; i++) {
            speech += 800;
            var page = VoiceTests.page(sequence, speech, false);
            var body = new [1000]b;
            page[26] = 4;
            page = page.slice(0, 27);
            page.addAll([250, 250, 250, 250]b);
            page.addAll(body);
            piece.addAll(page);
            sequence++;
        }
        received += piece.size();
        client.answer(RESULT_OK, 200, piece);
        var used = System.getSystemStats().usedMemory;
        if (used > peak) {
            peak = used;
        }
    }
    var stats = System.getSystemStats();  // the limit as the test runs it
    logger.debug("voice received " + received + " B, kept by the player " + player.keptBytes + " B");
    logger.debug("memory: before " + before + " B, peak " + peak + " B, app limit " + stats.totalMemory + " B");
    Test.assert(received > 250 * 1024);
    // The voice is in memory once (the pages and the player's source share the pieces): the growth
    // stays near 256 kB, well inside the fēnix 8's 768 kB for a watch app (the test's own limit
    // is larger)
    Test.assert(peak - before < 320 * 1024);
    ConversationTests.tearDown(c);
    return true;
}
