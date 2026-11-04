// Web 端 HTTP 适配器 —— **原生 / VM 桩**（`DA280`，r664）。
//
// 恒为 `null`：调用方据此继续走 `IOHttpClientAdapter` + 证书回调，
// 行为与改动前**逐字一致**（这也是本改动的反向验证判据）。
import 'package:dio/dio.dart';

HttpClientAdapter? createWebHttpClientAdapter() => null;
