#!/usr/bin/env python3
"""Edge-key smoke test for cpg-cli.sh's pinned prompt.

The prompt is a hand-rolled raw-key line editor running under `set -e`, where a
false test as the last command of a case branch takes the whole REPL down - Left
at column 0 really did kill it once. This drives every edge case through a real
pty and fails if the REPL doesn't survive to print "Bye.".

    python3 tests/repl-keys.py [path-to-bash]
"""
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASH = sys.argv[1] if len(sys.argv) > 1 else "bash"

# (keys, what it exercises) - each one is a "nothing to do" edge of the editor.
STEPS = [
    (b"\x1b[D", "Left at column 0"),
    (b"\x1b[C", "Right at end of an empty line"),
    (b"\x1b[A", "history back with empty history"),
    (b"\x1b[B", "history forward with empty history"),
    (b"\x7f", "Backspace on an empty line"),
    (b"\x1b[3~", "Delete at end of line"),
    (b"\x15", "Ctrl-U on an empty line"),
    (b"\x0b", "Ctrl-K on an empty line"),
    (b"\x01", "Ctrl-A on an empty line"),
    (b"\x05", "Ctrl-E on an empty line"),
    (b"\x1b", "bare Escape"),
    (b"\t", "Tab with nothing typed"),
    (b"/zzz\t", "Tab with no match"),
    (b"\x15/s\t", "Tab with several matches"),
    (b"\x15abc\x1b[D\x1b[Dx", "insert in the middle"),
    (b"\x15\r", "Enter on an empty line"),
    (b"/status\r", "a real command"),
    (b"/exit\r", "exit"),
]


def main():
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.chdir(REPO)
        os.execv(BASH, [BASH, "cpg-cli.sh"])
        os._exit(1)                                        # unreachable
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

    out = bytearray()
    dead = []

    def pump(seconds):
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if not ready:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:                                # pty closed = child gone
                dead.append(True)
                return
            if not chunk:
                dead.append(True)
                return
            out.extend(chunk)

    pump(3.0)                                              # banner + status
    failed = None
    for keys, what in STEPS:
        try:
            os.write(fd, keys)
        except OSError:
            failed = what
            break
        pump(2.5 if b"\r" in keys else 0.4)
        if dead and what != "exit":
            failed = what
            break

    try:
        os.close(fd)
    except OSError:
        pass
    _, status = os.waitpid(pid, 0)
    text = bytes(out).decode("utf8", "replace")

    if failed:
        print(f"FAIL: REPL died on {failed}")
        return 1
    if "Bye." not in text:
        print("FAIL: never reached a clean exit (no 'Bye.')")
        return 1
    if os.waitstatus_to_exitcode(status) != 0:
        print(f"FAIL: exited {os.waitstatus_to_exitcode(status)}, expected 0")
        return 1
    # The scroll region must be released, or the terminal is left broken.
    if "\x1b[r" not in text:
        print("FAIL: scroll region never reset (missing ESC[r)")
        return 1
    print(f"ok - {len(STEPS)} edge cases, clean exit, scroll region restored")
    return 0


if __name__ == "__main__":
    sys.exit(main())
