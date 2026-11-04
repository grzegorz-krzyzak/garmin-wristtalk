import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! Draws what the conversation holds; knows nothing about the network
class AssistView extends WatchUi.View {

    // The START button sits at about 2 o'clock on the fenix bezel (degrees: 0 = 3 o'clock,
    // counter-clockwise)
    const START_ANGLE = 30;
    const ICON_Y = 0.05;       // the reply-mode icon (centre), of the screen height
    const STATUS_Y = 0.09;     // the status line (top), of the screen height
    const SPEAKER_ASIDE = 34;  // the speaker icon right of the middle (the system microphone's place)

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
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        if (_c.state == STATE_PAIRING) {
            drawPairing(dc);
        } else {
            drawConversationScreen(dc);
        }
        if (_c.idle.countdown > 0) {
            drawCountdown(dc, _c.idle.countdown);
        } else if (_c.popup.length() > 0) {
            drawPopup(dc, _c.popup);
        }
    }

    //! The pairing code to compare with Home Assistant, or what to do first
    private function drawPairing(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var font = Graphics.FONT_XTINY;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, STATUS_Y * h, font, Settings.text(Rez.Strings.PairTitle), Graphics.TEXT_JUSTIFY_CENTER);
        var notice = _c.pairing.notice;
        var code = _c.pairing.code;
        if (code.length() == 6) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.38, Graphics.FONT_NUMBER_MEDIUM, code.substring(0, 3) + " " + code.substring(3, 6),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            drawLines(dc, Settings.text(Rez.Strings.PairConfirmInHa), font, h * 0.55);
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
            drawLines(dc, notice, font, h * 0.35);
        }
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

    private function drawLines(dc as Dc, text as String, font as FontDefinition, top as Numeric) as Void {
        var fitted = Graphics.fitTextToArea(text, font, dc.getWidth() * 0.74, dc.getHeight() * 0.4, true);
        if (fitted != null) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
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
        if (c.state == STATE_CONNECTING) {
            status = c.connectingShown ? Settings.text(Rez.Strings.StatusConnecting) : "";
            hint = false;
        } else if (c.state == STATE_LISTENING) {
            status = Settings.text(Rez.Strings.StatusListening);
        } else if (c.state == STATE_RECOGNIZING) {
            status = Settings.text(Rez.Strings.StatusRecognizing);
            hint = false;
        } else if (c.state == STATE_SENDING) {
            status = Settings.text(Rez.Strings.StatusThinking);
            hint = false;
        } else if (c.state == STATE_PLAYING) {
            status = Settings.text(Rez.Strings.StatusReplying);
        } else if (c.state == STATE_ERROR) {
            status = Settings.text(Rez.Strings.StatusError);
            color = Graphics.COLOR_ORANGE;
        }
        // While listening the watch shows its own microphone in the middle of the top: it is the
        // recording light, so the status and the red dot are left out (photo on the fēnix 8)
        if (c.state == STATE_LISTENING) {
            status = "";
        }
        if (status.length() > 0) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, STATUS_Y * h, Graphics.FONT_XTINY, status, Graphics.TEXT_JUSTIFY_CENTER);
            if (c.state == STATE_LISTENING) {
                var textWidth = dc.getTextWidthInPixels(status, Graphics.FONT_XTINY);
                drawRecordingDot(dc, w / 2 - textWidth / 2 - 10,
                    STATUS_Y * h + dc.getFontHeight(Graphics.FONT_XTINY) / 2, c.tick);
            }
        }
        // The reply mode, always shown at one fixed place right of the middle - the middle is where
        // the watch shows its microphone while listening; hold UP switches it
        if (Capabilities.hasSpeaker()) {
            drawSpeaker(dc, w / 2 + SPEAKER_ASIDE, ICON_Y * h, Settings.textOnly());
        }
        // The START arc: pulsing while the app waits for START, steady where START may be pressed,
        // none where it does nothing. An empty idle screen also says what to do.
        var empty = c.state == STATE_IDLE && c.isEmpty();
        if (hint) {
            var pulse = c.waitingForStart() && c.pulsing && c.tick % 2 == 0;
            drawStartHint(dc, pulse ? Graphics.COLOR_DK_GRAY : Graphics.COLOR_LT_GRAY);
        }
        if (empty) {
            drawLines(dc, Settings.text(Rez.Strings.PressStartToSpeak), Graphics.FONT_XTINY, h * 0.42);
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
            if ((entry[2] as String).length() > 0) {
                items.add(Bubbles.textItem(dc, entry[2] as String, font, false, Bubbles.REPLY_BUBBLE,
                    entry[3] == true ? Graphics.COLOR_ORANGE : Graphics.COLOR_WHITE));
            }
        }
        if (c.heard.length() > 0) {
            anchor = items.size();
            items.add(Bubbles.textItem(dc, c.heard, font, true, Bubbles.COMMAND_BUBBLE, Graphics.COLOR_WHITE));
        } else if (c.state == STATE_LISTENING || c.state == STATE_RECOGNIZING) {
            // Blue "typing" dots where the command will appear: the voice is being taken in; grey
            // dots stay for the agent answering
            anchor = items.size();
            items.add(Bubbles.dotsItem(true, Bubbles.COMMAND_BUBBLE));
        }
        if (c.state == STATE_SENDING && c.reply.length() == 0) {
            items.add(Bubbles.dotsItem(false, Bubbles.REPLY_BUBBLE));
        } else if (c.state == STATE_ERROR) {
            items.add(Bubbles.textItem(dc, c.error, font, false, Bubbles.REPLY_BUBBLE, Graphics.COLOR_ORANGE));
        } else if (c.reply.length() > 0) {
            items.add(Bubbles.textItem(dc, c.reply, font, false, Bubbles.REPLY_BUBBLE, Graphics.COLOR_WHITE));
        }
        // A thin line between the status and the conversation; bubbles scroll under it
        var lineY = (STATUS_Y * h + dc.getFontHeight(Graphics.FONT_XTINY) + 4).toNumber();
        var half = Bubbles.chordHalf(dc, lineY) * 0.7;
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(w / 2 - half, lineY, w / 2 + half, lineY);
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

    //! A framed note in the middle, over everything, like a system popup; wraps a longer text
    private function drawPopup(dc as Dc, text as String) as Void {
        var font = Graphics.FONT_XTINY;
        var wrapped = Graphics.fitTextToArea(text, font, dc.getWidth() * 0.62, dc.getHeight() * 0.5, true);
        var lines = Bubbles.split(wrapped != null ? wrapped : text);
        var tw = 0;
        for (var i = 0; i < lines.size(); i++) {
            var lw = dc.getTextWidthInPixels(lines[i], font);
            if (lw > tw) {
                tw = lw;
            }
        }
        var lineHeight = dc.getFontHeight(font);
        var bw = tw + 28;
        var bh = lines.size() * lineHeight + 16;
        var x = (dc.getWidth() - bw) / 2;
        var y = (dc.getHeight() - bh) / 2;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(x, y, bw, bh, 10);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawRoundedRectangle(x, y, bw, bh, 10);
        dc.setPenWidth(1);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < lines.size(); i++) {
            dc.drawText(dc.getWidth() / 2, y + 8 + i * lineHeight, font, lines[i], Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    //! "Closing in 10" with what START and BACK do, framed like the popup; the START arc lit
    private function drawCountdown(dc as Dc, seconds as Number) as Void {
        var font = Graphics.FONT_XTINY;
        var number = Graphics.FONT_NUMBER_MILD;
        var title = Settings.text(Rez.Strings.CountdownTitle);
        var keep = Settings.text(Rez.Strings.CountdownKeep);
        var close = Settings.text(Rez.Strings.CountdownClose);
        var tw = dc.getTextWidthInPixels(title, font);
        var lw = dc.getTextWidthInPixels(keep, font);
        if (lw > tw) {
            tw = lw;
        }
        lw = dc.getTextWidthInPixels(close, font);
        if (lw > tw) {
            tw = lw;
        }
        var lineHeight = dc.getFontHeight(font);
        var numberHeight = dc.getFontHeight(number);
        var bw = tw + 28;
        var bh = 3 * lineHeight + numberHeight + 24;
        var x = (dc.getWidth() - bw) / 2;
        var y = (dc.getHeight() - bh) / 2;
        var cx = dc.getWidth() / 2;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(x, y, bw, bh, 10);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawRoundedRectangle(x, y, bw, bh, 10);
        dc.setPenWidth(1);
        var top = y + 8;
        dc.drawText(cx, top, font, title, Graphics.TEXT_JUSTIFY_CENTER);
        top += lineHeight + 4;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, top, number, seconds.toString(), Graphics.TEXT_JUSTIFY_CENTER);
        top += numberHeight + 4;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, top, font, keep, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, top + lineHeight, font, close, Graphics.TEXT_JUSTIFY_CENTER);
        drawStartHint(dc, Graphics.COLOR_WHITE);
    }

    //! A small grey speaker; with a slash for "text only", with a sound wave otherwise
    private function drawSpeaker(dc as Dc, x as Numeric, y as Numeric, muted as Boolean) as Void {
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x - 6, y - 2, 3, 5);
        dc.fillPolygon([[x - 3, y - 2], [x + 1, y - 6], [x + 1, y + 7], [x - 3, y + 3]]);
        dc.setPenWidth(2);
        if (muted) {
            dc.drawLine(x - 7, y + 6, x + 7, y - 6);
        } else {
            dc.drawArc(x + 1, y, 5, Graphics.ARC_COUNTER_CLOCKWISE, -40, 40);
        }
        dc.setPenWidth(1);
    }

    //! Listening: a small red dot next to "Listening…" pulsing softly - the usual recording light
    private function drawRecordingDot(dc as Dc, x as Numeric, y as Numeric, tick as Number) as Void {
        var shades = [0xAA0000, 0xFF0000];
        dc.setColor(shades[(tick / 8) % shades.size()], Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, 4);
    }

    //! Garmin-style hint: an arc on the bezel next to the START button
    private function drawStartHint(dc as Dc, color as Number) as Void {
        var r = dc.getWidth() / 2;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(5);
        dc.drawArc(r, r, r - 3, Graphics.ARC_COUNTER_CLOCKWISE, START_ANGLE - 9, START_ANGLE + 9);
        dc.setPenWidth(1);
    }
}
