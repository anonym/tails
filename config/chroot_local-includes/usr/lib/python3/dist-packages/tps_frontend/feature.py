import logging
from gi.repository import Gio, GLib, GObject, Gtk, Handy
import os
import re
import psutil
from typing import TYPE_CHECKING, Dict, List, Union

from tps.dbus.errors import TargetIsBusyError, SymlinkSourceDirectoryError

from tps_frontend import _, DBUS_SERVICE_NAME, DBUS_FEATURES_PATH, \
    DBUS_FEATURE_INTERFACE, DBUS_JOB_INTERFACE

if TYPE_CHECKING:
    from tps_frontend.window import Window

logger = logging.getLogger(__name__)


class Feature(object):
    @property
    def dbus_object_name(self) -> str:
        """The name of the D-Bus object representing this feature

        By default, the class name is used. Features for which
        the class name does not correspond with the D-Bus object
        can override this property."""
        return self.__class__.__name__

    @property
    def widget_name_prefix(self) -> str:
        """The string which widgets of this feature are prefixed with.
        By default, the class name converted to snake_case with
        "_switch" appended is used."""
        return camel_to_snake(self.__class__.__name__)

    @property
    def widgets_to_show_while_active(self) -> List[Gtk.Widget]:
        return list()

    def __init__(self, window: "Window", builder: Gtk.Builder,
                 bus: Gio.DBusConnection):
        logger.debug(f"Initializing feature {self.__class__.__name__}")
        self.window = window
        self.builder = builder
        self.object_path = os.path.join(DBUS_FEATURES_PATH,
                                        self.dbus_object_name)
        self.proxy = Gio.DBusProxy.new_sync(
            bus, Gio.DBusProxyFlags.NONE, None,
            DBUS_SERVICE_NAME,
            self.object_path,
            DBUS_FEATURE_INTERFACE,
            None,
        )  # type: Gio.DBusProxy

        self.is_active = self.proxy.get_cached_property("IsActive").get_boolean()
        self.has_data = self.proxy.get_cached_property("HasData").get_boolean()
        self.error = self.proxy.get_cached_property("Error").get_string()

        # Connect to properties-changed signal
        self.proxy.connect("g-properties-changed", self.on_properties_changed)

        box_name = self.widget_name_prefix + "_box"
        self.box = self.builder.get_object(box_name)  # type: Gtk.Box
        if not self.box:
            raise RuntimeError(f"Could not find {box_name}")

        self.expander = Gtk.Expander(
            expanded=True,
            visible=True,
            valign="center",
            sensitive=False,
        )

        action_row_name = self.widget_name_prefix + "_row"
        self.action_row = self.builder.get_object(action_row_name)  # type: Handy.ActionRow
        self.name = self.dbus_object_name
        self.translated_name = self.action_row.get_title()

        # Add the row about deleting leftover data
        self.delete_data_button = Gtk.Button(
            label = _("Delete Data…"),
            valign = "center",
        )
        self.delete_data_button.connect("clicked", self.on_delete_data_button_clicked)
        Gtk.StyleContext.add_class(self.delete_data_button.get_style_context(),
                                   'destructive-action')
        self.second_row = Handy.ActionRow(can_focus = False)
        self.second_row.add(self.delete_data_button)
        self.add_second_row()

        self.spinner = Gtk.Spinner()  # type: Gtk.Spinner
        self.warning_icon = Gtk.Image(
            icon_name="gtk-dialog-warning",
            icon_size=Gtk.IconSize.LARGE_TOOLBAR,
            visible=True,
            tooltip_text=_("Activation failed"),
        )

        switch_name = self.widget_name_prefix + "_switch"
        self.switch = self.builder.get_object(switch_name)  # type: Gtk.Switch
        if not self.switch:
            raise RuntimeError(f"Could not find {switch_name}")

        self.switch.set_state(self.is_active)
        self.switch.connect("notify::active", self.on_active_changed)
        self.switch.connect("state-set", self.on_state_set)

        self.update_second_row()

        self.dialog = None
        self.old_state = None  # type: bool

    def add_second_row(self):
        parent_list_box = self.action_row.get_parent()  # type: Gtk.ListBox

        i = 0
        while True:
            row = parent_list_box.get_row_at_index(i)
            if not row:
                raise RuntimeError(f"Couldn't find action row in list box")
            if row == self.action_row:
                break
            i += 1

        parent_list_box.insert(self.second_row, i + 1)

    def show_spinner(self):
        if not self.spinner in self.box.get_children():
            self.box.add(self.spinner)
            # Ensure that the spinner is the first widget in the box
            self.box.reorder_child(self.spinner, 0)
        self.spinner.start()
        self.spinner.set_visible(True)

    def hide_spinner(self):
        if self.spinner in self.box.get_children():
            self.box.remove(self.spinner)

    def show_warning_icon(self):
        if not self.warning_icon in self.box.get_children():
            self.box.add(self.warning_icon)
            # Ensure that the warning icon is the first widget in the box
            self.box.reorder_child(self.warning_icon, 0)

    def hide_warning_icon(self):
        if self.warning_icon in self.box.get_children():
            self.box.remove(self.warning_icon)

    def update_second_row(self):
        if self.error:
            self.show_warning_icon()
        else:
            self.hide_warning_icon()

        if self.error and self.has_data:
            subtitle = _("Activation failed. Try again or delete data.")
        elif self.error:
            subtitle = _("Activation failed. Try again.")
        elif self.has_data and not self.is_active:
            subtitle = _("There's some data. Turn on or delete data.")
        else:
            self.hide_second_row()
            return

        self.second_row.set_subtitle(subtitle)
        self.delete_data_button.set_visible(self.has_data)
        self.show_second_row()

    def show_second_row(self):
        self.second_row.show()
        if not self.expander in self.box.get_children():
            self.box.add(self.expander)

    def hide_second_row(self):
        self.second_row.hide()
        if self.expander in self.box.get_children():
            self.box.remove(self.expander)

    def on_state_set(self, switch: Gtk.Switch, state: bool):
        # We return True here to prevent the default handler from
        # running, which would sync the "state" property with the
        # "active" property. We don't want this, because we want to set
        # "state" only to True when the feature was activated
        # successfully.
        # See https://developer.gnome.org/gtk3/stable/GtkSwitch.html#GtkSwitch-state-set
        return True

    def on_active_changed(self, switch: Gtk.Switch, pspec: GObject.ParamSpec):
        is_active = self.proxy.get_cached_property("IsActive").get_boolean()
        if switch.get_active() == is_active:
            # The feature already has the desired state. There are only
            # two cases in which this should happen:
            # * The feature was changed without user interaction,
            #   e.g. activated as a default feature by the backend
            #   after the Persistent Storage was created. In this case
            #   we only have to set the state of the switch accordingly.
            # * If we called set_active ourselves, to flip the switch
            #   back into its old position, because activation of the
            #   feature failed or the user cancelled it. In this case
            #   the switch already has the desired state (setting it
            #   again is a noop).
            switch.set_state(is_active)
            return
        if switch.get_active():
            self.activate()
        else:
            self.deactivate()

    def activate(self):
        logger.debug(f"Activating feature {self.name}")
        self.show_spinner()

        # Create a cancellable that can be used to cancel the activation job
        self.cancellable = Gio.Cancellable()
        self.old_state = False

        self.proxy.call(method_name="Activate",
                        parameters=None,
                        flags=Gio.DBusCallFlags.NONE,
                        timeout_msec=GLib.MAXINT,
                        cancellable=self.cancellable,
                        callback=self.on_activate_call_finished)

    def deactivate(self):
        logger.debug(f"Deactivating feature {self.name}")
        self.show_spinner()

        # Already hide the widgets when we start deactivating the
        # feature, to:
        # * avoid races when the user clicks a widget and the action is
        #   only done when the feature is already deactivated
        # * avoid that showing the spinner causes the widgets to move
        for widget in self.widgets_to_show_while_active:
            widget.hide()

        # Create a cancellable that can be used to cancel the activation job
        self.cancellable = Gio.Cancellable()
        self.old_state = True

        self.proxy.call(method_name="Deactivate",
                   parameters=None,
                   flags=Gio.DBusCallFlags.NONE,
                   timeout_msec=GLib.MAXINT,
                   cancellable=self.cancellable,
                   callback=self.on_deactivate_call_finished)

    def on_activate_call_finished(self, proxy: Gio.DBusProxy,
                                  res: Gio.AsyncResult):
        self.hide_spinner()

        if self.dialog:
            self.dialog.destroy()
            self.dialog = None
        try:
            proxy.call_finish(res)
        except GLib.Error as e:
            logger.error(f"Error activating feature {self.name}: {e.message}")

            if e.matches(Gio.io_error_quark(), Gio.IOErrorEnum.CANCELLED):
                # The operation was cancelled by the user, so we cancel
                # the job of the backend.
                self.backend_job.call_sync(method_name="Cancel",
                                           parameters=None,
                                           flags=Gio.DBusCallFlags.NONE,
                                           timeout_msec=-1,
                                           cancellable=None)
            elif SymlinkSourceDirectoryError.is_instance(e):
                # The user did not create the source directory of a
                # feature that uses symlinks.
                # This is an expected error which we don't want error
                # reports for.
                SymlinkSourceDirectoryError.strip_remote_error(e)
                self.window.display_error(_("Error activating feature {}").format(self.translated_name),
                                          e.message,
                                          with_send_report_button=False)
            else:
                self.window.display_error(_("Error activating feature {}").format(self.translated_name),
                                          e.message)

            # Ensure that the switch displays the correct state
            is_active = self.proxy.get_cached_property("IsActive").get_boolean()
            self.switch.set_active(is_active)
            return

        logger.debug(f"Feature {self.name} successfully activated")

    def on_deactivate_call_finished(self, proxy: Gio.DBusProxy,
                                  res: Gio.AsyncResult):
        self.hide_spinner()

        if self.dialog:
            self.dialog.destroy()
            self.dialog = None
        try:
            proxy.call_finish(res)
        except GLib.Error as e:
            logger.error(f"Error deactivating feature {self.name}: {e.message}")

            if e.matches(Gio.io_error_quark(), Gio.IOErrorEnum.CANCELLED):
                # The operation was cancelled by the user, so we cancel
                # the job of the backend.
                self.backend_job.call_sync(method_name="Cancel",
                                           parameters=None,
                                           flags=Gio.DBusCallFlags.NONE,
                                           timeout_msec=-1,
                                           cancellable=None)
            elif TargetIsBusyError.is_instance(e):
                # Some process is still accessing the target. This is
                # an expected error which we don't want error reports
                # for.
                TargetIsBusyError.strip_remote_error(e)
                self.window.display_error(_("Error deactivating feature {}").format(self.translated_name),
                                          e.message,
                                          with_send_report_button=False)
            else:
                self.window.display_error(_("Error deactivating feature {}").format(self.translated_name),
                                          e.message)

            # Ensure that the switch displays the correct state
            is_active = self.proxy.get_cached_property("IsActive").get_boolean()
            self.switch.set_active(is_active)

            # We hid the widgets in the deactivate() function, so ensure
            # that they now have the correct visibility
            for widget in self.widgets_to_show_while_active:
                widget.set_visible(is_active)

            return

        logger.debug(f"Feature {self.name} successfully deactivated")

    def on_delete_data_button_clicked(self, button: Gtk.Button):
        msg = _(
            "Delete all data stored on the Persistent Storage for the {} feature?\n\n"
            "If you keep the data, it will be restored when you turn the feature on again.",
        ).format(self.translated_name)
        self.dialog = Gtk.MessageDialog(self.window,
                                        Gtk.DialogFlags.MODAL | \
                                        Gtk.DialogFlags.DESTROY_WITH_PARENT,
                                        Gtk.MessageType.WARNING,
                                        Gtk.ButtonsType.NONE,
                                        msg)
        self.dialog.add_button(_("Cancel"), Gtk.ResponseType.CANCEL)
        self.dialog.add_button(_("_Delete Data"), Gtk.ResponseType.OK)
        self.dialog.set_default_response(Gtk.ResponseType.CANCEL)
        button = self.dialog.get_widget_for_response(Gtk.ResponseType.OK)
        style_context = button.get_style_context()
        style_context.add_class("destructive-action")
        result = self.dialog.run()  # type: Gtk.ResponseType
        self.dialog.destroy()
        if result != Gtk.ResponseType.OK:
            return

        self.show_spinner()
        self.hide_second_row()
        self.proxy.call(method_name="Delete",
                        parameters=None,
                        flags=Gio.DBusCallFlags.NONE,
                        timeout_msec=GLib.MAXINT,
                        cancellable=None,
                        callback=self.on_delete_call_finished)

    def on_delete_call_finished(self, proxy: Gio.DBusProxy,
                                  res: Gio.AsyncResult):
        self.hide_spinner()

        try:
            proxy.call_finish(res)
        except GLib.Error as e:
            logger.error(f"Error deleting data of feature {self.name}: {e.message}")
            self.window.display_error(_("Error deleting data of feature {}").format(self.translated_name),
                                      e.message)
            return
        finally:
            self.update_second_row()

        logger.debug(f"Data of feature {self.name} successfully deleted")

    def on_properties_changed(self, proxy: Gio.DBusProxy,
                              changed_properties: GLib.Variant,
                              invalidated_properties: List[str]):
        logger.debug("changed properties: %s", changed_properties)
        if "IsActive" in changed_properties.keys():
            self.is_active = changed_properties["IsActive"]
            self.switch.set_active(self.is_active)
            self.switch.set_state(changed_properties["IsActive"])
            for widget in self.widgets_to_show_while_active:
                widget.set_visible(changed_properties["IsActive"])
            self.hide_spinner()

        if "HasData" in changed_properties.keys():
            self.has_data = changed_properties["HasData"]

        if "Error" in changed_properties.keys():
            self.error = changed_properties["Error"]

        if "IsActive" in changed_properties.keys() or \
                "HasData" in changed_properties.keys() or \
                "Error" in changed_properties.keys():
            self.update_second_row()

        if "Job" in changed_properties.keys():
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
        logger.debug("changed job properties: %s", changed_properties)
        if "ConflictingApps" in changed_properties.keys():
            apps = changed_properties["ConflictingApps"]
            self.show_conflicting_apps_message(apps)

    def show_conflicting_apps_message(self, apps: Dict[str, List[int]]):
        msg = self.get_conflicting_apps_message(apps)

        self.dialog = Gtk.MessageDialog(self.window,
                                        Gtk.DialogFlags.MODAL | \
                                        Gtk.DialogFlags.DESTROY_WITH_PARENT,
                                        Gtk.MessageType.INFO,
                                        Gtk.ButtonsType.CANCEL,
                                        msg)
        result = self.dialog.run()  # type: Gtk.ResponseType
        if result == Gtk.ResponseType.CANCEL:
            self.dialog.destroy()
            self.cancellable.cancel()
            self.switch.set_active(self.old_state)

    def get_conflicting_apps_message(self, apps: Dict[str, List[int]]):
        app_reprs = [self.app_repr_string(app, apps[app]) for app in apps]
        # Translators: Don't translate {applications}, it's a placeholder
        return _("Close {applications} to continue").format(
            applications=_(" and ").join(app_reprs)
        )

    @staticmethod
    def app_repr_string(app: str, pids: List[int]):
        # We list each app with the conflicting PIDs. The app names are
        # already translated.
        if len(pids) == 1:
            pid = str(pids[0])
            # Translators: Don't translate {app} and {pid}, they
            # are placeholders.
            return _("{app} (PID: {pid})").format(app=app, pid=pid)

        pids_repr = ", ".join(str(pid) for pid in pids)
        # Translators: Don't translate {app} and {pids}, they
        # are placeholders.
        return _("{app} (PIDs: {pids})").format(app=app, pids=pids_repr)

def camel_to_snake(name):
    """From https://stackoverflow.com/a/1176023
    Original authors:
    epost (https://stackoverflow.com/users/129879/epost)
    Zarathustra (https://stackoverflow.com/users/1248724/zarathustra)
    danijar (https://stackoverflow.com/users/1079110/danijar)"""
    name = re.sub('(.)([A-Z][a-z]+)', r'\1_\2', name)
    return re.sub('([a-z0-9])([A-Z])', r'\1_\2', name).lower()
