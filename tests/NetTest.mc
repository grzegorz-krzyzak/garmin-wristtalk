import Toybox.Lang;
import Toybox.Test;

//! A phone for one request at a time: answers at once, inside the send (as Connect IQ does without
//! the phone), or keeps the callback for later
class TestPhone {

    var depth as Number = 0;
    var deepest as Number = 0;
    var atOnce as Boolean;
    var callback as Method(code as Number, data as Dictionary or String or ByteArray or Null) as Void or Null = null;

    function initialize(atOnce as Boolean) {
        self.atOnce = atOnce;
    }

    function send(url as String, params as Dictionary<Object, Object>?, options as Dictionary,
            callback as Method(code as Number, data as Dictionary or String or ByteArray or Null) as Void) as Void {
        depth++;
        deepest = depth > deepest ? depth : deepest;
        if (atOnce) {
            callback.invoke(-101, null);
        } else {
            self.callback = callback;
        }
        depth--;
    }
}

//! What the logic would get; sends the request again on a failure, as a chunk lost on the way is
class TestAsker {

    var phone as TestPhone;
    var results as Array<Result> = [] as Array<Result>;
    var again as Number;

    function initialize(phone as TestPhone, again as Number) {
        self.phone = phone;
        self.again = again;
    }

    function ask() as Void {
        var request = new PendingRequest("https://home.example.org/api/x", null, {} as Dictionary,
            method(:onResult), 0);
        request.transport = phone.method(:send);
        request.send();
    }

    function onResult(result as Result) as Void {
        results.add(result);
        if (results.size() < again) {
            ask();
        }
    }
}

module NetTests {

    function flushAll() as Void {
        for (var i = 0; i < 100 && Deferred.pending(); i++) {
            Deferred.flush();
        }
    }
}

(:test)
function anAnswerGivenWhileSendingComesFromTheNextTick(logger as Test.Logger) as Boolean {
    var asker = new TestAsker(new TestPhone(true), 1);
    asker.ask();
    Test.assertEqual(asker.results.size(), 0);
    Test.assert(Deferred.pending());
    NetTests.flushAll();
    Test.assertEqual(asker.results.size(), 1);
    Test.assertEqual(asker.results[0].code, -101);
    return true;
}

(:test)
function requestsSentAgainFromAnswersGivenAtOnceDoNotNest(logger as Test.Logger) as Boolean {
    // Without the phone every answer comes inside its send: sent again from the answer, the sends
    // nested until the watch's stack ran out
    var asker = new TestAsker(new TestPhone(true), 10);
    asker.ask();
    NetTests.flushAll();
    Test.assertEqual(asker.results.size(), 10);
    Test.assertEqual(asker.phone.deepest, 1);
    return true;
}

(:test)
function anAnswerComingLaterGoesOnAtOnce(logger as Test.Logger) as Boolean {
    var asker = new TestAsker(new TestPhone(false), 1);
    asker.ask();
    Test.assertEqual(asker.results.size(), 0);
    asker.phone.callback.invoke(200, { "ok" => true });
    Test.assertEqual(asker.results.size(), 1);
    Test.assert(asker.results[0].ok());
    Test.assert(!Deferred.pending());
    return true;
}

class TestDelivery {

    var count as Number = 0;

    function deliver() as Void {
        count++;
    }
}

(:test)
function theConversationsTickHandsOnAWaitingAnswer(logger as Test.Logger) as Boolean {
    var t = ConversationTests.setUp(true);
    var c = t[0] as Conversation;
    Test.assert(Deferred.wake != null);
    var delivery = new TestDelivery();
    Deferred.add(delivery.method(:deliver));
    Test.assertEqual(delivery.count, 0);
    c.onTick();
    Test.assertEqual(delivery.count, 1);
    Test.assert(!Deferred.pending());
    ConversationTests.tearDown(c);
    Test.assert(Deferred.wake == null);
    return true;
}
