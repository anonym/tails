from logging import getLogger
from gi.repository import Gtk
import subprocess

from tps_frontend import WELCOME_VIEW_UI_FILE
from tps_frontend.view import View

logger = getLogger(__name__)


class WelcomeView(View):
    _ui_file = WELCOME_VIEW_UI_FILE

    def __init__(self, window):
        super().__init__(window)
        self.continue_button = self.builder.get_object("continue_button")  # type: Gtk.Button
        self.device_not_supported_label = \
            self.builder.get_object("device_not_support_label")  # type: Gtk.Box
        self.warning_icon = self.builder.get_object("warning_icon")  # type: Gtk.Image

    def show(self):
        super().show()

        # Check if the boot device is supported
        variant = self.window.service_proxy.get_cached_property(
            "BootDeviceIsSupported")
        device_is_supported = bool(variant and variant.get_boolean())

        if device_is_supported:
            self.continue_button.grab_focus()

        self.device_not_supported_label.set_visible(not device_is_supported)
        self.warning_icon.set_visible(not device_is_supported)
        self.continue_button.set_visible(device_is_supported)

    def on_cancel_button_clicked(self, button: Gtk.Button):
        self.window.destroy()

    def on_activate_link(self, label: Gtk.Label, uri: str):
        logger.debug("Opening documentation: %s", uri)
        subprocess.run(["tails-documentation", uri])
        return True

    def on_continue_button_clicked(self, button: Gtk.Button):
        self.window.passphrase_view.show()
