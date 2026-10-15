import 'package:sui/sui.dart';

/// Iterate distinct WAL coins, following every advertised page.
///
/// Empty intermediate pages are allowed. An absent or repeated cursor while
/// [PaginatedCoins.hasNextPage] is true is an invalid response: fail instead of
/// silently reporting a partial balance or requesting the same page forever.
Stream<CoinStruct> walCoins(
  SuiClient client,
  String owner,
  String walType,
) async* {
  String? cursor;
  final seenCursors = <String>{};
  final seenCoins = <String>{};
  while (true) {
    final page = await client.getCoins(
      owner,
      coinType: walType,
      cursor: cursor,
    );
    for (final coin in page.data) {
      if (seenCoins.add(coin.coinObjectId)) yield coin;
    }
    if (!page.hasNextPage) return;

    final nextCursor = page.nextCursor;
    if (nextCursor == null ||
        nextCursor.isEmpty ||
        !seenCursors.add(nextCursor)) {
      throw StateError('WAL coin pagination did not provide a new cursor');
    }
    cursor = nextCursor;
  }
}
