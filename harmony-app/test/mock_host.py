#!/usr/bin/env python3
"""
HaloLink mock host — a reference Mac-side client for HLDP v1.

The tablet runs a TCP *server* on 0.0.0.0:9528; this script connects to it,
performs the JSON-line handshake, streams an H.264 Annex-B file as VIDEO
frames, answers PINGs with PONGs and logs every touch/key/scroll/text control
frame that the tablet sends back.

Requires only the Python standard library (ffmpeg is optional, used to generate
the test stream when it does not exist yet).

Usage:
  # 1) generate a 2800x1840/30fps H.264 test stream (once)
  python3 test/mock_host.py --generate

  # 2) connect to the tablet and stream (default tablet: 192.168.1.10:9528)
  python3 test/mock_host.py --host 192.168.1.10 --port 9528

  # handshake/control-only (no video), useful to debug touch events
  python3 test/mock_host.py --host 192.168.1.10 --no-stream

  # protocol unit tests + a loopback end-to-end test (no tablet needed)
  python3 test/mock_host.py --self-test --loopback

Protocol recap (specs/PROTOCOL.md):
  frame  = 1B type | 4B big-endian payload length | payload
  0x01 VIDEO (H.264 Annex-B access unit)   0x02 CONTROL (UTF-8 JSON)
  0x03 PING  (Mac -> tablet)               0x04 PONG  (tablet -> Mac)
  Handshake: tablet hello\n -> Mac config\n -> tablet ready\n
"""

import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time

FRAME_VIDEO = 0x01
FRAME_CONTROL = 0x02
FRAME_PING = 0x03
FRAME_PONG = 0x04
MAX_FRAME_BYTES = 16 * 1024 * 1024

DEFAULT_TABLET_HOST = "192.168.1.10"
DEFAULT_PORT = 9528
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_STREAM = os.path.join(HERE, "stream.h264")


# --------------------------------------------------------------------------- #
# Protocol helpers
# --------------------------------------------------------------------------- #
def encode_frame(frame_type: int, payload: bytes = b"") -> bytes:
    if len(payload) > MAX_FRAME_BYTES:
        raise ValueError("payload too large for HLDP frame")
    return bytes([frame_type]) + struct.pack(">I", len(payload)) + payload


