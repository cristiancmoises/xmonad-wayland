#!/usr/bin/env python3
"""Drive the real client over a Unix Wayland socket; no compositor/GPU claim.

The server validates request phase ordering, proxy lifetime, dimensions, focus,
workspace transitions, output hotplug, and failures on incompatible compositors.
"""
import os
from pathlib import Path
import socket
import signal
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
U32 = struct.Struct('=I')
INTERFACES = {}
for path in (ROOT / 'protocols').glob('*.xml'):
    for interface in ET.parse(path).getroot().findall('interface'):
        INTERFACES[interface.attrib['name']] = {
            'request': interface.findall('request'), 'event': interface.findall('event')}


def string(value):
    data = value.encode() + b'\0'
    return U32.pack(len(data)) + data + b'\0' * (-len(data) % 4)


def decode(payload, args):
    result, offset = [], 0
    for arg in args:
        typ = arg.attrib['type']
        if typ == 'string':
            n = U32.unpack_from(payload, offset)[0]
            offset += 4
            result.append(payload[offset:offset + max(0, n-1)].decode())
            offset += (n + 3) & ~3
        else:
            fmt = '=i' if typ == 'int' else '=I'
            result.append(struct.unpack_from(fmt, payload, offset)[0])
            offset += 4
    assert offset == len(payload), (args, payload)
    return result


