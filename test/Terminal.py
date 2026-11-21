#!/usr/bin/env python3
"""Small end-to-end checks for the real terminal loop, using only stdlib PTYs."""

import fcntl
import errno
import os
import pty
import select
import signal
import struct
import termios
import tempfile
import time
import unittest


class TerminalCase(unittest.TestCase):
    executable = None

    def run_editor(self, path, keys, initial_size=(10, 50), resize=None):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", *initial_size, 0, 0))
        original = termios.tcgetattr(slave)
        pid = os.fork()
        if pid == 0:
            try:
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
                for fd in (0, 1, 2):
                    os.dup2(slave, fd)
                os.environ.update(TERM="xterm-256color", LANG="C.UTF-8")
                os.execv(self.executable, [self.executable, path])
            finally:
                os._exit(127)
        output = bytearray()
        deadline = time.monotonic() + 8
        chunks = list(keys) if isinstance(keys, (list, tuple)) else [keys]
        sent = 0
        resized = False
        status = None
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    pass
            if sent < len(chunks) and output:
                if resize is not None and not resized:
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", *resize, 0, 0))
                    os.kill(pid, signal.SIGWINCH)
                    resized = True
                    time.sleep(0.15)
                time.sleep(0.25)
                if sent == 0:
                    time.sleep(0.25)
                os.write(master, chunks[sent])
                sent += 1
                time.sleep(0.12)
            got, wait_status = os.waitpid(pid, os.WNOHANG)
            if got:
                status = wait_status
                break
        if status is None:
            os.kill(pid, signal.SIGKILL)
            _, status = os.waitpid(pid, 0)
            self.fail("editor did not exit after scripted keys; terminal output: " + repr(bytes(output[-1200:])))
        # Drain final terminal cleanup output before checking alternate-screen exit.
        time.sleep(0.05)
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            try:
                output.extend(os.read(master, 65536))
            except OSError:
                pass
        try:
            restored = termios.tcgetattr(slave)
        except termios.error as error:
            # Darwin detaches the exited child session from the slave fd;
            # the still-open PTY master retains the terminal attributes.
            if error.args[0] != errno.ENOTTY:
                raise
            restored = termios.tcgetattr(master)
        os.close(slave)
        os.close(master)
        return bytes(output), os.waitstatus_to_exitcode(status), (original, restored)

    def test_write_quit_and_terminal_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "notes.txt")
            output, code, (original, restored) = self.run_editor(path, [b"ihello", b"\x1b", b":wq\r"])
            self.assertEqual(code, 0)
            with open(path, "rb") as source:
                self.assertEqual(source.read(), b"hello\n")
            self.assertIn(b"-- INSERT --", output)
            self.assertIn(b"\x1b[10;1H", output)
            self.assertIn(b"\x1b[?1049l", output)
            self.assertEqual(original, restored)

    def test_formatter_error_keeps_editor_open_until_force_quit(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "Broken.hs")
            with open(path, "wb") as target:
                target.write(b"module Broken where\nmain =\n")
            output, code, (original, restored) = self.run_editor(path, [b":wq\r", b":q!\r"])
            self.assertEqual(code, 0)
            self.assertIn(b"format", output.lower())
            with open(path, "rb") as source:
                self.assertEqual(source.read(), b"module Broken where\nmain =\n")
            self.assertEqual(original, restored)

    def test_resize_then_quit(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "resize.txt")
            output, code, (original, restored) = self.run_editor(path, [b"\x1b", b":q!\r"], resize=(6, 30))
            self.assertEqual(code, 0)
            self.assertIn(b"\x1b[6;1H", output)
            self.assertEqual(original, restored)


if __name__ == "__main__":
    import sys

    TerminalCase.executable = os.path.abspath(sys.argv[1])
    unittest.main(argv=[sys.argv[0]], verbosity=2)
