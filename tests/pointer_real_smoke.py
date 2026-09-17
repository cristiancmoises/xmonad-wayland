#!/usr/bin/env python3
"""Run test-owned virtual input on an isolated headless River, never the host."""
import argparse
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def wait(predicate, processes, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if any(p.poll() is not None for p in processes):
            raise AssertionError('isolated test process exited early')
        result = predicate()
        if result:
            return result
        time.sleep(.025)
    raise AssertionError('timed out waiting for isolated pointer operation')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--river', required=True)
    parser.add_argument('--pointer-xml', required=True)
    parser.add_argument('--keyboard-xml', required=True)
    parser.add_argument('--manager', default=str(ROOT / 'build/xmonad-wayland'))
    parser.add_argument('--output', default=str(ROOT / 'evidence/pointer-real-smoke'))
    args = parser.parse_args()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='xw-pointer-real-') as directory:
        runtime = Path(directory)
        runtime.chmod(0o700)
        wayland_protocols = subprocess.check_output(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols'], text=True).strip()
        inputs = [('xdg-shell', Path(wayland_protocols) / 'stable/xdg-shell/xdg-shell.xml'),
                  ('wlr-virtual-pointer', Path(args.pointer_xml)),
                  ('virtual-keyboard', Path(args.keyboard_xml))]
        sources = []
        for name, xml in inputs:
            # The pinned River keyboard XML includes a license line before the
            # XML declaration. Scanner accepts it; normalize for other scanners.
            xml_text = xml.read_text()
            declaration = '<?xml version="1.0" encoding="UTF-8"?>'
            if declaration in xml_text:
                xml_text = xml_text.replace(declaration, '')
            normalized = runtime / f'{name}.xml'
            normalized.write_text(xml_text)
            subprocess.run(['wayland-scanner', 'client-header', str(normalized), str(runtime / f'{name}-client-protocol.h')], check=True)
            source = runtime / f'{name}-protocol.c'
            subprocess.run(['wayland-scanner', 'private-code', str(normalized), str(source)], check=True)
            sources.append(str(source))
        flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True))
        probe_binary = runtime / 'pointer-probe'
        subprocess.run(['gcc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I' + str(runtime),
                        str(ROOT / 'tests/pointer_probe.c'), *sources, *flags, '-o', str(probe_binary)], check=True)
        init = runtime / 'init'
        init.write_text('#!/bin/sh\nprintf "%s" "$WAYLAND_DISPLAY" > "$XW_SOCKET_FILE"\nexec env WAYLAND_DEBUG=client "$XW_MANAGER" 2> "$XW_MANAGER_LOG"\n')
        init.chmod(0o755)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1',
                   WLR_RENDERER='pixman', WLR_LIBINPUT_NO_DEVICES='1', XW_INIT=str(init),
                   XW_SOCKET_FILE=str(runtime / 'socket'), XW_MANAGER=str(Path(args.manager).resolve()),
                   XW_MANAGER_LOG=str(output / 'manager.log'))
        for name in ('WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'DISPLAY'):
            env.pop(name, None)
        processes = []
        with (output / 'river.log').open('w') as river_log, (output / 'probe.log').open('w') as probe_log:
            river = subprocess.Popen([args.river, '-no-xwayland', '-c', 'exec "$XW_INIT"'], env=env,
                                     stdout=river_log, stderr=river_log, start_new_session=True)
            processes.append(river)
            try:
                socket_file = runtime / 'socket'
                wait(lambda: socket_file.exists() and socket_file.read_text(), processes)
                env['WAYLAND_DISPLAY'] = socket_file.read_text()
                trace_path = output / 'manager.log'
                trace = lambda: trace_path.read_text() if trace_path.exists() else ''
                wait(lambda: 'manage_finish' in trace(), processes)
                probe = subprocess.Popen([str(probe_binary)], env=env, stdin=subprocess.PIPE,
                                         stdout=probe_log, stderr=probe_log, text=True, start_new_session=True)
                processes.append(probe)
                wait(lambda: 'READY' in (output / 'probe.log').read_text(), processes)
                wait(lambda: '.parent(river_window_v1' in trace(), processes)
                window_ids = re.findall(r'\.window\(new id river_window_v1#(\d+)\)', trace())
                window = window_ids[1]
                node = wait(lambda: re.findall(rf'river_window_v1#{window}\.get_node\(new id river_node_v1#(\d+)\)', trace()), processes)[0]
                output_size = tuple(map(int, re.findall(r'river_output_v1#\d+\.dimensions\((\d+), (\d+)\)', trace())[0]))
                def position():
                    matches = re.findall(rf'river_node_v1#{node}\.set_position\((-?\d+), (-?\d+)\)', trace())
                    return tuple(map(int, matches[-1])) if matches else None
                def dimensions():
                    matches = re.findall(rf'river_window_v1#{window}\.dimensions\((\d+), (\d+)\)', trace())
                    return tuple(map(int, matches[-1])) if matches else None
                def command(line):
                    before = (output / 'probe.log').read_text().count('command ')
                    probe.stdin.write(line + '\n')
                    probe.stdin.flush()
                    wait(lambda: (output / 'probe.log').read_text().count('command ') > before, processes)
                    time.sleep(.075)
                def place_pointer():
                    x, y = position()
                    command(f'absolute {x + 20} {y + 20} {output_size[0]} {output_size[1]}')
                def count(name):
                    return trace().count('.' + name + '(')
                def release(button):
                    ends = count('op_end')
                    command(f'button {button} 0')
                    wait(lambda: count('op_end') == ends + 1, processes)
                wait(lambda: position() and dimensions() and count('set_tiled') >= 3, processes)
                time.sleep(.2)
                for button in (272, 273):
                    if button == 272:
                        command(f'absolute 10 10 {output_size[0]} {output_size[1]}')
                    else:
                        place_pointer()
                    before = position()
                    old_dimensions = dimensions()
                    starts = count('op_start_pointer')
                    command('mods 64')
                    if button == 272:
                        command(f'press_at {before[0] + 20} {before[1] + 20} {output_size[0]} {output_size[1]} {button}')
                    else:
                        command(f'button {button} 1')
                    wait(lambda: count('op_start_pointer') == starts + 1, processes)
                    command('motion 10.5 15.5')
                    command('motion 10.5 15.5')
                    wait(lambda: position() == (before[0] + 21, before[1] + 31), processes)
                    if button == 273:
                        wait(lambda: dimensions() == (old_dimensions[0] - 21, old_dimensions[1] - 31), processes)
                    ends = count('op_end')
                    command('mods 0')
                    assert count('op_end') == ends, 'releasing Super ended the pointer grab'
                    release(button)
                for edges in (0, 1, 2, 4, 8, 5, 6, 9, 10):
                    place_pointer()
                    before, old_dimensions = position(), dimensions()
                    starts = count('op_start_pointer')
                    command(f'csd {edges}')
                    command('button 272 1')
                    wait(lambda: count('op_start_pointer') == starts + 1, processes)
                    command('motion 8 6')
                    expected = (before[0] + (8 if edges == 0 or edges & 4 else 0),
                                before[1] + (6 if edges == 0 or edges & 1 else 0))
                    expected_size = (old_dimensions[0] + (-8 if edges & 4 else 8 if edges & 8 else 0),
                                     old_dimensions[1] + (-6 if edges & 1 else 6 if edges & 2 else 0))
                    wait(lambda: position() == expected and dimensions() == expected_size, processes)
                    release(272)
                assert count('op_start_pointer') == count('op_end') == 11
                assert count('inform_resize_start') == count('inform_resize_end') == 9
                place_pointer()
                command('mods 64')
                command('tap 272')
                wait(lambda: count('op_start_pointer') == count('op_end') == 12, processes)
                command('mods 0')
                probe.stdin.write('quit\n')
                probe.stdin.flush()
                probe.wait(timeout=5)
                assert probe.returncode == 0
                report = ('PASS: isolated headless River, Super+left move, Super+right nearest-corner resize, '
                          'fractional virtual motion accumulated to logical coordinates, Super released before button, '
                          'CSD move and all eight resize edges, immediate press/release; '
                          '12 operations closed, 9 resize notifications paired.\n')
                (output / 'result.txt').write_text(report)
                print(report, end='')
            finally:
                for process in reversed(processes):
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()


if __name__ == '__main__':
    main()
