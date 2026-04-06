import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:otzaria/settings/settings_exports.dart';
import 'package:otzaria/text_book/bloc/text_book_bloc.dart';
import 'package:otzaria/text_book/bloc/text_book_event.dart';
import 'package:otzaria/text_book/bloc/text_book_state.dart';
import 'package:otzaria/text_book/models/search_results.dart';
import 'package:otzaria/utils/text_manipulation.dart' as utils;
import 'package:otzaria/widgets/search_pane_base.dart';
import 'package:otzaria/search/search_repository.dart';
import 'package:otzaria/search/book_facet.dart';
import 'package:search_engine/search_engine.dart';
import 'package:otzaria/search/view/search_dialog.dart';
import 'package:otzaria/tabs/models/searching_tab.dart';
import 'package:otzaria/search/bloc/search_event.dart';
import 'package:otzaria/search/models/search_configuration.dart';
import 'package:otzaria/models/books.dart';
import 'package:otzaria/widgets/nikud_search_button.dart';
import 'package:otzaria/text_book/utils/section_search_utils.dart';
import 'package:otzaria/text_book/utils/search_query_sync.dart';

class _GroupedResultItem {
  final String? header;
  final TextSearchResult? result;
  final int? resultListIndex;
  const _GroupedResultItem.header(this.header)
      : result = null,
        resultListIndex = null;
  const _GroupedResultItem.result(this.result, this.resultListIndex)
      : header = null;
  bool get isHeader => header != null;
}

class TextBookSearchView extends StatefulWidget {
  final String data;
  final ItemScrollController scrollControler;
  final FocusNode focusNode;
  final void Function() closeLeftPaneCallback;
  final String initialQuery;
  final Map<String, Map<String, bool>> initialSearchOptions;
  final Map<int, List<String>> initialAlternativeWords;
  final Map<String, String> initialSpacingValues;
  final SearchMode initialSearchMode;

  const TextBookSearchView({
    super.key,
    required this.data,
    required this.scrollControler,
    required this.focusNode,
    required this.closeLeftPaneCallback,
    required this.initialQuery,
    this.initialSearchOptions = const {},
    this.initialAlternativeWords = const {},
    this.initialSpacingValues = const {},
    this.initialSearchMode = SearchMode.exact,
  });

  @override
  TextBookSearchViewState createState() => TextBookSearchViewState();
}

