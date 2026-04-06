import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:otzaria/core/app_paths.dart';
import 'package:otzaria/data/data_providers/tantivy_data_provider.dart';
import 'package:otzaria/data/data_providers/sqlite_data_provider.dart';
import 'package:otzaria/library/models/library.dart';
import 'package:otzaria/models/books.dart';
import 'package:otzaria/indexing/services/indexing_isolate_service.dart';
import 'package:otzaria/search/utils/search_catalogue_order_helper.dart';

class IndexingRepository {
  final TantivyDataProvider _tantivyDataProvider;
  final IndexingIsolateService? _isolateService;
  IndexingIsolateService? _activeIsolateService;

  IndexingRepository(this._tantivyDataProvider,
      {IndexingIsolateService? isolateService})
      : _isolateService = isolateService;

  @visibleForTesting
  static bool shouldResetBeforeFullReindex({
    required bool indexExistedBeforeInit,
    required List<String> booksDone,
  }) {
    return indexExistedBeforeInit && booksDone.isEmpty;
  }

  /// Indexes all books in the provided library.
  ///
  /// [library] The library containing books to index
  /// [onProgress] Callback function to report progress
  /// מבצע אינדוקס ומחזיר true אם הסתיים בהצלחה, false אם בוטל
  Future<bool> indexAllBooks(
    Library library, {
    void Function()? onActualIndexingStarted,
    required void Function(int processed, int total) onProgress,
  }) async {
    _tantivyDataProvider.isIndexing.value = true;
    final isolateService =
        _isolateService ?? await IndexingIsolateService.create();
    _activeIsolateService = isolateService;
    final catalogueOrderSignature = buildCatalogueOrderSignature(library);
    final catalogueOrderByBookKey = SearchCatalogueOrderHelper.buildKeyOrderMap(
      library,
      keyOf: (book) => catalogueOrderKey(book as Book),
    );

    final allBooks = library.getAllBooks();
    final totalBooks = allBooks.length;
    bool cancelled = false;
    var didStartActualIndexing = false;

    try {
      await _tantivyDataProvider
          .ensureIndexStateMatchesCatalogue(catalogueOrderSignature);

      if (shouldResetBeforeFullReindex(
        indexExistedBeforeInit: _tantivyDataProvider.indexExistedBeforeInit,
        booksDone: _tantivyDataProvider.booksDone,
      )) {
        await _resetExistingIndexBeforeFullReindex();
      }

      int processedBooks = 0;
      int actuallyIndexed = 0;
      int skipped = 0;
      int errors = 0;

      debugPrint('📚 התחלת אינדוקס: $totalBooks ספרים');
      debugPrint(
          '📊 ספרים שכבר מאונדקסים: ${_tantivyDataProvider.booksDone.length}');

      for (Book book in allBooks) {
        if (!_tantivyDataProvider.isIndexing.value) {
          debugPrint('⚠️ אינדוקס בוטל על ידי המשתמש');
          cancelled = true;
          break;
        }

        try {
          final indexedBookKey = catalogueOrderKey(book);
          if (book is TextBook) {
            if (!_tantivyDataProvider.booksDone.contains(indexedBookKey)) {
              debugPrint('📖 מאנדקס ספר טקסט ב-isolate: ${book.title}');
              await _indexTextBook(
                book,
                isolateService,
                catalogueOrderByBookKey: catalogueOrderByBookKey,
                onActualIndexingStarted: () {
                  if (didStartActualIndexing) {
                    return;
                  }
                  didStartActualIndexing = true;
                  onActualIndexingStarted?.call();
                },
              );
              _tantivyDataProvider.booksDone.add(indexedBookKey);
              actuallyIndexed++;
            } else {
              debugPrint('⏭️ דילוג על ספר טקסט שכבר מאונדקס: ${book.title}');
              skipped++;
            }
          } else if (book is PdfBook) {
            if (!_tantivyDataProvider.booksDone.contains(indexedBookKey)) {
              debugPrint('📄 מאנדקס PDF ב-isolate: ${book.title}');
              await _indexPdfBook(
                book,
                isolateService,
                catalogueOrderByBookKey: catalogueOrderByBookKey,
                onActualIndexingStarted: () {
                  if (didStartActualIndexing) {
                    return;
                  }
                  didStartActualIndexing = true;
                  onActualIndexingStarted?.call();
                },
              );
              _tantivyDataProvider.booksDone.add(indexedBookKey);
              actuallyIndexed++;
            } else {
              debugPrint('⏭️ דילוג על PDF שכבר מאונדקס: ${book.title}');
              skipped++;
            }
          }

          processedBooks++;
          if (processedBooks % 25 == 0) {
            debugPrint('💾 שומר אינדקס (commit)...');
            final index = await _tantivyDataProvider.engine;
            await index.commit();
            saveIndexedBooks();
          }

          if (processedBooks % 50 == 0) {
            debugPrint(
                '📈 התקדמות: $processedBooks/$totalBooks (מאונדקסים: $actuallyIndexed, דולגו: $skipped, שגיאות: $errors)');
          }

          onProgress(processedBooks, totalBooks);
        } catch (e) {
          await Future.microtask(() {
            debugPrint('❌ שגיאה באינדוקס של ${book.title}: $e');
          });
          errors++;
          processedBooks++;
          onProgress(processedBooks, totalBooks);
          await Future.delayed(Duration.zero);
        }

        await Future.delayed(Duration.zero);
      }

      if (!cancelled) {
        debugPrint('✅ אינדוקס הושלם!');
        debugPrint('   📊 סה"כ: $totalBooks ספרים');
        debugPrint('   ✅ מאונדקסים: $actuallyIndexed');
        debugPrint('   ⏭️ דולגו: $skipped');
        debugPrint('   ❌ שגיאות: $errors');

        debugPrint('💾 שומר אינדקס סופי (final commit)...');
        final index = await _tantivyDataProvider.engine;
        await index.commit();
        saveIndexedBooks();
        debugPrint('✅ אינדקס נשמר בהצלחה!');
      }
    } finally {
      _activeIsolateService = null;
      if (!identical(isolateService, _isolateService)) {
        await isolateService.dispose();
      }
      _tantivyDataProvider.isIndexing.value = false;
    }
    return !cancelled;
  }

