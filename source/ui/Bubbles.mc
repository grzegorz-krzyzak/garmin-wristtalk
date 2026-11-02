import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;

enum ItemKind {
    ITEM_TEXT,
    ITEM_DOTS,
    ITEM_NOTE,
    ITEM_DIVIDER
}

//! Drawing of the conversation: chat bubbles (commands blue on the right, replies grey on the left),
//! "typing" dots, notes, the "new conversation" divider, the bezel scroll bar. Sizes and colours
//! for the fēnix 8 Solar 51 mm (MIP, 64 colours); another screen family gets its own constants.
module Bubbles {

    const COMMAND_BUBBLE = 0x0055AA;
    const REPLY_BUBBLE = 0x555555;
    const BUBBLE_TEXT = 0.6;   // widest text line, of the screen width
    const SIDE_LEFT = 0.13;    // the reply's left edge; the command's right edge mirrors it
    const SIDE_RIGHT = 0.87;
    const PAD = 6;
    const RADIUS = 8;
    const GAP = 8;
    const DOTS_WIDTH = 56;
    const DOTS_HEIGHT = 24;

    //! [kind, lines, right, fill, textColor]
    function textItem(dc as Dc, text as String, font as FontDefinition, right as Boolean, fill as Number,
            textColor as Number) as Array {
        var wrapped = Graphics.fitTextToArea(text, font, dc.getWidth() * BUBBLE_TEXT, 10000, false);
        return [ITEM_TEXT, split(wrapped != null ? wrapped : text), right, fill, textColor];
    }

    function noteItem(dc as Dc, text as String, font as FontDefinition) as Array {
        var item = textItem(dc, text, font, false, 0, Graphics.COLOR_LT_GRAY);
        item[0] = ITEM_NOTE;
        return item;
    }

    function dotsItem(right as Boolean, fill as Number) as Array {
        return [ITEM_DOTS, null, right, fill, 0];
    }

    function dividerItem(dc as Dc, text as String, font as FontDefinition) as Array {
        return [ITEM_DIVIDER, [text], false, 0, Graphics.COLOR_DK_GRAY];
    }

    function itemHeight(dc as Dc, item as Array, font as FontDefinition) as Number {
        if (item[0] == ITEM_DOTS) {
            return DOTS_HEIGHT;
        }
        var lines = (item[1] as Array).size() * dc.getFontHeight(font);
        return item[0] == ITEM_TEXT ? lines + 2 * PAD : lines;
    }

    //! Top-aligned while it fits (nothing jumps). When it does not fit, the latest command (item
    //! `anchor`) stands right under the line below the status and its reply below it - the reply
    //! arriving does not push the command out of sight. `scroll` is in lines
    //! from there: positive = back to earlier messages (UP), negative = further down a long reply
    //! (DOWN). Returns the scroll clamped to what the conversation allows.
    function drawConversation(dc as Dc, items as Array<Array>, font as FontDefinition, top as Numeric,
            bottom as Numeric, tick as Number, scroll as Number, anchor as Number) as Number {
        var tops = [] as Array<Number>;
        var total = 0;
        for (var i = 0; i < items.size(); i++) {
            total += i > 0 ? GAP : 0;
            tops.add(total);
            total += itemHeight(dc, items[i], font);
        }
        var area = bottom - top;
        var overflow = total > area ? (total - area).toNumber() : 0;
        var lineHeight = dc.getFontHeight(font);
        var base = anchor >= 0 && anchor < tops.size() ? tops[anchor] : overflow;
        if (base > overflow) {
            base = overflow;
        }
        var maxBack = (base + lineHeight - 1) / lineHeight;
        var maxForward = (overflow - base + lineHeight - 1) / lineHeight;
        if (scroll > maxBack) {
            scroll = maxBack;
        }
        if (scroll < -maxForward) {
            scroll = -maxForward;
        }
        var offset = base - scroll * lineHeight;
        if (offset < 0) {
            offset = 0;
        }
        if (offset > overflow) {
            offset = overflow;
        }
        dc.setClip(0, top, dc.getWidth(), area);
        for (var i = 0; i < items.size(); i++) {
            var y = top - offset + tops[i];
            var ih = itemHeight(dc, items[i], font);
            if (y + ih > top && y < bottom) {
                drawItem(dc, items[i], font, y, tick);
            }
        }
        dc.clearClip();
        if (overflow > 0) {
            drawScrollBar(dc, total, area, offset);
        }
        return scroll;
    }

