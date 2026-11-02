import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;

//! What a request ended with, in plain kinds the logic can act on
enum ResultKind {
    RESULT_OK,
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
    RESULT_NO_ADDRESS,        // nothing set in Garmin Connect
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

    const PROTOCOL = "1";
    const API = "/api/wristtalk/v1/";

    private var _app as String;

    function initialize(appVersion as String) {
        _app = appVersion;
    }

    function pair(info as Dictionary<Object, Object>, done as Method(result as Result) as Void) as Void {
        jsonPost("pair", info, null, done);
    }

    function pollPairing(pairId as String, done as Method(result as Result) as Void) as Void {
        jsonPost("pair/" + pairId, {} as Dictionary<Object, Object>, null, done);
    }

    function ping(done as Method(result as Result) as Void) as Void {
        jsonPost("ping", {} as Dictionary<Object, Object>, Settings.key(), done);
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
        }, done, null);
    }

    //! Long poll (15 s on the integration's side) - "waiting" means ask again
    function reply(session as String, done as Method(result as Result) as Void) as Void {
        jsonPost("reply/" + session, {} as Dictionary<Object, Object>, Settings.key(), done);
    }

    function audio(session as String, done as Method(result as Result) as Void) as Void {
        request("audio/" + session, {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => buildHeaders(Settings.key()),
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_OCTET_STREAM
        }, done, null);
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
            done as Method(result as Result) as Void) as Void {
        var headers = buildHeaders(key);
        headers["Content-Type"] = Communications.REQUEST_CONTENT_TYPE_JSON;
        request(path, {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => headers,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, done, body);
    }

    private function request(path as String, options as Dictionary, done as Method(result as Result) as Void,
            params as Dictionary<Object, Object>?) as Void {
        var base = Settings.houseUrl();
        if (base.length() == 0) {
            done.invoke(new Result(RESULT_NO_ADDRESS, 0, null));
            return;
        }
        options[:context] = [done, path];
        Communications.makeWebRequest(base + API + path, params, options as {
            :method as Communications.HttpRequestMethod, :headers as Dictionary,
            :body as String or ByteArray, :responseType as Communications.HttpResponseContentType,
            :context as Object?
        }, method(:onResponse));
    }

    function onResponse(code as Number, data as Dictionary or String or ByteArray or Null, context as Object) as Void {
        var body = data instanceof Dictionary || data instanceof ByteArray ? data : null;
        var request = context as Array;
        devTrace(System.getTimer() + " " + (request[1] as String) + " -> " + code + " "
            + (data instanceof ByteArray ? data.size() + " bytes" : data));
        (request[0] as Method(result as Result) as Void).invoke(new Result(classify(code, body), code, body));
    }

    //! By the status alone: Connect IQ gives no body for a status other than 200 (measured in the
    //! simulator), so every case to tell apart has its own status
    static function classify(code as Number, body as Dictionary or ByteArray or Null) as ResultKind {
        if (code == 200) {
            return RESULT_OK;
        }
        switch (code) {
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
