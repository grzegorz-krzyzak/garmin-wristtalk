import Toybox.Lang;
import Toybox.System;

//! How the reply's voice ended
enum VoiceEnd {
    VOICE_DONE,           // played to the end (or the watch cannot play it: the text says it all)
    VOICE_NOT_ARRIVED,    // none of it played
    VOICE_CUT_OFF,        // it stopped midway
    VOICE_UNAUTHORIZED    // the key was refused meanwhile: pair again
}

//! The reply's voice while it is being made (protocol 6): it asks Home Assistant for the pieces
//! one after another and plays once a few seconds of speech are in hand. A stall (the pieces
//! slower than the speech) waits for that margin again and revives the player; a voice that does
//! not come, or stops coming, ends with what played and says so. Time comes from `check(now)` on
//! the conversation's ticks, so the tests need not wait.
class Voice {

    // In hand before playing: at the start and after a stall 3 s (no stall followed at the phone's
    // pace on the watch); after a second stall 6 s; after a third the whole voice
    const MARGIN_MS = 3000;
    const SECOND_MARGIN_MS = 6000;
    const WHOLE_AFTER_STALLS = 3;
    // Giving up: no byte this long after the reply text (normally 3-4 s); no new byte this long
    // midway; this many failed requests in a row
    const FIRST_BYTE_MS = 6000;
    const NO_BYTES_MS = 5000;
    const FAILURES = 2;
    // A stall: the position within this much of the speech handed to the player
    const STALL_SLACK_MS = 300;
    // A stall shows ("Loading voice") once it has lasted this long - as ShownState.SHOW_MS: a
    // shorter one is only a gap heard
    const WAITING_SHOW_MS = 700;
    // The revival that worked on the watch: pause, this long, resume
    const PAUSE_MS = 300;
    // Resumed but not moving this long: a new stream from the stalled page (repeats ~0.7 s)
    const MOVE_MS = 1000;
    // All of the voice handed over and the position, once it moved, not moving this long: it has
    // ended, even if the player's "stopped" never came. Only once it moved: a voice played whole
    // reports position 0 all along on the fēnix 8 (beta 1.6.8: a 6.3 s reply stopped after 3 s) -
    // there the player's own end ends it, as before this watchdog
    const END_STILL_MS = 3000;
    // A voice played whole whose "stopped" never comes: the screen is ready again after its speech
    // and this margin - the sound is not stopped, the user stops it (START, BACK). Measured on the
    // fēnix 8 (beta 1.6.10): the player's end came every time, 54 ms before to 109 ms after the
    // speech's length - the largest rounded up to 1 s, and 1 s more
    static const NET_MARGIN_MS = 2000;

    //! The sound has started
    var playing as Boolean = false;
    var stalled as Boolean = false;

    private var _client as HaClient;
    private var _player as Player;
    private var _session as String;
    private var _volume as Number;
    private var _onPlaying as Method() as Void;
    private var _onWaiting as Method() as Void;
    private var _onEnd as Method(end as VoiceEnd) as Void;
    private var _holdLeft as Method(now as Number) as Number;

    private var _pages as OggPages = new OggPages();
    private var _request as AnswerRequest?;
    private var _failures as Number = 0;
    private var _cut as Boolean = false;      // nothing more comes, the voice did not end
    private var _over as Boolean = false;
    private var _startedAt as Number = 0;
    private var _lastBytesAt as Number = 0;
    private var _stalls as Number = 0;
    private var _stalledAt as Number = -1;
    private var _waitingShown as Boolean = false;
    private var _pausedAt as Number = -1;
    private var _resumedAt as Number = -1;
    private var _resumePos as Number = 0;
    private var _base as Number = 0;          // where the current stream starts in the speech (ms)
    private var _lastPos as Number = -1;
    private var _movedAt as Number = 0;
    private var _moved as Boolean = false;    // the position has changed since playing started
    private var _playStartAt as Number = -1;  // when the player started (timer)
    private var _whole as Boolean = false;    // played as one source: its position does not move

