import logging
import threading


class CustomAdapter(logging.LoggerAdapter):
    def process(self, msg, kwargs):
        thread_name = threading.current_thread().name
        if thread_name == "MainThread":
            thread_name = "0"
        else:
            thread_name = thread_name.removeprefix("Thread-")
        return f"[{thread_name}] {msg}", kwargs


def get_logger(name: str) -> logging.LoggerAdapter:
    return CustomAdapter(logging.getLogger(name), None)
