#!/usr/bin/env python3
"""Exercise actual C bindings, modes, reload, cursor and session-exit requests."""
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import xml.etree.ElementTree as ET

from protocol_smoke import INTERFACES, Server, U32, decode, string


class BindingServer(Server):
    def __init__(self, conn, scenario):
        super().__init__(conn, 'normal')
        self.scenario = scenario
        self.version = 1 if scenario == 'unsupported-exit' else 4
        self.cursor = None
        self.session_exit = False
        self.timer = None

    def request(self, obj, opcode, payload):
        iface = self.objects[obj]
        if iface == 'wl_display' and opcode == 1:
            new_id = U32.unpack(payload)[0]
            self.objects[new_id] = 'wl_registry'
            self.send(new_id, 0, U32.pack(1) + string('river_window_manager_v1') + U32.pack(self.version))
            self.send(new_id, 0, U32.pack(2) + string('river_xkb_bindings_v1') + U32.pack(1))
            return
        if iface == 'wl_registry':
            args = [ET.Element('arg', type=t) for t in ('uint', 'string', 'uint', 'uint')]
            _, interface, version, new_id = decode(payload, args)
            assert version == (self.version if interface == 'river_window_manager_v1' else 1)
            self.objects[new_id] = interface
            if interface == 'river_window_manager_v1':
                self.wm = new_id
            else:
                self.xkb = new_id
            if self.wm and self.xkb and not self.started:
                self.initial()
            return
        if iface in ('river_seat_v1', 'river_window_manager_v1'):
            request = INTERFACES[iface]['request'][opcode]
            name = request.attrib['name']
            if name == 'set_xcursor_theme':
                assert self.version >= 2 and self.phase == 'manage'
                self.cursor = decode(payload, request.findall('arg'))
                return
            if name == 'exit_session':
                assert self.version >= 4 and self.scenario == 'exit'
                self.session_exit = self.finished = True
                self.conn.shutdown(socket.SHUT_RDWR)
                return
        super().request(obj, opcode, payload)

    def validate_and_advance(self):
        if self.scenario in ('exit', 'unsupported-exit'):
            if self.round == 0:
                if self.version == 4:
                    assert self.cursor == ['fixture-theme', 42]
                self.key(ord('e'), 64)
                self.round = 1
                self.manage()
            elif self.scenario == 'unsupported-exit':
                self.timer = threading.Timer(0.5, self.process.send_signal, [signal.SIGTERM])
                self.timer.start()
            return
        enabled = {self.bindings[key] for key in self.enabled}
        if self.round == 0:
            assert self.cursor == ['fixture-theme', 42]
            assert (0xff51, 0) not in enabled and (0xff0d, 0) not in enabled
            self.key(ord('r'), 64)
        elif self.round == 1:
            assert enabled == {(0xff51, 0), (0xff0d, 0)}, enabled
            self.key(0xff51, 0)
        elif self.round == 2:
            assert self.focus == self.w1
            self.key(0xff0d, 0)
        elif self.round == 3:
            assert (0xff51, 0) not in enabled and (0xff0d, 0) not in enabled
            self.old_bindings = set(self.bindings)
            self.before = (dict(self.positions), dict(self.sizes), self.focus)
            self.key(ord('c'), 64)
        elif self.round == 4:
            assert self.old_bindings.isdisjoint(self.bindings), 'reload retained old proxies'
            assert self.before == (self.positions, self.sizes, self.focus), 'reload changed live window policy'
            assert (0xff51, 0) not in enabled and (ord('x'), 64) in enabled
            self.key(ord('x'), 64)
        elif self.round == 5:
            assert self.focus == self.w2, 'newly reloaded command was not dispatched'
            self.key(ord('q'), 65)
        elif self.round == 6:
            return
        else:
            raise AssertionError(self.round)
        self.round += 1
        self.manage()


def run(binary, scenario):
    with tempfile.TemporaryDirectory(prefix='xw-bindings-') as tmp:
        conn, client = socket.socketpair()
        environment = dict(os.environ, XDG_RUNTIME_DIR=tmp, WAYLAND_SOCKET=str(client.fileno()), XW_PROTOCOL_CASE=scenario)
        process = subprocess.Popen([binary], env=environment, pass_fds=(client.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        client.close()
        server = BindingServer(conn, scenario)
        server.process = process
        try:
            conn.settimeout(10)
            with conn:
                server.serve()
            _, err = process.communicate(timeout=10)
            assert process.returncode == 0, err.decode()
            if scenario == 'bindings':
                assert server.finished and server.round == 6
                assert b'configuration reloaded' in err
            elif scenario == 'exit':
                assert server.session_exit
            else:
                assert not server.session_exit
                assert b'session exit requires River window management protocol version 4' in err
            print(f'PASS {scenario}: dynamic modes/reload/cursor/exit protocol verified')
        finally:
            if server.timer:
                server.timer.cancel()
            if process.poll() is None:
                process.kill()
            process.communicate()


if __name__ == '__main__':
    for scenario in ('bindings', 'exit', 'unsupported-exit'):
        run(str(Path(sys.argv[1]).resolve()), scenario)
