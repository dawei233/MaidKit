import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:maid_kit/servers/terminal_command_recorder.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  group('TerminalCommandRecorder', () {
    test('records a simple command submitted with Enter', () {
      final commands = <String>[];
      final recorder = TerminalCommandRecorder(onCommand: commands.add);
      recorder.add(_bytes('ls -la'));
      recorder.add(_bytes('\r'));
      expect(commands, ['ls -la']);
    });

    test('handles LF line endings', () {
      final commands = <String>[];
      final recorder = TerminalCommandRecorder(onCommand: commands.add);
      recorder.add(_bytes('pwd\n'));
      expect(commands, ['pwd']);
    });

    test('skips empty commands', () {
      final commands = <String>[];
      final recorder = TerminalCommandRecorder(onCommand: commands.add);
      recorder.add(_bytes('\r\r\n'));
      expect(commands, isEmpty);
    });

    test('backspace edits the pending line before Enter', () {
      final commands = <String>[];
      final recorder = TerminalCommandRecorder(onCommand: commands.add);
      recorder.add(_bytes('echox'));
      recorder.add(_bytes('\x7F'));
      recorder.add(_bytes('\r'));
      expect(commands, ['echo']);
    });

    test('Ctrl+U clears the pending line', () {
      final commands = <String>[];
      final recorder = TerminalCommandRecorder(onCommand: commands.add);
      recorder.add(_bytes('secret-command'));
      recorder.add(_bytes('\x15'));
      recorder.add(_bytes('ls'));
      recorder.add(_bytes('\r'));
      expect(commands, ['ls']);
    });

    test('arrow keys and escape sequences do not pollute commands', () {
      final commands = <String>[];
      final recorder = TerminalCommandRecorder(onCommand: commands.add);
      recorder.add(_bytes('ls'));
      // Up arrow (ESC[A), Down arrow (ESC[B), Home (ESC[H).
      recorder.add(_bytes('\x1B[A\x1B[B\x1B[H'));
      recorder.add(_bytes(' -la'));
      recorder.add(_bytes('\r'));
      expect(commands, ['ls -la']);
    });

    test('Ctrl+C submits a partial command', () {
      final commands = <String>[];
      final recorder = TerminalCommandRecorder(onCommand: commands.add);
      recorder.add(_bytes('top'));
      recorder.add(_bytes('\x03'));
      expect(commands, ['top']);
    });

    test('bracketed paste content is captured and trimmed', () {
      final commands = <String>[];
      final recorder = TerminalCommandRecorder(onCommand: commands.add);
      recorder.add(_bytes('\x1B[200~'));
      recorder.add(_bytes('echo "hello world"'));
      recorder.add(_bytes('\x1B[201~\r'));
      expect(commands, ['echo "hello world"']);
    });

    test('multiple commands across chunks', () {
      final commands = <String>[];
      final recorder = TerminalCommandRecorder(onCommand: commands.add);
      recorder.add(_bytes('git status\rcd /var/log\r'));
      expect(commands, ['git status', 'cd /var/log']);
    });

    test('chunk split in the middle of a command', () {
      final commands = <String>[];
      final recorder = TerminalCommandRecorder(onCommand: commands.add);
      recorder.add(_bytes('sys'));
      recorder.add(_bytes('temctl status\r'));
      expect(commands, ['systemctl status']);
    });

    test('OSC sequences (like window title) are skipped', () {
      final commands = <String>[];
      final recorder = TerminalCommandRecorder(onCommand: commands.add);
      recorder.add(_bytes('\x1B]0;my-title\x07'));
      recorder.add(_bytes('whoami\r'));
      expect(commands, ['whoami']);
    });
  });
}
