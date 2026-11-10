import Toybox.Lang;

//! The reply's voice as it comes, in Ogg pages: how much speech is in (from the pages' granules),
//! whether the last page has come (the end-of-stream flag), and the bytes for a new stream from a
//! page. The integration sends whole pages; a piece that is not whole pages or skips a page number
//! is refused as a whole (asked again from the same offset).
class OggPages {

    const HEADER = 27;           // "OggS", version, flags, granule, serial, sequence, CRC, segments
    const END_OF_STREAM = 0x04;
    const GRANULES_PER_MS = 48;  // Opus granules: 48 kHz

    //! Bytes in so far - the offset to ask from next
    var size as Number = 0;
    //! The last page has come
    var ended as Boolean = false;

    private var _data as ByteArray = []b;
    private var _starts as Array<Number> = [] as Array<Number>;
    private var _granules as Array<Number> = [] as Array<Number>;
    private var _headerEnd as Number = 0;  // after the two header pages (OpusHead, OpusTags)

    function initialize() {
    }

    //! True when the piece was whole pages, the next in number; nothing is taken otherwise
    function add(piece as ByteArray) as Boolean {
        if (ended || piece.size() == 0) {
            return false;
        }
        var starts = [] as Array<Number>;
        var granules = [] as Array<Number>;
        var sequence = _starts.size();
        var eos = false;
        var pos = 0;
        while (pos < piece.size()) {
            if (eos || pos + HEADER > piece.size() || !isPageStart(piece, pos)) {
                return false;
            }
            var segments = piece[pos + 26] as Number;
            var length = HEADER + segments;
            if (pos + length > piece.size()) {
                return false;
            }
            for (var i = 0; i < segments; i++) {
                length += piece[pos + HEADER + i] as Number;
            }
            if (pos + length > piece.size() || number(piece, pos + 18) != sequence) {
                return false;
            }
            starts.add(size + pos);
            // The low 32 bits are enough (12 hours); -1: no packet ends on the page - the speech so far
            var granule = number(piece, pos + 6);
            if (granule < 0) {
                granule = granules.size() > 0 ? granules[granules.size() - 1]
                    : _granules.size() > 0 ? _granules[_granules.size() - 1] : 0;
            }
            granules.add(granule);
            eos = ((piece[pos + 5] as Number) & END_OF_STREAM) != 0;
            sequence++;
            pos += length;
        }
        _data.addAll(piece);
        _starts.addAll(starts);
        _granules.addAll(granules);
        size += piece.size();
        ended = eos;
        if (_headerEnd == 0 && _starts.size() > 2) {
            _headerEnd = _starts[2];
        }
        return true;
    }

    //! The speech in so far (ms)
    function speechMs() as Number {
        return _granules.size() > 0 ? _granules[_granules.size() - 1] / GRANULES_PER_MS : 0;
    }

    //! The bytes from `offset` on
    function bytes(offset as Number) as ByteArray {
        return _data.slice(offset, null);
    }

    //! A new stream from the page holding `positionMs`: the header pages, then that page and the
    //! rest. Null while the header pages are not in
    function fromPosition(positionMs as Number) as ByteArray? {
        var page = pageAt(positionMs);
        if (page < 0) {
            return null;
        }
        var data = _data.slice(0, _headerEnd);
        data.addAll(_data.slice(_starts[page], null));
        return data;
    }

    //! Where the stream from `fromPosition` starts in the speech (ms): its position 0
    function startMs(positionMs as Number) as Number {
        var page = pageAt(positionMs);
        return page > 2 ? _granules[page - 1] / GRANULES_PER_MS : 0;
    }

    //! The first audio page whose speech ends past `positionMs`; -1 without one
    private function pageAt(positionMs as Number) as Number {
        if (_headerEnd == 0) {
            return -1;
        }
        var granule = positionMs * GRANULES_PER_MS;
        for (var page = 2; page < _starts.size(); page++) {
            if (_granules[page] > granule) {
                return page;
            }
        }
        return -1;
    }

    private function isPageStart(data as ByteArray, pos as Number) as Boolean {
        return data[pos] == 0x4f && data[pos + 1] == 0x67 && data[pos + 2] == 0x67 && data[pos + 3] == 0x53;
    }

    private function number(data as ByteArray, pos as Number) as Number {
        return data.decodeNumber(Lang.NUMBER_FORMAT_SINT32,
            { :offset => pos, :endianness => Lang.ENDIAN_LITTLE }) as Number;
    }
}