class Server:
    def __init__(self, conn, mode):
        self.conn, self.mode = conn, mode
        self.objects = {1: 'wl_display'}
        self.wm = self.xkb = None
        self.output, self.output2 = 0xFF000000, 0xFF000004
        self.w1, self.w2, self.seat = 0xFF000001, 0xFF000002, 0xFF000003
        self.phase = 'idle'
        self.started = False
        self.bindings = {}
        self.enabled = set()
        self.sizes, self.visible, self.positions = {}, {}, {}
        self.focus = None
        self.round = 0
        self.requests = 0
        self.finished = False
        self.closed = set()
        self.node_windows = {}

    def send(self, obj, opcode, payload=b''):
        try:
            self.conn.sendall(struct.pack('=II', obj, ((len(payload) + 8) << 16) | opcode) + payload)
        except (BrokenPipeError, ConnectionResetError):
            # Expected failure exits and finished shutdown may close before
            # display.delete_id acknowledgements arrive. run() still checks
            # the child's exit status and diagnostic for failure scenarios.
            if not self.finished and self.mode not in ('missing', 'unavailable'):
                raise

    def event(self, obj, name, *values):
        events = INTERFACES[self.objects[obj]]['event']
        opcode = next(i for i, e in enumerate(events) if e.attrib['name'] == name)
        args = events[opcode].findall('arg')
        payload = b''
        for arg, value in zip(args, values):
            if arg.attrib['type'] == 'string':
                payload += string(value)
            else:
                payload += struct.pack('=i' if arg.attrib['type'] == 'int' else '=I', value)
            if arg.attrib['type'] == 'new_id':
                self.objects[value] = arg.attrib['interface']
        assert len(values) == len(args)
        self.send(obj, opcode, payload)

    def manage(self):
        self.phase = 'manage'
        self.event(self.wm, 'manage_start')

    def initial(self):
        self.started = True
        self.event(self.wm, 'output', self.output)
        self.event(self.output, 'position', 0, 0)
        self.event(self.output, 'dimensions', 1200, 800)
        for window in (self.w1, self.w2):
            self.event(self.wm, 'window', window)
            self.event(window, 'dimensions_hint', 0, 0, 0, 0)
        self.event(self.wm, 'seat', self.seat)
        self.manage()

    def key(self, keysym, modifiers):
        found = [k for k, v in self.bindings.items() if v == (keysym, modifiers)]
        assert len(found) == 1, ('missing or duplicate keybinding', keysym, modifiers)
        assert found[0] in self.enabled
        self.event(found[0], 'pressed')
        self.event(found[0], 'released')

    def validate_and_advance(self):
        shown = [w for w, visible in self.visible.items() if visible and w not in self.closed]
        for window in shown:
            assert window in self.sizes, ('no dimensions', window)
            width, height = self.sizes[window]
            assert 0 < width <= 1200 and 0 < height <= 800, ('invalid size', window, width, height)
            assert window in self.positions, ('window not positioned', window)
        if self.focus:
            assert self.focus in shown, ('focus is hidden/closed', self.focus, shown)
        if self.mode in ('sigint', 'sigterm'):
            assert len(shown) == 2
            self.finished = True  # no protocol replies needed after signal exit
            self.round = 1
            os.kill(self.process.pid, signal.SIGINT if self.mode == 'sigint' else signal.SIGTERM)
            return
        if self.round == 0:
            assert len(shown) == 2
            self.moved = self.focus
            self.key(ord('2'), 64 | 1)  # Super+Shift+2
        elif self.round == 1:
            assert len(shown) == 1 and self.moved not in shown, 'shift must hide moved window'
            self.key(ord('2'), 64)
        elif self.round == 2:
            assert shown == [self.moved], 'view must reveal moved window'
            self.event(self.wm, 'output', self.output2)
            self.event(self.output2, 'position', 1200, 0)
            self.event(self.output2, 'dimensions', 800, 600)
        elif self.round == 3:
            assert len(shown) >= 1
            self.event(self.output, 'removed')
        elif self.round == 4:
            # A retained output keeps its workspace; the unplugged workspace
            # becomes hidden. Closing a hidden window must remain safe.
            assert self.moved in self.objects
            self.event(self.moved, 'closed')
            self.closed.add(self.moved)
        elif self.round == 5:
            assert self.moved not in shown
            self.key(ord('1'), 64)
        elif self.round == 6:
            assert len(shown) == 1 and shown[0] != self.moved
            self.before_lock = self.focus
            self.event(self.wm, 'session_locked')
        elif self.round == 7:
            assert self.focus is None and not self.enabled, 'lock must clear focus and disable bindings'
            self.event(self.wm, 'session_unlocked')
        elif self.round == 8:
            assert self.focus == self.before_lock and len(self.enabled) == 30
            self.key(ord('q'), 64 | 1)
        elif self.round == 9:
            # A render may already be in flight when the stop request arrives.
            return
        else:
            raise AssertionError('unexpected additional transaction')
        self.round += 1
        self.manage()

    def request(self, obj, opcode, payload):
        assert obj in self.objects, ('request on destroyed/unknown proxy', obj, opcode)
        iface = self.objects[obj]
        self.requests += 1
        if iface == 'wl_display':
            new_id = U32.unpack(payload)[0]
            if opcode == 1:
                self.objects[new_id] = 'wl_registry'
                if self.mode != 'missing':
                    for name, interface in [(1, 'river_window_manager_v1'), (2, 'river_xkb_bindings_v1')]:
                        self.send(new_id, 0, U32.pack(name) + string(interface) + U32.pack(1))
            elif opcode == 0:
                self.send(new_id, 0, U32.pack(1))
                self.send(1, 1, U32.pack(new_id))
            else:
                raise AssertionError(('display request', opcode))
            return
        if iface == 'wl_registry':
            args = [ET.Element('arg', type=t) for t in ('uint', 'string', 'uint', 'uint')]
            _, interface, version, new_id = decode(payload, args)
            assert version == 1
            self.objects[new_id] = interface
            if interface == 'river_window_manager_v1':
                self.wm = new_id
                if self.mode == 'unavailable':
                    self.event(new_id, 'unavailable')
            else:
                self.xkb = new_id
            if self.wm and self.xkb and not self.started and self.mode in ('normal', 'sigint', 'sigterm'):
                self.initial()
            return

        requests = INTERFACES[iface]['request']
        assert opcode < len(requests), (iface, opcode)
        request = requests[opcode]
        name = request.attrib['name']
        args = request.findall('arg')
        values = decode(payload, args)
        assert int(request.attrib.get('since', '1')) <= 1, ('version violation', iface, name)
        for arg, value in zip(args, values):
            if arg.attrib['type'] == 'new_id':
                assert value not in self.objects
                self.objects[value] = arg.attrib['interface']
        if request.attrib.get('type') == 'destructor':
            self.objects.pop(obj)
            if obj < 0xFF000000:
                self.send(1, 1, U32.pack(obj))
            return

        if iface == 'river_window_manager_v1':
            if name == 'manage_finish':
                assert self.phase == 'manage'
                self.phase = 'render'
                for window, dims in list(self.sizes.items()):
                    if window in self.objects and window not in self.closed:
                        self.event(window, 'dimensions', *dims)
                self.event(obj, 'render_start')
            elif name == 'render_finish':
                assert self.phase == 'render'
                self.phase = 'idle'
                self.validate_and_advance()
            elif name == 'stop':
                self.event(obj, 'finished')
                self.finished = True
            elif name != 'manage_dirty':
                raise AssertionError(('unexpected WM request', name))
        elif iface == 'river_window_v1':
            if name == 'get_node':
                self.node_windows[values[0]] = obj
            else:
                assert obj not in self.closed, ('request after closed window', name)
                rendering = name in ('hide', 'show', 'set_borders')
                assert self.phase in (('manage', 'render') if rendering else ('manage',)), (name, self.phase)
                if name == 'propose_dimensions':
                    self.sizes[obj] = tuple(values)
                elif name in ('show', 'hide'):
                    self.visible[obj] = name == 'show'
        elif iface == 'river_node_v1':
            assert self.phase in ('manage', 'render')
            window = self.node_windows[obj]
            assert window not in self.closed
            if name == 'set_position':
                self.positions[window] = tuple(values)
        elif iface == 'river_seat_v1':
            assert self.phase == 'manage', (name, self.phase)
            if name == 'focus_window':
                assert values[0] in self.objects and values[0] not in self.closed
                self.focus = values[0]
            elif name == 'clear_focus':
                self.focus = None
        elif iface == 'river_xkb_bindings_v1':
            if name == 'get_xkb_binding':
                seat, binding, key, mods = values
                assert seat == self.seat
                self.bindings[binding] = (key, mods)
        elif iface == 'river_xkb_binding_v1':
            assert self.phase == 'manage', (name, self.phase)
            if name == 'enable':
                self.enabled.add(obj)
            elif name == 'disable':
                self.enabled.discard(obj)

    def serve(self):
        buf = b''
        while True:
            try:
                part = self.conn.recv(65536)
            except ConnectionResetError:
                if self.finished or self.mode in ('missing', 'unavailable'):
                    break
                raise
            if not part:
                break
            buf += part
            while len(buf) >= 8:
                obj, header = struct.unpack_from('=II', buf)
                length, opcode = header >> 16, header & 0xFFFF
                assert 8 <= length <= 65536 and length % 4 == 0
                if len(buf) < length:
                    break
                self.request(obj, opcode, buf[8:length])
                buf = buf[length:]