    function drawItem(dc as Dc, item as Array, font as FontDefinition, y as Numeric, tick as Number) as Void {
        var kind = item[0];
        if (kind == ITEM_DOTS) {
            drawDotsBubble(dc, y, item[2] as Boolean, item[3] as Number, tick);
        } else if (kind == ITEM_TEXT) {
            drawBubble(dc, item[1] as Array<String>, font, y, item[2] as Boolean, item[3] as Number,
                item[4] as Number);
        } else {
            var lines = item[1] as Array<String>;
            var lineHeight = dc.getFontHeight(font);
            dc.setColor(item[4] as Number, Graphics.COLOR_TRANSPARENT);
            for (var k = 0; k < lines.size(); k++) {
                dc.drawText(dc.getWidth() / 2, y + k * lineHeight, font, lines[k], Graphics.TEXT_JUSTIFY_CENTER);
            }
            if (kind == ITEM_DIVIDER) {
                // A thin line on both sides of "new conversation"
                var tw = dc.getTextWidthInPixels(lines[0], font);
                var mid = y + lineHeight / 2;
                var w = dc.getWidth();
                dc.drawLine(w * SIDE_LEFT, mid, w / 2 - tw / 2 - 6, mid);
                dc.drawLine(w / 2 + tw / 2 + 6, mid, w * SIDE_RIGHT, mid);
            }
        }
    }

    //! A rounded bubble around the lines, against the right (command) or the left (reply) side
    function drawBubble(dc as Dc, lines as Array<String>, font as FontDefinition, top as Numeric,
            right as Boolean, fill as Number, textColor as Number) as Number {
        var lineHeight = dc.getFontHeight(font);
        var textWidth = 0;
        for (var i = 0; i < lines.size(); i++) {
            var lw = dc.getTextWidthInPixels(lines[i], font);
            if (lw > textWidth) {
                textWidth = lw;
            }
        }
        var bw = textWidth + 2 * PAD;
        var bh = lines.size() * lineHeight + 2 * PAD;
        var w = dc.getWidth();
        var left = right ? w * SIDE_RIGHT - bw : w * SIDE_LEFT;
        dc.setColor(fill, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(left, top, bw, bh, RADIUS);
        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < lines.size(); i++) {
            dc.drawText(left + PAD, top + PAD + i * lineHeight, font, lines[i], Graphics.TEXT_JUSTIFY_LEFT);
        }
        return bh.toNumber();
    }

    //! "Typing…": three dots lighting up in turn inside a small bubble where the text will appear
    function drawDotsBubble(dc as Dc, top as Numeric, right as Boolean, fill as Number, tick as Number) as Void {
        var w = dc.getWidth();
        var left = right ? w * SIDE_RIGHT - DOTS_WIDTH : w * SIDE_LEFT;
        dc.setColor(fill, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(left, top, DOTS_WIDTH, DOTS_HEIGHT, RADIUS);
        var active = (tick / 3) % 3;
        for (var i = 0; i < 3; i++) {
            dc.setColor(i == active ? Graphics.COLOR_WHITE : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(left + DOTS_WIDTH / 2 + (i - 1) * 14, top + DOTS_HEIGHT / 2, 3);
        }
    }

    //! Garmin-style scroll bar on the left bezel (the right side is the START hint)
    function drawScrollBar(dc as Dc, total as Number, area as Numeric, offset as Numeric) as Void {
        var r = dc.getWidth() / 2;
        var from = 215;  // degrees, 0 = 3 o'clock, counter-clockwise: the bottom of the bar
        var span = 70;
        dc.setPenWidth(3);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(r, r, r - 4, Graphics.ARC_CLOCKWISE, from, from - span);
        var thumb = span * area / total;
        if (thumb < 8) {
            thumb = 8;
        }
        // offset 0 = the top of the conversation = the upper end of the bar (the smaller angle)
        var start = from - span + (span - thumb) * (offset.toFloat() / (total - area));
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(r, r, r - 4, Graphics.ARC_CLOCKWISE, (start + thumb).toNumber(), start.toNumber());
        dc.setPenWidth(1);
    }

    //! Half the width of the round screen at height y
    function chordHalf(dc as Dc, y as Numeric) as Float {
        var r = dc.getWidth() / 2.0;
        var d = r - y;
        return Math.sqrt(r * r - d * d).toFloat();
    }

    //! fitTextToArea wraps with "\n"
    function split(text as String) as Array<String> {
        var lines = [] as Array<String>;
        var rest = text;
        var i = rest.find("\n");
        while (i != null) {
            lines.add(rest.substring(0, i) as String);
            rest = rest.substring(i + 1, rest.length()) as String;
            i = rest.find("\n");
        }
        lines.add(rest);
        return lines;
    }
}
