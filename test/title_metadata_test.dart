import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/title_metadata.dart';

void main() {
  test('alternative names are unique regardless of case and spaces', () {
    expect(distinctAlternativeNames('Баллада о герое', [
      'Hero\'s Ballad', '  hero\'s   ballad  ', 'Баллада о герое',
      ' Ode of the Brave ', 'ODE OF THE BRAVE', '',
    ]), ['Hero\'s Ballad', 'Ode of the Brave']);
  });
  test('empty alternatives remain absent, not a fabricated section', () {
    expect(distinctAlternativeNames('Произведение', const []), isEmpty);
  });
}
