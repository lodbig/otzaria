import 'package:otzaria/models/books.dart';
import 'package:otzaria/search/book_facet.dart';

/// Helper class for facet-related operations
class FacetHelper {
  FacetHelper._();

  /// Resolves the category path for a book
  static String? resolveCategoryPath(Book book) {
    if (book.category?.path != null && book.category!.path.isNotEmpty) {
      return book.category!.path;
    }
    if (book.categoryPath != null && book.categoryPath!.isNotEmpty) {
      return book.categoryPath;
    }
    if (book.topics.isNotEmpty) {
      final topicsPath = BookFacet.topicsToPath(book.topics);
      return topicsPath.isEmpty ? null : topicsPath;
    }
    return null;
  }

  /// Builds a book facet path from category path and book
  /// Uses catalogueOrderKey for uniqueness instead of title
  static String buildBookFacet(String? categoryPath, Book book) {
    final bookKey = _buildBookKey(book);
    if (categoryPath == null || categoryPath.isEmpty || categoryPath == '/') {
      return '/$bookKey';
    }
    return '$categoryPath/$bookKey';
  }

  /// Builds a unique key for a book (same logic as IndexingRepository.catalogueOrderKey)
  static String _buildBookKey(Book book) {
    if (book.externalLibraryId != null && book.externalLibraryId!.isNotEmpty) {
      return 'ext:${book.externalLibraryId}';
    }

    if (book.id != null) {
      return 'id:${book.id}';
    }

    final categoryKey = book.category?.path ?? book.categoryPath ?? '';
    final fileTypeKey = book.fileType ?? book.runtimeType.toString();
    final pathKey = book is FileBook ? book.path : (book.filePath ?? '');
    return '${book.title}|$categoryKey|$fileTypeKey|$pathKey';
  }

  /// Increments a facet count in the given map
  static void incrementFacet(Map<String, int> counts, String facet,
      [int delta = 1]) {
    counts[facet] = (counts[facet] ?? 0) + delta;
  }

  /// Increments facet counts for all ancestors in the category path
  static void incrementFacetWithAncestors(
      Map<String, int> counts, String categoryPath,
      [int delta = 1]) {
    if (categoryPath.isEmpty) return;

    final normalized =
        categoryPath.startsWith('/') ? categoryPath : '/$categoryPath';

    incrementFacet(counts, '/', delta);
    final parts = normalized.split('/').where((p) => p.isNotEmpty).toList();
    var current = '';
    for (final part in parts) {
      current = '$current/$part';
      incrementFacet(counts, current, delta);
    }
  }

  /// Builds facet counts from search results and library books
  static Map<String, int> buildFacetCountsFromResults(
    List<dynamic> results,
    Map<String, Book> bookByTitle,
  ) {
    final counts = <String, int>{};
    if (results.isEmpty) {
      return counts;
    }

    for (final result in results) {
      final title = result.title;
      final book = bookByTitle[title];

      if (book != null) {
        final categoryPath = resolveCategoryPath(book);
        final bookFacet = buildBookFacet(categoryPath, book);

        incrementFacet(counts, bookFacet);

        if (categoryPath != null && categoryPath.isNotEmpty) {
          incrementFacetWithAncestors(counts, categoryPath);
        } else {
          incrementFacet(counts, '/');
        }
      }
    }

    return counts;
  }
}
