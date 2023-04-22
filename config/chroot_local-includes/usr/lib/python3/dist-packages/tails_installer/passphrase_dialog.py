import os

from gi.repository import Gdk, Gio, GLib, Gtk
from typing import TYPE_CHECKING

from tails_installer import _, TailsInstallerError
from tails_installer.tps_proxy import tps_proxy
from tails_installer.utils import _get_datadir
from tps.dbus.errors import DBusError

PASSPHRASE_DIALOG_UI_FILE = os.path.join(_get_datadir(), "passphrase_dialog.ui")

if TYPE_CHECKING:
    from gi.repository import GObject
    from tails_installer.creator import TailsInstallerCreator
    from tails_installer.gui import TailsInstallerWindow


@Gtk.Template.from_file(PASSPHRASE_DIALOG_UI_FILE)
class PassphraseDialog(Gtk.Dialog):
    __gtype_name__ = "PassphraseDialog"

    ok_button = Gtk.Template.Child()  # type: Gtk.Button
    cancel_button = Gtk.Template.Child()  # type: Gtk.Button
    passphrase_entry = Gtk.Template.Child()  # type: Gtk.Entry
    error_infobar = Gtk.Template.Child()  # type: Gtk.InfoBar
    error_infobar_label = Gtk.Template.Child()  # type: Gtk.Label

    def __init__(self, parent: "TailsInstallerWindow", creator: "TailsInstallerCreator",
                 *args, **kwargs):
        super().__init__(use_header_bar=1, *args, **kwargs)
        self.parent = parent
        self.live = creator
        self.passphrase = None
        self.passphrase_is_correct = False

        self.title = _("Enter Passphrase")
        self.set_transient_for(self.parent)
        self.set_destroy_with_parent(True)

    def run(self):
        self.passphrase_entry.grab_focus()
        self.ok_button.grab_default()
        super().run()

    @Gtk.Template.Callback()
    def on_cancel_button_clicked(self, button: Gtk.Button):
        self.destroy()

    @Gtk.Template.Callback()
    def on_ok_button_clicked(self, button: Gtk.Button):
        # The operation will take a few seconds, so we make the cursor a
        # spinner to signal that things are in progress
        spinning_cursor = Gdk.Cursor.new(Gdk.CursorType.WATCH)
        self.get_window().set_cursor(spinning_cursor)

        self.set_sensitive(False)

        self.passphrase = self.passphrase_entry.get_text()

        # Test the passphrase
        tps_proxy.call(
            method_name="TestPassphrase",
            parameters=GLib.Variant("(s)", (self.passphrase,)),
            flags=Gio.DBusCallFlags.NONE,
            timeout_msec=GLib.MAXINT,
            cancellable=None,
            callback=self.on_test_passphrase_finished,
        )

    def on_test_passphrase_finished(self, proxy: "GObject.Object",
                                    res: Gio.AsyncResult):
        try:
            is_correct = proxy.call_finish(res).unpack()[0]
        except GLib.Error as e:
            DBusError.strip_remote_error(e)
            self.destroy()
            error_msg = _('Failed to test passphrase: {message}').format(
                message=str(e),
            )
            self.parent.status(error_msg)
            return

        self.live.log.debug(f"Passphrase test result: {is_correct}")
        if not is_correct:
            self.set_sensitive(True)
            self.get_window().set_cursor(None)
            self.passphrase_entry.grab_focus()
            self.passphrase_entry.set_icon_from_icon_name(
                1, "dialog-error-symbolic")
            self.error_infobar_label.set_text(
                _("The passphrase you entered is incorrect."))
            self.error_infobar.show_all()
            return

        self.passphrase_is_correct = True
        self.destroy()

    @Gtk.Template.Callback()
    def on_passphrase_entry_changed(self, entry: Gtk.Entry):
        # Hide the error infobar (if there is any)
        self.error_infobar.hide()
        # Hide the warning icon (if there is any)
        entry.set_icon_from_icon_name(1, None)
        self.ok_button.set_sensitive(entry.get_text())

    @Gtk.Template.Callback()
    def on_show_passphrase_button_toggled(self, button: Gtk.Button):
        is_active = button.get_active()
        self.passphrase_entry.set_visibility(is_active)
