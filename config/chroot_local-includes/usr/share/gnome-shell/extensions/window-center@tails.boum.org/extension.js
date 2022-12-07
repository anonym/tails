const Main = imports.ui.main;
const GLib = imports.gi.GLib;

/*
  This extension is based on the All Windows + Save/Restore Window Positions GNOME Shell extension (https://github.com/jkavery/all-windows) by jkavery.
  It saves/restores window positions automatically.
*/

const EXTENSION_NAME = 'Window Center';

// At module scope to ride out the extension disable/enable for a system suspend/resume
// Note that this appears to violate https://gjs.guide/extensions/review-guidelines/review-guidelines.html#destroy-all-objects
// though the earlier the example shows init() creating an extension object.  The extension object is empty, but it's still an object.
// This map will contain primitives but never any object references.  Are Gobject references what the guidelines are actually prohibiting?
// If this extension were written in the style shown in the guidelines, it looks like this would be part of the Extension class,
// initialized by init().
const displaySize__windowId__state = new Map();

// The following are only used for logging
const EXTENSION_LOG_NAME = 'Window Center';
const START_TIME = GLib.DateTime.new_now_local().format_iso8601();

const LOG_NOTHING = 0;
const LOG_ERROR = 1;
const LOG_INFO = 2;
const LOG_DEBUG = 3;
const LOG_EVERYTHING = 4;

const LOG_LEVEL = LOG_ERROR;


function _getWindows() {
    return global.get_window_actors().map(a => a.meta_window).filter(w => !w.is_skip_taskbar());
}

function centerEveryWindow() {
    for (const window of this._getWindows()) {
        let workArea = Main.layoutManager.getWorkAreaForMonitor(Main.layoutManager.primaryIndex);
        let screenWidth = workArea.width
        let screenHeight = workArea.height
        let rect = window.get_frame_rect();
        let winWidth = rect.width
        let winHeight = rect.height

        // we need to decide the top-left corner, so to make it centered compared to screen
        let x = (screenWidth/2 - winWidth/2)
        let y = (screenHeight/2 - winHeight/2)
        window.move_resize_frame(true, x, y, rect.width, rect.height);
        rect = window.get_frame_rect()
        global.log(`${EXTENSION_LOG_NAME} moved: ${rect.x}-${rect.y}+${rect.width}x${rect.height}`);
    }
}

let _interval;

function init() {
}


function enable() {
    centerEveryWindow();
    // XXX: this timer is incredibly fast, because that's the easiest way to have a snappy UI
    // as a "mitigation" for the high CPU cost, we only run it a few times
    // a better solution would be stopping as soon as the only relevant window has been found and moved
    let intervalMS = 50;
    let totalTime = 3000;
    let refreshCount=totalTime / intervalMS;
    _interval = GLib.timeout_add(GLib.PRIORITY_DEFAULT,
        intervalMS, /* milliseconds */
        () => {
            refreshCount-=1;
            centerEveryWindow();
            if (refreshCount<=0) return GLib.SOURCE_REMOVE;
            else return GLib.SOURCE_CONTINUE;
        });
}

function disable() {
    if (_interval)
        GLib.source_remove(_interval);
}
