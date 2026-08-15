#!/usr/bin/env python3
"""Serve the Yocto deploy directory over HTTP, with byte-range support.

Usage:  ./scripts/serve-deploy.py [--dir DIR] [--port PORT]
        (Ctrl-C to stop. Serves tmp/deploy by default.)

WHY THIS EXISTS
---------------
Session 14 served the rpm package feed with `python3 -m http.server 8000`,
and that was fine: dnf downloads whole files, start to finish.

Session 11's RAUC streaming install is a completely different access
pattern, and it breaks on that server:

    rauc install http://10.42.0.1:8000/.../playground-bundle.raucb
    -> "failed to configure streaming: range requests not supported by server"

A `verity`-format bundle is designed to be read *in place* over the network
rather than downloaded first. RAUC hands the URL to an NBD device, and the
kernel then treats the remote file as a block device: it reads the squashfs
superblock, then the manifest, then nodes of the dm-verity hash tree, then
payload blocks -- small, scattered reads, thousands of them, never in order.

Every one of those becomes an HTTP `Range: bytes=X-Y` request. Python's
stdlib http.server implements plain GET and nothing else, so it answers
every request with the whole 60 MB file from byte 0. RAUC sees that it did
not get the range it asked for, aborts the connection, and retries -- which
is what the broken-pipe tracebacks on the server console actually are: the
server noticing the client hung up, not the cause of anything.

That is the whole reason for this file. It is stdlib-only (no pip install,
nothing to remember on a fresh machine) and it also serves the rpm feed
perfectly well, so it can simply replace the old one-liner.

The alternative -- scp the bundle to the Pi and install from a local path --
works, but it needs somewhere to put a 60 MB file. On the Pi 5 that's merely
wasteful; on the Pi Zero W capstone, whose only spare partition is /data at
100 MB, it's the difference between OTA working and not. Streaming exists
precisely so a device never needs room for the update it's applying.
"""

import argparse
import http.server
import os
import re
import socketserver
import sys

# Default to the Pi 5 build's deploy directory -- the same root session 14
# used, so PACKAGE_FEED_URIS=http://10.42.0.1:8000/rpm keeps working and the
# bundle is reachable at /images/raspberrypi5/*.raucb.
DEFAULT_DIR = "/media/blankmcu/EmbeddedLinux/yocto/build-rpi5/tmp/deploy"
DEFAULT_PORT = 8000

# A `Range` header we're willing to answer. The three legal shapes are
# "bytes=500-999" (explicit), "bytes=500-" (open-ended) and "bytes=-500"
# (the LAST 500 bytes -- note the leading dash means suffix, not negative).
# Multi-range requests ("bytes=0-99,200-299") are legal HTTP but need a
# multipart/byteranges body; nothing we talk to asks for them, so we don't
# match them here and they fall through to a plain 200 response, which is
# a permitted answer to any range request.
RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")


class _LimitedReader:
    """A read-only file wrapper that stops after `remaining` bytes.

    send_head() returns a file object which do_GET() then copies with
    shutil.copyfileobj() -- and that copies until EOF. For a 206 response we
    must stop at the end of the requested range instead, so we hand back a
    wrapper that reports EOF early. (Seeking to the start is done by the
    caller before wrapping.)
    """

    def __init__(self, fileobj, remaining):
        self._f = fileobj
        self._remaining = remaining

    def read(self, n=-1):
        if self._remaining <= 0:
            return b""
        if n is None or n < 0 or n > self._remaining:
            n = self._remaining
        data = self._f.read(n)
        self._remaining -= len(data)
        return data

    def close(self):
        self._f.close()


