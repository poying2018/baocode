import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/platform/shell_command_io.dart';

/// What the macOS installer asks the system to run as root: the string
/// AppleScript reads it as. It is the same on every machine, so it is
/// checked on every one.
void main() {
  test('the AppleScript keeps backslashes and quotes', () {
    expect(
      MacShellCommand.administratorScript(r'''echo "a\b" 'c' '''),
      r'''do shell script "echo \"a\\b\" 'c' " with administrator privileges''',
    );
  });

  test('the AppleScript keeps a newline in the string it is in', () {
    // A path may hold a newline, and it would end the string the command
    // is in.
    expect(
      MacShellCommand.administratorScript("cp 'a\nb' /usr/local/bin/x"),
      r'''do shell script "cp 'a\nb' /usr/local/bin/x" with administrator privileges''',
    );
  });

  test('the AppleScript keeps a tab and a carriage return', () {
    expect(
      MacShellCommand.administratorScript("cp 'a\tb\rc' /usr/local/bin/x"),
      r'''do shell script "cp 'a\tb\rc' /usr/local/bin/x" with administrator privileges''',
    );
  });
}
