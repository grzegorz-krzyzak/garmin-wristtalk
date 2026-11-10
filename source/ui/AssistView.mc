import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

enum NoticeIcon {
    NOTICE_ERROR,
    NOTICE_QUESTION,
    NOTICE_DONE,
    NOTICE_SPEAKER,
    NOTICE_SPEAKER_OFF
}

//! Draws what the conversation holds; knows nothing about the network
class AssistView extends WatchUi.View {

    // The START button sits at about 2 o'clock on the fenix bezel (degrees: 0 = 3 o'clock,
    // counter-clockwise)
    const START_ANGLE = 30;
    const ICON_Y = 0.032;      // the reply-mode icon (centre), of the screen height - above the
                               // status line and the watch's own microphone (at 0.045 it touched
                               // it, at 0.028 it touched the screen's edge)
    const STATUS_Y = 0.09;     // the status line (top), of the screen height

    private var _c as Conversation;
    private var _scroller as Scroller;
    private var _commandsSeen as Number = 0;

    function initialize(conversation as Conversation, scroller as Scroller) {
        View.initialize();
        _c = conversation;
        _scroller = scroller;
    }

    function onShow() as Void {
        _c.startOnce();
        _c.onUncovered();
        _c.onForeground();
    }

    //! Hidden: by our menu (it marked itself), or by the system - the watch face, the app switcher
    function onHide() as Void {
        if (!_c.menuOpen()) {
            _c.onBackground();
        }
    }

    function onUpdate(dc as Dc) as Void {
        Capabilities.smoothEdges(dc);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        if (_c.idle.countdown > 0) {
            // A screen of its own, as the watch's own countdowns - not a box over the conversation
            drawCountdown(dc, _c.idle.countdown, _c.idle.countdownFrom);
            return;
        }
        if (_c.state == STATE_PAIRING) {
            drawPairing(dc);
        } else {
            drawConversationScreen(dc);
        }
    }