    function initialize(client as HaClient, player as Player, session as String, volume as Number,
            onPlaying as Method() as Void, onWaiting as Method() as Void,
            onEnd as Method(end as VoiceEnd) as Void, holdLeft as Method(now as Number) as Number) {
        _client = client;
        _player = player;
        _session = session;
        _volume = volume;
        _onPlaying = onPlaying;
        _onWaiting = onWaiting;
        _onEnd = onEnd;
        _holdLeft = holdLeft;
    }

    function start(now as Number) as Void {
        _startedAt = now;
        _lastBytesAt = now;
        ask();
    }

    //! START, BACK, the menu, a new command: silence, nothing more asked
    function stop() as Void {
        _over = true;
        abandon();
        _player.stop();
    }

    // --- the pieces ---------------------------------------------------------------------------

    private function ask() as Void {
        if (_over || _cut || _pages.ended || _request != null) {
            return;
        }
        var request = new AnswerRequest(method(:onPiece));
        _request = request;
        _client.audioPiece(_session, _pages.size, request.method(:onResult));
    }

    private function abandon() as Void {
        if (_request != null) {
            (_request as AnswerRequest).abandoned = true;
            _request = null;
        }
    }

    function onPiece(result as Result) as Void {
        _request = null;
        if (_over) {
            return;
        }
        var now = System.getTimer();
        if (result.ok() && result.data instanceof ByteArray) {
            var piece = result.data as ByteArray;
            // A piece that is not whole pages, or skips one, is asked again from the same offset;
            // a voice past the watch's cap ends here, as cut off
            if (!_pages.add(piece)) {
                if (_pages.full) {
                    cutHere(now);
                } else {
                    failed();
                }
                return;
            }
            _failures = 0;
            _lastBytesAt = now;
            if (playing) {
                _player.add(piece);
                if (_pages.ended) {
                    _player.finish();
                }
            }
            ask();
            check(now);
            return;
        }
        if (result.kind == RESULT_WAITING) {
            ask();  // nothing new yet - not a failure
        } else if (result.kind == RESULT_UNAUTHORIZED) {
            _player.stop();
            finish(VOICE_UNAUTHORIZED);
        } else if (result.kind == RESULT_EXPIRED || result.kind == RESULT_NOT_FOUND) {
            // 410: cut midway (or asked past the end); 404: no voice, or the session is gone
            cutHere(now);
        } else {
            failed();
        }
    }

    private function failed() as Void {
        _failures++;
        if (_failures >= FAILURES) {
            cutHere(System.getTimer());
        } else {
            ask();
        }
    }

    //! Nothing more comes: what is in plays to its end, then "cut off"; nothing in - "did not arrive"
    private function cutHere(now as Number) as Void {
        _cut = true;
        abandon();
        if (playing) {
            _player.finish();
        } else if (_pages.speechMs() == 0) {
            finish(VOICE_NOT_ARRIVED);
            return;
        }
        check(now);
    }

    // --- playing ------------------------------------------------------------------------------

