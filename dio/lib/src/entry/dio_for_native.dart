import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:intl/intl.dart';

import '../adapter.dart';
import '../cancel_token.dart';
import '../response.dart';
import '../dio.dart';
import '../headers.dart';
import '../options.dart';
import '../dio_error.dart';
import '../adapters/io_adapter.dart';

Dio createDio([BaseOptions options])=>DioForNative(options);

class DioForNative with DioMixin implements Dio {
  /// Create Dio instance with default [Options].
  /// It's mostly just one Dio instance in your application.
  DioForNative([BaseOptions options]) {
    if (options == null) {
      options = BaseOptions();
    }
    this.options = options;
    this.httpClientAdapter=DefaultHttpClientAdapter();
  }

  ///  Download the file and save it in local. The default http method is "GET",
  ///  you can custom it by [Options.method].
  ///
  ///  [urlPath]: The file url.
  ///
  ///  [savePath]: The path to save the downloading file later. it can be a String or
  ///  a callback:
  ///  1. A path with String type, eg "xs.jpg"
  ///  2. A callback `String Function(HttpHeaders responseHeaders)`; for example:
  ///  ```dart
  ///   await dio.download(url,(Headers responseHeaders){
  ///      ...
  ///      return "...";
  ///    });
  ///  ```
  ///
  ///  [onReceiveProgress]: The callback to listen downloading progress.
  ///  please refer to [ProgressCallback].
  ///
  /// [deleteOnError] Whether delete the file when error occurs. The default value is [true].
  ///
  ///  [lengthHeader] : The real size of original file (not compressed).
  ///  When file is compressed:
  ///  1. If this value is 'content-length', the `total` argument of `onProgress` will be -1
  ///  2. If this value is not 'content-length', maybe a custom header indicates the original
  ///  file size , the `total` argument of `onProgress` will be this header value.
  ///
  ///  you can also disable the compression by specifying the 'accept-encoding' header value as '*'
  ///  to assure the value of `total` argument of `onProgress` is not -1. for example:
  ///
  ///     await dio.download(url, "./example/flutter.svg",
  ///     options: Options(headers: {HttpHeaders.acceptEncodingHeader: "*"}),  // disable gzip
  ///     onProgress: (received, total) {
  ///       if (total != -1) {
  ///        print((received / total * 100).toStringAsFixed(0) + "%");
  ///       }
  ///     });

