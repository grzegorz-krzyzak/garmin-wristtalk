import Toybox.Communications;
import Toybox.Lang;

//! What a request ended with, in plain kinds the logic can act on
enum ResultKind {
    RESULT_OK,
    RESULT_WAITING,           // 202 - the reply's voice is still being made: ask again
    RESULT_UNAUTHORIZED,      // 401 - the key was rejected: pair again
    RESULT_PAIRING_CLOSED,    // 403 - "Add watch" is not open in Home Assistant
    RESULT_NOT_FOUND,         // 404
    RESULT_BUSY,              // 409
    RESULT_EXPIRED,           // 410 - the pairing ended
    RESULT_TOO_LARGE,         // 413
    RESULT_TOO_MANY,          // 429
    RESULT_STT_FAILED,        // 424 - speech recognition failed a third time in a row
    RESULT_UPDATE_APP,        // 426: the app's protocol is too old
    RESULT_UPDATE_INTEGRATION, // 501: the integration's protocol is too old
    RESULT_SERVER,            // 5xx, e.g. the pipeline failed
    RESULT_NO_PHONE,          // Bluetooth to the phone
    RESULT_TIMEOUT,
    RESULT_HTTPS,             // -1001: the address must be https://
    RESULT_NO_ADDRESS,        // nothing set in the Connect IQ app
    RESULT_ERROR
}

class Result {

    var kind as ResultKind;
    var code as Number;
    var data as Dictionary or ByteArray or Null;

    function initialize(kind as ResultKind, code as Number, data as Dictionary or ByteArray or Null) {
        self.kind = kind;
        self.code = code;
        self.data = data;
    }

    function ok() as Boolean {
        return kind == RESULT_OK;
    }

    //! A string field of a JSON reply, "" when missing
    function text(key as String) as String {
        var value = data instanceof Dictionary ? (data as Dictionary)[key] : null;
        return value instanceof String ? value : "";
    }

    function flag(key as String) as Boolean {
        var value = data instanceof Dictionary ? (data as Dictionary)[key] : null;
        return value instanceof Boolean ? value as Boolean : false;
    }
}

//! Connection to Home Assistant - the WristTalk integration's protocol v1. Knows nothing about the
//! screen or the conversation; every request ends in one callback with a Result.
class HaClient {

    // Raised with the integration on every change one side sends or expects (the table: the
    // integration's design notes); 2: waits within 4 s, audio 202, a timed-out request repeated;
    // 3: POST repair - "Pair again" from the menu
    const PROTOCOL = "4";
    const API = "/api/wristtalk/v1/";

    private var _app as String;

    function initialize(appVersion as String) {
        _app = appVersion;
    }

    //! Not repeated on a timeout: each call starts a new pairing with a new code
    function pair(info as Dictionary<Object, Object>, done as Method(result as Result) as Void) as Void {
        jsonPost("pair", info, null, done, false);
    }

    function pollPairing(pairId as String, done as Method(result as Result) as Void) as Void {
        jsonPost("pair/" + pairId, {} as Dictionary<Object, Object>, null, done, true);
    }

    function ping(done as Method(result as Result) as Void) as Void {
        jsonPost("ping", {} as Dictionary<Object, Object>, Settings.key(), done, true);
    }

    //! "Pair again": with the key, before the watch drops it - Home Assistant revokes it
    function repair(done as Method(result as Result) as Void) as Void {
        jsonPost("repair", {} as Dictionary<Object, Object>, Settings.key(), done, true);
    }

