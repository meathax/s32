from __future__ import annotations

import os
import time
from pathlib import Path
from typing import IO


class LockTimeout(TimeoutError):
    pass


class FileLock:
    """Cross-platform advisory lock for serializing heavy FPGA jobs."""

    def __init__(self, path: Path, timeout_s: int = 7200, poll_s: float = 0.25):
        self.path = path
        self.timeout_s = timeout_s
        self.poll_s = poll_s
        self.handle: IO[bytes] | None = None

    def __enter__(self) -> "FileLock":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        deadline = time.monotonic() + self.timeout_s

        # On Windows, a process holding this file with restrictive sharing
        # makes the second open fail with PermissionError before
        # msvcrt.locking() can report ordinary contention.  Treat that exact
        # failure as contention and wait; otherwise every queued heavy task
        # fails immediately while the owner is still running.
        while self.handle is None:
            try:
                self.handle = self.path.open("a+b")
            except PermissionError as exc:
                if time.monotonic() >= deadline:
                    raise LockTimeout(
                        f"Timed out waiting for heavy-job lock: {self.path}"
                    ) from exc
                time.sleep(self.poll_s)

        while True:
            try:
                if os.name == "nt":
                    import msvcrt
                    self.handle.seek(0, os.SEEK_END)
                    if self.handle.tell() == 0:
                        self.handle.write(b"\0")
                        self.handle.flush()
                    self.handle.seek(0)
                    msvcrt.locking(self.handle.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except (OSError, BlockingIOError):
                if time.monotonic() >= deadline:
                    self.handle.close()
                    self.handle = None
                    raise LockTimeout(f"Timed out waiting for heavy-job lock: {self.path}")
                time.sleep(self.poll_s)

    def __exit__(self, exc_type, exc, tb) -> None:
        if self.handle is None:
            return
        try:
            if os.name == "nt":
                import msvcrt
                self.handle.seek(0)
                msvcrt.locking(self.handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
        finally:
            self.handle.close()
            self.handle = None