  Future<Response> download(
    String urlPath,
    savePath, {
    ProgressCallback onReceiveProgress,
    Map<String, dynamic> queryParameters,
    CancelToken cancelToken,
    bool deleteOnError = true,
    String lengthHeader = Headers.contentLengthHeader,
    data,
    Options options,
  }) async {
    // We set the `responseType` to [ResponseType.STREAM] to retrieve the
    // response stream.
    if (options != null) {
      options.method = options.method ?? "GET";
    } else {
      options = checkOptions("GET", options);
    }

    // Create HEAD request to get last modified date
    Response headResponse;
    try {
      headResponse = await head(
        urlPath,
        data: data,
        options: Options(method: 'HEAD', ),
        queryParameters: queryParameters,
      );
    } on DioError catch (e) {
      print(e.message);
      print(e.response);
      if (e.type == DioErrorType.RESPONSE) {
        if (e.response.request.receiveDataWhenStatusError) {
          var res = await transformer.transformResponse(
            e.response.request..responseType = ResponseType.json,
            e.response.data,
          );
          e.response.data = res;
        } else {
          e.response.data = null;
        }
      }
      rethrow;
    } catch (e) {
      rethrow;
    }

    // Specifically pass "en" as locale as we expect HTTP response to be English of course
    // Otherwise causes issues if "en" is not defined as supported locale
    DateFormat format = DateFormat('EEE, dd MMM yyyy hh:mm:ss vvvv', 'en');
    var lastEdited = format.parse(headResponse.headers['last-modified'].first);

    var tempDir = Directory.systemTemp;
    var tempFilename = '${tempDir.path}/${savePath.toString().split('/').last}.${lastEdited.millisecondsSinceEpoch}';

    // Check if temp file exists
    var tempFile = File(tempFilename);
    var initialSize = 0;

    if (tempFile.existsSync()) {
      initialSize = tempFile.lengthSync();
      options.headers['Range'] = 'bytes=$initialSize-';
    }

    // Receive data with stream.
    options.responseType = ResponseType.stream;
    Response<ResponseBody> response;
    try {
      response = await request<ResponseBody>(
        urlPath,
        data: data,
        options: options,
        queryParameters: queryParameters,
        cancelToken: cancelToken ?? CancelToken(),
      );
    } on DioError catch (e) {
      if (e.type == DioErrorType.RESPONSE) {
        if (e.response.request.receiveDataWhenStatusError) {
          var res = await transformer.transformResponse(
            e.response.request..responseType = ResponseType.json,
            e.response.data,
          );
          e.response.data = res;
        } else {
          e.response.data = null;
        }
      }
      rethrow;
    } catch (e) {
      rethrow;
    }

    response.headers = Headers.fromMap(response.data.headers);
//    File file;
//    if (savePath is Function) {
//      assert(savePath is String Function(Headers),
//          "savePath callback type must be `String Function(HttpHeaders)`");
//      file = File(savePath(response.headers));
//    } else {
//      file = File(savePath.toString());
//    }

    // Shouldn't call file.writeAsBytesSync(list, flush: flush),
    // because it can write all bytes by once. Consider that the
    // file with a very big size(up 1G), it will be expensive in memory.
    var raf = tempFile.openSync(mode: FileMode.append);

    //Create a Completer to notify the success/error state.
    Completer completer = Completer<Response>();
    Future future = completer.future;
    int received = 0;

    // Stream<Uint8List>
    Stream<Uint8List> stream = response.data.stream;
    bool compressed = false;
    int total = 0;
    String contentEncoding = response.headers.value(Headers.contentEncodingHeader);
    if (contentEncoding != null) {
      compressed = ["gzip", 'deflate', 'compress'].contains(contentEncoding);
    }
    if (lengthHeader == Headers.contentLengthHeader && compressed) {
      total = -1;
    } else {
      total = int.parse(response.headers.value(lengthHeader) ?? "-1");
    }

    StreamSubscription subscription;
    Future asyncWrite;
    bool closed = false;
    _closeAndDelete() async {
      if (!closed) {
        closed = true;
        await asyncWrite;
        await raf.close();
        if (deleteOnError) await tempFile.delete();
      }
    }

    subscription = stream.listen(
      (data) {
        subscription.pause();
        // Write file asynchronously
        asyncWrite = raf.writeFrom(data).then((_raf) {
          // Notify progress
          received += data.length;
          if (onReceiveProgress != null) {
            onReceiveProgress(received + initialSize, total + initialSize);
          }
          raf = _raf;
          if (cancelToken == null || !cancelToken.isCancelled) {
            subscription.resume();
          }
        }).catchError((err) async {
          try {
            await subscription.cancel();
          } finally {
            completer.completeError(assureDioError(err));
          }
        });
      },
      onDone: () async {
        try {
          await asyncWrite;
          closed=true;
          await raf.close();
          tempFile.copySync(savePath);
          tempFile.deleteSync();
          completer.complete(response);
        } catch (e) {
          completer.completeError(assureDioError(e));
        }
      },
      onError: (e) async {
        try {
          await _closeAndDelete();
        } finally {
          completer.completeError(assureDioError(e));
        }
      },
      cancelOnError: true,
    );
    // ignore: unawaited_futures
    cancelToken?.whenCancel?.then((_) async {
      await subscription.cancel();
      await _closeAndDelete();
    });

    if (response.request.receiveTimeout > 0) {
      future = future
          .timeout(Duration(milliseconds: response.request.receiveTimeout))
          .catchError((err) async {
        await subscription.cancel();
        await _closeAndDelete();
        throw DioError(
          request: response.request,
          error: "Receiving data timeout[${response.request.receiveTimeout}ms]",
          type: DioErrorType.RECEIVE_TIMEOUT,
        );
      });
    }
    return listenCancelForAsyncTask(cancelToken, future);
  }

  ///  Download the file and save it in local. The default http method is "GET",
  ///  you can custom it by [Options.method].
  ///
  ///  [uri]: The file url.
  ///
  ///  [savePath]: The path to save the downloading file later. it can be a String or
  ///  a callback:
  ///  1. A path with String type, eg "xs.jpg"
  ///  2. A callback `String Function(HttpHeaders responseHeaders)`; for example:
  ///  ```dart
  ///   await dio.downloadUri(uri,(Headers responseHeaders){
  ///      ...
  ///      return "...";
  ///    });
  ///  ```
  ///
  ///  [onReceiveProgress]: The callback to listen downloading progress.
  ///  please refer to [ProgressCallback].
  ///
  ///  [lengthHeader] : The real size of original file (not compressed).
  ///  When file is compressed:
  ///  1. If this value is 'content-length', the `total` argument of `onProgress` will be -1
  ///  2. If this value is not 'content-length', maybe a custom header indicates the original
  ///  file size , the `total` argument of `onProgress` will be this header value.
  ///
  ///  you can also disable the compression by specifying the 'accept-encoding' header value as '*'
  ///  to assure the value of `total` argument of `onProgress` is not -1. for example:
  ///
  ///     await dio.downloadUri(uri, "./example/flutter.svg",
  ///     options: Options(headers: {HttpHeaders.acceptEncodingHeader: "*"}),  // disable gzip
  ///     onProgress: (received, total) {
  ///       if (total != -1) {
  ///        print((received / total * 100).toStringAsFixed(0) + "%");
  ///       }
  ///     });
  @override
  Future<Response> downloadUri(
    Uri uri,
    savePath, {
    ProgressCallback onReceiveProgress,
    CancelToken cancelToken,
    bool deleteOnError = true,
    lengthHeader = Headers.contentLengthHeader,
    data,
    Options options,
  }) {
    return download(
      uri.toString(),
      savePath,
      onReceiveProgress: onReceiveProgress,
      lengthHeader: lengthHeader,
      deleteOnError: deleteOnError,
      cancelToken: cancelToken,
      data: data,
      options: options,
    );
  }
}