    //! A chunk of the command at its byte offset; textOnly matters on the first chunk, final = START
    function sendChunk(session as String, offset as Number, audio as ByteArray, textOnly as Boolean,
            final as Boolean, done as Method(result as Result) as Void) as Void {
        var headers = buildHeaders(Settings.key());
        headers["Content-Type"] = "application/octet-stream";
        if (textOnly) {
            headers["X-WT-Text-Only"] = "1";
        }
        if (final) {
            headers["X-WT-Final"] = "1";
        }
        request("command/" + session + "/" + offset, {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => headers,
            :body => audio,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, done, null, true);
    }

    //! Long poll (4 s on the integration's side - longer does not come back through the phone):
    //! "waiting" means ask again
    function reply(session as String, done as Method(result as Result) as Void) as Void {
        jsonPost("reply/" + session, {} as Dictionary<Object, Object>, Settings.key(), done, true);
    }

    //! The reply's voice; RESULT_WAITING (202, after 4 s) while it is being made
    function audio(session as String, done as Method(result as Result) as Void) as Void {
        request("audio/" + session, {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => buildHeaders(Settings.key()),
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_OCTET_STREAM
        }, done, null, true);
    }

    // --- plumbing ---

    private function buildHeaders(key as String?) as Dictionary {
        var headers = { "X-WT-Protocol" => PROTOCOL, "X-WT-App" => _app } as Dictionary;
        if (key != null) {
            headers["X-WT-Key"] = key;
        }
        return headers;
    }

    private function jsonPost(path as String, body as Dictionary<Object, Object>, key as String?,
            done as Method(result as Result) as Void, repeatable as Boolean) as Void {
        var headers = buildHeaders(key);
        headers["Content-Type"] = Communications.REQUEST_CONTENT_TYPE_JSON;
        request(path, {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => headers,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, done, body, repeatable);
    }

    //! repeatable: the same request may arrive twice (a chunk at its offset, a poll, the audio) - it
    //! is sent once more after a timeout
    private function request(path as String, options as Dictionary, done as Method(result as Result) as Void,
            params as Dictionary<Object, Object>?, repeatable as Boolean) as Void {
        var base = Settings.houseUrl();
        if (base.length() == 0) {
            done.invoke(new Result(RESULT_NO_ADDRESS, 0, null));
            return;
        }
        // The key and the recording go only over HTTPS: the iPhone refuses http:// itself (-1001),
        // Android may not - the watch does not rely on the phone (security review 2026-11-07)
        if (base.find("https://") != 0) {
            done.invoke(new Result(RESULT_HTTPS, Communications.SECURE_CONNECTION_REQUIRED, null));
            return;
        }
        // A handler object per request, not :context: without the phone Connect IQ calls the
        // callback at once with only the code and the data (measured on the fēnix 8, 2026-11-04 -
        // a three-argument callback crashed the app with "Not Enough Arguments")
        new PendingRequest(base + API + path, params, options, done, repeatable ? 1 : 0).send();
    }

    //! By the status alone: Connect IQ may drop the body of a status other than 200 (measured in the
    //! simulator for the chunk requests, binary body), so every case to tell apart has its own status
    static function classify(code as Number, body as Dictionary or ByteArray or Null) as ResultKind {
        if (code == 200) {
            return RESULT_OK;
        }
        switch (code) {
            case 202: return RESULT_WAITING;
            case 401: return RESULT_UNAUTHORIZED;
            case 403: return RESULT_PAIRING_CLOSED;
            case 404: return RESULT_NOT_FOUND;
            case 409: return RESULT_BUSY;
            case 410: return RESULT_EXPIRED;
            case 413: return RESULT_TOO_LARGE;
            case 429: return RESULT_TOO_MANY;
            case 424: return RESULT_STT_FAILED;
            case 426: return RESULT_UPDATE_APP;
            case 501: return RESULT_UPDATE_INTEGRATION;
            case Communications.SECURE_CONNECTION_REQUIRED: return RESULT_HTTPS;
            case Communications.NETWORK_REQUEST_TIMED_OUT: return RESULT_TIMEOUT;
            case Communications.BLE_CONNECTION_UNAVAILABLE:
            case Communications.BLE_HOST_TIMEOUT:
            case Communications.BLE_SERVER_TIMEOUT:
            case Communications.BLE_NO_DATA:
                return RESULT_NO_PHONE;
        }
        return code >= 500 ? RESULT_SERVER : RESULT_ERROR;
    }
}

//! One request and its answer: the callback Connect IQ calls with the code and the data. A timeout
//! is sent again while retries are left - through the phone one failed with -300 after 0.9 s
//! (measured on the fēnix 8, 2026-11-04) and the next request went through
class PendingRequest {

    private var _url as String;
    private var _params as Dictionary<Object, Object>?;
    private var _options as Dictionary;
    private var _done as Method(result as Result) as Void;
    private var _retries as Number;

    function initialize(url as String, params as Dictionary<Object, Object>?, options as Dictionary,
            done as Method(result as Result) as Void, retries as Number) {
        _url = url;
        _params = params;
        _options = options;
        _done = done;
        _retries = retries;
    }

    //! A handler object per request, not :context: without the phone Connect IQ calls the callback
    //! at once with only the code and the data (a three-argument callback crashed the app with "Not
    //! Enough Arguments", fēnix 8, 2026-11-04)
    function send() as Void {
        Communications.makeWebRequest(_url, _params, _options as {
            :method as Communications.HttpRequestMethod, :headers as Dictionary,
            :body as String or ByteArray, :responseType as Communications.HttpResponseContentType
        }, method(:onResponse));
    }

    function onResponse(code as Number, data as Dictionary or String or ByteArray or Null) as Void {
        if (shouldRetry(code, _retries)) {
            _retries--;
            send();
            return;
        }
        var body = data instanceof Dictionary || data instanceof ByteArray ? data : null;
        _done.invoke(new Result(HaClient.classify(code, body), code, body));
    }

    static function shouldRetry(code as Number, retries as Number) as Boolean {
        return retries > 0 && code == Communications.NETWORK_REQUEST_TIMED_OUT;
    }
}
