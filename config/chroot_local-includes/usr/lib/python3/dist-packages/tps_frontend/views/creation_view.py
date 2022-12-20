from logging import getLogger
from gi.repository import Gio, GLib, Gtk
from typing import TYPE_CHECKING, List

from tps_frontend import CREATION_VIEW_UI_FILE, DBUS_SERVICE_NAME, \
    DBUS_JOB_INTERFACE
from tps_frontend.view import View

if TYPE_CHECKING:
    from tps_frontend.window import Window

logger = getLogger(__name__)


class CreationView(View):
    _ui_file = CREATION_VIEW_UI_FILE

    def __init__(self, window: "Window"):
        super().__init__(window)
        self.backend_job = None
        self.status_label = self.builder.get_object("creation_status_label")  # type: Gtk.Label
        self.progress_bar = self.builder.get_object("creation_progress_bar")  # type: Gtk.ProgressBar

        # Connect to properties-changed signal
        self.window.service_proxy.connect("g-properties-changed",
                                          self.on_properties_changed)

    def on_properties_changed(self, proxy: Gio.DBusProxy,
                              changed_properties: GLib.Variant,
                              invalidated_properties: List[str]):
        if not "Job" in changed_properties.keys():
            return

        job_path = changed_properties["Job"]
        # noinspection PyArgumentList
        self.backend_job = Gio.DBusProxy.new_sync(
            connection=proxy.get_connection(),
            flags=Gio.DBusProxyFlags.NONE,
            info=None,
            name=DBUS_SERVICE_NAME,
            object_path=job_path,
            interface_name=DBUS_JOB_INTERFACE,
            cancellable=None,
        )  # type: Gio.DBusProxy

        self.backend_job.connect("g-properties-changed",
                                 self.on_job_properties_changed)

    def on_job_properties_changed(self, proxy: Gio.DBusProxy,
                                  changed_properties: GLib.Variant,
                                  invalidated_properties: List[str]):
        if "Status" in changed_properties.keys():
            status = changed_properties["Status"]
            # The status is already localized because it was retrieved
            # via UDisksClient.get_job_description().
            self.status_label.set_label(status)
        if "Progress" in changed_properties.keys():
            progress = changed_properties["Progress"]
            # The status is already localized because it was retrieved
            # via UDisksClient.get_job_description().
            self.progress_bar.set_fraction(progress / 100)
