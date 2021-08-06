import datetime
from typing import Optional
from logging import getLogger

import pytz
import gi

import tca.config

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
gi.require_version("GLib", "2.0")

from gi.repository import Gdk, GdkPixbuf, Gtk, GLib  # noqa: E402

log = getLogger('dialogs')

def get_tz_model():
    store = Gtk.ListStore(str)
    for tz in pytz.common_timezones:
        store.append([tz])
    return store


def get_time_dialog(initial_tz: Optional[str] = None):
    """Create a TimeDialog."""
    builder = Gtk.Builder()
    builder.set_translation_domain("tails")
    builder.add_from_file(tca.config.data_path + "time-dialog.ui")
    time_dialog = builder.get_object("dialog")  # noqa: N806

    tz_model = get_tz_model()
    select_tz = builder.get_object("select_tz")
    select_tz.set_model(tz_model)
    if initial_tz:
        for row in tz_model:
            if row[0] == initial_tz:
                select_tz.set_active_iter(row.iter)
                break
        else:
            log.warning("Cannot find user-selected timezone %s", initial_tz)

    renderer_text = Gtk.CellRendererText()
    select_tz.pack_start(renderer_text, True)
    select_tz.add_attribute(renderer_text, "text", 0)
    select_tz.set_entry_text_column(0)

    def get_tz_name(_=None):
        return tz_model.get_value(select_tz.get_active_iter(), 0)

    def get_date(_=None):
        spec = {
            part: int(builder.get_object(part).get_value())
            for part in ["hour", "minute", "day", "year"]
        }
        spec["month"] = int(builder.get_object("select_month").get_active_id())
        naive_dt = datetime.datetime(**spec)
        tz = pytz.timezone(get_tz_name())
        aware_dt = tz.localize(naive_dt)
        return aware_dt

    time_dialog.get_date = get_date
    time_dialog.get_tz_name = get_tz_name

    def check_input_valid(*args):
        """
        Check if user input is valid.

        Let Apply be sensitive accordingly
        """
        def is_valid():
            if not select_tz.get_active_iter():
                return False
            if not tz_model.get_value(select_tz.get_active_iter(), 0):
                return False
            try:
                # checks if the date is correct (ie: what about February 31?)
                get_date()
            except ValueError:
                return False
            return True

        builder.get_object("btn_apply").set_sensitive(is_valid())
        return

    now = datetime.datetime.now()
    builder.get_object("hour").set_range(0, 23)
    builder.get_object("hour").set_value(now.hour)
    builder.get_object("minute").set_range(0, 59)
    builder.get_object("minute").set_value(now.minute)
    builder.get_object("day").set_range(1, 31)
    builder.get_object("day").set_value(now.day)
    builder.get_object("year").set_range(2021, 2030)
    builder.get_object("year").set_value(now.year)

    builder.get_object("select_month").set_active_id(str(now.month))

    for spin in ["hour", "minute", "day", "year"]:
        builder.get_object(spin).set_numeric(True)
        builder.get_object(spin).set_increments(1, 6)

    for obj in ["hour", "minute", "day", "year", "select_month", "select_tz"]:
        builder.get_object(obj).connect("changed", check_input_valid)

    builder.get_object("btn_cancel").connect(
        "clicked", lambda *_: time_dialog.response(Gtk.ResponseType.CANCEL)
    )
    builder.get_object("btn_apply").connect(
        "clicked", lambda *_: time_dialog.response(Gtk.ResponseType.APPLY)
    )

    return time_dialog