def run(binary, mode):
    with tempfile.TemporaryDirectory(prefix='xw-protocol-') as tmp:
        # An inherited connected pair exercises the same libwayland transport
        # without creating a public socket path or requiring bind permissions.
        conn, client = socket.socketpair()
        env = dict(os.environ, XDG_RUNTIME_DIR=tmp, WAYLAND_SOCKET=str(client.fileno()))
        process = subprocess.Popen([binary], env=env, pass_fds=(client.fileno(),),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        client.close()
        try:
            conn.settimeout(10)
            server = Server(conn, mode)
            server.process = process
            with conn:
                server.serve()
            out, err = process.communicate(timeout=10)
            if mode == 'normal':
                assert process.returncode == 0, err.decode()
                assert server.finished and server.round == 9, (server.finished, server.round, err.decode())
            elif mode in ('sigint', 'sigterm'):
                assert process.returncode == 0 and server.round == 1, (process.returncode, err.decode())
            else:
                expected = {
                    'missing': b'compositor lacks river_window_manager_v1;',
                    'unavailable': b'River window management is unavailable ('
                }[mode]
                assert process.returncode == 1, (mode, process.returncode, err.decode())
                assert expected in err, (mode, err.decode())
            print(f'PASS {mode}: {server.requests} real client requests validated')
        except Exception:
            if process.poll() is not None:
                _, diagnostic = process.communicate()
                print(diagnostic.decode(), file=sys.stderr)
            raise
        finally:
            conn.close()
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == '__main__':
    executable = str(Path(sys.argv[1]).resolve())
    assert Path(executable).is_file(), 'client executable not built yet'
    for scenario in ('missing', 'unavailable', 'normal', 'sigint', 'sigterm'):
        run(executable, scenario)