  Future<void> _resetExistingIndexBeforeFullReindex() async {
    final indexPath = await AppPaths.getIndexPath();
    debugPrint('🧹 זוהתה בנייה מחדש מלאה - מוחק אינדקס ישן לפני אינדוקס');
    await _tantivyDataProvider.resetIndex(indexPath);
    await _tantivyDataProvider.reopenIndex();
  }

  Future<void> _indexTextBook(
    TextBook book,
    IndexingIsolateService isolateService, {
    required Map<String, int> catalogueOrderByBookKey,
    String? preloadedText,
    void Function()? onActualIndexingStarted,
  }) async {
    final text = await _loadTextBookText(book, preloadedText: preloadedText);
    if (text == null) {
      return;
    }

    final stream = await isolateService.processTextBook(text: text);
    await _consumePreparedDocuments(
      book: book,
      stream: stream,
      isolateService: isolateService,
      catalogueOrderByBookKey: catalogueOrderByBookKey,
      onActualIndexingStarted: onActualIndexingStarted,
    );
  }

  Future<void> _indexPdfBook(
    PdfBook book,
    IndexingIsolateService isolateService, {
    required Map<String, int> catalogueOrderByBookKey,
    void Function()? onActualIndexingStarted,
  }) async {
    final stream = await isolateService.processPdfBook(
      title: book.title,
      path: book.path,
    );
    await _consumePreparedDocuments(
      book: book,
      stream: stream,
      isolateService: isolateService,
      catalogueOrderByBookKey: catalogueOrderByBookKey,
      onActualIndexingStarted: onActualIndexingStarted,
    );
  }

  Future<String?> _loadTextBookText(
    TextBook book, {
    String? preloadedText,
  }) async {
    String? text = preloadedText;

    if ((text == null || text.isEmpty) && book.categoryId != null) {
      debugPrint(
          '   🔍 מנסה לקרוא מ-DB: ${book.title} (categoryId: ${book.categoryId})');
      text = await SqliteDataProvider.instance.getBookTextFromDb(
        book.title,
        book.categoryId,
        book.fileType ?? 'txt',
      );
    }

    if (text == null || text.isEmpty) {
      debugPrint('   🔍 מנסה לקרוא דרך LibraryProvider: ${book.title}');
      text = await book.text;
    }

    if (text.isEmpty) {
      debugPrint(
          '⚠️ ספר ריק: ${book.title} (categoryId: ${book.categoryId}) - מדלג');
      return null;
    }

    return text;
  }

