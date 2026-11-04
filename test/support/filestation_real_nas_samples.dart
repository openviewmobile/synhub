// `SYNO.FileStation.*` 的**真机逐字回包**（普通用户 `demo_user`，DSM 7.2，LAN）。
//
// ## 这些常量为什么存在
// 契约用例最怕"用例跟着代码走" —— 断言写的是我方**猜想**的形状。
// 所以这里放的是**真机原样回包**（只截掉多余的重复项，字段一个没改），
// 由 `test/filestation_real_nas_contract_test.dart` 喂给我方 DTO。
// 形状一旦对不上，用例就红 —— 这才叫"用真机验证"。
//
// 取证方式：只读 GET `entry.cgi`，**不带 maxVersion**（§5.3）。
//
// ignore_for_file: lines_longer_than_80_chars

library;

import 'dart:convert';

/// `/docker` 下**只读**目录（`perm.acl.write == false`）—— M12 只读标识真实样本。
final Map<String, dynamic> realListReadonlyDocker = realJson(
  r'''{"data": {"files": [{"additional": {"owner": {"gid": 100, "group": "users", "uid": 1027, "user": "demo_user"}, "perm": {"acl": {"append": false, "del": true, "exec": true, "read": true, "write": false}, "is_acl_mode": true, "posix": 755}, "real_path": "/volume1/docker/calibre", "size": 356, "time": {"atime": 1789426360, "crtime": 1654313237, "ctime": 1789416000, "mtime": 1789416000}, "type": ""}, "isdir": true, "name": "calibre", "path": "/docker/calibre"}], "offset": 0, "total": 13}, "success": true}''',
);

/// `/home` 下**可写**目录（`perm.acl.write == true`）—— 对照组。
final Map<String, dynamic> realListWriteHome = realJson(
  r'''{"data": {"files": [{"additional": {"owner": {"gid": 100, "group": "users", "uid": 1028, "user": "demo_user"}, "perm": {"acl": {"append": true, "del": true, "exec": true, "read": true, "write": true}, "is_acl_mode": true, "posix": 777}, "real_path": "/volume1/homes/demo_user/Books", "size": 2290, "time": {"atime": 1789977326, "crtime": 1789750535, "ctime": 1789977326, "mtime": 1789977326}, "type": ""}, "isdir": true, "name": "Books", "path": "/home/Books"}], "offset": 0, "total": 10}, "success": true}''',
);

/// `SYNO.FileStation.List / list_share` —— M51 共享文件夹固定入口。
final Map<String, dynamic> realListShare = realJson(
  r'''{"data": {"offset": 0, "shares": [{"additional": {"perm": {"acl": {"append": false, "del": true, "exec": true, "read": true, "write": false}, "acl_enable": true, "adv_right": {"disable_download": false, "disable_list": false, "disable_modify": false}, "is_acl_mode": true, "is_share_readonly": false, "posix": 755, "share_right": "RW"}}, "isdir": true, "name": "docker", "path": "/docker"}, {"additional": {"perm": {"acl": {"append": true, "del": true, "exec": true, "read": true, "write": true}, "acl_enable": true, "adv_right": {"disable_download": false, "disable_list": false, "disable_modify": false}, "is_acl_mode": true, "is_share_readonly": false, "posix": 777, "share_right": "RW"}}, "isdir": true, "name": "home", "path": "/home"}], "total": 2}, "success": true}''',
);

/// `SYNO.FileStation.Sharing / list` v3 —— M36 分享链接管理（本机 0 条）。
final Map<String, dynamic> realSharingList = realJson(
  r'''{"data": {"links": [], "offset": 0, "total": 0}, "success": true}''',
);

/// `SYNO.FileStation.BackgroundTask / list` v3 —— M58 后台任务（本机 0 条）。
final Map<String, dynamic> realBackgroundTaskList = realJson(
  r'''{"data": {"offset": 0, "tasks": [], "total": 0}, "success": true}''',
);

/// `SYNO.FileStation.Favorite / list` v2 —— M50 收藏夹（本机 0 条）。
final Map<String, dynamic> realFavoriteList = realJson(
  r'''{"data": {"favorites": [], "offset": 0, "total": 0}, "success": true}''',
);

/// 便捷解析。
Map<String, dynamic> realJson(String s) =>
    Map<String, dynamic>.from(jsonDecode(s) as Map);