    //! On every tick: the limits, starting, a stall and its revival
    function check(now as Number) as Void {
        if (_over) {
            return;
        }
        if (!_cut && !_pages.ended
                && (_pages.size == 0 ? now - _startedAt > FIRST_BYTE_MS : now - _lastBytesAt > NO_BYTES_MS)) {
            cutHere(now);
            if (_over) {
                return;
            }
        }
        if (!playing) {
            if (ready(0) && _holdLeft.invoke(now) == 0) {
                begin();
            }
            return;
        }
        var pos = _base + _player.position();
        // The net: a voice played whole has no moving position, only the player's own end - also one
        // cut before it started, played whole with what came
        if (_whole && (_pages.ended || _cut) && now - _playStartAt >= _pages.speechMs() + NET_MARGIN_MS) {
            _player.detach();
            finish(_pages.ended && !_cut ? VOICE_DONE : VOICE_CUT_OFF);
            return;
        }
        if ((_pages.ended || _cut) && _pausedAt < 0 && _resumedAt < 0) {
            if (pos != _lastPos) {
                _moved = _moved || _lastPos >= 0;
                _lastPos = pos;
                _movedAt = now;
            } else if (_moved && now - _movedAt >= END_STILL_MS) {
                _player.stop();
                finish(_pages.ended && !_cut ? VOICE_DONE : VOICE_CUT_OFF);
                return;
            }
        }
        if (_pausedAt >= 0) {
            if (now - _pausedAt >= PAUSE_MS) {
                _pausedAt = -1;
                _player.resume();
                _resumedAt = now;
                _resumePos = pos;
                if (_waitingShown) {
                    _waitingShown = false;
                    _onPlaying.invoke();
                }
            }
            return;
        }
        if (stalled) {
            checkStalled(now, pos);
        } else if (!_pages.ended && !_cut && pos >= _pages.speechMs() - STALL_SLACK_MS) {
            stalled = true;
            _stalls++;
            _stalledAt = now;
        }
    }

    private function checkStalled(now as Number, pos as Number) as Void {
        if (_resumedAt >= 0) {
            if (pos > _resumePos) {
                stalled = false;
                _resumedAt = -1;
            } else if (now - _resumedAt >= MOVE_MS) {
                restartAt(pos);
            }
            return;
        }
        if (!_waitingShown && now - _stalledAt >= WAITING_SHOW_MS) {
            _waitingShown = true;
            _onWaiting.invoke();
        }
        if (!ready(pos) || _holdLeft.invoke(now) > 0) {
            return;
        }
        if (_pages.speechMs() - pos < STALL_SLACK_MS) {
            // Cut with nothing left to play: a stalled stream does not end by itself
            _player.stop();
            finish(VOICE_CUT_OFF);
            return;
        }
        _player.pause();
        _pausedAt = now;
    }

    //! Enough in hand to play on: the margin, or the end (or nothing more coming)
    private function ready(pos as Number) as Boolean {
        if (_pages.ended || _cut) {
            return true;
        }
        if (_stalls >= WHOLE_AFTER_STALLS) {
            return false;
        }
        return _pages.speechMs() - pos >= (_stalls >= 2 ? SECOND_MARGIN_MS : MARGIN_MS);
    }

    private function begin() as Void {
        // All of it here already (a short reply, or a cut one): played whole, not as a stream; a
        // stream gets the pieces themselves, not a copy
        var whole = _pages.ended || _cut;
        _whole = whole;
        if (!_player.start(whole ? _pages.bytes(0) : _pages.piece(0), _volume, whole, method(:onPlayed))) {
            finish(VOICE_DONE);  // no speaker: the reply text is on screen
            return;
        }
        if (!whole) {
            for (var i = 1; i < _pages.pieceCount(); i++) {
                _player.add(_pages.piece(i));
            }
        }
        playing = true;
        _playStartAt = System.getTimer();
        _onPlaying.invoke();
    }

    //! Resumed and still not moving: a new stream from the stalled page
    private function restartAt(pos as Number) as Void {
        var data = _pages.fromPosition(pos);
        stalled = false;
        _resumedAt = -1;
        if (data == null) {
            _player.stop();
            finish(VOICE_CUT_OFF);
            return;
        }
        _base = _pages.startMs(pos);
        _player.restart(data);
    }

    function onPlayed(ok as Boolean) as Void {
        if (!_over) {
            finish(ok && _pages.ended && !_cut ? VOICE_DONE : VOICE_CUT_OFF);
        }
    }

    private function finish(end as VoiceEnd) as Void {
        _over = true;
        abandon();
        _onEnd.invoke(end);
    }
}
