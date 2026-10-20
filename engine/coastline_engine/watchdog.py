"""Quit when the process that started us is gone.

The engine answers the app over stdin/stdout, but while it's busy generating it doesn't read
stdin, so it wouldn't notice the app quitting and would keep the CPU busy for minutes. A
waterline worker likewise outlives a killed engine. Both watch their parent instead.
"""

from __future__ import annotations

import os
import threading
import time


def exit_with_parent(interval: float = 1.0) -> None:
    parent = os.getppid()

    def watch() -> None:
        while True:
            time.sleep(interval)
            if os.getppid() != parent:
                os._exit(0)

    threading.Thread(target=watch, name="parent-watchdog", daemon=True).start()
