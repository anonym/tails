from gi.repository import Gdk, Gio, Gtk
import inspect
from logging import getLogger
from typing import TYPE_CHECKING

from tps_frontend import FEATURES_VIEW_UI_FILE
from tps_frontend.view import View
from tps_frontend.feature import Feature

if TYPE_CHECKING:
    from tps_frontend.window import Window

logger = getLogger(__name__)

class PersistentDirectory(Feature):
    pass

class BrowserBookmarks(Feature):
    pass

class LanguageAndRegion(Feature):
    pass

class AdministrationPassword(Feature):
    pass

class Printers(Feature):
    pass

class NetworkConnections(Feature):
    pass

class Electrum(Feature):
    pass

class Thunderbird(Feature):
    pass

class GnuPG(Feature):
    switch_name = "gnupg_switch"

class Pidgin(Feature):
    pass

class SSHClient(Feature):
    pass

class AdditionalSoftware(Feature):
    pass

class Dotfiles(Feature):
    pass

def get_feature_classes():
    return [g for g in globals().values() if inspect.isclass(g)
            and Feature in g.__bases__]


class FeaturesView(View):
    _ui_file = FEATURES_VIEW_UI_FILE

    def __init__(self, window: "Window", bus: Gio.DBusConnection):
        super().__init__(window)
        self.bus = bus
        self.features = None

        # Append all non-default paths that contain icons to the search
        # paths
        # noinspection PyArgumentList
        icon_theme = Gtk.IconTheme.get_default()  # type: Gtk.IconTheme
        icon_theme.append_search_path(
            '/usr/share/seahorse/icons/hicolor/48x48/apps')

        # Set listbox header functions. This is required to add
        # separators between listboxrows.
        for listbox_name in ["personal_data_list_box",
                             "system_settings_list_box",
                             "network_list_box",
                             "applications_list_box",
                             "advanced_settings_list_box"]:
            listbox = self.builder.get_object(listbox_name)  # type: Gtk.ListBox
            listbox.set_header_func(self.add_separator)

    def show(self):
        super().show()
        if not self.features:
            self.features = [c(self.window, self.builder, self.bus)
                             for c in get_feature_classes()]
        # Show the change passphrase and delete buttons
        self.window.change_passphrase_button.show()
        self.window.delete_button.show()

    def on_hide(self):
        self.window.change_passphrase_button.hide()
        self.window.delete_button.hide()

    def add_separator(self, row, before):
        if not before:
            row.set_header(None)
        elif not row.get_header():
            row.set_header(
                Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))

    def on_persistent_directory_open_button_clicked(self, button: Gtk.Button):
        # noinspection PyArgumentList
        display = Gdk.Display.get_default()  # type: Gdk.Display
        launch_context = display.get_app_launch_context()  # type: Gdk.AppLaunchContext
        launch_context.set_timestamp(Gtk.get_current_event_time())
        # noinspection PyArgumentList
        Gio.AppInfo.launch_default_for_uri(
            "file:///home/amnesia/Persistent",
            context=launch_context,
        )
