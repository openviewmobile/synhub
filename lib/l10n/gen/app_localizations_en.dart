// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppTextEn extends AppText {
  AppTextEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'SynHub';

  @override
  String get navChat => 'Chat';

  @override
  String get navFiles => 'Files';

  @override
  String get navPhotos => 'Photos';

  @override
  String get navWorkspace => 'Workspace';

  @override
  String get navMe => 'Me';

  @override
  String get wsFiles => 'Files';

  @override
  String get wsNotes => 'Notes';

  @override
  String get wsPhotos => 'Photos';

  @override
  String get wsContacts => 'Contacts';

  @override
  String get wsCalendar => 'Calendar';

  @override
  String get wsTasks => 'Background tasks';

  @override
  String wsTasksRunning(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n running',
      one: '1 running',
    );
    return '$_temp0';
  }

  @override
  String get wsTasksNone => 'No tasks';

  @override
  String get wsTasksDone => 'All done';

  @override
  String get wsSearchFiles => 'Search files';

  @override
  String get wsSearchFilesHint => 'Search permitted folders by file name';

  @override
  String get wsSearchFilesShort => 'By file name';

  @override
  String wsHiddenCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n unused modules hidden',
      one: '1 unused module hidden',
    );
    return '$_temp0';
  }

  @override
  String get wsShowAll => 'Show all';

  @override
  String get wsSearchHint => 'Search modules; Enter searches files';

  @override
  String get wsNoMatch => 'No matching module';

  @override
  String wsSearchInFiles(String q) {
    return 'Search \"$q\" in files';
  }

  @override
  String get meAccount => 'Account';

  @override
  String get meApp => 'App';

  @override
  String get meNotLoggedIn => 'Not signed in';

  @override
  String get meProfile => 'Profile';

  @override
  String get meProfileHint => 'Nickname / avatar';

  @override
  String get meNotifications => 'Notifications & quiet hours';

  @override
  String get meNotificationsHint => 'Quiet hours, timezone';

  @override
  String get meE2ee => 'End-to-end encryption';

  @override
  String get meE2eeHint => 'Keys and decrypt attempts for private chats';

  @override
  String get meSettings => 'Settings';

  @override
  String get meSettingsHint => 'Theme / fonts / messages / storage';

  @override
  String get meCertificates => 'Trusted certificates';

  @override
  String get meCertificatesHint =>
      'Manage self-signed certificate fingerprints';

  @override
  String get meArchives => 'Archived channels';

  @override
  String get meArchivesHint => 'Archived encrypted conversations';

  @override
  String get setTitle => 'Settings';

  @override
  String get setSectionAppearance => 'Appearance';

  @override
  String get setSectionMedia => 'Messages & media';

  @override
  String get setSectionSecurity => 'Security & background';

  @override
  String get setSectionPrivacy => 'Privacy & data';

  @override
  String get setSectionAbout => 'About';

  @override
  String get setTheme => 'Theme';

  @override
  String get themeSystem => 'Follow system';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get setDynamicColor => 'Dynamic color';

  @override
  String get setDynamicColorHint =>
      'Follow the system wallpaper (Material You); off uses the brand blue';

  @override
  String setDynamicColorSource(String source, String hex) {
    return 'Colour taken from wallpaper: $source ($hex)';
  }

  @override
  String get setDynamicColorUnavailable =>
      'This device exposes no wallpaper colour (no Material You); brand blue for now';

  @override
  String get setChatGrid => 'Chat grid backdrop';

  @override
  String get setChatGridHint =>
      'Cockpit HUD ambience; off gives a flat background';

  @override
  String get setPerfMode => 'Performance mode';

  @override
  String get setPerfModeHint =>
      'Turn off expensive effects like blur to save battery on low-end devices';

  @override
  String get setReducedMotion => 'Reduce motion';

  @override
  String get setReducedMotionHint =>
      'All transitions finish instantly (honors the system \"Remove animations\" setting)';

  @override
  String setAutoHint(String on) {
    return 'Auto (device default: $on)';
  }

  @override
  String setManualHint(String on, String dflt) {
    return 'Set manually to $on (device default: $dflt)';
  }

  @override
  String get setOn => 'on';

  @override
  String get setOff => 'off';

  @override
  String get setRestoreAuto => 'Restore auto';

  @override
  String setDeviceTier(String tier) {
    return 'Device performance tier: $tier';
  }

  @override
  String setDeviceTierSpec(String spec, String blur, String motion) {
    return '$spec\nAuto: blur $blur · motion $motion';
  }

  @override
  String get setMotionFull => 'full';

  @override
  String get setMotionReduced => 'reduced';

  @override
  String get setLanguage => 'Language';

  @override
  String get setLanguageHint => 'Interface language (system / 简体中文 / English)';

  @override
  String get langSystem => 'Follow system';

  @override
  String get langZh => '简体中文';

  @override
  String get langEn => 'English';

  @override
  String get setImageQuality => 'Image quality for sending';

  @override
  String get qualityOriginal => 'Original';

  @override
  String get qualityOriginalHint =>
      'No re-encoding; keeps the original quality';

  @override
  String get qualityStandard => 'Standard';

  @override
  String get qualityStandardHint => 'Compressed to 1080p before sending';

  @override
  String get setSendByEnter => 'Send with Enter';

  @override
  String get setSendByEnterOn => 'Enter sends immediately';

  @override
  String get setSendByEnterOff =>
      'Enter inserts a newline; use the send button';

  @override
  String get setCacheLimit => 'Cache limit';

  @override
  String get cacheUnlimited => 'Unlimited';

  @override
  String get setClearCache => 'Clear downloaded files';

  @override
  String get cacheCounting => 'Counting…';

  @override
  String get cacheCountFailed => 'Failed to count';

  @override
  String get cacheNone => 'No cache';

  @override
  String cacheUsed(String size, int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n files',
      one: '1 file',
    );
    return '$size used · $_temp0';
  }

  @override
  String get dialogClearCacheTitle => 'Clear cache';

  @override
  String get dialogClearCacheBody =>
      'This deletes cached attachments, thumbnails and previews (video first frames, Office images and template thumbnails, PDF render caches); they will be downloaded or rebuilt next time. Content saved offline, online subtitles, chat history and settings are kept.';

  @override
  String cacheCleared(String size) {
    return 'Cleared $size';
  }

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionClear => 'Clear';

  @override
  String get setPostPreview => 'Preload messages when a notification arrives';

  @override
  String get setSort => 'Sorting of channels and conversations';

  @override
  String get setCertificates => 'Trusted certificates';

  @override
  String get setCertificatesHint =>
      'View or delete trusted server certificates';

  @override
  String get setNasManageHint =>
      'View saved NAS and accounts on this device, and switch the active connection';

  @override
  String get setNotifications => 'Notifications & background';

  @override
  String get setForegroundRunning => 'Foreground service running';

  @override
  String get setForegroundStopped => 'Foreground service not running';

  @override
  String get setSnooze => 'Quiet hours';

  @override
  String get setE2ee => 'End-to-end encryption';

  @override
  String get setOnDeviceAi => 'AI service';

  @override
  String get setOnDeviceAiHint =>
      'Cloud or on-device models: API key and model selection';

  @override
  String get setUsageAnalytics => 'Usage analytics';

  @override
  String get setUsageAnalyticsHint =>
      'Local usage log and habit insights (export or clear)';

  @override
  String get setVersion => 'Version';

  @override
  String get setSrcDirect => 'Direct';

  @override
  String get setSrcLan => 'LAN';

  @override
  String get setSrcDdns => 'DDNS';

  @override
  String get setSrcExternal => 'External';

  @override
  String get setSrcFqdn => 'Domain name';

  @override
  String get setSrcSmartDns => 'SmartDNS';

  @override
  String get setSrcRelay => 'Relay';

  @override
  String get setSrcOther => 'Other method';

  @override
  String get setSrcUnknown => 'Connection method unknown';

  @override
  String get setServer => 'Server';

  @override
  String get setMyAccount => 'My account';

  @override
  String get setAdminSuffix => ' (administrator)';

  @override
  String get setRoleAdmin => 'Administrator';

  @override
  String get setRoleMember => 'Standard account';

  @override
  String get setDiagnostics => 'Connection diagnostics';

  @override
  String get setNotConnected => 'Not connected';

  @override
  String get setAppLock => 'App lock';

  @override
  String get setAppLockLoading => 'Loading…';

  @override
  String get setGapProfileEntry => 'Account info';

  @override
  String get setGapProfileEntryHint =>
      'Nickname / email / account type (read-only)';

  @override
  String get setGapProfileTitle => 'Account info';

  @override
  String get setGapProfileNickname => 'Nickname';

  @override
  String get setGapProfileEmail => 'Email';

  @override
  String get setGapProfileOtherEmails => 'Other emails';

  @override
  String get setGapProfileAccountType => 'Account type';

  @override
  String get setGapProfileGuest => 'Guest account';

  @override
  String get setGapProfileMember => 'Regular account';

  @override
  String get setGapProfileUnset => 'Not set';

  @override
  String get setGapProfileNoEmail => 'No email bound';

  @override
  String get setGapProfileLoadFailed => 'Failed to load profile';

  @override
  String get setGapProfileRetry => 'Retry';

  @override
  String get setGapProfileNotLoggedIn =>
      'Not signed in; cannot read your profile';

  @override
  String get setGapProfileGuestHint =>
      'You are signed in as a guest; available features depend on the administrator\'s permissions.';

  @override
  String get fsGap5ThumbInfoSection => 'Photo metadata';

  @override
  String get fsGap5ThumbInfoEmpty =>
      'This file contains no EXIF / IPTC / XMP metadata';

  @override
  String get fsGap5ThumbInfoLoading => 'Reading metadata…';

  @override
  String get fsGap5ThumbInfoExif => 'EXIF';

  @override
  String get fsGap5ThumbInfoIptc => 'IPTC';

  @override
  String get fsGap5ThumbInfoXmp => 'XMP';

  @override
  String get fsGap5ThumbInfoCamera => 'Camera model';

  @override
  String get fsGap5ThumbInfoLens => 'Lens';

  @override
  String get fsGap5ThumbInfoTakenAt => 'Taken at';

  @override
  String get fsGap5ThumbInfoAperture => 'Aperture';

  @override
  String get fsGap5ThumbInfoIso => 'ISO';

  @override
  String get fsGap5ThumbInfoExposure => 'Exposure time';

  @override
  String get fsGap5ThumbInfoFocalLength => 'Focal length';

  @override
  String get fsGap5ThumbInfoGps => 'GPS location';

  @override
  String get fsGap5ThumbInfoSoftware => 'Software';

  @override
  String get fsGap5ThumbInfoMake => 'Camera make';

  @override
  String get fsGap5ThumbInfoOrientation => 'Orientation';

  @override
  String setAppLockOn(int n) {
    return 'On: $n-digit passcode';
  }

  @override
  String get setAppLockOff => 'Require a passcode each time the app opens';

  @override
  String unlockReason(String label, String app) {
    return 'Unlock $app with $label';
  }

  @override
  String keepAliveTitle(String app) {
    return '$app';
  }

  @override
  String get keepAliveText => 'Keeping the connection alive';

  @override
  String get previewModeClose => 'Off';

  @override
  String get previewModeWifi => 'Only on Wi-Fi';

  @override
  String get previewModeWifiAndData => 'On Wi-Fi or mobile data';

  @override
  String get sortByName => 'Name';

  @override
  String get sortByTime => 'Latest message';

  @override
  String get sortTargetFavorite => 'Starred';

  @override
  String get sortTargetChannel => 'Channels';

  @override
  String get sortTargetConversation => 'Direct messages';

  @override
  String get sortTargetChatbot => 'Bots';

  @override
  String sortSummaryMixed(
    String favorite,
    String channel,
    String conversation,
    String chatbot,
  ) {
    return 'Starred $favorite · Channels $channel · Direct messages $conversation · Bots $chatbot';
  }

  @override
  String get notifForegroundSection => 'Foreground service';

  @override
  String get notifForegroundService => 'Persistent foreground service';

  @override
  String get notifForegroundRunningHint =>
      'Running (the connection stays alive in the background)';

  @override
  String get notifForegroundStoppedHint =>
      'Not running (messages arrive only while the app is in the foreground)';

  @override
  String get notifBootSection => 'Startup';

  @override
  String get notifBoot => 'Start at boot';

  @override
  String get notifBootHint =>
      'Starts the persistent service at boot (the Dart engine reconnects only after you open the app)';

  @override
  String get notifBootOpenApp => 'Open the app at boot';

  @override
  String get notifBootOpenAppHint =>
      'Some systems block launching a UI at boot; the service still runs if this fails';

  @override
  String get notifSelfTestSection => 'Notification self-test';

  @override
  String get notifSendTest => 'Send a test notification';

  @override
  String get notifSendTestHint =>
      'Verifies notification permission and the Reply / Mark read / Snooze buttons';

  @override
  String get notifSendTestHintWindows =>
      'Verifies notification permission and identity (Reply / Mark read / Snooze are not available on Windows)';

  @override
  String get notifTestBody => 'This is a test notification 🙂';

  @override
  String get notifTestSent => 'Sent (check the notification shade)';

  @override
  String get notifTestFailed =>
      'Could not send: no native implementation on this platform, or notification permission was denied';

  @override
  String get notifClearAll => 'Clear all notifications';

  @override
  String get notifSnooze => 'Quiet hours';

  @override
  String get notifLinkOk =>
      'Link is healthy: the background service is running and the live channel is connected.';

  @override
  String get notifLinkOkChannelOnly =>
      'Link is healthy: the live channel is connected (this platform has no resident background service).';

  @override
  String get notifLinkWarnChannelOnly =>
      'Link is not ready: the live channel is not connected. Check your network.';

  @override
  String get notifLinkWarn =>
      'Link is not fully ready: check the background service and your network.';

  @override
  String get notifLinkSection => 'Background link';

  @override
  String get notifRealtimeChannel => 'Realtime channel';

  @override
  String get notifNativeService => 'Native background service';

  @override
  String get snoozeDisable => 'Turn off quiet hours';

  @override
  String get snooze20Minutes => '20 minutes';

  @override
  String get snooze1Hour => '1 hour';

  @override
  String get snooze2Hours => '2 hours';

  @override
  String get snooze4Hours => '4 hours';

  @override
  String get snooze8Hours => '8 hours';

  @override
  String get snooze24Hours => '24 hours';

  @override
  String snoozeSubtitleSchedule(String start, String end) {
    return 'Scheduled $start–$end';
  }

  @override
  String snoozeSubtitleScheduleManual(String start, String end, String left) {
    return 'Scheduled $start–$end, $left left on the manual timer';
  }

  @override
  String snoozeSubtitleRemaining(String left) {
    return '$left left';
  }

  @override
  String get snoozeStatusOff => 'Off';

  @override
  String get snoozeDisabledToast => 'Quiet hours turned off';

  @override
  String snoozeEnabledToast(String label) {
    return 'Quiet hours on: $label';
  }

  @override
  String get snoozeScheduleTitle => 'Scheduled quiet hours';

  @override
  String snoozeScheduleOn(String start, String end) {
    return 'On $start–$end';
  }

  @override
  String get snoozeTimezone => 'Time zone';

  @override
  String get snoozeTimezoneUnset =>
      'Device time zone (the server did not send timezoneUTC)';

  @override
  String get snoozeTimezoneDevice => 'Device time zone';

  @override
  String get snoozeFootnote =>
      'While quiet hours are active, new-message notifications are suppressed (messages are still received and stored). The setting lives on the server, so it carries over to other devices.';

  @override
  String get snoozeScheduleSameTime => 'The start and end times must differ';

  @override
  String get snoozeScheduleHint =>
      'No notifications during this window (crossing midnight is supported)';

  @override
  String get snoozeStartTime => 'Start time';

  @override
  String get snoozeEndTime => 'End time';

  @override
  String get actionSave => 'Save';

  @override
  String get actionSaved => 'Saved';

  @override
  String actionSaveFailed(String error) {
    return 'Could not save: $error';
  }

  @override
  String actionSetFailed(String error) {
    return 'Could not set: $error';
  }

  @override
  String get actionOk => 'OK';

  @override
  String get actionContinue => 'Continue';

  @override
  String get profileEditNotConnected => 'Not connected to Chat Server yet';

  @override
  String get profileEditInvalidNickname =>
      'The nickname contains characters that are not allowed';

  @override
  String get profileEditInvalidEmail => 'Invalid email address';

  @override
  String get profileEditFromGallery => 'Choose from library';

  @override
  String get profileEditTakePhoto => 'Take photo';

  @override
  String get profileEditRemoveAvatar => 'Remove avatar';

  @override
  String get profileEditNickname => 'Nickname';

  @override
  String get profileEditEmail => 'Email';

  @override
  String get profileEditDesc => 'Bio';

  @override
  String get profileEditReadonly => 'Read-only (set by the administrator)';

  @override
  String get profileEditDescHint => 'Up to 3 lines, visible to everyone';

  @override
  String profileEditAccountLine(String account, int id) {
    return 'Account: $account  ID: #$id';
  }

  @override
  String get botsTitle => 'Bots';

  @override
  String botsLoadFailed(String error) {
    return 'Could not load: $error';
  }

  @override
  String get botsEmpty => 'No bots available';

  @override
  String get botsKindSynobot => 'System assistant';

  @override
  String get botsKindBroadcast => 'Notification bot';

  @override
  String get botsKindChatbot => 'Chat bot';

  @override
  String get botsOpenFailed => 'Could not open a chat with this bot';

  @override
  String get e2eeDisabledBanner =>
      'End-to-end encryption is turned off on the server: you can still read existing encrypted channels, but creating new encrypted channels will be rejected.';

  @override
  String get e2eeSetupPasscode => 'Set encryption passcode';

  @override
  String get e2eeSetupPasscodeHint =>
      'Generates a key pair; the passcode protects your private key and cannot be recovered if forgotten';

  @override
  String get e2eeUnlock => 'Unlock';

  @override
  String get e2eeUnlockHint =>
      'Enter the passcode to decrypt your private key and send or receive encrypted messages';

  @override
  String get e2eeLock => 'Lock';

  @override
  String get e2eeLockHint =>
      'Clears the private key and channel keys from memory';

  @override
  String get e2eeChangePasscode => 'Change passcode';

  @override
  String get e2eeSyncMembers => 'Sync member status from the server';

  @override
  String get e2eeSyncMembersHint =>
      'Re-fetch the member list and who cannot decrypt messages';

  @override
  String e2eeSyncedChannels(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n encrypted channels',
      one: '1 encrypted channel',
    );
    return 'Synced $_temp0';
  }

  @override
  String get e2eeRenewKey => 'Renew key pair';

  @override
  String get e2eeRenewKeyHint =>
      'Use this if your private key may be exposed: it generates a new key pair and re-seals every encrypted channel key to the new public key';

  @override
  String get e2eeReuploadKeys => 'Re-upload my channel keys';

  @override
  String get e2eeReuploadKeysHint =>
      'Use this after renewing the key pair locally, or if the copy on the server was lost';

  @override
  String get e2eeUploaded => 'Uploaded';

  @override
  String get e2eeUploadFailed => 'Upload failed';

  @override
  String get e2eeResetIdentity =>
      'Clear the encryption identity on this device';

  @override
  String get e2eeResetIdentityHint =>
      'You will lose the ability to decrypt past messages in encrypted channels';

  @override
  String get e2eeChannelsSection => 'Encrypted channels';

  @override
  String get e2eeNoChannels => 'No channels yet';

  @override
  String e2eeBrokenUsers(String names) {
    return '$names cannot decrypt (fixable)';
  }

  @override
  String e2eeConversationNumbered(int id) {
    return 'Conversation #$id';
  }

  @override
  String get e2eeFix => 'Fix';

  @override
  String get e2eeNoneEncrypted => 'No encrypted channels on this server yet';

  @override
  String get e2eeNoneEncryptedHint =>
      'Turn one on in Synology Chat (desktop or mobile app) — this server has none yet';

  @override
  String get e2eeKeyStateReady => 'Channel key ready';

  @override
  String get e2eeKeyStateLocked => 'Locked: enter the passcode to unlock';

  @override
  String get e2eeKeyStateMissing =>
      'Cannot decrypt: the key pair changed, or this key was not sealed for you';

  @override
  String get e2eeKeyStateNotEncrypted => 'Not encrypted';

  @override
  String get e2eeEnabled => 'Encryption enabled';

  @override
  String get e2eeEnterPasscode => 'Enter the encryption passcode';

  @override
  String get e2eeUnlocked => 'Unlocked';

  @override
  String get e2eeUnlockFailed => 'Unlock failed';

  @override
  String get e2eeCurrentPasscode => 'Current passcode';

  @override
  String get e2eeNewPasscode => 'New passcode';

  @override
  String get e2eePasscodeUpdated => 'Passcode updated';

  @override
  String get e2eeChangeFailedOld =>
      'Could not change it: the current passcode is wrong';

  @override
  String get e2eeRenewKeyConfirmTitle => 'Renew the key pair?';

  @override
  String get e2eeRenewKeyConfirmBody =>
      'A new key pair will be generated and every encrypted channel/archive key will be re-sealed to the new public key. Once the old private key is revoked, content sealed only with it can no longer be decrypted; other devices must sync the new keys.\n\nYour existing encrypted channels keep working afterwards.';

  @override
  String get e2eeRenewedOk => 'Key pair renewed and re-registered';

  @override
  String get e2eeRenewFailed =>
      'Renewal failed (wrong passcode, or the server refused)';

  @override
  String get e2eeResetConfirmTitle =>
      'Clear the encryption identity on this device?';

  @override
  String get e2eeResetConfirmBody =>
      'Afterwards you will need to set a passcode again; if nobody can redistribute the keys, past messages in encrypted channels will stay unreadable forever.';

  @override
  String get e2eeResetAction => 'Clear';

  @override
  String get e2eeNoPublicKeys => 'No member public keys found';

  @override
  String e2eeRescueWho(int id) {
    return 'Who should the channel key be re-sealed for? (channel #$id)';
  }

  @override
  String get e2eeRescueBrokenTag => '  ⚠ Cannot decrypt';

  @override
  String get e2eeKeysResent => 'Keys resent';

  @override
  String get e2eeRescueFailed => 'Fix failed';

  @override
  String get e2eePasscode => 'Passcode';

  @override
  String get e2eePasscodeRequired => 'Passcode cannot be empty';

  @override
  String get e2eeStatusOff => 'End-to-end encryption is off';

  @override
  String get e2eeStatusLocked => 'Enabled, currently locked';

  @override
  String get e2eeStatusUnlocked => 'Enabled and unlocked';

  @override
  String e2eePublicKey(String key) {
    return 'My public key: $key';
  }

  @override
  String get e2eeCopyPublicKey => 'Copy public key';

  @override
  String get e2eePublicKeyCopied => 'Public key copied';

  @override
  String e2eeBrokenChannelCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n channels cannot be decrypted',
      one: '1 channel cannot be decrypted',
    );
    return '$_temp0';
  }

  @override
  String get e2eeUndecryptable => '🔒 Cannot decrypt (channel key missing)';

  @override
  String get e2eeEncryptedFile => 'Encrypted file';

  @override
  String get e2eeServerIdentityExists =>
      'An encryption identity already exists on the server; unlock it with the original passcode instead of setting up a new one';

  @override
  String e2eeBadPasscodeOrKey(String error) {
    return 'Wrong passcode, or the private key is corrupted ($error)';
  }

  @override
  String get e2eeWrongOldPasscode => 'The old passcode is wrong';

  @override
  String e2eeRenewKeyFailed(String error) {
    return 'Could not renew the key pair: $error';
  }

  @override
  String get e2eeNoRecipientKey =>
      'The other user has no public key yet, so this cannot be fixed';

  @override
  String get passcodeRepeat => 'Enter it again';

  @override
  String get passcodeMismatch => 'The entries do not match';

  @override
  String get passcodeWrong => 'Wrong passcode';

  @override
  String get passcodeFieldLabel4 => 'Passcode (4 digits)';

  @override
  String get passcodeMust4Digits => 'Must be 4 digits';

  @override
  String get passcodeSetTitle => 'Set app lock passcode';

  @override
  String get passcodeEnterToDisable =>
      'Enter the current passcode to turn it off';

  @override
  String get passcodeEnabledToast => 'App lock enabled';

  @override
  String passcodeEnableBioTitle(String label) {
    return 'Enable $label unlock?';
  }

  @override
  String passcodeEnableBioBody(String app, String label) {
    return 'Once enabled, you can unlock $app with $label instead of typing the 4-digit passcode each time. The passcode still works.';
  }

  @override
  String get passcodeNotNow => 'Not now';

  @override
  String get passcodeEnable => 'Enable';

  @override
  String passcodeUnlockWithLabel(String label) {
    return 'Unlock with $label';
  }

  @override
  String get passcodeBioHint =>
      'Use biometrics to unlock; the passcode always still works';

  @override
  String get passcodeReauthInterval => 'Re-authentication interval';

  @override
  String get passcodeLockNow => 'Lock now';

  @override
  String get passcodeBiometric => 'Biometrics';

  @override
  String get passcodeFace => 'Face';

  @override
  String get passcodeFingerprint => 'Fingerprint';

  @override
  String get passcodeLocked => 'Locked';

  @override
  String get passcodeBiometricFailed =>
      'Biometric authentication failed; enter your passcode';

  @override
  String passcodeEnterDigits(int n) {
    return 'Enter your $n-digit passcode';
  }

  @override
  String passcodeUnlockWith(String label) {
    return 'Unlock with $label';
  }

  @override
  String get notifyNewMessage => 'New message';

  @override
  String get notifyEmptyMessage => '(empty message)';

  @override
  String notifyAttachment(String label) {
    return '[Attachment] $label';
  }

  @override
  String notifyPollOptions(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n options',
      one: '1 option',
    );
    return '[Poll] $_temp0';
  }

  @override
  String get notifyReminderTitle => 'Reminder';

  @override
  String notifyAggTitle(int n) {
    return '$n new messages';
  }

  @override
  String notifyAggTitleChannel(int n, String channel) {
    return '$n new messages | $channel';
  }

  @override
  String get notifyReminderBody =>
      'Hi! Here\'s the reminder you asked for about this message.';

  @override
  String notifyReminderBodyWith(String preview) {
    return 'Hi! Here\'s the reminder you asked for about “$preview”.';
  }

  @override
  String get devTierLow => 'Entry';

  @override
  String get devTierMedium => 'Mid-range';

  @override
  String get devTierHigh => 'High-end';

  @override
  String devCoresCount(int n) {
    return '$n-core';
  }

  @override
  String get devSpecUnknown => 'Unknown';

  @override
  String get errUnknown => 'Unknown error';

  @override
  String get errBadRequest => 'Invalid request';

  @override
  String get errApiNotFound => 'API not found';

  @override
  String get errMethodNotFound => 'Method not found';

  @override
  String get errApiVersionUnsupported => 'API version not supported';

  @override
  String get errNoPermission => 'No permission';

  @override
  String get errSessionTimeout => 'Session timed out, please sign in again';

  @override
  String get errSessionInterrupted => 'Session interrupted';

  @override
  String get errHandleUpload => 'Upload processing failed';

  @override
  String get errProcessRelay => 'Relay processing failed';

  @override
  String get errProcessEntry => 'Entry processing failed';

  @override
  String get errProcessLib => 'Module processing failed';

  @override
  String get errCompoundStop => 'Compound request aborted';

  @override
  String get errCompoundReject => 'Compound request rejected';

  @override
  String get errNoRequiredParam => 'Missing required parameter';

  @override
  String get errNotAllowUpload => 'Upload not allowed';

  @override
  String get errNotAllowDemo => 'This action is not allowed in demo mode';

  @override
  String get errInternal => 'Server internal error';

  @override
  String get errProcessName => 'Process name error';

  @override
  String get errSidNotFound => 'Session not found, please sign in again';

  @override
  String get errRequestParameterInvalid => 'Invalid request parameter';

  @override
  String get errNoMatchLibEntry => 'No matching module entry';

  @override
  String get errNoAppPrivilege => 'No permission for this app';

  @override
  String get errAuthInvalidPassword => 'Wrong account or password';

  @override
  String get errAuthAccountDisabled => 'Account disabled';

  @override
  String get errAuthPermissionDenied => 'Permission denied';

  @override
  String get errAuthOtpRequired => 'Two-factor verification code required';

  @override
  String get errAuthOtpInvalid => 'Wrong verification code';

  @override
  String get errAuthPortalPortInvalid => 'Invalid portal port';

  @override
  String get errAuthOtpEnforced =>
      'This account requires two-factor verification';

  @override
  String get errAuthMaxTries => 'Too many attempts, please try again later';

  @override
  String get errAuthPasswordExpiredCantChange =>
      'Password expired and cannot be changed here';

  @override
  String get errAuthPasswordExpired => 'Password expired, please change it';

  @override
  String get errAuthPasswordMustChange => 'Password must be changed first';

  @override
  String get errAuthAccountLocked => 'Account locked';

  @override
  String get chatErrNoSuchUser => 'No such user (CHAT_ERR_NO_SUCH_USER)';

  @override
  String get chatErrNotInChannel =>
      'Not in this channel (CHAT_ERR_NOT_IN_CHANNEL)';

  @override
  String get chatErrPostNotFound =>
      'Message not found (CHAT_ERR_POST_NOT_FOUND)';

  @override
  String get chatErrChannelNotFound =>
      'Channel not found (CHAT_ERR_CHANNEL_NOT_FOUND)';

  @override
  String get chatErrNoPermission => 'No permission (CHAT_ERR_NO_PERMISSION)';

  @override
  String get chatErrDuplicatedTag => 'Duplicate tag (CHAT_ERR_DUPLICATED_TAG)';

  @override
  String get chatErrInvalidAvatar => 'Invalid avatar (CHAT_ERR_INVALID_AVATAR)';

  @override
  String get chatErrInvalidRecord => 'Invalid record (CHAT_ERR_INVALID_RECORD)';

  @override
  String get chatErrKeyPairNotExist =>
      'Key pair not found (CHAT_ERR_KEY_PAIR_NOT_EXIST)';

  @override
  String get chatErrExceedMaxFileSize =>
      'File exceeds the size limit (CHAT_ERR_EXCEED_MAX_FILE_SIZE)';

  @override
  String get chatErrSendTooFrequently =>
      'Sending too frequently (CHAT_ERR_SEND_TOO_FREQUENTLY)';

  @override
  String get chatErrChannelGlobalHide =>
      'Channel globally hidden (CHAT_ERR_CHANNEL_GLOBAL_HIDE)';

  @override
  String get chatErrServerDbMigrate =>
      'Server database is migrating (CHAT_ERR_SERVER_DB_MIGRATE)';

  @override
  String get chatErrDuplicatedChannelName =>
      'Duplicate channel name (CHAT_ERR_DUPLICATED_CHANNEL_NAME)';

  @override
  String get chatErrChannelKeyNotExist =>
      'Channel key not found (CHAT_ERR_CHANNEL_KEY_NOT_EXIST)';

  @override
  String get chatErrNotAllowEncryption =>
      'Encryption not allowed (CHAT_ERR_NOT_ALLOW_ENCRYPTION)';

  @override
  String get chatErrChannelEncrypted =>
      'Channel already encrypted (CHAT_ERR_CHANNEL_ENCRYPTED)';

  @override
  String get chatErrUserDuplicated =>
      'Duplicate user (CHAT_ERR_USER_DUPLICATED)';

  @override
  String get chatErrUserInvalid => 'Invalid user (CHAT_ERR_USER_INVALID)';

  @override
  String get chatErrAccountTypeInvalid =>
      'Invalid account type (CHAT_ERR_ACCOUNT_TYPE_INVALID)';

  @override
  String get chatErrNotAllowHttp =>
      'HTTP not allowed (CHAT_ERR_NOT_ALLOW_HTTP)';

  @override
  String get chatErrNotAllowGuestLogin =>
      'Guest sign-in not allowed (CHAT_ERR_NOT_ALLOW_GUEST_LOGIN)';

  @override
  String apiUnknownErrorCode(int code) {
    return 'Error code $code';
  }

  @override
  String get apiRequestFailed => 'Request failed';

  @override
  String get apiDownloadFailed => 'Download failed';

  @override
  String get apiEmptyDownload => 'Empty download';

  @override
  String get apiEmptyResponse => 'Empty response';

  @override
  String get apiNonTextResponse => 'Non-text response';

  @override
  String get apiTunnelNotStarted => 'Tunnel not started (tcpPort == 0)';

  @override
  String get apiTunnelRequestFailed => 'Tunnel request failed';

  @override
  String get apiTunnelUploadFailed => 'Tunnel upload failed';

  @override
  String get apiTunnelDownloadFailed => 'Tunnel download failed';

  @override
  String apiResponseNotJsonObject(String what) {
    return '$what: response is not a JSON object';
  }

  @override
  String apiResponseNotJson(String what, String preview) {
    return '$what: response is not valid JSON (first 120 bytes: $preview)';
  }

  @override
  String apiX509ExpectedSequence(String got) {
    return 'Expected SEQUENCE, got 0x$got';
  }

  @override
  String apiX509ExpectedBitString(String got) {
    return 'Expected BIT STRING, got 0x$got';
  }

  @override
  String get apiX509NotSequence => 'RSA public key content is not a SEQUENCE';

  @override
  String get apiX509NoNOrE => 'No n / e INTEGERs found in the RSA public key';

  @override
  String get errNoCompressPermission =>
      'This account has no compression permission (DSM → Control Panel → Application Privileges → File Station)';

  @override
  String get errNoExtractPermission =>
      'This account has no extraction permission (DSM → Control Panel → Application Privileges → File Station)';

  @override
  String get errNoPathPermission => 'No permission to access this location';

  @override
  String get errTargetNotFound =>
      'Target location not found (it may have been moved or deleted)';

  @override
  String get errSearchUnavailable =>
      'Search results are temporarily unavailable, please try again';

  @override
  String get errTooManyRequests => 'Too many requests, please try again later';

  @override
  String get errNoFileService => 'File service is not enabled on this NAS';

  @override
  String get errFileServiceVersionMismatch =>
      'This NAS has an incompatible file service version';

  @override
  String get errBadPathOrName =>
      'Parameter not accepted (possibly the path or file name)';

  @override
  String get errLoginExpired => 'Sign-in expired, please sign in again';

  @override
  String chatSearchFromUsers(int count) {
    return 'From $count people';
  }

  @override
  String chatSearchInChannels(int count) {
    return 'In $count channels';
  }

  @override
  String chatSearchMentions(int count) {
    return 'Mentions $count people';
  }

  @override
  String get chatSearchByTime => 'By time';

  @override
  String get chatFilterStar => 'Starred';

  @override
  String get chatFilterUrl => 'Link';

  @override
  String get chatFilterFile => 'File';

  @override
  String get chatFilterReaction => 'Reaction';

  @override
  String get chatFilterPin => 'Pinned';

  @override
  String get chatFilterVote => 'Poll';

  @override
  String get apiSetReactionNeedsSticker =>
      'setReaction needs stickerId or stickerName';

  @override
  String get apiAnonymousPromoteUnsupported =>
      'SYNO.Chat.Channel.Anonymous does not support promote on this server';

  @override
  String get apiFileIdOrObjectIdRequired =>
      'At least one of fileId and objectId is required';

  @override
  String get apiNodeVersionListNoParamShape =>
      'This server version cannot list node versions';

  @override
  String get apiRenameNeedsObjectId =>
      'The file must be located before renaming; please retry';

  @override
  String get officeFormatMs => 'Office file';

  @override
  String get fotoSpacePersonal => 'Personal space';

  @override
  String get fotoSpaceTeam => 'Shared space';

  @override
  String get noteWrongPasscode =>
      'Wrong password, or this content is not an encrypted note';

  @override
  String get noteNotBase64 =>
      'This content is not Base64, so it is not an encrypted note';

  @override
  String get noteNoSaltedHeader =>
      'No \"Salted__\" container header, so it is not ciphertext from this scheme';

  @override
  String get e2eeNoIdentity => 'E2EE identity is not set up yet';

  @override
  String get e2eeNoChannelKeySeal =>
      'No local key for this channel, cannot seal';

  @override
  String get e2eeNoChannelKeyToEncrypt =>
      'No channel key, cannot send to an encrypted channel';

  @override
  String get e2eeNoChannelKey => 'No channel key';

  @override
  String get apiCompoundMissingResult =>
      'SYNO.Entry.Request: response is missing the result array';

  @override
  String get apiSocketDisconnected => 'Connection closed';

  @override
  String apiPingTimeout(String duration) {
    return 'ping timeout (no ping/pong received for $duration)';
  }

  @override
  String get dtoActionUpload => 'Upload';

  @override
  String get dtoActionDownload => 'Download';

  @override
  String get dtoActionCopy => 'Copy';

  @override
  String get dtoActionMove => 'Move';

  @override
  String get dtoActionDelete => 'Delete';

  @override
  String get dtoTaskGeneric => 'Task';

  @override
  String dtoTaskTitleMore(String label, String name, int count) {
    return '$label · $name and $count more';
  }

  @override
  String get dtoFileTaskCompress => 'Compress';

  @override
  String get dtoFileTaskExtract => 'Extract';

  @override
  String get dtoFileTaskSize => 'Calculate size';

  @override
  String get dtoFileTaskChecksum => 'Calculate checksum';

  @override
  String get dtoShareRoleViewer => 'View only';

  @override
  String get dtoShareRolePreviewer => 'Preview only';

  @override
  String get dtoShareRoleCommenter => 'Can comment';

  @override
  String get dtoShareRolePreviewComment => 'Preview and comment only';

  @override
  String get dtoShareRoleOrganizer => 'Can manage';

  @override
  String get dtoCanEdit => 'Can edit';

  @override
  String get dtoNotePermReadOnly => 'Read only';

  @override
  String get dtoNotebookPreset => 'My notebook';

  @override
  String get dtoNotebookUntitled => 'Untitled notebook';

  @override
  String get dtoNoteUntitled => 'Untitled note';

  @override
  String get dtoPriorityLow => 'Low';

  @override
  String get dtoPriorityMedium => 'Medium';

  @override
  String get dtoPriorityHigh => 'High';

  @override
  String get dtoPriorityNone => 'None';

  @override
  String get dtoVersionUntitled => 'Untitled version';

  @override
  String get dtoEditorDeleted => 'Deleted user';

  @override
  String get dtoCalEveryDay => 'Daily';

  @override
  String get dtoCalEveryWeek => 'Weekly';

  @override
  String get dtoCalEveryMonth => 'Monthly';

  @override
  String get dtoCalEveryYear => 'Yearly';

  @override
  String get dtoCalRepeat => 'Repeats';

  @override
  String dtoCalEvery(int interval, String unit) {
    return 'Every $interval $unit';
  }

  @override
  String get dtoCalMonthWeekday => 'On the nth weekday of the month';

  @override
  String dtoCalEndCount(int count) {
    return '$count times';
  }

  @override
  String dtoCalEndDate(String date) {
    return 'Until $date';
  }

  @override
  String get dtoCalUnitDay => 'days';

  @override
  String get dtoCalUnitWeek => 'weeks';

  @override
  String get dtoCalUnitMonth => 'months';

  @override
  String get dtoCalUnitYear => 'years';

  @override
  String get dtoCalUnitTimes => 'times';

  @override
  String get dtoCalWeekdaySunday => 'Sun';

  @override
  String get dtoCalWeekdayMonday => 'Mon';

  @override
  String get dtoCalWeekdayTuesday => 'Tue';

  @override
  String get dtoCalWeekdayWednesday => 'Wed';

  @override
  String get dtoCalWeekdayThursday => 'Thu';

  @override
  String get dtoCalWeekdayFriday => 'Fri';

  @override
  String get dtoCalWeekdaySaturday => 'Sat';

  @override
  String get dtoCalWeekdaySep => ', ';

  @override
  String get regionUnitMetric => 'Metric';

  @override
  String get regionUnitImperial => 'Imperial';

  @override
  String get regionUnitUk => 'Imperial (UK)';

  @override
  String get regionUnitAuto => 'Follow region';

  @override
  String get regionWindForce => 'Force';

  @override
  String get regionBeaufort0 => 'Calm';

  @override
  String get regionBeaufort1 => 'Light air';

  @override
  String get regionBeaufort2 => 'Light breeze';

  @override
  String get regionBeaufort3 => 'Gentle breeze';

  @override
  String get regionBeaufort4 => 'Moderate breeze';

  @override
  String get regionBeaufort5 => 'Fresh breeze';

  @override
  String get regionBeaufort6 => 'Strong breeze';

  @override
  String get regionBeaufort7 => 'Near gale';

  @override
  String get regionBeaufort8 => 'Gale';

  @override
  String get regionBeaufort9 => 'Strong gale';

  @override
  String get regionBeaufort10 => 'Storm';

  @override
  String get regionBeaufort11 => 'Violent storm';

  @override
  String get regionBeaufort12 => 'Hurricane';

  @override
  String regionWindText(int level, String name) {
    return 'Force $level ($name)';
  }

  @override
  String get regionUnknown => 'Unknown';

  @override
  String get regionSourceManual => 'Manual';

  @override
  String get regionSourceDeviceLocation => 'Phone location';

  @override
  String get regionSourceEventGps => 'Event location (GPS)';

  @override
  String get regionSourceEventAddress => 'Event location (text)';

  @override
  String get regionSourceCalendarTimezone => 'Calendar timezone';

  @override
  String get regionSourceDeviceLocale => 'Device region';

  @override
  String regionLabel(String where, String source) {
    return '$where ($source)';
  }

  @override
  String get wxProviderNwsName => 'NWS (US official)';

  @override
  String get wxProviderNwsNote =>
      'US National Weather Service; official source, no key required';

  @override
  String get wxProviderQweatherName => 'QWeather';

  @override
  String get wxProviderQweatherNote =>
      'Best experience in mainland China (requires your own key)';

  @override
  String get wxProviderMetNoName => 'MET Norway';

  @override
  String get wxProviderMetNoNote =>
      'Norwegian Meteorological Institute; good European data, no key required';

  @override
  String get wxProviderOpenMeteoName => 'Open-Meteo';

  @override
  String get wxProviderOpenMeteoNote =>
      'Global, no key required; current, daily and hourly in one request';

  @override
  String get wxProviderWttrName => 'wttr.in';

  @override
  String get wxProviderWttrNote => 'Fallback source (last in the list)';

  @override
  String get wxErrNwsNoForecast =>
      'NWS did not return a forecast URL (this point may be outside coverage)';

  @override
  String get wxErrQweatherNoKey =>
      'QWeather requires an API key (set it in Settings)';

  @override
  String wxErrHttpStatus(int code) {
    return 'Weather API returned $code';
  }

  @override
  String wxErrHttpStatusBody(int code, String body) {
    return 'Weather API returned $code: $body';
  }

  @override
  String get wxErrNotJson =>
      'Weather API did not return JSON (possibly blocked by a gateway)';

  @override
  String get wxErrNoData => 'Weather API returned no data';

  @override
  String wxErrConnectTimeout(String host) {
    return 'Timed out connecting to $host (check your network)';
  }

  @override
  String wxErrSlowResponse(String host) {
    return '$host is responding too slowly';
  }

  @override
  String wxErrNoConnection(String host) {
    return 'Cannot connect to $host (a proxy may be needed in mainland China)';
  }

  @override
  String wxErrRequestFailed(String url, String error) {
    return 'Request to $url failed: $error';
  }

  @override
  String get wxWindN => 'N';

  @override
  String get wxWindNe => 'NE';

  @override
  String get wxWindE => 'E';

  @override
  String get wxWindSe => 'SE';

  @override
  String get wxWindS => 'S';

  @override
  String get wxWindSw => 'SW';

  @override
  String get wxWindW => 'W';

  @override
  String get wxWindNw => 'NW';

  @override
  String wxWindDir(String dir) {
    return '$dir wind';
  }

  @override
  String get wxCodeClear => 'Clear';

  @override
  String get wxCodeMainlyClear => 'Mainly clear';

  @override
  String get wxCodePartlyCloudy => 'Partly cloudy';

  @override
  String get wxCodeOvercast => 'Overcast';

  @override
  String get wxCodeFog => 'Fog';

  @override
  String get wxCodeDrizzle => 'Drizzle';

  @override
  String get wxCodeLightRain => 'Light rain';

  @override
  String get wxCodeModerateRain => 'Moderate rain';

  @override
  String get wxCodeFreezingRain => 'Freezing rain';

  @override
  String get wxCodeHeavyRain => 'Heavy rain';

  @override
  String get wxCodeLightSnow => 'Light snow';

  @override
  String get wxCodeModerateSnow => 'Moderate snow';

  @override
  String get wxCodeHeavySnow => 'Heavy snow';

  @override
  String get wxCodeSnowGrains => 'Snow grains';

  @override
  String get wxCodeRainShowers => 'Rain showers';

  @override
  String get wxCodeModerateRainShowers => 'Moderate rain showers';

  @override
  String get wxCodeViolentRainShowers => 'Violent rain showers';

  @override
  String get wxCodeSnowShowers => 'Snow showers';

  @override
  String get wxCodeThunderstorm => 'Thunderstorm';

  @override
  String get wxCodeThunderstormHail => 'Thunderstorm with hail';

  @override
  String get wxCodeUnknown => 'Unknown';

  @override
  String get holidayKindPublic => 'Public holiday';

  @override
  String get holidayKindTraditional => 'Traditional festival';

  @override
  String get holidayKindSolarTerm => 'Solar term';

  @override
  String get holidayKindObservance => 'Observance';

  @override
  String get holidayKindWorkday => 'Make-up workday';

  @override
  String get holidayKindReligious => 'Religious holiday';

  @override
  String get holidaySourceOpenHolidays => 'OpenHolidays';

  @override
  String get holidaySourceNager => 'Nager.Date';

  @override
  String get holidaySourceLunar => 'Lunar calendar';

  @override
  String holidaySourceFailed(String source, String error) {
    return 'Failed to load from $source: $error';
  }

  @override
  String holidayNoPublicSource(String cc) {
    return 'No public holiday data source for $cc; showing lunar and traditional festivals only';
  }

  @override
  String get holidayNoRegion =>
      'Region not determined yet; showing lunar calendar only';

  @override
  String holidayNoSourceFor(String country) {
    return 'No public holiday data source for $country yet';
  }

  @override
  String get holidayRegionGeneric => 'This region';

  @override
  String get holidayNewYear => 'New Year\'s Day';

  @override
  String get holidayLabour => 'Labour Day';

  @override
  String get holidayChristmas => 'Christmas';

  @override
  String get holidayGoodFriday => 'Good Friday';

  @override
  String get holidayEasterMonday => 'Easter Monday';

  @override
  String get holidayEasterSunday => 'Easter Sunday';

  @override
  String get holidayNationalDay => 'National Day';

  @override
  String get holidayMidAutumn => 'Mid-Autumn Festival';

  @override
  String get holidayDragonBoat => 'Dragon Boat Festival';

  @override
  String get holidayQingming => 'Qingming Festival';

  @override
  String get holidaySpringFestival => 'Spring Festival';

  @override
  String get holidayAllSaints => 'All Saints\' Day';

  @override
  String get holidayAssumption => 'Assumption Day';

  @override
  String get holidayEpiphany => 'Epiphany';

  @override
  String get holidayWomensDay => 'International Women\'s Day';

  @override
  String get holidayAllSouls => 'All Souls\' Day';

  @override
  String get regionCountryCN => 'China';

  @override
  String get regionCountryHK => 'Hong Kong';

  @override
  String get regionCountryMO => 'Macao';

  @override
  String get regionCountryTW => 'Taiwan';

  @override
  String get regionCountryJP => 'Japan';

  @override
  String get regionCountryKR => 'South Korea';

  @override
  String get regionCountryKP => 'North Korea';

  @override
  String get regionCountrySG => 'Singapore';

  @override
  String get regionCountryMY => 'Malaysia';

  @override
  String get regionCountryTH => 'Thailand';

  @override
  String get regionCountryVN => 'Vietnam';

  @override
  String get regionCountryID => 'Indonesia';

  @override
  String get regionCountryPH => 'Philippines';

  @override
  String get regionCountryIN => 'India';

  @override
  String get regionCountryAE => 'United Arab Emirates';

  @override
  String get regionCountrySA => 'Saudi Arabia';

  @override
  String get regionCountryIL => 'Israel';

  @override
  String get regionCountryTR => 'Türkiye';

  @override
  String get regionCountryGB => 'United Kingdom';

  @override
  String get regionCountryIE => 'Ireland';

  @override
  String get regionCountryFR => 'France';

  @override
  String get regionCountryDE => 'Germany';

  @override
  String get regionCountryES => 'Spain';

  @override
  String get regionCountryIT => 'Italy';

  @override
  String get regionCountryNL => 'Netherlands';

  @override
  String get regionCountryBE => 'Belgium';

  @override
  String get regionCountryAT => 'Austria';

  @override
  String get regionCountryCH => 'Switzerland';

  @override
  String get regionCountrySE => 'Sweden';

  @override
  String get regionCountryNO => 'Norway';

  @override
  String get regionCountryDK => 'Denmark';

  @override
  String get regionCountryFI => 'Finland';

  @override
  String get regionCountryPL => 'Poland';

  @override
  String get regionCountryCZ => 'Czechia';

  @override
  String get regionCountryHU => 'Hungary';

  @override
  String get regionCountryPT => 'Portugal';

  @override
  String get regionCountryGR => 'Greece';

  @override
  String get regionCountryRU => 'Russia';

  @override
  String get regionCountryUA => 'Ukraine';

  @override
  String get regionCountryUS => 'United States';

  @override
  String get regionCountryCA => 'Canada';

  @override
  String get regionCountryMX => 'Mexico';

  @override
  String get regionCountryBR => 'Brazil';

  @override
  String get regionCountryAR => 'Argentina';

  @override
  String get regionCountryCL => 'Chile';

  @override
  String get regionCountryCO => 'Colombia';

  @override
  String get regionCountryPE => 'Peru';

  @override
  String get regionCountryEG => 'Egypt';

  @override
  String get regionCountryZA => 'South Africa';

  @override
  String get regionCountryNG => 'Nigeria';

  @override
  String get regionCountryKE => 'Kenya';

  @override
  String get regionCountryAU => 'Australia';

  @override
  String get regionCountryNZ => 'New Zealand';

  @override
  String get holidayNoteSep => '; ';

  @override
  String get photoSectionTimeline => 'Timeline';

  @override
  String get photoSectionFolders => 'Folders';

  @override
  String get photoSectionFavorites => 'Favorites';

  @override
  String get photoNewAlbum => 'New album';

  @override
  String get photoCreateFolder => 'Create folder';

  @override
  String get photoRefresh => 'Refresh';

  @override
  String get photoSwitchSpace => 'Switch space';

  @override
  String get photoEmptyTimelineTitle => 'No photos yet';

  @override
  String get photoEmptyTimelineMessage =>
      'No indexed photos in your personal space yet.\nUpload with DSM \"Synology Photos\" or phone backup and they\'ll show up here.';

  @override
  String get photoEmptyAlbumsTitle => 'No albums yet';

  @override
  String get photoEmptyAlbumsMessage =>
      'Tap \"New album\" at the bottom right, or open a photo and use \"Add to album\".\n(Automatic backup is out of scope for this app.)';

  @override
  String photoItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$_temp0';
  }

  @override
  String get photoConditionalAlbum => 'Conditional album';

  @override
  String get photoShare => 'Share';

  @override
  String get photoShared => 'Shared';

  @override
  String get photoEmptyFoldersTitle => 'No visible folders';

  @override
  String get photoEmptyFoldersMessage =>
      'The \"Folders\" view mirrors the photo shared folder structure in DSM; regular users only see their own home/Photos by default.';

  @override
  String get photoMore => 'More';

  @override
  String get photoRename => 'Rename';

  @override
  String get photoDeleteFolder => 'Delete folder';

  @override
  String get photoSharedWithMe => 'Shared with me';

  @override
  String get photoEmptyFavoritesTitle => 'No favorites yet';

  @override
  String get photoEmptyFavoritesMessage =>
      'Tap the star at the bottom right of the viewer to favorite; favorites sync to the NAS.';

  @override
  String get photoAlbumActions => 'Album actions';

  @override
  String get photoDeleteAlbum => 'Delete album';

  @override
  String get photoEmptyAlbumTitle => 'This album is empty';

  @override
  String get photoEmptyAlbumMessage =>
      'Open a photo in the timeline and use \"Add to album\" to put it here.';

  @override
  String get photoRenameAlbum => 'Rename album';

  @override
  String get photoAlbumNameHint => 'Album name';

  @override
  String photoAlbumCreateHelper(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'The $count photos will be added to the new album.',
      one: 'The 1 photo will be added to the new album.',
    );
    return '$_temp0';
  }

  @override
  String get photoCreate => 'Create';

  @override
  String get photoAlbumNameRequired => 'Album name can\'t be empty';

  @override
  String photoAlbumCreated(String name) {
    return 'Created \"$name\"';
  }

  @override
  String photoAlbumCreateFailed(String error) {
    return 'Couldn\'t create album: $error';
  }

  @override
  String photoAddToAlbumTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Add to album ($count photos)',
      one: 'Add to album (1 photo)',
    );
    return '$_temp0';
  }

  @override
  String get photoClose => 'Close';

  @override
  String get photoNewAlbumAndAdd => 'New album with photos';

  @override
  String get photoNoNormalAlbums =>
      'No regular albums yet (photos can\'t be added to conditional albums manually)';

  @override
  String get photoAddedToAlbum => 'Added to album';

  @override
  String photoAddedPartial(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Added; $count photos couldn\'t be added (maybe they\'re in another album)',
      one: 'Added; 1 photo couldn\'t be added (maybe it\'s in another album)',
    );
    return '$_temp0';
  }

  @override
  String photoAddToAlbumFailed(String error) {
    return 'Couldn\'t add to album: $error';
  }

  @override
  String photoRenamed(String name) {
    return 'Renamed to \"$name\"';
  }

  @override
  String photoRenameFailed(String error) {
    return 'Couldn\'t rename: $error';
  }

  @override
  String get photoDeleteAlbumConfirm => 'Delete album?';

  @override
  String photoDeleteAlbumMessage(String name) {
    return '\"$name\" will be deleted; its photos stay in the photo library.';
  }

  @override
  String photoAlbumDeleted(String name) {
    return 'Deleted \"$name\"';
  }

  @override
  String photoDeleteFailed(String error) {
    return 'Couldn\'t delete: $error';
  }

  @override
  String get photoFolderNameHint => 'Folder name';

  @override
  String get photoFolderNameRequired => 'Folder name can\'t be empty';

  @override
  String photoFolderCreated(String name) {
    return 'Folder \"$name\" created';
  }

  @override
  String photoFolderCreateFailed(String error) {
    return 'Couldn\'t create folder: $error';
  }

  @override
  String get photoNewFolder => 'New folder';

  @override
  String get photoRenameFolder => 'Rename folder';

  @override
  String get photoDeleteFolderConfirm => 'Delete folder?';

  @override
  String photoDeleteFolderMessage(String name) {
    return '\"$name\" will be deleted and moved to the recycle bin (restorable in Drive).';
  }

  @override
  String photoFolderDeleted(String name) {
    return 'Deleted \"$name\"';
  }

  @override
  String get photoFavorited => 'Added to favorites';

  @override
  String get photoUnfavorited => 'Removed from favorites';

  @override
  String photoFavoriteFailed(String error) {
    return 'Couldn\'t update favorite: $error';
  }

  @override
  String get photoCoverSet => 'Set as cover';

  @override
  String photoCoverFailed(String error) {
    return 'Couldn\'t set cover: $error';
  }

  @override
  String get photoRemovedFromAlbum => 'Removed from album';

  @override
  String photoRemoveFailed(String error) {
    return 'Couldn\'t remove: $error';
  }

  @override
  String photoOpenedWith(String name) {
    return 'Opened with another app: $name';
  }

  @override
  String photoDownloaded(String name) {
    return 'Downloaded: $name';
  }

  @override
  String photoDownloadFailed(String error) {
    return 'Download failed: $error';
  }

  @override
  String get photoTakenAt => 'Taken';

  @override
  String get photoFileSize => 'Size';

  @override
  String get photoKind => 'Type';

  @override
  String get photoVideo => 'Video';

  @override
  String get photoKindPhoto => 'Photo';

  @override
  String get photoFolder => 'Folder';

  @override
  String get photoYes => 'Yes';

  @override
  String get photoNo => 'No';

  @override
  String get photoAddToAlbum => 'Add to album';

  @override
  String get photoSetAsCover => 'Set as album cover';

  @override
  String photoRemoveFromAlbumNamed(String name) {
    return 'Remove from \"$name\"';
  }

  @override
  String get photoInfo => 'Info';

  @override
  String get photoOpenWithOther => 'Open with another app';

  @override
  String get photoNotConnected => 'Not connected to the NAS yet';

  @override
  String get photoUnfavorite => 'Remove from favorites';

  @override
  String get photoOpenInPlayer => 'Open in system player';

  @override
  String photoOpenVideoFailed(String error) {
    return 'Couldn\'t open this video: $error';
  }

  @override
  String get photoDecodeFailed => 'Couldn\'t decode this image';

  @override
  String get photoErrSpacePermission =>
      'No permission for this space (the Synology Photos \"Shared space\" permission is assigned by an administrator)';

  @override
  String get photoErrNotFound =>
      'This photo/album doesn\'t exist or has been deleted';

  @override
  String get photoErrAccount =>
      'This account has no Synology Photos permission';

  @override
  String get photoErrDsmDenied =>
      'DSM denied the Photos app permission (Control Panel → Application Privileges → Synology Photos)';

  @override
  String get photoErrNotInstalled =>
      'Synology Photos isn\'t installed on this NAS';

  @override
  String get photoErrApiVersion =>
      'This NAS\'s Photos API version doesn\'t support this feature';

  @override
  String photoGroupMonth(int year, int month) {
    return '$month/$year';
  }

  @override
  String photoGroupDay(int year, int month, int day) {
    return '$month/$day/$year';
  }

  @override
  String get photoLoadFailed => 'Couldn\'t load';

  @override
  String get photoRetry => 'Retry';

  @override
  String get calWeekdayMinSun => 'Sun';

  @override
  String get calWeekdayMinMon => 'Mon';

  @override
  String get calWeekdayMinTue => 'Tue';

  @override
  String get calWeekdayMinWed => 'Wed';

  @override
  String get calWeekdayMinThu => 'Thu';

  @override
  String get calWeekdayMinFri => 'Fri';

  @override
  String get calWeekdayMinSat => 'Sat';

  @override
  String get calToday => 'Today';

  @override
  String get calEventFab => 'Event';

  @override
  String get calSubtitle => 'Synology Calendar';

  @override
  String get calBack => 'Back';

  @override
  String get calCalendarGroups => 'Calendar groups';

  @override
  String get calMonthView => 'Month';

  @override
  String get calWeekView => 'Week';

  @override
  String get calDayView => 'Day';

  @override
  String get calPrevMonth => 'Previous month';

  @override
  String get calNextMonth => 'Next month';

  @override
  String get calPrevWeek => 'Previous week';

  @override
  String get calNextWeek => 'Next week';

  @override
  String get calPrevDay => 'Previous day';

  @override
  String get calNextDay => 'Next day';

  @override
  String calMonthTitle(int year, int month) {
    return '$month/$year';
  }

  @override
  String calWeekRangeTitle(int month, int day) {
    return 'Week of $month/$day';
  }

  @override
  String calDayTitle(int month, int day, String weekday) {
    return '$month/$day · $weekday';
  }

  @override
  String calDayHeader(int month, int day, String weekday) {
    return '$month/$day · $weekday';
  }

  @override
  String get calEmptyCell => 'Empty';

  @override
  String get calNoTitle => '(No title)';

  @override
  String get calAllDay => 'All day';

  @override
  String get calTimeUnknown => 'Unknown time';

  @override
  String calDueDate(String date) {
    return 'Due $date';
  }

  @override
  String calCreator(String name) {
    return 'Created by $name';
  }

  @override
  String calTimezone(String tz) {
    return 'Time zone $tz';
  }

  @override
  String get calOccurrenceSuffix => ' (one of the occurrences)';

  @override
  String calTodoSection(int open) {
    return 'To-dos ($open)';
  }

  @override
  String calTodoSectionDone(int open, int done) {
    return 'To-dos ($open) · $done done';
  }

  @override
  String get calMarkDone => 'Mark as done';

  @override
  String get calMarkUndone => 'Mark as not done';

  @override
  String get calCleanDone => 'Clear completed';

  @override
  String get calNew => 'New';

  @override
  String get calNewTodo => 'New to-do';

  @override
  String get calEditTodo => 'Edit to-do';

  @override
  String get calEditEvent => 'Edit event';

  @override
  String get calNewEvent => 'New event';

  @override
  String get calEditThis => 'Edit this one';

  @override
  String get calEditAll => 'Edit all';

  @override
  String get calOnlyThis => 'This event only';

  @override
  String get calAllEvents => 'All events';

  @override
  String get calReadOnlyCalendar => 'Read-only calendar';

  @override
  String get calCanWrite => 'Writable';

  @override
  String get calSelectAll => 'Select all';

  @override
  String get calDayNoEventsTitle => 'No events on this day';

  @override
  String get calDayNoEventsMessage =>
      'Tap \"Event\" at the bottom right to add one, or try another day';

  @override
  String get calLoadFailed => 'Couldn\'t load the calendar';

  @override
  String get calNoWritableCalendar => 'No writable calendar';

  @override
  String get calNoWritableTodoCalendar => 'No writable to-do calendar';

  @override
  String get calEventTitleLabel => 'Title';

  @override
  String get calStartLabel => 'Start';

  @override
  String get calEndLabel => 'End';

  @override
  String get calDescriptionOptional => 'Description (optional)';

  @override
  String get calTitleRequired => 'Title cannot be empty';

  @override
  String get calRepeatNever => 'Does not repeat';

  @override
  String get calRepeatForever => 'Never ends';

  @override
  String get calRepeatCountLabel => 'Repeat count';

  @override
  String get calRepeatUntilDate => 'Until a date';

  @override
  String get calRepeatUntil => 'Repeat until';

  @override
  String get calPickDate => 'Pick a date';

  @override
  String calRepeatIntervalLabel(String unit) {
    return 'Interval (every N $unit)';
  }

  @override
  String calRepeatPrefixed(String rule) {
    return 'Repeats: $rule';
  }

  @override
  String get calRepeatLockedHint =>
      'Changes here apply only to this day; the other occurrences are unaffected';

  @override
  String calDeletedOnce(String summary) {
    return 'Deleted this occurrence of \"$summary\"';
  }

  @override
  String calDeletedSeries(String summary) {
    return 'Deleted the whole repeating event \"$summary\"';
  }

  @override
  String calDeleted(String summary) {
    return 'Deleted \"$summary\"';
  }

  @override
  String calCreated(String summary) {
    return 'Created \"$summary\"';
  }

  @override
  String calUpdatedOnce(String summary) {
    return 'Updated this occurrence of \"$summary\"';
  }

  @override
  String calUpdatedSeries(String summary) {
    return 'Updated the whole repeating event \"$summary\"';
  }

  @override
  String calUpdated(String summary) {
    return 'Updated \"$summary\"';
  }

  @override
  String calCreatedTodo(String summary) {
    return 'Created to-do \"$summary\"';
  }

  @override
  String get calTodoSaved => 'To-do saved';

  @override
  String get calCleanedDone => 'Cleared completed to-dos';

  @override
  String calDeleteFailed(String error) {
    return 'Couldn\'t delete: $error';
  }

  @override
  String calCreateFailed(String error) {
    return 'Couldn\'t create: $error';
  }

  @override
  String calUpdateFailed(String error) {
    return 'Couldn\'t update: $error';
  }

  @override
  String calTodoActionFailed(String error) {
    return 'Action failed: $error';
  }

  @override
  String calToggleFailed(String error) {
    return 'Couldn\'t toggle: $error';
  }

  @override
  String calClearFailed(String error) {
    return 'Couldn\'t clear: $error';
  }

  @override
  String get calTodoContent => 'To-do';

  @override
  String get calTodoContentRequired => 'To-do content can\'t be empty';

  @override
  String get calTodoCalendar => 'To-do calendar';

  @override
  String get calDone => 'Completed';

  @override
  String get calDueTime => 'Due time';

  @override
  String get calNotSet => 'Not set';

  @override
  String get calClearDue => 'Clear due time';

  @override
  String get calTodoNoteOptional => 'Note (optional)';

  @override
  String get calDeleteTodo => 'Delete to-do';

  @override
  String get calEnvTitle => 'Weather & holidays';

  @override
  String get calEnvRegionPending => 'Detecting region';

  @override
  String get calEnvRegionPendingDots => 'Detecting region…';

  @override
  String get calEnvAutoLocate => 'Use phone location';

  @override
  String get calEnvLocating => 'Locating…';

  @override
  String get calEnvLocateButton => 'Locating…';

  @override
  String get calEnvNoFix => 'No location fix (is location turned off?)';

  @override
  String get calEnvNoPermission =>
      'Not authorized yet — tap \"Use current location\" below to allow';

  @override
  String calEnvLocated(String coords) {
    return 'Located: $coords';
  }

  @override
  String calEnvAccuracy(String m) {
    return 'Accuracy $m m';
  }

  @override
  String get calEnvLocateOff => 'Off; using the manual place/timezone below';

  @override
  String get calEnvUseCurrent => 'Use current location';

  @override
  String get calEnvPlaceLabel => 'Place (weather uses these coordinates)';

  @override
  String get calEnvPlaceHint => 'City or place name, e.g. Hangzhou';

  @override
  String get calEnvSearch => 'Search';

  @override
  String get calEnvSearching => 'Searching…';

  @override
  String get calEnvPlaceNotFound => 'Place not found (nothing made up)';

  @override
  String calEnvSearchFailed(String error) {
    return 'Search failed: $error';
  }

  @override
  String calEnvPlaceCurrent(String name, String lat, String lon) {
    return 'Current place: $name ($lat, $lon)';
  }

  @override
  String get calEnvClear => 'Clear';

  @override
  String get calEnvRegion => 'Region';

  @override
  String get calEnvAuto => 'Auto';

  @override
  String get calEnvWeatherBg =>
      'Show weather animation as the calendar background';

  @override
  String get calEnvWeatherBgHint =>
      'Follows the selected day\'s weather (rain/snow/cloud/sunlight/stars); blurred so text stays readable';

  @override
  String get calEnvUnitsLabel => 'Units (auto by region by default)';

  @override
  String get calEnvUnitsByRegion => 'By region';

  @override
  String calEnvUnitsSummary(
    String temp,
    String wind,
    String precip,
    String pressure,
    String vis,
  ) {
    return 'Current: temperature $temp · wind $wind · precipitation $precip · pressure $pressure · visibility $vis';
  }

  @override
  String get calEnvWeatherSource => 'Weather source';

  @override
  String get calEnvNoProvider => 'No weather source available for this region';

  @override
  String calEnvUsingProvider(String provider) {
    return 'Using: $provider';
  }

  @override
  String get calEnvQweatherKeyLabel =>
      'QWeather API key (optional, stored in secure storage)';

  @override
  String get calEnvQweatherKeyHint =>
      'Only needed when using the QWeather source';

  @override
  String get calEnvQweatherKeySaved => 'QWeather key saved';

  @override
  String get calEnvSaveKey => 'Save key';

  @override
  String get calEnvKeyConfigured => 'Configured (value not shown)';

  @override
  String get calEnvKeyMissing => 'Not configured';

  @override
  String get calEnvHolidaySources => 'Holiday sources';

  @override
  String get calEnvHolidaySourcesNote =>
      'Public holidays come from an online holiday database (incl. states/provinces in Europe); lunar dates, solar terms and Chinese make-up days are computed locally (offline). Religious holidays follow moon sightings and are marked as estimated.';

  @override
  String get calEnvRefetch => 'Fetch again';

  @override
  String get calEnvDone => 'Done';

  @override
  String get calEnvBadgeRest => 'Off';

  @override
  String get calEnvBadgeWork => 'Work';

  @override
  String calEnvWeatherFailed(String error) {
    return 'Weather unavailable: $error';
  }

  @override
  String get calEnvWeatherLoading => 'Fetching weather…';

  @override
  String get calEnvNoPlace => 'Weather needs a location — tap to allow';

  @override
  String calEnvFeelsLike(String temp) {
    return ' Feels like $temp°';
  }

  @override
  String get calEnvTodayForecast => 'Today\'s forecast';

  @override
  String calEnvPrecip(String value, String unit) {
    return 'Precipitation $value$unit';
  }

  @override
  String calEnvSunrise(String time) {
    return 'Sunrise $time';
  }

  @override
  String calEnvSunset(String time) {
    return 'Sunset $time';
  }

  @override
  String get calEnvNowLabel => 'Now';

  @override
  String calEnvHumidity(String value) {
    return 'Humidity $value%';
  }

  @override
  String calEnvWind(String text) {
    return 'Wind $text';
  }

  @override
  String calEnvPressure(String value, String unit) {
    return 'Pressure $value$unit';
  }

  @override
  String calEnvDaily(String text) {
    return 'Today $text';
  }

  @override
  String get calEnvHourNow => 'Now';

  @override
  String calEnvHour(int hour) {
    return '$hour:00';
  }

  @override
  String calEnvApprox(String name) {
    return 'Est. $name';
  }

  @override
  String get calEnvWorkdaySuffix => ' (workday)';

  @override
  String calEnvSourceWeather(String name) {
    return 'Weather $name';
  }

  @override
  String calEnvSourceHoliday(String sources) {
    return 'Holidays $sources';
  }

  @override
  String get calEditLabel => 'Edit';

  @override
  String get noteErrNoPermission =>
      'This account has no Note Station permission (DSM → Control Panel → Application Privileges → Note Station)';

  @override
  String get noteErrAppDenied =>
      'DSM denied the Note Station application privilege (same as above)';

  @override
  String get noteErrParam =>
      'Parameters rejected (the notes API requires JSON-encoded parameters)';

  @override
  String get noteErrNotInstalled =>
      'Note Station is not installed or not enabled on this NAS';

  @override
  String get noteErrVersion =>
      'This NAS\'s Note Station version is incompatible';

  @override
  String noteConflictBanner(int n) {
    return '$n notes changed on both sides; tap to choose which one to keep';
  }

  @override
  String notePendingCount(int n) {
    return '$n changes waiting to sync';
  }

  @override
  String get noteOfflineCached => 'Offline · showing the last synced content';

  @override
  String noteOfflineCachedPending(int n) {
    return 'Offline · showing cached content · $n changes waiting to sync';
  }

  @override
  String get noteSyncing => 'Syncing…';

  @override
  String get noteSyncNow => 'Sync now';

  @override
  String get noteAll => 'All';

  @override
  String get noteNoNotebooks => 'No notebooks yet';

  @override
  String get noteEncrypted => 'Encrypted';

  @override
  String get noteSearchHint => 'Search title / excerpt / tags';

  @override
  String get noteCloseSearch => 'Close search';

  @override
  String get noteSearchNotes => 'Search notes';

  @override
  String get noteSyncMenu => 'Sync (pull + push)';

  @override
  String get noteTodoTitle => 'To-dos';

  @override
  String get noteTags => 'Tags';

  @override
  String get noteRecycle => 'Recycle bin';

  @override
  String get noteNewNotebook => 'New notebook';

  @override
  String get noteNewNote => 'New note';

  @override
  String get noteOpenNotesFailed => 'Couldn\'t open notes';

  @override
  String get noteEmptySearch => 'No matching notes';

  @override
  String get noteEmptyNotebook => 'This notebook is empty';

  @override
  String get noteEmptyAll => 'No notes yet';

  @override
  String get noteEmptyGeneric => 'Nothing here';

  @override
  String get noteNotebookName => 'Notebook name';

  @override
  String noteNotebookCreateFailed(String error) {
    return 'Couldn\'t create: $error';
  }

  @override
  String get noteRenameNotebook => 'Rename notebook';

  @override
  String get noteDeleteNotebookWithNotes => 'Delete (including its notes)';

  @override
  String noteNotebookUpdateFailed(String error) {
    return 'Couldn\'t update: $error';
  }

  @override
  String get noteDeleteNotebook => 'Delete notebook';

  @override
  String noteDeleteNotebookConfirm(String title) {
    return '\"$title\" and all its notes will be deleted.';
  }

  @override
  String noteNotebookDeleteFailed(String error) {
    return 'Couldn\'t delete: $error';
  }

  @override
  String get noteEmptyCreateHint =>
      'Tap \"New note\" at the bottom right to write your first one';

  @override
  String get noteShare => 'Share';

  @override
  String get noteVersionHistory => 'Version history';

  @override
  String get noteUnlockPrompt => 'Enter passcode';

  @override
  String get noteOpenFailed => 'Couldn\'t open this note';

  @override
  String noteModifiedAt(String time) {
    return 'Modified $time';
  }

  @override
  String get noteEncryptedAes => 'Encrypted note (AES256)';

  @override
  String get noteOfflineCacheNotice =>
      'Offline · showing this device\'s cached copy';

  @override
  String get noteWrongPasswordRetry => 'Wrong passcode, try again';

  @override
  String noteUnlockFailed(String error) {
    return 'Couldn\'t unlock: $error';
  }

  @override
  String get noteIsEncrypted => 'This note is encrypted';

  @override
  String get notePasswordLocalOnly =>
      'The body is ciphertext on the server; the passcode is used only in local memory (never uploaded or stored)';

  @override
  String get notePasscode => 'Passcode';

  @override
  String get noteUnlockTitle => 'Enter the passcode to unlock';

  @override
  String get noteWrongPassword => 'Wrong passcode';

  @override
  String get noteLocked => 'Locked';

  @override
  String noteTagFailed(String error) {
    return 'Couldn\'t change tags: $error';
  }

  @override
  String get noteUnlockToEdit => 'Unlock first to edit';

  @override
  String get noteDeleteTitle => 'Delete note';

  @override
  String noteDeleteConfirm(String title) {
    return '\"$title\" will be moved to the recycle bin and can be restored.';
  }

  @override
  String get noteDeletedOffline => 'Deleted offline; will sync when online';

  @override
  String get noteMovedToRecycle => 'Moved to the recycle bin';

  @override
  String noteDeleteFailed(String error) {
    return 'Couldn\'t delete: $error';
  }

  @override
  String get noteHistoryFailed => 'Couldn\'t read the version history';

  @override
  String get noteNoVersions => 'No earlier versions yet';

  @override
  String noteVersionN(String n) {
    return 'Version $n';
  }

  @override
  String get noteVersionRestored => 'Version restored';

  @override
  String noteRestoreFailed(String error) {
    return 'Couldn\'t restore: $error';
  }

  @override
  String get noteRestore => 'Restore';

  @override
  String get noteNewTagHint => 'New tag';

  @override
  String get noteAddTag => 'Add tags';

  @override
  String get noteNoTagsYet => 'No tags yet';

  @override
  String get noteTagsUnavailable =>
      'Couldn\'t load the tag list (network or permission); some tags may be missing';

  @override
  String get noteRecycleEmpty => 'The recycle bin is empty';

  @override
  String get noteRecycleEmptyMessage =>
      'Deleted notes land here first and are cleaned up by the NAS after 30 days';

  @override
  String get noteUntitled => 'Untitled note';

  @override
  String get noteActions => 'Actions';

  @override
  String get noteRecycleRestore => 'Restore';

  @override
  String get notePurge => 'Delete permanently';

  @override
  String noteRecycleActionFailed(String error) {
    return 'Action failed: $error';
  }

  @override
  String get noteRestored => 'Restored';

  @override
  String notePurgeConfirm(String title) {
    return '\"$title\" will be permanently deleted and cannot be recovered.';
  }

  @override
  String get notePurged => 'Permanently deleted';

  @override
  String get noteRecycleCleanTitle => 'Empty recycle bin';

  @override
  String noteRecycleCleanConfirm(int count) {
    return '$count notes will be permanently deleted and cannot be recovered.';
  }

  @override
  String noteRecycleCleanFailed(String error) {
    return 'Couldn\'t empty: $error';
  }

  @override
  String get noteOpenTagsFailed => 'Couldn\'t open tags';

  @override
  String get noteTagCreateHint =>
      'Open a note → \"Tags\" at the top right → type a new name, and the tag shows up here';

  @override
  String noteTagCount(int n) {
    return '$n notes';
  }

  @override
  String get noteTagNameHint => 'Tag name';

  @override
  String get noteRenameTag => 'Rename tag';

  @override
  String get noteDeleteTag => 'Delete tag';

  @override
  String noteDeleteTagConfirm(String title) {
    return '\"$title\" will be removed from all notes (the notes themselves stay).';
  }

  @override
  String get noteTodoOpen => 'Open';

  @override
  String get noteOpenTodosFailed => 'Couldn\'t open to-dos';

  @override
  String get noteNoTodos => 'No to-dos';

  @override
  String get noteNoTodosMessage =>
      'Tasks created in NoteStation will show up here';

  @override
  String noteTodoSaved(String title) {
    return 'Saved \"$title\"';
  }

  @override
  String get noteTodoOfflineChecked => 'Checked offline; will sync when online';

  @override
  String noteTodoUpdateFailed(String error) {
    return 'Couldn\'t update: $error';
  }

  @override
  String get noteExpandSubtasks => 'Expand subtasks';

  @override
  String get noteCollapseSubtasks => 'Collapse subtasks';

  @override
  String notePriorityLabel(String priority) {
    return '$priority priority';
  }

  @override
  String noteDue(String date) {
    return 'Due $date';
  }

  @override
  String get noteSubtask => 'Subtask';

  @override
  String get noteAddSubtask => 'Add subtask';

  @override
  String get noteNewSubtask => 'New subtask';

  @override
  String get noteTaskHint => 'What to do';

  @override
  String get noteDueDate => 'Due date';

  @override
  String get noteClearDueDate => 'Clear due date';

  @override
  String get notePriority => 'Priority';

  @override
  String get noteStar => 'Star';

  @override
  String get noteComment => 'Comment';

  @override
  String get noteOptional => 'Optional';

  @override
  String get notePriorityHint =>
      'Note: priority is a server-side enum (none/low/medium/high); an invalid value is reported as a missing parameter';

  @override
  String notePriorityValue(String priority) {
    return 'Priority: $priority';
  }

  @override
  String get noteTaskNameRequired => 'Task name can\'t be empty';

  @override
  String noteTodoSaveFailed(String error) {
    return 'Couldn\'t save: $error';
  }

  @override
  String get noteDeleteTodo => 'Delete to-do';

  @override
  String noteDeleteTodoConfirm(String title) {
    return '\"$title\" will be deleted.';
  }

  @override
  String noteTodoDeleteFailed(String error) {
    return 'Couldn\'t delete: $error';
  }

  @override
  String get noteFromNas => 'Pick an image from the NAS';

  @override
  String get noteInsert => 'Insert';

  @override
  String noteInsertCount(int n) {
    return 'Insert $n';
  }

  @override
  String get noteUpOneLevel => 'Up one level';

  @override
  String noteFolderOpenFailed(String error) {
    return 'Couldn\'t open this folder\n$error';
  }

  @override
  String get noteNoImagesHere => 'No images here';

  @override
  String get noteEmptyBody => 'This note is still empty';

  @override
  String get noteImageAttachment => 'Image attachment';

  @override
  String noteImageOpenFailed(String name) {
    return 'Can\'t open $name';
  }

  @override
  String get noteImageInNote => 'Image in note';

  @override
  String noteImageOpenError(String error) {
    return 'Couldn\'t open this image: $error';
  }

  @override
  String get noteConflictTitle => 'Sync conflict';

  @override
  String get noteNoConflicts => 'No conflicts left';

  @override
  String get noteNoConflictsMessage => 'Both sides now match.';

  @override
  String noteConflictUntitled(int n) {
    return 'Untitled $n';
  }

  @override
  String get noteConflictExplain =>
      'The server changed this note after you edited it offline. Keep one side; the other version will be discarded.';

  @override
  String get noteConflictLocal => 'My changes';

  @override
  String get noteConflictServer => 'Server version';

  @override
  String get noteConflictLocalEmpty => '(local content is empty)';

  @override
  String get noteConflictServerEmpty => '(server content is empty)';

  @override
  String get noteConflictServerFetchFailed =>
      'Couldn\'t fetch the server content (offline or encrypted).\nChoosing \"Use server\" will try again.';

  @override
  String get noteConflictKeepLocal => 'Keep mine';

  @override
  String get noteConflictUseServer => 'Use server';

  @override
  String get noteConflictUsedLocal =>
      'Overwrote the server with the local content';

  @override
  String get noteConflictUsedServer => 'Switched to the server version';

  @override
  String noteConflictMore(int n) {
    return '$n conflicts; showing the first 5';
  }

  @override
  String notePendingSyncFailed(String error) {
    return 'There are unsynced changes: $error';
  }

  @override
  String noteOverwriteFailed(String error) {
    return 'Couldn\'t overwrite: $error';
  }

  @override
  String noteDiscardFailed(String error) {
    return 'Couldn\'t discard local changes: $error';
  }

  @override
  String get notePasscodeRequired => 'Passcode can\'t be empty';

  @override
  String notePasscodeTooLong(int n) {
    return 'Passcodes are at most $n characters (same as the official app)';
  }

  @override
  String noteShareFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get notePublicShareOff => 'Public sharing turned off';

  @override
  String notePublicShareOn(String perm) {
    return 'Public sharing: $perm';
  }

  @override
  String noteShareLinkFailed(String error) {
    return 'Couldn\'t get the share link: $error';
  }

  @override
  String noteSharedWithGroup(String name, String perm) {
    return 'Group \"$name\": $perm';
  }

  @override
  String noteSharedWithUser(String name, String perm) {
    return 'User \"$name\": $perm';
  }

  @override
  String noteShareRemoved(String name) {
    return 'Stopped sharing with \"$name\"';
  }

  @override
  String get noteEncryptedNoShare => 'Encrypted notes can\'t be shared';

  @override
  String get noteEncryptedNoShareMessage =>
      'Encrypted notes in Synology Note Station cannot be shared publicly or with others.\nTurn off encryption first.';

  @override
  String get notePublicShare => 'Public sharing';

  @override
  String get noteAnyoneWithLink => 'Anyone with the link can open it';

  @override
  String noteCurrentPerm(String perm) {
    return 'Current permission: $perm';
  }

  @override
  String get notePublicOffHint =>
      'When off, only accounts you share with individually can view it';

  @override
  String get noteGettingLink => 'Getting the link…';

  @override
  String get noteNoLink => 'No link yet';

  @override
  String get noteCopyLink => 'Copy link';

  @override
  String get noteLinkCopied => 'Link copied';

  @override
  String get noteRefetchLink => 'Get link again';

  @override
  String get noteSharedWith => 'Shared with';

  @override
  String get noteSharedTitle => 'Shared by me';

  @override
  String get noteSharedEmpty => 'Nothing shared by you yet';

  @override
  String get noteSharedNotebooks => 'Shared notebooks';

  @override
  String get noteSharedNotes => 'Shared notes';

  @override
  String get noteBackgroundSyncTitle => 'Background sync';

  @override
  String get noteBackgroundSyncHint =>
      'Android pulls note changes in the background from time to time; turning this off only stops background sync and manual sync in the app still works';

  @override
  String get noteBackgroundSyncEnable => 'Allow background sync';

  @override
  String get noteBackgroundSyncNow => 'Sync now';

  @override
  String get noteBackgroundSyncQueued =>
      'Queued; it will sync automatically later';

  @override
  String get noteBackgroundSyncFailed => 'Setup failed';

  @override
  String get noteNoIndividualShare => 'Not shared with any account yet';

  @override
  String get noteUser => 'User';

  @override
  String get noteGroup => 'Group';

  @override
  String get noteInherited => 'Inherited from notebook';

  @override
  String get noteStopSharing => 'Stop sharing';

  @override
  String get noteAddUserGroup => 'Add a user or group';

  @override
  String get noteSearchDsmAccount => 'Search DSM users or groups';

  @override
  String noteAccountSearchFailed(String error) {
    return 'Couldn\'t find accounts: $error';
  }

  @override
  String get noteNoMatchingAccount => 'No matching accounts';

  @override
  String get notePermReadOnlyDesc => 'View only, cannot edit';

  @override
  String get notePermReadWriteDesc => 'Can edit the content';

  @override
  String get noteEditNote => 'Edit note';

  @override
  String get noteAiAssistant => 'AI assistant';

  @override
  String get noteMarkdownImageHint =>
      'In Markdown mode use `![alt](image URL)` to insert an image';

  @override
  String get noteInsertImage => 'Insert image';

  @override
  String get noteEncryptNote => 'Encrypt this note';

  @override
  String get noteStopEncrypt => 'Turn off encryption';

  @override
  String get notePreview => 'Preview';

  @override
  String get noteContinueEditing => 'Keep editing';

  @override
  String get noteUseMarkdown => 'Edit as Markdown';

  @override
  String get noteBackToRich => 'Back to rich text';

  @override
  String get noteEncryptionOffToast =>
      'Encryption turned off (saved as plain text)';

  @override
  String get noteEncryptionOnToast =>
      'This note will be encrypted on save (the passcode is used locally for encryption only)';

  @override
  String get noteSetPasscode => 'Set an encryption passcode';

  @override
  String get notePasscodeConfirm => 'Confirm passcode';

  @override
  String get notePasscodeMismatch => 'The passcodes do not match';

  @override
  String get notePasscodeMissing => 'Passcode required';

  @override
  String get notePickFromLibrary => 'From gallery';

  @override
  String get noteTakePhoto => 'Take a photo';

  @override
  String get notePickFromFiles => 'From files';

  @override
  String get notePickFromNas => 'From the NAS';

  @override
  String get noteFileStationImages => 'Images in FileStation';

  @override
  String noteImagePickFailed(String error) {
    return 'Couldn\'t pick an image: $error';
  }

  @override
  String get noteThisNote => 'This note';

  @override
  String get noteSummaryEmpty =>
      'The note is empty; write something before summarizing';

  @override
  String get notePassageBody => 'Body';

  @override
  String get noteUseMarkdownTitle => 'Edit as Markdown?';

  @override
  String get noteUseMarkdownKeepSource =>
      'This note will be saved as Markdown: the body stores rendered HTML and the source goes in an HTML comment (the official app and web UI show the formatted version; here you can keep editing the source).';

  @override
  String get noteUseMarkdownImport =>
      'The current content will be placed **as-is** into the Markdown source box (Markdown allows embedded HTML) so nothing is lost; you can rewrite it as Markdown over time.\n\nAfter saving, this note will be a Markdown note.';

  @override
  String get noteBackToRichTitle => 'Back to rich text?';

  @override
  String get noteBackToRichMessage =>
      'The Markdown will be **rendered** into the rich text editor (images/tables appear as rendered results).\n\nNote: after saving, this note no longer carries Markdown source and opens as a plain rich text note.';

  @override
  String get noteSelectNotebookFirst => 'Pick a notebook first';

  @override
  String get noteSaveEncryptNeedsPasscode =>
      'Couldn\'t save: an encrypted note needs a passcode (unlock first)';

  @override
  String get noteSavedOffline =>
      'Saved offline; will sync automatically when online';

  @override
  String get noteMdHint =>
      '# Heading\n\n**bold**, *italic*, `inline code`\n\n- list\n- [ ] to-do\n\n> quote\n\n```\ncode block\n```\n\n| table | col |\n| --- | --- |\n| 1 | 2 |\n';

  @override
  String get noteMdBold => 'Bold';

  @override
  String get noteMdList => 'List';

  @override
  String get noteMdQuote => 'Quote';

  @override
  String get noteMdCode => 'Code block';

  @override
  String get noteMdTable => 'Table';

  @override
  String get noteMdLink => 'Link';

  @override
  String get noteMdH1Tip => '# Heading';

  @override
  String get noteMdBoldTip => '**bold**';

  @override
  String get noteMdListTip => '- item';

  @override
  String get noteMdTodoTip => '- [ ] to-do';

  @override
  String get noteMdQuoteTip => '> quote';

  @override
  String get noteMdLinkTip => '[text](url)';

  @override
  String get noteMdH1Text => '# Heading\n';

  @override
  String get noteMdBoldText => '**bold**';

  @override
  String get noteMdListText => '- item\n- item\n';

  @override
  String get noteMdTodoText => '- [ ] to-do\n';

  @override
  String get noteMdQuoteText => '> quote\n';

  @override
  String get noteMdCodeText => '```\ncode\n```\n';

  @override
  String get noteMdLinkText => '[text](https://)';

  @override
  String noteConflictTitleCount(int n) {
    return 'Sync conflict ($n)';
  }

  @override
  String get noteOpenRecycleFailed => 'Couldn\'t open the recycle bin';

  @override
  String get noteBackToRichConfirm => 'Back to rich text';

  @override
  String noteSaveFailed(String error) {
    return 'Couldn\'t save: $error';
  }

  @override
  String get noteMdTodo => 'To-do';

  @override
  String get fileOfficeNoService =>
      'This NAS doesn\'t have Synology Office (or it isn\'t connected yet)';

  @override
  String get fileOfficeNeedsPassword =>
      'This document has a password; enter it first';

  @override
  String fileOfficeConvertUnsupported(int code) {
    return 'This file can\'t be converted (server error $code)';
  }

  @override
  String get fileOfficeUnrecognized =>
      'Synology Office doesn\'t recognize this file: it is probably not a native Office document (.odoc/.osheet/.oslides). Use \"Convert to Office document\" once first.';

  @override
  String get fileOfficePasswordTitle => 'Document password required';

  @override
  String get fileOfficePasswordBody =>
      'This document has an open password; unlock it before converting.';

  @override
  String fileOfficePasswordBodyNamed(String name) {
    return '\"$name\" has an open password; unlock it before converting.';
  }

  @override
  String get fileOfficePasswordField => 'Password';

  @override
  String get fileFavorited => 'In favorites';

  @override
  String get fileMoreActions => 'More actions';

  @override
  String get fileSharedFolder => 'Shared folder';

  @override
  String fileTodayAt(String time) {
    return 'Today $time';
  }

  @override
  String get fileYesterday => 'Yesterday';

  @override
  String get bookTocTitle => 'Contents';

  @override
  String get bookTocUnit => 'chapters';

  @override
  String bookTocCount(int n, String source) {
    return '$n items · $source';
  }

  @override
  String bookTocCountFiltered(int shown, int total) {
    return '$shown/$total items';
  }

  @override
  String bookTocNoMatch(String query) {
    return 'Nothing in the contents matches \"$query\"';
  }

  @override
  String get bookTocFilterHint => 'Find a chapter in the contents';

  @override
  String get bookUnsupportedFormat => 'This format can\'t be read inline yet';

  @override
  String get bookReasonEncrypted => 'password-protected (encrypted)';

  @override
  String get bookReasonMultiVolume =>
      'a multi-volume archive (all volumes are needed)';

  @override
  String get bookReasonDrm => 'protected by DRM';

  @override
  String get bookReasonCompression =>
      'a compression/coding variant this reader doesn\'t implement yet';

  @override
  String get bookReasonMissingParts =>
      'companion file(s) are missing — send them together';

  @override
  String get bookParseFailed =>
      'Couldn\'t parse this book (the file may be damaged or DRM-protected)';

  @override
  String bookChapterN(int n) {
    return 'Chapter $n';
  }

  @override
  String bookSectionN(int n) {
    return 'Section $n';
  }

  @override
  String bookPageN(int n) {
    return 'Page $n';
  }

  @override
  String pdfPageOutOfRange(int n) {
    return 'Page out of range ($n pages in total)';
  }

  @override
  String pdfTooShortBytes(int n) {
    return 'PDF is too short ($n bytes)';
  }

  @override
  String pdfExtractFailed(String error) {
    return 'Couldn\'t extract text: $error';
  }

  @override
  String pdfTocParseFailed(String error) {
    return 'Couldn\'t parse: $error';
  }

  @override
  String get pdfEncrypted =>
      'The PDF is encrypted; decryption is not attempted';

  @override
  String get pdfNoCatalog => 'No /Catalog found';

  @override
  String get pdfNoPages => 'No pages in the page tree';

  @override
  String get pdfNoTextStreams =>
      'No text in the content streams (probably a scan or pure graphics)';

  @override
  String get fileOpen => 'Open';

  @override
  String get fileOpenFolder => 'Open folder';

  @override
  String get fileDownloadToDevice => 'Download to this device';

  @override
  String get fileDownloadForbidden =>
      'Downloading is disabled by the administrator';

  @override
  String get fileManage => 'Manage';

  @override
  String get fileCopyTo => 'Copy to…';

  @override
  String get fileMoveTo => 'Move to…';

  @override
  String get fileExtractHere => 'Extract here';

  @override
  String get fileAddFavorite => 'Add to favorites';

  @override
  String get fileProperties => 'Properties';

  @override
  String fileExtFile(String ext) {
    return '$ext file';
  }

  @override
  String get filePropPath => 'Path';

  @override
  String filePropSizeWithBytes(String size, String bytes) {
    return '$size ($bytes bytes)';
  }

  @override
  String get filePropModified => 'Modified';

  @override
  String get filePropCreated => 'Created';

  @override
  String get filePropOwner => 'Owner';

  @override
  String get filePropGroup => 'Group';

  @override
  String get filePropMountType => 'Mount type';

  @override
  String get filePropRealPath => 'Real path';

  @override
  String get filePropPerm => 'Read / write';

  @override
  String get filePropNoDownload => 'Download disabled';

  @override
  String get fileWormProtected => 'Protected (read-only)';

  @override
  String get fileServerProbe => 'Measured on the server';

  @override
  String get filePropDiskSize => 'Size on disk';

  @override
  String get fileLoading => 'Loading…';

  @override
  String get filePropRealModified => 'Actual modified time';

  @override
  String fileOwnerUnavailable(String error) {
    return 'Unavailable ($error)';
  }

  @override
  String get fileMd5FailedSome =>
      'Some files can\'t be checksummed (possibly no read permission)';

  @override
  String get fileMd5LostResult =>
      'The server didn\'t keep the result (MD5 tasks live only tens of milliseconds on this DSM); please try again';

  @override
  String get fileCalculating => 'Calculating…';

  @override
  String get fileCopied => 'Copied';

  @override
  String get fileMd5Hint =>
      'Not calculated · computed on the server; large files take a while';

  @override
  String get fileCalculate => 'Calculate';

  @override
  String get fileUploading => 'Uploading…';

  @override
  String get fileContinueInBackground => 'Continue in background';

  @override
  String get filePropOwnerName => 'Owner';

  @override
  String get driveTeamFolders => 'Team folders';

  @override
  String get driveSharedWithMe => 'Shared with me';

  @override
  String get driveMoreTitle => 'Drive more';

  @override
  String driveSectionHud(String section) {
    return 'Synology Drive · $section';
  }

  @override
  String drivePersonalLabels(int n) {
    return '$n personal labels';
  }

  @override
  String get driveManageLabels => 'Manage labels';

  @override
  String get driveLabelsLoadFailed => 'Couldn\'t read labels';

  @override
  String get driveNoLabelsMessage =>
      'Tags in Drive are a many-to-many grouping.\nTap \"Manage labels\" at the top right to create one, or add it from \"⋮ → Labels\" on a file.';

  @override
  String get driveSharedLabel => 'Shared label';

  @override
  String get drivePersonalLabel => 'Personal label';

  @override
  String get driveTrashEmpty => 'The recycle bin is empty';

  @override
  String driveTrashCount(int n) {
    return '$n items';
  }

  @override
  String driveTrashUsage(String size) {
    return 'using $size';
  }

  @override
  String get driveEmptyTrashBody =>
      'Files in the recycle bin will be deleted permanently; this cannot be undone.';

  @override
  String get driveEmptyTrashAction => 'Empty';

  @override
  String get driveTrashEmptied => 'Recycle bin emptied';

  @override
  String driveEmptyTrashFailed(String error) {
    return 'Couldn\'t empty: $error';
  }

  @override
  String get driveTrashEmptyMessage =>
      'Files deleted from \"My Drive\" land here first;\nthey are really gone only after you empty the bin.';

  @override
  String get driveNoStarredTitle => 'No starred files yet';

  @override
  String get driveNoStarredMessage =>
      'Star a file in \"My Drive\" and it shows up here for quick access.';

  @override
  String get driveNoSharedTitle => 'Nothing shared with you';

  @override
  String get driveNoSharedMessage =>
      'Files other people share with you through Drive show up here.';

  @override
  String get driveNoTeamTitle => 'No team folders';

  @override
  String get driveNoTeamMessage =>
      'Team folders are created by an administrator in the Drive admin console; the parts you can see show up here.';

  @override
  String get driveListOpenFailed => 'Couldn\'t open this list';

  @override
  String get driveDeleted => 'Deleted';

  @override
  String get driveEmptyTrashConfirm => 'Empty the recycle bin?';

  @override
  String driveLabelCreated(String name) {
    return 'Label \"$name\" created';
  }

  @override
  String driveLabelRenamed(String name) {
    return 'Renamed to \"$name\"';
  }

  @override
  String get driveLabelColorUpdated => 'Color updated';

  @override
  String get driveDeleteLabelConfirm => 'Delete label?';

  @override
  String driveDeleteLabelBody(String name) {
    return '\"$name\" will be removed from all files (the files themselves are unaffected).';
  }

  @override
  String driveLabelDeleted(String name) {
    return 'Deleted \"$name\"';
  }

  @override
  String get driveLabelsHud => 'Synology Drive · Personal labels';

  @override
  String get driveNoLabelsManageMessage =>
      'Labels in Drive are a many-to-many grouping:\na file can have several labels; tap the + at the top right to create one.';

  @override
  String get driveChangeColor => 'Change color';

  @override
  String get driveLabelsHudFiles => 'Synology Drive · Files under this label';

  @override
  String get driveLabelOpenFailed => 'Couldn\'t open this label';

  @override
  String get driveLabelNoFiles => 'No files under this label yet';

  @override
  String get driveLabelNoFilesMessage =>
      'Add it to this label from \"⋮ → Labels\" on the file.';

  @override
  String get driveLabelsUpdated => 'Labels updated';

  @override
  String driveLabelPickerTitle(String name) {
    return 'Labels · $name';
  }

  @override
  String driveLabelPickerReadFailed(String error) {
    return 'Couldn\'t read labels: $error';
  }

  @override
  String get driveCreateLabelAndCheck => 'New label and check it';

  @override
  String get driveChooseColor => 'Choose a color';

  @override
  String get fileTasksLoadFailed => 'Couldn\'t read the tasks';

  @override
  String get fileNoTasks => 'No background tasks';

  @override
  String get driveTasksEmptyMessage =>
      'Synology Drive upload/download/transfer tasks show up here.\nCopy and compress tasks on NAS folders are under \"NAS files\".';

  @override
  String get driveTaskRemove => 'Remove from list';

  @override
  String get driveTaskStopAndRemove => 'Stop and remove';

  @override
  String driveTaskDeleteFailed(String error) {
    return 'Couldn\'t delete the task: $error';
  }

  @override
  String driveSharedWith(String name) {
    return 'Shared with $name';
  }

  @override
  String driveRoleChanged(String name, String role) {
    return 'Changed $name to \"$role\"';
  }

  @override
  String get driveRemoveShareConfirm => 'Remove sharing?';

  @override
  String driveRemoveShareBody(String name, String entry) {
    return 'After removal, $name can no longer access \"$entry\".';
  }

  @override
  String get driveRemoveShareAction => 'Remove';

  @override
  String driveRemovedShare(String name) {
    return 'Removed $name';
  }

  @override
  String get driveInvite => 'Invite';

  @override
  String get drivePublicLink => 'Public link';

  @override
  String get drivePermanentLink => 'Permanent open link';

  @override
  String get drivePermanentLinkNote =>
      'This is the file\'s permanent address and cannot be turned off here. To stop anonymous access, close the public link under \"Manage public sharing\".';

  @override
  String get driveManagePublicSharing => 'Manage public sharing';

  @override
  String get driveNoPublicLink =>
      'Couldn\'t get the file link (you may not have sharing permission)';

  @override
  String get driveOpenInBrowser => 'Open in browser';

  @override
  String get driveRefreshForLink =>
      'Tap refresh at the top right to fetch the link again';

  @override
  String get driveSharedWithSection => 'Shared with';

  @override
  String get driveSharesLoadFailed => 'Couldn\'t read the shared members';

  @override
  String get driveNoShares => 'Not shared with anyone yet';

  @override
  String get driveNoSharesMessage =>
      'Only you can access it.\nTap \"Invite\" at the top right to share this file with other accounts on the NAS.';

  @override
  String get driveInheritedFromParent => 'Inherited from the parent folder';

  @override
  String get driveChangePermission => 'Change permission';

  @override
  String get driveSearchPrincipalsHint => 'Search users or groups';

  @override
  String driveSearchPrincipalsFailed(String error) {
    return 'Couldn\'t search accounts: $error';
  }

  @override
  String get driveNoMatchingAccount => 'No matching accounts';

  @override
  String get driveChoosePermission => 'Choose a permission';

  @override
  String drivePrincipalWithNickname(String name, String nickname) {
    return '$name ($nickname)';
  }

  @override
  String fileDownloadFailed(String error) {
    return 'Download failed: $error';
  }

  @override
  String driveDownloaded(String name) {
    return 'Downloaded: $name';
  }

  @override
  String get driveRestoreConfirm => 'Restore to this version?';

  @override
  String driveRestoreRevBody(String time, String size) {
    return 'The version from $time ($size) will become the current content.\nRestoring also creates a new version, so old versions are not lost.';
  }

  @override
  String get driveRestore => 'Restore';

  @override
  String get driveRestoredPending =>
      'Restored; it takes a few seconds to take effect';

  @override
  String get driveRevisionsOpenFailed => 'Couldn\'t open version history';

  @override
  String get driveNoRevisionsMessage =>
      'This file has only one current content.\nDrive keeps older versions after a file is overwritten.';

  @override
  String get driveVersionCurrent => 'Current';

  @override
  String driveVersionId(String id) {
    return 'Version $id';
  }

  @override
  String get driveDownloadVersion => 'Download this version';

  @override
  String get driveRestoreVersion => 'Restore to this version';

  @override
  String get driveOfficeNoRevisionsMessage =>
      'Synology Office documents record a version every time an edit is saved.';

  @override
  String driveOfficeHud(String name) {
    return 'Synology Office · $name';
  }

  @override
  String driveFileHud(String name) {
    return 'Synology Drive · $name';
  }

  @override
  String driveOfficeRestoreBody(String label) {
    return '\"$label\" will become the current content; restoring also leaves a record, so old versions are not lost.';
  }

  @override
  String driveOfficeRestoreBodyAt(String label, String time) {
    return '\"$label\" will become the current content; ($time) restoring also leaves a record, so old versions are not lost.';
  }

  @override
  String driveRestoreFailed(String error) {
    return 'Couldn\'t restore: $error';
  }

  @override
  String get driveNoNodeId =>
      'The server didn\'t provide this document\'s internal id, so versions can\'t be named right now';

  @override
  String get driveVersionNameEdit => 'Change version name';

  @override
  String get driveVersionNameNew => 'Create version name';

  @override
  String get driveVersionNameHint => 'Version name';

  @override
  String get driveVersionNameHelper =>
      'Once named, this version is not cleaned up automatically (an empty name reverts it to an automatic version)';

  @override
  String get driveVersionAutoRestored => 'Reverted to an automatic version';

  @override
  String driveVersionNamed(String name) {
    return 'Named \"$name\"';
  }

  @override
  String driveVersionRenameFailed(String error) {
    return 'Couldn\'t name it: $error';
  }

  @override
  String driveVersionEditors(int n) {
    return 'Edited by $n people';
  }

  @override
  String get driveVersionFirst => 'Initial version';

  @override
  String get driveNameVersion => 'Name this version';

  @override
  String get driveExportVersion => 'Export this version';

  @override
  String driveExported(String name) {
    return 'Exported: $name';
  }

  @override
  String driveExportFailed(String error) {
    return 'Couldn\'t export: $error';
  }

  @override
  String get fileSearchTitle => 'Search files';

  @override
  String get fileSearchHint => 'File name keyword, e.g. report';

  @override
  String get fileSearchFailed => 'Search failed';

  @override
  String get fileNoMatches => 'No matching files';

  @override
  String get fileNoMatchesHint =>
      'Not the file you expected? The server\'s file index can lag — try Search NAS globally above.';

  @override
  String get fileSearchPrompt => 'Type a keyword to start searching';

  @override
  String get fileSearchScope => 'Scope: shared folders you have permission for';

  @override
  String get fileSearchStillRunning => 'Search is still running';

  @override
  String get fileSearchStillRunningMessage =>
      'The server hasn\'t finished searching this scope. Retry to keep waiting — results may still appear.';

  @override
  String get fileFavoritesLoadFailed => 'Couldn\'t read favorites';

  @override
  String get fileNoFavoritesMessage =>
      'Choose \"Add to favorites\" in the file action menu';

  @override
  String get fileShareLinksTitle => 'Share links';

  @override
  String get fileCleanInvalidLinks => 'Clean up invalid links';

  @override
  String get fileShareLinksLoadFailed => 'Couldn\'t read share links';

  @override
  String get fileNoShareLinks => 'No share links';

  @override
  String get fileNoShareLinksMessage =>
      'Choose \"Create share link\" in the file action menu';

  @override
  String get fileLinkInvalid => 'Expired';

  @override
  String get fileLinkHasPassword => 'Password protected';

  @override
  String fileLinkExpiresAt(String date) {
    return 'until $date';
  }

  @override
  String get fileDeleteLink => 'Delete link';

  @override
  String get fileLinkDetail => 'Share link details';

  @override
  String get fileLinkDetailServer => 'Server details';

  @override
  String fileLinkDetailFailed(String reason) {
    return 'Cannot load details: $reason';
  }

  @override
  String get fileLinkDetailRetry => 'Retry';

  @override
  String get fileLinkDetailMissing =>
      'The server returned no details for this link';

  @override
  String get fileLinkCopyLink => 'Copy link';

  @override
  String get fileLinkCopied => 'Link copied';

  @override
  String get fileLinkQrcode => 'QR code';

  @override
  String get fileLinkStatus => 'Status';

  @override
  String get fileLinkValid => 'Valid';

  @override
  String get fileLinkStartAt => 'Starts';

  @override
  String get fileLinkOwner => 'Owner';

  @override
  String get fileLinkId => 'Link ID';

  @override
  String get fileLinkKindFolder => 'Folder';

  @override
  String get fileLinkKindFile => 'File';

  @override
  String get fileLinkYes => 'Yes';

  @override
  String get fileLinkExpiryLabel => 'Valid until';

  @override
  String get fileLinkFieldUnknown => 'Not returned by the server';

  @override
  String get fileLinkNo => 'No';

  @override
  String get fileCleanFinished => 'Clear finished';

  @override
  String get fileNoTasksMessage =>
      'Compress / extract / copy-move / size calculation all show up here';

  @override
  String fileTasksFailedCount(int n) {
    return '$n files failed';
  }

  @override
  String fileTaskElapsedMinutes(int n) {
    return 'Running for $n min';
  }

  @override
  String fileTaskElapsedHours(int h, int m) {
    return 'Running for $h h $m min';
  }

  @override
  String get fileArchiveContents => 'View archive contents';

  @override
  String get fileArchiveContentsEmpty => 'This archive has no entries';

  @override
  String fileArchiveContentsFailed(String reason) {
    return 'Cannot read the archive: $reason';
  }

  @override
  String get fileArchiveContentsPasswordRetry => 'Enter password and retry';

  @override
  String fileArchiveContentsCount(int n) {
    return '$n entries';
  }

  @override
  String get fileStopTask => 'Stop task';

  @override
  String get driveConnectHint => 'Connect to the NAS to browse \"My Drive\"';

  @override
  String get fileOpenDirFailed => 'Couldn\'t open this directory';

  @override
  String get fileEmptyDir => 'This directory is empty';

  @override
  String get driveEmptyPersonal =>
      'No files in the personal space (/mydrive) yet';

  @override
  String get driveMyDrive => 'My Drive';

  @override
  String get driveStar => 'Star';

  @override
  String get driveUnstar => 'Unstar';

  @override
  String driveDownloadAs(String format) {
    return 'Download as $format';
  }

  @override
  String get driveConvertToOffice => 'Convert to Office document';

  @override
  String driveRenamed(String name) {
    return 'Renamed to $name';
  }

  @override
  String get driveDeleteConfirm => 'Delete?';

  @override
  String driveDeleteBody(String name) {
    return '\"$name\" goes to the Drive recycle bin and can be restored later.';
  }

  @override
  String driveDeletedItem(String name) {
    return 'Deleted $name';
  }

  @override
  String driveConverted(String name) {
    return 'Converted to $name (it will appear in the list shortly)';
  }

  @override
  String driveConvertFailed(String error) {
    return 'Couldn\'t convert: $error';
  }

  @override
  String get fileNewFolderHint => 'Plain folder';

  @override
  String get fileNewFolder => 'New folder';

  @override
  String get driveUploadFileTitle => 'Upload file';

  @override
  String get driveUploadSheetSubtitle =>
      'Put it in your personal space; Drive indexes it within a second or two';

  @override
  String driveCreateInPath(String path) {
    return 'Created under \"$path\"';
  }

  @override
  String driveCreated(String name) {
    return 'Created $name';
  }

  @override
  String get driveUploadNotPersonal =>
      'This location is not the personal space, so you can\'t upload from here yet';

  @override
  String driveUploadedIndexing(String name) {
    return 'Uploaded $name (Drive takes a second or two to index)';
  }

  @override
  String get fileCacheReadFailed => 'Couldn\'t read the cache';

  @override
  String get fileNewUpload => 'New / Upload';

  @override
  String get fileNewUploadSemantic => 'New or upload';

  @override
  String get fileOpenLocationFailed => 'Couldn\'t open this location';

  @override
  String get fileNoSharedFolders => 'No accessible shared folders';

  @override
  String get fileNoSharedFoldersMessage =>
      'This NAS has no shared folders you have permission for';

  @override
  String get fileEmptyFolder => 'This folder is empty';

  @override
  String get fileWideEmptyTitle => 'Nothing selected yet';

  @override
  String get fileWideEmptyMessage =>
      'Click to select on the left; double-click (or press Enter) to open. Details show here';

  @override
  String get fileWideOpenPreview => 'Open preview';

  @override
  String get fileWideOpenFolder => 'Open folder';

  @override
  String fileWideFolderItems(int n) {
    return '$n items';
  }

  @override
  String get fileWideContentsFailed => 'Couldn\'t read this folder\'s contents';

  @override
  String fileDownloadCount(int n) {
    return 'Download $n items';
  }

  @override
  String get fileDownloadCountMessage =>
      'They will be downloaded one by one to the app downloads folder; this may take a while.';

  @override
  String get fileStartDownload => 'Start download';

  @override
  String get fileRenameHelper => 'Cannot contain /';

  @override
  String get fileTargetFolderHint => 'Full path of the destination folder';

  @override
  String get fileTargetFolderExample => 'e.g. /home/Drive/backup';

  @override
  String get fileTaskSubmitted => 'Task submitted';

  @override
  String get fileTaskSubmittedWithTip =>
      'Task submitted; check progress under \"Tasks\"';

  @override
  String get fileArchiveDefaultName => 'Archive';

  @override
  String get fileStartCompress => 'Start compression';

  @override
  String get fileArchiveNameHint => 'Archive file name';

  @override
  String get fileCreateInCurrentDir =>
      'It will be created in the current folder';

  @override
  String get fileCompressSubmitted =>
      'Compression task submitted; check progress under \"Tasks\"';

  @override
  String fileExtractConfirmBody(String name) {
    return 'Extract $name into a folder of the same name in the current folder?';
  }

  @override
  String get fileExtractSubmitted => 'Extract task submitted';

  @override
  String get fileDirSize => 'Calculate folder size';

  @override
  String get fileDirSizeSubmitted => 'Size calculation task submitted';

  @override
  String fileDirSizeSubmittedId(String id) {
    return 'Size calculation task submitted ($id)';
  }

  @override
  String fileDeleteCount(int n) {
    return 'Delete $n items';
  }

  @override
  String fileDeleteOneConfirm(String name) {
    return 'Delete \"$name\"? This cannot be undone.';
  }

  @override
  String fileDeleteManyConfirm(int n) {
    return 'Delete these $n items? This cannot be undone.';
  }

  @override
  String get fileDeleted => 'Deleted';

  @override
  String get fileDownloadedToDownloads => 'Downloaded to the downloads folder';

  @override
  String fileUploadFromDevice(String target) {
    return 'Pick a file from this device and upload it to \"$target\"';
  }

  @override
  String fileUploaded(String name) {
    return 'Uploaded $name';
  }

  @override
  String get fileSortTitle => 'Sort by';

  @override
  String fileSelectedCount(int n) {
    return '$n selected';
  }

  @override
  String get fileSelectAll => 'Select all / clear';

  @override
  String get fileGridViewSwitch => 'Switch to list view';

  @override
  String get fileListViewSwitch => 'Switch to thumbnail view';

  @override
  String get fileSourceNas => 'NAS files';

  @override
  String get fileShareDisabled => 'Share links disabled';

  @override
  String fileStaleCache(String detail) {
    return 'Showing cached content: $detail';
  }

  @override
  String get fileSharedFoldersRoot => 'Shared folders';

  @override
  String get sortBySize => 'Size';

  @override
  String get sortByModified => 'Date modified';

  @override
  String get sortByOwner => 'Owner';

  @override
  String get sortByGroup => 'Group';

  @override
  String get sortByType => 'Type';

  @override
  String get sortByCreated => 'Date created';

  @override
  String get fileOfficeExport => 'Office export';

  @override
  String get fileUnknownReason => 'Unknown reason';

  @override
  String get fileEmptyFile => 'This file is empty';

  @override
  String get fileImageDecodeFailed => 'Couldn\'t decode this image';

  @override
  String get fileImageGestureHint =>
      'Double-tap to zoom / double-tap again to reset · pinch to zoom';

  @override
  String fileImageTooBig(String size) {
    return 'This image is $size, too large to display inline';
  }

  @override
  String get fileImageTooBigHint =>
      'Use \"Download\" or \"Open with another app\" at the top right to view the original';

  @override
  String fileTextHeadOnly(int kb, String size) {
    return 'Showing only the first $kb KB (file is $size)';
  }

  @override
  String get fileMediaPause => 'Pause';

  @override
  String get fileMediaPlay => 'Play';

  @override
  String get fileOfficeExtractHint =>
      '(Office body text is extracted on the server; it requires Synology Office on this NAS and the file to be in the Drive index)';

  @override
  String get fileOfficeEmptyBody =>
      'The server extracted an empty body: the document itself is empty, or its body is all images. Synology Office files (.odoc/.osheet/.oslides) can be downloaded and opened in the official Office app';

  @override
  String fileOfficeReadonlyBody(int n) {
    return 'Read-only · server-extracted body ($n characters)';
  }

  @override
  String get fileOfficeNotIndexed =>
      'Office body extraction on this NAS only works for files in the Drive index. Put the file in \"My Drive\" (or add its folder to Synology Drive) to read the body here; for now it will be opened in the system Office app.';

  @override
  String get fileWhyVideo =>
      'Video is most reliable in the system player (no inline decoding)';

  @override
  String get fileWhyPdf => 'PDF goes to the system or a third-party reader';

  @override
  String get fileWhyOffice =>
      'Office documents open in the system WPS/Office app';

  @override
  String get fileWhyArchive =>
      'Archives must be extracted before you can view their contents';

  @override
  String get fileWhyOther => 'This kind of file opens in a system app';

  @override
  String get fileOpenFailed => 'Couldn\'t open this file';

  @override
  String get pdfNoExtractableText =>
      'This PDF has no extractable text (it may be a scan), so AI cannot read it';

  @override
  String get pdfPrevPage => 'Previous page';

  @override
  String get pdfNextPage => 'Next page';

  @override
  String pdfPageOfTotal(int page, int total) {
    return 'Page $page of $total';
  }

  @override
  String get pdfLinuxNoPoppler =>
      'This computer has no PDF renderer yet. Install poppler-utils (which provides pdftoppm) and reopen this file.';

  @override
  String pdfPageN(int n) {
    return 'Page $n';
  }

  @override
  String get pdfAskTitle => 'Ask this PDF';

  @override
  String get pdfAskHint =>
      'Ask about this PDF, e.g. \"What is the conclusion?\"';

  @override
  String pdfParseFailed(String error) {
    return 'PDF parsing failed: $error';
  }

  @override
  String get pdfParsing => 'Parsing PDF…';

  @override
  String pdfOpenFailedDetail(String error) {
    return 'Couldn\'t open this PDF\n$error';
  }

  @override
  String get readerPrevPage => 'Previous page';

  @override
  String get readerNextPage => 'Next page';

  @override
  String pdfPageOf(int page, int total) {
    return 'Page $page / $total';
  }

  @override
  String get pdfBookmark => 'Bookmarks';

  @override
  String get pdfLoading => 'Loading PDF…';

  @override
  String get pdfOpenFailed => 'Couldn\'t open this PDF';

  @override
  String get bookOpenFailed => 'Couldn\'t open this book';

  @override
  String get bookServerNoContent => 'The server returned no content.';

  @override
  String get bookCannotRead => 'This book can\'t be read inline yet';

  @override
  String get bookDownloadHint =>
      'You can download it from the top right and open it in another app.';

  @override
  String get bookUntitled => 'Untitled';

  @override
  String bookAiLabel(String title, int n) {
    return '\"$title\" · Chapter $n';
  }

  @override
  String bookAiLabelNamed(String title, int n, String chapter) {
    return '\"$title\" · Chapter $n $chapter';
  }

  @override
  String get bookThisBook => 'This book';

  @override
  String bookChapterOf(String format, int n, int total) {
    return '$format · Chapter $n/$total';
  }

  @override
  String get bookTools => 'Reading tools';

  @override
  String get bookPrevChapter => 'Previous chapter';

  @override
  String get bookNextChapter => 'Next chapter';

  @override
  String get bookSearchTool => 'Search in book';

  @override
  String get bookSearchToolSubtitle =>
      'Find words in the whole book; tap a result to jump there';

  @override
  String get bookMarks => 'Bookmarks / highlights';

  @override
  String get bookMarksSubtitle =>
      'Bookmark the current position, or view saved ones';

  @override
  String get readerPrefsTitle => 'Reading settings';

  @override
  String get readerPrefsSubtitle => 'Font size / line spacing / background';

  @override
  String get bookSearchHint =>
      'Search for words in the book (Chinese supported)';

  @override
  String bookSearchHits(int n) {
    return '$n matches';
  }

  @override
  String get bookSearchPrompt =>
      'Type a word to search (this chapter and the whole book are on this device)';

  @override
  String bookSearchNoMatch(String query) {
    return 'No matches for \"$query\"';
  }

  @override
  String bookChapterTitleLine(int n, String title) {
    return 'Chapter $n · $title';
  }

  @override
  String get bookNoteTitle => 'Note';

  @override
  String get bookNoteHint => 'Write your own note (may be empty)';

  @override
  String bookMarksCount(int n) {
    return '$n entries';
  }

  @override
  String bookAddMarkAt(int n, int pct) {
    return 'Bookmark the current position in chapter $n ($pct%)';
  }

  @override
  String get bookNoMarks => 'No bookmarks yet';

  @override
  String get bookNoExcerpt => '(no excerpt)';

  @override
  String bookNotePrefix(String note) {
    return 'Note: $note';
  }

  @override
  String get bookMarkActions => 'Bookmark actions';

  @override
  String get bookEditNote => 'Edit note';

  @override
  String get bookWriteNote => 'Write note';

  @override
  String get readerPrefsGlobal => 'Applies to the whole book';

  @override
  String get readerFontSize => 'Font size';

  @override
  String get readerFontSmaller => 'Smaller';

  @override
  String get readerFontBigger => 'Larger';

  @override
  String get readerLineHeight => 'Line spacing';

  @override
  String readerLineHeightValue(String n) {
    return '$n×';
  }

  @override
  String get readerBackground => 'Background';

  @override
  String get readerThemeFollow => 'Follow theme';

  @override
  String get readerThemeSepia => 'Sepia';

  @override
  String get readerThemeNight => 'Night';

  @override
  String get readerJustify => 'Justify';

  @override
  String get readerJustifySubtitle =>
      'Long Chinese paragraphs may show large gaps; off by default';

  @override
  String get bookOwnToc => 'Book\'s own contents';

  @override
  String get aiExplain => 'Explain';

  @override
  String get aiTranslate => 'Translate';

  @override
  String get bookMissingImage => '(illustration missing)';

  @override
  String bookMissingImageNamed(String path) {
    return '(illustration missing: $path)';
  }

  @override
  String get bookBodyText => 'Body text';

  @override
  String get driveRenameHelper =>
      'Renaming sends only the changed fields to the server (official v2 behaviour)';

  @override
  String get fileSortTooltip => 'Sort';

  @override
  String get chatSystemMessage => 'System message';

  @override
  String chatSystemMessageEvent(String event) {
    return 'System message ($event)';
  }

  @override
  String chatSysJoined(String names) {
    return '$names joined this channel.';
  }

  @override
  String chatSysGuestJoined(String actor, String guest, String suffix) {
    return '$actor\'s guest $guest$suffix joined this channel.';
  }

  @override
  String chatSysInvited(String actor, String names) {
    return '$actor invited $names to this channel.';
  }

  @override
  String chatSysLeft(String names) {
    return '$names left this channel.';
  }

  @override
  String chatSysMemberRemoved(String actor, String names) {
    return '$actor removed $names from the member list.';
  }

  @override
  String chatSysYouRemoved(String channel) {
    return 'You were removed from the member list of $channel.';
  }

  @override
  String chatSysGuestInvited(String actor, String email) {
    return '$actor invited the guest $email.';
  }

  @override
  String chatSysChannelRenamed(String name) {
    return 'The channel name was changed to $name.';
  }

  @override
  String chatSysChannelDescChanged(String name) {
    return 'The channel description was changed to $name.';
  }

  @override
  String get chatSysConversationPromoted =>
      'The conversation was converted to a private channel.';

  @override
  String get chatSysChannelUpdated => 'The channel information was updated.';

  @override
  String chatSysChannelArchived(String channel, String who) {
    return 'Channel $channel was archived by $who.';
  }

  @override
  String chatSysChannelClosed(String channel, String reason) {
    return 'Channel $channel was closed. Reason: $reason';
  }

  @override
  String chatSysYouRevived(String actor, String channel) {
    return 'You were restored by $actor. You can now return to $channel.';
  }

  @override
  String chatSysRevived(String names, String actor) {
    return '$names was restored by $actor.';
  }

  @override
  String chatSysGuestKicked(String actor, String names) {
    return '$actor removed the guest $names from this channel.';
  }

  @override
  String chatSysEncryptEnabled(String app) {
    return 'Hello! Channel encryption is now enabled in $app. Encrypted channels let you protect information stored on your Synology NAS with a private passphrase. Everything in an encrypted channel is stored safely on the server and cannot be read by administrators. To start using encrypted channels, set a passphrase. Tap here to set your own passphrase.';
  }

  @override
  String get chatSysEncryptDisabled =>
      'Encrypted channels were disabled by an administrator. All encrypted channels were archived and closed.';

  @override
  String chatSysEncryptInvited(String who) {
    return 'Hello! $who invited you to use channel encryption. Tap here to set your own passphrase.';
  }

  @override
  String get chatSysUserBroken =>
      'Cannot enter this channel; its permissions must be restored by another user.';

  @override
  String get chatSysKeyReset => 'Your private key was reset.';

  @override
  String get chatSysThreadCreated => 'A post was created.';

  @override
  String chatSysCommentCreated(String actor) {
    return '$actor commented on the post.';
  }

  @override
  String get chatSysPostPinned => 'Pinned this message';

  @override
  String get chatSysVoteClosed => 'The poll is now closed.';

  @override
  String get chatSysVoteUpdated => 'The poll was updated.';

  @override
  String chatSysBotAdded(String actor, String names) {
    return '$actor added the integration $names';
  }

  @override
  String chatSysBotDeleted(String actor, String names) {
    return '$actor removed the integration $names.';
  }

  @override
  String chatSysBotReset(String names) {
    return '$names was reset';
  }

  @override
  String get chatSysUser => 'System user';

  @override
  String chatSysBotDisabled(String who, String names) {
    return '$who disabled the integration $names.';
  }

  @override
  String chatSysBotEnabled(String names, String who) {
    return 'The integration $names was enabled by $who.';
  }

  @override
  String chatSysWelcome(String who) {
    return 'Hello, $who,\nthis is your private space. You can write messages here or keep any files and links you may need later.';
  }

  @override
  String get chatSysCommandFailed => 'The command failed.';

  @override
  String chatUserFallback(int id) {
    return 'User $id';
  }

  @override
  String chatGuestSuffix(String name) {
    return '$name (guest)';
  }

  @override
  String get chatSomeUser => 'Someone';

  @override
  String chatConversationMembers(int count) {
    return 'Conversation ($count people)';
  }

  @override
  String chatChannelHash(int id) {
    return 'Channel #$id';
  }

  @override
  String get chatThisChannel => 'this channel';

  @override
  String get chatSysCloseAllUserBroken => 'No user can enter this channel.';

  @override
  String chatSysCloseUserDeleted(String user) {
    return 'User $user was deleted.';
  }

  @override
  String get chatSysCloseAdminToggle =>
      'This action was triggered by an administrator.';

  @override
  String chatSysCloseByUser(String user) {
    return '$user closed this channel.';
  }

  @override
  String get chatSubjectMessage => 'message';

  @override
  String chatSysPostDeleted(
    String who,
    String channel,
    String subject,
    String what,
  ) {
    return '$who deleted $what in your $subject in channel $channel.';
  }

  @override
  String get chatNameRequired => 'Channel name cannot be empty.';

  @override
  String get chatNameInvalid =>
      'Spaces and special characters are not allowed.';

  @override
  String get chatErrNotLoggedIn =>
      'Not signed in; cannot open the realtime channel';

  @override
  String chatErrRealtimeNotReady(String error) {
    return 'Realtime channel not ready: $error';
  }

  @override
  String get chatErrNoConnId =>
      'The realtime connection is not up yet, so this channel cannot be closed now - please retry shortly.';

  @override
  String chatErrEncryptAttachmentFailed(String error) {
    return 'Could not encrypt the attachment: $error';
  }

  @override
  String chatLoadMessagesFailed(String error) {
    return 'Failed to load messages: $error';
  }

  @override
  String chatLoadOlderFailed(String error) {
    return 'Failed to load earlier messages: $error';
  }

  @override
  String get chatSendFailedKept =>
      'Send failed. The message is still in the list — long-press to resend.';

  @override
  String chatSlashCommandNotFound(String command) {
    return 'No such command: /$command';
  }

  @override
  String get chatStickerSendFailed => 'Failed to send sticker';

  @override
  String get chatAddHashtag => 'Add hashtag';

  @override
  String get chatHashtagNameHint => 'Hashtag name (without #)';

  @override
  String get chatAdd => 'Add';

  @override
  String get chatAddHashtagFailed => 'Failed to add hashtag';

  @override
  String get chatRemoveHashtagWhich => 'Which hashtag do you want to remove?';

  @override
  String get chatRemoveHashtagFailed => 'Failed to remove hashtag';

  @override
  String get chatReminderFuture => 'The reminder must be set in the future';

  @override
  String get chatSetReminderFailed => 'Failed to set the reminder';

  @override
  String get chatCreateVoteFailed =>
      'Failed to create the poll (you may be sending too frequently)';

  @override
  String chatScheduledOk(String time) {
    return 'Scheduled ($time)';
  }

  @override
  String get chatScheduleFailed =>
      'Failed to schedule (you may be sending too frequently)';

  @override
  String get chatVoiceSendFailed =>
      'Failed to send the voice message (you may be sending too frequently — try again later)';

  @override
  String get chatRealtimeNotReady => 'Realtime channel not ready';

  @override
  String get chatAddToConversation => 'Add to conversation';

  @override
  String get chatAttachGallery => 'Photo library';

  @override
  String chatFileTooLarge(int limit) {
    return 'File size limit exceeded (max $limit MB).';
  }

  @override
  String chatUploading(String name) {
    return 'Uploading $name';
  }

  @override
  String get chatUploadFailed =>
      'Upload failed (you may be sending too frequently — try again later)';

  @override
  String get chatResendFailedAttachmentGone =>
      'Failed to resend (the attachment may no longer be available locally)';

  @override
  String get chatOperationFailed => 'Operation failed, try again later';

  @override
  String get chatConnectionStatus => 'Connection status';

  @override
  String get chatRealtimeConnected => 'Realtime channel connected';

  @override
  String get chatRealtimeDisconnected => 'Realtime channel disconnected';

  @override
  String get chatRealtimePushHint =>
      'You can still send messages, but realtime push is unavailable';

  @override
  String get chatSyncSyncing => 'Syncing';

  @override
  String get chatSyncDone => 'Sync complete';

  @override
  String get chatSyncDegraded => 'Degraded (lists still work)';

  @override
  String chatSyncCounts(int channels, int users) {
    return '$channels channels · $users users';
  }

  @override
  String get chatLastError => 'Last error';

  @override
  String get chatResyncNow => 'Resync now';

  @override
  String get chatDiagnostics => 'Hole-punching diagnostics';

  @override
  String get chatResendFailed => 'Failed to resend';

  @override
  String get chatClearReminderFailed => 'Failed to clear the reminder';

  @override
  String get chatDeleteFailed => 'Failed to delete';

  @override
  String chatSavedToDownloads(String name) {
    return 'Saved to Downloads: $name';
  }

  @override
  String get chatForwardTo => 'Forward to';

  @override
  String get chatForward => 'Forward';

  @override
  String get chatForwarded => 'Forwarded';

  @override
  String get chatForwardFailed => 'Failed to forward';

  @override
  String get chatNoInvitableUsers => 'No users available to invite';

  @override
  String chatInvitedUser(String name) {
    return 'Invited $name';
  }

  @override
  String get chatInviteFailed => 'Failed to invite';

  @override
  String chatChannelSemantic(String name) {
    return 'Channel: $name';
  }

  @override
  String get chatSearchInChannel => 'Search in this channel';

  @override
  String get chatNoMessages => 'No messages yet';

  @override
  String get chatNoMessagesHint =>
      'Send the first message to start the conversation';

  @override
  String get chatBackToLatest => 'Back to latest';

  @override
  String chatBackToLatestUnread(int count) {
    return 'Back to latest — $count new messages below';
  }

  @override
  String get chatTypePublic => 'Public';

  @override
  String get chatTypePrivate => 'Private';

  @override
  String get chatTypeAnonymous => 'Anonymous';

  @override
  String get chatTypeBot => 'Bot';

  @override
  String get chatChannel => 'Channel';

  @override
  String get chatDayBeforeYesterday => 'Day before yesterday';

  @override
  String chatWeekday(String name) {
    return '$name';
  }

  @override
  String get chatWeekdayMon => 'Monday';

  @override
  String get chatWeekdayTue => 'Tuesday';

  @override
  String get chatWeekdayWed => 'Wednesday';

  @override
  String get chatWeekdayThu => 'Thursday';

  @override
  String get chatWeekdayFri => 'Friday';

  @override
  String get chatWeekdaySat => 'Saturday';

  @override
  String get chatWeekdaySun => 'Sunday';

  @override
  String chatDateMonthDay(int month, int day) {
    return '$month/$day';
  }

  @override
  String chatDateFull(int year, int month, int day) {
    return '$month/$day/$year';
  }

  @override
  String get chatNewMessagesBelow => 'New messages below';

  @override
  String chatTypingUser(String name) {
    return '$name is typing';
  }

  @override
  String get chatTypingOne => '1 person is typing';

  @override
  String chatTypingMany(int count) {
    return '$count people are typing';
  }

  @override
  String get chatRealtimeDegraded =>
      'Realtime channel is degraded — tap for details';

  @override
  String get chatRealtimeOffline => 'Realtime disconnected';

  @override
  String get chatSearchThisChannel => 'Search this channel';

  @override
  String get chatMembersBroken => 'Members (some can\'t decrypt)';

  @override
  String get chatInvite => 'Invite';

  @override
  String get chatMediaPhotosVideos => 'Photos & videos';

  @override
  String get chatPinnedMessages => 'Pinned messages';

  @override
  String get chatAllFiles => 'All files';

  @override
  String get chatAllLinks => 'All links';

  @override
  String get chatMentions => 'Mentions';

  @override
  String get chatScheduledInfo => 'Scheduled messages';

  @override
  String get chatHashtags => 'Hashtags';

  @override
  String get chatNotifications => 'Notifications';

  @override
  String get chatChannelManage => 'Channel management';

  @override
  String get chatE2eeUnlocked => 'End-to-end encryption (unlocked)';

  @override
  String get chatE2eeLockedHint =>
      'This encrypted channel is locked — enter the passphrase to read it';

  @override
  String get chatE2eeKeyUnreadable =>
      'This channel\'s key cannot be decrypted (the key pair was replaced, or it wasn\'t sealed for you)';

  @override
  String chatAvatarSemantic(String name) {
    return '$name\'s avatar';
  }

  @override
  String get chatThreadReply => '↳ Thread reply';

  @override
  String get chatSendFailedRetry => 'Send failed · Retry';

  @override
  String get chatPinned => 'Pinned';

  @override
  String chatReplyCount(int count) {
    return '$count replies';
  }

  @override
  String chatHashtagTapHint(String tag) {
    return 'Hashtag $tag (search comes in Phase 6)';
  }

  @override
  String get chatEdited => 'Edited';

  @override
  String get chatStarred => 'Starred';

  @override
  String get chatSending => 'Sending';

  @override
  String get chatSendFailed => 'Send failed';

  @override
  String get chatRead => 'Read';

  @override
  String get chatSent => 'Sent';

  @override
  String chatReactionSemantics(String label, int count) {
    return '$label, $count reactions';
  }

  @override
  String chatReactionSemanticsMine(String label, int count) {
    return '$label, $count reactions including you';
  }

  @override
  String get chatSendPhotoFile => 'Send photo / file';

  @override
  String get chatStickersEmoji => 'Stickers / emoji';

  @override
  String get chatEmojiPanelTitle => 'Emoji';

  @override
  String get emojiCatPeople => 'Smileys & people';

  @override
  String get emojiCatNature => 'Animals & nature';

  @override
  String get emojiCatFood => 'Food & drink';

  @override
  String get emojiCatActivity => 'Activity';

  @override
  String get emojiCatTravel => 'Travel & places';

  @override
  String get emojiCatObjects => 'Objects';

  @override
  String get emojiCatSymbols => 'Symbols';

  @override
  String get emojiCatFlags => 'Flags';

  @override
  String get chatEmojiAll => 'All emoji';

  @override
  String get chatMessageHint => 'Message…';

  @override
  String get chatSend => 'Send';

  @override
  String chatRecordVoice(int seconds) {
    return 'Record voice (up to ${seconds}s)';
  }

  @override
  String get chatSlashJitsiDesc => 'Start a Jitsi video conference';

  @override
  String get chatSlashJumpchatDesc => 'Start a JumpChat meeting';

  @override
  String get chatContent => 'Content';

  @override
  String get chatErrNoServerPost => 'This message is not on the server yet';

  @override
  String chatErrNoAppForTypeSaved(String path) {
    return 'No app can open this file type (saved to $path)';
  }

  @override
  String chatErrNoAppForTypeAt(String path) {
    return 'No app can open this file type (file is at $path)';
  }

  @override
  String get chatErrNoAppForType => 'No app can open this file type';

  @override
  String chatErrOpenFailed(String error) {
    return 'Open failed: $error';
  }

  @override
  String chatErrDownloadFailed(String error) {
    return 'Download failed: $error';
  }

  @override
  String get chatErrDecryptKey =>
      'Decryption failed (is the channel key unlocked?)';

  @override
  String get chatErrDecrypt => 'Decryption failed';

  @override
  String get chatErrPlaybackFailed => 'Playback failed';

  @override
  String get chatStreamEncryptedTitle => 'This video is encrypted';

  @override
  String get chatStreamUntrustedCertTitle =>
      'The server certificate is not trusted';

  @override
  String get chatStreamEncryptedHint =>
      'An external player cannot access the channel key. Download and decrypt the video before watching; tap OK to start downloading.';

  @override
  String get chatStreamUntrustedCertHint =>
      'An external player does not trust the certificate of this server. Download the file before playing it.';

  @override
  String get chatSkipAgain => 'Do not show again';

  @override
  String get chatOpenAsTitle => 'Open with';

  @override
  String get chatOpenAsText => 'Text';

  @override
  String get chatOpenFile => 'Open file';

  @override
  String get chatSaveToDownloads => 'Save to Downloads';

  @override
  String get chatShare => 'Share';

  @override
  String get chatOpenWithOtherApp => 'Open with another app';

  @override
  String get chatImageActions => 'Image actions';

  @override
  String get chatImageLoadFailed => 'Failed to load image';

  @override
  String get chatVoiceMessage => 'Voice message';

  @override
  String get chatDownloading => 'Downloading…';

  @override
  String get chatErrNoAttachment => 'This message has no attachment';

  @override
  String get chatErrPageClosed => 'This page is closed';

  @override
  String get chatErrSaveToDownloadsFailed => 'Failed to save to Downloads';

  @override
  String get chatErrNoShareTarget => 'No app can receive the share';

  @override
  String get chatErrChannelNotInList =>
      'This channel is not in your list (it may be private or you have not joined it)';

  @override
  String chatErrCannotOpenLink(String url) {
    return 'Cannot open this link: $url';
  }

  @override
  String get chatErrNoAppForLink => 'No app can open this link';

  @override
  String get chatLinkRisky => 'This link may be unsafe';

  @override
  String get chatUnsafeWebsiteConfirmOpen =>
      'The following website might be classified by Google Safe Browsing as malicious. We do not recommend you to visit it. Are you sure you want to open it?';

  @override
  String get chatUnsafeWebsiteOpen => 'Open anyway';

  @override
  String get chatUnsafeWebsiteCancel => 'Cancel';

  @override
  String get chatErrNoMicPermission => 'No microphone permission';

  @override
  String chatErrRecordFailed(String error) {
    return 'Recording failed: $error';
  }

  @override
  String get chatRecording => 'Recording';

  @override
  String get chatVoiceStop => 'Stop recording';

  @override
  String get chatVoicePreview => 'Preview';

  @override
  String get chatVoicePreviewPause => 'Pause';

  @override
  String get chatVoiceDiscard => 'Discard';

  @override
  String get chatVoiceRerecord => 'Re-record';

  @override
  String get chatVoiceReviewHint => 'Preview it, then decide';

  @override
  String chatVoiceMaxSeconds(int seconds) {
    return 'Up to $seconds seconds';
  }

  @override
  String get chatNewChannel => 'New Channel';

  @override
  String chatChannelCount(int count) {
    return '$count channels';
  }

  @override
  String chatUserCount(int count) {
    return '$count users';
  }

  @override
  String get chatLinkReady => 'Connected';

  @override
  String get chatLinkReconnecting => 'Reconnecting';

  @override
  String get chatLinkOffline => 'Offline';

  @override
  String get chatLinkSyncFailed => 'Sync failed';

  @override
  String get chatLinkDisconnected => 'Disconnected';

  @override
  String get chatChannelsTitle => 'Channels';

  @override
  String get chatSearchMessages => 'Search messages';

  @override
  String get chatLogout => 'Sign out';

  @override
  String get chatStatusWaitingSync => 'Waiting to sync';

  @override
  String get chatStatusSyncing => 'Syncing…';

  @override
  String chatStatusConnSuffix(String connId) {
    return ' · $connId';
  }

  @override
  String get chatStatusRealtimeDown =>
      'Realtime channel offline (list still works)';

  @override
  String get chatSyncingChannels => 'Syncing channels…';

  @override
  String get chatNoChannels => 'No channels yet';

  @override
  String chatManageFailed(String label, String error) {
    return '$label failed: $error';
  }

  @override
  String get chatManageNameRequired => 'Enter a channel name';

  @override
  String chatManagePromoted(String name) {
    return 'Conversation converted to a private channel “$name”';
  }

  @override
  String chatManagePromoteFailed(String error) {
    return 'Conversion failed: $error';
  }

  @override
  String chatManageTitle(String name) {
    return 'Channel management · $name';
  }

  @override
  String get chatManageLoading => 'Loading…';

  @override
  String get chatManageEncryptedSuffix => ' · Encrypted';

  @override
  String chatManageLocalPosts(int count) {
    return ' · $count local messages';
  }

  @override
  String get chatFavoriteChannel => 'Star channel';

  @override
  String get chatFavoriteAction => 'Star';

  @override
  String get chatLeaveChannel => 'Leave channel';

  @override
  String chatLeaveConfirm(String name) {
    return 'Leave “$name”? Its messages will no longer be shown.';
  }

  @override
  String chatArchiveConfirm(String name) {
    return 'Archive “$name”? You can find it later under “Archived Channels”.';
  }

  @override
  String get chatArchiveUnsupported =>
      'The server did not archive this channel (not supported for this account or channel type)';

  @override
  String chatArchiveFailed(String error) {
    return 'Failed to archive channel: $error';
  }

  @override
  String get chatPromoteTitle => 'Convert conversation to a private channel';

  @override
  String chatCloseConfirm(String name) {
    return 'Close “$name”? This cannot be undone.';
  }

  @override
  String get chatManageNoActions =>
      'No manage actions available for this channel';

  @override
  String chatConvTitle(int channelId) {
    return 'Conversation #$channelId';
  }

  @override
  String chatPublicChannelTitle(int channelId) {
    return 'Public channel #$channelId';
  }

  @override
  String chatPrivateChannelTitle(int channelId) {
    return 'Private channel #$channelId';
  }

  @override
  String get chatChannelName => 'Channel name';

  @override
  String get chatChannelNameHelper => 'No spaces or special characters';

  @override
  String get chatPromoteAction => 'Convert';

  @override
  String chatCreatedEncrypted(int channelId) {
    return 'Encrypted channel #$channelId created';
  }

  @override
  String chatCreated(int channelId) {
    return 'Channel #$channelId created';
  }

  @override
  String get chatChannelNameHint => 'e.g. Project discussion';

  @override
  String get chatChannelPurposeOptional => 'Purpose (optional)';

  @override
  String get chatChannelPrivate => 'Private channel';

  @override
  String get chatChannelPrivateHint => 'Only invited members can join';

  @override
  String get chatChannelPublic => 'Public channel';

  @override
  String get chatChannelPublicHint => 'Everyone on the server can see and join';

  @override
  String get chatCreateE2eeDisabled =>
      'End-to-end encryption is disabled on the server, so encrypted channels cannot be created.';

  @override
  String get chatCreateE2eeHint =>
      'Messages are encrypted and decrypted only on members’ devices; the server never sees plaintext. This cannot be turned off later, and you cannot message people who do not have encryption keys.';

  @override
  String get chatCreateE2eeIrreversible =>
      'This cannot be changed after creation, so make sure first';

  @override
  String get chatSectionMembers => 'Members';

  @override
  String get chatCreateNoInvitableUsers =>
      'No users available to invite (or sync has not finished)';

  @override
  String get chatUserNoE2eeKey =>
      'This user does not have an end-to-end encryption key yet';

  @override
  String get chatCreateNameRequired => 'Channel name cannot be empty';

  @override
  String get chatCreateNoE2eeIdentity =>
      'You do not have an end-to-end encryption identity yet. Set one up under “End-to-end encryption” first.';

  @override
  String chatCreateMemberNoKey(String name) {
    return '$name does not have an end-to-end encryption key yet and cannot be added';
  }

  @override
  String get chatCreateNoChannelId =>
      'The server did not return a channel identity, so creating it may have failed.';

  @override
  String get chatNotificationAll => 'All messages';

  @override
  String get chatNotificationMentionSubscribe =>
      '@mentions and threads I follow';

  @override
  String get chatNotificationMention => 'Only @mentions';

  @override
  String get chatNotificationNone => 'Nothing';

  @override
  String chatNotificationChanged(String label) {
    return 'Notifications set to “$label”';
  }

  @override
  String get chatNotificationSaveFailed => 'Failed to save';

  @override
  String get chatNotificationTitle => 'Notification settings';

  @override
  String get chatRescueKeyTitle => 'Repair encryption key';

  @override
  String chatRescueKeyConfirm(int channelId, String name) {
    return 'Reseal the channel key for #$channelId and send it to $name?\n\nThey need a public key for this to work.';
  }

  @override
  String get chatRescueKeyDone => 'Channel key resent';

  @override
  String get chatRescueKeyFailed =>
      'Repair failed (they may not have a public key)';

  @override
  String get chatKickTitle => 'Remove from channel';

  @override
  String chatKickConfirm(String names) {
    return 'Remove $names from this channel?';
  }

  @override
  String get chatKickAction => 'Remove';

  @override
  String get chatKickDone => 'Removed';

  @override
  String get chatPostsDeletedByAdmin =>
      'Some posts have been deleted by admin. This page will be refreshed in a minute.';

  @override
  String get chatKickFailed =>
      'Failed to remove (only the owner or an admin can remove members)';

  @override
  String get chatInviteSkippedNoPassphrase =>
      'None of these members have set a passphrase, so the invitation was skipped';

  @override
  String get chatInviteDone => 'Invited';

  @override
  String chatMembersTitle(int count) {
    return 'Members ($count)';
  }

  @override
  String get chatInviteTitle => 'Invite members';

  @override
  String get chatSearchMembers => 'Search members';

  @override
  String chatBrokenMembersBanner(int count) {
    return '$count members cannot decrypt messages in this channel. Tap their names to resend the channel key.';
  }

  @override
  String get chatNoMembers => 'No members';

  @override
  String chatMemberMe(String name) {
    return '$name (me)';
  }

  @override
  String get chatMemberNoE2eeKey =>
      'This member does not have an end-to-end encryption key yet';

  @override
  String get chatMemberBrokenHint =>
      'Cannot decrypt messages in this channel; tap to repair';

  @override
  String chatStartChatFailed(String error) {
    return 'Could not start the conversation: $error';
  }

  @override
  String chatStartChatNoChannel(String name) {
    return 'The server did not return a conversation ($name)';
  }

  @override
  String chatProfileAccount(String username, int userId) {
    return 'Account: $username  ID: #$userId';
  }

  @override
  String chatProfileEmail(String email) {
    return 'Email: $email';
  }

  @override
  String chatProfileBio(String description) {
    return 'Bio: $description';
  }

  @override
  String get chatProfileE2eeUnset => 'End-to-end encryption: no passphrase set';

  @override
  String get chatProfileE2eeSet => 'End-to-end encryption: passphrase set';

  @override
  String get chatProfileInChannelBroken =>
      'In this channel: cannot decrypt (repairable)';

  @override
  String get chatProfileInChannelOk => 'In this channel: OK';

  @override
  String chatProfileTimezone(String tz) {
    return 'Timezone: $tz';
  }

  @override
  String get chatProfileUnavailable =>
      'Profile unavailable (server has no such user; showing the mentioned name only)';

  @override
  String get chatEditProfile => 'Edit profile';

  @override
  String get chatSendMessage => 'Send message';

  @override
  String chatInviteCount(int count) {
    return 'Invite ($count)';
  }

  @override
  String get chatSearchUsers => 'Search users';

  @override
  String get chatInviteNoPassphraseHint =>
      'Members without a passphrase (⚠) will not be added to an encrypted channel; you will be asked again when inviting.';

  @override
  String get chatRowNameSeparator => ', ';

  @override
  String get chatRowNoMessages => 'No messages';

  @override
  String get chatRowJustNow => 'Just now';

  @override
  String chatRowMinutesAgo(int n) {
    return '$n min ago';
  }

  @override
  String chatRowHoursAgo(int n) {
    return '$n h ago';
  }

  @override
  String chatRowDaysAgo(int n) {
    return '$n d ago';
  }

  @override
  String chatRowMembers(int count) {
    return '$count members';
  }

  @override
  String chatRowUnreadThreads(int count) {
    return '$count unread threads';
  }

  @override
  String get chatRowHasFailed => 'Some messages failed to send';

  @override
  String get chatRowHasBrokenMembers => 'Some members cannot decrypt';

  @override
  String get chatRowMuted => 'Muted';

  @override
  String get chatRowBotChannel => 'Bot channel';

  @override
  String get chatMySpace => 'My Space';

  @override
  String get chatHashtagsEmpty => 'This channel has no hashtags yet';

  @override
  String get chatContentMentions => '@me';

  @override
  String chatContentEmpty(String kind) {
    return 'This channel has no $kind content yet';
  }

  @override
  String get chatAuthorMe => 'Me';

  @override
  String get chatMediaImage => 'Image';

  @override
  String get chatMediaAudio => 'Audio';

  @override
  String chatMediaTitle(String name) {
    return '$name · Media & files';
  }

  @override
  String get chatMediaEmpty => 'Nothing here yet';

  @override
  String get chatMediaLoadEarlier => 'Load earlier';

  @override
  String chatMediaAttachmentCount(int count) {
    return '$count attachments';
  }

  @override
  String get chatArchiveEmpty =>
      'No archived channels.\nArchived encrypted conversations appear here.';

  @override
  String get chatArchiveReadable => 'Readable';

  @override
  String get chatArchiveLocked => 'Locked';

  @override
  String get chatArchiveUnlockHint =>
      'Set up the encryption key to open this channel';

  @override
  String get chatArchiveKeyUnavailable => 'Key unavailable';

  @override
  String chatArchiveHashId(int id) {
    return 'Archive #$id';
  }

  @override
  String chatArchiveMemberCount(int count) {
    return '$count members';
  }

  @override
  String get chatScheduledTitle => 'Scheduled messages';

  @override
  String get chatAttachSchedule => 'Schedule';

  @override
  String get chatScheduledEmpty => 'No scheduled messages';

  @override
  String chatScheduledSendAt(String time) {
    return 'Sends at $time';
  }

  @override
  String get chatRemindersEmpty => 'No reminders';

  @override
  String get chatPostNoBody => '(No text)';

  @override
  String chatReminderAt(String time) {
    return 'Reminds at $time';
  }

  @override
  String get chatReminderCancel => 'Remove reminder';

  @override
  String get chatCloseConversation => 'Close conversation';

  @override
  String get chatCloseChannel => 'Close channel';

  @override
  String get chatVoteClosed => 'Closed';

  @override
  String chatVoteTotalVotes(int total) {
    return '$total votes';
  }

  @override
  String get chatVoteEditTitle => 'Edit poll';

  @override
  String get chatVoteCloseAction => 'Close poll';

  @override
  String get chatVoteDeleteTitle => 'Delete poll';

  @override
  String get chatVoteDeleted => 'Poll deleted';

  @override
  String get chatVoteFailed => 'Vote failed';

  @override
  String get chatVoteRefreshFailed => 'Refresh failed';

  @override
  String get chatVoteViewResults => 'View results';

  @override
  String get chatVoteResultsTitle => 'Poll results';

  @override
  String get chatVoteNoVotes => 'No votes yet';

  @override
  String get chatVoteAddOption => 'Add option';

  @override
  String get chatVoteAddOptionFailed => 'Couldn\'t add the option';

  @override
  String get chatVoteEditFailed => 'Couldn\'t edit the poll';

  @override
  String get chatVoteCloseFailed => 'Couldn\'t close the poll';

  @override
  String get chatVoteDeleteFailed => 'Couldn\'t delete the poll';

  @override
  String get chatVoteDeleteConfirm =>
      'Delete this poll? The message itself will be kept.';

  @override
  String get chatVoteAnonymous => 'Anonymous';

  @override
  String chatVoteEndsAt(String time) {
    return 'Ends $time';
  }

  @override
  String get chatVoteChoiceHint => 'Option text';

  @override
  String get chatVoteCreateTitle => 'Create poll';

  @override
  String get chatVoteCreateSubmit => 'Create';

  @override
  String get chatVoteErrQuestionEmpty => 'Question can\'t be empty';

  @override
  String get chatVoteErrChoiceEmpty => 'Option can\'t be empty';

  @override
  String get chatVoteErrChoiceDuplicate => 'Duplicate option';

  @override
  String get chatVoteErrTooFewChoices => 'Add at least two options';

  @override
  String get chatVoteErrExpireFuture => 'End time must be in the future';

  @override
  String get chatVoteQuestionLabel => 'Question';

  @override
  String get chatVoteChoiceLabel => 'Option';

  @override
  String get chatVoteAllowMultiple => 'Allow multiple choices';

  @override
  String get chatVoteAnonymousVote => 'Anonymous voting';

  @override
  String get chatVoteAllowAddOption => 'Allow adding options';

  @override
  String get chatVoteSetExpire => 'Set end time';

  @override
  String get chatVoteClearExpire => 'No end time';

  @override
  String get chatVoteLockedHint =>
      'People have already voted: only \"Allow adding options\" and the end time can be changed';

  @override
  String get chatActionReplyThread => 'Reply in Thread';

  @override
  String get chatActionReact => 'React';

  @override
  String get chatActionUnpin => 'Unpin';

  @override
  String get chatActionPin => 'Pin';

  @override
  String get chatActionRemindMe => 'Remind me';

  @override
  String get chatActionRemoveHashtag => 'Remove hashtag';

  @override
  String get chatActionCopyText => 'Copy text';

  @override
  String get chatActionReadUsers => 'Read by';

  @override
  String get chatActionUnreadUsers => 'Unread by';

  @override
  String get chatActionSheetTitle => 'Message actions';

  @override
  String get chatReadStatusSection => 'Read status';

  @override
  String get chatTempResend => 'Resend';

  @override
  String get chatEditMessageTitle => 'Edit message';

  @override
  String get chatThreadTitle => 'Thread';

  @override
  String get chatThreadMarkAllRead => 'Mark all as read';

  @override
  String get chatThreadUnsubscribe => 'Unsubscribe';

  @override
  String get chatThreadSubscribe => 'Subscribe';

  @override
  String get chatThreadUnsubscribed => 'Unsubscribed';

  @override
  String get chatActionFailed => 'Couldn\'t complete the action';

  @override
  String get chatThreadOriginalMessage => 'Original message';

  @override
  String get chatThreadNoReplies => 'No replies yet';

  @override
  String get chatThreadReplyHint => 'Reply in Thread…';

  @override
  String chatReadStatusLoadFailed(String error) {
    return 'Couldn\'t load the read status:\n$error';
  }

  @override
  String get chatReadStatusNoReaders => 'No one has read this yet';

  @override
  String get chatReadStatusAllRead => 'Everyone has read this';

  @override
  String chatReadStatusReadCount(int count) {
    return '$count read';
  }

  @override
  String chatReadStatusUnreadCount(int count) {
    return '$count unread';
  }

  @override
  String get chatReadStatusNoMatch => 'No matching members';

  @override
  String chatReadStatusAccountInfo(String account, int id) {
    return 'Account: $account  ID: #$id';
  }

  @override
  String chatReadStatusUserStatus(String status) {
    return 'Status: $status';
  }

  @override
  String get chatNoPassphraseTitle => 'Error';

  @override
  String chatNoPassphraseBody(int count) {
    return '$count of the selected members haven\'t set up an end-to-end encryption passphrase. Select OK to remove them and continue encrypting the channel.';
  }

  @override
  String get chatNoPassphraseNotify => 'Notify them to set a passphrase';

  @override
  String get chatMentionChannelDesc => 'Notify everyone in this channel';

  @override
  String get chatMentionHereDesc => 'Notify everyone who is online now';

  @override
  String get chatStickerNoCatalog => 'This server has no sticker catalog';

  @override
  String get chatStickerCategoryEmpty => 'This category is empty';

  @override
  String get chatBotActionFailed => 'Couldn\'t trigger the button';

  @override
  String get chatBotProcessing => 'Processing...';

  @override
  String chatBotWelcomeDefault(String bot) {
    return 'This is a one-on-one conversation between you and $bot.';
  }

  @override
  String get chatBotFallbackName => 'the bot';

  @override
  String get contactHeaderTagline =>
      'Synology Contacts · Address books / Labels / CardDAV';

  @override
  String get contactImportVcfCsv => 'Import vCard / CSV';

  @override
  String get contactManageBooksLabels => 'Manage address books & labels';

  @override
  String get contactCarddavSync => 'CardDAV & sync';

  @override
  String get contactSortByName => 'Sort by name';

  @override
  String get contactSortByCompany => 'Sort by company';

  @override
  String get contactSortAsc => 'Switch to ascending';

  @override
  String get contactSortDesc => 'Switch to descending';

  @override
  String get contactSearchHint => 'Search name / company / email / phone';

  @override
  String get contactStarredChip => '★ Starred';

  @override
  String get contactOpenFailed => 'Couldn\'t open contacts';

  @override
  String contactNoMatch(String keyword) {
    return 'No match for “$keyword”';
  }

  @override
  String get contactNoMatchHint =>
      'Try another keyword, or clear the search box to see everything.';

  @override
  String get contactEmptyTitle => 'No contacts yet';

  @override
  String get contactEmptyBody =>
      'Contacts from Synology Contacts appear here.\nTap “New” at the bottom right, or import a vCard from “More → Import”.';

  @override
  String get contactNoBooks => 'No address books available';

  @override
  String get contactPickBookTitle => 'Which address book should it go in?';

  @override
  String contactSharedFrom(String name) {
    return 'Shared from $name';
  }

  @override
  String get contactUnnamed => '(Unnamed)';

  @override
  String get contactUnstarred => 'Unstarred';

  @override
  String get contactErrNotInstalled =>
      'Synology Contacts is not installed on this NAS';

  @override
  String get contactErrVersionUnsupported =>
      'The Contacts version on this NAS does not support this action';

  @override
  String get contactErrNoPermission =>
      'This account does not have permission for this action';

  @override
  String get contactErrParamRejected =>
      'The server rejected the parameters (this Contacts version probably does not support it)';

  @override
  String get contactErrBookNotFound => 'Address book not found';

  @override
  String get contactErrOffline => 'Connect to the NAS to see your contacts';

  @override
  String get contactErrNetwork =>
      'Network unreachable; check that the NAS is online';

  @override
  String get contactErrNoStarredLabel => 'This NAS has no Starred label';

  @override
  String contactExportBookName(String name) {
    return 'AddressBook_$name';
  }

  @override
  String contactExportLabelName(String name) {
    return 'Label_$name';
  }

  @override
  String get contactBooksAndLabels => 'Address books & labels';

  @override
  String get contactAddressBooks => 'Address books';

  @override
  String get contactNewAddressBook => 'New address book';

  @override
  String get contactNoBooksYet => 'No address books yet';

  @override
  String get contactBookPublic => 'Public (visible to other users on this NAS)';

  @override
  String get contactBookCreated => 'Address book created';

  @override
  String contactMemberCount(int count) {
    return '$count contacts';
  }

  @override
  String get contactBookPersonal => 'Personal';

  @override
  String get contactBookTeamPublic => 'Team / Public';

  @override
  String get contactBookSuggested => 'Suggested';

  @override
  String contactSharedTo(String names) {
    return 'Shared with $names';
  }

  @override
  String get contactExportVCard => 'Export vCard';

  @override
  String contactSharePrincipals(String principals) {
    return 'Shareable principals: $principals\n(To change sharing, use Contacts in the web portal; this page is read-only)';
  }

  @override
  String get contactRenameAddressBook => 'Rename address book';

  @override
  String get contactRenamed => 'Renamed';

  @override
  String contactExportingBook(String name) {
    return 'Exporting “$name”…';
  }

  @override
  String contactExportedTo(String path) {
    return 'Exported to $path';
  }

  @override
  String get contactDeleteAddressBook => 'Delete address book';

  @override
  String contactDeleteBookConfirm(String name, int count) {
    return 'Delete “$name”? Its $count contacts will be deleted too.';
  }

  @override
  String get contactBookDeleted => 'Address book deleted';

  @override
  String get contactLabelsHelp =>
      'A label is “a list of contacts”; exporting it produces a group address book. Starred is a built-in system label (type=1) and can\'t be renamed or deleted.';

  @override
  String get contactEditLabel => 'Edit label';

  @override
  String contactSystemLabelMembers(int count) {
    return 'System label · $count members';
  }

  @override
  String get contactLabelDeleted => 'Label deleted';

  @override
  String get contactRenameRecolor => 'Rename / recolor';

  @override
  String get contactExportVCardGroup => 'Export vCard (group address book)';

  @override
  String get contactCarddavIntro =>
      'Built-in contacts apps on phones, macOS, and other clients can all connect; the iOS URL only works over https.';

  @override
  String get contactCarddavBindBook =>
      'Address book to bind (determines the general URL)';

  @override
  String get contactCarddavIosHint =>
      'System Settings → Contacts → Accounts → Add CardDAV Account';

  @override
  String get contactCarddavOtherClients =>
      'Other clients (bound to a specific address book)';

  @override
  String get contactCarddavNoUuid =>
      'No address book UUID found; see the first entry';

  @override
  String get contactExternalSources =>
      'External address books (including CardDAV accounts)';

  @override
  String get contactNoExternalSources =>
      'No external address books yet. Add a CardDAV account, or connect Google/Outlook in the web portal.';

  @override
  String get contactExternalSource => 'External source';

  @override
  String contactBookHash(String id) {
    return 'Address book #$id';
  }

  @override
  String get contactExternalSourceNote =>
      'Note: the server has no “delete external source” API (only create/edit/sync); to delete one, use Contacts in the web portal.';

  @override
  String get contactSyncTriggered => 'Sync triggered';

  @override
  String contactSyncFailed(String error) {
    return 'Sync failed: $error';
  }

  @override
  String get contactAddedSyncing =>
      'Added; syncing now (this may take a while)';

  @override
  String contactAddFailed(String error) {
    return 'Couldn\'t add: $error';
  }

  @override
  String get contactCopyUrl => 'Copy URL';

  @override
  String get contactUrlCopied => 'URL copied';

  @override
  String get contactAddCarddavAccount => 'Add CardDAV account';

  @override
  String get contactServerUrl => 'Server address';

  @override
  String get contactUsername => 'Username';

  @override
  String get contactPassword => 'Password';

  @override
  String contactDetailNickname(String name) {
    return 'Nickname: $name';
  }

  @override
  String contactDetailAddressBook(String name) {
    return 'Address book: $name';
  }

  @override
  String get contactReadOnlyNote =>
      'This record is synced from the address book, so it can only be viewed, not edited.';

  @override
  String contactCopiedValue(String value) {
    return 'Copied $value';
  }

  @override
  String get contactCopyMove => 'Copy / Move';

  @override
  String get contactHide => 'Hide';

  @override
  String get contactUnhide => 'Unhide';

  @override
  String get contactHidden => 'Hidden';

  @override
  String get contactUnhidden => 'Unhidden';

  @override
  String get contactDeleteTitle => 'Delete contact';

  @override
  String contactDeleteConfirm(String name) {
    return 'Delete “$name”? This can\'t be undone.';
  }

  @override
  String contactLabelsUpdateFailed(String error) {
    return 'Couldn\'t update labels: $error';
  }

  @override
  String get contactNoOtherBook => 'No other address book to move it to';

  @override
  String get contactPickTargetBook =>
      'Choose a target address book (long-press = move)';

  @override
  String get contactMoved => 'Moved';

  @override
  String contactCopyFailed(String error) {
    return 'Copy failed: $error';
  }

  @override
  String contactMoveFailed(String error) {
    return 'Move failed: $error';
  }

  @override
  String get contactLabelPickerTitle => 'Label these contacts';

  @override
  String get contactNoLabelsHint =>
      'No labels yet — create one under “Manage → Labels” first';

  @override
  String get contactNameRequired => 'Name can\'t be empty';

  @override
  String get contactEditTitle => 'Edit contact';

  @override
  String get contactNewTitle => 'New contact';

  @override
  String get contactAddPhoto => 'Add photo';

  @override
  String get contactChangePhoto => 'Change photo';

  @override
  String get contactSectionBasic => 'Basic info';

  @override
  String get contactFieldFullName => 'Full name';

  @override
  String get contactFieldCompany => 'Company';

  @override
  String get contactFieldDepartment => 'Department';

  @override
  String get contactFieldJobTitle => 'Job title';

  @override
  String get contactSectionNameParts =>
      'Name parts (the official client joins these into the name)';

  @override
  String get contactFieldGivenName => 'Given name';

  @override
  String get contactFieldFamilyName => 'Family name';

  @override
  String get contactFieldPrefix => 'Name prefix';

  @override
  String get contactFieldSuffix => 'Name suffix';

  @override
  String get contactFieldMiddleName => 'Middle name';

  @override
  String get contactFieldPhone => 'Phone';

  @override
  String get contactPhoneHint => 'Mobile / landline';

  @override
  String get contactFieldUrl => 'Website';

  @override
  String get contactFieldIm => 'Instant messaging';

  @override
  String get contactImHint => 'IM account';

  @override
  String get contactFieldDate => 'Date (birthday, anniversary, etc.)';

  @override
  String get contactFieldAddress => 'Address';

  @override
  String get contactAddressHint => 'Street, city, ZIP, country';

  @override
  String get contactSectionOther => 'Other';

  @override
  String get contactFieldBirthday => 'Birthday';

  @override
  String get contactFieldNote => 'Note';

  @override
  String contactAddRow(String title) {
    return 'Add a $title row';
  }

  @override
  String get contactRemoveRow => 'Remove this row';

  @override
  String get contactImportTitle => 'Import contacts';

  @override
  String get contactImportHelp =>
      'Supports .vcf (vCard) / .csv / .txt. Pick a file to see a preview first, then confirm the import.';

  @override
  String get contactImportTargetBook => 'Which address book to import into';

  @override
  String get contactPickFile => 'Choose file';

  @override
  String contactPreviewCount(int count) {
    return 'Preview: $count entries';
  }

  @override
  String contactPreviewDuplicates(int count) {
    return '$count may already exist';
  }

  @override
  String get contactImportBusy => 'Working…';

  @override
  String get contactImportToThisBook => 'Import into this address book';

  @override
  String get contactNoFilePath =>
      'This platform didn\'t provide a file path; try a different file picker';

  @override
  String get contactNoContactsInFile =>
      'No contacts could be parsed from this file';

  @override
  String contactPreviewFailed(String error) {
    return 'Preview failed: $error';
  }

  @override
  String get contactImportDone => 'Import complete';

  @override
  String contactImportedCount(int count) {
    return 'Imported $count contacts';
  }

  @override
  String contactImportFailed(String error) {
    return 'Import failed: $error';
  }

  @override
  String get searchMessagesHint => 'Search messages…';

  @override
  String get searchFilter => 'Filter';

  @override
  String searchTotalCount(int count) {
    return '$count results';
  }

  @override
  String get searchPrompt => 'Enter a keyword or pick filters, then search';

  @override
  String get searchNoMatch => 'No matching messages';

  @override
  String get searchKeyword => 'Keyword';

  @override
  String get searchHashtagHint => 'Hashtags (space-separated, no #)';

  @override
  String get searchFileTypeHint => 'File types (e.g. png jpg pdf)';

  @override
  String get searchAuthor => 'Author';

  @override
  String get searchTimeRange => 'Time range';

  @override
  String get searchStartDate => 'Start date';

  @override
  String get searchEndDate => 'End date';

  @override
  String get searchApply => 'Apply';

  @override
  String searchLoadMoreFailed(String error) {
    return 'Couldn\'t load more: $error';
  }

  @override
  String get srvNoAddress => 'No usable address';

  @override
  String srvConnected(String url, String source) {
    return 'Connected to $url ($source)';
  }

  @override
  String srvAllUnreachable(String tried) {
    return 'All addresses unreachable: $tried';
  }

  @override
  String srvUnreachable(String url, String source, String error) {
    return '$url ($source) unreachable: $error';
  }

  @override
  String srvCertWaiting(String url, String hash) {
    return 'The certificate for $url is not trusted; waiting for confirmation (SHA-256 $hash)';
  }

  @override
  String srvCertRejected(String url) {
    return 'The certificate for $url was rejected; connection aborted';
  }

  @override
  String srvCertTrusted(String host) {
    return 'Trusted the certificate for $host; retrying the connection';
  }

  @override
  String srvRetryFailed(String url, String error) {
    return '$url still failed after retry: $error';
  }

  @override
  String srvUseDirect(String url) {
    return 'Using direct address $url';
  }

  @override
  String srvQueryingQc(String id) {
    return 'Querying QuickConnect: $id';
  }

  @override
  String srvServicePort(int port, String host, String region) {
    return 'Service port $port, via $host/$region';
  }

  @override
  String srvCandidate(String url, String source) {
    return 'Candidate $url ($source)';
  }

  @override
  String srvQcFailedRetry(String error) {
    return 'QuickConnect lookup failed; retrying shortly: $error';
  }

  @override
  String get srvConnect => 'Connect';

  @override
  String get srvRestoring => 'Restoring';

  @override
  String get srvRestoringSemantics => 'Restoring your last sign-in';

  @override
  String get srvRestoringHint => 'Restoring your last sign-in…';

  @override
  String srvLastAccount(String account, String server) {
    return 'Last used: $account@$server';
  }

  @override
  String get srvConnectToNas => 'Connect to your NAS';

  @override
  String srvOfflineBrowse(String account) {
    return 'Browse cached data offline (last used: $account)';
  }

  @override
  String get srvDirectAddress => 'Direct address';

  @override
  String get srvHostOrAddress => 'Host or address';

  @override
  String get srvQuickConnectExample => 'e.g. abc123-qq';

  @override
  String get srvHostExample => 'e.g. nas.example.com:5001';

  @override
  String get srvDesignPreview => 'Design preview';

  @override
  String srvLoadFailed(String error) {
    return 'Couldn\'t load: $error';
  }

  @override
  String get srvCertEmpty =>
      'You haven\'t trusted any server certificate yet.\nWhen you first connect to a server with a self-signed certificate, its details appear for confirmation.';

  @override
  String get srvCertUntrustTitle => 'Remove trust';

  @override
  String srvCertUntrustMessage(String host) {
    return 'After removing it, connecting to $host will ask you to confirm the fingerprint again.';
  }

  @override
  String srvCertForgotten(String host) {
    return 'Removed trust for $host';
  }

  @override
  String srvCertTrustedAt(String date) {
    return 'Trusted on $date';
  }

  @override
  String get srvCertChangedTitle => 'Server certificate changed';

  @override
  String get srvCertUntrustedTitle => 'Untrusted certificate';

  @override
  String srvCertChangedBody(String host) {
    return 'The certificate for $host differs from the one trusted before. If the server hasn\'t changed its certificate, someone may be eavesdropping — do not continue.';
  }

  @override
  String srvCertUntrustedBody(String host) {
    return 'The certificate for $host is self-signed or not trusted by the system. Make sure this is your own server before trusting it.';
  }

  @override
  String get srvCertOldFingerprint => 'Previous fingerprint';

  @override
  String get srvCertFingerprint => 'Fingerprint (SHA-256)';

  @override
  String get srvCertSubject => 'Subject';

  @override
  String get srvCertIssuer => 'Issuer';

  @override
  String get srvCertValidity => 'Validity';

  @override
  String get srvCertSelfSigned =>
      'Self-signed certificate (common on Synology NAS)';

  @override
  String get srvCertTrustAnyway => 'Trust anyway';

  @override
  String get srvCertTrustAndContinue => 'Trust and continue';

  @override
  String get srvNotConnected => 'Not connected to a server yet';

  @override
  String get srvSavedCredentialsLocked =>
      'Found your previous server and account, but the saved credentials cannot be unlocked on this device. Please enter your password again.';

  @override
  String get loginOtpLabel => 'One-time code (OTP)';

  @override
  String get loginOtpHint =>
      'Two-factor verification is on for this account; enter the 6-digit code';

  @override
  String get loginAction => 'Sign in';

  @override
  String get loginTrustDevice => 'Trust this device';

  @override
  String get loginTrustDeviceHint => 'Skip the verification code next time';

  @override
  String get usageModReader => 'Reading';

  @override
  String get usageActLabel => 'Tag';

  @override
  String get usageActSwitchSection => 'Switch section';

  @override
  String get usageActOpenExternal => 'Open externally';

  @override
  String get usageActBookmark => 'Bookmark';

  @override
  String get usageActExport => 'Export';

  @override
  String get usageActSync => 'Sync';

  @override
  String get usageActFailure => 'Failed';

  @override
  String get usageKindVolume => 'Volume';

  @override
  String get usageKindPeakHour => 'Active hours';

  @override
  String get usageKindWeekdayPattern => 'Weekly rhythm';

  @override
  String get usageKindTopModule => 'Top module';

  @override
  String get usageKindTopAction => 'Main actions';

  @override
  String get usageKindUnusedModule => 'Barely used modules';

  @override
  String get usageKindModuleMix => 'Module mix';

  @override
  String get usageKindFileTypePref => 'File type preference';

  @override
  String get usageKindTransferMix => 'Upload/download';

  @override
  String get usageKindSizeMix => 'File sizes';

  @override
  String get usageKindSearchQuality => 'Search hit rate';

  @override
  String get usageKindEditCadence => 'Editing activity';

  @override
  String get usageKindSessionLength => 'Session length';

  @override
  String get usageKindFailureHotspot => 'Failure hotspots';

  @override
  String get usageKindFeatureGap => 'Feature gaps';

  @override
  String get usageBandLateNight => 'Late night (0-6)';

  @override
  String get usageBandMorning => 'Early morning (6-9)';

  @override
  String get usageBandForenoon => 'Morning (9-12)';

  @override
  String get usageBandNoon => 'Midday (12-14)';

  @override
  String get usageBandAfternoon => 'Afternoon (14-18)';

  @override
  String get usageBandEvening => 'Evening (18-22)';

  @override
  String get usageBandNight => 'Night (22-24)';

  @override
  String usageTitleVolume(int count) {
    return '$count usage records so far';
  }

  @override
  String get usageBodyNoRecords =>
      'No records yet. After a few days of use, insights about your habits will appear here automatically.';

  @override
  String usageBodyVolume(int days, int sessions, int avg) {
    return 'Covers $days days and $sessions sessions ($avg min each on average).';
  }

  @override
  String usageTitlePeakHour(String band) {
    return 'You mostly use this app $band';
  }

  @override
  String usageBodyPeakHour(int pct, String band) {
    return '$pct% of activity is concentrated $band.';
  }

  @override
  String usageBodyPeakHourWithHour(int pct, String band, int hour) {
    return '$pct% of activity is concentrated $band; the busiest time is around $hour:00.';
  }

  @override
  String usageSugPeakHour(String band) {
    return 'You could turn the most-used entries for $band into time-based suggestions, and tuck rarely used modules into a second screen the rest of the day.';
  }

  @override
  String get usageTitleWeekdayTool => 'Mostly a workday tool';

  @override
  String get usageTitleWeekendMore => 'Used more on weekends';

  @override
  String get usageTitleWeekdayMixed => 'Used on both weekdays and weekends';

  @override
  String usageBodyWeekday(int wd, int rest) {
    return 'Weekdays $wd%, weekends $rest%.';
  }

  @override
  String get usageSugWeekend =>
      'On weekends you could play down office modules and bring photos, notes, and reading forward.';

  @override
  String usageTitleTopModule(String module, int share) {
    return 'Most used: $module ($share%)';
  }

  @override
  String usageBodyTopModule(String list) {
    return 'Top three: $list.';
  }

  @override
  String usageSugTopModule(String module) {
    return 'Put $module first on the home screen and surface its most-used actions as shortcuts.';
  }

  @override
  String usageTitleUnused(int count) {
    return '$count modules have never been opened';
  }

  @override
  String usageBodyUnused(String list) {
    return 'No usage recorded yet for $list.';
  }

  @override
  String get usageSugUnused =>
      'Either remove these entries from the home screen (less noise), or show a one-off hint in context (for example, when opening an Office document, suggest filing it in Notes).';

  @override
  String usageTitleTopAction(String action) {
    return 'Mainly doing: $action';
  }

  @override
  String usageActionCount(String action, int count) {
    return '$action $count times';
  }

  @override
  String usageTitleFileType(String ext, int share) {
    return 'Most handled: $ext ($share%)';
  }

  @override
  String usageBodyFileType(String list) {
    return 'Next: $list.';
  }

  @override
  String usageSugFileType(String ext) {
    return 'Make the default way to open $ext (preview/edit) the preferred one, and offer a next step right after opening.';
  }

  @override
  String get usageTitleUploadMain => 'Mostly uploading';

  @override
  String get usageTitleDownloadMain => 'Mostly downloading/previewing';

  @override
  String get usageTitleTransferEven => 'Uploads and downloads are about even';

  @override
  String usageBodyTransfer(int up, int down) {
    return '$up uploads, $down downloads.';
  }

  @override
  String get usageSugUploadMain =>
      'Uploads are a frequent path: worth improving the default destination folder, resume/concurrency, and a post-upload indexing hint.';

  @override
  String get usageSugDownloadMain =>
      'Reading dominates: better to invest in thumbnails, first-screen preview speed, and offline cache.';

  @override
  String usageTitleSizeMix(String bucket) {
    return 'Upload sizes cluster at $bucket';
  }

  @override
  String usageSizeEntry(String bucket, int count) {
    return '$bucket: $count times';
  }

  @override
  String usageTitleSearchLow(int pct) {
    return 'A high share of searches find nothing ($pct%)';
  }

  @override
  String get usageTitleSearchGood => 'Search hit rate looks good';

  @override
  String usageBodySearch(int count, int empty) {
    return '$count searches, $empty of them with no results.';
  }

  @override
  String get usageSugSearchLow =>
      'Consider: search history/suggestions, remembering the last search scope, and loosening file name and content matching.';

  @override
  String usageTitleEditHeavy(int pct) {
    return 'Fairly heavy use ($pct% editing)';
  }

  @override
  String usageTitleEditLight(int pct) {
    return 'Mostly browsing ($pct% editing)';
  }

  @override
  String usageBodyEdit(int open, int edit) {
    return '$open opens, $edit edits.';
  }

  @override
  String get usageSugEditHeavy =>
      'Editing is core: autosave, version history (Drive already has it), and conflict prompts need to be solid.';

  @override
  String get usageSugEditLight =>
      'Browsing is core: first-screen loading, thumbnails, and swipe navigation are worth optimizing.';

  @override
  String usageTitleSession(int avg) {
    return '$avg minutes per session on average';
  }

  @override
  String usageBodySession(int count, int max) {
    return '$count sessions in total, longest $max minutes.';
  }

  @override
  String get usageSugSessionLong =>
      'Sessions run long: worth adding a \"continue where you left off\" entry (recent files/notes).';

  @override
  String get usageSugSessionShort =>
      'Sessions are short: getting common actions within 1–2 taps matters more.';

  @override
  String usageTitleFailure(String key, int count) {
    return 'Most failures: $key ($count)';
  }

  @override
  String usageFailureEntry(String key, int count) {
    return '$key $count';
  }

  @override
  String get usageSugFailure =>
      'These paths deserve better error messages, retries, and graceful degradation (local cache fallback).';

  @override
  String usageLocalLog(int count) {
    return 'Local log · $count events';
  }

  @override
  String get usageRefresh => 'Refresh analysis';

  @override
  String usageExported(int count) {
    return 'Copied $count characters of JSON to the clipboard';
  }

  @override
  String get usageClearTitle => 'Clear usage records?';

  @override
  String get usageClearBody =>
      'This deletes all raw usage events and insights on this device; it cannot be undone.\n(After clearing, let a few days accumulate and the insights will come back.)';

  @override
  String get usageCleared => 'Cleared';

  @override
  String get usageEnableTitle => 'Record local usage log';

  @override
  String get usageEnableSubtitle =>
      'Only records which module and action were used and how many times; no file names, titles, or content, and nothing is uploaded.';

  @override
  String get usageSectionInsights => 'Insights';

  @override
  String get usageInsightsFailed => 'Couldn\'t compute insights';

  @override
  String get usageInsightsEmptyTitle => 'No insights yet';

  @override
  String get usageInsightsEmptyMessage =>
      'Come back after a few days; you will find analysis based on your real usage habits here.';

  @override
  String get usageSectionData => 'Data';

  @override
  String usageChipEvents(int count) {
    return 'Events $count';
  }

  @override
  String usageChipDays(int count) {
    return 'Days $count';
  }

  @override
  String usageChipSessions(int count) {
    return 'Sessions $count';
  }

  @override
  String usageChipAvg(int count) {
    return '$count min/session on average';
  }

  @override
  String usageChipSearch(int count) {
    return 'Searches $count';
  }

  @override
  String usageChipUpload(int count) {
    return 'Uploads $count';
  }

  @override
  String usageChipDownload(int count) {
    return 'Downloads $count';
  }

  @override
  String usageChipEdit(int count) {
    return 'Edits $count';
  }

  @override
  String usageDisabledNote(int count) {
    return 'Off: no new events are recorded; the existing $count stay on this device and can be exported or cleared.';
  }

  @override
  String get usageShowRaw => 'Show raw events';

  @override
  String get usageHideRaw => 'Hide raw events';

  @override
  String get usageExportJson => 'Export JSON';

  @override
  String usageHidEntries(int count) {
    return 'Moved $count entries to the second screen (restore them with \"Show all\" in Workspace)';
  }

  @override
  String usageHideAction(int count) {
    return 'Hide these $count entries';
  }

  @override
  String usageHiddenCount(int count) {
    return '$count hidden · Show all';
  }

  @override
  String get usageHowToChange => 'What you can change';

  @override
  String get usageEvidence => 'Evidence';

  @override
  String usageMetaKind(String kind) {
    return 'Type $kind';
  }

  @override
  String usageMetaConfidence(int pct) {
    return 'Confidence $pct%';
  }

  @override
  String usageMetaSource(String source) {
    return 'Source $source';
  }

  @override
  String get usageSourceHeuristic => 'Local rules';

  @override
  String usageMetaModel(String model) {
    return 'Model $model';
  }

  @override
  String usageMetaStrategy(String key) {
    return 'Strategy $key';
  }

  @override
  String get usageNoEvents => 'No events yet';

  @override
  String get diagTitle => 'Hole-punch diagnostics';

  @override
  String get diagRerunTooltip => 'Rerun';

  @override
  String get diagRerun => 'Rerun diagnostics';

  @override
  String get diagRunFirst => 'Run diagnostics';

  @override
  String get diagNotRun =>
      'No diagnostics run yet — tap the energy core below to start';

  @override
  String get diagQcIdLabel => 'QuickConnect ID';

  @override
  String get diagQcIdHelper => 'Optional; runs only the first two steps';

  @override
  String get diagPassed => 'Passed';

  @override
  String get diagStepNativeLoad => '① Load native library';

  @override
  String get diagStepCApi => '② C ABI calls';

  @override
  String get diagStepEchoList => '③ echo list (real server)';

  @override
  String get diagStepTunnel => '④ Hole punching and tunnel';

  @override
  String get diagStepCandidates => '④-1 Hole-punch candidates';

  @override
  String get diagStepTunnelUp => '④-2 Establish tunnel';

  @override
  String get diagStepTunnelOk => '⑤ Tunnel usable';

  @override
  String diagNativeFound(String lib) {
    return 'Found $lib';
  }

  @override
  String diagCApiDetail(int port, String running, String err) {
    return 'tcpPort=$port running=$running lastError=\"$err\" — setting/clearing candidates and echo both work';
  }

  @override
  String diagEchoOk(int errno, String sites, int mss, int ms) {
    return 'errno=$errno sites=$sites udt_tx_mss=$mss, took ${ms}ms';
  }

  @override
  String get diagNativeUnavailable => 'Native library unavailable; skipped';

  @override
  String get diagNoQcId =>
      'No QuickConnect ID entered — establishing a tunnel needs real credentials';

  @override
  String get diagEchoEmpty => 'The echo list is empty';

  @override
  String diagHostNoRecord(String host) {
    return 'No record for $host';
  }

  @override
  String diagHostResolveFailed(String host) {
    return 'Failed to resolve $host';
  }

  @override
  String diagAllResolveFailed(String host) {
    return 'All lookups failed; trying $host anyway';
  }

  @override
  String diagCandidatesPicked(
    int count,
    String host,
    int port,
    String source,
    String tried,
  ) {
    return '$count candidates, picked $host:$port ($source) | $tried';
  }

  @override
  String diagTunnelStart(int rc, String name, String err, int port, int ms) {
    return 'rc=$rc($name) lastError=\"$err\" tcpPort=$port, took ${ms}ms';
  }

  @override
  String get dpTitle => 'Design preview · HUD';

  @override
  String get dpSecSwitches => 'Effect switches (compare live)';

  @override
  String get dpSecScifi => 'Sci-fi layer · deep-space cockpit (new)';

  @override
  String get dpSecPalette => 'Palette / dynamic color';

  @override
  String get dpSecBubbles =>
      'Message bubbles (grouping + telemetry time + state)';

  @override
  String get dpSecChips =>
      'System messages / date dividers / new-message divider';

  @override
  String get dpSecComposer => 'Composer (glass capsule + morphing button)';

  @override
  String get dpSecRows => 'Conversation rows';

  @override
  String get dpSecIdentity => 'Avatars / badges / status dots';

  @override
  String get dpSecOrbs => 'Orb buttons and chrome';

  @override
  String get dpSecStates => 'Empty / error / skeleton states';

  @override
  String get dpSecSheet => 'Bottom action sheet + quick reactions';

  @override
  String get dpCommandTooltip => 'Command palette (demo)';

  @override
  String get dpCommandSnack =>
      'Command palette: fuzzy search channels and actions (later batch)';

  @override
  String get dpDynamicColor => 'Material You dynamic color';

  @override
  String get dpDynamicColorHint =>
      'DYNAMIC COLOR · follows the system wallpaper';

  @override
  String dpDeviceTier(String tier, String spec) {
    return 'Device tier $tier · $spec';
  }

  @override
  String get dpPerfModeHint => 'PERF · turns off blur';

  @override
  String get dpPerfDefaultOffHigh => 'Off by default (high-end)';

  @override
  String get dpPerfDefaultOnLow => 'On by default (mid/low-end)';

  @override
  String get dpReducedMotionHint => 'REDUCED MOTION · accessibility / battery';

  @override
  String get dpMotionDefaultOnEntry => 'On by default (entry-level)';

  @override
  String get dpMotionDefaultOff => 'Off by default';

  @override
  String get dpChatGrid => 'Grid texture';

  @override
  String get dpChatGridHint => 'GRID · cockpit ambience for the chat page';

  @override
  String get dpGridDefaultOn => 'On by default';

  @override
  String get dpGridDefaultOffEntry => 'Off by default (entry-level)';

  @override
  String get dpConnectSemantics => 'Connect (demo)';

  @override
  String get dpEnergySnack => 'Energy core: primary action (demo)';

  @override
  String get dpEnergyOrbCaption =>
      'ENERGY ORB · halo + counter-rotating arc + progress ring';

  @override
  String get dpReplayBoot => 'Replay boot sequence';

  @override
  String get dpMaterialYouCaption =>
      'MATERIAL YOU · primary follows the system wallpaper · state is never color alone';

  @override
  String get dpBubble1 =>
      'This design language is called HUD (cockpit glass) — glass surfaces + edge highlights + monospaced telemetry text.';

  @override
  String get dpBubble2 =>
      'When the same person sends several messages in a row, the inner corner tightens to 6 so it reads as one block, not a wall.';

  @override
  String get dpBubble3 =>
      'Time and state tuck into the bottom-right of the bubble, saving the 16dp each row used to need.';

  @override
  String get dpBubble4 =>
      'My messages use primary-colored glass with onPrimary text for contrast.';

  @override
  String get dpBubble5 =>
      'This one is sending: a scanning ring plus small telemetry text.';

  @override
  String get dpBubble6 =>
      'This one failed to send; Retry sits right under the bubble, no long press needed.';

  @override
  String get dpBubble7 =>
      'Reactions are tappable chips (tap to toggle your own reaction).';

  @override
  String get dpBubbleQuoted =>
      'When the same person sends several messages in a row, the inner corner tightens to 6…';

  @override
  String dpAvatarSemantics(String name) {
    return 'Avatar of $name';
  }

  @override
  String get dpResendHint => 'Tap to resend';

  @override
  String dpSwitchReaction(String reaction) {
    return 'Toggle reaction: $reaction';
  }

  @override
  String get dpNewMessages => 'New messages below';

  @override
  String get dpChannelCreated => 'Channel created';

  @override
  String get dpE2eeOn => 'End-to-end encryption turned on';

  @override
  String get dpAttachTooltip => 'Send image / file';

  @override
  String get dpComposerTyped => 'Type something to try…';

  @override
  String get dpComposerHint => 'Message…';

  @override
  String get dpHoldToTalk => 'Hold to talk';

  @override
  String get dpSchedule => 'Scheduled';

  @override
  String get dpDemoChannel1 => 'Product design';

  @override
  String get dpDemoPreview1 =>
      'Xiao Lin: I tightened the inner corner to 6 on the HUD bubbles, take a look';

  @override
  String get dpDemoPreview2 => 'I resent that last one';

  @override
  String get dpDemoChannel2 => 'Ops alerts';

  @override
  String get dpDemoPreview3 => 'Bot: NAS temperature 41°C, within normal range';

  @override
  String get dpDemoChannel3 => 'Release channel';

  @override
  String get dpDemoPreview4 => 'Send failed · tap to retry';

  @override
  String get dpDegraded => 'Degraded';

  @override
  String get dpToBottom => 'To bottom';

  @override
  String get dpStartConversation =>
      'Send the first message to start the conversation';

  @override
  String get dpCannotConnectNas =>
      'Can\'t connect to the NAS; check your network or sign in again';

  @override
  String get dpRetryDemo => 'Retry (demo)';

  @override
  String get dpMessageActions => 'Message actions';

  @override
  String dpReactSnack(String emoji) {
    return 'Reacted $emoji';
  }

  @override
  String get dpReplyInThread => 'Reply in thread';

  @override
  String get dpReplyInThreadDesc => 'The original thread model stays as is';

  @override
  String get dpCopyText => 'Copy text';

  @override
  String get dpDownloadAttachment => 'Download attachment';

  @override
  String get dpDangerZone => 'Danger zone';

  @override
  String get dpDeleteMessage => 'Delete message';

  @override
  String get dpBottomSheet => 'Bottom action sheet';

  @override
  String get dpAttachGrid => 'Attachment grid';

  @override
  String get dpFollowSystem => 'System';

  @override
  String get dpLight => 'Light';

  @override
  String get dpDark => 'Dark';

  @override
  String dpPick(String label) {
    return 'Pick: $label';
  }

  @override
  String get aiTaskSummary => 'Summarize';

  @override
  String get aiTaskExplain => 'Explain';

  @override
  String get aiTaskTranslate => 'Translate';

  @override
  String get aiTaskAskBook => 'Ask this book';

  @override
  String get aiEngineCloud => 'Cloud model';

  @override
  String get aiEngineOnDevice => 'On-device model';

  @override
  String get aiEngineExtractive => 'Built-in summary (no model)';

  @override
  String get aiReadinessUnsupported =>
      'This device does not support on-device inference';

  @override
  String get aiReadinessNeedsModel => 'No on-device model downloaded yet';

  @override
  String get aiReadinessNeedsCloud => 'Cloud is not configured yet';

  @override
  String get aiReadinessInstalling => 'Installing model';

  @override
  String get aiReadinessReady => 'Model ready';

  @override
  String get aiNoteLfm =>
      'Smallest (about 170MB), fits on any device; Chinese quality is average, good for a first run-through.';

  @override
  String get aiNoteQwen =>
      'Recommended: good Chinese, natural answers, about 475MB, runs on an 8GB device.';

  @override
  String get aiTierCloud => 'Cloud LLM';

  @override
  String aiSelectedChars(int count) {
    return '$count characters selected';
  }

  @override
  String aiSheetTitle(String kind) {
    return 'AI assistant · $kind';
  }

  @override
  String get aiAskHintDefault =>
      'Ask about this book, e.g. \"What is the author\'s core argument?\"';

  @override
  String get aiAskAction => 'Ask';

  @override
  String get aiCloudNoAnswer => 'The cloud model did not answer';

  @override
  String get aiNoAnswer => 'No answer this time';

  @override
  String aiCloudErrorDetail(String error) {
    return '$error\n\nCheck the provider URL, API Key, and model id under Settings → AI service; for reasoning models, raise the maximum length.';
  }

  @override
  String aiOnDeviceErrorDetail(String error) {
    return '$error\n\nThe model runs on the phone and can fail when memory is tight; retry later or switch to a smaller model tier.';
  }

  @override
  String get aiThinking => 'The model is thinking…';

  @override
  String get aiCloudGenerating => 'The cloud model is generating…';

  @override
  String get aiOnDeviceGenerating => 'The on-device model is generating…';

  @override
  String get aiExtracting => 'Extracting key points…';

  @override
  String get aiPickAction => 'Pick an action to start';

  @override
  String get aiPickActionHint =>
      'Summarize / ask / explain the selection, all done on this device.';

  @override
  String get aiEmptyAnswer => 'The model returned nothing';

  @override
  String get aiCloudEmptyDetail =>
      'The cloud returned an empty answer. For reasoning models the usual cause is a maximum length too small, all spent on thinking; raise it under AI service → Advanced and retry.';

  @override
  String get aiOnDeviceEmptyDetail =>
      'The model produced nothing this time; retry or switch to a smaller model tier.';

  @override
  String get aiGenerating => 'Generating…';

  @override
  String aiBudgetRaised(int budget) {
    return 'The model spent its budget on thinking; automatically raised to $budget and retried (this length is remembered for next time).';
  }

  @override
  String get aiCitedSource => 'Source passages';

  @override
  String aiInputTruncated(int chars) {
    return 'Input is too long; only the first $chars characters are used';
  }

  @override
  String get aiStop => 'Stop';

  @override
  String get aiCopy => 'Copy';

  @override
  String get aiInstallOnDeviceModel => 'Install on-device model';

  @override
  String get aiPickProvider => 'Choose a provider';

  @override
  String get aiPickProviderHint =>
      'A dozen common services are built in; you can also pick Custom and enter your own relay URL.';

  @override
  String get aiBaseUrlExample => 'e.g. https://api.deepseek.com/v1';

  @override
  String get aiDefault => 'Default';

  @override
  String get aiKeyHintFallback => 'As required by the provider';

  @override
  String get aiShow => 'Show';

  @override
  String get aiKeyStored =>
      'The key is kept in system secure storage (Android Keystore), not in ordinary preferences';

  @override
  String get aiNoKeyCheck =>
      'This is a local/self-hosted service and usually does not check the key';

  @override
  String get aiWhereToGetKey => 'Where to get a key';

  @override
  String get aiModelLabel => 'Model';

  @override
  String get aiModelExample => 'e.g. deepseek-chat';

  @override
  String get aiFetchModels => 'Fetch model list';

  @override
  String get aiNoModelListInterface =>
      'This provider has no model-list endpoint; enter it manually';

  @override
  String aiAllModels(int count) {
    return 'All $count';
  }

  @override
  String get aiCommonModels => 'Common models (selectable even without a list)';

  @override
  String get aiTestConnection => 'Test connection';

  @override
  String get aiCollapseAdvanced => 'Hide advanced';

  @override
  String get aiAdvancedParams => 'Advanced parameters';

  @override
  String aiTemperature(String value) {
    return 'Temperature $value (lower is steadier, higher is more diverse)';
  }

  @override
  String get aiMaxOutputTokens => 'Max output tokens';

  @override
  String get aiProtocol => 'Protocol';

  @override
  String get aiIntlService => 'International';

  @override
  String get aiChinaService => 'Mainland China';

  @override
  String get aiSelfHosted => 'Self-hosted / local';

  @override
  String aiSearchModels(int count) {
    return 'Search models ($count total)';
  }

  @override
  String get aiServiceTitle => 'AI service';

  @override
  String get aiEnable => 'Enable AI assistant';

  @override
  String get aiEnableHint =>
      'AI entry points in the reader, notes, and documents';

  @override
  String get aiWifiOnly => 'Download models on WiFi only';

  @override
  String get aiWifiOnlyHint =>
      'Models are hundreds of MB; avoid using mobile data';

  @override
  String get aiWhichTier => 'Which tier';

  @override
  String aiTierCloudConfigured(String provider) {
    return 'Cloud: $provider (your text is sent to this provider; mind privacy and cost)';
  }

  @override
  String aiTierCloudConfiguredModel(String provider, String model) {
    return 'Cloud: $provider · $model (your text is sent to this provider; mind privacy and cost)';
  }

  @override
  String get aiTierCloudNotConfigured =>
      'Cloud is not set up yet: pick a provider, enter a key, and choose a model. For now it falls back to the on-device model or built-in summary automatically';

  @override
  String get aiTierOnDeviceDesc =>
      'On-device: the model runs on this phone and your text never leaves it';

  @override
  String get aiTierExtractiveDesc =>
      'Built-in summary: picks sentences from the source, fully offline and zero-config';

  @override
  String get aiCloudConfig => 'Cloud configuration';

  @override
  String get aiOnDeviceConfig => 'On-device configuration';

  @override
  String get aiExtractiveTitle => 'Built-in summary';

  @override
  String get aiChecking => 'Checking…';

  @override
  String aiCheckFailed(String error) {
    return 'Couldn\'t check: $error';
  }

  @override
  String aiCurrentModel(String model) {
    return 'Current model: $model';
  }

  @override
  String aiCurrentModelBackend(String model, String backend) {
    return 'Current model: $model · backend $backend';
  }

  @override
  String get aiInstalled => 'Installed';

  @override
  String get aiModelLocalOnly =>
      'The model runs on this device and needs no network.';

  @override
  String get aiUnsupportedHint =>
      'This device uses the built-in summary: sentences are picked from the source without a model.';

  @override
  String get aiModelTiers => 'Model tiers';

  @override
  String get aiWhyLocal => 'Why it runs on this device';

  @override
  String get aiTextStaysLocal => 'Your text stays on this device';

  @override
  String get aiTextStaysLocalBody =>
      'Selected and chapter text is processed only on this phone; nothing is uploaded and no remote log is written. Downloads use HTTPS from the litert-community organization on Hugging Face.';

  @override
  String get aiNoConfigNeeded => 'No configuration needed';

  @override
  String get aiNoConfigNeededBody =>
      'The built-in summary uses a pure-Dart extractive algorithm (picking the most informative sentences) with no network and no model download. It fits \"just show me the gist\" and will struggle with complex questions.';

  @override
  String get aiTryIt => 'Try it';

  @override
  String get aiTryHint =>
      'Paste some text to see whether it can summarize the key points';

  @override
  String get aiTryAction => 'Try it';

  @override
  String get aiCloudReady => 'Cloud model ready';

  @override
  String get aiOnDeviceReady => 'On-device model ready';

  @override
  String get aiExtractiveReady => 'Built-in summary available';

  @override
  String aiProbeFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get aiOrphanFiles => 'Other model files on this device';

  @override
  String get aiOrphanBody =>
      'Not in the current model catalog (left over from an earlier version)';

  @override
  String get aiRecommended => 'Recommended';

  @override
  String aiDownloading(int percent) {
    return 'Downloading $percent%';
  }

  @override
  String aiDownloadingMirror(int percent) {
    return 'Downloading $percent% (direct host unreachable, using the hf-mirror mirror)';
  }

  @override
  String aiDownload(String size) {
    return 'Download ($size)';
  }

  @override
  String get aiInUse => 'In use';

  @override
  String get aiSetCurrent => 'Set as current';

  @override
  String get aiAssistant => 'AI assistant';

  @override
  String get aiExpandAssistant => 'Expand AI assistant';

  @override
  String get aiNotProbed => 'Not probed yet';

  @override
  String get aiPlatformExtractive =>
      'This platform uses the built-in summary (on-device models are Android/iOS only)';

  @override
  String get aiPlatformUnsupported =>
      'This platform does not support on-device models; the built-in summary is used automatically';

  @override
  String get aiDownloadFailedNetwork =>
      'Download failed: neither the direct host nor the mirror is reachable (for a few hundred MB, retry on WiFi)';

  @override
  String get aiDownloadFailedStorage => 'Download failed: not enough storage';

  @override
  String get aiDownloadFailedAuth =>
      'Download failed: this model needs authorization (try another tier)';

  @override
  String aiDownloadFailed(String error) {
    return 'Download failed: $error';
  }

  @override
  String aiNoModelListNamed(String provider) {
    return '$provider has no model-list endpoint; enter one manually or tap a common model below';
  }

  @override
  String get aiPickProviderFirst => 'Pick a provider or enter a base URL first';

  @override
  String get aiNoModelListReturned =>
      'This provider didn\'t return a model list; enter the model id manually';

  @override
  String get aiTestIncomplete => 'Not complete yet (base URL + model)';

  @override
  String get aiTestNoText =>
      'Connected (the server returned no text; this model may not support this prompt)';

  @override
  String aiTestOk(String text) {
    return 'Connected: $text';
  }

  @override
  String get aiEngineReadyNoModel =>
      'The engine is ready, but no model has been downloaded yet';

  @override
  String get aiDownloadFailedShort => 'Download failed';

  @override
  String get aiExtractiveNotFound => 'The source does not mention it.';

  @override
  String get aiExtractivePassagesHeader =>
      'Most relevant passages from the source (excerpted directly, no model):\n';

  @override
  String get aiExtractiveTooShort => 'This passage is too short to summarize.';

  @override
  String get aiCloudNotConfiguredHint =>
      'Cloud is not set up yet: just fill in the base URL and model';

  @override
  String get aiCloudNotConfigured =>
      'Cloud is not set up yet: fill in the provider and model under Settings → AI service';

  @override
  String aiBudgetExhausted(String error, int from, int to) {
    return '$error; the maximum length was automatically raised from $from to $to and retried, but it still wrote no body. Raise the length further or switch to a non-reasoning model.';
  }

  @override
  String get aiExtractiveEngineDetail =>
      'No model: sentences are picked from the source';

  @override
  String get chatSectionUnread => 'Unread';

  @override
  String get dictPosNoun => 'Noun';

  @override
  String get dictPosVerb => 'Verb';

  @override
  String get dictPosAdjective => 'Adjective';

  @override
  String get dictPosAdverb => 'Adverb';

  @override
  String get dictPosPronoun => 'Pronoun';

  @override
  String get dictPosPreposition => 'Preposition';

  @override
  String get dictPosConjunction => 'Conjunction';

  @override
  String get dictPosInterjection => 'Interjection';

  @override
  String get dictPosNumeral => 'Numeral';

  @override
  String get dictPosPhrase => 'Phrase';

  @override
  String get dictPosOther => 'Other';

  @override
  String get bookDictTitle => 'Dictionary';

  @override
  String get bookDictLookup => 'Look up';

  @override
  String bookDictNotFound(String word) {
    return 'Not in the built-in dictionary: “$word”';
  }

  @override
  String get bookDictNotFoundHint =>
      'Go back to the selection menu and use Explain to let the AI cover it';

  @override
  String bookDictSource(int count) {
    return 'Built-in dictionary · $count words';
  }

  @override
  String get bookTtsReadAloud => 'Read aloud';

  @override
  String get bookExportNote => 'Save to Note';

  @override
  String get bookTtsTitle => 'Read this chapter';

  @override
  String get bookTtsPause => 'Pause';

  @override
  String get bookTtsResume => 'Resume';

  @override
  String get bookTtsStop => 'Stop';

  @override
  String get bookTtsNext => 'Next';

  @override
  String get bookTtsPrev => 'Previous';

  @override
  String bookTtsState(int n, int total) {
    return 'Paragraph $n of $total';
  }

  @override
  String get bookTtsIdle => 'Tap Play to start from the current paragraph';

  @override
  String get bookTtsResumeHint =>
      'Resume restarts this paragraph — the system voice has no mid-paragraph resume';

  @override
  String get bookTtsUnsupported => 'No speech engine available on this device';

  @override
  String bookTtsFailed(String error) {
    return 'Speech failed: $error';
  }

  @override
  String bookExportTitle(String book, int n) {
    return '“$book” · Excerpt from Chapter $n';
  }

  @override
  String get bookExportTagReader => 'Reading notes';

  @override
  String bookExportTagChapter(int n) {
    return 'Chapter $n';
  }

  @override
  String bookExportWhere(String book, int n) {
    return '“$book”, Chapter $n';
  }

  @override
  String bookExportWherePercent(String book, int n, int percent) {
    return '“$book”, Chapter $n · $percent%';
  }

  @override
  String bookExportSource(String where, int total) {
    return '$where ($total chapters)';
  }

  @override
  String bookExportSourceNamed(String where, String chapter, int total) {
    return '$where $chapter ($total chapters)';
  }

  @override
  String get bookExportNotebook => 'Reading notes';

  @override
  String bookExportNotebookReady(String notebook) {
    return 'Saved to “$notebook”';
  }

  @override
  String bookExportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String get bookExportTagFailed =>
      'Note created, but tags were not written (no version available)';

  @override
  String get bookLinkBack => 'Back';

  @override
  String get bookLinkNotFound =>
      'This link points to content that is not in the book';

  @override
  String bookLinkExternalFailed(String url) {
    return 'Could not open the link: $url';
  }

  @override
  String get bookSendChapterTitle => 'Send the whole chapter to AI?';

  @override
  String bookSendChapterBody(int chars) {
    return 'This chapter is about $chars characters. It can only be sent once a model is configured in AI settings; the cloud tier sends the text over the network, while on-device/built-in tiers stay on the phone. Only this chapter is sent.';
  }

  @override
  String get bookSendChapterConfirm => 'Send chapter';

  @override
  String get bookAiNoKey =>
      'AI is not configured yet: Settings → AI → Cloud model, fill in the URL and key';

  @override
  String get bookAiNoKeyShort => 'AI is not configured';

  @override
  String get aiProtoOpenai => 'OpenAI compatible';

  @override
  String get aiProvOpenaiNote =>
      'Direct access from mainland China usually fails — use a proxy or relay URL';

  @override
  String get aiProvAnthropicNote =>
      'Messages protocol: auth via x-api-key, and the anthropic-version header is required';

  @override
  String get aiProvGeminiNote =>
      'Key goes in the query string; direct access from mainland China usually needs a proxy';

  @override
  String get aiProvDeepseekName => 'DeepSeek';

  @override
  String get aiProvDeepseekNote =>
      'Strong Chinese/code ability at a low price (official examples use api.deepseek.com; /v1 also works)';

  @override
  String get aiProvMoonshotNote => 'Strong at long context';

  @override
  String get aiProvZhipuName => 'Zhipu GLM';

  @override
  String get aiProvZhipuKeyHint => 'Looks like id.secret';

  @override
  String get aiProvZhipuNote =>
      'Base URL includes /api/paas/v4; no model-list endpoint, so enter the model id by hand';

  @override
  String get aiProvDashscopeName => 'Alibaba Bailian (Qwen)';

  @override
  String get aiProvDashscopeNote =>
      'You must use the compatible-mode path; no documented model-list endpoint, so enter the model id by hand; the newer domain includes a WorkspaceId and keys are region-bound (a Beijing key calling Singapore returns 401)';

  @override
  String get aiProvSiliconflowName => 'SiliconFlow';

  @override
  String get aiProvSiliconflowNote => 'One key covers many open-source models';

  @override
  String get aiProvVolcesName => 'Volcengine Ark (Doubao)';

  @override
  String get aiProvVolcesKeyHint => 'Looks like a UUID';

  @override
  String get aiProvVolcesNote =>
      'The model id must be an inference endpoint (ep-…); the official docs site is JS-rendered so the base URL could not be verified word by word — switch to a relay URL if it will not connect';

  @override
  String get aiProvOpenrouterNote => 'One key routes to hundreds of models';

  @override
  String get aiProvQianfanName => 'Baidu Qianfan';

  @override
  String get aiProvQianfanNote =>
      'Base URL includes /v2; the key is the long bce-v3 style string';

  @override
  String get aiProvHunyuanName => 'Tencent Hunyuan';

  @override
  String get aiProvHunyuanNote =>
      'No official model-list endpoint, so enter the model id by hand; it will move to TokenHub later';

  @override
  String get aiProvOllamaName => 'Ollama (local/LAN)';

  @override
  String get aiProvOllamaKeyHint =>
      'Ollama does not check it — leaving it blank is fine';

  @override
  String get aiProvOllamaNote =>
      'Default port 11434; when the phone connects to a computer, replace localhost with the computer\'s LAN IP. The OpenAI-compatible layer requires a key field but ignores it, so we fill in a placeholder automatically';

  @override
  String get aiProvLmstudioName => 'LM Studio (local/LAN)';

  @override
  String get aiProvLmstudioKeyHint => 'Not checked — anything or blank';

  @override
  String get aiProvLmstudioNote => 'Default port 1234';

  @override
  String get aiProvVllmName => 'vLLM / self-hosted OpenAI service';

  @override
  String get aiProvVllmKeyHint => 'Depends on your server config';

  @override
  String get aiProvVllmNote =>
      'Default port 8000; gateways like one-api / new-api / LiteLLM also use this';

  @override
  String get aiProvCustomName => 'Custom / relay URL';

  @override
  String get aiProvCustomKeyHint => 'Fill in as your provider requires';

  @override
  String get aiProvCustomNote =>
      'Enter the full base URL (including the version path) and pick a protocol';

  @override
  String get aiModelPickerManual => 'Enter the model id by hand';

  @override
  String get aiModelPickerCommon => 'Or pick from these common models';

  @override
  String aiErrRequestRejected(String tail) {
    return 'Request rejected (400)$tail';
  }

  @override
  String aiErrKeyInvalid(String tail) {
    return 'API key is invalid or expired (401)$tail';
  }

  @override
  String aiErrInsufficientBalance(String tail) {
    return 'Insufficient balance (402)$tail';
  }

  @override
  String aiErrNoPermission(String tail) {
    return 'No permission or region-restricted (403)$tail';
  }

  @override
  String aiErrNotFound(String tail, String url) {
    return 'Address or model not found (404)$tail — check the base URL and model id$url';
  }

  @override
  String aiErrBodyTooLarge(String tail) {
    return 'Request body too large (413)$tail';
  }

  @override
  String aiErrParamsRejected(String tail) {
    return 'Parameters rejected (422)$tail';
  }

  @override
  String aiErrRateLimited(String tail) {
    return 'Rate limited or out of quota (429) — try again later$tail';
  }

  @override
  String aiErrServer(int code, String tail) {
    return 'Server error ($code)$tail';
  }

  @override
  String aiErrRequestFailed(int code, String tail) {
    return 'Request failed ($code)$tail';
  }

  @override
  String aiErrNotJson(String error) {
    return 'The server did not return JSON (a gateway or login page may have intercepted it): $error';
  }

  @override
  String get aiErrNoStream =>
      'The server returned no content (this model may not support streaming)';

  @override
  String aiErrModelError(String message) {
    return 'The model returned an error: $message';
  }

  @override
  String get aiErrNoContent =>
      'The model returned nothing (the gateway may have ignored the streaming request; try another model or check the URL)';

  @override
  String get aiTruncatedNote =>
      '\n\n(The answer hit the length limit and was truncated; raise the maximum length in AI Service → Advanced)';

  @override
  String aiReasoningOnlyBudget(int budget, int chars, String reason) {
    return 'The model spent all $budget tokens on reasoning and wrote no answer (received $chars characters of thinking)';
  }

  @override
  String aiReasoningOnlyPlain(int chars) {
    return 'The model returned only its reasoning, no answer (received $chars characters of reasoning)';
  }

  @override
  String aiErrConnectTimeout(String host) {
    return 'Connection timed out: cannot reach $host (check the network, proxy, or URL)';
  }

  @override
  String get aiErrWaitTimeout =>
      'Timed out waiting for a response: the model sent no data for too long (try a faster model)';

  @override
  String get aiErrBadCertificate =>
      'Certificate check failed (a self-signed certificate must be trusted first)';

  @override
  String get aiErrCancelled => 'Cancelled';

  @override
  String aiErrLocalService(String host) {
    return 'Cannot reach $host: for a local service, use the computer/server **LAN IP** on the phone, not localhost';
  }

  @override
  String aiErrUnreachable(String host) {
    return 'Cannot reach $host: the network is down or blocked (direct access from mainland China usually needs a proxy)';
  }

  @override
  String aiErrUnknown(String error) {
    return 'Request error: $error';
  }

  @override
  String get aiCancelReason => 'Cancelled by user';

  @override
  String get aiCompleteSystemDefault => 'You are a concise assistant.';

  @override
  String get aiCompleteUserDefault =>
      'Reply with exactly three words: connection succeeded';

  @override
  String get aiProfileNeedProvider => 'Pick a provider before saving a profile';

  @override
  String get aiProfileKeepOne => 'Keep at least one profile';

  @override
  String get aiProfileUntitled => 'Untitled profile';

  @override
  String get aiProfilesTitle => 'Profiles';

  @override
  String aiProfileCount(int n) {
    return '$n total';
  }

  @override
  String get aiProfileKeyNote =>
      'Keys still live only in the system secure storage, never in the profile table';

  @override
  String get aiProfileEmpty => 'No saved profiles yet';

  @override
  String get aiProfileSaveAs => 'Save as new profile';

  @override
  String get aiProfileSaveAsHint =>
      'Save the current settings as a profile for one-tap switching (multiple per provider allowed)';

  @override
  String aiProfileSaved(String name) {
    return 'Saved as “$name”';
  }

  @override
  String get aiProfileRename => 'Rename';

  @override
  String get aiProfileDelete => 'Delete profile';

  @override
  String aiProfileDeleteConfirm(String name) {
    return 'Delete “$name”? Its key will also be removed from secure storage.';
  }

  @override
  String aiProfileDeleted(String name) {
    return 'Deleted “$name”';
  }

  @override
  String get aiProfileNameHint => 'e.g. Work relay / Home Ollama';

  @override
  String get aiProfileSwitch => 'Switch';

  @override
  String get aiProfileNone => 'Not configured yet';

  @override
  String get aiUsageTitle => 'Usage & cost';

  @override
  String get usageObjTask => 'Task';

  @override
  String get usageObjOther => 'Other';

  @override
  String get usageObjVoice => 'Voice';

  @override
  String get usageObjTemplate => 'Template';

  @override
  String get usageObjRss => 'RSS';

  @override
  String get usageObjNote => 'Note';

  @override
  String get usageObjEmule => 'eMule';

  @override
  String get usageObjVideoFrame => 'Video frame';

  @override
  String get usageObjSong => 'Song';

  @override
  String get usageObjFolder => 'Folder';

  @override
  String get usageObjEvent => 'Event';

  @override
  String get usageObjDm => 'Direct message';

  @override
  String get usageObjSystem => 'System';

  @override
  String get usageObjMessage => 'Message';

  @override
  String get usageObjMessages => 'Messages';

  @override
  String get usageObjFindme => 'Find me';

  @override
  String get usageObjFile => 'File';

  @override
  String get usageObjBeep => 'Beep';

  @override
  String get usageObjUrl => 'URL';

  @override
  String get usageObjMagnet => 'Magnet link';

  @override
  String get usageObjTts => 'Speech';

  @override
  String get usageObjTodo => 'To-do';

  @override
  String get usageObjText => 'Text';

  @override
  String get usageObjSnooze => 'Snoozed';

  @override
  String get usageObjSnoozeSchedule => 'Snooze schedule';

  @override
  String get usageObjProfile => 'Profile';

  @override
  String get usageObjPollResults => 'Poll results';

  @override
  String get usageObjMonth => 'Month';

  @override
  String get usageObjMail => 'Mail';

  @override
  String get usageObjContact => 'Contact';

  @override
  String get usageObjChapter => 'Chapter';

  @override
  String get usageObjCamera => 'Camera';

  @override
  String get usageObjBt => 'Bluetooth';

  @override
  String get usageObjBackup => 'Backup';

  @override
  String get usageObjAlbumSort => 'Album sort';

  @override
  String get usageObjAiSelect => 'AI pick';

  @override
  String get usageObjNas => 'File Station';

  @override
  String get usageFailOther => 'Uncategorized';

  @override
  String get aiServerChannelDesc =>
      'Server-side generation detected: chat can answer with the NAS (your text is sent to the NAS)';

  @override
  String get aiServerChannelTitle => 'NAS-side AI channel';

  @override
  String get aiUsageEntry => 'Locally estimated usage & cost';

  @override
  String get aiUsageEstimateNote =>
      'These figures are estimated locally from call records: token counts prefer the server-returned usage and fall back to character counts; cost uses a built-in price table. This is not your provider bill — check the official console.';

  @override
  String aiUsagePriceNote(String date) {
    return 'Price table updated $date, covering common models only; unknown models are marked “unknown” and self-hosted/local services count as 0.';
  }

  @override
  String get aiUsageRangeAll => 'All';

  @override
  String get aiUsageRange7 => 'Last 7 days';

  @override
  String get aiUsageRange30 => 'Last 30 days';

  @override
  String get aiUsageEmpty => 'No cloud calls recorded yet';

  @override
  String get aiUsageEmptyHint =>
      'Run one summary with a cloud model and data will show up here';

  @override
  String aiUsageCalls(int n) {
    return '$n calls';
  }

  @override
  String aiUsagePromptTokens(int n) {
    return 'Input tokens: $n';
  }

  @override
  String aiUsageCompletionTokens(int n) {
    return 'Output tokens: $n';
  }

  @override
  String aiUsageTotalTokens(int n) {
    return 'Total tokens: $n';
  }

  @override
  String aiUsageReasoningTokens(int n) {
    return 'Of which reasoning: $n';
  }

  @override
  String aiUsageEstimatedCalls(int n) {
    return '$n calls used estimated tokens';
  }

  @override
  String aiUsageUnpriced(int n) {
    return '$n calls unpriced (price unknown)';
  }

  @override
  String aiUsageCost(String amount) {
    return 'about $amount';
  }

  @override
  String get aiUsageByModel => 'By model';

  @override
  String get aiUsageByDay => 'By day';

  @override
  String get aiUsageClear => 'Clear stats';

  @override
  String get aiUsageClearConfirm =>
      'Clear local usage records? (Your provider bill is unaffected.)';

  @override
  String get aiUsageCleared => 'Usage records cleared';

  @override
  String get aiThinkingFold => 'Show reasoning';

  @override
  String get aiThinkingCollapse => 'Hide reasoning';

  @override
  String aiThinkingChars(int n) {
    return '$n chars';
  }

  @override
  String get aiThinkingCopy => 'Copy reasoning';

  @override
  String get aiThinkingCopied => 'Reasoning copied';

  @override
  String get aiUsageCostUnknown => 'Price unknown';

  @override
  String get wsRecentTitle => 'Recent';

  @override
  String get bookContinueTitle => 'Continue reading';

  @override
  String bookContinuePercent(int pct) {
    return '$pct% read';
  }

  @override
  String bookContinueProgress(int n, int total, int pct) {
    return 'Chapter $n/$total · $pct%';
  }

  @override
  String get dsTitle => 'Downloads';

  @override
  String get dsStatusDownloading => 'Downloading';

  @override
  String get dsStatusError => 'Error';

  @override
  String get dsStatusWaiting => 'Waiting';

  @override
  String get dsStatusPaused => 'Paused';

  @override
  String get dsStatusSeeding => 'Seeding';

  @override
  String get dsStatusPreSeeding => 'Pre-seeding';

  @override
  String get dsStatusHashChecking => 'Checking';

  @override
  String get dsStatusFinishing => 'Finishing';

  @override
  String get dsStatusExtracting => 'Extracting';

  @override
  String get dsStatusPreprocessing => 'Preprocessing';

  @override
  String get dsStatusPostprocessing => 'Post-processing';

  @override
  String get dsStatusDownloaded => 'Downloaded';

  @override
  String get dsStatusCaptchaNeeded => 'Verification required';

  @override
  String get dsStatusFilehostingWaiting => 'Waiting for file hosting';

  @override
  String dsStatusCode(int code) {
    return 'Status $code';
  }

  @override
  String get dsStatusErrBrokenLink => 'Broken link';

  @override
  String get dsStatusErrDestNotExist => 'Destination folder not found';

  @override
  String get dsStatusErrDestDeny => 'No permission for the destination folder';

  @override
  String get dsStatusErrDiskFull => 'Disk is full';

  @override
  String get dsStatusErrQuota => 'Storage quota exceeded';

  @override
  String get dsStatusErrTimeout => 'Download timed out';

  @override
  String get dsStatusErrFileSize => 'Exceeds the file system size limit';

  @override
  String get dsStatusErrTorrentDuplicate =>
      'This torrent is already in the task list';

  @override
  String get dsStatusErrFileNotExist => 'File not found';

  @override
  String get dsStatusErrExtractFailed => 'Extraction failed';

  @override
  String get dsStatusErrExtractPassword => 'Wrong extraction password';

  @override
  String get dsStatusErrExtractInvalid => 'The archive is corrupted';

  @override
  String get dsStatusErrTorrentInvalid => 'Invalid torrent file';

  @override
  String get dsStatusErrRequiredAccount => 'Account required';

  @override
  String get dsStatusErrTryLater => 'Server busy, try again later';

  @override
  String get dsStatusErrNameTooLong => 'The file name is too long';

  @override
  String get dsLoadFailed => 'Couldn\'t load download tasks';

  @override
  String get dsEmptyTitle => 'No download tasks yet';

  @override
  String get dsEmptyMessage =>
      'Tap New task to add a link, magnet, or torrent file';

  @override
  String get dsEmptyFiltered => 'No tasks in this category';

  @override
  String get dsErrNotInstalled =>
      'Download Station is not installed on this NAS';

  @override
  String get dsErrNoPrivilege =>
      'This account has no permission to use Download Station';

  @override
  String get dsErrNetwork =>
      'Network connection failed; check your network and try again';

  @override
  String get dsErrLoadDetail => 'Couldn\'t load task details';

  @override
  String get dsErrTaskNotFound => 'Task not found (it may have been removed)';

  @override
  String get dsErrNoDefaultDest =>
      'No default download folder is set; specify one first';

  @override
  String get dsErrUploadFailed => 'Failed to upload the torrent file';

  @override
  String get dsErrReachLimit => 'Task limit reached';

  @override
  String get dsErrRequestInvalid => 'The request parameters were rejected';

  @override
  String get dsErrJsonParse => 'The server could not parse the request';

  @override
  String get dsErrActionFailed => 'The operation failed';

  @override
  String get dsErrSystem => 'Download Station service error';

  @override
  String get dsErrPathNotExist => 'Path not found';

  @override
  String get dsErrUnlinkFailed =>
      'Failed to delete files (the task may still be removed)';

  @override
  String get dsErrDemo => 'This action is not allowed in demo mode';

  @override
  String dsErrUnknown(int code) {
    return 'Unknown error ($code)';
  }

  @override
  String get dsPause => 'Pause';

  @override
  String get dsResume => 'Resume';

  @override
  String get dsDeleteTitle => 'Delete tasks?';

  @override
  String get dsDeleteBody =>
      'The task will be removed from the download list. This cannot be undone.';

  @override
  String dsDeleteBodyN(int n) {
    return 'The $n selected tasks will be removed from the download list. This cannot be undone.';
  }

  @override
  String get dsDeleted => 'Deleted';

  @override
  String dsDeleteFailed(String msg) {
    return 'Couldn\'t delete: $msg';
  }

  @override
  String dsPauseFailed(String msg) {
    return 'Couldn\'t pause: $msg';
  }

  @override
  String dsResumeFailed(String msg) {
    return 'Couldn\'t resume: $msg';
  }

  @override
  String get dsStatusLabel => 'Status';

  @override
  String get dsProgress => 'Progress';

  @override
  String get dsSize => 'Size';

  @override
  String get dsDownloadSpeed => 'Download speed';

  @override
  String get dsUploadSpeed => 'Upload speed';

  @override
  String get dsEta => 'Time left';

  @override
  String get dsDestination => 'Download folder';

  @override
  String get dsType => 'Type';

  @override
  String get dsHash => 'Hash';

  @override
  String get dsPeers => 'Peers';

  @override
  String get dsCreator => 'Created by';

  @override
  String get dsAddedTime => 'Added';

  @override
  String get dsCompletedTime => 'Completed';

  @override
  String get dsDetail => 'Task details';

  @override
  String get dsTaskId => 'Task ID';

  @override
  String dsTotalDown(String rate) {
    return 'Down $rate';
  }

  @override
  String dsTotalUp(String rate) {
    return 'Up $rate';
  }

  @override
  String dsTotalTasks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tasks',
      one: '1 task',
    );
    return '$_temp0';
  }

  @override
  String get dsNewTask => 'New task';

  @override
  String get dsCreateUrl => 'Link';

  @override
  String get dsCreateFile => 'Torrent file';

  @override
  String get dsUrlHint =>
      'Supports HTTP, FTP, magnet, and Thunder links, one per line';

  @override
  String get dsUrlRequired => 'Enter at least one link';

  @override
  String get dsTooManyUrls => 'You can add up to 50 links at a time';

  @override
  String get dsPickTorrent => 'Choose a .torrent or .nzb file';

  @override
  String get dsFileTooLarge => 'The file cannot exceed 100 MB';

  @override
  String get dsChooseDestination =>
      'Download folder (leave blank to use the default)';

  @override
  String dsDefaultDestination(String path) {
    return 'Default: $path';
  }

  @override
  String get dsExtractPassword => 'Extraction password';

  @override
  String get dsExtractPasswordHint =>
      'Optional; required for encrypted archives';

  @override
  String get dsCreated => 'Task created';

  @override
  String dsCreateFailed(String msg) {
    return 'Couldn\'t create the task: $msg';
  }

  @override
  String get dsCreateList => 'Choose files before downloading';

  @override
  String get dsCreateListHint =>
      'Useful when you only want some files from a torrent';

  @override
  String get dsBtSettings => 'BT settings';

  @override
  String get dsBtMaxDownload => 'Max download (KB/s)';

  @override
  String get dsBtMaxUpload => 'Max upload (KB/s)';

  @override
  String get dsBtSeedingRatio => 'Seeding ratio';

  @override
  String get dsBtSeedingInterval => 'Seeding time (minutes)';

  @override
  String get dsBtMaxPeers => 'Max peers';

  @override
  String get dsBtUnlimited => 'Unlimited';

  @override
  String get dsBtRateHint => '0 means unlimited';

  @override
  String get dsBtSaved => 'BT settings saved';

  @override
  String dsBtSaveFailed(String msg) {
    return 'Couldn\'t save: $msg';
  }

  @override
  String get dsBtLoadFailed => 'Couldn\'t load BT settings';

  @override
  String get dsBtNotSupported => 'This task is not a torrent';

  @override
  String get dsNotInstalledHint =>
      'Install Download Station from DSM Package Center to use this module';

  @override
  String get dsNoPrivilegeHint =>
      'Ask an administrator to grant this account Download Station access';

  @override
  String get pbTitle => 'Phone backup';

  @override
  String get pbAutoBackup => 'Automatic backup';

  @override
  String get pbAutoBackupHint =>
      'When on, open this page to run an incremental backup';

  @override
  String get pbCancel => 'Cancel';

  @override
  String pbCountFailed(int n) {
    return '$n failed';
  }

  @override
  String pbCountPending(int n) {
    return '$n queued';
  }

  @override
  String pbCountSkipped(int n) {
    return '$n skipped';
  }

  @override
  String get pbErrorTitle => 'Backup failed';

  @override
  String get pbFailedTitle => 'Failed files';

  @override
  String get pbFolderPickTitle => 'Choose the destination album';

  @override
  String get pbGrant => 'Allow access';

  @override
  String get pbIncludeVideos => 'Back up videos';

  @override
  String pbLastFinished(String time) {
    return 'Last finished: $time';
  }

  @override
  String get pbNeverFinished => 'No backup has run yet';

  @override
  String get pbNotConnected => 'Not connected to the NAS yet';

  @override
  String get pbNothingToDo => 'Nothing new to back up';

  @override
  String get pbPause => 'Pause';

  @override
  String get pbPermissionDenied =>
      'Without permission the app can\'t read your photos. Allow access to \"Photos and videos\" and try again.';

  @override
  String get pbPermissionGranted => 'Photo library access granted';

  @override
  String get pbPermissionPartial =>
      'Only the selected photos were allowed, so the backup will be incomplete. Switch to \"Allow all\".';

  @override
  String get pbPermissionTitle => 'Photo library access';

  @override
  String get pbPreparing =>
      'Scanning your photo library and comparing with the NAS…';

  @override
  String pbProgress(int done, int total) {
    return 'Backed up $done/$total';
  }

  @override
  String get pbResume => 'Resume';

  @override
  String get pbRetryFailed => 'Retry failed';

  @override
  String get pbStart => 'Start backup';

  @override
  String get pbTargetCreate => 'Create destination album';

  @override
  String get pbTargetNone => 'No destination album selected';

  @override
  String pbTargetReady(String name) {
    return 'Destination: $name';
  }

  @override
  String get pbTargetTitle => 'Destination album';

  @override
  String get pbWifiBlocked =>
      'Not on Wi-Fi, so the \"Wi-Fi only\" rule paused the backup';

  @override
  String get pbWifiOnly => 'Back up on Wi-Fi only';

  @override
  String get ptClearSelection => 'Clear all';

  @override
  String get ptExitSelection => 'Exit selection';

  @override
  String get ptSelectAll => 'Select all';

  @override
  String ptSelectedCount(int n) {
    return '$n selected';
  }

  @override
  String ptSelectedTags(int n) {
    return '$n tags selected';
  }

  @override
  String get ptTag => 'Tag';

  @override
  String ptTagApplied(int n) {
    return 'Tagged $n photos';
  }

  @override
  String ptTagApplyFailed(String msg) {
    return 'Couldn\'t apply tags: $msg';
  }

  @override
  String ptTagCreate(String name) {
    return 'Create tag \"$name\"';
  }

  @override
  String ptTagCreateFailed(String msg) {
    return 'Couldn\'t create tag: $msg';
  }

  @override
  String ptTagFailed(int n) {
    return '$n actions failed';
  }

  @override
  String get ptTagLoadFailed => 'Couldn\'t load tags; you can still create one';

  @override
  String get ptTagNone => 'No tags yet';

  @override
  String get ptTagSearchHint => 'Search or create a tag';

  @override
  String ptTagSheetTitle(int n) {
    return 'Tags ($n photos selected)';
  }

  @override
  String ptTagUpdated(int n) {
    return 'Updated tags on $n photos';
  }

  @override
  String pbAllDone(int done, int skipped) {
    return 'Backup complete: $done added, $skipped skipped';
  }

  @override
  String get asTitle => 'Music';

  @override
  String get asTabSongs => 'Songs';

  @override
  String get asTabAlbums => 'Albums';

  @override
  String get asTabArtists => 'Artists';

  @override
  String get asTabGenres => 'Genres';

  @override
  String get asTabFolders => 'Folders';

  @override
  String get asTabPlaylists => 'Playlists';

  @override
  String get asSearchTitle => 'Search music';

  @override
  String get asSearchHint => 'Search songs, albums or artists';

  @override
  String get asSearchEmpty => 'No matching music found';

  @override
  String get asSearchFailed => 'Search failed';

  @override
  String get asSearchGroupSongs => 'Songs';

  @override
  String get asSearchGroupAlbums => 'Albums';

  @override
  String get asSearchGroupArtists => 'Artists';

  @override
  String get asSearchGroupGenres => 'Genres';

  @override
  String get asSearchGroupComposers => 'Composers';

  @override
  String get asEmptySongs => 'No songs in the music library yet';

  @override
  String get asEmptyAlbums => 'No albums yet';

  @override
  String get asEmptyArtists => 'No artists yet';

  @override
  String get asEmptyGenres => 'No genres yet';

  @override
  String get asEmptyFolders => 'This folder is empty';

  @override
  String get asEmptyPlaylists => 'No playlists yet';

  @override
  String get asLoadFailed => 'Failed to load the music library';

  @override
  String get asErrNotInstalled => 'Audio Station is not installed on this NAS';

  @override
  String get asNotInstalledHint =>
      'Install Audio Station from DSM Package Center to use it';

  @override
  String get asErrNoPrivilege =>
      'This account has no permission to use Audio Station';

  @override
  String get asNoPrivilegeHint =>
      'Ask an administrator to grant access to Audio Station';

  @override
  String get asErrLoadMoreFailed => 'Failed to load more';

  @override
  String get asErrNetwork =>
      'Network connection failed, please check and retry';

  @override
  String get asErrPlaylistNameInvalid => 'The playlist name is not accepted';

  @override
  String get asErrRadioBadRequest =>
      'The server did not accept this radio request';

  @override
  String get asErrFileExists => 'A file with the same name already exists';

  @override
  String get asErrTooManySongs => 'The number of songs has reached the limit';

  @override
  String get asErrDuplicateSongs => 'There are duplicate songs';

  @override
  String get asErrPlaylistNotExists =>
      'The playlist does not exist (DSM may be reindexing)';

  @override
  String get asErrSharedPlaylistRating =>
      'Songs with rating rules cannot be copied into a shared playlist';

  @override
  String get asErrPinExists => 'This item is already in your favorites';

  @override
  String get asErrPinNotExists => 'This favorite does not exist';

  @override
  String get asErrPinTargetNotExists => 'The item to favorite does not exist';

  @override
  String get asErrInvalidPassword => 'Incorrect password';

  @override
  String asErrUnknown(int code) {
    return 'Unknown error ($code)';
  }

  @override
  String asSongCount(int n) {
    return '$n songs';
  }

  @override
  String asAlbumCount(int n) {
    return '$n albums';
  }

  @override
  String asArtistCount(int n) {
    return '$n artists';
  }

  @override
  String get asDetailAlbums => 'Albums';

  @override
  String get asDetailSongs => 'Songs';

  @override
  String get asDetailArtists => 'Artists';

  @override
  String get asDetailFolders => 'Folders';

  @override
  String get asEmptyDetailSongs => 'No songs here yet';

  @override
  String get asEmptyDetailAlbums => 'No albums here yet';

  @override
  String get asEmptyDetailArtists => 'No artists here yet';

  @override
  String get asPlaylistLoadFailed => 'Failed to load the playlist';

  @override
  String get asSmartPlaylist => 'Smart playlist';

  @override
  String get asSharedPlaylist => 'Shared';

  @override
  String get asPersonalPlaylist => 'Personal';

  @override
  String get asFolderUp => 'Up one level';

  @override
  String get asPinsTitle => 'My favorites';

  @override
  String get asPinEmpty => 'No favorites yet';

  @override
  String get asPinEmptyHint =>
      'Tap \"Add to favorites\" on an album, artist, genre or playlist to see it here';

  @override
  String get asPinAdd => 'Add to favorites';

  @override
  String get asPinAdded => 'Added to favorites';

  @override
  String asPinAddFailed(String e) {
    return 'Failed to add favorite: $e';
  }

  @override
  String get asPinRemove => 'Remove from favorites';

  @override
  String get asPinRemoved => 'Removed from favorites';

  @override
  String asPinRemoveFailed(String e) {
    return 'Failed to remove favorite: $e';
  }

  @override
  String get asPinUnsupported => 'This favorite cannot be opened yet';

  @override
  String get asPinsLoadFailed => 'Failed to load favorites';

  @override
  String get asSongInfo => 'Song info';

  @override
  String get asLyrics => 'Lyrics';

  @override
  String get asLyricsEmpty => 'This song has no lyrics';

  @override
  String get asLyricsLoadFailed => 'Failed to load lyrics';

  @override
  String get asLyricsSearch => 'Search lyrics online';

  @override
  String get asLyricsSearchEmpty => 'No lyrics found online either';

  @override
  String get asLyricsSearchFailed => 'Failed to search lyrics online';

  @override
  String get asRating => 'Rating';

  @override
  String get asRatingUnset => 'Unrated';

  @override
  String get asRatingSet => 'Rating saved';

  @override
  String get asRatingCleared => 'Rating cleared';

  @override
  String asRatingFailed(String e) {
    return 'Failed to save rating: $e';
  }

  @override
  String get asStreamUrl => 'Streaming URL';

  @override
  String get asStreamUrlCopied => 'Streaming URL copied';

  @override
  String get asStreamUrlMaskedNote =>
      'The session credentials in this URL are masked; the copy button gives the full URL (it contains your session credentials - do not share it).';

  @override
  String get asStreamUrlCopiedWithToken =>
      'Full streaming URL copied (it contains your session credentials - do not share it)';

  @override
  String get asCopy => 'Copy';

  @override
  String get asPlay => 'Play';

  @override
  String get asClosePlayer => 'Close playback';

  @override
  String get asPause => 'Pause';

  @override
  String asPlayFailed(String e) {
    return 'Playback failed: $e';
  }

  @override
  String get asSongLoadFailed => 'Failed to load song info';

  @override
  String get asFieldArtist => 'Artist';

  @override
  String get asFieldAlbum => 'Album';

  @override
  String get asFieldAlbumArtist => 'Album artist';

  @override
  String get asFieldComposer => 'Composer';

  @override
  String get asFieldGenre => 'Genre';

  @override
  String get asFieldYear => 'Year';

  @override
  String get asFieldTrack => 'Track';

  @override
  String get asFieldDisc => 'Disc';

  @override
  String get asFieldDuration => 'Duration';

  @override
  String get asFieldBitrate => 'Bitrate';

  @override
  String get asFieldFrequency => 'Sample rate';

  @override
  String get asFieldChannels => 'Channels';

  @override
  String get asFieldFilesize => 'File size';

  @override
  String get asFieldCodec => 'Codec';

  @override
  String get asFieldPath => 'Path';

  @override
  String get asOpenFailed => 'Failed to open';

  @override
  String get mediaPrevious => 'Previous';

  @override
  String get mediaNext => 'Next';

  @override
  String get mediaBackward10 => 'Back 10 seconds';

  @override
  String get mediaForward10 => 'Forward 10 seconds';

  @override
  String get mediaVolume => 'Volume';

  @override
  String get mediaMute => 'Mute';

  @override
  String get mediaUnmute => 'Unmute';

  @override
  String get mediaAspect => 'Aspect ratio';

  @override
  String get mediaAspectFit => 'Fit, with black bars';

  @override
  String get mediaAspectFill => 'Fill, edges cropped';

  @override
  String get mediaAspectZoom => 'Zoom in, more cropped';

  @override
  String get mediaAspectStretch => 'Stretch to fill';

  @override
  String get mediaAudioTrack => 'Audio track';

  @override
  String get mediaSubtitle => 'Subtitles';

  @override
  String get mediaSubtitleOff => 'Subtitles off';

  @override
  String get mediaSubtitleAuto => 'Auto match';

  @override
  String get mediaNoTracks => 'Nothing to choose';

  @override
  String get mediaRotate => 'Rotate screen';

  @override
  String get mediaFullscreen => 'Fullscreen';

  @override
  String get mediaExitFullscreen => 'Exit fullscreen';

  @override
  String get mediaErrCodecUnsupported =>
      'The system decoder can\'t play this file\'s codec';

  @override
  String mediaAudioUnsupported(String codec) {
    return 'This device can\'t decode this audio track ($codec), so you\'d get picture without sound.';
  }

  @override
  String get mediaAudioUnsupportedSwitch => 'Switch track';

  @override
  String get mediaTrackUnsupported => 'Not on this device';

  @override
  String get mediaPip => 'Picture in picture';

  @override
  String get mediaErrNetworkFailed =>
      'Can\'t reach the file address (network down or session expired)';

  @override
  String get photoSectionPersons => 'People';

  @override
  String get photoSectionConcepts => 'Scenes';

  @override
  String get photoEmptyPersonsTitle => 'No people identified yet';

  @override
  String get photoEmptyPersonsMessage =>
      'Synology Photos identifies people in your indexed photos automatically.\nIf you just enabled face recognition, wait for the NAS to finish indexing.';

  @override
  String get photoEmptyPersonsDisabledTitle => 'Face recognition is off';

  @override
  String get photoEmptyPersonsDisabledMessage =>
      'Enable face recognition in DSM under \"Synology Photos → Settings → People\" (configured by an administrator); people show up here only after that.';

  @override
  String get photoPersonsMigratingTitle =>
      'Face recognition is still being organized';

  @override
  String get photoPersonsMigratingMessage =>
      'The NAS is still organizing faces in your indexed photos; people will appear here when it finishes.';

  @override
  String get photoErrPersonMigrating =>
      'Face recognition isn\'t finished on this NAS yet (Synology Photos is migrating), please try again later';

  @override
  String get photoEmptyPersonTitle => 'No photos for this person';

  @override
  String get photoEmptyPersonMessage =>
      'The photos may have been removed from this person\'s group.';

  @override
  String get photoPersonUntitled => 'Unnamed person';

  @override
  String get photoEmptyConceptsTitle => 'No scenes identified yet';

  @override
  String get photoEmptyConceptsMessage =>
      'Scenes (themes) are grouped automatically from photo content by Synology Photos; they appear after indexing finishes.';

  @override
  String get photoEmptyConceptsDisabledTitle => 'Scene recognition is off';

  @override
  String get photoEmptyConceptsDisabledMessage =>
      'Enable categories/scenes in DSM under \"Synology Photos → Settings\"; scenes show up here only after that.';

  @override
  String get photoEmptyConceptTitle => 'No photos in this scene';

  @override
  String get photoEmptyConceptMessage =>
      'The photos may have been removed from this scene\'s group.';

  @override
  String photoPhotoCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count photos',
      one: '1 photo',
    );
    return '$_temp0';
  }

  @override
  String get photoErrConceptClustering =>
      'Scene recognition isn\'t finished on this NAS yet (Synology Photos is organizing), please try again later';

  @override
  String get mailTitle => 'Mail';

  @override
  String get survTitle => 'Surveillance';

  @override
  String get survStatusLive => 'Live';

  @override
  String get survStatusSetting => 'Setting up';

  @override
  String get survStatusDisabled => 'Disabled';

  @override
  String get survStatusDisconnected => 'Disconnected';

  @override
  String get survStatusUnknown => 'Unknown status';

  @override
  String survCameraCount(int count) {
    return '$count cameras';
  }

  @override
  String get survEmptyTitle => 'No cameras yet';

  @override
  String get survEmptyMessage =>
      'Add cameras in Surveillance Station to view them here';

  @override
  String get survErrNotInstalled =>
      'Surveillance Station is not installed on this NAS';

  @override
  String get survNotInstalledHint =>
      'Install Surveillance Station from DSM Package Center to use it';

  @override
  String get survErrNoPrivilege =>
      'This account has no permission to use Surveillance Station';

  @override
  String get survNoPrivilegeHint =>
      'Ask an administrator to grant this account Surveillance Station access';

  @override
  String get survLoadFailed => 'Failed to load cameras';

  @override
  String get survStatusOffline => 'Offline';

  @override
  String survStatusOther(int code) {
    return 'Status ($code)';
  }

  @override
  String get survCameraDetailTitle => 'Camera';

  @override
  String get survDetailLoadFailed => 'Failed to load camera';

  @override
  String get survLiveSection => 'Live view';

  @override
  String get survLiveHint =>
      'Live streams play in an external player; use the URLs below';

  @override
  String get survLiveUnavailable =>
      'This camera is offline, so there is no live view right now';

  @override
  String get survSnapshot => 'Snapshot';

  @override
  String get survOpenSnapshot => 'Open snapshot';

  @override
  String get survRtspUrl => 'RTSP URL';

  @override
  String get survMjpegUrl => 'MJPEG URL';

  @override
  String get survCopyUrl => 'Copy URL';

  @override
  String get survCopyDone => 'URL copied';

  @override
  String get survPtzSection => 'PTZ';

  @override
  String get survPtzUp => 'Up';

  @override
  String get survPtzDown => 'Down';

  @override
  String get survPtzLeft => 'Left';

  @override
  String get survPtzRight => 'Right';

  @override
  String get survPtzHome => 'Home';

  @override
  String get survPtzZoomIn => 'Zoom in';

  @override
  String get survPtzZoomOut => 'Zoom out';

  @override
  String get survPtzPresetTitle => 'Presets';

  @override
  String get survPtzPresetEmpty => 'No presets on this camera';

  @override
  String get survPtzPresetFailed => 'Failed to load presets';

  @override
  String survPresetPosition(int n) {
    return 'Preset $n';
  }

  @override
  String survPtzMoveFailed(String reason) {
    return 'PTZ failed: $reason';
  }

  @override
  String get survRecordingsSection => 'Recordings';

  @override
  String get survRecordingsEmpty => 'No recent recordings';

  @override
  String get survRecordingsFailed => 'Failed to load recordings';

  @override
  String survRecordingCount(int count) {
    return '$count clips';
  }

  @override
  String survRecordingDuration(String duration) {
    return 'Duration $duration';
  }

  @override
  String get survRecordingEncrypted => 'Encrypted';

  @override
  String get mailEmptyTitle => 'No messages';

  @override
  String get mailEmptyMessage => 'This mailbox is empty';

  @override
  String get mailErrNotInstalled => 'MailPlus is not installed on this NAS';

  @override
  String get mailNotInstalledHint =>
      'Install MailPlus (and MailPlus Server first) from DSM Package Center';

  @override
  String get mailErrNoPrivilege =>
      'This account has no permission to use MailPlus';

  @override
  String get mailNoPrivilegeHint =>
      'Ask an administrator to grant this account MailPlus access';

  @override
  String get mailLoadFailed => 'Failed to load mailboxes';

  @override
  String get mailThreadsFailed => 'Failed to load messages';

  @override
  String get mailDetailFailed => 'Failed to load the message';

  @override
  String get mailRetry => 'Retry';

  @override
  String get mailNoSubject => '(no subject)';

  @override
  String mailThreadCount(int count) {
    return '$count messages';
  }

  @override
  String get mailUnread => 'Unread';

  @override
  String get mailFlagged => 'Starred';

  @override
  String get mailHasAttachment => 'Attachment';

  @override
  String get mailLoadMore => 'Load more';

  @override
  String get mailRefreshed => 'Refreshed';

  @override
  String get mailFrom => 'From';

  @override
  String get mailTo => 'To';

  @override
  String get mailDate => 'Date';

  @override
  String get mailAttachments => 'Attachments';

  @override
  String get mailNoBody => 'No readable body';

  @override
  String get mailMarkRead => 'Mark as read';

  @override
  String get mailMarkUnread => 'Mark as unread';

  @override
  String get mailStar => 'Star';

  @override
  String get mailUnstar => 'Unstar';

  @override
  String get mailMoveTo => 'Move to…';

  @override
  String get mailActionDone => 'Done';

  @override
  String mailActionFailed(String reason) {
    return 'Action failed: $reason';
  }

  @override
  String get mailUnreadInMailbox => 'Unread messages';

  @override
  String get mailCompose => 'Compose';

  @override
  String get mailSubject => 'Subject';

  @override
  String get mailCc => 'Cc';

  @override
  String get mailBcc => 'Bcc';

  @override
  String get mailBody => 'Body';

  @override
  String get mailSend => 'Send';

  @override
  String get mailSendDone => 'Message sent';

  @override
  String get mailSendFailed => 'Failed to send';

  @override
  String get mailNeedRecipient => 'Add at least one recipient';

  @override
  String get mailRecipientHint => 'Separate addresses with commas';

  @override
  String get mailQuotaFailed => 'Quota unavailable';

  @override
  String mailQuota(String used, String total) {
    return '$used of $total used';
  }

  @override
  String get survErrCamDisabled => 'This camera is disabled';

  @override
  String get survErrClientBlocked =>
      'This client has been blocked by an administrator';

  @override
  String get survErrCmsClosed =>
      'The recording server is closed; reload the page';

  @override
  String get survErrExecuteFailed => 'The operation failed';

  @override
  String get survErrLicense =>
      'Not enough camera licenses; contact an administrator';

  @override
  String get survErrNameRepeated => 'The name is already in use';

  @override
  String get survErrNetwork =>
      'Network connection failed; check your network and retry';

  @override
  String get survErrObjectNotExist =>
      'The object does not exist (it may have been deleted)';

  @override
  String get survErrParamInvalid => 'The request parameters were not accepted';

  @override
  String get survErrRecordingEncrypted =>
      'This recording is encrypted and cannot be played directly';

  @override
  String get survErrServiceDisabled =>
      'Surveillance Station service is currently unavailable';

  @override
  String get mailErrAttachmentDisabled =>
      'Attachment storage is disabled by an administrator';

  @override
  String get mailErrAuthRequired => 'Account authentication is required first';

  @override
  String get mailErrDailyFlow => 'Daily traffic limit exceeded';

  @override
  String get mailErrDatabase => 'The server database operation failed';

  @override
  String get mailErrDraftNotExist =>
      'The draft does not exist (it may have been sent or deleted)';

  @override
  String get mailErrIllegalAttachment =>
      'The message contains a disallowed attachment';

  @override
  String get mailErrImapConnection =>
      'Failed to connect to the receiving server';

  @override
  String get mailErrInvalid => 'Invalid request';

  @override
  String get mailErrInvalidAccount => 'Invalid mailbox account';

  @override
  String get mailErrLabelDuplicated => 'Duplicate label name';

  @override
  String get mailErrLabelNameTooLong => 'Label name is too long';

  @override
  String get mailErrLabelNotExist => 'Label does not exist';

  @override
  String get mailErrMailboxDuplicated => 'Duplicate mailbox name';

  @override
  String get mailErrMailboxNameTooLong => 'Mailbox name is too long';

  @override
  String get mailErrMailboxNotExist => 'Mailbox does not exist';

  @override
  String get mailErrNetwork =>
      'Network connection failed; check your network and retry';

  @override
  String get mailErrNoSpace => 'Not enough storage space';

  @override
  String get mailErrRecipientUnavailable => 'The recipient is unavailable';

  @override
  String get mailErrSendLocalOnly =>
      'Configuration allows sending only within this domain';

  @override
  String get mailErrSendQuota => 'Sending quota reached';

  @override
  String get mailErrSharedDisabled =>
      'Shared mailbox is disabled by an administrator';

  @override
  String get mailErrSmtpAuth =>
      'Failed to authenticate with the sending server';

  @override
  String get mailErrSmtpConnection => 'Failed to connect to the sending server';

  @override
  String get mailErrUnknownDesc => 'MailPlus returned an unknown error';

  @override
  String get mailErrUpgrading => 'MailPlus is upgrading; try again later';

  @override
  String get mailErrVersionMismatch =>
      'Client and server versions do not match';

  @override
  String get navHome => 'Home';

  @override
  String get navDrive => 'Drive';

  @override
  String get chatErrNotInstalled => 'Synology Chat is not installed';

  @override
  String get fileErrNotInstalled => 'File Station is not enabled';

  @override
  String get calErrNotInstalled => 'Calendar is not installed';

  @override
  String get driveErrNotInstalled => 'Synology Drive is not installed';

  @override
  String get officeErrNotInstalled => 'Synology Office is not installed';

  @override
  String get aiNotNasService => 'AI is not a NAS service and is unaffected';

  @override
  String get serviceCheckTitle => 'Service check';

  @override
  String get serviceCheckSubtitle =>
      'See each service\'s status and reason, and re-check';

  @override
  String get serviceRecheck => 'Check again';

  @override
  String get serviceRechecking => 'Checking…';

  @override
  String get serviceNeverChecked => 'Not checked yet';

  @override
  String get serviceShowHidden => 'Temporarily show hidden modules';

  @override
  String get serviceShowHiddenHint =>
      'Modules that are not installed or not permitted are hidden; turn on to show them temporarily';

  @override
  String get serviceStateAvailable => 'Available';

  @override
  String get serviceStatePartial => 'Partially available';

  @override
  String get serviceStateAbsent => 'Not installed';

  @override
  String get serviceStateUnauthorized => 'No permission';

  @override
  String get serviceStateSessionExpired => 'Session expired';

  @override
  String get serviceStateUnreachable => 'Network error';

  @override
  String get serviceStateUnknown => 'Not checked';

  @override
  String get serviceStateAvailableReason => 'Service is available';

  @override
  String get serviceStatePartialReason =>
      'Available (some features are unavailable on your NAS)';

  @override
  String get serviceStateUnknownReason =>
      'Not checked yet (will be checked after sign-in)';

  @override
  String get serviceUnauthorizedDetail =>
      'Installed, but this account has no permission to use it';

  @override
  String get serviceSessionExpiredTitle => 'Session expired';

  @override
  String get serviceRelogin => 'Sign in again';

  @override
  String get serviceUnreachableTitle => 'Cannot reach the NAS';

  @override
  String get serviceRetry => 'Retry';

  @override
  String get serviceRestrictedHint =>
      'You can still use the available services below, or check again.';

  @override
  String get serviceRestrictedNone =>
      'No other available services were detected.';

  @override
  String get serviceEntryUnauthorized =>
      'This account has no permission to use this service';

  @override
  String get serviceEntryUnreachable => 'Network unavailable, please retry';

  @override
  String get serviceEntrySessionExpired =>
      'Session expired, please sign in again';

  @override
  String serviceLastCheckedAt(String time) {
    return 'Last checked: $time';
  }

  @override
  String serviceSessionExpiredDetail(String reason) {
    return '$reason (the service was not deleted; just sign in again)';
  }

  @override
  String serviceUnreachableDetail(String reason) {
    return '$reason (the service is not hidden; you can retry)';
  }

  @override
  String serviceRestrictedAbsent(String services) {
    return 'This NAS does not provide $services';
  }

  @override
  String serviceRestrictedNoAccess(String services) {
    return '$services are currently unavailable to this account';
  }

  @override
  String serviceRestrictedReason(String label, String reason) {
    return '· $label: $reason';
  }

  @override
  String get photoVideoUnavailable =>
      'Video playback is unavailable on this NAS.';

  @override
  String get asStreamUnavailable =>
      'Audio streaming is unavailable on this NAS.';

  @override
  String get capabilityMissingHint =>
      'This feature is unavailable on your NAS.';

  @override
  String get mediaErrStreamRejected =>
      'The server refused this stream request (HTTP 4xx/5xx, or the response was not media).';

  @override
  String mediaAutoContinueNoPicture(String name) {
    return 'Auto-played the next item \"$name\", but it can\'t be played in-app. You can open it with your system player.';
  }

  @override
  String get globalSearchEntry => 'Search NAS globally';

  @override
  String get globalSearchEngine => 'Universal Search';

  @override
  String get globalSearchTitle => 'Global search';

  @override
  String get mediaErrFormatUnsupported =>
      'The system decoder usually can\'t handle this format (WMA/ASF, APE, WavPack, DSD, …). Open it with another app; files in the music library are transcoded on the server automatically.';

  @override
  String get asTranscodeFallbackHint =>
      'Your device usually can\'t decode this format, so server-side transcoding (mp3/wav) is used.';

  @override
  String get asTranscodeFailedHint =>
      'Retrying the server-transcoded stream. If it keeps failing, open the original file in another app.';

  @override
  String get photoC2Hub => 'Photos extras';

  @override
  String get photoC2HubTitle => 'More photo features';

  @override
  String get photoC2HubSubtitle =>
      'Shared · Places · Search · Tags · People · Conditional albums · Similar photos';

  @override
  String get photoC2Sharing => 'Shared albums';

  @override
  String get photoC2SharingEntry =>
      'Shared with me and shared by me — members, roles, link on/off';

  @override
  String get photoC2SharedWithMe => 'Shared with me';

  @override
  String get photoC2SharedByMe => 'Shared by me';

  @override
  String get photoC2SharedEmpty => 'No one has shared an album with you yet';

  @override
  String get photoC2SharedByMeEmpty => 'You haven\'t shared any album yet';

  @override
  String photoC2SharedFrom(String owner) {
    return 'Shared by $owner';
  }

  @override
  String photoC2ShareModifiedAt(String count) {
    return '$count items · shared';
  }

  @override
  String get photoC2Members => 'Members';

  @override
  String get photoC2MembersEmpty =>
      'No members yet; visitors can only see it through a shared link';

  @override
  String get photoC2AddMember => 'Add member';

  @override
  String get photoC2AddMemberEmpty => 'No users or groups available';

  @override
  String get photoC2RemoveMember => 'Remove member';

  @override
  String get photoC2RemoveMemberConfirm => 'Remove member?';

  @override
  String photoC2RemoveMemberBody(String name) {
    return 'After removal, $name will no longer see this album.';
  }

  @override
  String photoC2MemberRemoved(String name) {
    return 'Removed $name';
  }

  @override
  String photoC2MemberAdded(String name) {
    return 'Added $name';
  }

  @override
  String get photoC2RoleView => 'View only';

  @override
  String get photoC2RoleDownload => 'Can download';

  @override
  String get photoC2RoleUpload => 'Can upload';

  @override
  String get photoC2RoleManage => 'Can manage';

  @override
  String get photoC2RoleUpdated => 'Permission updated';

  @override
  String get photoC2ShareLink => 'Shared link';

  @override
  String get photoC2ShareLinkNone => 'No link yet';

  @override
  String get photoC2CopyLink => 'Copy link';

  @override
  String get photoC2LinkCopied => 'Link copied';

  @override
  String get photoC2LinkEnabled => 'Link sharing turned on';

  @override
  String get photoC2DisableLink => 'Turn off link sharing';

  @override
  String get photoC2DisableLinkConfirm => 'Turn off link sharing?';

  @override
  String get photoC2DisableLinkBody =>
      'Once turned off, anyone with the link can no longer open this album.';

  @override
  String get photoC2LinkClosed => 'Link sharing turned off';

  @override
  String get photoC2PasswordPending =>
      'Password sharing isn\'t supported yet (needs the CGI encryption channel)';

  @override
  String get photoC2PhotoRequest => 'Photo requests';

  @override
  String get photoC2PhotoRequestEntry =>
      'Manage the upload links you\'ve sent (deleting one disables it at once)';

  @override
  String get photoC2PhotoRequestEmpty => 'No photo requests yet';

  @override
  String get photoC2PhotoRequestDelete => 'Delete request';

  @override
  String get photoC2PhotoRequestDeleteConfirm => 'Delete photo request?';

  @override
  String get photoC2PhotoRequestDeleteBody =>
      'Deleting it disables the upload link at once; outside visitors can no longer upload through it.';

  @override
  String get photoC2PhotoRequestDeleted => 'Photo request deleted';

  @override
  String get photoC2PhotoRequestNeverExpires => 'Never expires';

  @override
  String photoC2PhotoRequestExpires(String count) {
    return 'Expires in $count seconds';
  }

  @override
  String get photoC2Geocoding => 'Places';

  @override
  String get photoC2GeocodingEntry =>
      'Browse photos by location (place names come from the NAS geocoding service)';

  @override
  String get photoC2GeocodingEmpty => 'No photos with a location yet';

  @override
  String get photoC2GeocodingServiceHint =>
      'Place names come from the geocoding service on your NAS; with it off, only coordinate groups are shown.';

  @override
  String photoC2GeocodingItemCount(String count) {
    return '$count photos';
  }

  @override
  String get photoC2Search => 'Search photos';

  @override
  String get photoC2SearchEntry =>
      'Find photos by keyword and open them in the full-screen viewer';

  @override
  String get photoC2SearchHint =>
      'Search file names, places, tags, people or camera';

  @override
  String get photoC2SearchEmpty => 'No matching photos';

  @override
  String get photoC2SearchNoKeyword => 'Type a keyword to start searching';

  @override
  String photoC2SearchResultCount(String count) {
    return '$count photos found';
  }

  @override
  String get photoC2SearchKeywordOnly =>
      'Only keyword is sent for now (other filter field names are verified and will be wired up later).';

  @override
  String get photoC2ConditionAlbum => 'Condition albums';

  @override
  String get photoC2ConditionAlbumEntry =>
      'Auto-built albums from time, place, people or tags';

  @override
  String get photoC2ConditionAlbumEmpty => 'No condition albums yet';

  @override
  String get photoC2ConditionAlbumDelete => 'Delete condition album';

  @override
  String get photoC2ConditionAlbumDeleteConfirm => 'Delete condition album?';

  @override
  String photoC2ConditionAlbumDeleteBody(String name) {
    return '\"$name\" will be moved to the recycle bin (the photos themselves are not affected).';
  }

  @override
  String get photoC2ConditionAlbumDeleted => 'Condition album deleted';

  @override
  String photoC2ConditionSummary(String summary) {
    return 'Condition: $summary';
  }

  @override
  String get photoC2ConditionNone => 'No condition';

  @override
  String get photoC2ConditionInvalid => 'Condition is no longer valid';

  @override
  String get photoC2ConditionPeek => 'Preview matching count';

  @override
  String photoC2ConditionPeekCount(String count) {
    return '$count photos match';
  }

  @override
  String get photoC2ConditionKindTime => 'Time';

  @override
  String get photoC2ConditionKindPlace => 'Place';

  @override
  String get photoC2ConditionKindPerson => 'People';

  @override
  String get photoC2ConditionKindTag => 'Tags';

  @override
  String get photoC2ConditionKindKeyword => 'Keyword';

  @override
  String get photoC2ConditionKindOther => 'Other';

  @override
  String get photoC2Similar => 'Similar photos';

  @override
  String get photoC2SimilarEntry =>
      'Official similar groups (needs the NAS similar index)';

  @override
  String get photoC2SimilarDisabled => 'Similar photos are off';

  @override
  String get photoC2SimilarDisabledHint =>
      'Turn on \"Similar photos\" in the Photos settings and groups will appear here.';

  @override
  String get photoC2SimilarIndexing => 'Similar index is still running';

  @override
  String photoC2SimilarIndexingHint(String count, String stage) {
    return '$count photos left to index (stage $stage).';
  }

  @override
  String get photoC2SimilarReady => 'Similar index is ready';

  @override
  String get photoC2SimilarEmpty => 'No similar groups yet';

  @override
  String get photoC2NoPermission => 'No permission';

  @override
  String get photoC2NoPermissionHint =>
      'Some features are hidden because your account lacks permission.';

  @override
  String get photoC2SessionHint =>
      'Your session has expired. Sign in again and retry.';

  @override
  String get photoC2EntryHidden => 'This feature is hidden';

  @override
  String get photoC2ActionFailed => 'Action failed';

  @override
  String get photoC2NotConnected => 'Not connected';

  @override
  String get photoC2NoPermissionBody =>
      'Your account doesn\'t have permission to access this feature.';

  @override
  String get officeDocsEntry => 'Office documents';

  @override
  String get officeDocsEntryHint => 'Only .odoc / .osheet / .oslides in Drive';

  @override
  String get officeDocsEmptyTitle => 'No Office documents in this folder';

  @override
  String officeDocsEmptyDetail(String path) {
    return 'No .odoc / .osheet / .oslides in \"$path\". Go back one level, or browse everything under Files → Drive.';
  }

  @override
  String get officeDocsNoPermission =>
      'No permission to access Synology Office (the Office documents entry is hidden)';

  @override
  String get officeViewerReadonlyBadge => 'Read-only preview';

  @override
  String get officeViewerNoEdit => 'Editing isn\'t supported yet';

  @override
  String get officeViewerParsing => 'Opening Office document…';

  @override
  String get officeViewerLoadFailedTitle => 'Can\'t open this Office document';

  @override
  String get officeViewerLoadFailedHint =>
      'The file may be damaged, or it isn\'t a valid Synology Office native document (.odoc/.osheet/.oslides).';

  @override
  String get officeViewerNotNativeDetail =>
      'This isn\'t a Synology Office native document (.odoc/.osheet/.oslides).';

  @override
  String get officeViewerDownloadFailedTitle => 'Couldn\'t read the file';

  @override
  String get officeViewerPasswordTitle => 'Document password required';

  @override
  String get officeViewerEncryptedSectionTitle => 'Some content is encrypted';

  @override
  String get officeViewerEncryptedSectionDetail =>
      'Only the unencrypted part is shown; decryption is planned for a later stage.';

  @override
  String get officeViewerTranscodedTitle => 'Got a converted file';

  @override
  String get officeViewerTranscodedDetail =>
      'This download path converted the Office native document into another format, so its bytes are no longer .odoc/.osheet/.oslides and it can\'t be opened.';

  @override
  String get officeViewerNoPermissionTitle =>
      'No permission to read this document';

  @override
  String get officeViewerNoPermissionDetail =>
      'Your account can\'t read or download this file.';

  @override
  String get officeViewerSessionTitle => 'Session expired';

  @override
  String get officeViewerSessionDetail =>
      'Your sign-in has expired. Please sign in again and retry.';

  @override
  String get officeViewerTooBigTitle => 'Document is too large to open inline';

  @override
  String officeViewerTooBig(String size) {
    return 'This document is $size, which is above the inline parsing limit.';
  }

  @override
  String get officeViewerTooBigHint =>
      'Download it to read, or try again on a faster connection.';

  @override
  String get officeViewerEmptyModel => 'There\'s nothing to display.';

  @override
  String officeViewerSheetCount(String n) {
    return '$n sheets';
  }

  @override
  String get officeViewerSheetEmpty => 'This workbook has no sheets';

  @override
  String get officeViewerSheetStyleNote =>
      'Headers and cell styles are shown as declared by the file.';

  @override
  String officeViewerSheetTruncated(String rows, String cols) {
    return 'Showing the first $rows rows × $cols columns (the sheet is larger; only the visible range is rendered).';
  }

  @override
  String officeViewerSheetMerges(String n) {
    return 'This sheet has $n merged cell range(s).';
  }

  @override
  String officeViewerDocChars(String n) {
    return '$n characters';
  }

  @override
  String get officeViewerDocEmpty =>
      'This document has no body blocks to display';

  @override
  String get officeViewerDocLayoutNote =>
      'Read-only rendering: headings, paragraphs, lists, tables and image references. Headers/footers, pagination and font colors are simplified.';

  @override
  String get officeViewerDocImageNote =>
      'Images: embedded image bytes aren\'t decoded yet, so they\'re shown as references (attachment id) below.';

  @override
  String officeViewerDocImagePlaceholder(String id) {
    return 'Image (attachment id: $id)';
  }

  @override
  String get officeViewerDocImageNoId => 'Image (no attachment id)';

  @override
  String officeViewerSlideCount(String n) {
    return '$n slides';
  }

  @override
  String get officeViewerSlidesEmpty => 'This presentation has no slides';

  @override
  String get officeViewerSlidesLayoutNote =>
      'Only the text and images of each slide are shown; layout is simplified (no master inheritance, animations or layout restoration).';

  @override
  String officeViewerSlidePage(String n, String total) {
    return 'Slide $n of $total';
  }

  @override
  String officeViewerSlidePageNo(String n) {
    return 'Slide $n';
  }

  @override
  String get officeViewerSlidesHidden => '(hidden slide)';

  @override
  String get officeViewerSlideEmptyBody => 'This slide has no text';

  @override
  String get officeViewerSlidesNotes => 'Speaker notes';

  @override
  String officeDownloadConvertedNotice(String name) {
    return 'Converted to Office format: saved as $name';
  }

  @override
  String get noteC3Export => 'Export';

  @override
  String get noteC3ExportTitle => 'Export note';

  @override
  String get noteC3ExportWord => 'Export as Word document';

  @override
  String get noteC3ExportWordHint => 'The NAS generates a .docx';

  @override
  String get noteC3ExportNote => 'Export as .nsx archive';

  @override
  String get noteC3ExportNoteHint =>
      'NoteStation\'s own archive format (re-importable)';

  @override
  String get noteC3ExportNotebook => 'Export notebook to NAS';

  @override
  String get noteC3ExportDest => 'Destination folder';

  @override
  String get noteC3ExportDestHint => 'e.g. /notes';

  @override
  String get noteC3ExportSaveConfig => 'Include app settings';

  @override
  String get noteC3ExportTodo => 'Include to-dos';

  @override
  String get noteC3ExportStarted => 'Exporting…';

  @override
  String noteC3ExportOpened(String name) {
    return 'Exported and opened $name';
  }

  @override
  String get noteC3ExportEmpty => 'The exported file is empty';

  @override
  String noteC3ExportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String get noteC3ExportNotebookDone => 'Exported to the NAS folder';

  @override
  String get noteC3Import => 'Import';

  @override
  String get noteC3ImportTitle => 'Import notes';

  @override
  String get noteC3ImportEnex => 'Import from Evernote .enex';

  @override
  String get noteC3ImportEnexHint => 'An .enex file exported by Evernote';

  @override
  String get noteC3ImportNotebook => 'Import from .nsx';

  @override
  String get noteC3ImportNotebookHint => 'A NoteStation archive file';

  @override
  String get noteC3ImportEvernote => 'Import from an Evernote account';

  @override
  String get noteC3ImportEvernoteHint =>
      'Connect an Evernote account, then pick notebooks';

  @override
  String get noteC3Importing => 'Importing…';

  @override
  String noteC3ImportProgress(String percent) {
    return 'Importing… $percent%';
  }

  @override
  String get noteC3ImportApplying => 'Preparing notebooks';

  @override
  String get noteC3ImportDone => 'Import complete';

  @override
  String noteC3ImportFailed(String error) {
    return 'Import failed: $error';
  }

  @override
  String get noteC3ImportCancelled => 'Cancelled';

  @override
  String get noteC3ImportStop => 'Cancel import';

  @override
  String get noteC3ImportOverwriteHint =>
      'Importing merges the notebooks/notes in the file into this account and may create duplicates. Continue?';

  @override
  String get noteC3ImportFileMissing => 'The file to import was not found';

  @override
  String get noteC3VersionTitle => 'Version history';

  @override
  String get noteC3VersionLabel => 'Version';

  @override
  String get noteC3VersionEmpty => 'No earlier versions';

  @override
  String get noteC3VersionRestore => 'Restore';

  @override
  String get noteC3VersionRestoreConfirm => 'Restore this version?';

  @override
  String noteC3VersionRestoreBody(String version) {
    return 'The current content will be replaced by version $version (the old content stays in history). Restore?';
  }

  @override
  String get noteC3VersionRestored => 'Restored to that version';

  @override
  String noteC3VersionRestoreFailed(String error) {
    return 'Restore failed: $error';
  }

  @override
  String get noteC3VersionCopyToNew => 'Copy as new note';

  @override
  String get noteC3Clip => 'Web clipper';

  @override
  String get noteC3ClipTitle => 'Clip a web page';

  @override
  String get noteC3ClipUrl => 'Page URL';

  @override
  String get noteC3ClipName => 'Title';

  @override
  String get noteC3ClipNotebook => 'Save to notebook';

  @override
  String get noteC3ClipHint =>
      'The NAS fetches the page body and keeps the source URL.';

  @override
  String get noteC3ClipInvalidUrl =>
      'Enter a URL starting with http:// or https://';

  @override
  String get noteC3ClipSaved => 'Clip saved';

  @override
  String get noteC3NoPermission =>
      'You do not have permission for this feature';

  @override
  String get noteC3NoPermissionHint =>
      'This account lacks permission for the feature';

  @override
  String get noteC3SessionHint => 'Session expired, please sign in again';

  @override
  String get noteC3NotConnected => 'Not connected to the NAS yet';

  @override
  String get noteC3ActionFailed => 'Operation failed';

  @override
  String mailErrUnknown(String code) {
    return 'Unknown error ($code)';
  }

  @override
  String get survErrCodec =>
      'Missing the media decoder required for playback (Advanced Media Extensions is required)';

  @override
  String survErrUnknown(String code) {
    return 'Unknown error ($code)';
  }

  @override
  String get serviceStateUncertain =>
      'Conflicting signals (shown conservatively)';

  @override
  String get serviceStateUncertainReason =>
      'App privileges indicate this module is installed, but none of its APIs were detected — showing it conservatively instead of hiding it.';

  @override
  String get contactGroupsTab => 'Groups';

  @override
  String get contactGroupsSection => 'Contact groups';

  @override
  String get contactNoGroups => 'No groups in this address book yet.';

  @override
  String get contactNoGroupMembers => 'No members in this group.';

  @override
  String get contactOuSection => 'Organization units (read-only)';

  @override
  String get contactNoOu =>
      'No organization units (or no directory service connected).';

  @override
  String get contactSyncStatus => 'Sync status';

  @override
  String get contactSyncStatusFailed => 'Failed';

  @override
  String get contactSyncStatusProcessing => 'Processing';

  @override
  String get contactLastUpdate => 'Last update';

  @override
  String get calNoCalendars => 'No calendars for this account yet.';

  @override
  String get calPickerLoadFailed =>
      'Failed to load calendars. Go back and retry.';

  @override
  String get calExternalCalendars => 'External calendars (Google, etc.)';

  @override
  String get calExternalCalendarsUnsupported =>
      'Not supported yet: connect this calendar in the official web UI first.';

  @override
  String get calErrInvalidParameter =>
      'The server rejected this request - the options may not match its version. Tap retry to try again.';

  @override
  String get calErrNoPermission =>
      'This account is not allowed to perform that operation.';

  @override
  String get calErrServerCondition =>
      'The server cannot complete this operation right now (117). Tap retry to try again.';

  @override
  String get calErrVersionUnsupported =>
      'The server does not support this operation (version mismatch).';

  @override
  String calErrCode(String code) {
    return 'Request failed (error $code)';
  }

  @override
  String calErrGeneric(String error) {
    return 'Load failed: $error';
  }

  @override
  String get chatAttachVideo => 'Gallery video';

  @override
  String get chatAttachRecordVideo => 'Record video';

  @override
  String get chatVideoRecordPermissionDenied =>
      'Cannot access the camera or microphone. Allow the permission in system settings and try again.';

  @override
  String get chatVideoGalleryPermissionDenied =>
      'Cannot read videos from the gallery. Check the system permission and try again.';

  @override
  String get chatCameraUnavailable =>
      'This device has no usable camera. Pick an image from the gallery instead.';

  @override
  String get chatImagePickFailed =>
      'Failed to pick the image. Please try again.';

  @override
  String get profileAvatarPickFailed =>
      'Failed to pick the avatar. Please try again.';

  @override
  String get driveScanPickFailed =>
      'Failed to take the page. Please try again.';

  @override
  String get chatVideoPickFailed =>
      'Failed to pick the video. Please try again.';

  @override
  String get chatJoinPublicChannel => 'Join public channel';

  @override
  String get chatJoinPublicFailed =>
      'Failed to join the channel. Please try again later.';

  @override
  String get chatJoinPublicEmpty => 'No public channel is available to join.';

  @override
  String get chatShareToChannel => 'Share to channel';

  @override
  String get chatSharedToChannel => 'Shared to the channel.';

  @override
  String get chatShareFailed => 'Share failed. Please try again.';

  @override
  String get chatShareExceedMaxFiles =>
      'You can share up to 50 files at a time; the rest were ignored.';

  @override
  String get noteC3ClipModeSimple => 'Simplified';

  @override
  String get noteC3ClipModeFull => 'Full page';

  @override
  String noteC3ImportEvernoteBrowserFailed(String url) {
    return 'Couldn\'t open the browser. Open manually: $url';
  }

  @override
  String get noteC3ImportEvernoteMerge => 'Merge into existing notebook';

  @override
  String get noteC3ImportEvernoteMergeHint =>
      'Whether multiple Evernote notebooks are merged into one on import';

  @override
  String noteC3ImportEvernoteLock(String lock) {
    return 'Server-side import is locked: $lock';
  }

  @override
  String get noteAEditorFormatBlock => 'Paragraph style';

  @override
  String get noteAEditorContent => 'Body text';

  @override
  String get noteAEditorFontSize => 'Font size';

  @override
  String get noteAEditorNoteLink => 'Note link';

  @override
  String get noteAEditorNoteLinkTitle => 'Link to note';

  @override
  String get noteAEditorNoteLinkEmpty => 'No other notes to link to';

  @override
  String get noteAEditorHorizontalRule => 'Horizontal rule';

  @override
  String get noteAEditorFileAttachment => 'Add file attachment';

  @override
  String get noteAEditorFilePickFailed => 'Failed to pick a file';

  @override
  String get noteAEditorAttachments => 'Attachments';

  @override
  String get noteAEditorAttachmentDelete => 'Delete attachment';

  @override
  String noteAEditorAttachmentDeleteConfirm(String name) {
    return 'Delete attachment \"$name\"?';
  }

  @override
  String get noteAEditorAttachmentDeleteFailed =>
      'Failed to delete the attachment';

  @override
  String get noteAEditorAttachmentDownload => 'Download and open';

  @override
  String get noteAEditorAttachmentDownloadFailed =>
      'Failed to download the attachment';

  @override
  String get noteAEditorAttachmentEmpty => 'This note has no attachments yet';

  @override
  String get chatBookmarks => 'Bookmarks';

  @override
  String get chatBookmarkRemoveFailed =>
      'Failed to remove the bookmark. Please try again.';

  @override
  String get chatNoBookmarks => 'No starred messages yet';

  @override
  String get chatSubscribedThreadsTitle => 'Subscribed threads';

  @override
  String get chatNoSubscribedThreads => 'No subscribed threads yet';

  @override
  String get chatGlobalPanelTitle => 'Cross-channel content';

  @override
  String get chatGlobalTabThreads => 'Threads';

  @override
  String get chatGlobalTabReminders => 'Reminders';

  @override
  String get chatGlobalTabScheduled => 'Scheduled';

  @override
  String get chatGlobalFanoutNote =>
      'Aggregated locally from each channel (the server API is per-channel)';

  @override
  String get fsP0ConflictTitle => 'A file with the same name already exists';

  @override
  String fsP0ConflictBody(String name) {
    return '$name already exists in this folder. Choose how to handle it.';
  }

  @override
  String get fsP0ConflictOverwrite => 'Overwrite';

  @override
  String get fsP0ConflictRename => 'Rename';

  @override
  String get fsP0ConflictSkip => 'Skip';

  @override
  String fsP0UploadRenamed(String name) {
    return 'Renamed to $name';
  }

  @override
  String get fsP0RecycleBin => 'Recycle bin';

  @override
  String get fsP0RecycleEmpty => 'Empty recycle bin';

  @override
  String get fsP0RecycleEmptyConfirm =>
      'Everything in the recycle bin will be permanently deleted and cannot be recovered. Continue?';

  @override
  String get fsP0RecycleEmptyDone => 'Recycle bin emptied';

  @override
  String get fsP0RecycleRestore => 'Restore';

  @override
  String get fsP0RecycleRestoreConfirm =>
      'Restore the selected items to their original location?';

  @override
  String get fsP0RecycleRestored => 'Restored';

  @override
  String get fsP0DeleteForever => 'Delete permanently';

  @override
  String get fsP0DeleteForeverConfirm =>
      'The selected items will be permanently deleted and cannot be recovered. Continue?';

  @override
  String get fsP0ShareAdd => 'Create share link';

  @override
  String get fsP0ShareCreateTitle => 'Create share link';

  @override
  String get fsP0SharePasswordEnable => 'Enable password protection';

  @override
  String get fsP0SharePasswordLabel => 'Password';

  @override
  String get fsP0ShareValidity => 'Validity';

  @override
  String get fsP0SharePermanent => 'Permanent';

  @override
  String fsP0ShareDays(int days) {
    return '$days days';
  }

  @override
  String get fsP0ShareCreatedTitle => 'Share link created';

  @override
  String get fsP0ShareCopyUrl => 'Copy link';

  @override
  String get fsP0ShareCreateFailed => 'Failed to create the share link';

  @override
  String get asShuffle => 'Shuffle';

  @override
  String get asPrevious => 'Previous';

  @override
  String get asNext => 'Next';

  @override
  String get asRepeatOff => 'Play in order';

  @override
  String get asRepeatAll => 'Repeat all';

  @override
  String get asRepeatOne => 'Repeat one';

  @override
  String get asQuality => 'Quality';

  @override
  String get asPinRename => 'Rename';

  @override
  String get asPinRenameTitle => 'Rename favorite';

  @override
  String get asPinName => 'Name';

  @override
  String get asPinRenameConfirm => 'Save';

  @override
  String get asPinRenamed => 'Favorite renamed';

  @override
  String get asPinRenameFailed => 'Rename failed';

  @override
  String get asPinReorderFailed => 'Reorder failed';

  @override
  String asQualityKbps(int kbps) {
    return '$kbps kbps';
  }

  @override
  String asQueuePosition(int index, int total) {
    return '$index/$total';
  }

  @override
  String get dsBatchActions => 'Batch actions';

  @override
  String dsBatchFailed(String msg) {
    return 'Operation failed: $msg';
  }

  @override
  String get dsPauseAll => 'Pause all';

  @override
  String get dsResumeAll => 'Resume all';

  @override
  String get dsClearFinished => 'Clear completed';

  @override
  String get dsClearFinishedConfirm =>
      'Completed tasks will be removed from the download list. This cannot be undone.';

  @override
  String get dsClearedFinished => 'Completed tasks cleared';

  @override
  String get dsRemoveErrors => 'Delete failed tasks';

  @override
  String get dsRemoveErrorsConfirm =>
      'Delete all failed tasks? This cannot be undone.';

  @override
  String get dsRemovedErrors => 'Failed tasks deleted';

  @override
  String get dsMoreActions => 'More actions';

  @override
  String get dsForceComplete => 'Finish task';

  @override
  String get dsForceCompleteConfirm =>
      'After finishing, the task cannot be resumed. Downloaded files stay in the destination folder.';

  @override
  String get dsForceCompleted => 'Task finished';

  @override
  String get dsSearchHint => 'Search task name';

  @override
  String get dsSortBy => 'Sort by';

  @override
  String get dsSortDefault => 'Default order';

  @override
  String get dsSortAsc => 'Ascending';

  @override
  String get dsSortDesc => 'Descending';

  @override
  String get dsSortName => 'Name';

  @override
  String get dsSortSize => 'Size';

  @override
  String get dsSortDownloaded => 'Downloaded';

  @override
  String get dsSortStatus => 'Status';

  @override
  String get dsSortSpeedDown => 'Download speed';

  @override
  String get dsSortSpeedUp => 'Upload speed';

  @override
  String get dsSortStarted => 'Added time';

  @override
  String get dsPriority => 'Priority';

  @override
  String get dsPriorityHigh => 'High';

  @override
  String get dsPriorityNormal => 'Normal';

  @override
  String get dsPriorityLow => 'Low';

  @override
  String get dsPriorityAuto => 'Auto';

  @override
  String get dsTrackerList => 'Trackers';

  @override
  String get dsTrackerEmpty => 'No tracker information';

  @override
  String get dsPeerList => 'Peers';

  @override
  String get dsPeerEmpty => 'No peer information';

  @override
  String get dsFtpAuth => 'Requires FTP/HTTP credentials';

  @override
  String get dsFtpUsername => 'Username';

  @override
  String get dsFtpPassword => 'Password';

  @override
  String get dsSelectFiles => 'Select files to download';

  @override
  String get dsSelectFilesHint => 'Uncheck files you don\'t want';

  @override
  String get dsStartDownload => 'Start download';

  @override
  String get dsFilesStarted => 'Download of selected files started';

  @override
  String get dsFileSelectFailed => 'Failed to load the file list';

  @override
  String get dsCreateListUnavailable =>
      'Task created, but the server returned no file list, so files cannot be chosen first';

  @override
  String get dsFileListEmpty => 'This torrent has no file list';

  @override
  String get photoP0ActionDownload => 'Download';

  @override
  String get photoP0ActionFavorite => 'Favorite';

  @override
  String get photoP0ActionUnfavorite => 'Remove from favorites';

  @override
  String get photoP0ActionAddToAlbum => 'Add to album';

  @override
  String get photoP0ActionRemoveFromAlbum => 'Remove from album';

  @override
  String get photoP0DeleteTitle => 'Delete selected items?';

  @override
  String get photoP0DeleteBody =>
      'Deleted items are moved to the DSM Recycle Bin; restoring them requires the shared folder\'s Recycle Bin to be enabled.';

  @override
  String photoP0DeletedCount(String count) {
    return 'Deleted $count items';
  }

  @override
  String photoP0BatchResult(String ok, String fail) {
    return '$ok succeeded, $fail failed';
  }

  @override
  String photoP0BatchAllFailed(String fail) {
    return 'All $fail failed';
  }

  @override
  String photoP0DownloadZipReady(String name) {
    return 'Saved $name';
  }

  @override
  String get photoP0DownloadZipEmpty =>
      'The server returned no content; these photos may not be downloadable as an archive.';

  @override
  String get photoP0VideoQuality => 'Quality';

  @override
  String get photoP0VideoQualityAuto => 'Auto';

  @override
  String get photoP0VideoQualityFirst => 'Quality first';

  @override
  String get photoP0VideoSpeedFirst => 'Speed first';

  @override
  String photoP0VideoQualityApplied(String name) {
    return 'Video quality: $name';
  }

  @override
  String photoP0PersonMigratingProgress(String message, String percent) {
    return '$message ($percent% organized)';
  }

  @override
  String get fsP0bDownloadPause => 'Pause';

  @override
  String get fsP0bDownloadResume => 'Resume';

  @override
  String get fsP0bDownloadPausedTip =>
      'Paused. The downloaded part is kept and you can resume.';

  @override
  String fsP0bDownloadResumed(String size) {
    return 'Resumed from $size.';
  }

  @override
  String get fsP0bDownloadRestarted =>
      'The server does not support resuming, so the file was downloaded again from the start.';

  @override
  String fsP0bDownloadIncomplete(String detail) {
    return 'Download incomplete: $detail';
  }

  @override
  String get fsP0bRestoreConflictTitle =>
      'Items with the same name already exist at the destination';

  @override
  String fsP0bRestoreConflictBody(String count) {
    return '$count item(s) already exist at the restore destination. Choose how to proceed.';
  }

  @override
  String get fsP0bRestoreOverwrite => 'Overwrite';

  @override
  String get fsP0bRestoreSkip => 'Skip';

  @override
  String get fsP0bCompressPasswordEnable => 'Require a password';

  @override
  String get fsP0bCompressPasswordLabel => 'Password';

  @override
  String get fsP0bPasswordConfirmLabel => 'Confirm password';

  @override
  String get fsP0bPasswordMismatch => 'Passwords do not match';

  @override
  String get fsP0bPasswordEmpty => 'Password cannot be empty';

  @override
  String get fsP0bExtractPasswordLabel => 'Password';

  @override
  String get fsP0bExtractPasswordHint =>
      'Only required for encrypted archives; leave blank if there is no password';

  @override
  String get fsP0bSearchFilter => 'Filter';

  @override
  String get fsP0bSearchFilterActive => 'Filter active';

  @override
  String get fsP0bSearchType => 'Type';

  @override
  String get fsP0bSearchTypeAny => 'Any';

  @override
  String get fsP0bSearchTypeFolder => 'Folders';

  @override
  String get fsP0bSearchTypeFile => 'Any file';

  @override
  String get fsP0bSearchTypeDocuments => 'Documents';

  @override
  String get fsP0bSearchTypeVideos => 'Videos';

  @override
  String get fsP0bSearchTypePictures => 'Pictures';

  @override
  String get fsP0bSearchTypeAudio => 'Audio';

  @override
  String get fsP0bSearchTypeExtension => 'Custom extensions';

  @override
  String get fsP0bSearchExtensionHint => 'Extensions (comma separated)';

  @override
  String get fsP0bSearchSize => 'Size (MB)';

  @override
  String get fsP0bSearchSizeFrom => 'Min';

  @override
  String get fsP0bSearchSizeTo => 'Max';

  @override
  String get fsP0bSearchSizeInvalid =>
      'Minimum size cannot exceed maximum size';

  @override
  String get fsP0bSearchDate => 'Modified time';

  @override
  String get fsP0bSearchDateFrom => 'From';

  @override
  String get fsP0bSearchDateTo => 'To';

  @override
  String get fsP0bSearchDateInvalid =>
      'Start date cannot be later than end date';

  @override
  String get fsP0bSearchOwner => 'Owner';

  @override
  String get fsP0bSearchOwnerHint => 'Account name; leave blank for any';

  @override
  String get fsP0bSearchApply => 'Apply';

  @override
  String get fsP0bSearchClear => 'Clear filter';

  @override
  String get noteBReminder => 'Reminder';

  @override
  String get noteBReminderOff => 'No reminder';

  @override
  String get noteBReminderOnTime => 'On time';

  @override
  String noteBReminderBefore(String value, String unit) {
    return '$value $unit before';
  }

  @override
  String get noteBReminderCustom => 'Custom';

  @override
  String get noteBReminderUnitMinute => 'minute(s)';

  @override
  String get noteBReminderUnitHour => 'hour(s)';

  @override
  String get noteBReminderUnitDay => 'day(s)';

  @override
  String get noteBReminderUnitWeek => 'week(s)';

  @override
  String get noteBReminderNeedsDueDate => 'Set a due date first';

  @override
  String get noteBOverdueSettings => 'Overdue alerts';

  @override
  String get noteBOverdueEnable => 'Daily overdue summary';

  @override
  String get noteBOverdueTime => 'Reminder time';

  @override
  String get noteBOverdueTitle => 'Overdue';

  @override
  String noteBOverdueCount(String count) {
    return '$count overdue task(s)';
  }

  @override
  String get noteBOverdueShow =>
      'Find overdue items under the \"Unfinished\" filter on the To-do page';

  @override
  String get noteBOverdueHint =>
      'At the set time, summarize today\'s overdue unfinished tasks';

  @override
  String get noteBNotifyUnsupported =>
      'Reminders only fire while the app is open in this version';

  @override
  String get noteBSmart => 'Smart notebooks';

  @override
  String get noteBSmartNew => 'New smart notebook';

  @override
  String get noteBSmartEdit => 'Edit smart notebook';

  @override
  String get noteBSmartEmpty => 'No smart notebooks yet';

  @override
  String get noteBSmartName => 'Name';

  @override
  String get noteBSmartKeyword => 'Keyword';

  @override
  String get noteBSmartNoteTitle => 'Title contains';

  @override
  String get noteBSmartNotebooks => 'Limit to notebooks';

  @override
  String get noteBSmartTags => 'Tags (comma separated)';

  @override
  String get noteBSmartTagAnd => 'Tags: match all';

  @override
  String get noteBSmartTagOr => 'Tags: match any';

  @override
  String get noteBSmartDateFrom => 'Modified from';

  @override
  String get noteBSmartDateTo => 'Modified to';

  @override
  String get noteBSmartDelete => 'Delete smart notebook';

  @override
  String noteBSmartDeleteConfirm(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get noteBSmartSaved => 'Smart notebook saved';

  @override
  String noteBSmartFailed(String error) {
    return 'Save failed: $error';
  }

  @override
  String get noteBSmartNameRequired => 'Enter a name';

  @override
  String get noteBSmartNoConditions => 'No conditions';

  @override
  String get noteBShelf => 'Shelves';

  @override
  String get noteBShelfAdd => 'Add to shelf';

  @override
  String get noteBShelfRemove => 'Remove from shelf';

  @override
  String get noteBShelfName => 'Shelf name';

  @override
  String get noteBShelfEmpty => 'No notebooks yet';

  @override
  String get noteBShelfDone => 'Shelf updated';

  @override
  String get noteBJoined => 'Shared with me';

  @override
  String get noteBJoinedNotebooks => 'Joined notebooks';

  @override
  String get noteBJoinedNotes => 'Joined notes';

  @override
  String get noteBJoinedEmpty => 'Nothing shared with you yet';

  @override
  String noteBJoinedOwner(String owner) {
    return 'by $owner';
  }

  @override
  String get noteBCopy => 'Copy';

  @override
  String get noteBCopySuffix => '(copy)';

  @override
  String get noteBCopyToEncrypt => 'Copy to encrypted';

  @override
  String get noteBCopyToPlaintext => 'Copy to plain text';

  @override
  String get noteBCopyPassword => 'Enter note password';

  @override
  String get noteBCopyDone => 'Copied';

  @override
  String noteBCopyFailed(String error) {
    return 'Copy failed: $error';
  }

  @override
  String get noteBCopyTitle => 'Untitled note';

  @override
  String get fsC5MountTitle => 'Remote mounts';

  @override
  String get fsC5MountChip => 'Mounts';

  @override
  String get fsC5MountIsoSection => 'ISO images';

  @override
  String get fsC5MountRemoteSection => 'Remote volumes (CIFS)';

  @override
  String get fsC5MountEmpty => 'No remote volume or ISO image is mounted yet.';

  @override
  String get fsC5MountAdd => 'Add mount';

  @override
  String get fsC5MountAddCifs => 'Mount remote folder (CIFS)';

  @override
  String get fsC5MountAddIso => 'Mount ISO image';

  @override
  String get fsC5MountServer => 'Server address';

  @override
  String fsC5MountServerHint(String example) {
    return 'e.g. $example';
  }

  @override
  String get fsC5MountAccount => 'Account';

  @override
  String get fsC5MountPassword => 'Password';

  @override
  String get fsC5MountMountPoint => 'Mount point';

  @override
  String fsC5MountPointHint(String example) {
    return 'e.g. $example';
  }

  @override
  String get fsC5MountSource => 'ISO source file';

  @override
  String get fsC5MountAutoMount => 'Auto-mount at boot';

  @override
  String get fsC5MountActor => 'Mounted by';

  @override
  String get fsC5MountAutoMountFailed => 'Auto-mount at boot failed';

  @override
  String get fsC5MountIsoReadOnly => 'ISO volumes are read-only';

  @override
  String get fsC5MountUnmount => 'Unmount';

  @override
  String fsC5MountUnmountConfirm(String name) {
    return 'Unmount $name?';
  }

  @override
  String get fsC5MountUnmounted => 'Unmounted';

  @override
  String get fsC5MountReconnect => 'Reconnect';

  @override
  String get fsC5MountRemount => 'Remount';

  @override
  String get fsC5MountBrowse => 'Browse';

  @override
  String get fsC5MountSubmitted => 'Mount request submitted';

  @override
  String get fsC5MountPermissionDenied =>
      'This account is not allowed to mount or unmount remote volumes (DSM → Control Panel → Application Privileges → File Station)';

  @override
  String get fsC5MountUnavailable => 'Remote mounts are unavailable';

  @override
  String get fsC5MountServerDisabled =>
      'Mounting is not enabled for this account on this server, so there is no type to add. Ask your administrator to enable remote mount or ISO mount in File Station.';

  @override
  String get fsC5MountNeedsHome =>
      'Only administrators can mount remote folders outside their home folder. Non-administrators can mount remote folders within their \"home\" folder only, and User Home is not enabled for this account.';

  @override
  String get fsC5MountVirtualSection => 'Virtual folders';

  @override
  String get fsC5MountRequired =>
      'Server address and mount point cannot be empty';

  @override
  String get fsC5FilterHint => 'Filter in folder';

  @override
  String get fsC5FilterChip => 'Filter';

  @override
  String get fsC5FilterClear => 'Clear filter';

  @override
  String get fsC5FilterNoMatch => 'No matches';

  @override
  String get fsC5ReadOnly => 'Read-only';

  @override
  String get fsC5WormLocked => 'WORM locked';

  @override
  String fsC5WormBlocked(String action) {
    return 'This file is locked by WriteOnce and cannot be $action';
  }

  @override
  String get fsC5CompressFormat => 'Archive format';

  @override
  String get fsC5CompressLevel => 'Compression level';

  @override
  String get fsC5LevelStore => 'Store only';

  @override
  String get fsC5LevelFastest => 'Fastest';

  @override
  String get fsC5LevelModerate => 'Standard';

  @override
  String get fsC5LevelBest => 'Best';

  @override
  String get fsC5ExtractCodepage => 'Filename encoding';

  @override
  String get fsC5ExtractCodepageHint =>
      'Pick the matching encoding if extracted filenames are garbled';

  @override
  String get fsC5TaskDetailParams => 'Task parameters';

  @override
  String get fsC5TaskDetailErrors => 'Task errors';

  @override
  String get fsC5TaskNoError => 'No errors';

  @override
  String get fsC5FavoriteRename => 'Rename favorite';

  @override
  String get fsC5FavoriteClearBroken => 'Clean up broken favorites';

  @override
  String get fsC5FavoriteClearBrokenConfirm =>
      'All favorites pointing to paths that no longer exist will be deleted.';

  @override
  String get fsC5FavoriteCleared => 'Broken favorites cleaned up';

  @override
  String get fsC5FavoriteRenamed => 'Favorite renamed';

  @override
  String get noteBNotifySystemReady =>
      'System reminders are on: alarms fire even when the app is closed';

  @override
  String get noteBNotifyPermissionNeeded =>
      'System reminders need notification permission; without it reminders fire only while the app is open';

  @override
  String get noteBNotifyExactAlarmDenied =>
      'Exact alarms are not allowed: reminders may be delayed (fell back to inexact alarms)';

  @override
  String get noteBNotifyGrant => 'Grant permission';

  @override
  String photoP1PersonCount(String count) {
    return '$count people';
  }

  @override
  String photoP1ConceptCount(String count) {
    return '$count scenes';
  }

  @override
  String photoP1LoadMoreRemaining(String count) {
    return 'Load more ($count left)';
  }

  @override
  String get photoP1CountUnavailable => 'Count unavailable';

  @override
  String photoP1DetailSummary(String count) {
    return '$count photos';
  }

  @override
  String get photoP1CreateShareLink => 'Create share link';

  @override
  String get photoP1CreateShareLinkHint =>
      'This only creates the link; it is not shared yet';

  @override
  String get photoP1EnableShareLink => 'Turn on link sharing';

  @override
  String get photoP1EnableShareLinkConfirm => 'Turn on link sharing?';

  @override
  String get photoP1EnableShareLinkBody =>
      'Anyone with the link can browse this album unless a password is set.';

  @override
  String get photoP1ShareLinkCreated => 'Share link created';

  @override
  String get photoP1PasswordTitle => 'Password protection';

  @override
  String get photoP1PasswordEnabled => 'Password protection is on';

  @override
  String get photoP1PasswordOff => 'No password set';

  @override
  String get photoP1PasswordField => 'Access password';

  @override
  String get photoP1PasswordClearHint => 'Leave empty to clear the password';

  @override
  String get photoP1PasswordSaved => 'Password updated';

  @override
  String get photoP1ExpirationField => 'Expires in (days)';

  @override
  String get photoP1ExpirationNever => 'Leave empty for no expiry';

  @override
  String get photoP1LinkNeedsPassphrase =>
      'Create the share link before setting a password';

  @override
  String get photoP1InviteRole => 'Role';

  @override
  String get photoP1InviteConfirm => 'Invite';

  @override
  String photoP1InviteSelected(String count) {
    return '$count selected';
  }

  @override
  String photoP1MemberInvited(String count) {
    return 'Invited $count member(s)';
  }

  @override
  String photoP1SearchSuggestTitle(String type) {
    return 'Suggestion · $type';
  }

  @override
  String get photoP1SearchSuggestEmpty => 'No suggestions';

  @override
  String get photoP1SimilarLoadMore => 'Load more';

  @override
  String get photoP1ConditionCreate => 'New condition album';

  @override
  String get photoP1ConditionEdit => 'Edit conditions';

  @override
  String get photoP1ConditionName => 'Album name';

  @override
  String get photoP1ConditionNameEmpty => 'Enter an album name';

  @override
  String get photoP1ConditionType => 'Condition types';

  @override
  String photoP1ConditionValue(String count) {
    return '$count selected';
  }

  @override
  String get photoP1ConditionValueEmpty => 'No values selected';

  @override
  String get photoP1ConditionValueSearch => 'Search values';

  @override
  String get photoP1ConditionNoPreview => 'Not previewed yet';

  @override
  String get photoP1ConditionPolicyAnd => 'Match all';

  @override
  String get photoP1ConditionPolicyOr => 'Match any';

  @override
  String get photoP1ConditionPeek => 'Preview matching photos';

  @override
  String photoP1ConditionPeekResult(String count) {
    return 'Matching photos: $count';
  }

  @override
  String get photoP1ConditionPeekFailed => 'Preview failed';

  @override
  String get photoP1ConditionCreated => 'Condition album created';

  @override
  String get photoP1ConditionUpdated => 'Condition album updated';

  @override
  String get photoP1ConditionNeedOne => 'Select at least one condition';

  @override
  String get photoP1ConditionSuggestEmpty => 'No values available';

  @override
  String get photoP1ConditionSuggestFailed => 'Failed to load values';

  @override
  String get photoP1ConditionItemType => 'Media type';

  @override
  String get photoP1ConditionItemTypeAll => 'All';

  @override
  String get photoP1ConditionItemTypePhoto => 'Photos';

  @override
  String get photoP1ConditionItemTypeVideo => 'Videos';

  @override
  String get photoP1ConditionKeyword => 'Keywords (comma separated)';

  @override
  String get photoP1ConditionUserIdMissing => 'Cannot read the current user id';

  @override
  String get photoP1UploadToTimeline => 'Upload to timeline';

  @override
  String get photoP1UploadPickFailed => 'Failed to pick files';

  @override
  String photoP1UploadDone(String count) {
    return 'Uploaded $count item(s)';
  }

  @override
  String photoP1UploadFailed(String ok, String failed) {
    return '$ok succeeded, $failed failed';
  }

  @override
  String get photoP1PlaceItemsEmpty => 'No photos for this place yet';

  @override
  String get photoP1EditorTitle => 'Rotate photo';

  @override
  String get photoP1EditorRotateCw => 'Rotate 90° clockwise';

  @override
  String get photoP1EditorRotateCcw => 'Rotate 90° counter-clockwise';

  @override
  String get photoP1EditorRotate180 => 'Rotate 180°';

  @override
  String get photoP1EditorSaved => 'Rotation saved';

  @override
  String get photoMapOpen => 'Open in maps';

  @override
  String photoMapSheetTitle(String name) {
    return 'Open \"$name\" in maps';
  }

  @override
  String get photoMapNameOnlyHint =>
      'This place has only a name, no coordinates: the map app will search by name, not pinpoint it.';

  @override
  String photoMapPreciseHint(String lat, String lon) {
    return 'Using coordinates $lat, $lon (WGS-84).';
  }

  @override
  String get photoMapNothingHint =>
      'No name or coordinates; cannot open a map.';

  @override
  String get photoMapServiceLabel => 'Map service';

  @override
  String get photoMapServiceAuto => 'Auto (follow region)';

  @override
  String get photoMapServiceGoogle => 'Google Maps';

  @override
  String get photoMapServiceAmap => 'Amap';

  @override
  String get photoMapServiceTencent => 'Tencent Maps';

  @override
  String get photoMapServiceBaidu => 'Baidu Maps';

  @override
  String photoMapAutoResolved(String service) {
    return 'Currently detected: $service';
  }

  @override
  String get photoMapRegionHint =>
      'Region detection uses only your device locale/time zone and may be wrong — change it above and it will be remembered.';

  @override
  String get photoMapOpenAction => 'Open';

  @override
  String get photoMapCopyName => 'Copy name';

  @override
  String get photoMapCopied => 'Copied';

  @override
  String get photoMapFailed =>
      'Could not open a map: make sure a map app or browser is installed.';

  @override
  String photoMapFallbackNote(String service, String fallback) {
    return '$service has no key-free web version; falls back to the $fallback web page if it cannot open.';
  }

  @override
  String get photoMapPreciseBadge => 'Exact coordinates';

  @override
  String get photoMapNameSearchBadge => 'Search by name';

  @override
  String get driveP0EntryDenied =>
      'This account has no permission for this feature (entry hidden)';

  @override
  String get driveP0EntryUnavailable =>
      'This NAS does not provide this feature (Synology Drive Server may be too old)';

  @override
  String get driveP0EntrySessionExpired =>
      'Your session has expired. Please sign in again.';

  @override
  String get driveP0RecentTitle => 'Recent';

  @override
  String get driveP0RecentEmptyTitle => 'No recent items';

  @override
  String get driveP0RecentEmptyMessage =>
      'Files you open or change in Drive appear here';

  @override
  String get driveP0SharedByMeTitle => 'Shared by me';

  @override
  String get driveP0SharedByMeEmptyTitle => 'Nothing shared yet';

  @override
  String get driveP0SharedByMeEmptyMessage =>
      'Files you share with others in Drive appear here';

  @override
  String get driveP0FolderEmptyTitle => 'This folder is empty';

  @override
  String get driveP0FolderEmptyMessage =>
      'There are no files or subfolders here yet';

  @override
  String get driveP0FolderOpenFailed => 'Cannot open this folder';

  @override
  String get driveP0SearchTitle => 'Search';

  @override
  String get driveP0SearchHint => 'Search files and folders';

  @override
  String get driveP0SearchEmptyTitle => 'No matches found';

  @override
  String get driveP0SearchEmptyMessage =>
      'Try another keyword or loosen the filters';

  @override
  String get driveP0SearchFailed => 'Search failed';

  @override
  String get driveP0SearchNeedCondition =>
      'Enter a keyword or pick at least one filter';

  @override
  String get driveP0SearchLocation => 'Location';

  @override
  String get driveP0SearchLocationAny => 'Anywhere';

  @override
  String get driveP0SearchLocationMyDrive => 'My Files';

  @override
  String get driveP0SearchLocationTeamFolders => 'Team Folders';

  @override
  String get driveP0SearchLocationSharedWithMe => 'Shared with me';

  @override
  String get driveP0SearchLocationSharedByMe => 'Shared by me';

  @override
  String get driveP0SearchLocationStarred => 'Starred';

  @override
  String get driveP0SearchLocationCurrent => 'Current folder';

  @override
  String get driveP0SearchType => 'Type';

  @override
  String get driveP0SearchTypeAny => 'Any type';

  @override
  String get driveP0SearchTypeFolder => 'Folder';

  @override
  String get driveP0SearchTypeFile => 'File';

  @override
  String get driveP0SearchTypeOdoc => 'Synology Document';

  @override
  String get driveP0SearchTypeOsheet => 'Synology Spreadsheet';

  @override
  String get driveP0SearchTypeOslide => 'Synology Slides';

  @override
  String get driveP0SearchTypeDocument => 'Document';

  @override
  String get driveP0SearchTypeImage => 'Image';

  @override
  String get driveP0SearchTypeAudio => 'Audio';

  @override
  String get driveP0SearchTypeVideo => 'Video';

  @override
  String get driveP0SearchOwner => 'Owner';

  @override
  String get driveP0SearchOwnerAny => 'Anyone';

  @override
  String get driveP0SearchOwnerMe => 'Me';

  @override
  String get driveP0SearchOwnerNotMe => 'Not me';

  @override
  String get driveP0SearchSize => 'Size';

  @override
  String get driveP0SearchSizeAny => 'Any';

  @override
  String get driveP0SearchSizeGreater => 'Larger than';

  @override
  String get driveP0SearchSizeLess => 'Smaller than';

  @override
  String get driveP0SearchSizeEqual => 'About';

  @override
  String get driveP0SearchSizeUnit => 'MB';

  @override
  String get driveP0SearchDate => 'Date';

  @override
  String get driveP0SearchDateAny => 'Any time';

  @override
  String get driveP0SearchDateModified => 'Modified time';

  @override
  String get driveP0SearchDateCreated => 'Created time';

  @override
  String get driveP0SearchLabel => 'Label';

  @override
  String get driveP0CopyTo => 'Copy to…';

  @override
  String get driveP0MoveTo => 'Move to…';

  @override
  String get driveP0CopyMovePick =>
      'No subfolders to enter; use the destination button at top right';

  @override
  String get driveP0CopyHere => 'Copy here';

  @override
  String get driveP0MoveHere => 'Move here';

  @override
  String get driveP0CopyMoveSameFolder =>
      'You cannot choose the item itself as the destination';

  @override
  String get driveP0CopyMoveConflictTitle =>
      'Items with the same name already exist';

  @override
  String driveP0CopyMoveConflictBody(String count) {
    return '$count item(s) have the same name in the destination. Choose how to handle them.';
  }

  @override
  String get driveP0ConflictAutorename => 'Rename automatically';

  @override
  String get driveP0ConflictOverwrite => 'Overwrite';

  @override
  String get driveP0ConflictStop => 'Skip';

  @override
  String driveP0CopyMoveDone(String count) {
    return 'Done: $count item(s)';
  }

  @override
  String driveP0CopyMoveFailed(String error) {
    return 'Operation failed: $error';
  }

  @override
  String get driveP0InfoTitle => 'Info';

  @override
  String get driveP0InfoType => 'File type';

  @override
  String get driveP0InfoTypeFile => 'File';

  @override
  String get driveP0InfoFolder => 'Folder';

  @override
  String get driveP0InfoLocation => 'Location';

  @override
  String get driveP0InfoCreated => 'Created time';

  @override
  String get driveP0InfoModified => 'Modified time';

  @override
  String get driveP0InfoOwner => 'Owner';

  @override
  String get driveP0InfoSize => 'Size';

  @override
  String get driveP0InfoLabels => 'Labels';

  @override
  String get driveP0InfoPermission => 'Permissions';

  @override
  String get driveP0InfoCanDownload => 'Can download';

  @override
  String get driveP0InfoCanWrite => 'Can edit';

  @override
  String get driveP0InfoCanPreview => 'Can preview';

  @override
  String get driveP0InfoShared => 'Shared';

  @override
  String get driveP0InfoStarred => 'Starred';

  @override
  String get driveP0InfoLocked => 'Locked';

  @override
  String driveP0InfoLockedBy(String name) {
    return 'Locked by $name';
  }

  @override
  String get driveP0InfoNone => 'None';

  @override
  String get driveP0InfoClose => 'Close';

  @override
  String get driveP0EncryptedTitle => 'Enter Password';

  @override
  String get driveP0EncryptedOfficeBody =>
      'This file is encrypted. Please enter the password.';

  @override
  String get imageEditBackendOpenai => 'OpenAI-compatible · images/edits';

  @override
  String get imageEditBackendGemini => 'Google Gemini · generateContent';

  @override
  String get imageEditBackendA1111 => 'A1111 · sdapi/v1/img2img';

  @override
  String get imageEditStrengthWeak => 'Weak';

  @override
  String get imageEditStrengthMedium => 'Medium';

  @override
  String get imageEditStrengthStrong => 'Strong';

  @override
  String get imageEditPresetEnhance => 'Enhance clarity';

  @override
  String get imageEditPresetEnhancePrompt =>
      'Improve clarity and detail, remove blur, and keep the original composition and the person\'s features';

  @override
  String get imageEditPresetDenoise => 'Denoise';

  @override
  String get imageEditPresetDenoisePrompt =>
      'Remove noise and compression artifacts while keeping texture and text detail';

  @override
  String get imageEditPresetRealistic => 'Stylize (realistic)';

  @override
  String get imageEditPresetRealisticPrompt =>
      'Convert to a clean, realistic photographic style with natural light, keeping the original scene';

  @override
  String get imageEditPresetIllustration => 'Stylize (illustration)';

  @override
  String get imageEditPresetIllustrationPrompt =>
      'Convert to a soft hand-drawn illustration style, keeping the subject\'s pose and colors';

  @override
  String get imageEditPresetIdPhoto => 'Replace ID photo background';

  @override
  String get imageEditPresetIdPhotoPrompt =>
      'Keep the face and hair unchanged, and replace the background with a solid color';

  @override
  String get imageEditPresetIdPhotoNotice =>
      'The result is not guaranteed to meet ID photo requirements; do not use it for official applications';

  @override
  String get imageEditPresetRestore => 'Restore old photo';

  @override
  String get imageEditPresetRestorePrompt =>
      'Repair scratches and fading and sharpen moderately, without changing the person\'s appearance';

  @override
  String get imageEditPresetCustom => 'Custom';

  @override
  String get imageEditPresetCustomPrompt => '';

  @override
  String get imgEditErrNoNetwork =>
      'No network connection; AI enhancement is unavailable';

  @override
  String get imgEditErrNetworkUnknown =>
      'Network type unknown; treated conservatively as non-Wi-Fi';

  @override
  String get imgEditErrWifiOnly =>
      'Wi-Fi-only upload is on; you are on mobile data, which uses your data plan';

  @override
  String get imgEditErrNoBackend =>
      'No image-to-image backend configured yet. Set one up under AI Services first';

  @override
  String get imgEditErrNoKey => 'API key not set yet';

  @override
  String get imgEditErrConsent =>
      'You must first agree that photos will be sent to the service you configured';

  @override
  String get imgEditErrDisabled => 'AI enhancement is turned off';

  @override
  String imgEditErrQuota(String used, String cap) {
    return 'Today\'s AI enhancement quota is used up ($used/$cap); it resets at 00:00 tomorrow';
  }

  @override
  String get imgEditErrBusy => 'An enhancement is already running; please wait';

  @override
  String imgEditErrPromptTooLong(String chars, String limit) {
    return 'The prompt is too long ($chars characters, limit $limit)';
  }

  @override
  String get imgEditErrPromptEmpty =>
      'Write a sentence describing how to enhance it first';

  @override
  String imgEditErrRequestRejected(String tail) {
    return 'The service does not accept these parameters or this size (400) $tail';
  }

  @override
  String imgEditErrNotFoundHost(String host) {
    return 'The address or model does not exist (404); check the address and model id of “$host”';
  }

  @override
  String imgEditErrGenerateTimeout(String seconds) {
    return 'Generation took too long with no data (${seconds}s so far); retry or use a smaller size';
  }

  @override
  String imgEditErrLocalUnreachable(String host) {
    return 'Cannot reach your local service ($host)';
  }

  @override
  String get imgEditErrCancelledBilling =>
      'Stop requested; the server may still bill for it';

  @override
  String imgEditErrServerBody(String tail) {
    return 'The server returned an error in the response: $tail';
  }

  @override
  String imgEditErrBlocked(String tail) {
    return 'The service refused to generate this image (a content policy may have been triggered) $tail';
  }

  @override
  String get imgEditErrNotImage =>
      'The service returned data that is not an image; discarded (nothing was saved)';

  @override
  String get imgEditErrEmptyImage =>
      'The service returned an empty or truncated image (nothing was saved)';

  @override
  String get imgEditErrUrlOnly =>
      'The service returned only an image link (this feature does not accept links; nothing was saved)';

  @override
  String imgEditErrPartial(String ok, String failed) {
    return '$ok succeeded, $failed failed (incomplete result)';
  }

  @override
  String get imgEditErrInputNotImage =>
      'This photo cannot be decoded (it may not be an image or may be corrupted)';

  @override
  String imgEditErrTooLarge(String mb, String limit) {
    return 'The photo is too large ($mb MB); the limit is about $limit MB';
  }

  @override
  String get imgEditErrExifNotStripped =>
      'Internal error: could not strip the photo EXIF data (upload was blocked)';

  @override
  String get imgEditErrUrlRefused =>
      'Internal security policy: send base64 only, never send image links to a self-hosted backend';

  @override
  String get imgEditErrSaveDenied =>
      'No permission to save to the album; saving to this device is still available';

  @override
  String get imgEditErrUploadUnsupported =>
      'This NAS does not support uploading photos from the app';

  @override
  String get imgEditErrSessionExpired =>
      'The session has expired; please sign in again';

  @override
  String get imgEditErrDisabledMidFlight =>
      'AI enhancement was turned off; this result can still be saved';

  @override
  String get officeDocReadOnly => 'Read-only';

  @override
  String get officeDocRenderPartial =>
      'Some content is shown in a limited form.';

  @override
  String get officeDocRenderNotADoc => 'Not a renderable document tree';

  @override
  String officeDocUnsupportedType(String name) {
    return 'Unsupported node type: $name';
  }

  @override
  String officeDocUnsupportedUnknown(String name) {
    return 'Unsupported node type (not in schema): $name';
  }

  @override
  String get officeDocUnsupportedInline => 'Unsupported inline type';

  @override
  String get officeDocEmpty => 'This document has no displayable blocks';

  @override
  String get officeDocSettingsRow => 'Document settings (registered only)';

  @override
  String officeDocStyleEditorTitle(String count) {
    return 'Styles ($count)';
  }

  @override
  String officeDocStyleHeading(String name) {
    return 'Heading style $name';
  }

  @override
  String get officeDocStyleBody => 'Body';

  @override
  String get officeDocPageDecorate => 'Page decorations';

  @override
  String get officeDocHeader => 'Header';

  @override
  String get officeDocFooter => 'Footer';

  @override
  String get officeDocPageNum => 'Page number';

  @override
  String get officeDocPageNumToken => '#';

  @override
  String get officeDocPageBreak => 'Page break';

  @override
  String get officeDocTitle => 'Document';

  @override
  String get officeDocLoading => 'Loading document…';

  @override
  String get officeDocLoadFailed => 'Failed to open';

  @override
  String get officeDocSessionExpired => 'Session expired';

  @override
  String get officeDocNoContent => 'Nothing to display';

  @override
  String get officeDocRetry => 'Retry';

  @override
  String get officeDocFallbackPreview => 'Open read-only preview';

  @override
  String get officeDocSave => 'Save snapshot';

  @override
  String get officeDocSaveOk => 'Snapshot saved';

  @override
  String officeDocSaveFailed(String name) {
    return 'Save failed: $name';
  }

  @override
  String get officeDocSaveNoSession => 'No collaboration session; cannot save';

  @override
  String officeDocSessionUnavailable(String name) {
    return 'Collaboration session unavailable: $name';
  }

  @override
  String get officeDocEditNextBatch => 'Edit (next batch)';

  @override
  String get officeDocGatePending => 'Checking write permission…';

  @override
  String get officeDocGateAllowed => '—';

  @override
  String get officeDocGateNoPermission =>
      'No write/comment permission: opened read-only.';

  @override
  String get officeDocGateUnresolved =>
      'This document\'s Office identifiers are not resolved yet (the server may still be catching up right after creation): opened read-only. Tap Recheck to try again.';

  @override
  String get officeDocGateNotProvisioned =>
      'This document\'s Office data is not ready yet (right after creation the server needs a moment): opened read-only. Tap Recheck to try again.';

  @override
  String get officeDocGateRecheck => 'Recheck';

  @override
  String officeDocGateSchemaTooOld(String value) {
    return 'Server mobile schema $value < 2000: opened read-only.';
  }

  @override
  String get officeDocGateRelogin =>
      'Session expired: sign in again (opened read-only).';

  @override
  String get officeDocGateUnverified =>
      'We could not confirm write access to this file, so it opened read-only.';

  @override
  String get pbDestinationTitle => 'Backup destination';

  @override
  String get pbDestinationDrive => 'Synology Drive';

  @override
  String get pbDestinationPhotos => 'Synology Photos';

  @override
  String get pbDestinationDriveDesc =>
      'Official camera backup location: /mydrive/PhotoBackup/<device>/';

  @override
  String get pbDestinationPhotosDesc =>
      'Back up into the Phone Backup album in Synology Photos';

  @override
  String pbDestinationSwitched(String name) {
    return 'Switched to $name; each destination keeps its own ledger';
  }

  @override
  String pbTargetPathLabel(String path) {
    return 'Destination path: $path';
  }

  @override
  String get pbTargetDriveMissing =>
      'This NAS does not have Synology Drive photo upload';

  @override
  String get pbTargetPhotosMissing =>
      'This NAS does not have Synology Photos backup upload';

  @override
  String get pbTargetNoPermission =>
      'This account has no permission for this backup destination';

  @override
  String get pbTargetUnavailable => 'No backup destination is available';

  @override
  String get pbDcimOnly => 'Back up DCIM (camera) only';

  @override
  String get pbDcimOnlyHint =>
      'The official camera backup always covers DCIM only; turning this off also uploads screenshots and downloads';

  @override
  String get pbChargeOnly => 'Back up only while charging';

  @override
  String get pbChargeOnlyHint =>
      'Same constraint as the official app: runs only when plugged in (background uses system constraints, foreground takes effect immediately)';

  @override
  String get pbChargeBlocked =>
      'Not charging; paused because \"back up only while charging\" is on';

  @override
  String get pbScreenOffOnly => 'Back up only while the screen is off';

  @override
  String get pbScreenOffOnlyHint =>
      'Starts after the screen turns off; while the screen is on the background job backs off and retries';

  @override
  String get pbBackgroundTitle => 'Background backup';

  @override
  String get pbBackgroundScheduled =>
      'System background scheduling is on (about once an hour)';

  @override
  String get pbBackgroundNotScheduled =>
      'Not scheduled: turn on \"Automatic backup\" to let the system schedule it';

  @override
  String get pbBackgroundCharging => 'Charging';

  @override
  String get pbBackgroundNotCharging => 'Not charging';

  @override
  String get pbBackgroundScreenOn =>
      'Screen is on (with \"screen off only\" it waits until the screen turns off)';

  @override
  String get pbBackgroundScreenOff =>
      'Screen is off (meets \"screen off only\")';

  @override
  String get pbBackgroundBatteryHint =>
      'Battery optimization may kill background backup; adding this app to the allow list is recommended';

  @override
  String get pbBackgroundGrantBattery => 'Add to allow list';

  @override
  String pbBackgroundLastResult(String result) {
    return 'Last background result: $result';
  }

  @override
  String get pbBackgroundRunNow => 'Queue a run now';

  @override
  String get pbBackgroundUnsupported =>
      'This device does not support system background scheduling: backup runs only while the app is open';

  @override
  String pbBackgroundDevice(String name) {
    return 'Device name: $name';
  }

  @override
  String get imageEditEntryTitle => 'AI Enhance';

  @override
  String get imageEditEntryTooltip => 'AI Enhance (image-to-image)';

  @override
  String get imageEditBusyTooltip => 'Enhancing, please wait';

  @override
  String get imageEditSingleOnly =>
      'AI Enhance handles one photo at a time; select exactly one';

  @override
  String imageEditSendBanner(String host) {
    return 'This photo will be sent to <the service you configured> ($host)';
  }

  @override
  String get imageEditSendBannerLocalNote =>
      'If that address is not localhost/LAN, the photo still leaves your device';

  @override
  String imageEditSendSummary(String count) {
    return '$count photo(s) · EXIF (incl. GPS) removed';
  }

  @override
  String imageEditSendSummaryBytes(String count, String kb) {
    return '$count photo(s) · EXIF (incl. GPS) removed · ~$kb KB';
  }

  @override
  String get imageEditConsentTitle => 'Please confirm before use';

  @override
  String get imageEditConsentBody =>
      '· The photo itself (EXIF incl. GPS removed) is sent to the service you configured;<br>· it never passes through any server of this app;<br>· it may cost money;<br>· you can disable it or revoke consent anytime in \"AI Service → AI Enhance\".';

  @override
  String get imageEditConsentAgree => 'I understand and agree';

  @override
  String get imageEditConsentRefuse => 'Do not agree';

  @override
  String get imageEditPanelTitle => 'AI Enhance';

  @override
  String get imageEditPresetLabel => 'Preset';

  @override
  String get imageEditPromptLabel => 'Prompt';

  @override
  String get imageEditPromptHint => 'How should it be enhanced? e.g. sharpen';

  @override
  String imageEditPromptCounter(String chars, String limit) {
    return '$chars/$limit';
  }

  @override
  String get imageEditStrengthLabel => 'Strength';

  @override
  String get imageEditVariantsLabel => 'Variants';

  @override
  String imageEditVariantsCostUnknown(String count) {
    return 'Will generate $count · estimated cost: unit price unknown (recorded honestly, cannot be estimated)';
  }

  @override
  String imageEditVariantsCostLocal(String count) {
    return 'Will generate $count · estimated cost: 0 (self-hosted/LAN)';
  }

  @override
  String imageEditVariantsCostKnown(String count, String usd) {
    return 'Will generate $count · estimated cost: $usd USD';
  }

  @override
  String imageEditQuotaLine(String remaining, String cap) {
    return '$remaining/$cap left today';
  }

  @override
  String get imageEditStart => 'Start enhancing';

  @override
  String get imageEditAllowMobile => 'Use mobile data anyway';

  @override
  String get imageEditRunning => 'Enhancing…';

  @override
  String imageEditRunningElapsed(String seconds) {
    return 'Waiting ${seconds}s';
  }

  @override
  String get imageEditStop => 'Stop';

  @override
  String get imageEditResultTitle => 'Result';

  @override
  String imageEditVariantOf(String index, String total) {
    return 'Image $index/$total';
  }

  @override
  String get imageEditHoldToCompare => 'Hold to view the original';

  @override
  String get imageEditSaveAsNewPhoto => 'Save as new photo';

  @override
  String get imageEditSaveToDevice => 'Save to this device';

  @override
  String imageEditSavedToTimeline(String count) {
    return 'Saved as $count new photo(s)';
  }

  @override
  String imageEditSavedToDeviceOpened(String name) {
    return 'Saved to this device and opened: $name';
  }

  @override
  String imageEditSaveFailed(String error) {
    return 'Save failed: $error';
  }

  @override
  String get imageEditSettingsTitle => 'AI Enhance (image-to-image)';

  @override
  String get imageEditSettingsEnable => 'Enable AI Enhance';

  @override
  String get imageEditSettingsEnableHint =>
      'Off by default; photos are sent to the service you configured (never through this app\'s servers)';

  @override
  String get imageEditSettingsBackend => 'Backend';

  @override
  String get imageEditSettingsBaseUrl => 'Service URL';

  @override
  String get imageEditSettingsModel => 'Model';

  @override
  String get imageEditSettingsKey => 'API Key';

  @override
  String get imageEditSettingsDailyCap => 'Daily limit (photos)';

  @override
  String get imageEditSettingsCapOff => 'Off (0/day)';

  @override
  String imageEditSettingsCapValue(String count) {
    return '$count/day';
  }

  @override
  String get imageEditSettingsWifiOnly => 'Upload on Wi-Fi only';

  @override
  String get imageEditSettingsConsentDone => 'Consented (revocable anytime)';

  @override
  String get imageEditSettingsConsentMissing =>
      'Not yet consented (asked on first use)';

  @override
  String get imageEditSettingsRevoke => 'Revoke consent';

  @override
  String get imageEditSettingsRevoked =>
      'Consent revoked and AI Enhance disabled';

  @override
  String get photoMapPreciseNoNumbersHint =>
      'This photo has exact coordinates (WGS-84) and will be pinpointed. To protect privacy, the numbers are hidden by default (tap \"Copy coordinates\" to get them).';

  @override
  String get photoMapCopyCoord => 'Copy coordinates';

  @override
  String get photoMapOverseasConsentTitle =>
      'Send coordinates to an overseas map service?';

  @override
  String photoMapOverseasConsentBody(String service) {
    return 'Coordinates will be sent to $service (an overseas service, a cross-border transfer). They are only sent after you agree, and this notice is shown once.';
  }

  @override
  String get photoMapOverseasConsentAgree => 'Agree and continue';

  @override
  String get photoMapOverseasConsentRefuse => 'Cancel';

  @override
  String get officeDocEditNeedSelection => 'Select the text to format first.';

  @override
  String get officeDocEditNeedParagraph =>
      'Place the cursor in a paragraph first.';

  @override
  String get officeDocEditNoSession =>
      'The collaboration session is not established; editing is unavailable.';

  @override
  String officeDocEditFailed(String name) {
    return 'Edit failed: $name';
  }

  @override
  String officeDocEditStepDropped(String name) {
    return 'This step had no effect (rejected by the server): $name';
  }

  @override
  String officeDocEditRolledBack(String name) {
    return 'This step was not confirmed by the server and was rolled back: $name';
  }

  @override
  String get officeDocEditDropped =>
      'Could not align with the server; unconfirmed local edits were discarded.';

  @override
  String officeDocEditUnavailable(String name) {
    return 'This document cannot be edited: $name';
  }

  @override
  String get officeDocAligning => 'Version mismatch; aligning with the server…';

  @override
  String get officeDocAligned =>
      'Aligned with the server and resent local edits.';

  @override
  String get officeDocReconnecting =>
      'Connection restored; reloading the document…';

  @override
  String officeDocPendingCount(String count) {
    return '$count unconfirmed step(s)';
  }

  @override
  String get officeDocLeaveTitle => 'Unconfirmed edits';

  @override
  String officeDocLeavePending(String count) {
    return '$count edit(s) are not yet confirmed; leaving now may lose them.';
  }

  @override
  String get officeDocLeaveStay => 'Stay';

  @override
  String get officeDocLeaveConfirm => 'Leave anyway';

  @override
  String get officeDocBold => 'Bold';

  @override
  String officeDocMarkApplied(Object count, Object label) {
    return 'Applied $label to $count characters';
  }

  @override
  String officeDocMarkRemoved(Object label) {
    return '$label removed';
  }

  @override
  String get officeDocItalic => 'Italic';

  @override
  String get officeDocUnderline => 'Underline';

  @override
  String get officeDocHeading => 'Heading level';

  @override
  String get officeDocHeadingBody => 'Body';

  @override
  String officeDocHeadingLevel(String level) {
    return 'Heading $level';
  }

  @override
  String get officeDocList => 'List';

  @override
  String get officeDocUndo => 'Undo';

  @override
  String officeDocUndoOf(String name) {
    return 'Undo: $name';
  }

  @override
  String get officeDocRedo => 'Redo';

  @override
  String get calParticipantsLabel => 'Participants';

  @override
  String get calParticipantAdd => 'Add';

  @override
  String get calParticipantEmpty => 'No participants yet';

  @override
  String get calAddParticipant => 'Add participant';

  @override
  String get calParticipantEmailHint => 'Enter email';

  @override
  String get calParticipantAddEmail => 'Add as external participant';

  @override
  String get calParticipantUnsupported =>
      'This NAS calendar has no user-list API; enter an email address manually.';

  @override
  String get calParticipantPickUser => 'Pick a NAS user';

  @override
  String get calParticipantUsersFailed =>
      'Could not load the user list; you can enter an email address manually.';

  @override
  String get calParticipantNoUsers =>
      'No NAS users available; you can enter an email address manually.';

  @override
  String get calParticipantBadEmail => 'Enter a valid email address';

  @override
  String get calParticipantAccepted => 'Accepted';

  @override
  String get calParticipantDeclined => 'Declined';

  @override
  String get calParticipantTentative => 'Tentative';

  @override
  String get calParticipantNeedsAction => 'No response';

  @override
  String get noteDrawEntry => 'Drawing';

  @override
  String get noteDrawEntryHint => 'Draw and insert as a drawing attachment';

  @override
  String get noteDrawTitle => 'Drawing';

  @override
  String get noteDrawBrush => 'Brush';

  @override
  String get noteDrawEraser => 'Eraser';

  @override
  String get noteDrawColor => 'Color';

  @override
  String get noteDrawWidth => 'Size';

  @override
  String get noteDrawUndo => 'Undo';

  @override
  String get noteDrawRedo => 'Redo';

  @override
  String get noteDrawClear => 'Clear';

  @override
  String get noteDrawBackground => 'Background';

  @override
  String get noteDrawBackgroundWhite => 'White';

  @override
  String get noteDrawBackgroundTransparent => 'Transparent';

  @override
  String get noteDrawHint =>
      'Draw with one finger; two-finger gestures are ignored.';

  @override
  String get noteDrawHintDesktop =>
      'Drag to draw; use Undo/Redo on the toolbar to go back.';

  @override
  String get noteDrawInsert => 'Insert';

  @override
  String get noteDrawEmpty => 'The canvas is empty';

  @override
  String noteDrawExportFailed(String error) {
    return 'Failed to export the drawing: $error';
  }

  @override
  String noteDrawInsertFailed(String error) {
    return 'Failed to insert the drawing: $error';
  }

  @override
  String get noteDrawUnavailable => 'Drawing unavailable';

  @override
  String get noteDrawUnavailableHint =>
      'This server lacks the note attachment API, so drawings cannot be uploaded';

  @override
  String get mediaSessionReconnected =>
      'Reconnected — resuming from where you left off';

  @override
  String get mediaSessionResumeFailed =>
      'Session expired; automatic resume failed. Tap Retry to sign in again.';

  @override
  String get officeSheetTitle => 'Spreadsheet';

  @override
  String get officeSheetLoading => 'Loading spreadsheet…';

  @override
  String get officeSheetLoadFailed => 'Couldn\'t open';

  @override
  String get officeSheetSessionExpired => 'Sign-in session expired';

  @override
  String get officeSheetRetry => 'Retry';

  @override
  String get officeSheetFallbackPreview => 'Use read-only preview';

  @override
  String get officeSheetNoContent => 'No spreadsheet content to display';

  @override
  String get officeSheetEditNextBatch => 'Edit (coming next batch)';

  @override
  String officeSheetSessionUnavailable(String name) {
    return 'Collaboration session not established: $name';
  }

  @override
  String officeSheetModelFailed(String name) {
    return 'Couldn\'t rebuild the sheet model: $name';
  }

  @override
  String get officeSheetEmpty => 'This workbook has no sheets to display';

  @override
  String get officeSheetNoRows =>
      'This sheet has no rows or columns (rowCount/colCount is 0)';

  @override
  String officeSheetRenderPartial(String count) {
    return 'Some content in this sheet could not be shown completely ($count item(s)).';
  }

  @override
  String get mediaCoverUnavailable => 'No cover';

  @override
  String get fsDownloadTaskListTitle => 'Download tasks';

  @override
  String get fsDownloadTaskQueued => 'Queued';

  @override
  String get fsDownloadTaskDownloading => 'Downloading';

  @override
  String get fsDownloadTaskPaused => 'Paused';

  @override
  String get fsDownloadTaskDone => 'Completed';

  @override
  String get fsDownloadTaskFailed => 'Download failed';

  @override
  String get fsDownloadTaskCancelled => 'Cancelled';

  @override
  String get fsDownloadTaskOpen => 'Open';

  @override
  String get fsDownloadTaskRetry => 'Retry';

  @override
  String get fsDownloadTaskClose => 'Close';

  @override
  String get fsDownloadTaskBackground => 'Continue in background';

  @override
  String get fsDownloadTaskQueuedHint =>
      'Queued: starts after the current task finishes';

  @override
  String get fsDownloadTaskActiveHint =>
      'Tasks continue in the background; start another download to reopen this list';

  @override
  String fsDownloadTaskSummary(String done, String total) {
    return '$done/$total completed';
  }

  @override
  String get officeSheetEditHint =>
      'Tap a cell to edit; changes sync immediately.';

  @override
  String get officeSheetEditNoSession =>
      'Collaboration session is not established; read-only for now.';

  @override
  String get officeSheetPendingNone => 'All changes confirmed';

  @override
  String officeSheetPendingCount(String count, String cells) {
    return 'Unconfirmed changes: $count ($cells cells)';
  }

  @override
  String get officeSheetEditRetry => 'Retry';

  @override
  String officeSheetEditFailedCell(String cell, String reason) {
    return 'The change to \"$cell\" did not take effect: $reason';
  }

  @override
  String get officeSheetEditReasonRejected =>
      'The server rejected this change (status 0)';

  @override
  String officeSheetEditReasonStale(String count) {
    return 'The server version stayed stale after $count replays';
  }

  @override
  String officeSheetEditReasonTransport(String detail) {
    return 'Send failed: $detail';
  }

  @override
  String officeSheetEditReasonUnknown(String detail) {
    return 'Could not confirm the server result: $detail';
  }

  @override
  String get fsDownloadTaskEmpty => 'No download tasks yet';

  @override
  String get fsDownloadTaskEntry => 'Download tasks';

  @override
  String fsDownloadTaskEntryActive(String count, String percent) {
    return 'Download tasks · $count active · $percent%';
  }

  @override
  String get fsDownloadDisabled =>
      'File download is not available on this server';

  @override
  String asQueueRestoreSkipped(String count) {
    return 'Skipped $count unavailable item(s) in the play queue';
  }

  @override
  String get fsC5TaskDetail => 'Task details';

  @override
  String get officeSlidesTitle => 'Presentation';

  @override
  String get officeSlidesLoading => 'Loading presentation…';

  @override
  String get officeSlidesLoadFailed => 'Couldn\'t open';

  @override
  String get officeSlidesSessionExpired => 'Sign-in session expired';

  @override
  String get officeSlidesRetry => 'Retry';

  @override
  String get officeSlidesFallbackPreview => 'Use read-only preview';

  @override
  String get officeSlidesNoContent => 'No presentation content to display';

  @override
  String get officeSlidesEditNextBatch => 'Edit (coming in the next batch)';

  @override
  String officeSlidesSessionUnavailable(String name) {
    return 'Collaboration session unavailable: $name';
  }

  @override
  String officeSlidesModelFailed(String name) {
    return 'Couldn\'t rebuild the presentation model: $name';
  }

  @override
  String get officeSlidesEmpty => 'This presentation has no slides to display';

  @override
  String officeSlidesRenderPartial(String count) {
    return 'Some content is shown in a limited way ($count unregistered/unrendered items, see markers below).';
  }

  @override
  String officeSlidesSlidePage(String index) {
    return 'Slide $index';
  }

  @override
  String officeSlidesSlideCount(String count) {
    return '$count slides';
  }

  @override
  String officeSlidesLayoutCount(String count) {
    return '$count layouts';
  }

  @override
  String officeSlidesImageCount(String count) {
    return '$count images';
  }

  @override
  String get officeSlidesHiddenSlide => 'Hidden slide';

  @override
  String get officeSlidesSlideEmpty => 'No body content on this slide';

  @override
  String get officeSlidesNotes => 'Notes';

  @override
  String officeSlidesMaster(String count) {
    return 'Master (not merged into slides, $count blocks)';
  }

  @override
  String get officeSlidesMasterEmpty => 'The master has no text';

  @override
  String get officeSlidesReadOnly => 'Read-only rendering';

  @override
  String get officeSlidesPageNumberToken => 'Page number';

  @override
  String get officeSlidesDateTimeToken => 'Date/time';

  @override
  String officeSlidesUnsupportedType(String name) {
    return 'Type not rendered yet: $name';
  }

  @override
  String officeSlidesUnsupportedUnknown(String name) {
    return 'Type not rendered (not declared in the schema): $name';
  }

  @override
  String get officeSlidesUnsupportedInline => 'Unsupported inline type';

  @override
  String get asQuickCast => 'Cast';

  @override
  String get asQuickEffects => 'Effects';

  @override
  String get asEqGroupMaster => 'Master';

  @override
  String get asEqGroupPresets => 'Presets';

  @override
  String get asCastDlnaHint =>
      'You can use DLNA on the same network instead (see Remote players).';

  @override
  String get asCastGroupDevices => 'Castable devices';

  @override
  String get asPlayCountOne => 'Played once';

  @override
  String get asMinutesAgoOne => '1 minute ago';

  @override
  String get asHoursAgoOne => '1 hour ago';

  @override
  String get asDaysAgoOne => '1 day ago';

  @override
  String get asMoreSources => 'Media sources';

  @override
  String get asMorePlayback => 'Playback & casting';

  @override
  String get asUnnamedName => 'Unnamed';

  @override
  String get asLyricsFullscreen => 'Full-screen lyrics';

  @override
  String get asLyricsCopied => 'Line copied';

  @override
  String get asLyricsFontSmaller => 'Smaller text';

  @override
  String get asLyricsFontLarger => 'Larger text';

  @override
  String get asQualityHint =>
      'Applies only when the server transcodes; direct play uses the original file';

  @override
  String get asRadioInfo => 'Station info';

  @override
  String get asRadioStop => 'Stop';

  @override
  String get asRadioOpenPlayer => 'Open player';

  @override
  String get asRadioNowPlaying => 'Now playing';

  @override
  String get asRadioPaused => 'Paused';

  @override
  String get asRadioDesc => 'Description';

  @override
  String get asRadioDescEmpty => '(No description from the station)';

  @override
  String get asRadioTechHint =>
      'Address and codec are set by the station; change them via “Edit station”.';

  @override
  String get asQueueEntry => 'Play queue';

  @override
  String asQueueEntryActive(String count) {
    return 'Play queue · $count track(s)';
  }

  @override
  String get asQueueEmpty => 'The play queue is empty (single-track playback)';

  @override
  String get chatAvailableChannelsTitle => 'Public channels';

  @override
  String get chatAvailableChannelsSearch => 'Search channel name';

  @override
  String get chatAvailableChannelsNoPrivilege =>
      'No permission to view public channels';

  @override
  String get chatAvailableChannelsLoadFailed =>
      'Failed to load public channels';

  @override
  String get chatAvailableChannelsLoadFailedDetail =>
      'Check your network and try again';

  @override
  String chatAvailableChannelsMembers(String count) {
    return '$count members';
  }

  @override
  String get chatAvailableChannelsJoin => 'Join';

  @override
  String get chatAvailableChannelsNoMatch => 'No matching channel';

  @override
  String get officeSlidesEditNoSession =>
      'Collaboration session not established; read-only.';

  @override
  String get officeSlidesEditHint =>
      'Tap the text on a slide to edit (changes sync immediately).';

  @override
  String get officeSlidesEditNoBlocks =>
      'This presentation has no editable text';

  @override
  String get officeSlidesEditEmptyBlock => '(empty text block)';

  @override
  String get officeSlidesEditHintShort => 'Enter text';

  @override
  String get officeSlidesEditCancel => 'Cancel';

  @override
  String get officeSlidesEditSave => 'Save';

  @override
  String get officeSlidesEditRetry => 'Retry';

  @override
  String get officeSlidesPendingNone => 'All changes confirmed';

  @override
  String officeSlidesPendingCount(String count, String blocks) {
    return 'Unconfirmed changes: $count ($blocks blocks)';
  }

  @override
  String get officeSlidesEditReasonRejected =>
      'The server rejected this change (status 411)';

  @override
  String officeSlidesEditReasonStale(String count) {
    return 'The server version stayed stale; replayed $count times';
  }

  @override
  String officeSlidesEditReasonHistory(String detail) {
    return 'Failed to fetch remote increments: $detail';
  }

  @override
  String officeSlidesEditReasonTransport(String detail) {
    return 'Send failed: $detail';
  }

  @override
  String officeSlidesEditReasonUnknown(String detail) {
    return 'Cannot confirm the server result: $detail';
  }

  @override
  String officeSlidesEditFailedBlock(String block, String reason) {
    return 'Change to \"$block\" did not take effect: $reason';
  }

  @override
  String get officeAttachmentMissingId =>
      'Missing file identity; cannot load the image';

  @override
  String get officeAttachmentEmpty => 'Server returned an empty image';

  @override
  String get officeAttachmentTimeout => 'Image request timed out';

  @override
  String get officeAttachmentNotFound => 'Attachment not found (404)';

  @override
  String get officeAttachmentUnresolvable =>
      'The server cannot provide this image\'s attachment (120)';

  @override
  String get officeAttachmentNoPermission =>
      'No permission to view this attachment (105)';

  @override
  String officeAttachmentSessionExpired(String code) {
    return 'Session expired ($code)';
  }

  @override
  String officeAttachmentHttpFailed(String status) {
    return 'Request failed (HTTP $status)';
  }

  @override
  String get officeAttachmentListNeedsObjectId =>
      'Missing file identity; cannot list attachments';

  @override
  String get officeDocImageFailed => 'Image failed to load';

  @override
  String officeDocImageFailedNamed(String name) {
    return 'Image failed to load: $name';
  }

  @override
  String get officeDocImageRetry => 'Retry';

  @override
  String get officeDocImageReasonMissing => 'No usable image reference';

  @override
  String get officeDocImageReasonNotFound => 'Image not found on the server';

  @override
  String get officeDocImageReasonNoPermission =>
      'No permission to view this image';

  @override
  String get officeDocImageReasonSession =>
      'Session expired; sign in and retry';

  @override
  String get officeDocImageReasonTimeout => 'Network timeout';

  @override
  String get officeDocImageReasonNetwork => 'Network connection failed';

  @override
  String get officeDocImageReasonEmpty => 'Server returned an empty image';

  @override
  String get officeDocImageReasonUnknown => 'Temporarily unavailable';

  @override
  String get fsGapNoMore => 'No more items';

  @override
  String get fsGapLoadingMore => 'Loading more…';

  @override
  String get fsGapLoadMoreFailed => 'Failed to load more';

  @override
  String get fsGapRetry => 'Retry';

  @override
  String get fsGapEditShareLink => 'Edit share link';

  @override
  String get fsGapShareNewPassword => 'New password';

  @override
  String get fsGapSharePasswordKeep =>
      'Leave blank to keep the current password';

  @override
  String get fsGapSharePasswordRemove => 'Saving will remove the password';

  @override
  String get fsGapShareValidityKeep => 'Keep current';

  @override
  String get fsGapShareEdited => 'Share link updated';

  @override
  String get fsGapShareSend => 'Send';

  @override
  String get fsGapShareSendFailed => 'Send failed (no app available)';

  @override
  String get fsGapReadOnlyShare => 'Read-only share';

  @override
  String get driveGapSortTitle => 'Sort';

  @override
  String get driveGapSortDefault => 'Default';

  @override
  String get driveGapSortName => 'Name';

  @override
  String get driveGapSortSize => 'Size';

  @override
  String get driveGapSortModified => 'Modified';

  @override
  String get driveGapSortCreated => 'Created';

  @override
  String get driveGapSortAscending => 'Ascending';

  @override
  String get driveGapSortDescending => 'Descending';

  @override
  String get driveGapViewList => 'List view';

  @override
  String get driveGapViewGrid => 'Grid view';

  @override
  String get driveGapSearchHistoryTitle => 'Recent searches';

  @override
  String get driveGapSearchHistoryClear => 'Clear';

  @override
  String get driveGapRequestIdentifierTitle => 'How should uploads be grouped?';

  @override
  String get driveGapRequestIdentifierCreateFolder =>
      'Create a folder for each uploader';

  @override
  String get driveGapRequestIdentifierAddPrefix =>
      'Add uploader name before the file name';

  @override
  String get driveGapNewTextFile => 'Text file';

  @override
  String get driveGapNewTextFileHint =>
      'Plain text (.txt), editable right away';

  @override
  String get driveGapTextEditorTitle => 'Edit text';

  @override
  String driveGapTextEditorLoadFailed(String error) {
    return 'Couldn\'t open this text file: $error';
  }

  @override
  String get driveGapTextEditorSave => 'Save';

  @override
  String get driveGapTextEditorHint => 'Start typing…';

  @override
  String get driveGapTextEditorSaved => 'Saved';

  @override
  String driveGapTextEditorSaveFailed(String error) {
    return 'Save failed: $error';
  }

  @override
  String get driveGapTextEditorNotEditable =>
      'Saving in-app isn\'t supported here (personal space only)';

  @override
  String get driveGapTextEditorReadOnly =>
      'Read-only: you don\'t have permission to change this file';

  @override
  String get driveGapEditText => 'Edit text';

  @override
  String driveGapTextCreated(String name) {
    return 'Created \"$name\"';
  }

  @override
  String get driveGapScopeTitle =>
      'This is My Drive — it\'s split into three scopes';

  @override
  String get driveGapScopeIntro =>
      'Switch to the other two scopes under \"More\":';

  @override
  String get driveGapScopeMyDriveTitle => 'My Drive';

  @override
  String get driveGapScopeMyDriveBody => 'Your own files, visible only to you.';

  @override
  String get driveGapScopeSharedTitle => 'Shared with me';

  @override
  String get driveGapScopeSharedBody =>
      'Individual files or folders others shared with you.';

  @override
  String get driveGapScopeTeamTitle => 'Team folders';

  @override
  String get driveGapScopeTeamBody =>
      'Shared team space; members read/write per permission.';

  @override
  String get driveGapScopeDismiss => 'Got it';

  @override
  String get officeDocChartPlaceholder => 'Chart (no data to render yet)';

  @override
  String get mediaSessionRenewFailedPaused =>
      'Session expired and automatic renewal failed — playback paused. Reopen the app and sign in again, then retry.';

  @override
  String get photoWave1TimelineViewDay => 'Day';

  @override
  String get photoWave1TimelineViewMonth => 'Month';

  @override
  String get photoWave1TimelineViewYear => 'Year';

  @override
  String get photoWave1TimelineViewMode => 'Time scale';

  @override
  String photoWave1GroupYear(String year) {
    return '$year';
  }

  @override
  String get photoWave1LoadMore => 'Load more';

  @override
  String get photoWave1LoadingMore => 'Loading more…';

  @override
  String photoWave1AllLoaded(int count) {
    return 'All loaded ($count photos)';
  }

  @override
  String photoWave1LoadMoreFailed(String error) {
    return 'Failed to load more: $error';
  }

  @override
  String get photoWave1AlbumSort => 'Album sort';

  @override
  String get photoWave1AlbumSortBy => 'Sort by';

  @override
  String get photoWave1AlbumSortDirection => 'Sort direction';

  @override
  String get photoWave1AlbumSortAsc => 'Ascending';

  @override
  String get photoWave1AlbumSortDesc => 'Descending';

  @override
  String get photoWave1AlbumSortName => 'Name';

  @override
  String get photoWave1AlbumSortCreateTime => 'Creation time';

  @override
  String get photoWave1AlbumSortStartTime => 'Start time';

  @override
  String get photoWave1AlbumSortType => 'Type';

  @override
  String get photoWave1AlbumSortSharingStatus => 'Sharing status';

  @override
  String get photoWave1AlbumSortShareModTime => 'Sharing modified time';

  @override
  String get photoWave1AlbumSortSaved => 'Sort order saved';

  @override
  String photoWave1AlbumSortFailed(String error) {
    return 'Failed to save sort order: $error';
  }

  @override
  String get photoWave1MoveToFolder => 'Move to folder';

  @override
  String get photoWave1CopyToFolder => 'Copy to folder';

  @override
  String get photoWave1MoveCopyPickFolder => 'Choose destination folder';

  @override
  String get photoWave1MoveCopyNoFolders => 'No folders available';

  @override
  String photoWave1MovedCount(int count) {
    return 'Moved $count items';
  }

  @override
  String photoWave1CopiedCount(int count) {
    return 'Copied $count items';
  }

  @override
  String photoWave1MoveCopyFailed(String error) {
    return 'Operation failed: $error';
  }

  @override
  String get chatActionCopyDesc => 'Copy description';

  @override
  String get chatMentionButton => 'Mention someone';

  @override
  String get noteGapsSelectAll => 'Select all';

  @override
  String get noteGapsInvertSelection => 'Invert';

  @override
  String noteGapsSelectedCount(int count) {
    return '$count selected';
  }

  @override
  String get noteGapsBatchDelete => 'Delete';

  @override
  String noteGapsBatchDeleteConfirm(int count) {
    return 'Delete the $count selected notes?';
  }

  @override
  String get noteGapsBatchMove => 'Move';

  @override
  String get noteGapsBatchMoveTitle => 'Move to notebook';

  @override
  String noteGapsBatchDeleted(int count) {
    return 'Deleted $count notes';
  }

  @override
  String noteGapsBatchMoved(int count) {
    return 'Moved $count notes';
  }

  @override
  String noteGapsBatchPartial(int ok, int fail) {
    return 'Deleted $ok, failed $fail';
  }

  @override
  String noteGapsBatchFailed(String error) {
    return 'Batch operation failed: $error';
  }

  @override
  String get noteGapsSort => 'Sort';

  @override
  String get noteGapsSortByTitle => 'By title';

  @override
  String get noteGapsSortByCtime => 'By created time';

  @override
  String get noteGapsSortByMtime => 'By modified time';

  @override
  String get noteGapsSortAsc => 'Ascending';

  @override
  String get noteGapsSortDesc => 'Descending';

  @override
  String get noteGapsAttachmentSearch => 'Search attachment text';

  @override
  String get noteGapsAttachmentView => 'View text';

  @override
  String get noteGapsAttachmentTextEmpty => '(No text to preview)';

  @override
  String noteGapsAttachmentTextFailed(String error) {
    return 'Failed to read attachment text: $error';
  }

  @override
  String get noteGapsDefaultFontSize => 'Default font size';

  @override
  String get noteGapsDefaultFontSizeSet => 'Default font size saved';

  @override
  String get noteGapsRecordAudio => 'Record audio';

  @override
  String get noteGapsRecordAudioStart => 'Recording…';

  @override
  String get noteGapsRecordAudioStop => 'Done';

  @override
  String get noteGapsRecordAudioDenied => 'No microphone permission';

  @override
  String noteGapsRecordAudioFailed(String error) {
    return 'Recording failed: $error';
  }

  @override
  String get noteGapsRecordAudioFileName => 'Recorded as .3gp attachment';

  @override
  String get noteGapsRecordVideo => 'Record video';

  @override
  String get noteGapsShareClip => 'Clip to note';

  @override
  String get noteGapsShareClipNoNotebook =>
      'No notebook available to clip into.';

  @override
  String get noteGapsShareClipDone => 'Clipped to a note.';

  @override
  String get noteGapsShareClipFailed =>
      'Failed to clip the shared item. Try again.';

  @override
  String get noteGapsShareClipTitle => 'Shared text';

  @override
  String get officeSlidesShapeUnsupported => 'This shape is not supported yet';

  @override
  String get dsFileList => 'Files';

  @override
  String get dsFileEmpty => 'No file information';

  @override
  String get dsFileSkipped => 'Skipped';

  @override
  String get dsLoadMore => 'Load more';

  @override
  String dsFilesTotal(int n) {
    return '$n files in total';
  }

  @override
  String get dsFilesInactive =>
      'The task is not active or has finished; no file list available';

  @override
  String get dsExportTorrent => 'Export .torrent';

  @override
  String dsTorrentExported(String name) {
    return 'Exported $name';
  }

  @override
  String dsTorrentExportFailed(String msg) {
    return 'Export failed: $msg';
  }

  @override
  String get dsSettings => 'Download settings';

  @override
  String get dsSettingsLoadFailed => 'Failed to load settings';

  @override
  String dsSettingsSaveFailed(String msg) {
    return 'Failed to save: $msg';
  }

  @override
  String get dsAutoExtraction => 'Auto extraction';

  @override
  String get dsUnzipToPath => 'Folder path';

  @override
  String get dsUnzipToPathHint => 'e.g. /volume1/downloads';

  @override
  String get dsUnzipToPathSave => 'Save path';

  @override
  String get dsUnzipCreateSubfolder => 'Create a subfolder';

  @override
  String get dsUnzipOverwrite => 'Overwrite existing files';

  @override
  String get dsUnzipDeleteArchive => 'Delete the archive after extraction';

  @override
  String get dsUnzipNeedPath => 'Enter a destination folder first';

  @override
  String get dsAutoExtractionHint =>
      'Automatically extract archives after download (server setting)';

  @override
  String get dsAutoExtractionSaved => 'Auto extraction setting saved';

  @override
  String get dsAutoExtractionUnsupported =>
      'This NAS\'s Download Station does not support the auto extraction setting';

  @override
  String get dsUnzipLocation => 'Extraction location';

  @override
  String get dsErrSourceNotAvailable =>
      'This task has no source file to export';

  @override
  String get dsErrNoThumbnail => 'This task has no thumbnail yet';

  @override
  String get dsErrFileListInactive =>
      'The task is not active or has finished; no file list available';

  @override
  String get fsGap2PickFolder => 'Choose this folder';

  @override
  String get fsGap2Up => 'Up';

  @override
  String get fsGap2NoSubfolder => 'No subfolders here';

  @override
  String get fsGap2LoadFailed => 'Failed to load folder';

  @override
  String get fsGap2Root => 'Root';

  @override
  String get fsGap2CompressMode => 'Update mode';

  @override
  String get fsGap2ModeAdd => 'Add (new archive)';

  @override
  String get fsGap2ModeUpdate => 'Update (add and replace)';

  @override
  String get fsGap2ModeFreshen => 'Freshen (update existing only)';

  @override
  String get fsGap2ModeSynchronize => 'Synchronize';

  @override
  String get fsGap2FavoriteReorder => 'Reorder favorites';

  @override
  String get fsGap2FavoriteReorderSave => 'Save order';

  @override
  String get fsGap2FavoriteReordered => 'Favorite order saved';

  @override
  String get fsGap2MoveUp => 'Move up';

  @override
  String get fsGap2MoveDown => 'Move down';

  @override
  String get fsGap2PersonalFolder => 'Personal folder';

  @override
  String get fsGap2TaskRetry => 'Retry';

  @override
  String get fsGap2TaskRetryNoPlan => 'No parameter snapshot; cannot retry';

  @override
  String get fsGap2TaskRetrySubmitted => 'Task resubmitted';

  @override
  String get fsGap2TaskParamSecretMasked => 'Hidden (password-type parameter)';

  @override
  String get fsGap2Shortcut => 'Create home shortcut';

  @override
  String get fsGap2ShortcutDone => 'Shortcut requested';

  @override
  String get fsGap2ShortcutFailed => 'Shortcuts not supported on this device';

  @override
  String get fsGap2FavoriteReorderFailed => 'Failed to save favorite order';

  @override
  String get fsGap2FavoriteReorderRejected =>
      'The server rejected these parameters';

  @override
  String get officeLibraryNtypePresentation => 'Presentation';

  @override
  String get officeLibraryNtypeDoc => 'Document';

  @override
  String get officeLibraryNtypeSheet => 'Spreadsheet';

  @override
  String get officeTemplateLibraryEmpty =>
      'No templates returned by the server';

  @override
  String get officeTemplateFilterAll => 'All';

  @override
  String get officeTemplateCanPreview => 'Previewable';

  @override
  String get officeTemplatePreview => 'Details / Preview';

  @override
  String get officeTemplateMake => 'New from template';

  @override
  String get officeTemplateMakeDialogTitle => 'New from template';

  @override
  String get officeTemplateMakeTitleLabel => 'File name (optional)';

  @override
  String get officeTemplateMakeCancel => 'Cancel';

  @override
  String get officeTemplateMakeConfirm => 'Create';

  @override
  String officeTemplateMakeCreated(Object name) {
    return 'Created from template “$name”';
  }

  @override
  String officeTemplateMakeFailed(Object error) {
    return 'Failed to create from template: $error';
  }

  @override
  String get officeTemplatePreviewAction => 'Preview';

  @override
  String get officeTemplatePreviewClose => 'Close';

  @override
  String get officeTemplatePreviewNote =>
      'Official thumbnail preview, not a rendering of the document body. Create from this template to open its content.';

  @override
  String officeTemplatePreviewCounter(Object index, Object total) {
    return '$index / $total';
  }

  @override
  String get officeTemplatePreviewPrev => 'Previous';

  @override
  String get officeTemplatePreviewNext => 'Next';

  @override
  String get officeTemplatePreviewShowBody => 'Show body';

  @override
  String get officeTemplatePreviewShowThumb => 'Show thumbnail';

  @override
  String get officeTemplatePreviewBodyNote =>
      'The document body is exported by the server and rendered locally (read-only). If the export fails, the official thumbnail is shown.';

  @override
  String get officeTemplateBodyEncrypted =>
      'This is an encrypted template; a password is required to export its body.';

  @override
  String get officeTemplateBodyUnknownType =>
      'This template type has no usable body export.';

  @override
  String officeTemplateBodyFailed(Object error) {
    return 'Body export failed: $error';
  }

  @override
  String get officeTemplateBodyFetching => 'Fetching the template content…';

  @override
  String get officeTemplateBodyRendering => 'Laying out the content…';

  @override
  String get officeTemplateBodyReasonMissingId =>
      'This template has no identifier, so its content cannot be fetched.';

  @override
  String get officeTemplateBodyReasonNotFound =>
      'The server says this template’s content is gone (it may have been deleted).';

  @override
  String get officeTemplateBodyReasonNoPermission =>
      'This account is not allowed to export this template’s content.';

  @override
  String get officeTemplateBodyReasonSession =>
      'The session has expired. Reconnect and try again.';

  @override
  String get officeTemplateBodyReasonTimeout =>
      'Timed out fetching the template content. You can retry.';

  @override
  String get officeTemplateBodyReasonNetwork =>
      'The network is unreachable, so the template content cannot be fetched.';

  @override
  String get officeTemplateBodyReasonEmpty =>
      'The server returned an empty body (this template may have no content).';

  @override
  String get officeTemplateBodyNotOoxml =>
      'The server did not return a standard spreadsheet file, so it cannot be previewed.';

  @override
  String officeTemplateBodyParseFailed(Object error) {
    return 'This template could not be parsed: $error';
  }

  @override
  String get officeTemplateExportMissingId =>
      'Missing template identity; cannot fetch the template body';

  @override
  String get officeTemplateExportEmpty => 'The server returned an empty body.';

  @override
  String get officeTemplateExportTimeout =>
      'Timed out fetching the template body.';

  @override
  String get officeTemplateExportUnavailable =>
      'This channel is unavailable on the current connection.';

  @override
  String get officeTemplateUse => 'Use this template';

  @override
  String get officeTemplateUseEncrypted => 'Create encrypted';

  @override
  String get officeTemplateSourceSystem => 'System';

  @override
  String get officeTemplateSourceMine => 'Mine';

  @override
  String get officeTemplateMoreActions => 'More actions';

  @override
  String get officeTemplateThumbMissingId =>
      'Missing template identity; cannot load the thumbnail';

  @override
  String get officeTemplateThumbEmpty =>
      'The server returned an empty thumbnail';

  @override
  String get officeTemplateThumbTimeout => 'Timed out loading the thumbnail';

  @override
  String get officeThemeEmpty => 'No themes for this type';

  @override
  String get officeThemeApply => 'Apply theme';

  @override
  String officeThemeApplyFailed(Object error) {
    return 'Failed to apply theme: $error';
  }

  @override
  String officeThemeApplied(Object name) {
    return 'Asked the server to apply theme “$name”';
  }

  @override
  String get officeVersionEmpty => 'No version history';

  @override
  String get officeVersionFirst => 'Initial version';

  @override
  String officeSheetConditionalFormats(Object count) {
    return 'Conditional formatting rules applied ($count)';
  }

  @override
  String officeSheetConditionalFormatLine(Object formula, Object ranges) {
    return '$ranges · $formula';
  }

  @override
  String get dsBtSearchTitle => 'BT search';

  @override
  String get dsBtBack => 'Back';

  @override
  String get dsBtSearchHint => 'Enter a keyword to search torrents';

  @override
  String get dsBtSearchAction => 'Search';

  @override
  String get dsBtSourceLabel => 'Source';

  @override
  String get dsBtSourceAll => 'All sources';

  @override
  String get dsBtIdleTitle => 'Search torrents';

  @override
  String get dsBtIdleMessage =>
      'Enter a keyword to search the sources enabled on your NAS.';

  @override
  String get dsBtSearching => 'Searching…';

  @override
  String get dsBtIncompleteHint =>
      'Some sources could not be reached; results may be incomplete.';

  @override
  String get dsBtCategoryAll => 'All categories';

  @override
  String get dsBtSortTooltip => 'Sort';

  @override
  String get dsBtSortFieldTitle => 'Name';

  @override
  String get dsBtSortFieldSize => 'Size';

  @override
  String get dsBtSortFieldDate => 'Date';

  @override
  String get dsBtSortFieldSeeds => 'Seeds';

  @override
  String get dsBtSortFieldPeers => 'Peers';

  @override
  String get dsBtSortAsc => 'Ascending';

  @override
  String get dsBtSortDesc => 'Descending';

  @override
  String get dsBtLoadMore => 'Load more';

  @override
  String get dsBtEndOfResults => 'No more results';

  @override
  String get dsBtDownload => 'Download';

  @override
  String get dsBtDownloadAdded => 'Added to download tasks';

  @override
  String dsBtDownloadFailed(Object error) {
    return 'Failed to add download: $error';
  }

  @override
  String get dsBtUntitled => '(Untitled)';

  @override
  String get dsBtUnknown => 'Unknown';

  @override
  String get dsBtSizeLabel => 'Size';

  @override
  String get dsBtSeedsLabel => 'Seeds';

  @override
  String get dsBtPeersLabel => 'Peers';

  @override
  String get dsLabelSep => ': ';

  @override
  String get dsBtNeedDest =>
      'Could not read the default download folder. Confirm a folder in New task to create it.';

  @override
  String get dsBtErrorTitle => 'Search failed';

  @override
  String get dsBtNoResultsTitle => 'No results found';

  @override
  String get dsBtNoResultsMessage => 'Try another keyword or source.';

  @override
  String get dsBtUnavailableTitle => 'BT search unavailable';

  @override
  String get dsBtUnavailableApiMissing => 'Not connected to a NAS yet.';

  @override
  String get dsBtUnavailableNotInstalled =>
      'Download Station is not installed on this NAS.';

  @override
  String get dsBtUnavailableNoPrivilege =>
      'This account does not have permission to use BT search.';

  @override
  String get dsBtUnavailableIdNotFound =>
      'BT search is not enabled on this NAS, or the search session has expired.';

  @override
  String get dsBtUnavailableNoPlugins =>
      'BT search is not enabled on this NAS, or no sources are available.';

  @override
  String get dsBtUnavailableSources => 'No usable sources were found.';

  @override
  String get dsBtUnavailableOffline =>
      'Network connection failed. Check your network and try again.';

  @override
  String get dsErrBtSearchUnavailable =>
      'BT search is not enabled on this NAS or no sources are available';

  @override
  String get photoWave2SearchFilter => 'Filter';

  @override
  String get photoWave2SearchFilterTitle => 'Filters';

  @override
  String get photoWave2SearchFilterApply => 'Apply';

  @override
  String get photoWave2SearchFilterClear => 'Clear all';

  @override
  String get photoWave2SearchFilterUnavailable =>
      'Filters aren\'t available right now';

  @override
  String photoWave2SearchFilterActive(Object count) {
    return '$count filter group(s) active';
  }

  @override
  String get photoWave2Tags => 'Tags';

  @override
  String get photoWave2TagsEntry =>
      'Browse photos by tag (tags are indexed on the NAS)';

  @override
  String get photoWave2TagsEmpty => 'No tags yet';

  @override
  String photoWave2TagItemCount(Object count) {
    return '$count photos';
  }

  @override
  String get photoWave2TagPhotosEmpty => 'No photos with this tag yet';

  @override
  String get photoWave2TagsLocalNote =>
      'The server\'s tag list is empty right now; showing tags this device has seen';

  @override
  String photoWave2TagLoaded(Object count) {
    return 'Loaded $count';
  }

  @override
  String photoWave2TagTotal(Object count) {
    return '$count tags';
  }

  @override
  String get photoWave2Persons => 'People';

  @override
  String get photoWave2PersonsEntry =>
      'Browse photos by person (requires face recognition on the NAS)';

  @override
  String get photoWave2PersonSearchHint => 'Search by name prefix';

  @override
  String get photoWave2PersonSuggestEmpty => 'No matching people';

  @override
  String photoWave2PersonFaces(Object count) {
    return '$count faces detected on this page';
  }

  @override
  String get photoWave2PersonFacesFailed =>
      'Face info isn\'t available right now';

  @override
  String get photoWave2PartialUnavailable =>
      'This part isn\'t available right now — try again later.';

  @override
  String get calSettingsTitle => 'Calendar settings';

  @override
  String get calSettingsSubtitle =>
      'Colors / time zone / sharing / user settings (read-only)';

  @override
  String get calEventColorsSection => 'Event colors (from server)';

  @override
  String get calEventColor => 'Event color';

  @override
  String get calColorDefault => 'Default color';

  @override
  String get calNoServerColors =>
      'This NAS returned no usable colors (it needs a newer server version).';

  @override
  String get calTimezoneSection => 'Time zone';

  @override
  String get calTimezoneCurrent => 'Time zone for new events';

  @override
  String get calTimezonePick => 'Choose a time zone';

  @override
  String get calTimezoneEmpty => 'This NAS returned no time zone list.';

  @override
  String get calUserSettingsSection => 'User settings (read-only)';

  @override
  String get calDateFormat => 'Date format';

  @override
  String get calTimeFormat => 'Time format';

  @override
  String get calWeekStart => 'Week starts on';

  @override
  String get calDefaultView => 'Default view';

  @override
  String get calShowWeekNumbers => 'Show week numbers';

  @override
  String get calYes => 'Yes';

  @override
  String get calNo => 'No';

  @override
  String get calWeekdaySun => 'Sunday';

  @override
  String get calWeekdayMon => 'Monday';

  @override
  String get calWeekdayTue => 'Tuesday';

  @override
  String get calWeekdayWed => 'Wednesday';

  @override
  String get calWeekdayThu => 'Thursday';

  @override
  String get calWeekdayFri => 'Friday';

  @override
  String get calWeekdaySat => 'Saturday';

  @override
  String get calSharingSection => 'Shared calendars';

  @override
  String get calSharingManage => 'View / manage members';

  @override
  String get calSharingNone => 'This calendar is not shared with anyone.';

  @override
  String get calSharingAdd => 'Add member';

  @override
  String get calSharingSaved => 'Sharing settings updated';

  @override
  String get calSharingSaveFailed => 'Failed to save sharing settings';

  @override
  String get calSaving => 'Saving…';

  @override
  String get calRemove => 'Remove';

  @override
  String get calImportSection => 'Import';

  @override
  String get calIcsImport => 'ICS import';

  @override
  String get calIcsImportUnavailable =>
      'ICS import is not supported yet: the server interface parameters are not verified yet, so wiring it would create an entry that always fails.';

  @override
  String get calInviteMail => 'Invitation email';

  @override
  String get calInviteMailUnavailable =>
      'Invitation email needs the NAS mail suite (MailPlus or a mail server) plus an administrator account. It is not available here.';

  @override
  String get calLoading => 'Loading…';

  @override
  String get officeLibraryNotConnected => 'Not connected';

  @override
  String get officeLibraryRefresh => 'Refresh';

  @override
  String get officeLibraryRetry => 'Retry';

  @override
  String get officeTemplateLibraryTitle => 'Template library';

  @override
  String officeTemplateLibraryLoadFailed(Object error) {
    return 'Failed to load template library: $error';
  }

  @override
  String get officeTemplateMakeUnopened =>
      'Created, but the server returned no openable node';

  @override
  String get officeThemeTitle => 'Theme';

  @override
  String get officeThemeEntry => 'Theme';

  @override
  String get officeThemeNoObjectId =>
      'Could not resolve the document internal id; request not sent';

  @override
  String officeThemeLoadFailed(Object error) {
    return 'Failed to load themes: $error';
  }

  @override
  String get officeVersionReadOnlyTitle => 'Version history (read-only)';

  @override
  String get officeVersionReadOnlyEntry => 'Version history (read-only)';

  @override
  String officeVersionLoadFailed(Object error) {
    return 'Failed to load version history: $error';
  }

  @override
  String get fsGap3ShareWithMe => 'Shared with me';

  @override
  String get fsGap3NoSharedWithMe => 'Nobody has shared with you yet';

  @override
  String get fsGap3NoSharedWithMeMessage =>
      'Files others share with you will show up here.';

  @override
  String get fsGap3SharedWithMeLoadFailed =>
      'Couldn\'t load items shared with me';

  @override
  String get fsGap3SharedWithMeUnavailable =>
      'This server does not support \"Shared with me\"';

  @override
  String get fsGap3SharedBy => 'From';

  @override
  String get fsGap3StatusExpired => 'Expired';

  @override
  String get fsGap3StatusInactive => 'Not yet active';

  @override
  String get fsGap3StatusOk => 'Active';

  @override
  String get fsGap3TypeSharingLinks => 'Share link';

  @override
  String get fsGap3TypeRequestLink => 'File request';

  @override
  String get fsGap3TypeDocumentLink => 'Document link';

  @override
  String noteBTodoTimeoutChip(Object count) {
    return 'Overdue $count';
  }

  @override
  String get noteBTodoTimeoutEmpty => 'No overdue tasks';

  @override
  String get noteBTodoTimeoutHint => 'Every task is still within its due date';

  @override
  String get noteBShortcut => 'Shortcuts';

  @override
  String get noteBShortcutEmpty => 'No shortcuts yet';

  @override
  String get noteBShortcutEmptyHint =>
      'The server has no shortcuts saved for this account';

  @override
  String get noteBShortcutLoadFailed => 'Failed to load shortcuts';

  @override
  String get noteBShortcutCategoryNotebook => 'Notebook';

  @override
  String get noteBShortcutCategoryNote => 'Note';

  @override
  String get noteBShortcutCategoryTag => 'Tag';

  @override
  String get noteBShortcutCategoryStack => 'Stack';

  @override
  String get noteBShortcutCategorySmart => 'Smart notebook';

  @override
  String get noteBShortcutCategoryOther => 'Other';

  @override
  String get driveWave2QuotaTitle => 'Storage';

  @override
  String get driveWave2QuotaEntry => 'View Drive usage and quota';

  @override
  String get driveWave2QuotaMyDrive => 'My files';

  @override
  String get driveWave2QuotaUnlimited => 'Unlimited';

  @override
  String driveWave2QuotaUsed(Object used) {
    return '$used used';
  }

  @override
  String driveWave2QuotaUsedOf(Object total, Object used) {
    return '$used used of $total';
  }

  @override
  String driveWave2QuotaPercent(Object percent) {
    return '$percent% used';
  }

  @override
  String get driveWave2QuotaEmpty => 'No storage quota information to show';

  @override
  String get driveWave2QuotaLoadFailed => 'Couldn\'t read storage usage';

  @override
  String get driveWave2QuotaRefresh => 'Refresh';

  @override
  String get driveWave2QuotaOtherShares => 'Other folders';

  @override
  String get driveWave2ConvertTitle => 'Convert to Office format';

  @override
  String get driveWave2ConvertEntry => 'Convert to Office format';

  @override
  String get driveWave2ConvertTarget => 'Target format';

  @override
  String get driveWave2ConvertTargetDocx => 'Word document (.docx)';

  @override
  String get driveWave2ConvertSubmit => 'Start conversion';

  @override
  String get driveWave2ConvertSubmitting => 'Submitting conversion…';

  @override
  String get driveWave2ConvertSubmitted =>
      'Conversion submitted and processing in the background. It will appear in the original folder when finished.';

  @override
  String get driveWave2ConvertFinished => 'Conversion finished';

  @override
  String get driveWave2ConvertFailed =>
      'Conversion failed, please try again later';

  @override
  String get driveWave2ConvertUnavailable =>
      'This NAS does not offer the conversion service';

  @override
  String get driveWave2ConvertClose => 'Close';

  @override
  String get calExportSection => 'Export';

  @override
  String get calExportIcs => 'Export as .ics file';

  @override
  String get calExportDone => 'Exported';

  @override
  String get calExportOpen => 'Open / Share';

  @override
  String get calExportFailed => 'Export failed';

  @override
  String get calTodoSearchTitle => 'Search to-dos';

  @override
  String get calTodoSearchHint => 'Enter a keyword';

  @override
  String get calTodoSearchAction => 'Search';

  @override
  String get calTodoSearchPrompt => 'Enter a keyword, then tap Search.';

  @override
  String get calTodoSearchEmpty => 'No matching to-dos found.';

  @override
  String get dsRssTitle => 'RSS feeds';

  @override
  String get dsRssBack => 'Back';

  @override
  String get dsRssUpdateAll => 'Update all';

  @override
  String get dsRssAdd => 'Add feed';

  @override
  String get dsRssAddQueued => 'Feed submitted and being fetched.';

  @override
  String get dsRssAddSubmit => 'Add';

  @override
  String get dsRssAutoDownload => 'Auto-download new items';

  @override
  String get dsRssCancel => 'Cancel';

  @override
  String get dsRssClearItems => 'Clear items';

  @override
  String get dsRssClearItemsConfirm =>
      'Clear the items already fetched for this feed?';

  @override
  String get dsRssConfirm => 'OK';

  @override
  String get dsRssDelete => 'Delete';

  @override
  String get dsRssDeleteConfirm =>
      'Delete this feed? Its items will be removed as well.';

  @override
  String get dsRssDeleteTitle => 'Delete feed';

  @override
  String get dsRssDestHint => 'Leave empty for the default folder';

  @override
  String get dsRssDestLabel => 'Download folder (optional)';

  @override
  String get dsRssEmptyMessage =>
      'Tap the button in the corner to add an RSS address.';

  @override
  String get dsRssEmptyTitle => 'No feeds yet';

  @override
  String get dsRssEndOfItems => 'You\'ve reached the end';

  @override
  String get dsRssErrorTitle => 'Couldn\'t load feeds';

  @override
  String get dsRssFilterAdd => 'New rule';

  @override
  String get dsRssFilterDeleteConfirm => 'Delete this auto-download rule?';

  @override
  String get dsRssFilterDeleteTitle => 'Delete rule';

  @override
  String get dsRssFilterDest => 'Download to';

  @override
  String get dsRssFilterEditTitle => 'Edit rule';

  @override
  String get dsRssFilterMatch => 'Contains';

  @override
  String get dsRssFilterMatched => 'Rule matched';

  @override
  String get dsRssFilterName => 'Rule name';

  @override
  String get dsRssFilterNameRequired => 'Enter a rule name';

  @override
  String get dsRssFilterNotMatch => 'Excludes';

  @override
  String get dsRssFilterNotMatched => 'Rule did not match';

  @override
  String get dsRssFilterRegex => 'Parse as regular expression';

  @override
  String get dsRssFilterSaved => 'Rule saved';

  @override
  String get dsRssFilterTest => 'Test';

  @override
  String get dsRssFilterTestString => 'Sample text';

  @override
  String get dsRssFiltersEmptyMessage =>
      'Rules match new items by keyword and download matches to the chosen folder.';

  @override
  String get dsRssFiltersEmptyTitle => 'No auto-download rules yet';

  @override
  String get dsRssFiltersErrorTitle => 'Couldn\'t load filters';

  @override
  String get dsRssItemNew => 'New';

  @override
  String get dsRssItemUntitled => 'Untitled';

  @override
  String get dsRssItemsEmptyMessage =>
      'This feed has no items yet, try refreshing later.';

  @override
  String get dsRssItemsEmptyTitle => 'No items yet';

  @override
  String get dsRssItemsErrorTitle => 'Couldn\'t load items';

  @override
  String get dsRssLastUpdate => 'Last updated';

  @override
  String get dsRssLoadMore => 'Load more';

  @override
  String get dsRssNeverUpdated => 'Never updated';

  @override
  String get dsRssSave => 'Save';

  @override
  String get dsRssTabFilters => 'Auto-download';

  @override
  String get dsRssTabItems => 'Items';

  @override
  String get dsRssTestRequired => 'Enter text to test';

  @override
  String get dsRssUnavailableApiMissing =>
      'You\'re not connected to a NAS yet.';

  @override
  String get dsRssUnavailableNoPrivilege =>
      'This account is not allowed to use RSS feeds.';

  @override
  String get dsRssUnavailableNotInstalled =>
      'Download Station is not installed on this NAS.';

  @override
  String get dsRssUnavailableOffline =>
      'Network connection failed. Check your network and try again.';

  @override
  String get dsRssUnavailableTitle => 'RSS is unavailable';

  @override
  String get dsRssUntitled => '(Untitled feed)';

  @override
  String get dsRssUpdate => 'Update now';

  @override
  String get dsRssUpdating => 'Updating…';

  @override
  String get dsRssUpdatingHint =>
      'The feed is updating; the list refreshes automatically.';

  @override
  String get dsRssUrlLabel => 'RSS address';

  @override
  String get dsRssUrlRequired => 'Enter an RSS URL';

  @override
  String get photoWave3ExifTitle => 'Capture info';

  @override
  String get photoWave3ExifCamera => 'Camera';

  @override
  String get photoWave3ExifAperture => 'Aperture';

  @override
  String get photoWave3ExifExposureTime => 'Exposure time';

  @override
  String get photoWave3ExifFocalLength => 'Focal length';

  @override
  String get photoWave3ExifIso => 'ISO';

  @override
  String get photoWave3ExifLens => 'Lens';

  @override
  String get photoWave3ExifEmpty => 'This photo has no capture info to show';

  @override
  String get photoWave3ExifFailed => 'Capture info is unavailable right now';

  @override
  String get photoWave3AlbumSettings => 'Album settings';

  @override
  String get photoWave3Cache => 'Album cache';

  @override
  String get photoWave3CacheStatus => 'Cache status';

  @override
  String get photoWave3CacheStatusDone => 'Completed';

  @override
  String get photoWave3CacheStatusProcessing => 'Processing';

  @override
  String get photoWave3CacheStatusUnknown => 'Unknown status';

  @override
  String get photoWave3CacheSize => 'Cache size';

  @override
  String photoWave3CacheSizeValue(Object size) {
    return 'Photo cache on the NAS uses $size';
  }

  @override
  String get photoWave3CacheSizeUnavailable =>
      'Cache size is unavailable right now';

  @override
  String get photoWave3CacheReadOnly =>
      'This version only shows cache status and size; it does not offer clearing.';

  @override
  String get photoWave3AlbumListDisplay => 'Album list preference';

  @override
  String get photoWave3AlbumDisplayAll => 'All albums';

  @override
  String get photoWave3AlbumDisplayMine => 'My albums';

  @override
  String get photoWave3AlbumDisplayUnknown =>
      'The server returned an unrecognized display preference';

  @override
  String get photoWave3Refresh => 'Reload';

  @override
  String chatErrUnknownCode(Object code) {
    return 'Unknown error (code $code)';
  }

  @override
  String get apiDeleteReactionNeedsSticker =>
      'deleteReaction needs stickerId or stickerName';

  @override
  String get dsBtPollingHint => 'Searching sources; results keep coming in…';

  @override
  String get dsBtNoResultsFilteredMessage =>
      'No results from the selected sources. Try another keyword.';

  @override
  String get dsBtSourceUnnamed => 'Unnamed source';

  @override
  String get asRadioTitle => 'Internet radio';

  @override
  String get asRadioSearchTitle => 'Search stations';

  @override
  String get asRadioSearchHint => 'Search internet radio stations';

  @override
  String get asRadioSearchEmpty => 'No matching stations';

  @override
  String get asAddToPlaylist => 'Add to playlist';

  @override
  String get asChoosePlaylist => 'Choose a playlist';

  @override
  String get asChoosePlaylistEmpty =>
      'No playlists yet — create one on the Audio Station home first';

  @override
  String asPlaylistAdded(Object name) {
    return 'Added to \"$name\"';
  }

  @override
  String get asRadioSearchUnsupported =>
      'This NAS does not support station search';

  @override
  String get asRadioEmpty => 'No radio stations yet';

  @override
  String get asRadioLoadFailed => 'Failed to load radio stations';

  @override
  String get asRadioContainerBadge => 'Radio category';

  @override
  String get asRadioStationBadge => 'Station';

  @override
  String get asRadioListNote =>
      'Tap a category to open it, tap a station to play. Some stations need their playlist resolved first, so playback may take a moment.';

  @override
  String get asEmptyComposers => 'No composers yet';

  @override
  String get asEmptyDetailComposers => 'No composers here yet';

  @override
  String asComposerCount(int n) {
    return '$n composers';
  }

  @override
  String get asWebQueueTitle => 'Play queue';

  @override
  String get asWebQueueEmpty => 'The server-side play queue is empty';

  @override
  String get asWebQueueLoadFailed => 'Failed to load the play queue';

  @override
  String get asWebQueueUnsupported =>
      'This NAS\'s Audio Station does not support the play queue';

  @override
  String get asWebQueueShuffleOn => 'Shuffle: on';

  @override
  String get asWebQueueShuffleOff => 'Shuffle: off';

  @override
  String get asWebQueueModeNormal => 'Sequential';

  @override
  String get noteWave4FtsEntry => 'Full-text search';

  @override
  String get noteWave4FtsTitle => 'Full-text search';

  @override
  String get noteWave4FtsHint => 'Search titles, content and attachment text';

  @override
  String get noteWave4FtsPrompt => 'Enter a keyword to search';

  @override
  String get noteWave4FtsEmpty => 'No matching notes';

  @override
  String get noteWave4FtsEmptyHint =>
      'Try another keyword. If the server has full-text search disabled, go back and filter by title.';

  @override
  String get noteWave4FtsFailed => 'Search failed';

  @override
  String get noteWave4ShortcutAdd => 'Add shortcut';

  @override
  String get noteWave4ShortcutRemove => 'Remove shortcut';

  @override
  String get noteWave4ShortcutAdded => 'Added to shortcuts';

  @override
  String get noteWave4ShortcutRemoved => 'Removed from shortcuts';

  @override
  String noteWave4ShortcutFailed(Object error) {
    return 'Shortcut action failed: $error';
  }

  @override
  String noteWave4ShortcutDeleteConfirm(Object name) {
    return 'Remove the shortcut “$name”?';
  }

  @override
  String get noteWave4ShortcutNoTarget => 'This shortcut has no target to open';

  @override
  String get noteWave4NewFromCamera => 'New from camera';

  @override
  String get noteWave4NewFromVideo => 'New from video';

  @override
  String get noteWave4ExportSubmitted =>
      'Export task submitted; generating on the server…';

  @override
  String noteWave4ExportSaved(Object name) {
    return 'Exported to $name';
  }

  @override
  String get noteWave4ExportSubsystem =>
      'This NAS\'s export subsystem reported an error (exports depend on Synology Drive)';

  @override
  String get noteWave5ChangePassword => 'Change password';

  @override
  String get noteWave5ChangePasswordTitle => 'Change note password';

  @override
  String get noteWave5OldPassword => 'Current password';

  @override
  String get noteWave5NewPassword => 'New password';

  @override
  String get noteWave5ConfirmPassword => 'Confirm new password';

  @override
  String get noteWave5ChangePasswordDone => 'Password changed';

  @override
  String noteWave5ChangePasswordFailed(Object error) {
    return 'Couldn\'t change the password: $error';
  }

  @override
  String noteWave5UnlockFailed(Object error) {
    return 'Operation failed: $error';
  }

  @override
  String get noteWave5PasswordMismatch => 'The new passwords don\'t match';

  @override
  String get noteWave5PasswordRequired => 'Enter the current password';

  @override
  String get noteWave5NewPasswordRequired => 'Enter a new password';

  @override
  String get noteWave5PasswordUnchanged =>
      'The new password is the same as the current one';

  @override
  String get noteWave5ChangePasswordNoContent =>
      'The note body hasn\'t synced yet, so the password can\'t be changed right now';

  @override
  String get noteWave5InfoTitle => 'Note info';

  @override
  String get noteWave5InfoSize => 'Size (approximate)';

  @override
  String get noteWave5InfoCreated => 'Created';

  @override
  String get noteWave5InfoModified => 'Modified';

  @override
  String get noteWave5InfoSource => 'Source link';

  @override
  String get noteWave5InfoNotebook => 'Notebook';

  @override
  String get noteWave5InfoTags => 'Tags';

  @override
  String get noteWave5InfoOwner => 'Owner';

  @override
  String get noteWave5InfoEncrypted => 'Encrypted';

  @override
  String get noteWave5InfoUnset => '—';

  @override
  String get noteWave5TopLevel => '(Top level)';

  @override
  String get noteWave5SourceUrlEdit => 'Edit source link';

  @override
  String get noteWave5SourceUrlHint => 'https://…';

  @override
  String get noteWave5SourceUrlSaved => 'Source link saved';

  @override
  String get noteWave5SourceUrlInvalid =>
      'That doesn\'t look like a valid link';

  @override
  String get noteWave5SourceUrlOpenFailed => 'Couldn\'t open this link';

  @override
  String noteWave5SourceUrlOpenFailedDetail(Object error) {
    return 'Couldn\'t open this link: $error';
  }

  @override
  String get noteWave5SourceUrlOpen => 'Open link';

  @override
  String get noteWave5Archive => 'Archive';

  @override
  String get noteWave5Unarchive => 'Unarchive';

  @override
  String get noteWave5Archived => 'Archived';

  @override
  String get noteWave5Unarchived => 'Unarchived';

  @override
  String get noteWave5ShowArchived => 'Show archived notebooks';

  @override
  String noteWave5ArchiveFailed(Object error) {
    return 'Couldn\'t archive: $error';
  }

  @override
  String noteWave5EmptyRecycleDone(Object count) {
    return 'Recycle bin emptied ($count items)';
  }

  @override
  String noteWave5EmptyRecyclePartial(Object ok, Object fail) {
    return 'Emptied $ok, $fail failed';
  }

  @override
  String get noteWave5ViewList => 'List view';

  @override
  String get noteWave5ViewGrid => 'Grid view';

  @override
  String get noteWave5ShowSubTags => 'Show sub-tags';

  @override
  String get noteWave5SubTagOf => 'Parent tag';

  @override
  String get noteWave5TagOperatorOr => 'Any tag (OR)';

  @override
  String get noteWave5TagOperatorAnd => 'All tags (AND)';

  @override
  String get noteWave5FilterByTags => 'Filter by tags';

  @override
  String get noteWave5ClearTagFilter => 'Clear tag filter';

  @override
  String get fsGap4WormSection => 'WriteOnce';

  @override
  String get fsGap4WormMode => 'Mode';

  @override
  String get fsGap4WormAutoLock => 'Auto Lock';

  @override
  String get fsGap4WormEnabled => 'Enabled';

  @override
  String get fsGap4WormNotEnabled => 'Disabled';

  @override
  String get fsGap4WormLockWaitTime => 'Auto Lock Timer';

  @override
  String get fsGap4WormRetention => 'Retention period';

  @override
  String get fsGap4WormLockState => 'Lock state';

  @override
  String get fsGap4WormUnset => '—';

  @override
  String get fsGap4WormSubvolNormal => 'Normal';

  @override
  String get fsGap4WormSubvolEnterprise => 'Enterprise';

  @override
  String get fsGap4WormSubvolCompliance => 'Compliance';

  @override
  String get fsGap4WormSubvolNormalPlus => 'Normal+';

  @override
  String get fsGap4WormStateOpen => 'Open';

  @override
  String get fsGap4WormStateLocked => 'Locked';

  @override
  String get fsGap4WormStateImmutable => 'Immutable';

  @override
  String get fsGap4WormStateAppendOnly => 'Append-only';

  @override
  String get fsGap4WormStateExpired => 'Expired';

  @override
  String get fsGap4WormStateUnknown => 'Unknown';

  @override
  String get fsGap4WormUnitYear => 'year(s)';

  @override
  String get fsGap4WormUnitDay => 'day(s)';

  @override
  String get fsGap4WormUnitHour => 'hour(s)';

  @override
  String get fsGap4WormUnitMinute => 'min(s)';

  @override
  String get fsGap4WormUnitSecond => 'sec(s)';

  @override
  String get fsGap4WormForever => 'Locked forever';

  @override
  String get dsCaptchaTitle => 'Enter captcha';

  @override
  String get dsCaptchaHint =>
      'This NAS requires a captcha to continue this download task. Enter the characters in the image.';

  @override
  String dsCaptchaProgress(Object cur, Object total) {
    return '$cur of $total';
  }

  @override
  String get dsCaptchaImageFailed =>
      'Couldn\'t load the captcha image. Please try again.';

  @override
  String get dsCaptchaRetryImage => 'Reload image';

  @override
  String get dsCaptchaCodeLabel => 'Captcha';

  @override
  String get dsCaptchaSubmit => 'Submit';

  @override
  String get dsCaptchaSkip => 'Skip this task';

  @override
  String get dsCaptchaCodeRequired => 'Enter the captcha';

  @override
  String get dsCaptchaAccepted => 'Captcha submitted';

  @override
  String get dsCaptchaLoadFailed => 'Couldn\'t read captcha tasks';

  @override
  String get dsCaptchaNoneTitle => 'No tasks need a captcha';

  @override
  String get dsCaptchaNoneMessage =>
      'All tasks that needed a captcha have been handled.';

  @override
  String dsCaptchaBanner(Object count) {
    return '$count tasks need a captcha to continue';
  }

  @override
  String get dsCaptchaEnter => 'Enter captcha';

  @override
  String get dsErrWrongCaptcha => 'Incorrect captcha. Please try again.';

  @override
  String get dsErrEmuleEd2kNotConnected =>
      'eMule is not connected to an ED2K server.';

  @override
  String get dsErrEmuleKadNotConnected =>
      'eMule is not connected to the Kad network.';

  @override
  String get dsErrListNotFound =>
      'The file list has expired. Please add this task again.';

  @override
  String get photoRecentTitle => 'Recently Added';

  @override
  String get photoRecentEntry =>
      'Browse photos and videos by when they were added';

  @override
  String get photoRecentEmptyTitle => 'Nothing recently added yet';

  @override
  String get photoRecentEmptyMessage =>
      'Once indexing finishes on the NAS, recently added photos will appear here.';

  @override
  String get driveWave2FolderItemCount => 'Item count';

  @override
  String get driveWave2FolderItemCountUnavailable => 'Temporarily unavailable';

  @override
  String get driveWave2RequestAccess => 'Request access';

  @override
  String get driveWave2RequestAccessConfirmTitle => 'Request access';

  @override
  String get driveWave2RequestAccessConfirmMessage =>
      'Send an access request to the owner of this item?';

  @override
  String get driveWave2RequestAccessCancel => 'Cancel';

  @override
  String get driveWave2RequestAccessConfirm => 'Send request';

  @override
  String get driveWave2RequestAccessSent => 'Access request sent';

  @override
  String driveWave2FolderItemCountValue(int count) {
    return '$count items';
  }

  @override
  String driveWave2RequestAccessFailed(String error) {
    return 'Request failed: $error';
  }

  @override
  String get noteN4DeleteGps => 'Delete GPS Info';

  @override
  String get noteN4DeleteGpsMessage => 'Deleted GPS information successfully';

  @override
  String get noteN4Location => 'Location';

  @override
  String get noteN4LocationNameHint => 'Place name';

  @override
  String get noteN4LocationPermissionDenied =>
      'No location permission; cannot get the current location';

  @override
  String get noteN4LocationSaved => 'Location saved';

  @override
  String get noteN4LocationUnavailable =>
      'Cannot get the current location right now';

  @override
  String get noteN4LocationUnsupported =>
      'This device does not support location';

  @override
  String get noteN4NoSearchResult => 'No matching items found.';

  @override
  String noteN4SaveFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get noteN4SearchNeedsCenter =>
      'Set or get a location first to search nearby places';

  @override
  String get noteN4SearchPlace => 'Search place';

  @override
  String get noteN4SearchPlaceHint => 'Search for a place or address';

  @override
  String get noteN4Searching => 'Searching…';

  @override
  String get noteN4SetLocation => 'Set location';

  @override
  String get noteN4UseCurrentLocation => 'Use current location';

  @override
  String get noteN4UseThisPlace => 'Use this one';

  @override
  String get fsTaskClearConfirmFinished =>
      'Finished tasks will be cleared. Are you sure you want to continue?';

  @override
  String get officeSlidesDeckEmpty =>
      'This presentation has no slides to show.';

  @override
  String get officeSlidesDeckNotes => 'Notes';

  @override
  String get officeSlidesDeckNoNotes => 'No notes on this slide';

  @override
  String get officeSlidesDeckFullscreen => 'Full screen';

  @override
  String get officeSlidesDeckExitFullscreen => 'Exit full screen';

  @override
  String get officeSlidesDeckInfoTitle => 'Presentation info';

  @override
  String get officeSlidesDeckVectorNote =>
      'SVG vector graphics are drawn by the built-in renderer; EMF / WMF and similar formats are not shown yet.';

  @override
  String get officeSlidesDeckUnsupported =>
      'This slide contains objects that are not supported yet';

  @override
  String get officeSlidesDeckBlank => 'This slide has nothing to show';

  @override
  String get officeSlidesDeckImageFailed => 'This image could not be displayed';

  @override
  String get officeSlidesDeckFallbackNote =>
      'The layout of this presentation could not be read, so the text is shown instead.';

  @override
  String officeSlidesDeckInfoSize(String w, String h, String ratio) {
    return 'Canvas $w×$h ($ratio)';
  }

  @override
  String officeSlidesDeckInfoPages(String n) {
    return '$n slides';
  }

  @override
  String officeSlidesDeckInfoLayouts(String n) {
    return '$n layouts';
  }

  @override
  String officeSlidesDeckUnsupportedSummary(String n) {
    return '$n objects (tables/charts/diagrams) are not supported yet.';
  }

  @override
  String get officeSheetEmptyHint =>
      'Try opening it again, or open this file in the official Synology Drive app.';

  @override
  String get officeSheetFitWidth => 'Fit width';

  @override
  String get officeSheetZoomOut => 'Zoom out';

  @override
  String get officeSheetZoomIn => 'Zoom in';

  @override
  String get officeSheetChart => 'Chart';

  @override
  String get officeSheetChartUnavailable =>
      'This chart cannot be displayed yet';

  @override
  String officeSheetRenderTruncated(String rows, String cols) {
    return 'Showing the first $rows rows × $cols columns (the sheet is larger; only the visible range is rendered).';
  }

  @override
  String get officeSheetFallbackNotOoxml =>
      'This file is not in the standard spreadsheet format; it was opened in compatibility mode, so some layout may be incomplete.';

  @override
  String get officeSheetFallbackParseFailed =>
      'The standard spreadsheet layout could not be parsed; it was opened in compatibility mode, so some layout may be incomplete.';

  @override
  String get officeSheetFallbackEmpty =>
      'The file bytes could not be retrieved; it was opened in compatibility mode, so some layout may be incomplete.';

  @override
  String get noteMailSendToEmail => 'Email note';

  @override
  String get noteMailShareOut => 'Share to other apps';

  @override
  String get noteMailUnavailable => 'No email app available.';

  @override
  String get driveG4ComputersTitle => 'Computers';

  @override
  String get driveG4ComputersEntry => 'Computers';

  @override
  String get driveG4ComputersEntrySubtitle =>
      'See computers signed in to the same account and their synced folders';

  @override
  String get driveG4ComputersEmpty => 'No connected computer yet';

  @override
  String get driveG4ComputersEmptyBody =>
      'Install the Synology Drive client on a computer and sign in with the same account to see it here.';

  @override
  String get driveG4ComputersLoadFailed => 'Could not load the computer list';

  @override
  String driveG4ComputersCount(String count) {
    return '$count computers';
  }

  @override
  String get driveG4ComputersDevice => 'Device';

  @override
  String get driveG4LocalFilesTitle => 'Local files';

  @override
  String get driveG4LocalFilesEntry => 'Local files';

  @override
  String get driveG4LocalFilesEntrySubtitle =>
      'Upload files from this device to Drive';

  @override
  String get driveG4LocalFilesEmpty => 'This folder is empty';

  @override
  String get driveG4LocalFilesEmptyBody => 'Open another folder, or refresh.';

  @override
  String get driveG4LocalFilesUnavailable =>
      'Local files are not browsable on this device';

  @override
  String get driveG4LocalFilesUnavailableBody =>
      'Only Android phones can browse local storage; this platform is not supported yet.';

  @override
  String get driveG4LocalFilesUpload => 'Upload to Drive';

  @override
  String driveG4LocalFilesUploading(String name) {
    return 'Uploading $name';
  }

  @override
  String driveG4LocalFilesUploaded(String name) {
    return 'Uploaded $name';
  }

  @override
  String driveG4LocalFilesUploadFailed(String error) {
    return 'Upload failed: $error';
  }

  @override
  String get driveG4LocalFilesNotConnected =>
      'Not connected to the NAS; connect first.';

  @override
  String driveG4LocalFilesTarget(String path) {
    return 'Upload to $path';
  }

  @override
  String get driveG4ArchiveTitle => 'Compress and download';

  @override
  String get driveG4ArchiveDownload => 'Download as archive';

  @override
  String get driveG4ArchiveDownloading => 'Packing…';

  @override
  String get driveG4ArchiveNameLabel => 'Archive name';

  @override
  String driveG4ArchiveSaveFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String driveG4ArchiveSaved(String name) {
    return 'Saved $name';
  }

  @override
  String get driveG4ArchiveShare => 'Pack and share';

  @override
  String driveG4ArchiveShareFailed(String error) {
    return 'Share failed: $error';
  }

  @override
  String get driveG4ArchiveNoHandler => 'No app can receive this share';

  @override
  String get driveG4ArchiveNoSelection => 'Select files to pack first';

  @override
  String get driveG4SendCopy => 'Send a copy';

  @override
  String driveG4SendCopySaved(String name) {
    return 'Sent $name';
  }

  @override
  String get driveG4PasswordVerifyTitle => 'This share is password-protected';

  @override
  String get driveG4PasswordVerifyHint => 'Enter the sharing password';

  @override
  String get driveG4PasswordVerifyAction => 'Verify';

  @override
  String get driveG4PasswordVerifyOk => 'Password accepted';

  @override
  String get driveG4PasswordVerifyBad => 'Wrong password, try again';

  @override
  String get driveG4PasswordVerifyEmpty => 'Enter the password first';

  @override
  String get fsG4ToolsTitle => 'File tools';

  @override
  String get fsG4ToolsSection => 'More';

  @override
  String get fsG4VolumeFirstTitle => 'This is volume 1 of a split archive';

  @override
  String fsG4VolumeFirstBody(String kind) {
    return '$kind: the NAS reads the remaining volumes in the same folder automatically.';
  }

  @override
  String fsG4VolumeLaterTitle(String n) {
    return 'This is volume $n; it cannot be extracted on its own';
  }

  @override
  String fsG4VolumeLaterBody(String kind, String first) {
    return '$kind: choose volume 1 (“$first”) instead.';
  }

  @override
  String get fsG4VolumeKindRarPart => 'RAR volumes (.partN.rar)';

  @override
  String get fsG4VolumeKindRarOld => 'Legacy RAR volumes (.rNN)';

  @override
  String get fsG4VolumeKindNumeric => 'Numbered volumes (.001/.002…)';

  @override
  String get fsG4VolumeKindZip => 'ZIP volumes (.z01/.z02…)';

  @override
  String get fsG4UsbTitle => 'External devices';

  @override
  String get fsG4UsbEntry =>
      'View USB drives attached to the NAS and eject them safely (admin only)';

  @override
  String get fsG4UsbEmpty => 'No USB device detected';

  @override
  String get fsG4UsbEmptyBody => 'Plug a USB drive into the NAS, then refresh.';

  @override
  String get fsG4UsbNoDeviceTitle =>
      'The server returned no external devices (404)';

  @override
  String get fsG4UsbNoDeviceBody =>
      'This does not mean there is no USB drive on the NAS: on this device the list still returned 404 while the drive was mounted and visible in Files. In DSM the list is usually admin-only - to use the drive, open it in Files.';

  @override
  String get fsG4UsbLoadFailed => 'Could not load external devices';

  @override
  String get fsG4UsbEject => 'Eject';

  @override
  String get fsG4UsbEjectConfirmTitle => 'Eject this device?';

  @override
  String fsG4UsbEjectConfirmBody(String name) {
    return 'This stops all reads and writes to “$name”. Ongoing transfers will fail, so make sure no task is running.';
  }

  @override
  String get fsG4UsbEjectDone => 'Device ejected';

  @override
  String fsG4UsbEjectFailed(String error) {
    return 'Eject failed: $error';
  }

  @override
  String get fsG4UsbPartition => 'Partition';

  @override
  String fsG4UsbStatus(String status) {
    return 'Status: $status';
  }

  @override
  String fsG4UsbUsedOfTotal(String used, String total) {
    return '$used used of $total';
  }

  @override
  String get fsG4OfflineTitle => 'Offline files';

  @override
  String get fsG4OfflineEntry => 'Offline files';

  @override
  String get fsG4OfflineEntrySubtitle =>
      'Files you marked as available offline (cached on this device, uses local space)';

  @override
  String get fsG4OfflineEmpty => 'No offline files yet';

  @override
  String get fsG4OfflineEmptyBody =>
      'Choose “Add to offline files” in a file’s menu, then find it here.';

  @override
  String get fsG4OfflinePin => 'Add to offline files';

  @override
  String get fsG4OfflineUnpin => 'Remove from offline files';

  @override
  String get fsG4OfflinePinned =>
      'Added to offline files, caching to this device…';

  @override
  String get fsG4OfflineUnpinned => 'Removed from offline files';

  @override
  String get fsG4OfflineRemove => 'Remove offline';

  @override
  String get fsG4OfflineOnlyFiles => 'Only files can be made available offline';

  @override
  String fsG4OfflineCount(String count) {
    return '$count items';
  }

  @override
  String fsG4OfflineTotal(String size) {
    return '$size total';
  }

  @override
  String fsG4OfflineTotalPartial(String size, String count) {
    return '$size total ($count items of unknown size)';
  }

  @override
  String fsG4OfflineCached(String size) {
    return 'Cached on this device ($size)';
  }

  @override
  String fsG4OfflineCacheFailed(String reason) {
    return 'Added, but caching failed: $reason';
  }

  @override
  String get fsG4OfflineCacheNow => 'Cache on this device';

  @override
  String get fsG4OfflineNotCached => 'Not cached';

  @override
  String get fsWebDavTitle => 'WebDAV connection';

  @override
  String get fsWebDavEntry =>
      'Connect to the NAS over WebDAV and browse folders (read-only; deprecated by Synology since DSM 7)';

  @override
  String get fsWebDavEntryDescription =>
      'Connect to the NAS over WebDAV (the official DS file app\'s other transport path)';

  @override
  String get fsWebDavHost => 'Host';

  @override
  String get fsWebDavHostHint => 'NAS IP or domain name';

  @override
  String get fsWebDavPort => 'Port';

  @override
  String get fsWebDavAccount => 'Account';

  @override
  String get fsWebDavPassword => 'Password';

  @override
  String get fsWebDavSecure => 'HTTPS';

  @override
  String get fsWebDavSecureHint => 'the https port is usually 5006';

  @override
  String get fsWebDavConnect => 'Connect';

  @override
  String get fsWebDavConnecting => 'Connecting…';

  @override
  String get fsWebDavMissingHost => 'Enter a host address (IP or domain name)';

  @override
  String get fsWebDavDeprecated =>
      'The official DS file app has marked WebDAV mode as deprecated since DSM 7 (WebDavConnectionManager: DEPRECATED_DSM_VERSION = 7). It still connects, but it is no longer a supported path.';

  @override
  String get fsWebDavReadOnly =>
      'WebDAV is read-only here: you can browse folders and download files. Upload, new folder, delete and rename are not supported yet.';

  @override
  String get fsWebDavEmpty => 'This folder is empty';

  @override
  String get fsWebDavEmptyBody =>
      'The server responded, but the folder has no entries.';

  @override
  String fsWebDavError(String error) {
    return 'Connection failed: $error';
  }

  @override
  String fsWebDavCapability(String dav, String allow) {
    return 'DAV: $dav · supports: $allow';
  }

  @override
  String fsWebDavPath(String path) {
    return 'Current path: $path';
  }

  @override
  String get fsWebDavUp => 'Up one level';

  @override
  String get fsWebDavNotConnected =>
      'Not connected to a NAS, so the address cannot be prefilled';

  @override
  String get fsWebDavServer => 'Server';

  @override
  String get officeSlidesFallbackPlain => 'Open as text';

  @override
  String get photoGridDensity => 'Thumbnail density';

  @override
  String get photoGridDensityLarge => 'Large';

  @override
  String get photoGridDensityMedium => 'Medium';

  @override
  String get photoGridDensitySmall => 'Small';

  @override
  String get photoGridDensityTiny => 'Dense';

  @override
  String photoGridDensityApplied(String label) {
    return 'Thumbnail density: $label';
  }

  @override
  String get photoHeicPreviewTitle => 'This HEIC photo has no preview yet';

  @override
  String get photoHeicPreviewBody =>
      'HEIC/HEIF needs a JPEG preview generated by Image Assistant on the NAS before it can be shown in the app.';

  @override
  String get photoHeicPreviewAction => 'Generate preview on NAS';

  @override
  String get photoHeicPreviewConfirmTitle => 'Generate preview on the NAS?';

  @override
  String get photoHeicPreviewConfirmBody =>
      'This regenerates preview images on the NAS and may take some time and CPU.';

  @override
  String get photoHeicPreviewRequested =>
      'Preview generation requested; come back later to refresh.';

  @override
  String photoHeicPreviewFailed(String reason) {
    return 'Request failed: $reason';
  }

  @override
  String photoHeicRegenerating(String count) {
    return 'NAS is generating $count previews';
  }

  @override
  String get photoFormatUnsupportedRaw =>
      'This RAW/DNG file cannot be displayed in the app yet';

  @override
  String get photoFormatUnsupportedAvif =>
      'This AVIF file cannot be displayed in the app yet';

  @override
  String get photoFormatUnsupportedGeneric =>
      'This format cannot be displayed in the app yet; download it and open it with another app';

  @override
  String get photoFormatUnsupportedBody =>
      'Same as the official app: RAW / DNG / AVIF are not decoded in the app. Download and open with another app, or enable Image Assistant on the NAS.';

  @override
  String get photoFormatUnsupportedBadge => 'Format not supported';

  @override
  String get photoSearchHistoryTitle => 'Recent searches';

  @override
  String get photoSearchHistoryClear => 'Clear history';

  @override
  String get photoSearchHistoryCleared => 'Search history cleared';

  @override
  String get photoGlobalSearchGroup => 'Photos';

  @override
  String photoGlobalSearchFailed(String reason) {
    return 'Photo search failed: $reason';
  }

  @override
  String photoGlobalSearchCount(String count) {
    return '$count photos';
  }

  @override
  String photoDeleteUndoPending(String seconds, String count) {
    return '$count item(s) will be deleted in ${seconds}s';
  }

  @override
  String get photoDeleteUndoAction => 'Undo';

  @override
  String get photoDeleteUndone => 'Undone — nothing was deleted';

  @override
  String get photoPlaybackSettings => 'Playback settings';

  @override
  String get photoPlaybackHttp => 'Play over HTTP';

  @override
  String get photoPlaybackHttpDesc =>
      'When a self-signed certificate blocks video playback, fetch the stream over a plain HTTP URL instead.';

  @override
  String get photoPlaybackHttpPort => 'HTTP port';

  @override
  String get photoPlaybackPortInvalid => 'Incorrect port (must be 1–65535)';

  @override
  String get photoPlaybackCert => 'Ignore certificate errors';

  @override
  String get photoPlaybackCertDesc =>
      'Ignore certificate validation errors with self-signed certificates (the app fetches the video itself before playing).';

  @override
  String get photoSlideshow => 'Slideshow';

  @override
  String get photoSlideshowSettings => 'Slideshow settings';

  @override
  String get photoSlideshowSpeed => 'Speed';

  @override
  String get photoSlideshowOrder => 'Play order';

  @override
  String get photoSlideshowShuffle => 'Shuffle';

  @override
  String get photoSlideshowSequential => 'In order';

  @override
  String get photoSlideshowStart => 'Start slideshow';

  @override
  String get photoSlideshowStop => 'Stop slideshow';

  @override
  String get photoSlideshowNoPhotos => 'No playable photos in this list';

  @override
  String photoSlideshowSeconds(String seconds) {
    return '${seconds}s';
  }

  @override
  String photoSlideshowInterval(String seconds, String order) {
    return 'Every ${seconds}s · $order';
  }

  @override
  String get photoSlideshowStarted => 'Slideshow playing';

  @override
  String get officeViewerSlidesImage => 'Image';

  @override
  String get driveG6ConnectionsTitle => 'Connected devices';

  @override
  String get driveG6ConnectionsEntry => 'Connected devices';

  @override
  String get driveG6ConnectionsEntryHint =>
      'See which clients and devices are connected to Drive on this NAS';

  @override
  String get driveG6ConnectionsSubtitle =>
      'Devices connected to this NAS with a Drive client';

  @override
  String get driveG6ConnectionsEmptyTitle => 'No connected devices';

  @override
  String get driveG6ConnectionsEmptyBody =>
      'Once you sign in to this NAS from Synology Drive on a computer or phone, that device will be listed here.';

  @override
  String get driveG6ConnectionsLoadFailed => 'Could not load connected devices';

  @override
  String get driveG6ConnectionStatusConnected => 'Connected';

  @override
  String get driveG6ConnectionStatusOffline => 'Offline';

  @override
  String get driveG6ConnectionUnknownDevice => 'Unknown device';

  @override
  String get driveG6FileRequestDisabled =>
      'File requests are turned off on this NAS. Enable them in the Drive admin console of DSM, then try again.';

  @override
  String driveG6ActionFailed(String error) {
    return 'Action failed: $error';
  }

  @override
  String get driveG6GenericFailure => 'Action failed. Please try again later.';

  @override
  String get photoG6TasksTitle => 'Background tasks';

  @override
  String get photoG6TasksEntry => 'Background tasks';

  @override
  String get photoG6TasksEntryHint =>
      'See copy / move and other tasks running in Photos';

  @override
  String get photoG6TasksEmptyTitle => 'No background tasks in progress';

  @override
  String get photoG6TasksEmptyBody =>
      'Copy / move and other tasks started in Photos will show their progress here.';

  @override
  String get photoG6TaskOperationCopy => 'Copy';

  @override
  String get photoG6TaskOperationMove => 'Move';

  @override
  String get photoG6TaskStatusWaiting => 'Waiting';

  @override
  String get photoG6TaskStatusProcessing => 'In progress';

  @override
  String get photoG6TaskStatusAborting => 'Aborting';

  @override
  String get photoG6TaskStatusDone => 'Done';

  @override
  String photoG6TaskProgress(String done, String total) {
    return '$done/$total';
  }

  @override
  String photoG6TaskErrors(String count) {
    return '$count failed';
  }

  @override
  String get photoG6TaskUnknownType => 'Photo task';

  @override
  String get photoG6MigrationTitle => 'Migration status';

  @override
  String get photoG6MigrationEntry => 'Migration status';

  @override
  String get photoG6MigrationEntryHint =>
      'Photo Station / Moments to Synology Photos migration progress';

  @override
  String get photoG6MigrationStatusDone => 'Migration completed';

  @override
  String get photoG6MigrationStatusRunning => 'Migrating';

  @override
  String get photoG6MigrationStatusFailed =>
      'Migration failed. Check the details in Synology Photos on your NAS.';

  @override
  String get photoG6MigrationStatusUnknown =>
      'Migration status is unavailable right now. Please try again later.';

  @override
  String get photoG6MigrationStagePhotoStation =>
      'Migrating Photo Station photos';

  @override
  String get photoG6MigrationStageMomentsPersonal =>
      'Migrating Moments personal photos';

  @override
  String get photoG6MigrationStageBoth =>
      'Migrating Photo Station and Moments photos';

  @override
  String photoG6MigrationProgress(String current, String total) {
    return 'Step $current of $total';
  }

  @override
  String get photoG6MigrationIdleTitle => 'No migration in progress';

  @override
  String get photoG6MigrationIdleBody =>
      'Once Photo Station / Moments photos finish migrating, the result appears here.';

  @override
  String get photoFreeUpTitle => 'Free Up Space';

  @override
  String get photoFreeUpEntry => 'Free Up Space';

  @override
  String get photoFreeUpEntryHint =>
      'Delete local copies of photos already backed up to your NAS to free up phone storage. Photos without a backup are never touched.';

  @override
  String get photoFreeUpExplainTitle => 'Only backed-up photos are deleted';

  @override
  String get photoFreeUpExplainBody =>
      'Each photo is checked one by one: only photos already backed up on your NAS enter the removable list, and photos without a backup are always kept. Your system shows a confirmation dialog before anything is deleted, and you can cancel at any time. Your NAS copies are not affected.';

  @override
  String photoFreeUpReclaimable(String size) {
    return '$size can be freed';
  }

  @override
  String photoFreeUpCounts(String backedUp, String kept) {
    return '$backedUp backed up · $kept without a backup will not be deleted';
  }

  @override
  String get photoFreeUpRescan => 'Check again';

  @override
  String get photoFreeUpScanning => 'Checking your photos against NAS backups…';

  @override
  String photoFreeUpProgress(String done, String total) {
    return 'Processed $done/$total';
  }

  @override
  String get photoFreeUpStart => 'Free Up Space';

  @override
  String get photoFreeUpCancelled => 'Cancelled — no photos were deleted';

  @override
  String photoFreeUpDeleted(String size, String count) {
    return 'Freed $size ($count photos)';
  }

  @override
  String photoFreeUpDeletedSomeFailed(String count) {
    return '$count photos could not be deleted; the rest were freed';
  }

  @override
  String get photoFreeUpFailed =>
      'Deletion did not complete — no photos were deleted. Please try again later.';

  @override
  String get photoFreeUpNothingToFree => 'Nothing to free up right now';

  @override
  String get photoFreeUpCacheCleared =>
      'Temporary files left by uploads were cleaned up';

  @override
  String get photoFreeUpNoPermissionTitle =>
      'Can\'t read your photos, so backups can\'t be checked';

  @override
  String get photoFreeUpNotConnected =>
      'The NAS is not connected, so we can\'t check which photos are already backed up. Connect and check again.';

  @override
  String get photoFreeUpNoTarget =>
      'No backup target is set, so only this device\'s backup records can be used';

  @override
  String get photoFreeUpNothingTitle => 'No photos to free up';

  @override
  String get photoFreeUpNothingBody =>
      'None of your photos have been backed up yet, or the check is complete and there are no extra local copies.';

  @override
  String get photoFreeUpUnsupportedTitle =>
      'This device won\'t let the app delete photos';

  @override
  String get photoFreeUpUnsupportedBody =>
      'No deletion capability is available here. You can clean up manually in system settings; your NAS backups are intact and nothing was deleted.';

  @override
  String get photoFreeUpSettingsOnlyTitle =>
      'You\'ll need to clean up manually on this device';

  @override
  String get photoFreeUpSettingsOnlyBody =>
      'This system version can\'t ask for a delete confirmation from the app. Please clean up manually in system settings → app storage, or delete the photos listed above in your system gallery. Your NAS backups are intact.';

  @override
  String get photoFreeUpOpenSettings => 'Clean up in system settings';

  @override
  String get photoFreeUpSettingsFailed =>
      'Could not open system settings. Please go to Settings → Apps → Storage and clean up manually.';

  @override
  String get photoFreeUpItemReasonLedger =>
      'Backed up (this device\'s backup record)';

  @override
  String get photoFreeUpItemReasonRemote =>
      'Backed up (same file already on NAS)';

  @override
  String get photoFreeUpItemStatePending => 'To delete';

  @override
  String get photoFreeUpItemStateDeleted => 'Deleted';

  @override
  String get photoFreeUpItemStateKept => 'Kept';

  @override
  String get widgetPlaceholderNotLoggedIn =>
      'Open the app and sign in to see your photos, notes and to-dos here';

  @override
  String get widgetPlaceholderNotConnected =>
      'Not connected to the NAS yet; connect to see your content here';

  @override
  String get widgetPlaceholderNoPhotos => 'No photos yet';

  @override
  String get widgetPlaceholderNoNotes => 'No notes yet — tap to create one';

  @override
  String get widgetPlaceholderNoTodos => 'No open to-dos';

  @override
  String get widgetTodosTitle => 'To-dos';

  @override
  String get widgetNewNote => 'New note';

  @override
  String get noteAdvSearchEntry => 'Advanced search';

  @override
  String get noteAdvSearchTitle => 'Advanced search';

  @override
  String get noteAdvSearchKeyword => 'Keyword';

  @override
  String get noteAdvSearchKeywordHint =>
      'Search titles, body text and attachment text';

  @override
  String get noteAdvSearchTitleLabel => 'Title contains';

  @override
  String get noteAdvSearchTitleHint => 'For example: weekly report';

  @override
  String get noteAdvSearchTags => 'Tags';

  @override
  String get noteAdvSearchTagsAny => 'Any';

  @override
  String get noteAdvSearchTagAnd => 'Contains all selected tags';

  @override
  String get noteAdvSearchTagOr => 'Contains any selected tag';

  @override
  String get noteAdvSearchIncludeSubTags => 'Include sub-tags';

  @override
  String get noteAdvSearchIncludeSubTagsHint =>
      'When off, only notes tagged with exactly the selected tags are shown';

  @override
  String get noteAdvSearchExcludeTags => 'Exclude tags';

  @override
  String get noteAdvSearchExcludeTagsHint =>
      'Excluded tags and their sub-tags are both excluded';

  @override
  String get noteAdvSearchNotebooks => 'Notebooks';

  @override
  String get noteAdvSearchNotebooksAny => 'All notebooks';

  @override
  String get noteAdvSearchTimeModified => 'Modified';

  @override
  String get noteAdvSearchTimeCreated => 'Created';

  @override
  String get noteAdvSearchDateFrom => 'From';

  @override
  String get noteAdvSearchDateTo => 'To';

  @override
  String get noteAdvSearchDateInvalid =>
      'The start date cannot be later than the end date';

  @override
  String get noteAdvSearchRun => 'Search';

  @override
  String get noteAdvSearchClear => 'Clear conditions';

  @override
  String get noteAdvSearchPrompt => 'Set a condition to start searching';

  @override
  String get noteAdvSearchPromptHint => 'Set at least one condition';

  @override
  String get noteAdvSearchEmpty => 'No notes match these conditions';

  @override
  String get noteAdvSearchEmptyHint =>
      'Try another keyword or loosen the conditions';

  @override
  String get noteAdvSearchFailed => 'Search failed';

  @override
  String noteAdvSearchSelectedCount(Object count) {
    return '$count selected';
  }

  @override
  String noteAdvSearchResultsCount(Object count) {
    return '$count results';
  }

  @override
  String get driveD8CollectionTitle => 'Collections';

  @override
  String get driveD8CollectionEmptyTitle => 'No collections yet';

  @override
  String driveD8CollectionCount(String count) {
    return '$count collections';
  }

  @override
  String get driveD8CollectionLoadFailed =>
      'Collections are unavailable right now';

  @override
  String get driveD8CollectionEmptyBody =>
      'Collections gather files scattered across folders into four kinds: photos, documents, music and videos.';

  @override
  String get driveD8CollectionCreate => 'New collection';

  @override
  String driveD8CollectionCreated(String name) {
    return 'Created \"$name\"';
  }

  @override
  String driveD8CollectionActionFailed(String error) {
    return 'Something went wrong: $error';
  }

  @override
  String get driveD8CollectionAll => 'All';

  @override
  String get driveD8CollectionRename => 'Rename / change colour';

  @override
  String get driveD8CollectionDelete => 'Delete collection';

  @override
  String driveD8CollectionRenamed(String name) {
    return 'Renamed to \"$name\"';
  }

  @override
  String get driveD8CollectionDeleteConfirm => 'Delete this collection?';

  @override
  String driveD8CollectionDeleteBody(String name) {
    return '\"$name\" will be deleted. The files inside it are not deleted.';
  }

  @override
  String get driveD8CollectionDeleted => 'Collection deleted';

  @override
  String get driveD8CollectionFilesLoadFailed =>
      'Files in this collection are unavailable right now';

  @override
  String get driveD8CollectionFilesEmptyTitle => 'This collection is empty';

  @override
  String get driveD8CollectionFilesEmptyBody =>
      'Pick \"Add to collection\" in a file list to put files in here.';

  @override
  String get driveD8CollectionRemoveFromCollection => 'Remove from collection';

  @override
  String get driveD8CollectionRemoveConfirm => 'Remove from this collection?';

  @override
  String driveD8CollectionRemoveBody(String name) {
    return '\"$name\" will be removed from the collection. The file itself is not deleted.';
  }

  @override
  String get driveD8CollectionRemoved => 'Removed from the collection';

  @override
  String get driveD8CollectionRenameTitle => 'Rename collection';

  @override
  String get driveD8CollectionCreateTitle => 'New collection';

  @override
  String get driveD8CollectionNameHint => 'Collection name';

  @override
  String get driveD8CollectionTypePhoto => 'Photo collection';

  @override
  String get driveD8CollectionTypeDocument => 'Document collection';

  @override
  String get driveD8CollectionTypeAudio => 'Music collection';

  @override
  String get driveD8CollectionTypeVideo => 'Video collection';

  @override
  String get driveD8CollectionEntry => 'Collections';

  @override
  String get driveD8CollectionEntryHint =>
      'Gather files from different folders into photo, document, music and video collections';

  @override
  String get driveD12TeamTrashEntry => 'Team folder recycle bin';

  @override
  String get driveD12TeamTrashPickFolder =>
      'Pick a team folder to view and restore files deleted inside it';

  @override
  String get driveD12TeamTrashTitle => 'Team folder recycle bin';

  @override
  String get driveD12TeamTrashNoTeamFolders => 'No team folders';

  @override
  String driveD12TeamTrashCount(String count) {
    return '$count team folders';
  }

  @override
  String get driveD12TeamTrashLoadFailed =>
      'Team folders are unavailable right now';

  @override
  String get driveD12TeamTrashNoTeamFoldersBody =>
      'This account has no team folders yet, so there is no team folder recycle bin to show.';

  @override
  String get driveD12TeamTrashEmptyTitle => 'The recycle bin is empty';

  @override
  String driveD12TeamTrashItemCount(String count) {
    return '$count deleted items';
  }

  @override
  String get driveD12TeamTrashNoEmptyAction =>
      'Team folder recycle bins cannot be emptied (same as the official app); restore or delete items one by one.';

  @override
  String get driveD12TeamTrashEmptyBody =>
      'No deleted files in this team folder.';

  @override
  String get driveD8CollectionAddToCollection => 'Add to collection';

  @override
  String get photoMediaLiveBadge => 'Live Photo';

  @override
  String get photoMediaMotionBadge => 'Motion Photo';

  @override
  String get photoMediaLivePlayTooltip => 'Play Live Photo';

  @override
  String get photoMediaLiveStopTooltip => 'Stop Live Photo';

  @override
  String get photoMediaLiveUnavailable =>
      'This Live Photo video is unavailable (the server did not return a playable video).';

  @override
  String get photoMediaPanoPhotoHint => 'Tap and drag to view the 360 photo.';

  @override
  String get photoMediaPanoPhotoFailed => 'Unable to load the 360 photo.';

  @override
  String get photoMediaPanoResetView => 'Reset view';

  @override
  String get photoMediaPanoVideoFlatNotice =>
      'This is a 360 video. This player does not support spherical view yet, so it plays as a regular flat video.';

  @override
  String get photoMediaEditDateTitle => 'Edit date and time';

  @override
  String get photoMediaEditDateMenuAction => 'Edit date and time';

  @override
  String get photoMediaEditDateAction => 'Save';

  @override
  String get photoMediaEditDateField => 'Date';

  @override
  String get photoMediaEditTimeField => 'Time';

  @override
  String get photoMediaEditDateConfirmTitle => 'Change capture time?';

  @override
  String photoMediaEditDateConfirmBody(String from, String to) {
    return 'This changes the photo’s capture time from $from to $to. The original file is not re-encoded, but the timeline and sorting in Photos will change.';
  }

  @override
  String get photoMediaEditDateSaved => 'Capture time updated.';

  @override
  String photoMediaEditDateFailed(String error) {
    return 'Failed to change capture time: $error';
  }

  @override
  String get photoMediaEditDateInvalid =>
      'The time did not change — please change the date or the time first.';

  @override
  String get loginGuestMode => 'Sign in as guest';

  @override
  String get loginGuestEmailLabel => 'Guest email';

  @override
  String get loginGuestQuerying => 'Looking up guest account…';

  @override
  String loginGuestFound(Object name) {
    return 'Guest account: $name';
  }

  @override
  String get loginGuestNotFound => 'No guest account found for this email';

  @override
  String get loginGuestHint => 'Guest access must be enabled on the NAS first';

  @override
  String get driveScanTitle => 'Scan document';

  @override
  String get driveScanCapture => 'Capture a page';

  @override
  String get driveScanDone => 'Create PDF and upload';

  @override
  String driveScanPages(Object n) {
    return '$n pages captured';
  }

  @override
  String driveScanSaved(Object name) {
    return 'Scan uploaded: $name';
  }

  @override
  String get driveScanUploadFailed => 'Failed to upload scan';

  @override
  String get driveScanNeedPage => 'Capture at least one page first';

  @override
  String get aiVaultBadge => 'Offline cache saved · reuse without re-download';

  @override
  String get aiVaultReused =>
      'Reused the local offline cache — no network used';

  @override
  String get aiVaultPurge => 'Clear offline cache';

  @override
  String aiVaultPurged(String size) {
    return 'Freed $size';
  }

  @override
  String get aiVaultHint =>
      'A second copy of each on-device model is kept on this phone: removing it in the app or installing a new build needs no re-download. Uninstalling the app clears this copy - restore it from the computer backup instead and skip the download.';

  @override
  String aiVaultLocation(String path) {
    return 'Cache location: $path';
  }

  @override
  String get aiDeviceCapabilityTitle => 'Device capability';

  @override
  String get aiDeviceCapabilityHint =>
      'On-device models are recommended for this device\'s compute; the list changes with the phone.';

  @override
  String get aiDeviceTierLabel => 'AI compute tier';

  @override
  String get aiDeviceTierUnsupported => 'Unsupported';

  @override
  String get aiDeviceTierEntry => 'Entry';

  @override
  String get aiDeviceTierMainstream => 'Mainstream';

  @override
  String get aiDeviceHostUnknown =>
      'Desktop host: phone hardware is not probed here; the on-device tier is only judged on Android/iOS';

  @override
  String get aiDeviceSyntheticProfile =>
      '★ Device capability = synthetic profile (QA-injected, not real hardware)';

  @override
  String get aiDeviceProbeUnknown =>
      'Couldn\'t read this device\'s hardware info: the platform doesn\'t expose a hardware interface, so on-device model support can\'t be determined.';

  @override
  String get aiDeviceTierHigh => 'High';

  @override
  String get aiDeviceTierFlagship => 'Flagship';

  @override
  String get aiDeviceSocLabel => 'SoC';

  @override
  String get aiDeviceRamLabel => 'RAM';

  @override
  String get aiDeviceStorageLabel => 'Free storage';

  @override
  String get aiDeviceGpuLabel => 'GPU';

  @override
  String get aiDeviceGpuNone => 'No OpenCL detected; judged by CPU thresholds';

  @override
  String get aiDeviceNpuLabel => 'NPU';

  @override
  String get aiDeviceNpuNone => 'No NNAPI';

  @override
  String get aiDeviceNpuNnapi => 'NNAPI present';

  @override
  String get aiDeviceNpuVendor => 'Vendor NPU (known usable)';

  @override
  String get aiDeviceModuleHidden => 'On-device AI is hidden on this device';

  @override
  String aiDeviceModuleHiddenBody(String reason) {
    return 'This device does not meet the minimum requirements for on-device models ($reason); the on-device tier and model catalog are hidden. Cloud models and extractive summaries still work.';
  }

  @override
  String get aiDeviceVetoLowRam => 'system reports a low-RAM device';

  @override
  String aiDeviceVetoCores(int n) {
    return 'too few CPU cores ($n)';
  }

  @override
  String get aiDeviceVetoAbi => 'not an arm64 device';

  @override
  String aiDeviceVetoRam(String gb) {
    return 'only $gb GB RAM, below the minimum for on-device models';
  }

  @override
  String aiBlockedModelsTitle(int n) {
    return 'Models not usable on this device ($n)';
  }

  @override
  String aiBlockedReasonRam(String need, String have) {
    return 'Not enough RAM (needs $need GB, this device has $have GB)';
  }

  @override
  String get aiBlockedReasonTier => 'Device tier too low';

  @override
  String aiBlockedReasonStorage(String need, String have) {
    return 'Not enough storage (needs $need, $have free)';
  }

  @override
  String get aiBlockedReasonNpu => 'Requires a vendor NPU this device lacks';

  @override
  String get aiBlockedReasonModuleHidden => 'On-device module is hidden';

  @override
  String get aiDeviceModelBlocked =>
      'This device does not meet the model\'s requirements; cancelled';

  @override
  String get apiObjectIdRequired => 'Missing file identity; cannot continue';

  @override
  String get apiTemplateMakeNeedsIds =>
      'Creating from a template is missing the destination; go back to the target folder and retry';

  @override
  String get asAlphaAll => 'All';

  @override
  String asBatchRatingSet(Object count) {
    return 'Rated $count tracks';
  }

  @override
  String get asCastConnect => 'Connect';

  @override
  String get asCastConnectFailed => 'Connection failed';

  @override
  String get asCastCurrent => 'Cast current track';

  @override
  String get asCastDisconnect => 'Disconnect';

  @override
  String get asCastPlayFailed => 'Casting failed';

  @override
  String get asCastTitle => 'Cast to Chromecast';

  @override
  String get asCastUnsupported => 'Chromecast is not supported on this device';

  @override
  String get asCastUnsupportedHint =>
      'Requires Google Play services and Cast support on the device.';

  @override
  String asDaysAgo(Object n) {
    return '$n days ago';
  }

  @override
  String get asDownload => 'Download';

  @override
  String get asDownloadDisabled =>
      'Downloads are disabled on the NAS. Turn them on in the NAS download package, then retry.';

  @override
  String get asDownloadFailed =>
      'Download failed: cannot write to local storage';

  @override
  String get asDownloadNoContent =>
      'The server returned no content to download';

  @override
  String asDownloadOk(Object n) {
    return 'Downloaded $n bytes to this device';
  }

  @override
  String get asDownloadedLocal => 'Downloaded to this device';

  @override
  String get asEqEnable => 'Enable equalizer';

  @override
  String get asEqGaplessHint =>
      'Enabling the equalizer disables gapless playback';

  @override
  String get asEqUnsupported => 'Equalizer is currently unavailable';

  @override
  String get asEqUnsupportedHint =>
      'Adjust while audio is playing — the effect attaches to the current playback session.';

  @override
  String get asEqNoPresets =>
      'This device\'s native equalizer exposes only the on/off switch: the platform returned no preset names, so there is no preset list here. Toggling applies to the current playback output immediately.';

  @override
  String get asEqualizer => 'Equalizer';

  @override
  String asHoursAgo(Object n) {
    return '$n hours ago';
  }

  @override
  String get asJustNow => 'Just now';

  @override
  String get asLibraryAll => 'All (default)';

  @override
  String get asLibraryPersonal => 'My music library';

  @override
  String get asLibraryShared => 'Shared music library';

  @override
  String get asLibrarySwitch => 'Music library';

  @override
  String asMinutesAgo(Object n) {
    return '$n minutes ago';
  }

  @override
  String get asMoreLists => 'More lists';

  @override
  String get asMostPlayed => 'Most played';

  @override
  String get asMostPlayedEmpty => 'No play history yet';

  @override
  String get asNewPlaylist => 'New playlist';

  @override
  String get asOnlineTag => 'Online tags';

  @override
  String asPlayCount(Object count) {
    return 'Played $count times';
  }

  @override
  String get asPlaylistCreated => 'Playlist created';

  @override
  String asPlaylistDeleteBody(Object name) {
    return 'Delete “$name”?';
  }

  @override
  String get asPlaylistDeleteTitle => 'Delete playlist';

  @override
  String get asRadioAdd => 'New radio station';

  @override
  String get asRadioBatchDelete => 'Delete selected';

  @override
  String asRadioBatchDeleteBody(Object count) {
    return 'Delete the $count selected radio stations? This cannot be undone.';
  }

  @override
  String asRadioBatchDeleted(Object count) {
    return 'Deleted $count radio stations';
  }

  @override
  String get asRadioNameRequired => 'Enter a station name';

  @override
  String get asRadioSelectAll => 'Select all';

  @override
  String get asRadioSelectMode => 'Select';

  @override
  String get asRadioSelectNone => 'Deselect all';

  @override
  String asRadioSelectionCount(Object count) {
    return '$count selected';
  }

  @override
  String get asRadioBatchDeleteTitle => 'Delete selected stations';

  @override
  String get asRadioUrlRequired => 'Enter the station URL';

  @override
  String get asRadioDeleteTitle => 'Delete radio station';

  @override
  String get asRadioEdit => 'Edit';

  @override
  String get asRadioFavAdded => 'Added to favorites';

  @override
  String get asRadioFavAdd => 'Add to favorites';

  @override
  String get asRadioFavRemove => 'Remove from favorites';

  @override
  String get asRandom100 => '100 random tracks';

  @override
  String get asRandom100Failed => 'Failed to load the random list';

  @override
  String get asRandom100Refresh => 'Shuffle again';

  @override
  String get asRatingClear => 'Clear rating';

  @override
  String get asRecentlyAdded => 'Recently added';

  @override
  String get asRecentlyAddedEmpty => 'No recently added albums yet';

  @override
  String get asRecentlyAddedFailed => 'Failed to load recently added';

  @override
  String get asRecentlyPlayed => 'Recently played';

  @override
  String get asRecentlyPlayedEmpty => 'No play history yet';

  @override
  String get asRemoteEmpty => 'No remote players found';

  @override
  String get asRemoteEmptyHint =>
      'No controllable playback devices (DLNA/UPnP renderers, etc.) were found on the NAS.';

  @override
  String get asRemoteNoPrivilege =>
      'This account has no remote playback permission';

  @override
  String get asRemoteNoPrivilegeHint =>
      'This account lacks the Audio Station remote playback permission (granted by a DSM administrator), so the server returns no playback devices.';

  @override
  String get asRemoteUpnpDisabled => 'DLNA / UPnP is disabled on the server';

  @override
  String get asRemoteUpnpDisabledHint =>
      'Audio Station on the NAS has UPnP/DLNA turned off (Settings > Advanced > DLNA), so it does not discover playback devices - nothing to do with this phone.';

  @override
  String get asRemoteLoadFailed => 'Failed to load remote players';

  @override
  String get asRemoteNoCurrent => 'Nothing is playing on this device right now';

  @override
  String get asRemotePushCurrent => 'Push the current track to this device';

  @override
  String get asRemoteTitle => 'Remote players';

  @override
  String get asRemoteTypeBt => 'Bluetooth';

  @override
  String get asRemoteUnnamed => 'Unnamed player';

  @override
  String get asSelectionCancel => 'Exit multi-select';

  @override
  String asSelectionCount(Object count) {
    return '$count selected';
  }

  @override
  String get asShare => 'Share';

  @override
  String get asShareDisable => 'Turn sharing off';

  @override
  String get asShareEnable => 'Turn sharing on';

  @override
  String get asShareNoPrivilege =>
      'Sharing is disabled on the NAS. Turn it on there, then retry.';

  @override
  String get asShareNone => 'This song has no share link yet';

  @override
  String get asShowInFiles => 'Show in File Station';

  @override
  String get asSleepTimer => 'Sleep timer';

  @override
  String get asSleepTimerCancel => 'Cancel';

  @override
  String get asSleepTimerOff => 'Turn sleep timer off';

  @override
  String get asSleepTimerDone => 'Sleep timer finished; playback paused';

  @override
  String asSleepTimerMinutes(Object m) {
    return '$m min';
  }

  @override
  String asSleepTimerRemaining(Object left) {
    return 'Sleep timer · $left';
  }

  @override
  String get asSleepTimerSet => 'Set sleep timer';

  @override
  String get asSmartRulesMissing =>
      'Could not load the smart list rules; nothing was renamed';

  @override
  String get asSongMenu => 'More';

  @override
  String get asTagEmpty => 'No online tags found';

  @override
  String asTagFailed(Object e) {
    return 'Online tag lookup failed: $e';
  }

  @override
  String get asTagHint => 'Look up this album\'s tags online (Discogs)';

  @override
  String get asTagQuery => 'Search';

  @override
  String get asTagRefresh => 'Search again';

  @override
  String get audioLyricsBadResponse =>
      'The lyrics service returned data we could not read (the source may have changed)';

  @override
  String audioLyricsSourceLine(Object x) {
    return 'Lyrics source: $x';
  }

  @override
  String get audioLyricsSourceNas => 'NAS lyrics library';

  @override
  String get audioLyricsSourcePublic => 'lrclib.net public lyrics';

  @override
  String get audioLyricsCached => 'Using local cache';

  @override
  String get audioLyricsNotFound => 'No lyrics found for this song';

  @override
  String get audioLyricsOffline =>
      'No network connection; cannot search lyrics online';

  @override
  String get audioLyricsPick => 'Choose another lyrics version';

  @override
  String get audioLyricsPlain =>
      'These lyrics don\'t auto-scroll (plain text, drag to read)';

  @override
  String get audioLyricsJumpToActive => 'Jump to the line playing now';

  @override
  String get audioLyricsRetry => 'Retry';

  @override
  String get audioLyricsSearchHint => 'Search lyrics';

  @override
  String get audioLyricsServer =>
      'The lyrics service returned an error; try again later';

  @override
  String get audioLyricsTimeout => 'The lyrics service timed out';

  @override
  String get audioVisualizerCaption => 'Motion visual';

  @override
  String get audioVisualizerCaptionSpectrum =>
      'Live spectrum (from device audio output)';

  @override
  String get cancel => 'Cancel';

  @override
  String get chatActionStickThread => 'Pin in thread';

  @override
  String get chatActionUnstickThread => 'Unpin from thread';

  @override
  String get chatStickFailed => 'Failed to pin the post; please retry.';

  @override
  String get chatStickUnsupported =>
      'Pinning posts in a thread is disabled on the server';

  @override
  String get delete => 'Delete';

  @override
  String get dsBack => 'Back';

  @override
  String get dsBrowserAdd => 'Add to downloads';

  @override
  String get dsBrowserAdded => 'Added to download tasks';

  @override
  String get dsBrowserFound => 'Download link found';

  @override
  String get dsBrowserGo => 'Open';

  @override
  String get dsBrowserTitle => 'Download link browser';

  @override
  String get dsBrowserUrl => 'URL';

  @override
  String get dsBtCatAll => 'All categories';

  @override
  String get dsBtSort => 'Sort';

  @override
  String get dsBtSortDate => 'By date';

  @override
  String get dsBtSortDefault => 'Default order';

  @override
  String get dsBtSortSeeds => 'By seeders';

  @override
  String get dsBtSortSize => 'By size';

  @override
  String get dsBtSortTitle => 'By name';

  @override
  String get dsCancel => 'Cancel';

  @override
  String get dsCapBtPreview => 'BT preview';

  @override
  String get dsCapEmule => 'eMule';

  @override
  String get dsCapUnzip => 'Auto extract';

  @override
  String get dsCapUnzipService => 'Extraction service';

  @override
  String get dsCatActive => 'Active';

  @override
  String dsCreateOptionsFailed(Object msg) {
    return 'Task created, but the options did not apply: $msg';
  }

  @override
  String get dsCreateOptionsNotApplied =>
      'Task created, but “start now / speed limit” could not be applied (the list has not refreshed yet)';

  @override
  String get dsDelete => 'Delete';

  @override
  String get dsDestinationHint => 'e.g. /volume1/downloads';

  @override
  String dsDestinationSaveFailed(Object msg) {
    return 'Update failed: $msg';
  }

  @override
  String get dsDestinationSaved => 'Download destination updated';

  @override
  String get dsEditDestination => 'Edit download destination';

  @override
  String get dsEmuleAddServer => 'Add server';

  @override
  String get dsEmuleAdded => 'Download task created';

  @override
  String get dsEmuleConnect => 'Connect';

  @override
  String get dsEmuleConnectKad => 'Connect Kad';

  @override
  String get dsEmuleDeleteSelected => 'Delete selected';

  @override
  String get dsEmuleDisconnect => 'Disconnect all';

  @override
  String get dsEmuleDownloadN => 'Download selected';

  @override
  String get dsEmuleDownloads => 'eMule downloads';

  @override
  String get dsEmuleEmpty => 'No eMule tasks.';

  @override
  String get dsEmuleExtension => 'Extension';

  @override
  String get dsEmuleFileType => 'File type';

  @override
  String get dsEmuleKeyword => 'Keyword';

  @override
  String get dsEmuleMaxSize => 'Max size (MB)';

  @override
  String get dsEmuleMethod => 'Search method';

  @override
  String get dsEmuleMinSize => 'Min size (MB)';

  @override
  String get dsEmuleMinSource => 'Min sources';

  @override
  String get dsEmuleNoResult => 'No results found';

  @override
  String get dsEmuleNoServer => 'No eMule servers yet.';

  @override
  String get dsEmuleSearch => 'eMule search';

  @override
  String get dsEmuleServerIp => 'IP / hostname';

  @override
  String get dsEmuleServerName => 'Name (optional)';

  @override
  String get dsEmuleServerPort => 'Port';

  @override
  String get dsEmuleServerRequired => 'Enter the IP and port';

  @override
  String get dsEmuleServers => 'eMule servers';

  @override
  String get dsEmuleTitle => 'eMule';

  @override
  String get dsEmuleUnnamed => '(unnamed file)';

  @override
  String get dsEmuleUploads => 'eMule uploads';

  @override
  String get dsEmuleUploadsEmpty => 'Nothing is uploading right now.';

  @override
  String get dsFileCopied => 'File copy started';

  @override
  String dsFileCopyFailed(Object msg) {
    return 'Copy failed: $msg';
  }

  @override
  String get dsFileCopyTo => 'Copy to…';

  @override
  String dsFileOptionFailed(Object msg) {
    return 'Operation failed: $msg';
  }

  @override
  String get dsFileOptionSaved => 'Submitted';

  @override
  String get dsFilePriority => 'Priority';

  @override
  String get dsFileSkip => 'Skip';

  @override
  String get dsFileUnskip => 'Resume download';

  @override
  String get dsLoading => 'Loading…';

  @override
  String get dsMaxDownloadRate => 'Download limit (KB/s)';

  @override
  String get dsMaxUploadRate => 'Upload limit (KB/s)';

  @override
  String get dsModules => 'Modules';

  @override
  String get dsNotify => 'Task completion alerts';

  @override
  String get dsNotifyComplete => 'Alert when a task finishes';

  @override
  String get dsNotifyCompleteHint =>
      'Show an in-app notice when a task finishes or fails (the server does not push completion events, so the client polls for them)';

  @override
  String dsNotifyFailed(Object name) {
    return 'Download failed: $name';
  }

  @override
  String dsNotifyFinished(Object name) {
    return 'Download finished: $name';
  }

  @override
  String get dsNzbFileEmpty => 'No NZB file information';

  @override
  String get dsNzbFiles => 'NZB file list';

  @override
  String dsNzbFilesTotal(Object n) {
    return '$n files in total';
  }

  @override
  String get dsNzbLog => 'NZB log';

  @override
  String get dsNzbLogEmpty => 'No NZB log yet';

  @override
  String get dsNzbUnavailable => 'This task has no usable NZB information';

  @override
  String get dsPackageInfo => 'Download Station package information';

  @override
  String get dsRssEditFeed => 'Edit subscription';

  @override
  String get dsRssFeedSaved => 'Subscription updated';

  @override
  String get dsRssTitleLabel => 'Name';

  @override
  String get dsSave => 'Save';

  @override
  String get dsStartImmediately => 'Start downloading immediately';

  @override
  String get dsStartImmediatelyHint =>
      'When off, the task is queued (paused) after creation';

  @override
  String get dsVersion => 'Version';

  @override
  String get dsVersionUnknown => 'Unknown version';

  @override
  String get dtoNotifBackgroundTask => 'Background task';

  @override
  String get dtoNotifComment => 'Comment';

  @override
  String get dtoNotifCommentReply => 'Comment reply';

  @override
  String get dtoNotifLabelOwnerTransfer => 'Label owner transfer';

  @override
  String get dtoNotifMention => '@ mention';

  @override
  String get dtoNotifRequest => 'Access request';

  @override
  String get dtoNotifRequestOfficeTemplate => 'Office template request';

  @override
  String get dtoNotifRequestUnlock => 'Unlock request';

  @override
  String get dtoNotifShareWithMe => 'Shared with me';

  @override
  String get dtoNotifSharedLabel => 'Shared label';

  @override
  String get dtoShortcutUntitled => 'Untitled';

  @override
  String get dtoSmartUntitled => 'Untitled smart notebook';

  @override
  String get noteConflictKeepBoth => 'Keep both';

  @override
  String noteConflictKeepBothFailed(Object error) {
    return 'Could not keep the copy: $error';
  }

  @override
  String get noteConflictKeptBoth => 'Both copies were kept';

  @override
  String get noteConflictSuffix => 'Conflict';

  @override
  String get noteStorageExternal => 'External storage (app-specific folder)';

  @override
  String get noteStorageExternalShort => 'External';

  @override
  String get noteStorageInternal => 'Internal storage (app private)';

  @override
  String get noteStorageTitle => 'Storage location (attachments/offline data)';

  @override
  String get noteThemeTitle => 'Theme';

  @override
  String get officeDocTocTitle => 'Contents';

  @override
  String get officeTemplateLibraryEncryptedTitle =>
      'New from template (encrypted)';

  @override
  String get rename => 'Rename';

  @override
  String get widgetNotebooksTitle => 'Notebooks';

  @override
  String get widgetPlaceholderNoNotebooks => 'No notebooks yet';

  @override
  String get ok => 'OK';

  @override
  String get asSleepTimerCancelLong => 'Cancel sleep timer';

  @override
  String get audioLyricsInstrumental => '♪';

  @override
  String get audioLyricsLoading => 'Searching lyrics…';

  @override
  String get audioLyricsNoTimeline => 'No auto-scroll';

  @override
  String get audioLyricsNotLoaded => 'No lyrics loaded for this song yet';

  @override
  String get audioUpNext => 'Up next';

  @override
  String get audioPrevious => 'Previous';

  @override
  String get audioNext => 'Next';

  @override
  String get audioRepeatOne => 'Repeat one';

  @override
  String get carddavAccountLoadFailed =>
      'Could not read the account information';

  @override
  String get carddavSourcesLoadFailed => 'Could not load external sources';

  @override
  String get contactShareeEveryone => 'Everyone';

  @override
  String get contactGroupsLoadFailed => 'Could not load groups';

  @override
  String get contactMembersLoadFailed => 'Could not load members';

  @override
  String get contactOuLoadFailed => 'Could not load organizational units';

  @override
  String get mediaSubtitleSourceGestdownNote =>
      'No API key needed; covers TV episodes only (the file name needs a season/episode tag like S01E02); observed languages are mostly English and French';

  @override
  String get mediaSubtitleSourceOpenSubtitlesNote =>
      'Works without an API key (anonymous quota applies); adding an API key makes it more reliable and supports more languages';

  @override
  String get mediaSubtitleSourceOpenSubtitlesRestNote =>
      'No API key needed; finds Simplified, Traditional and bilingual Chinese by title (no hash matching)';

  @override
  String mediaSubtitleRestHttp(Object code) {
    return 'The OpenSubtitles legacy API returned HTTP $code';
  }

  @override
  String get mediaSubtitleRestLanguageUnsupported =>
      'No OpenSubtitles legacy language code matches this language';

  @override
  String get mediaSubtitleEpisodeUnknown => 'Episode unknown';

  @override
  String noteConflictResolveFailed(Object error) {
    return 'Could not resolve: $error';
  }

  @override
  String get noteConflictRetry => 'Retry';

  @override
  String get nasTitle => 'My NAS';

  @override
  String get nasAdd => 'Add NAS';

  @override
  String get nasPartialLoad =>
      'Some saved server entries could not be read and were skipped; the rest are unaffected.';

  @override
  String get nasFootnote =>
      'This device can store several NAS servers and accounts; after switching, Files, Photos, Notes, Music, Downloads and Drive all connect to the current one. Removing affects only the selected entry.';

  @override
  String get nasEmpty => 'No NAS saved yet';

  @override
  String get nasNameLabel => 'Name';

  @override
  String get nasNameHint => 'e.g. Home NAS';

  @override
  String get nasRemoveTitle => 'Remove this NAS?';

  @override
  String nasRemoveActiveBody(String name) {
    return '\"$name\" is the current NAS; removing it disconnects it first and switches to another saved NAS. Only this entry is deleted; other NAS configurations are unaffected.';
  }

  @override
  String nasRemoveBody(String name) {
    return 'Only \"$name\" is deleted from this device; other NAS configurations are unaffected.';
  }

  @override
  String get nasRemovedNone => 'Removed. No NAS is saved now.';

  @override
  String nasRemovedSwitched(String name) {
    return 'Removed and switched to \"$name\".';
  }

  @override
  String nasSwitched(String name) {
    return 'Switched to \"$name\"';
  }

  @override
  String get nasConnectFailed => 'Can\'t connect to this NAS right now';

  @override
  String get nasRecordGone => 'This entry no longer exists';

  @override
  String get nasNotSignedIn => 'Not signed in';

  @override
  String nasAccount(String account) {
    return 'Account: $account';
  }

  @override
  String get nasCurrent => 'Current';

  @override
  String get nasSwitchTo => 'Switch to this NAS';

  @override
  String get nasRemove => 'Remove';

  @override
  String get nasNameOptional => 'Name (optional)';

  @override
  String get nasDirectAddress => 'Direct address';

  @override
  String get nasHostOrAddress => 'Host or address';

  @override
  String get nasAddAndConnect => 'Add and connect';

  @override
  String get nasSaved => 'Saved NAS';

  @override
  String nasSelectN(int n) {
    return 'Choose a NAS ($n)';
  }

  @override
  String get nasManage => 'Manage NAS';

  @override
  String nasLabelNotSignedIn(String name) {
    return '$name (not signed in)';
  }

  @override
  String nasCurrentLabel(String name) {
    return 'Current: $name';
  }

  @override
  String get adminPermissionRequired => 'Administrator permission required';

  @override
  String get photoAdminTitle => 'Photos (admin)';

  @override
  String photoAdminLoadFailed(String error) {
    return 'Couldn\'t load admin settings: $error';
  }

  @override
  String get photoAdminSettingsTitle => 'Admin settings';

  @override
  String get photoAdminSettingsEmpty => 'This NAS returned no admin fields';

  @override
  String get photoAdminRefetch => 'Refetch geocoding';

  @override
  String get photoAdminRefetchHint =>
      'Ask the NAS to re-resolve place names from photo coordinates (uses some NAS resources)';

  @override
  String get photoAdminRefetchTitle => 'Refetch geocoding?';

  @override
  String get photoAdminRefetchBody =>
      'The NAS will re-resolve place names for all photos; this may take a while.';

  @override
  String get photoAdminRefetchQueued => 'Geocoding refetch requested';

  @override
  String photoAdminRefetchFailed(String error) {
    return 'Request failed: $error';
  }

  @override
  String get photoAdminEntrySubtitle =>
      'Admin settings and geocoding refetch; shown to administrators only';

  @override
  String get photoMapTitle => 'Photo map';

  @override
  String photoMapLayerTooltip(String name) {
    return 'Switch layer ($name)';
  }

  @override
  String get photoMapMyLocation => 'My location';

  @override
  String photoMapLoadFailed(String error) {
    return 'Couldn\'t load the map: $error';
  }

  @override
  String get photoMapNoGeotagged => 'No photos with location data yet';

  @override
  String get photoMapTilesUnavailable =>
      'Basemap failed to load: your network may not reach this tile source. Tap here to retry, or use the layer button at the top right to switch sources.';

  @override
  String photoMapNPhotos(int n) {
    return '$n photos';
  }

  @override
  String photoMapClusterN(int n) {
    return '$n photos around here';
  }

  @override
  String get photoMapNoLocationSupport =>
      'This device has no location capability';

  @override
  String get photoMapLocationDenied =>
      'Location permission denied; can\'t show your position';

  @override
  String get photoMapLocationFailed => 'Couldn\'t get a location right now';

  @override
  String get sleepBackupTitle => 'Focused backup and sync';

  @override
  String sleepBackupRemaining(int n) {
    return '$n files left to back up';
  }

  @override
  String sleepBackupCountdown(int n) {
    return 'The screen will dim in $n seconds.';
  }

  @override
  String get sleepBackupOutdated =>
      'There are unfinished tasks: once enabled, they run automatically when idle.';

  @override
  String get sleepBackupEnablingTitle => 'Once enabled:';

  @override
  String get sleepBackupEnable => 'Enable';

  @override
  String get sleepBackupDisable => 'Disable';

  @override
  String get sleepBackupEnabledState =>
      'Enabled (state is shared with reminder scheduling)';

  @override
  String get sleepBackupDisabledState => 'Not enabled';

  @override
  String get sleepBackupTestReminder => 'Test reminder';

  @override
  String sleepBackupReminderTitleLine(String title) {
    return 'Reminder title: $title';
  }

  @override
  String sleepBackupScheduleLine(int interval) {
    return 'Unfinished tasks are checked about every $interval minutes; reminders start 24 hours apart and back off to at most 3 days.';
  }

  @override
  String get sleepBackupTestNotDue =>
      'No reminder is due right now (not yet due, or no outdated tasks); the decision follows the official rules.';

  @override
  String get sleepBackupTestSent =>
      'Local notification sent using the official reminder text.';

  @override
  String get sleepBackupTestNoPerm =>
      'Notification permission denied: the text is shown in the page instead of a system notification.';

  @override
  String get sleepBackupStatusProcessing => 'Backing up and syncing...';

  @override
  String get sleepBackupStatusFinished => 'Backup and sync finished';

  @override
  String get sleepBackupStatusStopped => 'Backup and sync stopped';

  @override
  String get sleepBackupNotificationTitle => 'SynHub reminder';

  @override
  String get sleepBackupNotificationMessage =>
      'There are unfinished tasks. Go to More > Backup and sync tasks and enable Focused backup and sync to run them when idle.';

  @override
  String get sleepBackupGuideRunning =>
      'The app will run tasks while the screen is dimmed. The process may take a while to finish.';

  @override
  String get sleepBackupGuideForeground =>
      'Keep this app in the foreground to continue.';

  @override
  String get sleepBackupGuideNoLock =>
      'Don\'t lock the screen or quit the app.';

  @override
  String get sleepBackupStopDesc =>
      'An error occurred. Go to Home > Background tasks to check these tasks:';

  @override
  String get sleepBackupWorkerTitle => 'SynHub sleep backup';

  @override
  String get sleepBackupWorkerText =>
      'To keep the backup running, keep the app in the foreground and the screen on.';

  @override
  String get photoSleepBackupSubtitle =>
      'Runs unfinished backup tasks while the screen is dimmed, with a 24-hour backoff reminder';

  @override
  String photoSimilarGroupN(int n) {
    return '$n photos in this group';
  }

  @override
  String get photoSimilarSingle => 'This one';

  @override
  String get photoSimilarNotActionable =>
      'This server returned no grouping info; view only.';

  @override
  String get photoSimilarUngroup => 'Ungroup';

  @override
  String get photoSimilarHint =>
      'Tap a photo to set it as the top pick; tap × at its corner to remove it from this group.';

  @override
  String get photoSimilarRemoved => 'Removed from this group';

  @override
  String get photoSimilarTopPickSet => 'Set as top pick';

  @override
  String get photoSimilarUngrouped => 'Ungrouped';

  @override
  String get photoSimilarRemoveTitle => 'Remove it from this group?';

  @override
  String get photoSimilarRemoveBody =>
      'It just leaves this group; the photo itself is not deleted.';

  @override
  String get photoSimilarUngroupTitle => 'Ungroup this group?';

  @override
  String get photoSimilarUngroupBody =>
      'All photos in the group are kept; they just stop being treated as a duplicate group.';

  @override
  String photoSimilarTotalN(int n) {
    return '$n photos total';
  }

  @override
  String get photoTopPickSelected => 'Top pick selected';

  @override
  String get photoFaceRemove => 'Remove from this person';

  @override
  String get photoFaceSeparate => 'Split into a new person';

  @override
  String get photoFaceRemoveTitle => 'Remove this face from the person?';

  @override
  String get photoFaceSeparateTitle => 'Split into a new person?';

  @override
  String get photoFaceRemoveBody =>
      'It just stops being assigned to this person; the photo itself is not deleted.';

  @override
  String get photoFaceSeparateBody =>
      'A new unnamed person will be created from this face.';

  @override
  String get photoFaceRemoved => 'Removed';

  @override
  String get photoFaceSeparated => 'Split';

  @override
  String get photoPersonMergeTooltip => 'Merge into…';

  @override
  String get photoPersonMergePickerTitle => 'Merge into which person?';

  @override
  String photoPersonMergeConfirmTitle(String name) {
    return 'Merge this person into \"$name\"?';
  }

  @override
  String get photoPersonMergeConfirmBody =>
      'After merging, this group of faces will belong to the target person; this cannot be undone automatically.';

  @override
  String get photoPersonMergeAction => 'Merge';

  @override
  String get photoPersonMerged => 'Merged';

  @override
  String get photoCastStopped => 'Cast stopped';

  @override
  String get photoCastNoDevices => 'No castable devices found';

  @override
  String get photoCastPickDevice => 'Cast to which device?';

  @override
  String get photoCastConnectFailed => 'Cast connection failed';

  @override
  String get photoRequestDescription => 'Description (optional)';

  @override
  String get photoRequestTeamLibrary => 'Team space';

  @override
  String get photoRequestTeamLibraryHint => 'Off = personal space';

  @override
  String get photoRequestMaxFileSize => 'Max file size (MB, empty = unlimited)';

  @override
  String get photoMapEntry => 'Map';

  @override
  String photoWave2SearchFilterApplyCount(int n) {
    return 'Apply ($n)';
  }

  @override
  String photoPersonsMigratingLine(String title, String message) {
    return '$title: $message';
  }

  @override
  String photoCacheLocalSize(String size, int n) {
    return '$size MB · $n files';
  }

  @override
  String get driveAdminTitle => 'Drive (admin)';

  @override
  String get driveAdminNoFields => 'The server returned no fields';

  @override
  String get driveAdminNoUsers => 'The server returned no users';

  @override
  String get driveAdminEntryTitle => 'Management (admin)';

  @override
  String get driveAdminEntrySubtitle =>
      'Drive settings / database usage / user privileges (read-only)';

  @override
  String driveScanLayoutStats(int lines, int words) {
    return 'Layout: $lines lines / $words word blocks';
  }

  @override
  String driveScanLayoutFailPart(int n) {
    return ' · $n pages failed';
  }

  @override
  String driveScanOcrStats(int chars) {
    return ' · Built-in OCR (dot-matrix print): $chars chars';
  }

  @override
  String driveScanUnknownPart(int n) {
    return ' · $n unrecognized';
  }

  @override
  String driveScanProcessedStats(int n, int detected) {
    return 'Processed $n pages · boundaries detected on $detected';
  }

  @override
  String get driveScanEnhance => 'Auto-crop and enhance';

  @override
  String get driveScanLines => 'Text line analysis';

  @override
  String get driveScanMovePrev => 'Move earlier';

  @override
  String get driveScanMoveNext => 'Move later';

  @override
  String get driveScanRemovePage => 'Remove this page';

  @override
  String get driveScanGallery => 'Import from gallery';

  @override
  String driveSyncFailedDetail(String error) {
    return 'Failed: $error';
  }

  @override
  String driveSyncCheckFailedDetail(String error) {
    return 'Check failed: $error';
  }

  @override
  String get driveSyncLocalHint => '/storage/emulated/0/Documents/Projects';

  @override
  String get driveSyncRemoteHint => '/mydrive/Projects';

  @override
  String get driveSyncTasksTooltip => 'Sync tasks';

  @override
  String get driveCategoryPhoto => 'Photos';

  @override
  String get driveCategoryVideo => 'Videos';

  @override
  String get driveCategoryAudio => 'Audio';

  @override
  String get driveCategoryDocument => 'Documents';

  @override
  String driveCategoryChip(String label, int count) {
    return '$label ($count)';
  }

  @override
  String drivePdfTextSelectedDetail(String text) {
    return 'Highlighted by text line: $text';
  }

  @override
  String driveSearchFilterActive(String label, String value) {
    return '$label: $value';
  }

  @override
  String safOnDemandConfiguredStatus(String account) {
    return 'Saved: system “Files” can access this NAS; account $account';
  }

  @override
  String safOnDemandUnconfiguredStatus(String account) {
    return 'Not set up: system “Files” has no account for this NAS; account $account';
  }

  @override
  String get safOnDemandUnknownAccount => '(unknown)';

  @override
  String get safOnDemandNativeNote =>
      'On-demand download is handled by Android\'s document provider: a file is downloaded when you open it.';

  @override
  String get driveAdminSectionSettings => 'Settings (Settings/list v1)';

  @override
  String get driveAdminSectionDatabase =>
      'Database (Config/get v1 + DBUsage/get v1)';

  @override
  String get driveAdminSectionPrivilege => 'Privilege (Privilege/list v1)';

  @override
  String driveAdminReadFailed(String section) {
    return 'Couldn\'t load ($section)';
  }

  @override
  String get fieldName => 'Name';

  @override
  String get fieldDescription => 'Description';

  @override
  String get listSeparator => ', ';

  @override
  String get asRadioPlayFailed =>
      'This station could not be played. Try another station or retry.';

  @override
  String get asRadioPlayFailedShort => 'Couldn\'t play';

  @override
  String get asRadioPlayRetry => 'Retry';

  @override
  String get audioRadioNew => 'New station';

  @override
  String get audioRadioEdit => 'Edit station';

  @override
  String audioRadioDeleteBody(String title) {
    return 'Delete \"$title\"?';
  }

  @override
  String get officeEmptyDocTitle => 'This document has no content yet';

  @override
  String get officeEmptyDocBody =>
      'Write something in Synology Office / WPS / Microsoft Word and save; come back and pull to refresh to see it.';

  @override
  String dsRssFilterMatchLine(String value) {
    return 'Include: $value';
  }

  @override
  String dsRssFilterNotMatchLine(String value) {
    return 'Exclude: $value';
  }

  @override
  String dsRssFilterDestLine(String value) {
    return 'Download to: $value';
  }

  @override
  String asPinReorderFailedDetail(String error) {
    return 'Couldn\'t reorder favorites: $error';
  }

  @override
  String asPinRenameFailedDetail(String error) {
    return 'Rename failed: $error';
  }

  @override
  String get dsUnzipLocationCurrentFolder => 'the download folder';

  @override
  String get dsUnzipLocationSpecifiedFolder => 'the specified folder';

  @override
  String dsUnzipLocationLine(String path) {
    return 'Extract to: $path';
  }

  @override
  String dsModulesLine(String list) {
    return 'Modules: $list';
  }

  @override
  String get appPageNotFound => 'Page not found';

  @override
  String chatUserWithAccount(String display, String username) {
    return '$display ($username)';
  }

  @override
  String get officeNotConnectedDsm => 'Not connected to DSM';

  @override
  String mailSendFailedDetail(String message, String error) {
    return '$message: $error';
  }

  @override
  String get noteConflictResolveIncomplete =>
      'Couldn\'t finish resolving the conflict; try again later';

  @override
  String textAiPassageLabel(String name, int n, String title) {
    return '$name ($n) · $title';
  }

  @override
  String get filePdfMarkupEntry => 'Annotate / sign';

  @override
  String officeViewerImageRef(String label, String id) {
    return '$label: $id';
  }

  @override
  String bookSlidesHeading(int n) {
    return 'Slide $n';
  }

  @override
  String calendarLunarMonthDay(Object d, Object m, Object zh) {
    return 'Lunar $m/$d';
  }

  @override
  String calendarLunarMonthOnly(Object m, Object zh) {
    return 'Lunar month $m';
  }

  @override
  String calendarLunarDayOnly(Object d, Object zh) {
    return 'Lunar day $d';
  }

  @override
  String get bookChmNoHtml => 'This book has no readable HTML body text';

  @override
  String get bookChmParseFailed =>
      'Failed to parse this CHM file (it may be damaged)';

  @override
  String get bookDjvuNoPages =>
      'This DJVU has no readable pages (no bitmaps and no text layer)';

  @override
  String get bookDjvuParseFailed =>
      'Failed to parse this DJVU file (it may be damaged)';

  @override
  String get bookParseFailedDrm =>
      'Failed to parse this book (it may be damaged or DRM-protected)';

  @override
  String bookFootnoteWrap(String inner) {
    return '($inner)';
  }

  @override
  String bookSheetN(String n) {
    return 'Sheet $n';
  }

  @override
  String get bookWorkbookTitle => 'Workbook';

  @override
  String get bookListSeparator => ', ';

  @override
  String get bookSearchHitOpen => '\"';

  @override
  String get bookSearchHitClose => '\"';

  @override
  String bookXpsVectorUnrendered(String count) {
    return '(this page has $count vector graphics; not rendered)';
  }

  @override
  String get bookXpsNoContent =>
      '(this page has no extractable text or bitmaps)';

  @override
  String get driveOnDemandNotEnabled => 'On-demand download is not enabled';

  @override
  String get driveOnDemandMissingFileId => 'Missing fileId';

  @override
  String driveOnDemandTooLarge(String size, String limit) {
    return 'File $size exceeds the \"open on demand\" limit of $limit; choose \"Available offline\" in the app first';
  }

  @override
  String get driveOnDemandEmptyContent => 'The server returned empty content';

  @override
  String driveOnDemandRejected(String code) {
    return 'Download refused (DSM error code $code)';
  }

  @override
  String driveOnDemandActualTooLarge(String size, String limit) {
    return 'Actual size $size exceeds the limit of $limit; discarded';
  }

  @override
  String driveOnDemandFailed(String error) {
    return 'Download failed: $error';
  }

  @override
  String get driveSafOfflineRootTitle => 'Synology Drive - Offline files';

  @override
  String get driveSafRemoteRootTitle => 'Synology Drive - Cloud files';

  @override
  String get driveOfficeCreateDoc => 'Synology Office document';

  @override
  String get driveOfficeCreateSheet => 'Synology Office spreadsheet';

  @override
  String get driveOfficeCreateSlides => 'Synology Office presentation';

  @override
  String officeViewerTranscodedKind(String kind) {
    return '(detected as $kind)';
  }

  @override
  String get fsGap2ErrorDetailSeparator => ': ';

  @override
  String get officeDocStepEmptyEdit => 'Empty edit';

  @override
  String officeDocStepDeleteText(String from, String to) {
    return 'Delete text (positions $from..$to)';
  }

  @override
  String officeDocStepInsertText(String text) {
    return 'Insert text \"$text\"';
  }

  @override
  String officeDocStepReplaceText(String text) {
    return 'Replace text with \"$text\"';
  }

  @override
  String officeDocStepAddMark(String mark) {
    return 'Add formatting $mark';
  }

  @override
  String officeDocStepRemoveMark(String mark) {
    return 'Remove formatting $mark';
  }

  @override
  String get officeDocTocLevel1 => 'Heading 1';

  @override
  String get officeDocTocLevel2 => 'Heading 2';

  @override
  String get officeDocTocLevel3 => 'Heading 3';

  @override
  String get officeDocTocLevel4 => 'Heading 4';

  @override
  String get officeDocTocLevel5 => 'Heading 5';

  @override
  String get officeDocTocLevel6 => 'Heading 6';

  @override
  String officeDocStepSetHeading(String level) {
    return 'Set heading level $level';
  }

  @override
  String get officeDocStepSetList => 'Set list';

  @override
  String officeDocStepSetParagraphAttrs(String attrs) {
    return 'Set paragraph attributes $attrs';
  }

  @override
  String officeDocStepSetDocAttrs(String attrs) {
    return 'Set document attributes $attrs';
  }

  @override
  String officeDocStepEdit(String type) {
    return 'Edit ($type)';
  }

  @override
  String officeDocTolerantMarks(String nodes, String marks) {
    return 'The document has $nodes images carrying $marks text formatting marks; those marks have no effect on images, so they were ignored. The text and images are otherwise intact.';
  }

  @override
  String get officeCollabErrNoPermission =>
      'This account does not have edit permission for this file';

  @override
  String get officeCollabErrNotReady =>
      'Collaboration service is not ready yet';

  @override
  String get officeCollabErrTimeout => 'Collaboration service timed out';

  @override
  String get officeCollabErrDisconnected =>
      'Collaboration service disconnected';

  @override
  String get officeCollabErrUnavailable =>
      'Collaboration service is temporarily unavailable';

  @override
  String officeSheetChartSeries(String n) {
    return 'Series $n';
  }

  @override
  String officeDocHeadingLevelLabel(String level) {
    return 'Heading level $level';
  }

  @override
  String get officeDocListOff => 'Remove list';

  @override
  String officeDocUndoLabel(String label) {
    return 'Undo $label';
  }

  @override
  String officeDocRedoLabel(String label) {
    return 'Redo $label';
  }

  @override
  String get officeSlidesBlockUnknown => '(unknown position)';

  @override
  String officeSlidesBlockLabel(String block) {
    return 'Block $block';
  }

  @override
  String get driveWatchTaskDeleted => 'Task deleted';

  @override
  String get driveWatchAutoSyncDisabled => 'Auto-sync is off';

  @override
  String driveWatchTooSoon(String minutes) {
    return 'Less than $minutes minutes since the last sync';
  }

  @override
  String driveWatchFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get driveGapLabelSep => ': ';

  @override
  String get drivePdfWrittenSuffix => '_written';

  @override
  String get drivePdfAnnotSuffix => '_annotated';

  @override
  String get drivePdfTextLayerUnsupportedFilter =>
      'Unsupported content-stream filter (only /FlateDecode)';

  @override
  String drivePdfTextLayerNoWidths(String name, String subtype) {
    return 'Font `$name` ($subtype) has no /Widths; coordinates unreliable, not decoding';
  }

  @override
  String drivePdfTextLayerUnknownOp(String op) {
    return 'Unsupported operator `$op` (coordinates may be incomplete)';
  }

  @override
  String driveSyncConflictDupName(
    String dir,
    String base,
    String stamp,
    String ext,
  ) {
    return '$dir$base (conflict $stamp)$ext';
  }

  @override
  String get driveSyncNeedLocalFolder => 'Choose a local folder';

  @override
  String get driveSyncNeedRemoteFolder => 'Choose a remote folder';

  @override
  String get driveSyncRemoteMustStartSlash => 'Remote path must start with /';

  @override
  String get driveSyncIntervalPositive =>
      'Auto-sync interval must be greater than 0 minutes';

  @override
  String get driveSyncLocalNewer => 'Local is newer';

  @override
  String get driveSyncRemoteNewer => 'Remote is newer';

  @override
  String get photoC2GroupAperture => 'Aperture';

  @override
  String get photoC2GroupCamera => 'Camera';

  @override
  String get photoC2GroupLens => 'Lens';

  @override
  String get photoC2GroupFlash => 'Flash';

  @override
  String get photoC2GroupExposureTime => 'Exposure time';

  @override
  String get photoC2GroupFocalLength => 'Focal length';

  @override
  String get photoC2GroupGeocoding => 'Location';

  @override
  String get photoC2GroupPerson => 'People';

  @override
  String get photoC2GroupTag => 'Tags';

  @override
  String get photoC2GroupConcept => 'Scenes';

  @override
  String get photoC2GroupRating => 'Rating';

  @override
  String get photoC2GroupFavorite => 'Favorites';

  @override
  String get photoC2GroupTime => 'Time';

  @override
  String get photoC2GroupItemType => 'Media type';

  @override
  String get photoP0PersonShow => 'Show';

  @override
  String get photoP0PersonHide => 'Hide';

  @override
  String get photoP0CastUnknownDevice => 'Unknown device';

  @override
  String get photoP0CastToScreen => 'Cast to screen';

  @override
  String get photoP0CastStop => 'Stop casting';

  @override
  String get photoWave3CacheCleared => 'Cleaned';

  @override
  String get photoP0RemoveSmartDone => 'Removed from this scene';

  @override
  String get asPlaylistNameHint => 'Name';

  @override
  String get mediaAudioChannelName => 'Playback controls';

  @override
  String get mediaCtlPrevious => 'Previous';

  @override
  String get mediaCtlNext => 'Next';

  @override
  String get mediaCtlPlay => 'Play';

  @override
  String get mediaCtlPause => 'Pause';

  @override
  String get mediaCtlStop => 'Stop and dismiss';

  @override
  String get mediaHideControls => 'Hide controls';

  @override
  String get mediaMore => 'More';

  @override
  String get mediaSubtitleSearchEllipsis => 'Search online subtitles…';

  @override
  String mediaSpeedValue(String speed) {
    return 'Speed ${speed}x';
  }

  @override
  String get mediaSpeed => 'Playback speed';

  @override
  String get mediaSubtitleSearch => 'Search online subtitles';

  @override
  String mediaBackwardN(String n) {
    return 'Back $n seconds';
  }

  @override
  String mediaForwardN(String n) {
    return 'Forward $n seconds';
  }

  @override
  String get mediaHoldBoost => 'Release to resume speed · 2×';

  @override
  String get mediaSubtitleSize => 'Subtitle size';

  @override
  String get mediaSubtitleTranscript => 'Subtitle transcript';

  @override
  String get mediaSubtitleSmaller => 'Smaller subtitles';

  @override
  String get mediaSubtitleLarger => 'Larger subtitles';

  @override
  String get mediaSubtitlePosition => 'Subtitle position';

  @override
  String get mediaSubtitlePositionDefault => 'Default';

  @override
  String get mediaSubtitleHigher => 'Move subtitles up';

  @override
  String get mediaSubtitleLower => 'Move subtitles down';

  @override
  String get mediaSubtitleBackground => 'Subtitle background';

  @override
  String get mediaCast => 'Cast';

  @override
  String get mediaCastTitle => 'Cast to TV';

  @override
  String get mediaCastSearching =>
      'Looking for TVs and projectors on your network…';

  @override
  String get mediaCastEmpty => 'No castable device found';

  @override
  String get mediaCastEmptyHint =>
      'Make sure the TV is on, on the same Wi-Fi as this phone, and has screen casting / DLNA enabled.';

  @override
  String get mediaCastSearch => 'Search again';

  @override
  String get mediaCastStop => 'Stop casting';

  @override
  String get mediaCastFailed => 'Casting failed';

  @override
  String get mediaCastReasonNoRenderer =>
      'No device on this network accepts casting.';

  @override
  String get mediaCastReasonUnreachable =>
      'The device is unreachable (turned off, or not on this network).';

  @override
  String get mediaCastReasonRejected =>
      'The TV refused this video (unsupported format, or blocked by its policy).';

  @override
  String get mediaCastReasonPlaybackFailed =>
      'The TV got the address but could not play it — it cannot reach the video on your NAS. Check the network or the certificate.';

  @override
  String get mediaCastPauseRemote => 'Pause on TV';

  @override
  String get mediaCastRemotePlaying => 'Playing on TV';

  @override
  String get mediaCastResumeRemote => 'Resume on TV';

  @override
  String get mediaCastRemotePaused => 'Paused on TV';

  @override
  String mediaVolumePercent(String n) {
    return 'Volume $n%';
  }

  @override
  String mediaBrightnessPercent(String n) {
    return 'Brightness $n%';
  }

  @override
  String mediaSubtitleSearchFailed(String err) {
    return 'Search failed: $err';
  }

  @override
  String mediaSubtitleSourceUnavailable(String source) {
    return 'This source is no longer available ($source)';
  }

  @override
  String mediaSubtitleDownloadFailed(String err) {
    return 'Download failed: $err';
  }

  @override
  String get mediaSubtitleTitleField => 'Title';

  @override
  String get mediaSubtitleTitleHint =>
      'For TV episodes, include a season/episode tag like S01E02';

  @override
  String get mediaSubtitleLangChinese => 'Chinese first';

  @override
  String get mediaSubtitleLangEnglish => 'English first';

  @override
  String get mediaSubtitleLangAny => 'Any';

  @override
  String get mediaSubtitleApiKeyLabel => 'OpenSubtitles API key (optional)';

  @override
  String get mediaSubtitleKeyMissing =>
      'No subtitle API key is configured. Keyless sources are tried first; some providers need an API key.';

  @override
  String mediaSubtitleHash(String hash) {
    return 'Media fingerprint computed: $hash… (matches by the first and last 64 KB)';
  }

  @override
  String mediaSubtitleFailureLine(String source, String message) {
    return '$source: $message';
  }

  @override
  String get mediaSubtitleOnline => 'Online subtitles';

  @override
  String mediaSubtitleOpenSubtitlesAnonymousRejected(String code) {
    return 'OpenSubtitles rejected the anonymous request (HTTP $code): enter an API key below and try again';
  }

  @override
  String mediaSubtitleOpenSubtitlesRejected(String code) {
    return 'OpenSubtitles rejected this request (HTTP $code): the API key may be invalid or over quota';
  }

  @override
  String get mediaSubtitleHearingImpaired => 'Hearing impaired';

  @override
  String mediaSubtitlePartsCount(String n) {
    return '$n parts (only the first is used)';
  }

  @override
  String get mediaSubtitleProofread => 'Proofread';

  @override
  String mediaSubtitleGestdownHttp(String code) {
    return 'Gestdown returned HTTP $code';
  }

  @override
  String mediaSubtitleGestdownShowFailed(String code) {
    return 'Gestdown show lookup failed (HTTP $code)';
  }

  @override
  String mediaSubtitleBadJson(String code) {
    return 'The subtitle source did not return valid JSON (HTTP $code)';
  }

  @override
  String get mediaSubtitleKeySaveFailed =>
      'Could not save the key (secure storage unavailable)';

  @override
  String get mediaSubtitleUnreadableContent =>
      'This subtitle has no readable content (it may not be a text subtitle)';

  @override
  String get mediaSubtitleAllSourcesFailed =>
      'All online subtitle sources failed; see the reasons above';

  @override
  String get mediaSubtitleNoMatch =>
      'No matching subtitles found (try another title or language)';

  @override
  String get mediaSubtitleTimeout => 'Request timed out';

  @override
  String mediaSubtitleServerUnreachable(String err) {
    return 'Cannot reach the subtitle server ($err)';
  }

  @override
  String mediaSubtitleTlsFailed(String err) {
    return 'TLS handshake failed ($err)';
  }

  @override
  String get mediaSubtitleNoTitleFromFileName =>
      'Cannot derive a title from the file name; enter one in the search box';

  @override
  String mediaSubtitleOpenSubtitlesUnavailable(String code) {
    return 'OpenSubtitles is temporarily unavailable (HTTP $code); try again later';
  }

  @override
  String mediaSubtitleOpenSubtitlesUnexpectedStatus(String code) {
    return 'OpenSubtitles returned an unexpected status code HTTP $code';
  }

  @override
  String get mediaSubtitleNoDownloadFileId =>
      'This result has no downloadable file id';

  @override
  String mediaSubtitleFileDownloadFailed(String code) {
    return 'Subtitle file download failed (HTTP $code)';
  }

  @override
  String get mediaSubtitleUnrecognizedSubtitle =>
      'The download is not a recognizable subtitle (the archive layout may have changed)';

  @override
  String get mediaSubtitleGestdownEpisodesOnly =>
      'Gestdown supports TV episodes only: the file name needs a season/episode tag like S01E02';

  @override
  String get mediaSubtitleNoDownloadUri =>
      'This result has no download address';

  @override
  String mediaSubtitleGestdownDownloadFailed(String code) {
    return 'Gestdown subtitle download failed (HTTP $code)';
  }

  @override
  String get mediaSubtitleUnrecognizedContent =>
      'The downloaded content is not a recognizable subtitle';

  @override
  String mediaSubtitleParseResultFailed(String source, String err) {
    return 'Failed to parse the $source result: $err';
  }

  @override
  String calParticipantNameStatus(String name, String status) {
    return '$name ($status)';
  }

  @override
  String get calWeatherClearDay => 'Sunny';

  @override
  String get calWeatherClearNight => 'Clear night';

  @override
  String get calWeatherCloudy => 'Cloudy';

  @override
  String get calWeatherRain => 'Rain';

  @override
  String get calWeatherSnow => 'Snow';

  @override
  String get calWeatherThunder => 'Thunderstorm';

  @override
  String get calWeatherFog => 'Fog';

  @override
  String get chatChannelGeneral => 'General';

  @override
  String get chatChannelRandom => 'Random';

  @override
  String chatMentionSent(String name) {
    return 'Mentioned @$name';
  }

  @override
  String contactLabelValue(String label, String value) {
    return '$label: $value';
  }

  @override
  String noteC3ErrorCodeSuffix(String code) {
    return ' ($code)';
  }

  @override
  String noteC3MessageWithError(String message, String error) {
    return '$message: $error';
  }

  @override
  String get widgetNotebookUntitled => 'Untitled notebook';

  @override
  String get widgetTodoUntitled => 'Untitled to-do';

  @override
  String adminGapStoragePoolsLine(String vol, String n) {
    return '$vol ($n storage pools)';
  }

  @override
  String get adminGapEnabled => 'Enabled';

  @override
  String get adminGapDisabled => 'Disabled';

  @override
  String adminGapAuthCount(String n) {
    return '$n authenticators';
  }

  @override
  String adminGapHddCount(String n) {
    return '$n drives';
  }

  @override
  String adminGapUserCount(String n) {
    return '$n users';
  }

  @override
  String adminGapGroupCount(String n) {
    return '$n groups';
  }

  @override
  String adminGapAppPrivCount(String n) {
    return '$n rules';
  }

  @override
  String adminGapDiskCount(String n) {
    return '$n disks';
  }

  @override
  String adminGapPackageCount(String n) {
    return '$n packages:';
  }

  @override
  String get adminGapUpgradeAvailable => 'Update available';

  @override
  String get adminGapUpgradeLatest => 'Up to date';

  @override
  String adminGapServiceCount(String n) {
    return '$n services';
  }

  @override
  String get aiModelLfmName => 'LFM2.5 230M (int4)';

  @override
  String get dsNotifyDownloadFailed => 'Download failed';

  @override
  String get dsNotifyDownloadDone => 'Download complete';

  @override
  String dsRssLastUpdateLine(String when) {
    return 'Last updated: $when';
  }

  @override
  String setGapServerLabel(String base, String source) {
    return '$base ($source)';
  }

  @override
  String chatSearchKeyword(String x) {
    return '\"$x\"';
  }

  @override
  String officeSectionEncryptedNotice(String x) {
    return 'Encrypted section: $x (zlib+AES-256-CBC+base64), not decrypted in phase 2a; needs phase 2b';
  }

  @override
  String officeSectionOpaqueNotice(String x) {
    return 'Unrecognized section: $x';
  }

  @override
  String get officeSlidesGraphicChart => 'Chart';

  @override
  String get officeSlidesGraphicDiagram => 'SmartArt diagram';

  @override
  String get officeSlidesGraphicTable => 'Table';

  @override
  String get officeSlidesGraphicOle => 'Embedded object';

  @override
  String get officeSlidesGraphicObject => 'Object';

  @override
  String fsGap2FavoriteReorderRejectedDetail(String head, String detail) {
    return '$head ($detail)';
  }

  @override
  String get usageModMedia => 'Media';

  @override
  String get usageModAi => 'AI assistant';

  @override
  String get usageModDownloads => 'Downloads';

  @override
  String get usageModAdmin => 'Admin';

  @override
  String get usageModSurveillance => 'Surveillance';

  @override
  String get usageActView => 'Page view';

  @override
  String get usageActSwitchView => 'Switch view';

  @override
  String get usageActFilter => 'Filter';

  @override
  String get usageActSort => 'Sort';

  @override
  String get usageActSelect => 'Select';

  @override
  String get usageActComplete => 'Complete';

  @override
  String get usageActAbandon => 'Abandon';

  @override
  String get usageActStart => 'Start';

  @override
  String get usageActPause => 'Pause';

  @override
  String get usageActResume => 'Resume';

  @override
  String get usageActAudition => 'Audition';

  @override
  String get usageActVote => 'Vote';

  @override
  String get usageActSwitchLanguage => 'Switch language';

  @override
  String get usageFailUnknown => 'Unknown';

  @override
  String get usageFailOffline => 'Offline';

  @override
  String get usageFailNetwork => 'Network error';

  @override
  String get usageFailTimeout => 'Timed out';

  @override
  String get usageFailAuth => 'Authentication failed';

  @override
  String get usageFailPermission => 'No permission';

  @override
  String get usageFailNotFound => 'Not found';

  @override
  String get usageFailUnsupported => 'Unsupported';

  @override
  String get usageFailDecode => 'Decode or render failed';

  @override
  String get usageFailTls => 'Certificate or TLS failed';

  @override
  String get usageFailStorage => 'Out of storage';

  @override
  String get usageFailConflict => 'Conflict';

  @override
  String get usageFailServer => 'Server error';

  @override
  String get usageFailCancelled => 'Cancelled';

  @override
  String get usageSectionModules => 'Usage by module';

  @override
  String get usageSectionAdoption => 'Feature adoption';

  @override
  String get usageSectionViewPrefs => 'View & option preferences';

  @override
  String get usageSectionFailures => 'Failure reasons';

  @override
  String get usageSectionDurations => 'Time spent';

  @override
  String get usageNoViewPrefs => 'No view or option switches yet';

  @override
  String get usageNoFailures => 'No failures recorded';

  @override
  String get usageNoDurations => 'No durations recorded yet';

  @override
  String get usageAdoptAll => 'Every module has been used at least once';

  @override
  String usageRange(String from, String to) {
    return 'Range $from to $to';
  }

  @override
  String usageModuleRow(String name, int count, int share) {
    return '$name · $count times · $share%';
  }

  @override
  String usageAdoptTitle(int used, int total) {
    return 'Adopted $used/$total modules';
  }

  @override
  String usageAdoptBody(String unused) {
    return 'Not used yet: $unused';
  }

  @override
  String usageViewPrefRow(String view, int count) {
    return '$view · $count times';
  }

  @override
  String usageFailReasonRow(String reason, int count) {
    return '$reason · $count times';
  }

  @override
  String usageDurationRow(String action, int avgMin, int count) {
    return '$action · avg $avgMin min · $count times';
  }

  @override
  String get usageKindViewPref => 'View preference';

  @override
  String get usageKindFailureReason => 'Failure reasons';

  @override
  String get usageSugViewPref =>
      'You can make the preferred view the default to switch less.';

  @override
  String usageTitleViewPref(String view, int share) {
    return 'Preferred view: $view ($share%)';
  }

  @override
  String usageBodyViewPref(String list) {
    return 'Other views: $list';
  }

  @override
  String usageTitleFailureReason(String reason, int count) {
    return 'Top failure reason: $reason ($count times)';
  }

  @override
  String usageBodyFailureReason(String list) {
    return 'Other reasons: $list';
  }

  @override
  String get usageViewGrid => 'Grid';

  @override
  String get usageViewList => 'List';

  @override
  String get usageViewTimeline => 'Timeline';

  @override
  String get usageViewMonth => 'Month';

  @override
  String get usageViewWeek => 'Week';

  @override
  String get usageViewAgenda => 'Agenda';

  @override
  String get usageViewLyrics => 'Lyrics';

  @override
  String get usageViewVisualizer => 'Visualizer';

  @override
  String get usageViewPlayer => 'Player';

  @override
  String get usageViewOther => 'Other';

  @override
  String get trafficTitle => 'Network traffic';

  @override
  String get trafficSubtitle =>
      'Per-module and time-of-day (exact + estimated)';

  @override
  String get trafficRangeDay => 'Last 24 hours';

  @override
  String get trafficRangeWeek => 'Last 7 days';

  @override
  String get trafficTotal => 'Total';

  @override
  String get trafficExact => 'Exact';

  @override
  String get trafficEstimated => 'Estimated';

  @override
  String get trafficExactHint =>
      'Measured in the Dart HTTP client (request + response bytes)';

  @override
  String get trafficEstimatedHint =>
      'Native players bypass Dart; estimated from system UID counters over active sessions';

  @override
  String get trafficUnattributed => 'Unattributed';

  @override
  String trafficUnattributedShare(String percent) {
    return 'Unattributed $percent%';
  }

  @override
  String get trafficDirectionAll => 'Total';

  @override
  String get trafficDirectionDown => 'Download';

  @override
  String get trafficDirectionUp => 'Upload';

  @override
  String get trafficSectionRanking => 'Traffic by module';

  @override
  String get trafficSectionHours => 'Time of day (24 hours)';

  @override
  String trafficRankRow(String name, String bytes, String share) {
    return '$name · $bytes · $share%';
  }

  @override
  String get trafficOsSection => 'vs. system counters';

  @override
  String trafficOsTotal(String bytes) {
    return 'System UID total $bytes';
  }

  @override
  String trafficOsAttributed(String bytes) {
    return 'Attributed in this app $bytes';
  }

  @override
  String trafficOsUnaccounted(String bytes) {
    return 'Unaccounted $bytes';
  }

  @override
  String trafficOsSince(String time) {
    return 'since $time';
  }

  @override
  String get trafficOsUnavailable =>
      'System traffic counters are unavailable on this device; the estimated tier is unavailable';

  @override
  String get trafficEmptyTitle => 'No traffic data yet';

  @override
  String get trafficEmptyMessage =>
      'Use the app for a while and check back. Exact counts start with Dart requests; estimates need a full playback session.';

  @override
  String get trafficPrivacyNote =>
      'Only module, direction, bytes and hour are stored - no URLs, hosts or file names';

  @override
  String get trafficExactPaths =>
      'Exact covers all Dart requests: login, listings, metadata, thumbnails, downloads, uploads, exports';

  @override
  String get trafficEstimatedPaths =>
      'Estimated covers video and audio playback plus native frame/stream bridges (deltas over active sessions)';

  @override
  String get trafficModUnattributed => 'Unattributed';

  @override
  String get trafficLoadFailed => 'Failed to load traffic data';

  @override
  String get trafficStorageNote =>
      'Kept locally as hourly buckets for 90 days (up to 100,000 rows); never uploaded';

  @override
  String get oemKeepaliveTitle => 'Background keep-alive settings';

  @override
  String get oemKeepaliveIntro =>
      'This app does not use system push: chat and new-message notifications arrive only while the system lets it run in the background.';

  @override
  String get oemKeepaliveNoFcm =>
      'Turn on every item below — when the app is limited in the background, notifications silently never arrive.';

  @override
  String get oemKeepaliveRowSummary =>
      'Vendor battery and auto-start allowances; without them notifications stop';

  @override
  String get oemKillAggressive =>
      'This vendor\'s power policy is aggressive; without these settings the app is usually killed within tens of minutes';

  @override
  String get oemKillModerate =>
      'This vendor\'s power policy is moderate; the app may be killed after long periods of disuse';

  @override
  String get oemKillStandard =>
      'System-level power saving only (Doze / App Standby buckets); rarely killed in normal use';

  @override
  String get oemStepAutostart => 'Allow auto-start / app launch management';

  @override
  String get oemStepBackgroundActivity =>
      'Allow background activity / associated start-up';

  @override
  String get oemStepBatteryUnrestricted =>
      'Set battery optimization to unrestricted / allow high background power use';

  @override
  String get oemStepLockRecents =>
      'Lock this app in the recents list so a one-tap clean does not remove it';

  @override
  String get oemOpenAutostart => 'Open auto-start management';

  @override
  String get oemOpenBattery => 'Open battery optimization whitelist';

  @override
  String get oemOpenAppDetails => 'Open app details';

  @override
  String get oemAutostartMissing =>
      'No vendor auto-start settings page was found on this device; follow the path below manually.';

  @override
  String get oemPathLabel => 'Manual path';

  @override
  String get oemBatteryIgnored =>
      'Already on the battery optimization whitelist';

  @override
  String get oemBatteryNotIgnored =>
      'Not yet on the battery optimization whitelist';

  @override
  String get oemDeviceLabel => 'This device';

  @override
  String get oemPathXiaomi =>
      'Settings > Apps > Manage apps > SynHub > Autostart; then set Battery saver to No restrictions';

  @override
  String get oemPathHuawei =>
      'Settings > Apps and services > App launch > SynHub > turn off Manage automatically and allow auto-start, associated start-up and background activity';

  @override
  String get oemPathHonor =>
      'Settings > Apps > App launch > SynHub > turn off Manage automatically and allow auto-start, associated start-up and background activity';

  @override
  String get oemPathOppo =>
      'Settings > Apps > App management > SynHub > allow auto-start, associated start-up and background activity, then set Power saving to Allow background running';

  @override
  String get oemPathVivo =>
      'Settings > Apps and permissions > Permission management > Autostart > allow SynHub; then Battery > High background power consumption > allow';

  @override
  String get oemPathOneplus =>
      'Settings > Apps > App management > SynHub > Power consumption > Allow background running; also turn off Smart power saving';

  @override
  String get oemPathSamsung =>
      'Settings > Battery and device care > Battery > Background usage limits > remove SynHub from Sleeping apps / Deep sleeping apps';

  @override
  String get oemPathMeizu =>
      'Settings > App management > Permission management > Background management > allow SynHub to run in the background';

  @override
  String get oemPathRealme =>
      'Settings > Apps > App management > SynHub > allow auto-start, associated start-up and background activity, then set Power saving to Allow background running';

  @override
  String get oemPathTranssion =>
      'Settings > Apps > App management > SynHub > allow auto-start and background activity, then Battery > disable power saving optimization';

  @override
  String get oemPathGoogle =>
      'Settings > Apps > SynHub > Battery > Unrestricted';

  @override
  String get oemPathOther =>
      'Settings > Apps > SynHub > Battery > allow background activity; then set SynHub to Not optimized under Battery optimization';

  @override
  String get oemNoteHuawei =>
      'Missing Google services on Huawei/Honor does not affect this app, but App launch defaults to Manage automatically and must be changed.';

  @override
  String get oemNoteHonor =>
      'Honor MagicOS defaults App launch to Manage automatically; without this the foreground service can be frozen too.';

  @override
  String get oemNoteXiaomi =>
      'HyperOS/MIUI also clears background apps from the recents list; locking the card is recommended.';

  @override
  String get oemNoteOppo =>
      'ColorOS freezes background apps via both Smart power saving and Deep sleep; allow both.';

  @override
  String get oemNoteVivo =>
      'OriginOS/FuntouchOS has High background power consumption off by default; allow it manually.';

  @override
  String get oemNoteSamsung =>
      'One UI automatically adds infrequently used apps to Sleeping apps / Deep sleeping apps; remove it manually.';

  @override
  String get oemNoteMeizu =>
      'Flyme restricts background running by default in Background management; allow it manually.';

  @override
  String get oemNoteRealme =>
      'realme UI shares code with ColorOS, so Smart power saving freezes background apps too.';

  @override
  String get oemNoteTranssion =>
      'Transsion devices (Tecno/Infinix/itel) have aggressive power management and usually no system push channel.';

  @override
  String get oemNoteOneplus =>
      'OxygenOS after the ColorOS merge also has Smart power saving; turn it off as well.';

  @override
  String get oemNoteGoogle =>
      'Stock/AOSP only has Doze and App Standby buckets, with no vendor whitelist; unrestricted background use is still recommended.';

  @override
  String get oemNoteOther =>
      'Unrecognised vendor: the generic background-permission steps are enough.';

  @override
  String get oemOpenFailed =>
      'This system settings page could not be opened on this device; follow the manual path below';

  @override
  String get capReasonOk => 'Available';

  @override
  String get capReasonNotSupported => 'Not supported on this platform';

  @override
  String get capReasonNotImplemented => 'Not implemented on this platform yet';

  @override
  String get capReasonNeedsMobile => 'Requires a mobile device';

  @override
  String get capReasonBridgeMissing => 'Native module missing';

  @override
  String get capReasonProbing => 'Probing…';

  @override
  String get capReasonTimeout => 'Probe timed out';

  @override
  String get capReasonProbeError => 'Probe failed';

  @override
  String get capReasonDeviceNo => 'Not supported on this device';

  @override
  String get capReasonUnknown => 'Unknown reason';

  @override
  String get errGenericFailed => 'The operation could not be completed';

  @override
  String get errConnectFailed =>
      'Connection failed: check the address and your network';

  @override
  String get errConnectTimeout =>
      'Connection timed out: the server did not respond in time. Check your network and retry.';

  @override
  String get errCannotReachServer =>
      'Cannot reach the server: check the address and your network';

  @override
  String get errBadCertificate =>
      'The server certificate could not be verified';

  @override
  String get errAbnormalResponse =>
      'The server returned an unexpected response';

  @override
  String errHttpStatus(Object code) {
    return 'The server returned HTTP $code';
  }

  @override
  String get errCancelled => 'The operation was cancelled';

  @override
  String get errNetworkConnectFailed =>
      'Network connection failed: check your network and retry';

  @override
  String get errNetworkUnreachable =>
      'Network unreachable: check Wi-Fi or mobile data';

  @override
  String get errTlsHandshakeFailed =>
      'TLS handshake with the server failed (certificate or proxy problem)';

  @override
  String get errNetworkRequestFailed =>
      'Network request failed: try again later';

  @override
  String get errBadDataFormat =>
      'The data format is invalid and cannot be processed';

  @override
  String get errFileIoFailed =>
      'File read/write failed: check storage space and permissions';

  @override
  String get errOperationTimeout => 'The operation timed out: try again later';

  @override
  String errDsmCodeWithDetail(Object code, Object detail) {
    return 'DSM $code: $detail';
  }

  @override
  String get fsG4SafOnDemandTitle => 'System picker · Files on demand';

  @override
  String get fsG4SafOnDemandSection => 'System “Files” integration';

  @override
  String get fsG4SafOnDemandTurnOn => 'Turn on files on demand';

  @override
  String get fsG4SafOnDemandTurnOff => 'Turn off files on demand';

  @override
  String fsG4SafOnDemandOnDesc(String cachedBytes) {
    return 'Configured: opening a cloud file signs in and downloads automatically (cache $cachedBytes bytes)';
  }

  @override
  String get fsG4SafOnDemandOffDesc =>
      'While unconfigured, only already-downloaded offline files open from system “Files”';

  @override
  String get fsG4SafOnDemandClearCache => 'Clear files-on-demand cache';

  @override
  String fsG4SafOnDemandCacheCleared(String freed) {
    return 'Released cache (about $freed bytes)';
  }

  @override
  String get fsG4SafOnDemandClearCacheDesc =>
      'Deletes files downloaded on demand (offline-marked files are untouched)';

  @override
  String get fsG4SafOnDemandNeedPassword =>
      'This record has no stored password (or it cannot be decrypted), so the system picker cannot sign in by itself.';

  @override
  String get fsG4SafOnDemandEnabled =>
      'Enabled: opening a Drive cloud file from system “Files” downloads automatically';

  @override
  String get fsG4SafOnDemandDisabled =>
      'Turned off; the saved account was cleared';

  @override
  String get fsG4SafOnDemandNotConfigured =>
      'The system picker still shows “not set up”';

  @override
  String get adminGapAppPrivTitle => 'App privileges';

  @override
  String get adminGapAuth2faTitle => 'Two-factor authenticator';

  @override
  String get adminGapBeepBeeping => 'Beeping';

  @override
  String get adminGapBeepNotBeeping => 'Not beeping';

  @override
  String get adminGapBeepStop => 'Stop';

  @override
  String get adminGapBeepStopped => 'Beeping stopped';

  @override
  String get adminGapBeepTitle => 'Beep';

  @override
  String get adminGapBeepUnknown => 'Status unknown';

  @override
  String get adminGapDiskHealthTitle => 'Disk health';

  @override
  String get adminGapEmptyList => '(empty)';

  @override
  String get adminGapFindMeSupported => 'Supported on this device';

  @override
  String get adminGapFindMeTitle => 'FindMe (locate my NAS)';

  @override
  String get adminGapFindMeUnknown => 'Status unknown';

  @override
  String get adminGapFindMeUnsupported => 'Not supported on this device';

  @override
  String get adminGapGroupTitle => 'Groups';

  @override
  String get adminGapHddTitle => 'Hard disk management';

  @override
  String get adminGapLoading => 'Loading…';

  @override
  String get adminGapNeedsAdmin =>
      'Administrator privileges are required to view this page.';

  @override
  String get adminGapNetworkTitle => 'Network';

  @override
  String get adminGapPackageTitle => 'Packages';

  @override
  String get adminGapPwdPolicyTitle => 'Password policy';

  @override
  String get adminGapReadFailed => 'Failed to load.';

  @override
  String get adminGapServiceTitle => 'Service status';

  @override
  String get adminGapStorageTitle => 'Storage';

  @override
  String get adminGapSysInfoTitle => 'System information';

  @override
  String get adminGapSysInfoUnknown => 'System information unavailable';

  @override
  String get adminGapToolsEntryHint => 'Visible to administrators only';

  @override
  String get adminGapToolsTitle => 'Admin tools';

  @override
  String get adminGapUpgradeTitle => 'DSM update';

  @override
  String get adminGapUserTitle => 'Users';

  @override
  String driveC1ActionFailed(String error) {
    return 'Action failed: $error';
  }

  @override
  String get driveC1AdvanceSharing => 'Advanced sharing';

  @override
  String get driveC1AdvanceSharingEmpty => 'No public links yet';

  @override
  String get driveC1AdvanceSharingIntro =>
      'Anonymous public links: anyone with the link can open it without an account; use Share for member sharing.';

  @override
  String get driveC1ClearLinkPassword => 'Clear access password?';

  @override
  String get driveC1ClearLinkPasswordHint =>
      'After clearing, anyone with the link can open it directly.';

  @override
  String get driveC1ClearNotifications => 'Clear notifications';

  @override
  String get driveC1ClearNotificationsConfirm => 'Clear all notifications?';

  @override
  String get driveC1CloseLink => 'Close link';

  @override
  String get driveC1CloseLinkBody =>
      'The public link stops working immediately after closing; anyone with the link will lose access.';

  @override
  String get driveC1CloseLinkConfirm => 'Close public link?';

  @override
  String get driveC1CloseRequest => 'Close';

  @override
  String get driveC1DeleteForever => 'Delete permanently';

  @override
  String driveC1DeleteForeverBody(String name) {
    return '\"$name\" will be permanently deleted and cannot be recovered.';
  }

  @override
  String get driveC1DeleteForeverConfirm => 'Delete permanently?';

  @override
  String driveC1DeleteForeverFailed(String error) {
    return 'Permanent deletion failed: $error';
  }

  @override
  String get driveC1DeletedAt => 'Deleted at';

  @override
  String get driveC1FileRequests => 'File requests';

  @override
  String get driveC1FileRequestsEmpty => 'No file request links yet';

  @override
  String get driveC1FileRequestsEntry =>
      'Manage the file request links you created: view, close, reopen, delete';

  @override
  String get driveC1LinkClosed => 'Link closed';

  @override
  String driveC1LinkExpiry(String time) {
    return 'Expires $time';
  }

  @override
  String get driveC1LinkExpiryAdd => 'Add expiry';

  @override
  String get driveC1LinkExpiryClear => 'Remove expiry';

  @override
  String get driveC1LinkExpiryCleared => 'Expiry removed';

  @override
  String get driveC1LinkExpiryEdit => 'Edit expiry';

  @override
  String get driveC1LinkExpiryNone => 'Never expires';

  @override
  String get driveC1LinkExpirySaved => 'Expiry saved';

  @override
  String get driveC1LinkPassword => 'Access password';

  @override
  String get driveC1LinkPasswordCleared => 'Access password cleared';

  @override
  String get driveC1LinkPasswordHint =>
      'Leave blank and save to require no password';

  @override
  String get driveC1LinkPasswordOn => 'Access password set';

  @override
  String get driveC1LinkPasswordSaved => 'Access password saved';

  @override
  String get driveC1Lock => 'Lock';

  @override
  String driveC1LockFailed(String error) {
    return 'Action failed: $error';
  }

  @override
  String get driveC1Locked => 'Locked';

  @override
  String get driveC1NewFileRequest => 'Request files';

  @override
  String get driveC1Notifications => 'Notifications';

  @override
  String get driveC1NotificationsCleared => 'Notifications cleared';

  @override
  String get driveC1NotificationsEmpty => 'No notifications';

  @override
  String get driveC1NotificationsEntry =>
      'Notifications for Drive upload and sync events';

  @override
  String get driveC1OriginalPath => 'Original location';

  @override
  String get driveC1ReopenRequest => 'Reopen';

  @override
  String get driveC1RequestClosed => 'Closed';

  @override
  String driveC1RequestCreated(String url) {
    return 'Request link created: $url';
  }

  @override
  String driveC1RequestDeleteBody(String name) {
    return 'The link for \"$name\" will stop working.';
  }

  @override
  String get driveC1RequestDeleteConfirm => 'Delete this file request link?';

  @override
  String get driveC1RequestDeleted => 'Deleted';

  @override
  String get driveC1RequestReopened => 'Reopened';

  @override
  String get driveC1RequestTitleHint => 'e.g. Homework submission';

  @override
  String get driveC1RequestUnlock => 'Request unlock';

  @override
  String driveC1RestoreOneFailed(String error) {
    return 'Restore failed: $error';
  }

  @override
  String get driveC1Restored => 'Restored';

  @override
  String driveC1RoleUpdated(String role) {
    return 'Role updated to \"$role\"';
  }

  @override
  String get driveC1TeamMembers => 'Team members';

  @override
  String get driveC1TeamMembersEmpty => 'No members visible';

  @override
  String get driveC1TeamMembersEntry =>
      'See who is in a team folder and what role each member has';

  @override
  String get driveC1TeamMembersPick => 'Pick a team folder to view its members';

  @override
  String get driveC1Unlock => 'Unlock';

  @override
  String get driveC1UnlockRequested => 'Unlock requested';

  @override
  String get driveC1Unlocked => 'Unlocked';

  @override
  String get driveG4LocalFilesListFailed => 'Failed to read the folder';

  @override
  String get driveGapEncryptedDoc => 'Encrypted document';

  @override
  String get driveGapEncryptedPassword => 'Password';

  @override
  String get driveGapEncryptedPasswordConfirm => 'Confirm password';

  @override
  String get driveGapEncryptedPasswordEmpty => 'Password cannot be empty';

  @override
  String get driveGapEncryptedPasswordMismatch => 'The passwords do not match';

  @override
  String get driveGapEncryptedPasswordTitle => 'Set document password';

  @override
  String get driveGapEncryptedSheet => 'Encrypted spreadsheet';

  @override
  String get driveGapEncryptedSlides => 'Encrypted presentation';

  @override
  String get driveGapEncryptedTemplate => 'New from template (encrypted)';

  @override
  String get driveGapNewEncrypted => 'New encrypted…';

  @override
  String get driveGapNewEncryptedHint =>
      'Document / spreadsheet / presentation / template · password required';

  @override
  String get driveGapNewFromTemplate => 'New from template…';

  @override
  String get driveGapNewFromTemplateHint =>
      'Start from the official template gallery';

  @override
  String get driveGapNewOfficeDoc => 'Synology Office document';

  @override
  String get driveGapNewOfficeDocHint =>
      'Online document, continue editing on any device';

  @override
  String get driveGapNewOfficeSheet => 'Synology Office spreadsheet';

  @override
  String get driveGapNewOfficeSheetHint =>
      'Online spreadsheet with formulas and collaboration';

  @override
  String get driveGapNewOfficeSlides => 'Synology Office presentation';

  @override
  String get driveGapNewOfficeSlidesHint =>
      'Online slides for presenting and collaborating';

  @override
  String driveGapOfficeNodeCreated(String name) {
    return 'Created \"$name\"';
  }

  @override
  String get driveGapOfficeNodeNoFolderId =>
      'Could not resolve the current folder; nothing was created';

  @override
  String get driveGapTemplateParentUnresolved =>
      'Could not locate the current folder; template creation cancelled';

  @override
  String get driveP0PasswordLabel => 'Password';

  @override
  String get driveP0PasswordSubmit => 'Open';

  @override
  String get driveP0PasswordWrong =>
      'The password is incorrect. Please try again.';

  @override
  String get fsC5Up => 'Up one level';

  @override
  String get fsGapSharePermanentEditNote =>
      'Editing from the official client does not send the \"remove expiry\" field (the link keeps its current expiry time);';

  @override
  String get imageEditSettingsEntry => 'AI Enhance (image-to-image)';

  @override
  String get imageEditSettingsEntryOff => 'Off (photos are not sent)';

  @override
  String imageEditSettingsEntryOn(String backend, String count) {
    return 'On · $backend · $count';
  }

  @override
  String get imageEditSettingsLoadFailed =>
      'Failed to load AI Enhance settings';

  @override
  String get imageEditSettingsPageIntro =>
      'This page configures only the photo AI Enhance (image-to-image) channel: selected photos are sent to the service URL you enter for redrawing, never through this app\'s servers.';

  @override
  String get imageEditSettingsSeparateNote =>
      'Independent from the large language model tiers under AI Service (cloud / on-device / built-in summary): changing the backend and quota here does not affect the model used for chat.';

  @override
  String get pbStructure => 'Organize into date folders';

  @override
  String get pbStructureNone =>
      'No date folders (none): all files go directly in the device folder';

  @override
  String get pbStructureYear => 'By year (year): device folder / 2026';

  @override
  String get pbStructureYearMonth =>
      'By year and month (official default): device folder / 2026 / 09';

  @override
  String get pbUploadQuality => 'Upload quality';

  @override
  String get pbUploadQualityHigh => 'High (2048 px long edge)';

  @override
  String get pbUploadQualityHint =>
      'Compression happens locally on the phone (originals are not compressed); HEIC/RAW/video are uploaded as-is';

  @override
  String get pbUploadQualityLow => 'Low (1280 px long edge)';

  @override
  String get pbUploadQualityMedium => 'Medium (1600 px long edge)';

  @override
  String get pbUploadQualityOriginal => 'Original';

  @override
  String get photoC2PhotoRequestCreate => 'New';

  @override
  String get photoC2PhotoRequestCreateHint =>
      'Create a link that lets outside guests upload without an account';

  @override
  String get photoC2PhotoRequestEdit => 'Edit photo request';

  @override
  String get photoC2PhotoRequestSaved => 'Photo request saved';

  @override
  String get photoP0ActionRemoveSmart => 'Remove from this scene';

  @override
  String get photoP0ActionSetCover => 'Set as cover';

  @override
  String get photoP0ActionShare => 'Send to';

  @override
  String get photoP0CoverSet => 'Cover updated';

  @override
  String get photoP0PersonRename => 'Rename person';

  @override
  String get photoP0PersonRenamed => 'Person renamed';

  @override
  String get photoP0RemoveSmartBody =>
      'Only affects this scene grouping; the photo itself is not deleted and remains visible in the timeline.';

  @override
  String get photoP0RemoveSmartConfirm =>
      'Remove the selected photos from this scene?';

  @override
  String get photoP0ShareDone => 'Handed off to the system share sheet';

  @override
  String get photoWave3CacheClear => 'Clear local cache';

  @override
  String get photoWave3CacheClearDesc =>
      'Clears only the image cache on this phone; photos on the NAS are not deleted and will be downloaded again next time.';

  @override
  String get photoWave3CacheLimit => 'Local cache limit';

  @override
  String get photoWave3CacheLocalReading => 'Measuring local cache…';

  @override
  String get common_cancel => 'Cancel';

  @override
  String get common_save => 'Save';

  @override
  String get deselectAll => 'Deselect all';

  @override
  String get driveCategoryEmpty => 'No files in this category yet';

  @override
  String get driveCategoryEmptyHint =>
      'Categories are grouped locally by file extension (same approach as the official Home category icons); only files in Recent are counted';

  @override
  String get driveCategoryEntry => 'Browse by category';

  @override
  String get driveCategoryError => 'Failed to load recent files';

  @override
  String get driveCategoryTitle => 'Browse by category';

  @override
  String get driveTaskDetailStale =>
      'Could not get the latest status; the values above are from the list snapshot';

  @override
  String get driveTaskFieldCreated => 'Created';

  @override
  String get driveTaskFieldErrors => 'Errors';

  @override
  String get driveTaskFieldFiles => 'Files';

  @override
  String get driveTaskFieldFinished => 'Finished';

  @override
  String get driveTaskFieldId => 'Task ID';

  @override
  String get driveTaskFieldMessage => 'Details';

  @override
  String get driveTaskFieldProgress => 'Progress';

  @override
  String get driveTaskFieldSize => 'Size';

  @override
  String get driveTaskFieldStatus => 'Status';

  @override
  String get driveTaskRemoveDoneBody =>
      'Only removes the record from the task list (Tasks/delete); files already transferred are not affected.';

  @override
  String get driveTaskRemoveDoneTitle => 'Remove this finished task?';

  @override
  String get driveTaskRemoveRunningBody =>
      'This task is still running. Tasks/delete only removes the record and does not stop the transfer on the server; to actually stop it, handle it at the source.';

  @override
  String get driveTaskRemoveRunningTitle => 'Remove this task from the list?';

  @override
  String get driveTaskStatusFailed => 'Failed';

  @override
  String get driveTaskStatusFinished => 'Finished';

  @override
  String get driveTaskStatusRunning => 'Running';

  @override
  String get driveTaskStatusUnknown => 'Unknown';

  @override
  String get drive_pdf_export => 'Export annotated PDF';

  @override
  String get drive_pdf_export_failed => 'Export failed';

  @override
  String get drive_pdf_highlight => 'Highlight';

  @override
  String get drive_pdf_ink => 'Handwriting / signature';

  @override
  String get drive_pdf_marks => 'annotations';

  @override
  String get drive_pdf_no_page => 'This PDF has no renderable pages';

  @override
  String get drive_pdf_no_text_layer =>
      'The text layer is unavailable on this page; highlighting by rectangle';

  @override
  String get drive_pdf_note => 'Note';

  @override
  String get drive_pdf_pages => 'pages';

  @override
  String get drive_pdf_render_failed => 'Rendering failed';

  @override
  String get drive_pdf_save_drive => 'Save to Drive';

  @override
  String get drive_pdf_saved_drive => 'Saved back to Drive';

  @override
  String get drive_pdf_saved_local => 'Exported';

  @override
  String get drive_pdf_undo => 'Undo last';

  @override
  String get drive_pdf_writeback =>
      'Write back to the original file (incremental update)';

  @override
  String get drive_pdf_writeback_failed => 'Write-back failed';

  @override
  String get drive_pdf_written_drive =>
      'Written back to the original file (new Drive version)';

  @override
  String get drive_pdf_written_local => 'Written back';

  @override
  String get drive_sync_add => 'New sync task';

  @override
  String get drive_sync_auto => 'Automatic sync';

  @override
  String get drive_sync_check => 'Check now';

  @override
  String get drive_sync_check_title => 'Sync check result';

  @override
  String get drive_sync_conflict => 'Conflicts';

  @override
  String get drive_sync_delete => 'Delete';

  @override
  String get drive_sync_download => 'To download';

  @override
  String get drive_sync_edit => 'Edit';

  @override
  String get drive_sync_empty =>
      'No sync tasks yet. Create one to compare a local folder with Drive.';

  @override
  String get drive_sync_execute => 'Run now';

  @override
  String get drive_sync_executed => 'Ran';

  @override
  String get drive_sync_failed => 'Failed';

  @override
  String get drive_sync_ignore_remove =>
      'Ignore local deletions (keep remote files)';

  @override
  String get drive_sync_interval => 'Interval';

  @override
  String get drive_sync_load_failed => 'Could not load sync tasks';

  @override
  String get drive_sync_local => 'Local folder';

  @override
  String get drive_sync_no_execute =>
      'Only differences are checked here: no files are moved and no background sync runs.';

  @override
  String get drive_sync_remote => 'Remote folder';

  @override
  String get drive_sync_remove => 'To delete';

  @override
  String get drive_sync_title => 'Sync tasks';

  @override
  String get drive_sync_upload => 'To upload';

  @override
  String get drive_sync_watch_no_native =>
      'Started watching local changes (while the app is alive); the system did not allow persistent background watching, so re-enable it after the app is killed';

  @override
  String get drive_sync_watch_ran => 'Automatic sync';

  @override
  String get drive_sync_watch_skip => 'Skip';

  @override
  String get drive_sync_watch_start => 'Watch local changes';

  @override
  String get drive_sync_watch_started =>
      'Started watching local changes (while the app is running in the foreground or background)';

  @override
  String get drive_sync_watch_stop => 'Stop watching';

  @override
  String get drive_sync_watch_stopped => 'Stopped watching';

  @override
  String get fsDownloadTaskSaveFailed =>
      'Failed to save to the system Downloads folder';

  @override
  String get fsDownloadTaskSaveOk =>
      'Saved to the system Downloads folder; find it in the system Files app';

  @override
  String get fsDownloadTaskSaveToLocal => 'Save to this device';

  @override
  String fsDownloadTaskSavedToPath(Object path) {
    return 'Saved to $path';
  }

  @override
  String get fsDownloadTaskSaveLocalFailed => 'Could not save to this computer';

  @override
  String get fsDownloadTaskSaveToDownloads => 'Save to system Downloads';

  @override
  String get fsDownloadTaskSaveUnsupported =>
      'This device does not support writing directly to the system Downloads folder';

  @override
  String get fsLocalPhotosEmpty => 'No photos found on this phone';

  @override
  String get fsLocalPhotosNeedPermission =>
      'Photo library permission is required to read local photos; grant it in system settings';

  @override
  String get fsLocalPhotosPickFailed => 'Failed to read local photos';

  @override
  String get fsLocalPhotosTitle => 'Upload local photos to the current folder';

  @override
  String fsLocalPhotosUploaded(String name) {
    return 'Uploaded $name';
  }

  @override
  String fsLocalPhotosUploading(String name) {
    return 'Uploading $name';
  }

  @override
  String get noteLeaveEncryptCancel => 'Cancel';

  @override
  String get noteLeaveEncryptOk => 'OK';

  @override
  String get officeDocEnterEdit => 'Edit';

  @override
  String get officeDocExitEdit => 'Finish editing (back to standard layout)';

  @override
  String get officeDocLayoutFallback =>
      'Could not read the standard Office format; switched to compatible layout. Font sizes, indents, and column widths may differ from the original.';

  @override
  String get officeDocNoContentHint =>
      'Write something in Synology Office / WPS / Microsoft Word and save it, then come back and pull to refresh.';

  @override
  String get officeDocNoteDismiss => 'Got it';

  @override
  String get officeDocOpenInOffice => 'Open in the official Office app';

  @override
  String get officeSlidesDeckHideThumbs => 'Hide slide list';

  @override
  String get officeSlidesDeckShowThumbs => 'Show slide list';

  @override
  String get selectAll => 'Select all';

  @override
  String selectedCount(String n) {
    return '$n selected';
  }

  @override
  String get sortResetOnError => 'Reset sorting to Default and retry';

  @override
  String aiBlockedModelsTitleUndetermined(int n) {
    return 'Models that can’t be verified on this device ($n)';
  }

  @override
  String get aiBlockedReasonUndetermined =>
      'Can’t verify whether it fits: this device’s hardware info is unavailable (no hardware probe on this platform), so the download is not started.';

  @override
  String get aiDeviceModelUnverifiable =>
      'Can’t verify whether this model fits this device; download cancelled';

  @override
  String get officeLoadErrNoLinkId =>
      'Can’t open this document: the server didn’t return its permanent link.';

  @override
  String get officeLoadErrNotConnected =>
      'Can’t open this document: not connected to the server.';

  @override
  String get officeLoadErrShape =>
      'Can’t open this document: the content format the server returned isn’t recognized. You can try “Read-only preview”.';

  @override
  String get officeLoadErrFetchAck =>
      'Can’t open this document: the server’s response was incomplete.';

  @override
  String get officeLoadErrNoObjectId =>
      'Can’t open this document: its internal document id is missing.';

  @override
  String fileUploadLocalPhotoFromDevice(String target) {
    return 'Pick a photo from this device’s gallery and upload it to \"$target\"';
  }

  @override
  String get passcodeReauthAlways => 'Ask every time';

  @override
  String passcodeReauthMinutes(int minutes) {
    return 'After $minutes minutes';
  }

  @override
  String mediaResumedFrom(String time) {
    return 'Resumed from $time';
  }

  @override
  String get mediaStartOver => 'Start over';

  @override
  String get trayShowMainWindow => 'Show main window';
}