    //! The pairing code to compare with Home Assistant, or what to do first
    private function drawPairing(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var font = Graphics.FONT_XTINY;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, STATUS_Y * h, font, Settings.text(Rez.Strings.PairTitle), Graphics.TEXT_JUSTIFY_CENTER);
        drawHeaderLine(dc);
        var notice = _c.pairing.notice;
        var code = _c.pairing.code;
        if (code.length() == 6) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.38, Graphics.FONT_NUMBER_MEDIUM, code.substring(0, 3) + " " + code.substring(3, 6),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            drawLines(dc, Settings.text(Rez.Strings.PairConfirmInHa), font, h * 0.55, Graphics.COLOR_LT_GRAY);
        } else if (notice.equals(Settings.text(Rez.Strings.PairOpenInHa))) {
            // A short main line and a smaller hint where to find it, like pairing a TV
            var main = Graphics.fitTextToArea(notice, Graphics.FONT_TINY, w * 0.74, h * 0.3, true);
            if (main != null) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(w / 2, h * 0.34, Graphics.FONT_TINY, main, Graphics.TEXT_JUSTIFY_CENTER);
            }
            // Where, then the button as Home Assistant draws it: "+ Add watch" in a rounded frame
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.62, font, Settings.text(Rez.Strings.PairOpenInHaHint), Graphics.TEXT_JUSTIFY_CENTER);
            drawButton(dc, Settings.text(Rez.Strings.PairAddWatchButton), font, h * 0.62 + dc.getFontHeight(font) + 4);
        } else if (notice.length() > 0) {
            drawLines(dc, notice, font, h * 0.35, Graphics.COLOR_WHITE);
        }
    }

    //! The thin line under the header (the status or a title). Every screen with a header has it;
    //! only the countdown, which covers the whole screen like the watch's own questions, has
    //! neither. Returns where it is.
    private function drawHeaderLine(dc as Dc) as Number {
        var lineY = (STATUS_Y * dc.getHeight() + dc.getFontHeight(Graphics.FONT_XTINY) + 4).toNumber();
        var half = Bubbles.chordHalf(dc, lineY) * 0.7;
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(dc.getWidth() / 2 - half, lineY, dc.getWidth() / 2 + half, lineY);
        return lineY;
    }

    //! A text on a filled button, centred, its top at `top`. Filled blue like the command bubbles: a thin
    //! ring (outline) shows every stair step on this screen (no anti-aliasing), a filled shape
    //! with the bubbles' radius does not
    private function drawButton(dc as Dc, text as String, font as FontDefinition, top as Numeric) as Void {
        var bw = dc.getTextWidthInPixels(text, font) + 24;
        var bh = dc.getFontHeight(font) + 8;
        dc.setColor(Bubbles.COMMAND_BUBBLE, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle((dc.getWidth() - bw) / 2, top, bw, bh, Bubbles.RADIUS);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() / 2, top + bh / 2, font, text, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! Wrapped, centred lines. Colours across the screens: what matters in white, what helps
    //! (hints, the status) in grey
    private function drawLines(dc as Dc, text as String, font as FontDefinition, top as Numeric,
            color as Number) as Void {
        var fitted = Graphics.fitTextToArea(text, font, dc.getWidth() * 0.74, dc.getHeight() * 0.4, true);
        if (fitted != null) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.drawText(dc.getWidth() / 2, top, font, fitted, Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    private function drawConversationScreen(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var c = _c;
        // The status line stays quiet: one grey for every state, colour only for an error; the
        // bubbles below carry the colour
        var status = "";
        var color = Graphics.COLOR_LT_GRAY;
        var hint = true;
        // What the screen shows of the state (ShownState): a waiting state without its look yet
        // shows its content only - "Recognising" not yet shown still looks like listening
        var s = c.shown.state;
        var revealed = c.shown.revealed;
        if (s == STATE_RECOGNIZING && !revealed) {
            s = STATE_LISTENING;
            revealed = true;
        }
        if (s == STATE_CONNECTING) {
            status = revealed ? Settings.text(Rez.Strings.StatusConnecting) : "";
            hint = false;
        } else if (s == STATE_RECOGNIZING) {
            status = Settings.text(Rez.Strings.StatusRecognizing);
            hint = false;
        } else if (s == STATE_SENDING) {
            status = revealed ? Settings.text(Rez.Strings.StatusThinking) : "";
            hint = false;
        } else if (s == STATE_LOADING_VOICE) {
            status = revealed ? Settings.text(Rez.Strings.StatusLoadingVoice) : "";
        } else if (s == STATE_PLAYING) {
            status = Settings.text(Rez.Strings.StatusReplying);
        } else if (s == STATE_ERROR) {
            status = Settings.text(Rez.Strings.StatusError);
            color = Graphics.COLOR_ORANGE;
            hint = c.canRetry;  // to be fixed elsewhere: START does nothing
        }
        // While listening the watch shows its own microphone in the middle of the top: it is the
        // recording light, so there is no status
        if (status.length() > 0) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, STATUS_Y * h, Graphics.FONT_XTINY, status, Graphics.TEXT_JUSTIFY_CENTER);
        }
        // The reply mode, always at one place: in the middle above the status line (and above the
        // watch's own microphone while listening); hold UP switches it
        if (Capabilities.hasSpeaker()) {
            drawSpeaker(dc, w / 2, ICON_Y * h, Settings.textOnly(), 1, Graphics.COLOR_LT_GRAY);
        }
        // The START arc: blinking while the app waits for START (Conversation.pulseOn), steady where
        // START may be pressed, none where it does nothing. An empty idle screen also says what to do.
        var empty = s == STATE_IDLE && c.isEmpty();
        var blinkedOff = c.waitingForStart() && c.pulsing && !c.pulseOn;
        if (hint && !blinkedOff) {
            drawStartHint(dc, Graphics.COLOR_LT_GRAY, 5);
        }
        if (empty && c.popup.length() == 0) {
            drawLines(dc, Settings.text(Rez.Strings.PressStartToSpeak), Graphics.FONT_XTINY, h * 0.42,
                Graphics.COLOR_WHITE);
        }

        // XTINY: TINY fits only three lines of a reply on this screen - TINY is the "large" setting
        var font = Settings.largeText() ? Graphics.FONT_TINY : Graphics.FONT_XTINY;
        var items = [] as Array<Array>;
        var anchor = -1;  // the latest command - it stays at the top of the conversation area
        for (var i = 0; i < c.history.size(); i++) {
            var entry = c.history[i];
            if (entry[0] == ENTRY_DIVIDER) {
                items.add(Bubbles.dividerItem(dc, Settings.text(Rez.Strings.NewConversation), font));
                continue;
            }
            anchor = items.size();
            items.add(Bubbles.textItem(dc, entry[1] as String, font, true, Bubbles.COMMAND_BUBBLE, Graphics.COLOR_WHITE));
            if (entry[3] == true) {
                // A command that failed: a short grey note, the error itself is gone with its moment
                items.add(Bubbles.noteItem(dc, Settings.text(Rez.Strings.NoReply), font));
            } else if ((entry[2] as String).length() > 0) {
                items.add(Bubbles.textItem(dc, entry[2] as String, font, false, Bubbles.REPLY_BUBBLE,
                    Graphics.COLOR_WHITE));
            }
        }
        var taking = s == STATE_LISTENING || s == STATE_RECOGNIZING;
        if (c.heard.length() > 0 && !taking) {
            anchor = items.size();
            items.add(Bubbles.textItem(dc, c.heard, font, true, Bubbles.COMMAND_BUBBLE, Graphics.COLOR_WHITE));
        } else if (taking) {
            // Blue dots where the command will appear. Listening: the three pulse together - the
            // voice coming in; recognising: they light up in turn, as the grey dots of the agent
            // answering - a result being worked out (the two states must not look the same)
            anchor = items.size();
            items.add(Bubbles.dotsItem(true, Bubbles.COMMAND_BUBBLE, s == STATE_LISTENING));
        }
        if (s == STATE_SENDING) {
            // The reply waits for "Thinking" to have stayed its minimum
            if (revealed) {
                items.add(Bubbles.dotsItem(false, Bubbles.REPLY_BUBBLE, false));
            }
        } else if (c.reply.length() > 0 && s != STATE_ERROR && !taking) {
            items.add(Bubbles.textItem(dc, c.reply, font, false, Bubbles.REPLY_BUBBLE, Graphics.COLOR_WHITE));
        }
        // Bubbles scroll under the line
        var lineY = drawHeaderLine(dc);
        // An error: like a system screen in the middle, not a reply bubble (orange on grey read
        // pink on purple on this screen, and it looked as if the assistant said it)
        if (s == STATE_ERROR) {
            drawNotice(dc, lineY, NOTICE_ERROR, c.error, c.errorHint);
            return;
        }
        // A popup the same way, in place of the bubbles - not a framed box over them; once the
        // screen has caught up with the state (it follows a waiting look's minimum too)
        if (c.popup.length() > 0 && c.shown.settled()) {
            var kind = c.popupKind;
            drawNotice(dc, lineY,
                kind == POPUP_PAIRED ? NOTICE_DONE : kind == POPUP_NOT_HEARD ? NOTICE_QUESTION
                    : kind == POPUP_TEXT_ONLY || kind == POPUP_VOICE_FAILED ? NOTICE_SPEAKER_OFF : NOTICE_SPEAKER,
                c.popup, kind == POPUP_NOT_HEARD ? Settings.text(Rez.Strings.NotHeardHint) : "");
            return;
        }
        // A new command: back to it
        if (c.commandCount != _commandsSeen) {
            _commandsSeen = c.commandCount;
            _scroller.reset();
        }
        _scroller.lineHeight = dc.getFontHeight(font);
        _scroller.advance(System.getTimer());
        _scroller.limitTo(Bubbles.drawConversation(dc, items, font, lineY + 6, h * 0.86, c.tick,
            _scroller.scroll, anchor));
        if (_scroller.gliding()) {
            WatchUi.requestUpdate();
        }
    }

    const MARK_RADIUS = 11;     // the mark on the error screen and the popups

    //! The error screen and the popups, one layout in place of the bubbles: a small white mark,
    //! the message in white, what to do below it in grey
    private function drawNotice(dc as Dc, top as Numeric, icon as NoticeIcon, message as String,
            hint as String) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var y = top + (h * 0.86 - top) * 0.18;
        var cy = y + MARK_RADIUS;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        if (icon == NOTICE_ERROR || icon == NOTICE_QUESTION) {
            // White, as what matters on every screen; the colour stays in the status line only
            dc.setPenWidth(3);
            dc.drawCircle(cx, cy, MARK_RADIUS);
            dc.setPenWidth(1);
            dc.drawText(cx, cy, Graphics.FONT_XTINY, icon == NOTICE_ERROR ? "!" : "?",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else if (icon == NOTICE_DONE) {
            dc.setPenWidth(3);
            dc.drawLine(cx - 10, cy, cx - 3, cy + 7);
            dc.drawLine(cx - 3, cy + 7, cx + 10, cy - 7);
            dc.setPenWidth(1);
        } else {
            // The status line's speaker, at the mark's size
            drawSpeaker(dc, cx, cy, icon == NOTICE_SPEAKER_OFF, 1.6, Graphics.COLOR_WHITE);
        }
        y += 2 * MARK_RADIUS + 8;
        var font = Settings.largeText() ? Graphics.FONT_TINY : Graphics.FONT_XTINY;
        var text = Graphics.fitTextToArea(message, font, w * 0.72, h * 0.3, true);
        if (text != null) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, y, font, text, Graphics.TEXT_JUSTIFY_CENTER);
            y += Bubbles.split(text).size() * dc.getFontHeight(font) + 6;
        }
        if (hint.length() > 0) {
            var small = Graphics.fitTextToArea(hint, Graphics.FONT_XTINY, w * 0.7, h * 0.3, true);
            if (small != null) {
                dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, y, Graphics.FONT_XTINY, small, Graphics.TEXT_JUSTIFY_CENTER);
            }
        }
    }

    //! "Stay?" over the seconds left, a ring along the bezel running out with them; a tick by
    //! START (yes, stay) and a cross by BACK (no, close now), as the watch's own yes / no questions -
    //! under "Closing in" a tick read as "yes, close"
    private function drawCountdown(dc as Dc, seconds as Number, from as Number) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var r = w / 2;
        // The ring: from 12 o'clock clockwise, what is left of the time
        var left = from > 0 ? seconds.toFloat() / from : 1.0;
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(4);
        dc.drawCircle(r, r, r - 4);
        if (left > 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(6);
            var end = 90 - (360 * left).toNumber();
            dc.drawArc(r, r, r - 4, Graphics.ARC_CLOCKWISE, 90, end == 90 ? 89 : end);
        }
        dc.setPenWidth(1);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        // The question close over the seconds - one block, not spread over the screen
        dc.drawText(cx, h * 0.28, Graphics.FONT_SMALL, Settings.text(Rez.Strings.CountdownQuestion), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.55, Graphics.FONT_NUMBER_HOT, seconds.toString(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        // START at 2 o'clock, BACK at 4 o'clock on the bezel
        var tick = bezelPoint(r, START_ANGLE, r - 32);
        var cross = bezelPoint(r, -START_ANGLE, r - 32);
        // Green and red, as the system's own YES / NO (the "Pair again" question)
        dc.setPenWidth(4);
        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(tick[0] - 11, tick[1], tick[0] - 3, tick[1] + 8);
        dc.drawLine(tick[0] - 3, tick[1] + 8, tick[0] + 11, tick[1] - 8);
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cross[0] - 9, cross[1] - 9, cross[0] + 9, cross[1] + 9);
        dc.drawLine(cross[0] - 9, cross[1] + 9, cross[0] + 9, cross[1] - 9);
        dc.setPenWidth(1);
    }

    //! A point at `angle` degrees (0 = 3 o'clock, counter-clockwise) and `radius` from the centre
    private function bezelPoint(r as Number, angle as Number, radius as Number) as Array<Float> {
        var a = Math.toRadians(angle);
        return [r + radius * Math.cos(a), r - radius * Math.sin(a)] as Array<Float>;
    }

    //! A small grey speaker; with a slash for "text only", with a sound wave otherwise
    //! `scale` 1 in the status line, the mark's size on a popup
    private function drawSpeaker(dc as Dc, x as Numeric, y as Numeric, muted as Boolean, scale as Numeric,
            color as Number) as Void {
        var k = scale;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x - 6 * k, y - 2 * k, 3 * k, 5 * k);
        dc.fillPolygon([[x - 3 * k, y - 2 * k], [x + 1 * k, y - 6 * k], [x + 1 * k, y + 7 * k], [x - 3 * k, y + 3 * k]]);
        dc.setPenWidth((2 * k).toNumber());
        if (muted) {
            dc.drawLine(x - 7 * k, y + 6 * k, x + 7 * k, y - 6 * k);
        } else {
            dc.drawArc(x + 1 * k, y, 5 * k, Graphics.ARC_COUNTER_CLOCKWISE, -40, 40);
        }
        dc.setPenWidth(1);
    }

    //! Garmin-style hint: an arc on the bezel next to the START button
    private function drawStartHint(dc as Dc, color as Number, width as Number) as Void {
        var r = dc.getWidth() / 2;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(width);
        dc.drawArc(r, r, r - 3, Graphics.ARC_COUNTER_CLOCKWISE, START_ANGLE - 9, START_ANGLE + 9);
        dc.setPenWidth(1);
    }
}