class RangeRequestHandler(http.server.SimpleHTTPRequestHandler):
    # HTTP/1.0 (the stdlib default) closes the TCP connection after every
    # single response. With thousands of range requests per install that
    # means thousands of TCP handshakes, which turns a fast install into a
    # crawl. HTTP/1.1 gives us keep-alive -- safe here only because every
    # response we generate carries an accurate Content-Length, which is what
    # lets the client find the boundary between responses on a reused socket.
    protocol_version = "HTTP/1.1"

    def end_headers(self):
        # Advertise range support on EVERY response, including the plain 200s
        # and the directory listings. Clients decide whether ranges are usable
        # by looking for this header before they try -- RAUC's probe is what
        # produced the "range requests not supported by server" error, and it
        # happens before any range is ever requested.
        self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def send_head(self):
        """Return an open file for do_GET/do_HEAD to send, honouring Range."""
        range_header = self.headers.get("Range")
        if range_header is None:
            return super().send_head()  # ordinary whole-file request

        match = RANGE_RE.match(range_header.strip())
        if match is None:
            # Unparseable or multi-range: RFC 9110 allows a server to ignore
            # the header and send the whole thing. Correct, just not clever.
            return super().send_head()

        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()  # ranges over a generated listing: no

        try:
            f = open(path, "rb")
        except OSError:
            self.send_error(404, "File not found")
            return None

        try:
            size = os.fstat(f.fileno()).st_size
            first, last = match.group(1), match.group(2)

            if first == "":
                # "bytes=-N" -- the final N bytes. Used by readers that want a
                # trailer first, which is exactly how squashfs and the verity
                # footer get located, so this branch really does get taken.
                if last == "":
                    self.send_error(400, "Malformed Range header")
                    return None
                length = min(int(last), size)
                start = size - length
                end = size - 1
            else:
                start = int(first)
                end = int(last) if last != "" else size - 1
                end = min(end, size - 1)  # clamp: asking past EOF is legal

            if start >= size or start > end:
                # 416 must report the real size so the client can retry sanely.
                self.send_response(416, "Requested Range Not Satisfiable")
                self.send_header("Content-Range", "bytes */%d" % size)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return None

            f.seek(start)
            length = end - start + 1

            self.send_response(206, "Partial Content")
            self.send_header("Content-Type", self.guess_type(path))
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
            self.send_header("Content-Length", str(length))
            self.send_header(
                "Last-Modified", self.date_time_string(os.fstat(f.fileno()).st_mtime)
            )
            self.end_headers()
        except Exception:
            f.close()
            raise

        return _LimitedReader(f, length)

    # --- noise control -------------------------------------------------------
    # A client that closes a connection early is completely normal here: NBD
    # abandons reads it no longer needs. The stdlib prints a full traceback for
    # each one, which is what buried the real error message last time. These
    # two overrides turn that into a single quiet log line.
    def copyfile(self, source, outputfile):
        try:
            super().copyfile(source, outputfile)
        except (BrokenPipeError, ConnectionResetError):
            self.log_message("client closed connection early (normal for NBD)")

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def log_message(self, fmt, *args):
        # One compact line per request instead of the default's timestamp
        # banner, because a streaming install generates a LOT of them.
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    # NBD issues concurrent reads; a single-threaded server would serialise
    # them and could deadlock against a client waiting on a second request.
    daemon_threads = True
    allow_reuse_address = True  # survive a restart without TIME_WAIT griping


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dir", default=DEFAULT_DIR, help="directory to serve")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="TCP port")
    args = parser.parse_args()

    if not os.path.isdir(args.dir):
        sys.exit("ERROR: %s is not a directory (is the build disk mounted?)" % args.dir)

    os.chdir(args.dir)
    server = ThreadedHTTPServer(("0.0.0.0", args.port), RangeRequestHandler)

    print("Serving %s on port %d (byte-range enabled)" % (args.dir, args.port))
    print("  bundle: http://10.42.0.1:%d/images/raspberrypi5/"
          "playground-bundle-raspberrypi5.raucb" % args.port)
    print("  feed:   http://10.42.0.1:%d/rpm" % args.port)
    print("Ctrl-C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped.")


if __name__ == "__main__":
    main()