class TextBookSearchViewState extends State<TextBookSearchView>
    with AutomaticKeepAliveClientMixin<TextBookSearchView> {
  TextEditingController searchTextController = TextEditingController();
  final SearchRepository _searchRepository = SearchRepository();
  List<TextSearchResult> searchResults = [];
  late ItemScrollController scrollControler;
  bool _isSearching = false;
  List<String> _content = [];
  String? _bookPath;
  String? _bookTitle;
  bool _forceSearchEngine = false;
  Map<String, Map<String, bool>> _searchOptions = {};
  Map<int, List<String>> _alternativeWords = {};
  Map<String, String> _spacingValues = {};
  SearchMode _searchMode = SearchMode.exact;
  bool _searchWithNikud = false;
  bool _searchInCurrentSection = false;
  SectionBounds? _currentSectionBounds;
  List<int> _lastVisibleIndices = [];
  int? _selectedSearchResultIndex;

  bool get _isSimpleSearch =>
      !_forceSearchEngine &&
      _searchOptions.isEmpty &&
      _alternativeWords.isEmpty &&
      _spacingValues.isEmpty &&
      _searchMode == SearchMode.exact;

  static const int _maxResultSnippetChars = 220;

  @override
  void initState() {
    super.initState();
    _content = widget.data.split('\n');

    searchTextController.text = widget.initialQuery;
    _searchOptions = widget.initialSearchOptions;
    _alternativeWords = widget.initialAlternativeWords;
    _spacingValues = widget.initialSpacingValues;
    _searchMode = widget.initialSearchMode;
    _forceSearchEngine = _searchMode != SearchMode.exact ||
        _searchOptions.isNotEmpty ||
        _alternativeWords.isNotEmpty ||
        _spacingValues.isNotEmpty;

    scrollControler = widget.scrollControler;
    widget.focusNode.requestFocus();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeBookPath();
      _updateCurrentSection();
    });
  }

  @override
  void didUpdateWidget(TextBookSearchView oldWidget) {
    super.didUpdateWidget(oldWidget);

    // עדכון שדה החיפוש אם initialQuery השתנה
    final queryChanged = widget.initialQuery != oldWidget.initialQuery;
    final needsControllerSync =
        widget.initialQuery != searchTextController.text;

    if (queryChanged && needsControllerSync) {
      syncSearchControllerQuery(searchTextController, widget.initialQuery);

      // הרצת חיפוש אם יש טקסט חדש
      if (widget.initialQuery.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _searchTextUpdated();
          }
        });
      }
    }
  }

  Future<void> _initializeBookPath() async {
    if (!mounted) return;
    final state = context.read<TextBookBloc>().state;
    if (state is TextBookLoaded) {
      final bookTitle = state.book.title;
      debugPrint('📚 TextBookSearch: book.title = $bookTitle');

      _bookTitle = bookTitle;

      final topics = await BookFacet.resolveTopics(
        title: bookTitle,
        initialTopics: state.book.topics,
        type: TextBook,
        categoryPath: state.book.categoryPath,
      );

      if (!mounted) return;

      debugPrint('📚 TextBookSearch: final topics = "$topics"');
      _bookPath = BookFacet.buildFacetPath(
        title: bookTitle,
        topics: topics,
        bookId: state.book.id,
        externalLibraryId: state.book.externalLibraryId,
        categoryPath: state.book.categoryPath,
        fileType: state.book.fileType,
        filePath: state.book.filePath,
      );
      debugPrint('📚 TextBookSearch: _bookPath = $_bookPath');
      if (searchTextController.text.isNotEmpty) {
        _runInitialSearch();
      }
    }
  }

  void _runInitialSearch() {
    _searchTextUpdated();
  }

  void _updateCurrentSection() {
    if (!mounted) return;
    final state = context.read<TextBookBloc>().state;
    if (state is! TextBookLoaded) return;

    // Check if visibleIndices changed to avoid unnecessary recalculation
    if (_lastVisibleIndices.isNotEmpty &&
        listEquals(_lastVisibleIndices, state.visibleIndices)) {
      return;
    }

    _lastVisibleIndices = List.from(state.visibleIndices);

    final bounds = detectCurrentSection(
      content: _content,
      visibleIndices: state.visibleIndices,
    );

    setState(() {
      _currentSectionBounds = bounds;
    });
  }

  Future<void> _searchTextUpdated() async {
    String query = searchTextController.text.trim();
    if (query.isEmpty ||
        (!_isSimpleSearch && (_bookPath == null || _bookTitle == null))) {
      setState(() {
        searchResults = [];
        _isSearching = false;
      });
      return;
    }

    // הסרת ניקוד כברירת מחדל, אלא אם המשתמש לחץ על כפתור "עם ניקוד"
    if (!_searchWithNikud && utils.hasNikud(query)) {
      query = utils.removeVolwels(query);
    }

    setState(() {
      _isSearching = true;
    });

    if (_isSimpleSearch) {
      final results = await searchInContent(
        content: _content,
        query: query,
        bounds: _searchInCurrentSection ? _currentSectionBounds : null,
      );

      if (mounted) {
        _applySearchResults(results);
      }
      return;
    }

    try {
      // The facet filter is a prefix filter in the underlying engine, so when a
      // book is a parent facet (e.g. /.../ספר הזהר) it may also match child
      // facets like commentaries. We therefore post-filter by exact title.
      //
      // Use a higher raw limit to avoid losing relevant results that would have
      // been returned after filtering.
      const rawLimit = 5000;
      const displayLimit = 1000;

      final rawResults = await _searchRepository.searchTexts(
        query,
        [_bookPath!],
        rawLimit,
        searchOptions: _searchOptions,
        alternativeWords: _alternativeWords,
        customSpacing: _spacingValues,
        fuzzy: _searchMode == SearchMode.fuzzy,
      );

      final expectedTitle = _bookTitle!.trim();

      final filtered = rawResults
          .where((r) => !r.isPdf && r.title.trim() == expectedTitle)
          .toList(growable: false);

      // In-book search should be presented in reading order (by segment/line),
      // not by relevance.
      final sorted = filtered.toList(growable: true)
        ..sort((a, b) {
          final sa = a.segment.toInt();
          final sb = b.segment.toInt();
          if (sa != sb) return sa.compareTo(sb);

          final ra = a.reference;
          final rb = b.reference;
          final rc = ra.compareTo(rb);
          if (rc != 0) return rc;

          return a.text.compareTo(b.text);
        });

      final results = sorted.take(displayLimit).toList(growable: false);

      debugPrint(
        '📚 TextBookSearch: rawResults=${rawResults.length}, '
        'filteredResults=${results.length}, title="$expectedTitle"',
      );

      if (mounted) {
        _applySearchResults(_convertSearchResults(results));
      }
    } catch (e) {
      debugPrint('Search error: $e');
      if (mounted) {
        setState(() {
          searchResults = [];
          _isSearching = false;
          _selectedSearchResultIndex = null;
        });
      }
    }
  }

  void _applySearchResults(List<TextSearchResult> results) {
    setState(() {
      searchResults = results;
      _isSearching = false;
      if (results.isEmpty) {
        _selectedSearchResultIndex = null;
      } else if (_selectedSearchResultIndex == null ||
          _selectedSearchResultIndex! >= results.length) {
        _selectedSearchResultIndex = 0;
      }
    });
  }

  void _navigateToSearchResult(
    int resultListIndex, {
    bool closePaneOnAndroid = false,
  }) {
    if (resultListIndex < 0 || resultListIndex >= searchResults.length) {
      return;
    }

    final result = searchResults[resultListIndex];
    setState(() {
      _selectedSearchResultIndex = resultListIndex;
    });

    final bloc = context.read<TextBookBloc>();
    bloc.add(UpdateSelectedIndex(result.index));
    bloc.add(HighlightLine(result.index));

    widget.scrollControler.scrollTo(
      index: result.index,
      duration: const Duration(milliseconds: 250),
      curve: Curves.ease,
      alignment: 0.35,
    );

    if (closePaneOnAndroid && Platform.isAndroid) {
      widget.closeLeftPaneCallback();
    }
  }

  void _moveBetweenResults(int offset) {
    if (searchResults.isEmpty) {
      return;
    }

    final currentIndex =
        _selectedSearchResultIndex ?? (offset >= 0 ? -1 : searchResults.length);
    final nextIndex =
        (currentIndex + offset).clamp(0, searchResults.length - 1);
    if (nextIndex == currentIndex) {
      return;
    }

    _navigateToSearchResult(nextIndex);
  }

  List<TextSearchResult> _convertSearchResults(List<SearchResult> results) {
    final List<TextSearchResult> converted = [];
    for (final result in results) {
      try {
        final lineNumber = result.segment.toInt();
        if (lineNumber >= 0 && lineNumber < _content.length) {
          converted.add(TextSearchResult(
            index: lineNumber,
            snippet: result.text,
            address: result.reference,
            query: searchTextController.text,
          ));
        }
      } catch (e) {
        debugPrint('Error converting result: $e');
      }
    }
    return converted;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // יצירת רשימה מקובצת - כותרת מופיעה רק כשהיא משתנה
    final List<_GroupedResultItem> items = [];
    String? lastAddress;
    for (var resultListIndex = 0;
        resultListIndex < searchResults.length;
        resultListIndex++) {
      final r = searchResults[resultListIndex];
      if (lastAddress != r.address) {
        items.add(_GroupedResultItem.header(r.address));
        lastAddress = r.address;
      }
      items.add(_GroupedResultItem.result(r, resultListIndex));
    }

    return BlocListener<TextBookBloc, TextBookState>(
      listenWhen: (prev, current) =>
          prev is TextBookLoaded &&
          current is TextBookLoaded &&
          !listEquals(prev.visibleIndices, current.visibleIndices),
      listener: (context, state) {
        _updateCurrentSection();
      },
      child: SearchPaneBase(
        searchController: searchTextController,
        focusNode: widget.focusNode,
        progressWidget:
            _isSearching ? const LinearProgressIndicator(minHeight: 4) : null,
        resultToolbar:
            searchResults.isNotEmpty ? _buildSearchResultNavigationBar() : null,
        resultCountString: searchResults.isNotEmpty
            ? 'נמצאו ${searchResults.length} תוצאות'
            : null,
        resultsWidget: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];

            // אם זו כותרת קבוצה
            if (item.isHeader) {
              return BlocBuilder<SettingsBloc, SettingsState>(
                builder: (context, settingsState) {
                  String text = item.header!;
                  if (settingsState.replaceHolyNames) {
                    text = utils.replaceHolyNames(text);
                  }
                  return Padding(
                    padding: const EdgeInsets.only(
                      top: 8.0,
                      bottom: 8.0,
                      right: 4.0,
                      left: 4.0,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          FluentIcons.text_align_right_24_regular,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            text,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            }

            // אם זו תוצאה רגילה
            final result = item.result!;
            final resultListIndex = item.resultListIndex!;
            return BlocBuilder<SettingsBloc, SettingsState>(
              builder: (context, settingsState) {
                String snippet = result.snippet;

                if (settingsState.replaceHolyNames) {
                  snippet = utils.replaceHolyNames(snippet);
                }

                snippet = _buildSearchExcerpt(
                  fullText: snippet,
                  query: result.query,
                  maxChars: _maxResultSnippetChars,
                );

                // יצירת TextSpans עם הדגשה של מילות החיפוש
                final highlightedSnippet = _buildHighlightedText(
                  snippet,
                  result.query,
                  settingsState,
                  context,
                );

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: _selectedSearchResultIndex == resultListIndex
                        ? Theme.of(context)
                            .colorScheme
                            .primaryContainer
                            .withValues(alpha: 0.35)
                        : null,
                    border: Border.all(
                      color: _selectedSearchResultIndex == resultListIndex
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context)
                              .colorScheme
                              .outline
                              .withValues(alpha: 0.3),
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: InkWell(
                    onTap: () {
                      _navigateToSearchResult(
                        resultListIndex,
                        closePaneOnAndroid: true,
                      );
                    },
                    borderRadius: BorderRadius.circular(8),
                    hoverColor: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withValues(alpha: 0.3),
                    splashColor: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withValues(alpha: 0.4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: RichText(
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.justify,
                        text: TextSpan(
                          style: TextStyle(
                            fontSize: 16,
                            fontFamily: settingsState.fontFamily,
                            color: Theme.of(context).colorScheme.onSurface,
                            height: 1.5,
                          ),
                          children: highlightedSnippet,
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
        isNoResults: searchResults.isEmpty &&
            searchTextController.text.isNotEmpty &&
            !_isSearching,
        onSearchTextChanged: (value) {
          context.read<TextBookBloc>().add(UpdateSearchText(value));
          _searchTextUpdated();
        },
        resetSearchCallback: () {
          setState(() {
            searchResults = [];
            _forceSearchEngine = false;
            _searchOptions = {};
            _alternativeWords = {};
            _spacingValues = {};
            _searchMode = SearchMode.exact;
            _searchWithNikud = false;
            _searchInCurrentSection = false;
          });
        },
        additionalActions: [
          // כפתור "כל הספר"
          _buildScopeButton(
            message: 'חיפוש בכל הספר',
            icon: FluentIcons.book_24_regular,
            isActive: !_searchInCurrentSection,
            onTap: () {
              setState(() {
                _searchInCurrentSection = false;
              });
              _searchTextUpdated();
            },
          ),
          const SizedBox(width: 4),
          // כפתור "כותרת נוכחית"
          _buildScopeButton(
            message: 'חיפוש בקטע נוכחי',
            icon: FluentIcons.text_align_right_24_regular,
            isActive: _searchInCurrentSection,
            onTap: () {
              setState(() {
                _searchInCurrentSection = true;
              });
              _updateCurrentSection(); // עדכן את הקטע הנוכחי
              // Wait for the next frame to ensure _currentSectionBounds is updated
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _searchTextUpdated();
              });
            },
          ),
          // כפתור חיפוש עם ניקוד (רק אם יש ניקוד בטקסט)
          if (utils.hasNikud(searchTextController.text)) ...[
            const SizedBox(width: 4),
            NikudSearchButton(
              isActive: _searchWithNikud,
              onPressed: () {
                setState(() {
                  _searchWithNikud = !_searchWithNikud;
                });
                _searchTextUpdated();
              },
            ),
          ],
        ],
        hintText: 'חפש כאן...',
        onAdvancedSearch: () {
          // Create a temporary SearchingTab to hold the state
          final tempTab = SearchingTab("חיפוש", searchTextController.text);
          tempTab.searchOptions.addAll(_searchOptions);
          tempTab.alternativeWords.addAll(_alternativeWords);
          tempTab.spacingValues.addAll(_spacingValues);
          tempTab.searchBloc.add(SetSearchMode(_searchMode));

          final bookTitle =
              (context.read<TextBookBloc>().state as TextBookLoaded).book.title;

          showDialog(
            context: context,
            builder: (context) => SearchDialog(
              existingTab: tempTab,
              bookTitle: bookTitle,
              onSearch: (query, searchOptions, alternativeWords, spacingValues,
                  searchMode) {
                applyInBookSearchQuery(
                  controller: searchTextController,
                  query: query,
                  onQueryChanged: (value) {
                    context.read<TextBookBloc>().add(UpdateSearchText(value));
                  },
                );
                setState(() {
                  _forceSearchEngine = true;
                  _searchOptions = searchOptions;
                  _alternativeWords = alternativeWords;
                  _spacingValues = spacingValues;
                  _searchMode = searchMode;
                });
                _searchTextUpdated();
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildSearchResultNavigationBar() {
    final isAtFirstResult =
        (_selectedSearchResultIndex ?? 0) <= 0 || searchResults.isEmpty;
    final isAtLastResult = searchResults.isEmpty ||
        (_selectedSearchResultIndex ?? 0) >= searchResults.length - 1;

    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: 12,
        end: 12,
        bottom: 2,
      ),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildResultNavigationButton(
              icon: FluentIcons.chevron_up_24_regular,
              tooltip: 'התוצאה הקודמת',
              onPressed: isAtFirstResult ? null : () => _moveBetweenResults(-1),
            ),
            const SizedBox(width: 4),
            _buildResultNavigationButton(
              icon: FluentIcons.chevron_down_24_regular,
              tooltip: 'התוצאה הבאה',
              onPressed: isAtLastResult ? null : () => _moveBetweenResults(1),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultNavigationButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isEnabled = onPressed != null;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: isEnabled
                ? colorScheme.primaryContainer.withValues(alpha: 0.55)
                : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isEnabled
                  ? colorScheme.primary.withValues(alpha: 0.6)
                  : colorScheme.outline.withValues(alpha: 0.3),
            ),
          ),
          child: Icon(
            icon,
            size: 16,
            color: isEnabled
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }

  // פונקציה ליצירת טקסט מודגש
  List<InlineSpan> _buildHighlightedText(
    String text,
    String query,
    SettingsState settingsState,
    BuildContext context,
  ) {
    if (query.isEmpty) {
      return [TextSpan(text: text)];
    }

    final List<InlineSpan> spans = [];
    final searchTerms = query.trim().split(RegExp(r'\s+'));

    final highlightRegex = RegExp(
      searchTerms.map(RegExp.escape).join('|'),
      caseSensitive: false,
    );

    int currentPosition = 0;

    for (final match in highlightRegex.allMatches(text)) {
      // טקסט רגיל לפני ההדגשה
      if (match.start > currentPosition) {
        spans.add(TextSpan(
          text: text.substring(currentPosition, match.start),
        ));
      }
      // הטקסט המודגש
      spans.add(TextSpan(
        text: match.group(0),
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 18,
          color: Color(0xFFD32F2F), // צבע אדום חזק למילות החיפוש
        ),
      ));
      currentPosition = match.end;
    }

    // טקסט רגיל אחרי ההדגשה האחרונה
    if (currentPosition < text.length) {
      spans.add(TextSpan(
        text: text.substring(currentPosition),
      ));
    }

    return spans;
  }

  String _buildSearchExcerpt({
    required String fullText,
    required String query,
    required int maxChars,
  }) {
    var text = fullText.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= maxChars) return text;

    // Helper to find word end
    int findWordEnd(int fromIndex) {
      if (fromIndex >= text.length) return text.length;
      final nextSpace = text.indexOf(' ', fromIndex);
      return nextSpace != -1 ? nextSpace : text.length;
    }

    // Helper to find word start
    int findWordStart(int fromIndex) {
      if (fromIndex <= 0) return 0;
      final lastSpace = text.lastIndexOf(' ', fromIndex);
      return lastSpace != -1 ? lastSpace + 1 : 0;
    }

    final q = query.trim();
    if (q.isEmpty) {
      var end = findWordEnd(maxChars);
      final suffix = end < text.length ? ' ...' : '';
      return '${text.substring(0, end)}$suffix';
    }

    final terms = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (terms.isEmpty) {
      var end = findWordEnd(maxChars);
      final suffix = end < text.length ? ' ...' : '';
      return '${text.substring(0, end)}$suffix';
    }

    final highlightRegex = RegExp(
      terms.map(RegExp.escape).join('|'),
      caseSensitive: false,
    );

    final matches = highlightRegex.allMatches(text);
    if (matches.isEmpty) {
      var end = findWordEnd(maxChars);
      final suffix = end < text.length ? ' ...' : '';
      return '${text.substring(0, end)}$suffix';
    }

    Match? bestMatch;
    Match? firstMatch;

    // Try to find a whole word match
    // We define a word char as alphanumeric or Hebrew
    final wordCharRegex = RegExp(r'[a-zA-Z0-9\u0590-\u05FF]');

    for (final match in matches) {
      firstMatch ??= match;

      final start = match.start;
      final end = match.end;

      bool startOk = start == 0 || !wordCharRegex.hasMatch(text[start - 1]);
      bool endOk = end == text.length || !wordCharRegex.hasMatch(text[end]);

      if (startOk && endOk) {
        bestMatch = match;
        break;
      }
    }

    bestMatch ??= firstMatch;

    final len = text.length;
    var start = (bestMatch!.start - (maxChars ~/ 2)).clamp(0, len);
    var end = (start + maxChars).clamp(0, len);

    // If we're at the end and didn't get enough chars, shift the window left.
    if (end - start < maxChars) {
      start = (end - maxChars).clamp(0, len);
    }

    start = findWordStart(start);
    end = findWordEnd(end);

    final prefix = start > 0 ? '... ' : '';
    final suffix = end < len ? ' ...' : '';
    return '$prefix${text.substring(start, end)}$suffix';
  }

  /// בונה כפתור בחירת טווח חיפוש (כל הספר / קטע נוכחי)
  Widget _buildScopeButton({
    required String message,
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: message,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: isActive ? colorScheme.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isActive
                  ? colorScheme.primary
                  : colorScheme.outline.withValues(alpha: 0.5),
              width: 1.5,
            ),
          ),
          child: Icon(
            icon,
            size: 16,
            color: isActive
                ? colorScheme.primary
                : colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