  Future<void> _consumePreparedDocuments({
    required Book book,
    required Stream<IndexingIsolateUpdate> stream,
    required IndexingIsolateService isolateService,
    required Map<String, int> catalogueOrderByBookKey,
    void Function()? onActualIndexingStarted,
  }) async {
    try {
      await for (final update in stream) {
        if (!_tantivyDataProvider.isIndexing.value) {
          await isolateService.cancelActiveWork();
          return;
        }

        if (update is! IndexingBatchReady) {
          continue;
        }

        await _writePreparedBatch(
          book,
          update.documents,
          catalogueOrderByBookKey: catalogueOrderByBookKey,
          onActualIndexingStarted: onActualIndexingStarted,
        );
        await update.acknowledge();
      }
    } catch (e) {
      await isolateService.cancelActiveWork();
      rethrow;
    }
  }

  Future<void> _writePreparedBatch(
    Book book,
    List<PreparedIndexDocument> documents, {
    required Map<String, int> catalogueOrderByBookKey,
    void Function()? onActualIndexingStarted,
  }) async {
    if (documents.isEmpty) {
      return;
    }

    onActualIndexingStarted?.call();

    final index = await _tantivyDataProvider.engine;
    final title = book.title;
    final topics = _buildTopicsPath(book);
    final isPdf = book is PdfBook;
    final filePath = isPdf ? book.path : '';
    final catalogueOrder =
        catalogueOrderByBookKey[catalogueOrderKey(book)] ?? 0xFFFFFFFF;

    // שימוש ב-upsertDocument במקום addDocument כדי לעדכן מסמכים קיימים
    for (final document in documents) {
      if (!_tantivyDataProvider.isIndexing.value) {
        return;
      }

      await index.upsertDocument(
        id: buildCatalogueDocumentId(
          catalogueOrder: catalogueOrder,
          ordinal: document.ordinal,
        ),
        title: title,
        reference: document.reference,
        topics: topics,
        text: document.text,
        segment: BigInt.from(document.segment),
        isPdf: isPdf,
        filePath: filePath,
      );
    }
  }

  @visibleForTesting
  static BigInt buildCatalogueDocumentId({
    required int catalogueOrder,
    required int ordinal,
  }) {
    return (BigInt.from(catalogueOrder + 1) << 32) + BigInt.from(ordinal + 1);
  }

  @visibleForTesting
  static String buildCatalogueOrderSignature(Library library) {
    final orderedKeys = SearchCatalogueOrderHelper.buildOrderedKeys(
      library,
      keyOf: (book) => catalogueOrderKey(book as Book),
    );
    return sha1.convert(utf8.encode(orderedKeys.join('\n'))).toString();
  }

  @visibleForTesting
  static String catalogueOrderKey(Book book) {
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

  String _buildTopicsPath(Book book) {
    final topics = "/${book.topics.replaceAll(', ', '/')}";
    // שימוש ב-catalogueOrderKey במקום title כדי להבטיח ייחודיות
    // זה מאפשר הבחנה בין ספרים עם אותו שם
    final bookKey = catalogueOrderKey(book);
    return '$topics/$bookKey';
  }

  /// Cancels the ongoing indexing process.
  void cancelIndexing() {
    _tantivyDataProvider.isIndexing.value = false;
    unawaited(_activeIsolateService?.cancelActiveWork());
  }

  /// Persists the list of indexed books to disk.
  void saveIndexedBooks() {
    _tantivyDataProvider.saveBooksDoneToDisk();
  }

  /// Clears the index and resets the list of indexed books.
  Future<void> clearIndex() async {
    await _tantivyDataProvider.clear();
  }

  /// Gets the list of books that have already been indexed.
  List<String> getIndexedBooks() {
    return List<String>.from(_tantivyDataProvider.booksDone);
  }

  /// Checks if indexing is currently in progress.
  bool isIndexing() {
    return _tantivyDataProvider.isIndexing.value;
  }
}
