import 'dart:convert';
import 'dart:typed_data';

/// Extracts complete commands from the byte stream a user types into a
/// terminal, so they can be recorded as command history.
///
/// The terminal input stream is raw bytes: printable text, control characters,
/// escape sequences (arrows, Home/End, Alt+key, bracketed paste), and the
/// Enter key that submits a command. This recorder reconstructs the current
/// input line and reports it once a command is submitted.
///
/// It is intentionally conservative:
/// - Escape sequences are skipped, not treated as command text.
/// - Backspace removes the last character from the pending line.
/// - Ctrl+U clears the line; Ctrl+C / Ctrl+D submit whatever is pending
///   (matching how shells record partial commands).
/// - Enter submits the pending line; empty lines are ignored.
/// - Bracketed paste (`ESC [ 2 0 0 ~ ... ESC [ 2 0 1 ~`) content is captured.
class TerminalCommandRecorder {
  TerminalCommandRecorder({required this.onCommand});

  /// Called once per submitted command with the trimmed command text.
  final void Function(String command) onCommand;

  final _pending = StringBuffer();
  bool _inBracketedPaste = false;

  /// Feeds a chunk of terminal input bytes.
  void add(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    for (var i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      if (_inBracketedPaste) {
        if (_consumeBracketedPasteEnd(text, i)) {
          _inBracketedPaste = false;
          i += 5; // consume the whole "ESC[201~" terminator
          continue;
        }
        _pending.writeCharCode(code);
        continue;
      }
      // ESC begins either a control sequence (CSI: ESC[), an OSC sequence
      // (ESC]), or a single escape (ESC followed by one more char).
      if (code == 0x1B) {
        if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x5B) {
          // CSI: ESC[... — skip until a final byte in the @-~ range.
          var j = i + 2;
          while (j < text.length) {
            final c = text.codeUnitAt(j);
            if (c >= 0x40 && c <= 0x7E) break;
            j++;
          }
          // Bracket paste start (ESC[200~) — everything until ESC[201~ is
          // literal input.
          if (text.startsWith('[200~', i + 2)) {
            _inBracketedPaste = true;
          }
          i = j < text.length ? j : text.length - 1;
          continue;
        }
        if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x5D) {
          // OSC: ESC]...BEL — skip until BEL (0x07) or ST (ESC\).
          var j = i + 2;
          while (j < text.length) {
            final c = text.codeUnitAt(j);
            if (c == 0x07) break;
            if (c == 0x1B && j + 1 < text.length && text.codeUnitAt(j + 1) == 0x5C) {
              j++;
              break;
            }
            j++;
          }
          i = j < text.length ? j : text.length - 1;
          continue;
        }
        // Lone ESC: consume it and the next character (e.g. Alt+key).
        i += 1;
        continue;
      }
      switch (code) {
        case 0x0D: // Enter (CR) — submits the command.
        case 0x0A: // LF (some terminals send \n).
          _submit();
          break;
        case 0x08: // Backspace.
        case 0x7F: // DEL.
          _backspace();
          break;
        case 0x15: // Ctrl+U — clear the line.
          _clear();
          break;
        case 0x03: // Ctrl+C.
        case 0x04: // Ctrl+D.
          if (_pending.isNotEmpty) _submit();
          break;
        default:
          _pending.writeCharCode(code);
      }
    }
  }

  void _backspace() {
    final current = _pending.toString();
    if (current.isEmpty) return;
    _pending
      ..clear()
      ..write(current.substring(0, current.length - 1));
  }

  void _clear() {
    _pending.clear();
  }

  void _submit() {
    final command = _pending.toString().trim();
    _pending.clear();
    if (command.isEmpty) return;
    onCommand(command);
  }

  bool _consumeBracketedPasteEnd(String text, int start) {
    // "ESC[201~" is the terminator.
    return start + 5 < text.length &&
        text.codeUnitAt(start) == 0x1B &&
        text.codeUnitAt(start + 1) == 0x5B &&
        text.startsWith('201~', start + 2);
  }
}
