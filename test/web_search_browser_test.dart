import 'package:flutter_test/flutter_test.dart';
import 'package:smart_search_app/features/web/presentation/web_search_browser.dart';

void main() {
  test('Google search URL encodes the complete query', () {
    final uri =
        GoogleSearchBrowserPage.searchUri('best cafes in Bangalore & nearby');

    expect(
      uri.toString(),
      'https://www.google.com/search?q=best+cafes+in+Bangalore+%26+nearby',
    );
    expect(uri.queryParameters['q'], 'best cafes in Bangalore & nearby');
  });
}