def json_line(obj: dict) -> bytes:
    return (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")


class FrameDecoder:
    """Incremental HLDP frame decoder (mirror of the tablet-side parser)."""

    def __init__(self) -> None:
        self._buf = bytearray()

    def feed(self, data: bytes):
        self._buf.extend(data)
        while True:
            if len(self._buf) < 5:
                return
            frame_type = self._buf[0]
            length = struct.unpack(">I", bytes(self._buf[1:5]))[0]
            if length > MAX_FRAME_BYTES:
                raise ValueError(f"frame too large: {length}")
            if len(self._buf) < 5 + length:
                return
            payload = bytes(self._buf[5:5 + length])
            del self._buf[:5 + length]
            yield frame_type, payload


def build_hello(screen=(1840, 2800, 2.5, 144), app_version="0.1.0") -> dict:
    w, h, density, refresh = screen
    return {
        "type": "hello",
        "protocol": "halolink/1",
        "device": "HUAWEI MatePad 11.5\"S",
        "model": "TGR-W10",
        "screen": {"width": w, "height": h, "density": density, "refreshRate": refresh},
        "features": ["touch", "keyboard", "h264"],
        "appVersion": app_version,
    }


def build_config(width: int, height: int, fps: int, bitrate: int,
                 profile: str = "main", keyframe_interval: int = 2,
                 scale_mode: str = "fit", retina: bool = True,
                 input_enabled: bool = False,
                 render_mode: str = "scale",
                 frame_ts: bool = False) -> dict:
    """HLDP v1.2 config (v1.0/v1.1 hosts simply omit the newer fields)."""
    if render_mode == "pixel1to1":
        retina = False
        logical_w, logical_h = width, height
    else:
        logical_w, logical_h = (width // 2, height // 2) if retina else (width, height)
    return {
        "type": "config",
        "codec": "h264",
        "width": width,
        "height": height,
        "fps": fps,
        "bitrate": bitrate,
        "profile": profile,
        "keyframeInterval": keyframe_interval,
        "scaleMode": scale_mode,
        "retina": retina,
        "logicalWidth": logical_w,
        "logicalHeight": logical_h,
        "inputEnabled": input_enabled,
        "renderMode": render_mode,
        "frameTs": frame_ts,
    }


# --------------------------------------------------------------------------- #
# Annex-B access unit splitting
# --------------------------------------------------------------------------- #
def iter_nals(data: bytes):
    """Yields (start, end) byte ranges of NAL units including their start code.

    Uses bytes.find (C speed) so parsing a 9 MB 2800x1840 test stream takes a few
    milliseconds instead of seconds - important because the first video frame must
    reach the tablet within the decoder's first-frame window.
    """
    starts = []
    i = 0
    n = len(data)
    while i + 3 <= n:
        j = data.find(b"\x00\x00\x01", i)
        if j < 0:
            break
        # If this 3-byte pattern is the tail of a 4-byte start code, prefer the
        # 4-byte form (start one byte earlier).
        if j > 0 and data[j - 1] == 0x00:
            starts.append(j - 1)
        else:
            starts.append(j)
        i = j + 3
    for idx, start in enumerate(starts):
        end = starts[idx + 1] if idx + 1 < len(starts) else n
        yield start, end


def split_access_units(data: bytes):
    """Groups Annex-B NALs into access units: SPS/PPS/SEI prefix + one VCL NAL."""
    access_units = []
    prefix_start = None
    for start, end in iter_nals(data):
        if start + 4 > end:
            continue
        # NAL header follows the start code (3 or 4 bytes).
        header_off = start + (4 if data[start:start + 4] == b"\x00\x00\x00\x01" else 3)
        if header_off >= end:
            continue
        nal_type = data[header_off] & 0x1F
        if nal_type in (1, 5):  # VCL: non-IDR slice / IDR slice
            au_start = prefix_start if prefix_start is not None else start
            access_units.append(bytes(data[au_start:end]))
            prefix_start = None
        else:
            if prefix_start is None:
                prefix_start = start
    if prefix_start is not None and prefix_start < len(data):
        access_units.append(bytes(data[prefix_start:]))
    return access_units


# --------------------------------------------------------------------------- #
# Test stream generation
# --------------------------------------------------------------------------- #
def generate_stream(path: str, width: int, height: int, fps: int, seconds: int = 5) -> bool:
    cmd = [
        "ffmpeg", "-y",
        "-f", "lavfi", "-i", f"testsrc2=size={width}x{height}:rate={fps}",
        "-t", str(seconds),
        "-c:v", "libx264", "-profile:v", "main", "-g", str(fps),
        "-pix_fmt", "yuv420p", "-f", "h264", path,
    ]
    print(f"[mock] generating test stream: {' '.join(cmd)}")
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        size = os.path.getsize(path)
        print(f"[mock] wrote {path} ({size} bytes)")
        return True
    except (OSError, subprocess.CalledProcessError) as err:
        print(f"[mock] ffmpeg failed: {err}", file=sys.stderr)
        return False


# --------------------------------------------------------------------------- #
# Fake tablet (loopback / self test)
# --------------------------------------------------------------------------- #
def run_fake_tablet(listener: socket.socket, config_out: dict, result: dict) -> None:
    conn, _ = listener.accept()
    conn.settimeout(5.0)
    hello = build_hello()
    conn.sendall(json_line(hello))
    buf = b""
    while b"\n" not in buf:
        buf += conn.recv(4096)
    line, _, rest = buf.partition(b"\n")
    config_out.update(json.loads(line.decode("utf-8")))
    conn.sendall(json_line({"type": "ready"}))
    decoder = FrameDecoder()
    decoder.feed(rest)
    deadline = time.time() + 3.0
    while time.time() < deadline:
        try:
            data = conn.recv(65536)
        except socket.timeout:
            break
        if not data:
            break
        for frame_type, payload in decoder.feed(data):
            if frame_type == FRAME_VIDEO:
                result["video_frames"] = result.get("video_frames", 0) + 1
                result["video_bytes"] = result.get("video_bytes", 0) + len(payload)
            elif frame_type == FRAME_PING:
                conn.sendall(encode_frame(FRAME_PONG))
                result["pings"] = result.get("pings", 0) + 1
            elif frame_type == FRAME_CONTROL:
                msg = json.loads(payload.decode("utf-8"))
                result.setdefault("controls", []).append(msg)
    conn.close()


# --------------------------------------------------------------------------- #
# Client session
# --------------------------------------------------------------------------- #
class MockHost:
    def __init__(self, host: str, port: int, config: dict, stream_path: str,
                 no_stream: bool, duration: float, verbose: bool,
                 portrait_stream_path: str = "", follow_orientation: bool = True) -> None:
        self.access_units = []
        self.prepare_seconds = 0.0
        self.portrait_stream_path = portrait_stream_path
        self.follow_orientation = follow_orientation
        self.landscape_units = []
        self.portrait_units = []
        self.portrait_mode = False
        self.orientation = "landscape"
        self.pending_controls = []  # control frames queued by the reader thread
        # A single lock for every socket write: the pinger thread and the video
        # thread must never interleave bytes of two frames (a large sendall can
        # be split by the kernel and interleave without this lock).
        self.send_lock = threading.Lock()
        self.render_mode = config.get("renderMode", "scale")
        self.scale_mode = config.get("scaleMode", "fit")
        self.frame_ts = bool(config.get("frameTs", False))
        self.host = host
        self.port = port
        self.config = config
        self.stream_path = stream_path
        self.no_stream = no_stream
        self.duration = duration
        self.verbose = verbose
        self.sock = None
        self.decoder = FrameDecoder()
        self.stop_event = threading.Event()
        self.hello = None
        self.ready = False
        self.stats = {"video_frames": 0, "video_bytes": 0, "touches": 0, "keys": 0,
                      "scrolls": 0, "pongs": 0, "stats": 0, "texts": 0}
        self.t0 = 0.0

    def send_all(self, payload: bytes) -> None:
        with self.send_lock:
            self.sock.sendall(payload)

    # -- logging ----------------------------------------------------------
    def log(self, message: str) -> None:
        if self.verbose:
            print(f"[mock] {message}")

    # -- handshake --------------------------------------------------------
    def handshake(self, timeout: float = 10.0) -> None:
        self.sock.settimeout(timeout)
        buf = b""
        while b"\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("tablet closed during handshake")
            buf += chunk
        line, _, rest = buf.partition(b"\n")
        self.hello = json.loads(line.decode("utf-8"))
        print(f"[mock] hello: {json.dumps(self.hello, ensure_ascii=False)}")
        protocol = self.hello.get("protocol", "")
        if protocol not in ("halolink/1", "halolink/1.1"):
            raise ValueError(f"unexpected protocol: {protocol}")
        if self.follow_orientation:
            hello_screen = self.hello.get("screen", {})
            orientation = hello_screen.get("orientation", "landscape")
            self.apply_orientation(orientation, announce=False)
        self.sock.sendall(json_line(self.config))
        self.log(f"sent config {self.config['width']}x{self.config['height']} "
                 f"({self.orientation})")
        if rest:
            for frame_type, payload in self.decoder.feed(rest):
                self.handle_frame(frame_type, payload)
        # Wait for "ready" JSON line.
        ready_buf = b""
        while b"\n" not in ready_buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("tablet closed before ready")
            ready_buf += chunk
        line, _, rest = ready_buf.partition(b"\n")
        msg = json.loads(line.decode("utf-8"))
        if msg.get("type") != "ready":
            raise ValueError(f"expected ready, got {msg}")
        self.ready = True
        print("[mock] handshake complete: tablet is streaming-ready")
        self.decoder.feed(rest)
        self.sock.settimeout(0.2)

    # -- orientation switching (v1.1) ------------------------------------
    def apply_orientation(self, orientation: str, announce: bool = True) -> None:
        portrait = (orientation == "portrait")
        if portrait == self.portrait_mode and not announce:
            return
        self.portrait_mode = portrait
        self.orientation = "portrait" if portrait else "landscape"
        if portrait and self.portrait_units:
            self.access_units = self.portrait_units
            self.config = build_config(1840, 2800, self.config["fps"], self.config["bitrate"],
                                       profile=self.config.get("profile", "main"),
                                       keyframe_interval=self.config.get("keyframeInterval", 2),
                                       scale_mode=self.scale_mode,
                                       render_mode=self.render_mode,
                                       frame_ts=self.frame_ts)
        else:
            self.access_units = self.landscape_units
            self.config = build_config(2800, 1840, self.config["fps"], self.config["bitrate"],
                                       profile=self.config.get("profile", "main"),
                                       keyframe_interval=self.config.get("keyframeInterval", 2),
                                       scale_mode=self.scale_mode,
                                       render_mode=self.render_mode,
                                       frame_ts=self.frame_ts)
        if announce:
            print(f"[mock] orientation -> {self.orientation}: will resend config "
                  f"{self.config['width']}x{self.config['height']} and switch stream")

    # -- receive loop -----------------------------------------------------
    def reader(self) -> None:
        while not self.stop_event.is_set():
            try:
                data = self.sock.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not data:
                break
            try:
                for frame_type, payload in self.decoder.feed(data):
                    self.handle_frame(frame_type, payload)
            except ValueError as err:
                print(f"[mock] protocol error: {err}", file=sys.stderr)
                break

    def handle_frame(self, frame_type: int, payload: bytes) -> None:
        if frame_type == FRAME_CONTROL:
            self.handle_control(payload)
        elif frame_type == FRAME_PONG:
            self.stats["pongs"] += 1
        elif frame_type == FRAME_PING:
            self.sock.sendall(encode_frame(FRAME_PONG))
        elif frame_type == FRAME_VIDEO:
            self.stats["video_frames"] += 1
            self.stats["video_bytes"] += len(payload)

    def handle_control(self, payload: bytes) -> None:
        try:
            msg = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as err:
            print(f"[mock] bad control json: {err}", file=sys.stderr)
            return
        kind = msg.get("type")
        if kind == "touch":
            self.stats["touches"] += 1
            print(f"[mock] TOUCH {msg.get('action'):<6} x={msg.get('x'):.4f} "
                  f"y={msg.get('y'):.4f} pointer={msg.get('pointerId')}")
        elif kind == "key":
            self.stats["keys"] += 1
            print(f"[mock] KEY   {msg.get('action'):<6} {msg.get('key')}")
        elif kind == "scroll":
            self.stats["scrolls"] += 1
            print(f"[mock] SCROLL dx={msg.get('dx')} dy={msg.get('dy')}")
        elif kind == "text":
            self.stats["texts"] += 1
            print(f"[mock] TEXT  {msg.get('text')!r}")
        elif kind == "stats":
            self.stats["stats"] += 1
            print(f"[mock] STATS rxFps={msg.get('rxFps')} decodeMs={msg.get('decodeMs')} "
                  f"rttMs={msg.get('rttMs')} input={msg.get('input')}")
        elif kind == "request_keyframe":
            print("[mock] tablet requested a keyframe")
        elif kind == "display":
            orientation = msg.get("orientation", "landscape")
            print(f"[mock] DISPLAY {msg.get('width')}x{msg.get('height')} "
                  f"orientation={orientation} refresh={msg.get('refreshRate')}Hz")
            self.apply_orientation(orientation)
            # Re-send config as a binary CONTROL frame (we are in frame mode now,
            # NOT handshake mode) - sending a raw JSON line would desync the tablet.
            self.pending_controls.append(
                encode_frame(FRAME_CONTROL, json.dumps(self.config).encode("utf-8")))
        elif kind == "bye":
            print("[mock] tablet said bye")
            self.stop_event.set()
        else:
            print(f"[mock] control: {msg}")

    # -- ping thread ------------------------------------------------------
    def pinger(self) -> None:
        while not self.stop_event.wait(2.0):
            try:
                self.send_all(encode_frame(FRAME_PING))
            except OSError:
                break

    # -- stream ------------------------------------------------------------------
    def load_stream(self) -> None:
        """Parse the H.264 file(s) BEFORE connecting so frame 1 goes out immediately."""
        if self.no_stream:
            return
        t0 = time.time()
        if not os.path.exists(self.stream_path):
            if not generate_stream(self.stream_path, 2800, 1840, self.config["fps"]):
                raise FileNotFoundError(self.stream_path)
        with open(self.stream_path, "rb") as f:
            self.landscape_units = split_access_units(f.read())
        if not self.landscape_units:
            raise ValueError("no access units parsed from landscape stream")
        portrait_path = self.portrait_stream_path
        if self.follow_orientation:
            if not portrait_path:
                portrait_path = os.path.join(HERE, "stream_portrait.h264")
            if not os.path.exists(portrait_path):
                print("[mock] generating portrait test stream (1840x2800)...")
                generate_stream(portrait_path, 1840, 2800, self.config["fps"])
            with open(portrait_path, "rb") as f:
                self.portrait_units = split_access_units(f.read())
            if not self.portrait_units:
                raise ValueError("no access units parsed from portrait stream")
        self.prepare_seconds = time.time() - t0
        self.access_units = self.landscape_units
        sizes = [len(au) for au in self.access_units]
        print(f"[mock] {len(self.access_units)} landscape AUs ready (+"
              f"{len(self.portrait_units)} portrait) in {self.prepare_seconds * 1000:.0f} ms, "
              f"{sizes[0]}..{max(sizes)} bytes")

    def stream(self) -> None:
        if self.no_stream:
            print("[mock] --no-stream: keeping the control channel open, no video")
            while not self.stop_event.wait(0.5):
                pass
            return
        access_units = self.access_units
        frame_interval = 1.0 / float(self.config["fps"])
        self.t0 = time.time()
        sent = 0
        next_at = self.t0
        active_orientation = self.orientation
        while not self.stop_event.is_set():
            if self.duration > 0 and time.time() - self.t0 > self.duration:
                break
            # A display-change frame arrived: send the fresh config first, then
            # switch to the new orientation's stream (new GOP starts with IDR).
            while self.pending_controls:
                self.send_all(self.pending_controls.pop(0))
                print(f"[mock] sent new config {self.config['width']}x{self.config['height']} "
                      f"({self.orientation})")
            if self.orientation != active_orientation:
                active_orientation = self.orientation
                sent = 0
                access_units = self.access_units
                print(f"[mock] switched stream to {active_orientation} "
                      f"({len(access_units)} AUs)")
            access_units = self.access_units
            au = access_units[sent % len(access_units)]
            if self.frame_ts:
                payload = struct.pack(">Q", time.time_ns() // 1000) + au
            else:
                payload = au
            self.send_all(encode_frame(FRAME_VIDEO, payload))
            self.stats["video_frames"] += 0  # sent frames tracked separately
            sent += 1
            next_at += frame_interval
            now = time.time()
            if next_at > now:
                time.sleep(next_at - now)
            else:
                next_at = now
            if sent % (self.config["fps"] * 2) == 0:
                elapsed = time.time() - self.t0
                print(f"[mock] sent {sent} AUs in {elapsed:.1f}s "
                      f"({sent / max(elapsed, 0.001):.1f} fps)")
        print(f"[mock] stream finished: {sent} access units")

    # -- lifecycle --------------------------------------------------------
    def run(self) -> int:
        self.load_stream()
        print(f"[mock] connecting to {self.host}:{self.port}")
        self.sock = socket.create_connection((self.host, self.port), timeout=10.0)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.handshake()
        reader = threading.Thread(target=self.reader, daemon=True)
        reader.start()
        pinger = threading.Thread(target=self.pinger, daemon=True)
        pinger.start()
        try:
            self.stream()
        except KeyboardInterrupt:
            print("\n[mock] interrupted")
        finally:
            self.stop_event.set()
            try:
                self.send_all(encode_frame(FRAME_CONTROL, json.dumps({"type": "bye"}).encode()))
            except OSError:
                pass
            time.sleep(0.2)
            try:
                self.sock.close()
            except OSError:
                pass
        elapsed = max(time.time() - self.t0, 0.001)
        print(f"[mock] received: touches={self.stats['touches']} keys={self.stats['keys']} "
              f"scrolls={self.stats['scrolls']} texts={self.stats['texts']} "
              f"stats={self.stats['stats']} pongs={self.stats['pongs']}")
        return 0


# --------------------------------------------------------------------------- #
# Self tests (no tablet required)
# --------------------------------------------------------------------------- #
def test_protocol_helpers() -> None:
    # frame encode/decode round-trip
    payloads = [b"", b"x", os.urandom(1024), os.urandom(300 * 1024)]
    wire = b"".join(encode_frame(FRAME_CONTROL, p) for p in payloads)
    decoded = list(FrameDecoder().feed(wire))
    assert len(decoded) == len(payloads), f"expected {len(payloads)} frames, got {len(decoded)}"
    for (ftype, payload), expected in zip(decoded, payloads):
        assert ftype == FRAME_CONTROL and payload == expected, "round-trip mismatch"
    # split across arbitrary TCP chunk boundaries
    decoder = FrameDecoder()
    got = []
    for i in range(0, len(wire), 7):
        got.extend(decoder.feed(wire[i:i + 7]))
    assert [p for _, p in got] == payloads, "chunked decode mismatch"
    # handshake json line
    line = json_line(build_hello())
    assert line.endswith(b"\n")
    assert json.loads(line.decode())["protocol"] == "halolink/1"
    print("[self-test] protocol helpers OK")


def test_access_unit_split() -> None:
    sps = b"\x00\x00\x00\x01\x67\x42\x00\x1f"
    pps = b"\x00\x00\x00\x01\x68\xce\x3c\x80"
    sei = b"\x00\x00\x00\x01\x06\x05\x04"
    idr = b"\x00\x00\x00\x01\x65" + b"\xaa" * 100
    p_slice = b"\x00\x00\x01\x41" + b"\xbb" * 50
    data = sps + pps + sei + idr + p_slice + p_slice
    aus = split_access_units(data)
    assert len(aus) == 3, f"expected 3 AUs, got {len(aus)}"
    assert aus[0].startswith(sps) and aus[0].endswith(idr)
    assert aus[1] == p_slice and aus[2] == p_slice
    print("[self-test] Annex-B access unit splitting OK")


def run_loopback() -> int:
    """Runs the client against an in-process fake tablet; verifies end-to-end framing."""
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    config_out: dict = {}
    result: dict = {}
    thread = threading.Thread(target=run_fake_tablet, args=(listener, config_out, result),
                              daemon=True)
    thread.start()

    # build a tiny synthetic H.264-ish stream so no ffmpeg is needed
    sps = b"\x00\x00\x00\x01\x67\x42\x00\x1f"
    pps = b"\x00\x00\x00\x01\x68\xce\x3c\x80"
    idr = b"\x00\x00\x00\x01\x65" + bytes(range(0, 200))
    p = b"\x00\x00\x00\x01\x41" + bytes(range(0, 80))
    tmp = os.path.join(HERE, "_loopback_test.h264")
    with open(tmp, "wb") as f:
        f.write(sps + pps + idr + p * 20)
    host = MockHost("127.0.0.1", port, build_config(2800, 1840, 30, 24000000),
                    tmp, no_stream=False, duration=1.0, verbose=False)
    # fake tablet sends no control frames, so the client exits after `duration`
    rc = host.run()
    thread.join(timeout=5)
    os.unlink(tmp)
    listener.close()
    assert config_out.get("width") == 2800, f"fake tablet got config {config_out}"
    assert result.get("video_frames", 0) >= 20, f"fake tablet received {result}"
    print(f"[loopback] OK: fake tablet received {result.get('video_frames')} video frames, "
          f"config={config_out.get('width')}x{config_out.get('height')}, pings={result.get('pings')}")
    return rc


def main() -> int:
    parser = argparse.ArgumentParser(description="HaloLink mock host (Mac-side HLDP client)")
    parser.add_argument("--host", default=DEFAULT_TABLET_HOST, help="tablet IP")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="tablet TCP port")
    parser.add_argument("--width", type=int, default=2800, help="virtual display width")
    parser.add_argument("--height", type=int, default=1840, help="virtual display height")
    parser.add_argument("--fps", type=int, default=30, help="stream fps")
    parser.add_argument("--bitrate", type=int, default=24000000, help="bitrate hint")
    parser.add_argument("--profile", default="main", help="h264 profile hint")
    parser.add_argument("--frame-ts", action="store_true",
                        help="v1.3: prefix every VIDEO payload with an 8-byte BE Unix-us capture timestamp")
    parser.add_argument("--render-mode", default="scale", choices=["scale", "pixel1to1"],
                        help="v1.2 host render mode: scale (HiDPI 2x)/pixel1to1 (native 1:1)")
    parser.add_argument("--scale-mode", default="fill", choices=["fit", "fill"],
                        help="v1.2 scaleMode for renderMode=scale")
    parser.add_argument("--keyframe-interval", type=int, default=2, help="keyframe interval (s)")
    parser.add_argument("--stream", default=DEFAULT_STREAM, help="landscape H.264 Annex-B file")
    parser.add_argument("--portrait-stream", default="", help="portrait H.264 Annex-B file")
    parser.add_argument("--no-follow-orientation", action="store_true",
                        help="ignore hello.screen.orientation (stay landscape)")
    parser.add_argument("--no-stream", action="store_true", help="handshake/control only")
    parser.add_argument("--duration", type=float, default=0.0,
                        help="stop after N seconds (0 = run until Ctrl-C)")
    parser.add_argument("--generate", action="store_true", help="generate the test stream and exit")
    parser.add_argument("--self-test", action="store_true", help="run protocol unit tests")
    parser.add_argument("--loopback", action="store_true", help="run loopback end-to-end test")
    parser.add_argument("--quiet", action="store_true", help="less output")
    args = parser.parse_args()

    if args.generate:
        return 0 if generate_stream(args.stream, args.width, args.height, args.fps) else 1

    if args.self_test:
        test_protocol_helpers()
        test_access_unit_split()

    if args.loopback:
        return run_loopback()

    if args.self_test and not args.loopback:
        print("[self-test] all local tests passed")
        return 0

    config = build_config(args.width, args.height, args.fps, args.bitrate,
                          profile=args.profile, keyframe_interval=args.keyframe_interval,
                          scale_mode=args.scale_mode, render_mode=args.render_mode,
                          frame_ts=args.frame_ts)
    host = MockHost(args.host, args.port, config, args.stream, args.no_stream,
                    args.duration, verbose=not args.quiet,
                    portrait_stream_path=args.portrait_stream,
                    follow_orientation=not args.no_follow_orientation)
    try:
        return host.run()
    except (ConnectionError, OSError, ValueError) as err:
        print(f"[mock] error: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
