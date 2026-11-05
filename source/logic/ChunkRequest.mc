import Toybox.Lang;
import Toybox.System;

//! One try of sending a chunk of the command: where it is in the recording, when it went, how many
//! tries so far. A try that is given up (no answer in time) is abandoned - its late answer is ignored
//! and a new try goes; the integration ignores a chunk it already has.
class ChunkRequest {

    var offset as Number;
    var size as Number;
    var final as Boolean;
    var tries as Number;
    var sentAt as Number;
    var abandoned as Boolean = false;

    private var _onResult as Method(request as ChunkRequest, result as Result) as Void;

    function initialize(offset as Number, size as Number, final as Boolean, tries as Number,
            onResult as Method(request as ChunkRequest, result as Result) as Void) {
        self.offset = offset;
        self.size = size;
        self.final = final;
        self.tries = tries;
        sentAt = System.getTimer();
        _onResult = onResult;
    }

    //! The same chunk again, one try more
    function next() as ChunkRequest {
        return new ChunkRequest(offset, size, final, tries + 1, _onResult);
    }

    function onResult(result as Result) as Void {
        if (!abandoned) {
            _onResult.invoke(self, result);
        }
    }
}
