import 'dart:convert';
import 'package:bcrypt/bcrypt.dart';
import 'package:crypto/crypto.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'dart:math';

// kanged from https://github.com/DUpdateSystem/UpgradeAll/blob/b2f92c9/core-websdk/src/main/java/net/xzos/upgradeall/core/websdk/api/client_proxy/hubs/CoolApk.kt
class CoolApk extends AppSource {
  CoolApk() {
    name = tr('coolApk');
    hosts = ['www.coolapk.com', 'api2.coolapk.com'];
    allowSubDomains = true;
    naiveStandardVersionDetection = true;
  }

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    print('Debug: Standardizing URL: $url');
    RegExp standardUrlRegEx = RegExp(
        r'^https?://(www\.)?coolapk\.com/apk/[^/]+',
        caseSensitive: false);
    var match = standardUrlRegEx.firstMatch(url);
    if (match == null) {
      print('Debug: Invalid URL for CoolApk: $url');
      throw InvalidURLError(name);
    }
    String standardizedUrl = match.group(0)!;
    print('Debug: Standardized URL: $standardizedUrl');
    return standardizedUrl;
  }

  @override
  Future<String?> tryInferringAppId(String standardUrl,
      {Map<String, dynamic> additionalSettings = const {}}) async {
    print('Debug: Inferring appId from URL: $standardUrl');
    String appId = Uri.parse(standardUrl).pathSegments.last;
    print('Debug: Inferred appId: $appId');
    return appId;
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
      String standardUrl,
      Map<String, dynamic> additionalSettings,
      ) async {
    String appId = (await tryInferringAppId(standardUrl))!;
    String apiUrl = 'https://api2.coolapk.com';
    print('Debug: Fetching details for appId: $appId');

    // get latest
    var detailUrl = '$apiUrl/v6/apk/detail?id=$appId';
    var headers = await getRequestHeaders(additionalSettings);
    print('Debug: Requesting URL: $detailUrl with headers: $headers');
    var res = await sourceRequest(detailUrl, additionalSettings);

    print('Debug: Response status code: ${res.statusCode}');
    if (res.statusCode != 200) {
      print('Debug: HTTP error: ${res.statusCode} - ${res.body}');
      throw getObtainiumHttpError(res);
    }

    var json = jsonDecode(res.body);
    print('Debug: Parsed JSON: $json');
    if (json['status'] == -2 || json['data'] == null) {
      print('Debug: No releases found or invalid status: ${json['status']}');
      throw NoReleasesError();
    }

    var detail = json['data'];
    String version = detail['apkversionname'].toString();
    String appName = detail['title'].toString();
    String author = detail['developername']?.toString() ?? 'CoolApk';
    String changelog = detail['changelog']?.toString() ?? '';
    int? releaseDate = detail['lastupdate'] != null
        ? (detail['lastupdate'] is int
        ? detail['lastupdate'] * 1000
        : int.parse(detail['lastupdate'].toString()) * 1000)
        : null;
    String aid = detail['id'].toString();

    print('Debug: Version: $version, AppName: $appName, Author: $author, AID: $aid');

    // get apk url
    String apkUrl = await _getLatestApkUrl(apiUrl, appId, aid, version, headers);
    if (apkUrl.isEmpty) {
      print('Debug: No APK URL found for $appId');
      throw NoAPKError();
    }
    print('Debug: APK URL: $apkUrl');

    String apkName = '${appId}_$version.apk';

    return APKDetails(
      version,
      [MapEntry(apkName, apkUrl)],
      AppNames(author, appName),
      releaseDate: releaseDate != null
          ? DateTime.fromMillisecondsSinceEpoch(releaseDate)
          : null,
      changeLog: changelog,
    );
  }

  Future<String> _getLatestApkUrl(String apiUrl, String appId, String aid,
      String version, Map<String, String>? headers) async {
    String url = '$apiUrl/v6/apk/download?pn=$appId&aid=$aid';
    print('Debug: Fetching APK URL: $url');
    var res = await sourceRequest(url, {}, followRedirects: false);
    print('Debug: APK request status code: ${res.statusCode}');
    if (res.statusCode >= 300 && res.statusCode < 400) {
      String location = res.headers['location'] ?? '';
      print('Debug: Redirect location: $location');
      return location;
    }
    print('Debug: No redirect found for APK URL');
    return '';
  }

  @override
  Future<Map<String, String>?> getRequestHeaders(
      Map<String, dynamic> additionalSettings,
      {bool forAPKDownload = false}) async {
    var tokenPair = _getToken();
    print('Debug: Generated tokenPair: $tokenPair');
    // CoolAPK header
    return {
      'User-Agent':
      'Dalvik/2.1.0 (Linux; U; Android 9; MI 8 SE MIUI/9.5.9) (#Build; Xiaomi; MI 8 SE; PKQ1.181121.001; 9) +CoolMarket/12.4.2-2208241-universal',
      'X-App-Id': 'com.coolapk.market',
      'X-Requested-With': 'XMLHttpRequest',
      'X-Sdk-Int': '30',
      'X-App-Mode': 'universal',
      'X-App-Channel': 'coolapk',
      'X-Sdk-Locale': 'zh-CN',
      'X-App-Version': '12.4.2',
      'X-Api-Supported': '2208241',
      'X-App-Code': '2208241',
      'X-Api-Version': '12',
      'X-App-Device': tokenPair['deviceCode']!,
      'X-Dark-Mode': '0',
      'X-App-Token': tokenPair['token']!,
    };
  }

  Map<String, String> _getToken() {
    final rand = Random();

    String randHexString(int n) =>
        List.generate(n, (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0'))
            .join()
            .toUpperCase();

    String randMacAddress() =>
        List.generate(6, (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0'))
            .join(':');

    // 加密算法来自 https://github.com/XiaoMengXinX/FuckCoolapkTokenV2、https://github.com/Coolapk-UWP/Coolapk-UWP
    // device
    String aid = randHexString(16);
    String mac = randMacAddress();
    const manufactor = 'Google';
    const brand = 'Google';
    const model = 'Pixel 5a';
    const buildNumber = 'SQ1D.220105.007';

    // generate deviceCode
    String deviceCode =
    base64.encode('$aid; ; ; $mac; $manufactor; $brand; $model; $buildNumber'.codeUnits);
    print('Debug: DeviceCode: $deviceCode');

    // generate timestamp
    String timeStamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    String base64TimeStamp = base64.encode(timeStamp.codeUnits);
    String md5TimeStamp = md5.convert(timeStamp.codeUnits).toString();
    String md5DeviceCode = md5.convert(deviceCode.codeUnits).toString();
    print('Debug: TimeStamp: $timeStamp, MD5TimeStamp: $md5TimeStamp, MD5DeviceCode: $md5DeviceCode');

    // generate token
    String token =
        'token://com.coolapk.market/dcf01e569c1e3db93a3d0fcf191a622c?$md5TimeStamp\$$md5DeviceCode&com.coolapk.market';
    String base64Token = base64.encode(token.codeUnits);
    String md5Base64Token = md5.convert(base64Token.codeUnits).toString();
    String md5Token = md5.convert(token.codeUnits).toString();
    print('Debug: Token: $token, Base64Token: $base64Token, MD5Base64Token: $md5Base64Token');

    // generate salt and hash
    String bcryptSalt = '\$2a\$10\$${base64TimeStamp.substring(0, 14)}/${md5Token.substring(0, 6)}u';
    String bcryptResult = BCrypt.hashpw(md5Base64Token, bcryptSalt);
    String reBcryptResult = bcryptResult.replaceRange(0, 3, '\$2y');
    String finalToken = 'v2${base64.encode(reBcryptResult.codeUnits)}';
    print('Debug: BCryptSalt: $bcryptSalt, BCryptResult: $bcryptResult, FinalToken: $finalToken');

    return {'deviceCode': deviceCode, 'token': finalToken};
  }
}