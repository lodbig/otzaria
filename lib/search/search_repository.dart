import 'package:otzaria/data/data_providers/tantivy_data_provider.dart';
import 'package:otzaria/search/search_query_builder.dart';
import 'package:search_engine/search_engine.dart';
import 'package:flutter/foundation.dart';

/// Performs a search operation across indexed texts.
///
/// [query] The search query string
/// [facets] List of facets to search within
/// [limit] Maximum number of results to return
/// [order] Sort order for results
/// [fuzzy] Whether to perform fuzzy matching
/// [distance] Default distance between words (slop)
/// [customSpacing] Custom spacing between specific word pairs
/// [alternativeWords] Alternative words for each word position (OR queries)
/// [searchOptions] Search options for each word (prefixes, suffixes, etc.)
///
/// Returns a Future containing a list of search results
///
class SearchRepository {
  Future<List<SearchResult>> searchTexts(
      String query, List<String> facets, int limit,
      {ResultsOrder order = ResultsOrder.relevance,
      bool fuzzy = false,
      int distance = 2,
      Map<String, String>? customSpacing,
      Map<int, List<String>>? alternativeWords,
      Map<String, Map<String, bool>>? searchOptions}) async {
    final index = await TantivyDataProvider.instance.engine;

    // בדיקה אם יש מרווחים מותאמים אישית, מילים חילופיות או אפשרויות חיפוש
    final hasCustomSpacing = customSpacing != null && customSpacing.isNotEmpty;
    final hasAlternativeWords =
        alternativeWords != null && alternativeWords.isNotEmpty;
    debugPrint('🔍 hasCustomSpacing: $hasCustomSpacing');
    final hasSearchOptions = searchOptions != null &&
        searchOptions.isNotEmpty &&
        searchOptions.values.any((wordOptions) =>
            wordOptions.values.any((isEnabled) => isEnabled == true));

    debugPrint('🔍 hasSearchOptions: $hasSearchOptions');
    debugPrint('🔍 hasAlternativeWords: $hasAlternativeWords');

    // המרת החיפוש לפורמט המנוע החדש
    debugPrint('🔍 Using prepareQueryParams');
    final params = SearchQueryBuilder.prepareQueryParams(
        query, fuzzy, distance, customSpacing, alternativeWords, searchOptions);
    final List<String> regexTerms = params['regexTerms'] as List<String>;
    final int effectiveSlop = params['effectiveSlop'] as int;
    final int maxExpansions = params['maxExpansions'] as int;

    debugPrint('🔍 Final search params:');
    debugPrint('   regexTerms: $regexTerms');
    debugPrint('   facets: $facets');
    debugPrint('   limit: $limit');
    debugPrint('   slop: $effectiveSlop');
    debugPrint('   maxExpansions: $maxExpansions');
    debugPrint('🚀 Calling index.search...');

    final results = await index.search(
        regexTerms: regexTerms,
        facets: facets,
        limit: limit,
        offset: 0,
        slop: effectiveSlop,
        maxExpansions: maxExpansions,
        order: order);

    debugPrint('✅ Search completed, found ${results.length} results');
    return results;
  }

  /// Performs a streaming search operation across indexed texts.
  /// Results are returned in chunks for better UX with large result sets.
  ///
  /// [query] The search query string
  /// [facets] List of facets to search within
  /// [limit] Maximum number of results to return
  /// [chunkSize] Number of results per chunk (default: 50)
  /// [order] Sort order for results
  /// [fuzzy] Whether to perform fuzzy matching
  /// [distance] Default distance between words (slop)
  /// [customSpacing] Custom spacing between specific word pairs
  /// [alternativeWords] Alternative words for each word position (OR queries)
  /// [searchOptions] Search options for each word (prefixes, suffixes, etc.)
  ///
  /// Returns a Stream of search result chunks
  ///
  Stream<List<SearchResult>> searchTextsStream(
      String query, List<String> facets, int limit,
      {int chunkSize = 50,
      ResultsOrder order = ResultsOrder.relevance,
      bool fuzzy = false,
      int distance = 2,
      Map<String, String>? customSpacing,
      Map<int, List<String>>? alternativeWords,
      Map<String, Map<String, bool>>? searchOptions}) async* {
    final index = await TantivyDataProvider.instance.engine;

    // המרת החיפוש לפורמט המנוע החדש
    final params = SearchQueryBuilder.prepareQueryParams(
        query, fuzzy, distance, customSpacing, alternativeWords, searchOptions);
    final List<String> regexTerms = params['regexTerms'] as List<String>;
    final int effectiveSlop = params['effectiveSlop'] as int;
    final int maxExpansions = params['maxExpansions'] as int;

    debugPrint('🔍 Starting streaming search:');
    debugPrint('   regexTerms: $regexTerms');
    debugPrint('   facets: $facets');
    debugPrint('   limit: $limit');
    debugPrint('   chunkSize: $chunkSize');
    debugPrint('   slop: $effectiveSlop');
    debugPrint('   maxExpansions: $maxExpansions');

    final stream = index.searchStream(
      regexTerms: regexTerms,
      facets: facets,
      limit: limit,
      offset: 0,
      slop: effectiveSlop,
      maxExpansions: maxExpansions,
      order: order,
      chunkSize: chunkSize,
    );

    await for (final chunk in stream) {
      debugPrint('📦 Received chunk of ${chunk.length} results');
      yield chunk;
    }

    debugPrint('✅ Streaming search completed');
  }
}
