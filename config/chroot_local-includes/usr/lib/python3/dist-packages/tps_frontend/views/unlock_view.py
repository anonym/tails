from logging import getLogger
from gi.repository import Gio, GLib, Gtk
from typing import TYPE_CHECKING

from tps_frontend import UNLOCK_VIEW_UI_FILE
from tps_frontend.view import View

if TYPE_CHECKING:
    from tps_frontend.window import Window

logger = getLogger(__name__)

class UnlockView(View):
    _ui_file = UNLOCK_VIEW_UI_FILE

    def __init__(self, window: "Window"):
        super().__init__(window)
        self.passphrase_entry = self.builder.get_object("passphrase_entry")  # type: Gtk.Entry
        self.verify_hint_box = self.builder.get_object("verify_hint_box")  # type: Gtk.Box
        self.unlock_button = self.builder.get_object("unlock_button")  # type: Gtk.Button

    def show(self):
        super().show()
        self.passphrase_entry.grab_focus()
        self.unlock_button.grab_default()
        self.window.delete_button.show()

    def on_hide(self):
        self.window.delete_button.hide()

    def on_passphrase_entry_changed(self, entry: Gtk.Entry):
        has_text = bool(entry.get_text())
        self.unlock_button.set_sensitive(has_text)

    def on_unlock_button_clicked(self, button: Gtk.Button):
        passphrase = self.passphrase_entry.get_text()
        self.window.spinner_view.show()
        self.window.service_proxy.call(
            method_name="Unlock",
            parameters=GLib.Variant("(s)", (passphrase,)),
            flags=Gio.DBusCallFlags.NONE,
            # -1 means the default timeout of 25 seconds is used,
            # which should be enough.
            timeout_msec=-1,
            # XXX: Maybe support cancellation
            cancellable=None,
            callback=self.window.on_unlock_call_finished,
        )

    def on_show_passphrase_button_toggled(self, button: Gtk.CheckButton):
        is_active = button.get_active()
        self.passphrase_entry.set_visibility(is_active)
