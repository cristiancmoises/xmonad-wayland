#!/usr/bin/env python3
"""Validate pointer operations through the real Haskell/C Wayland client."""
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

from protocol_smoke import INTERFACES, Server, U32, decode, string


class PointerServer(Server):
    def __init__(self, conn, scenario):
        super().__init__(conn, 'normal')
        self.seat2 = 0xFF000004
        self.scenario = scenario
        self.pointer_bindings, self.pointer_enabled = {}, set()
        self.operations, self.resizing = set(), set()
        self.starts = self.ends = 0
        self.steps = self.exercise()
        self.quantize = False
        self.actual_sizes = {}
        self.completed = False

    def request(self, obj, opcode, payload):
        iface = self.objects[obj]
        if iface == 'wl_display' and opcode == 1:
            new_id = U32.unpack(payload)[0]
            self.objects[new_id] = 'wl_registry'
            for number, interface, version in ((1, 'river_window_manager_v1', 2),
                                               (2, 'river_xkb_bindings_v1', 1),
                                               (3, 'river_layer_shell_v1', 1)):
                self.send(new_id, 0, U32.pack(number) + string(interface) + U32.pack(version))
            return
        if iface == 'wl_registry':
            args = [ET.Element('arg', type=t) for t in ('uint', 'string', 'uint', 'uint')]
            _, interface, version, new_id = decode(payload, args)
            assert version == (2 if interface == 'river_window_manager_v1' else 1)
            self.objects[new_id] = interface
            if interface == 'river_window_manager_v1':
                self.wm = new_id
            elif interface == 'river_xkb_bindings_v1':
                self.xkb = new_id
            else:
                self.layer = new_id
            if self.wm and self.xkb and self.layer and not self.started:
                self.initial()
            return
        if iface not in ('wl_display', 'wl_registry'):
            request = INTERFACES[iface]['request'][opcode]
            name = request.attrib['name']
            values = decode(payload, request.findall('arg'))
            if iface == 'river_seat_v1':
                if name == 'get_pointer_binding':
                    binding, button, modifiers = values
                    assert modifiers == 64 and button in (272, 273)
                    self.pointer_bindings[binding] = (obj, button)
                elif name == 'op_start_pointer':
                    assert obj not in self.operations, 'operation restarted before previous manage finished'
                    self.operations.add(obj)
                    self.starts += 1
                elif name == 'op_end':
                    assert obj in self.operations, 'ending absent operation'
                    self.operations.remove(obj)
                    self.ends += 1
                elif name == 'destroy':
                    self.operations.discard(obj)
            elif iface == 'river_pointer_binding_v1':
                assert self.phase == 'manage' or name == 'destroy'
                if name == 'enable':
                    self.pointer_enabled.add(obj)
                elif name == 'disable':
                    self.pointer_enabled.discard(obj)
                elif name == 'destroy':
                    self.pointer_enabled.discard(obj)
                    self.pointer_bindings.pop(obj, None)
            elif iface == 'river_window_v1':
                if name == 'inform_resize_start':
                    assert obj not in self.resizing
                    self.resizing.add(obj)
                elif name == 'inform_resize_end':
                    assert obj in self.resizing
                    self.resizing.remove(obj)
                elif name == 'destroy':
                    self.resizing.discard(obj)
        super().request(obj, opcode, payload)

    def event(self, obj, name, *values):
        if name == 'dimensions' and self.objects[obj] == 'river_window_v1':
            if getattr(self, 'skip_dimensions', False):
                return
            if self.quantize:
                # Real clients may acknowledge a different size than proposed.
                values = (values[0] + 7, values[1] + 9)
            self.actual_sizes[obj] = values
        super().event(obj, name, *values)

    def press(self, button, window=None):
        window = self.w1 if window is None else window
        self.event(self.seat, 'pointer_enter', window)
        x, y = self.positions[window]
        self.event(self.seat, 'pointer_position', x + 10, y + 10)
        bindings = [b for b, pair in self.pointer_bindings.items() if pair == (self.seat, button)]
        assert len(bindings) == 1, 'Super pointer binding missing or duplicated'
        assert bindings[0] in self.pointer_enabled
        self.event(bindings[0], 'pressed')

    def validate_and_advance(self):
        try:
            next(self.steps)
        except StopIteration:
            self.completed = True
            return
        self.round += 1
        if getattr(self, 'render_only', False):
            self.render_only = False
        else:
            self.manage()

    def exercise(self):
        assert len(self.bindings) == 34, 'pointer support changed keyboard bindings'
        assert len(self.pointer_bindings) == len(self.pointer_enabled) == 2, 'Super move/resize bindings missing'
        self.event(self.seat, 'window_interaction', self.w1)
        self.key(ord('t'), 64)
        yield
        assert self.tiled[self.w1] == 0
        if self.scenario == 'rejections':
            self.press(272, self.w2)
            yield
            assert not self.operations, 'tiled target started a pointer operation'
            self.event(self.wm, 'seat', self.seat2)
            self.event(self.w1, 'pointer_move_requested', self.seat2)
            self.event(self.w1, 'pointer_resize_requested', self.seat, 3)
            yield
            assert not self.operations, 'secondary seat or invalid edges started an operation'
            self.event(self.w1, 'fullscreen_requested', 0)
            self.event(self.w1, 'pointer_move_requested', self.seat)
            yield
            assert not self.operations, 'fullscreen target started an operation'
            self.event(self.w1, 'exit_fullscreen_requested')
            yield
            self.key(ord('2'), 64)
            self.event(self.w1, 'pointer_move_requested', self.seat)
            yield
            assert not self.operations, 'hidden target started an operation'
            self.key(ord('1'), 64)
            yield
            self.press(272)
            self.event(self.wm, 'session_locked')
            yield
            assert not self.operations and not self.pointer_enabled
            self.event(self.wm, 'session_unlocked')
            yield
            # The explicitly named CSD target takes precedence over hover.
            self.event(self.seat, 'pointer_enter', self.w2)
            self.event(self.w1, 'pointer_move_requested', self.seat)
            before = self.positions[self.w1]
            yield
            assert self.operations == {self.seat}
            self.event(self.seat, 'op_delta', 10, 10)
            self.event(self.seat, 'op_release')
            yield
            assert self.positions[self.w1] == (before[0] + 10, before[1] + 10)
            self.key(ord('q'), 65)
            yield
            return
        if self.scenario == 'border':
            self.event(self.w1, 'fullscreen_requested', 0)
            yield
            # A client may retain its content size across a border change.
            self.skip_dimensions = True
            Server.event(self, self.w1, 'dimensions', 300, 200)
            self.phase = 'render'
            self.event(self.wm, 'render_start')
            self.render_only = True
            yield
            self.event(self.w1, 'exit_fullscreen_requested')
            yield
            self.press(272)
            yield
            assert self.sizes[self.w1] == (300, 200), 'pointer baseline used stale outer border dimensions'
            self.event(self.seat, 'op_release')
            yield
            self.key(ord('q'), 65)
            yield
            return
        original = self.positions[self.w1]
        self.press(272)
        yield
        assert self.operations == {self.seat} and not self.resizing
        self.event(self.seat, 'op_delta', 10, 20)
        yield
        assert self.positions[self.w1] == (original[0] + 10, original[1] + 20)
        self.event(self.output, 'position', 0, 0)
        self.event(self.output, 'dimensions', 1200, 800)
        yield
        assert self.operations == {self.seat}, 'unchanged output state cancelled an operation'
        # Totals are logical integers, not fixed point and not incremental.
        self.event(self.seat, 'op_delta', 15, 25)
        binding = next(b for b, pair in self.pointer_bindings.items() if pair == (self.seat, 272))
        self.event(binding, 'released')
        self.event(self.seat, 'pointer_leave')
        yield
        assert self.operations == {self.seat}, 'modifier/button binding release ended the grab'
        assert self.positions[self.w1] == (original[0] + 15, original[1] + 25)
        # Release may precede the last delta in this transaction.
        self.event(self.seat, 'op_release')
        self.event(self.seat, 'op_delta', 20, 30)
        yield
        assert not self.operations
        assert self.positions[self.w1] == (original[0] + 20, original[1] + 30)
        if self.scenario == 'geometry':
            for edges in (1, 2, 4, 8, 5, 6, 9, 10):
                before = (*self.positions[self.w1], *self.actual_sizes[self.w1])
                self.event(self.w1, 'pointer_resize_requested', self.seat, edges)
                yield
                assert self.operations == {self.seat} and self.resizing == {self.w1}
                self.quantize = True
                self.event(self.seat, 'op_delta', 10, 10)
                yield
                x, y = self.positions[self.w1]
                width, height = self.sizes[self.w1]
                assert x == (before[0] + before[2] - width - 7 if edges & 4 else before[0]), (edges, before, (x, y, width, height))
                assert y == (before[1] + before[3] - height - 9 if edges & 1 else before[1])
                self.event(self.seat, 'op_release')
                yield
                assert not self.operations and not self.resizing
                # Render-only, delayed dimensions must retain the opposite edge.
                old = self.positions[self.w1]
                self.phase = 'render'
                self.event(self.w1, 'dimensions', width + 3, height + 4)
                self.event(self.wm, 'render_start')
                # This generator's next yield normally starts manage. Signal the
                # render separately in the advance helper below instead.
                self.render_only = True
                yield
                assert self.positions[self.w1] == (old[0] - (3 if edges & 4 else 0), old[1] - (4 if edges & 1 else 0))
                self.quantize = False
            self.press(273)
            yield
            assert self.resizing == {self.w1}
            before = self.positions[self.w1]
            self.event(self.seat, 'op_delta', 10, 10)
            yield
            assert self.positions[self.w1] == (before[0] + 10, before[1] + 10), 'right drag did not select top-left corner'
            self.event(self.seat, 'op_release')
            yield
        else:
            for cancellation in ('locked', 'layer', 'fullscreen', 'workspace', 'output', 'closed', 'seat'):
                self.press(273)
                yield
                assert self.operations == {self.seat}
                if cancellation == 'locked':
                    self.event(self.wm, 'session_locked')
                elif cancellation == 'layer':
                    self.event(self.layer_seats[self.seat], 'focus_exclusive')
                elif cancellation == 'fullscreen':
                    self.event(self.w1, 'fullscreen_requested', 0)
                elif cancellation == 'workspace':
                    self.key(ord('2'), 64)
                elif cancellation == 'output':
                    self.event(self.output, 'dimensions', 1100, 800)
                elif cancellation == 'closed':
                    self.event(self.w1, 'closed')
                    self.closed.add(self.w1)
                else:
                    self.event(self.seat, 'removed')
                    self.event(self.wm, 'seat', self.seat2)
                self.event(self.seat, 'op_delta', 100, 100)
                yield
                assert not self.operations and not self.resizing, cancellation
                if cancellation in ('locked', 'layer'):
                    assert not self.pointer_enabled
                    self.event(self.wm, 'session_unlocked') if cancellation == 'locked' else self.event(self.layer_seats[self.seat], 'focus_none')
                elif cancellation == 'fullscreen':
                    self.event(self.w1, 'exit_fullscreen_requested')
                elif cancellation == 'workspace':
                    self.key(ord('1'), 64)
                elif cancellation == 'closed':
                    self.w1 = self.w2
                    self.key(ord('t'), 64)
                elif cancellation == 'seat':
                    self.seat = self.seat2
                yield
        self.key(ord('q'), 65)
        yield


def run(binary, scenario):
    with tempfile.TemporaryDirectory(prefix='xw-pointer-') as tmp:
        conn, client = socket.socketpair()
        env = dict(os.environ, XDG_RUNTIME_DIR=tmp, WAYLAND_SOCKET=str(client.fileno()))
        process = subprocess.Popen([binary], env=env, pass_fds=(client.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        client.close()
        server = PointerServer(conn, scenario)
        try:
            conn.settimeout(10)
            with conn:
                server.serve()
            _, err = process.communicate(timeout=10)
            assert process.returncode == 0, err.decode()
            assert server.finished and server.completed
            print(f'PASS pointer {scenario}: {server.starts} operations, {server.requests} client requests')
        finally:
            if process.poll() is None:
                process.kill()
            _, diagnostic = process.communicate()
            if process.returncode:
                print(f'pointer {scenario}, round {server.round}: {diagnostic.decode()}', file=sys.stderr)


if __name__ == '__main__':
    for case in ('geometry', 'lifetime', 'border', 'rejections'):
        run(str(Path(sys.argv[1]).resolve()), case)
