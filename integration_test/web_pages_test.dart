// Web 逐页深扫（r718）：把**零参数页面类**逐个真渲染一遍，每页抓一张像素。
//
// 为什么要有这个：`docs/web-page-coverage.md` 的实读是 **A=3 / U=160**，
// 因为 79 场场景像素没有"一场对一页"的账。这里换一种仪器：
// **直接构造页面 widget**（与 Windows 的 `windows_pages_test.dart` 同思路），
// 每页的判据是"真画出 Scaffold ＋ 可见 Text > 0"（空态/错误态也算渲染），
// 然后 `takeScreenshot` 存像素 —— 像素就是这一页的**存在性证据**。
//
// 跑法：
//   chromedriver --port=4444 &
//   flutter drive --driver=test_driver/web_shot_driver.dart \
//     --target=integration_test/web_pages_test.dart -d web-server --web-port=8133 \
//     --browser-name=chrome \
//     --web-browser-flag=--disable-web-security --web-browser-flag=--ignore-certificate-errors
//
// ★ 口径：本用例**不登录**、**不碰网络**（页面各自 provider 会走空/错误态），
//   所以它证明的是"这一页在 Web 上能构造、能画、不崩"，**不证明**"有数据"。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;
import 'package:synhub/src/core/i18n/l10n.dart';

import 'package:synhub/src/features/admin/admin_tools_page.dart';
import 'package:synhub/src/features/ai/ai_model_page.dart';
import 'package:synhub/src/features/ai/ai_usage_page.dart';
import 'package:synhub/src/features/analytics/analytics_page.dart';
import 'package:synhub/src/features/analytics/traffic_page.dart';
import 'package:synhub/src/features/audio/audio_cast_page.dart';
import 'package:synhub/src/features/audio/audio_page.dart';
import 'package:synhub/src/features/audio/audio_radio_page.dart';
import 'package:synhub/src/features/audio/audio_search_page.dart';
import 'package:synhub/src/features/calendar/calendar_page.dart';
import 'package:synhub/src/features/chat/available_channels_page.dart';
import 'package:synhub/src/features/chat/channel_create_page.dart';
import 'package:synhub/src/features/contacts/contacts_page.dart';
import 'package:synhub/src/features/design/design_preview_page.dart';
import 'package:synhub/src/features/downloads/download_bt_search_page.dart';
import 'package:synhub/src/features/downloads/download_captcha_page.dart';
import 'package:synhub/src/features/downloads/download_emule_search_page.dart';
import 'package:synhub/src/features/downloads/download_emule_server_page.dart';
import 'package:synhub/src/features/downloads/download_page.dart';
import 'package:synhub/src/features/downloads/download_rss_page.dart';
import 'package:synhub/src/features/drive/drive_category_page.dart';
import 'package:synhub/src/features/drive/drive_collection_page.dart';
import 'package:synhub/src/features/drive/drive_search_page.dart';
import 'package:synhub/src/features/files/drive_labels_page.dart';
import 'package:synhub/src/features/files/drive_saf_on_demand_page.dart';
import 'package:synhub/src/features/files/file_offline_page.dart';
import 'package:synhub/src/features/files/webdav_page.dart';
import 'package:synhub/src/features/home/home_page.dart';
import 'package:synhub/src/features/login/login_page.dart';
import 'package:synhub/src/features/mailplus/mail_compose_page.dart';
import 'package:synhub/src/features/mailplus/mail_page.dart';
import 'package:synhub/src/features/notes/note_adv_search_page.dart';
import 'package:synhub/src/features/notes/note_background_sync_page.dart';
import 'package:synhub/src/features/notes/note_conflict_page.dart';
import 'package:synhub/src/features/notes/note_fts_search_page.dart';
import 'package:synhub/src/features/notes/note_recycle_page.dart';
import 'package:synhub/src/features/notes/note_tag_page.dart';
import 'package:synhub/src/features/notes/note_todo_page.dart';
import 'package:synhub/src/features/notes/notes_page.dart';
import 'package:synhub/src/features/photos/photo_admin_page.dart';
import 'package:synhub/src/features/photos/photo_backup_page.dart';
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_free_up_page.dart';
import 'package:synhub/src/features/photos/photo_wave2_page.dart';
import 'package:synhub/src/features/photos/sleep_backup_page.dart';
import 'package:synhub/src/features/search/search_page.dart';
import 'package:synhub/src/features/servers/nas_manager_page.dart';
import 'package:synhub/src/features/servers/server_setup_page.dart';
import 'package:synhub/src/features/settings/notification_settings_page.dart';
import 'package:synhub/src/features/settings/profile_edit_page.dart';
import 'package:synhub/src/features/settings/snooze_settings_page.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';
import 'package:synhub/src/features/surveillance/surv_page.dart';
import 'package:synhub/src/features/chat/archive_page.dart';
import 'package:synhub/src/features/audio/audio_detail_page.dart';
import 'package:synhub/src/features/audio/audio_pins_page.dart';
import 'package:synhub/src/features/audio/audio_gaps_page.dart';
import 'package:synhub/src/features/audio/audio_remote_page.dart';
import 'package:synhub/src/features/audio/audio_web_queue_page.dart';
import 'package:synhub/src/features/settings/bots_page.dart';
import 'package:synhub/src/features/servers/certificates_page.dart';
import 'package:synhub/src/features/chat/channel_list_page.dart';
import 'package:synhub/src/features/contacts/contacts_manage_page.dart';
import 'package:synhub/src/features/diagnostics/diag_page.dart';
import 'package:synhub/src/features/downloads/download_create_page.dart';
import 'package:synhub/src/features/downloads/download_emule_page.dart';
import 'package:synhub/src/features/downloads/download_settings_page.dart';
import 'package:synhub/src/features/drive/drive_admin_page.dart';
import 'package:synhub/src/features/drive/drive_computers_page.dart';
import 'package:synhub/src/features/drive/drive_connections_page.dart';
import 'package:synhub/src/features/drive/drive_extras_page.dart';
import 'package:synhub/src/features/drive/drive_file_request_page.dart';
import 'package:synhub/src/features/files/drive_more_page.dart';
import 'package:synhub/src/features/drive/drive_notifications_page.dart';
import 'package:synhub/src/features/drive/drive_quota_page.dart';
import 'package:synhub/src/features/drive/drive_sync_tasks_page.dart';
import 'package:synhub/src/features/files/drive_tasks_page.dart';
import 'package:synhub/src/features/drive/drive_team_members_page.dart';
import 'package:synhub/src/features/drive/drive_team_trash_page.dart';
import 'package:synhub/src/features/drive/drive_trash_page.dart';
import 'package:synhub/src/features/settings/e2ee_page.dart';
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/features/files/file_mount_page.dart';
import 'package:synhub/src/features/chat/global_content_page.dart';
import 'package:synhub/src/features/search/global_search_page.dart';
import 'package:synhub/src/features/notes/note_drawing_page.dart';
import 'package:synhub/src/features/notes/note_editor_page.dart';
import 'package:synhub/src/features/notes/note_joined_page.dart';
import 'package:synhub/src/features/notes/note_overdue_settings_page.dart';
import 'package:synhub/src/features/notes/note_shared_page.dart';
import 'package:synhub/src/features/notes/note_shelf_page.dart';
import 'package:synhub/src/features/notes/note_shortcut_page.dart';
import 'package:synhub/src/features/notes/note_smart_page.dart';
import 'package:synhub/src/features/notes/note_todo_editor_page.dart';
import 'package:synhub/src/features/settings/oem_keepalive_page.dart';
import 'package:synhub/src/features/office/office_library_page.dart';
import 'package:synhub/src/features/settings/personal_profile_page.dart';
import 'package:synhub/src/features/photos/photo_ai_edit_settings_page.dart';
import 'package:synhub/src/features/photos/photo_wave3_page.dart';
import 'package:synhub/src/features/photos/photo_background_tasks_page.dart';
import 'package:synhub/src/features/photos/photo_c2_page.dart';
import 'package:synhub/src/features/photos/photo_map_page.dart';
import 'package:synhub/src/features/photos/photo_migration_page.dart';
import 'package:synhub/src/features/photos/photo_recent_page.dart';
import 'package:synhub/src/features/settings/service_check_page.dart';
import 'package:synhub/src/features/settings/settings_page.dart';
import 'package:synhub/src/features/files/usb_devices_page.dart';
import 'package:synhub/src/features/chat/channel_hashtags_page.dart';
import 'package:synhub/src/features/chat/channel_media_page.dart';
import 'package:synhub/src/features/chat/channel_members_page.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/contacts/contact_editor_page.dart';
import 'package:synhub/src/features/contacts/contact_import_page.dart';
import 'package:synhub/src/features/downloads/download_detail_page.dart';
import 'package:synhub/src/features/downloads/download_file_select_page.dart';
import 'package:synhub/src/features/drive/drive_local_files_page.dart';
import 'package:synhub/src/features/drive/drive_scan_page.dart';
import 'package:synhub/src/features/mailplus/mail_detail_page.dart';
import 'package:synhub/src/features/files/office_page.dart';
import 'package:synhub/src/features/chat/read_status_page.dart';
import 'package:synhub/src/features/chat/channel_scheduled_page.dart';
import 'package:synhub/src/features/chat/subscribed_threads_page.dart';
import 'package:synhub/src/features/surveillance/surv_camera_page.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/drive_revisions_page.dart';
import 'package:synhub/src/features/files/drive_share_page.dart';
import 'package:synhub/src/features/office/office_doc_page.dart';
import 'package:synhub/src/data/dto/drive_collection_dto.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/data/dto/drive_label_dto.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/features/audio/audio_song_page.dart';
import 'package:synhub/src/features/chat/channel_content_page.dart';
import 'package:synhub/src/features/drive/drive_advance_sharing_page.dart';
import 'package:synhub/src/features/drive/drive_copy_move_page.dart';
import 'package:synhub/src/features/drive/drive_folder_page.dart';
import 'package:synhub/src/features/drive/drive_pdf_markup_page.dart';
import 'package:synhub/src/features/notes/note_share_page.dart';
import 'package:synhub/src/features/notes/note_view_page.dart';
import 'package:synhub/src/features/office/office_sheet_page.dart';
import 'package:synhub/src/features/office/office_slides_page.dart';
import 'package:synhub/src/features/chat/thread_page.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/features/drive/drive_text_editor_page.dart';
import 'dart:typed_data';

/// 零参数页面清单（由 `tool/web_page_coverage.py` 同源的类名枚举得出）。
/// r719 批次②：给"构造时必须给对象"的页面一个**最小夹具**。
/// 只填必填字段，值都是假数据 —— 这些页在无会话下会走空态/错误态，判据仍只是
/// "构造得出来、画得出、不崩"。
DriveEntryDto _driveEntry() => const DriveEntryDto(
      fileId: '1',
      name: 'a.odoc',
      type: 'file',
      path: '/a.odoc',
      displayPath: '/mydrive/a.odoc',
      parentId: '0',
      size: 1024,
      modifiedTime: 1700000000,
      createdTime: 1700000000,
      contentType: 'application/octet-stream',
      starred: false,
      shared: false,
      owner: 'mock',
      canDownload: true,
      canPreview: true,
      canWrite: true,
      capabilities: <String, dynamic>{},
    );

DriveCollectionDto _collection() => const DriveCollectionDto(
      collectionId: '1',
      name: 'C',
      type: 'document_folder',
      color: '#888888',
      position: 0,
      fileCount: 0,
    );

DriveLabelDto _label() => const DriveLabelDto(
      labelId: '1',
      name: 'L',
      color: '#888888',
      position: 0,
      type: 'label',
    );

/// r719 批次③：笔记/相册的 DTO 最小夹具（只填必填字段）。
NotebookDto _notebook() => const NotebookDto(objectId: '1', title: 'NB');
NoteDto _note() => const NoteDto(objectId: '1', title: 'N');
SmartNotebookDto _smart() => const SmartNotebookDto(objectId: '1', title: 'S');
FotoItemDto _photo() => const FotoItemDto(id: '1', filename: 'a.jpg');

final List<(String, Widget Function())> _pages = [
      ('AdminToolsPage', () => const AdminToolsPage()),
      ('AiModelPage', () => const AiModelPage()),
      ('AiUsagePage', () => const AiUsagePage()),
      ('AudioCastPage', () => const AudioCastPage()),
      ('AudioPage', () => const AudioPage()),
      ('AudioRadioSearchPage', () => const AudioRadioSearchPage()),
      ('AudioSearchPage', () => const AudioSearchPage()),
      ('AvailableChannelsPage', () => const AvailableChannelsPage()),
      ('CalendarPage', () => const CalendarPage()),
      ('ChannelCreatePage', () => const ChannelCreatePage()),
      ('ContactsPage', () => const ContactsPage()),
      ('DesignPreviewPage', () => const DesignPreviewPage()),
      ('DownloadBtSearchPage', () => const DownloadBtSearchPage()),
      ('DownloadCaptchaPage', () => const DownloadCaptchaPage()),
      ('DownloadEmuleSearchPage', () => const DownloadEmuleSearchPage()),
      ('DownloadEmuleServerPage', () => const DownloadEmuleServerPage()),
      ('DownloadPage', () => const DownloadPage()),
      ('DownloadRssPage', () => const DownloadRssPage()),
      ('DriveBrowseTab', () => const DriveBrowseTab()),
      ('DriveCategoryPage', () => const DriveCategoryPage()),
      ('DriveCollectionPage', () => const DriveCollectionPage()),
      ('DriveLabelsPage', () => const DriveLabelsPage()),
      ('DriveSafOnDemandBody', () => const DriveSafOnDemandBody()),
      ('DriveSearchPage', () => const DriveSearchPage()),
      ('FileOfflinePage', () => const FileOfflinePage()),
      ('HomePage', () => const HomePage()),
      ('LoginPage', () => const LoginPage()),
      ('MailComposePage', () => const MailComposePage()),
      ('MailPage', () => const MailPage()),
      ('NasManagerPage', () => const NasManagerPage()),
      ('NoteAdvSearchPage', () => const NoteAdvSearchPage()),
      ('NoteBackgroundSyncPage', () => const NoteBackgroundSyncPage()),
      ('NoteConflictPage', () => const NoteConflictPage()),
      ('NoteFtsSearchPage', () => const NoteFtsSearchPage()),
      ('NoteRecyclePage', () => const NoteRecyclePage()),
      ('NoteTagPage', () => const NoteTagPage()),
      ('NoteTodoPage', () => const NoteTodoPage()),
      ('NotesPage', () => const NotesPage()),
      ('NotificationSettingsPage', () => const NotificationSettingsPage()),
      ('PhotoAdminPage', () => const PhotoAdminPage()),
      ('PhotoBackupPage', () => const PhotoBackupPage()),
      ('PhotoBrowsePage', () => const PhotoBrowsePage()),
      ('PhotoFreeUpSpacePage', () => const PhotoFreeUpSpacePage()),
      ('PhotoPersonsPage', () => const PhotoPersonsPage()),
      ('ProfileEditPage', () => const ProfileEditPage()),
      ('ScheduleSnoozePage', () => const ScheduleSnoozePage()),
      ('SearchPage', () => const SearchPage()),
      ('ServerSetupPage', () => const ServerSetupPage()),
      ('SleepBackupPage', () => const SleepBackupPage()),
      ('SnoozeSettingsPage', () => const SnoozeSettingsPage()),
      ('SurveillancePage', () => const SurveillancePage()),
      ('TrafficPage', () => const TrafficPage()),
      ('UsageAnalyticsPage', () => const UsageAnalyticsPage()),
      ('WebDavPage', () => const WebDavPage()),
      ('WorkspaceTab', () => const WorkspaceTab()),
      ('AppShellPage', () => const AppShellPage()),
      ('ArchivePage', () => const ArchivePage()),
      // 无无名构造：用专辑详情这一支（空名字 ⇒ 空态，仍然要能画）
      ('AudioDetailPage', () => const AudioDetailPage.album(name: '')),
      ('AudioPinsPage', () => const AudioPinsPage()),
      ('AudioRadioPage', () => const AudioRadioPage()),
      ('AudioRandom100Page', () => const AudioRandom100Page()),
      ('AudioRecentlyAddedPage', () => const AudioRecentlyAddedPage()),
      ('AudioRemotePage', () => const AudioRemotePage()),
      ('AudioWebQueuePage', () => const AudioWebQueuePage()),
      ('BotsPage', () => const BotsPage()),
      ('CertificatesPage', () => const CertificatesPage()),
      ('ChannelListPage', () => const ChannelListPage()),
      ('ContactsManagePage', () => const ContactsManagePage()),
      ('DiagPage', () => const DiagPage()),
      ('DownloadCreatePage', () => const DownloadCreatePage()),
      ('DownloadEmulePage', () => const DownloadEmulePage()),
      ('DownloadSettingsPage', () => const DownloadSettingsPage()),
      ('DriveAdminPage', () => const DriveAdminPage()),
      ('DriveComputersPage', () => const DriveComputersPage()),
      ('DriveConnectionsPage', () => const DriveConnectionsPage()),
      ('DriveExtrasPage', () => const DriveExtrasPage()),
      ('DriveFileRequestPage', () => const DriveFileRequestPage()),
      ('DriveMorePage', () => const DriveMorePage()),
      ('DriveNotificationsPage', () => const DriveNotificationsPage()),
      ('DriveQuotaPage', () => const DriveQuotaPage()),
      ('DriveSyncTasksPage', () => const DriveSyncTasksPage()),
      ('DriveTasksPage', () => const DriveTasksPage()),
      ('DriveTeamMembersPage', () => const DriveTeamMembersPage()),
      ('DriveTeamTrashPage', () => const DriveTeamTrashPage()),
      ('DriveTrashPage', () => const DriveTrashPage()),
      ('E2eePage', () => const E2eePage()),
      ('FileBrowsePage', () => const FileBrowsePage()),
      ('FileMountPage', () => const FileMountPage()),
      ('GlobalContentPage', () => const GlobalContentPage()),
      ('GlobalSearchPage', () => const GlobalSearchPage()),
      ('NoteDrawingPage', () => const NoteDrawingPage()),
      ('NoteEditorPage', () => const NoteEditorPage()),
      ('NoteJoinedPage', () => const NoteJoinedPage()),
      ('NoteOverdueSettingsPage', () => const NoteOverdueSettingsPage()),
      ('NoteSharedPage', () => const NoteSharedPage()),
      ('NoteShelfPage', () => const NoteShelfPage()),
      ('NoteShortcutPage', () => const NoteShortcutPage()),
      ('NoteSmartPage', () => const NoteSmartPage()),
      ('NoteTodoEditorPage', () => const NoteTodoEditorPage()),
      ('OemKeepalivePage', () => const OemKeepalivePage()),
      ('OfficeTemplateLibraryPage', () => const OfficeTemplateLibraryPage()),
      ('PersonalProfilePage', () => const PersonalProfilePage()),
      ('PhotoAiEditSettingsPage', () => const PhotoAiEditSettingsPage()),
      ('PhotoAlbumSettingsPage', () => const PhotoAlbumSettingsPage()),
      ('PhotoBackgroundTasksPage', () => const PhotoBackgroundTasksPage()),
      ('PhotoC2Page', () => const PhotoC2Page()),
      ('PhotoMapPage', () => const PhotoMapPage()),
      ('PhotoMigrationPage', () => const PhotoMigrationPage()),
      ('PhotoRecentlyAddedPage', () => const PhotoRecentlyAddedPage()),
      ('PhotoTagsPage', () => const PhotoTagsPage()),
      ('ServiceCheckPage', () => const ServiceCheckPage()),
      ('SettingsPage', () => const SettingsPage()),
      ('UsbDevicesPage', () => const UsbDevicesPage()),
      ('AudioPlayedPage', () => const AudioPlayedPage(mode: AudioPlayedMode.recently)),
      ('ChannelHashtagsPage', () => const ChannelHashtagsPage(channelId: 1)),
      ('ChannelMediaPage', () => const ChannelMediaPage(channelId: 1)),
      ('ChannelMembersPage', () => const ChannelMembersPage(channelId: 1)),
      ('ChatPage', () => const ChatPage(channelId: 1)),
      ('ContactEditorPage', () => const ContactEditorPage(addressbookId: '1')),
      ('ContactImportPage', () => const ContactImportPage(books: [])),
      ('DownloadDetailPage', () => const DownloadDetailPage(taskId: '1')),
      ('DownloadFileSelectPage', () => const DownloadFileSelectPage(listId: '1')),
      ('DownloadRssFeedPage', () => const DownloadRssFeedPage(title: 'rss')),
      ('DriveLocalFilesPage', () => const DriveLocalFilesPage(targetDrivePath: '/mydrive')),
      ('DriveScanPage', () => const DriveScanPage(folderId: '1')),
      ('MailDetailPage', () => const MailDetailPage(threadId: '1')),
      ('OfficePage', () => const OfficePage(title: 'doc')),
      ('ReadStatusPage', () => const ReadStatusPage(postId: 1)),
      ('RemindersPage', () => const RemindersPage(channelId: 1)),
      ('ScheduledMessagesPage', () => const ScheduledMessagesPage(channelId: 1)),
      ('SubscribedThreadsPage', () => const SubscribedThreadsPage(channelId: 1)),
      ('SurvCameraPage', () => const SurvCameraPage(cameraId: 1)),
      ('PhotoAlbumItemsPage', () => PhotoAlbumItemsPage(album: FotoAlbumDto(id: '1', name: 'A'))),
      ('PhotoFolderPage', () => PhotoFolderPage(folder: FotoFolderDto(id: '1', name: 'F'))),
      ('PhotoTagDetailPage', () => PhotoTagDetailPage(tag: FotoTagDto(id: '1', name: 't'))),
      // 空 items 会让查看器在本页断言失败（r719 实测），给一张最小照片
      ('PhotoViewerPage', () => PhotoViewerPage(items: [_photo()])),
      ('FilePreviewPage', () => FilePreviewPage(entry: FileEntryDto(name: 'a.txt', path: '/a.txt'))),
      ('DriveRevisionsPage', () => DriveRevisionsPage(entry: _driveEntry())),
      ('DriveSharePage', () => DriveSharePage(entry: _driveEntry())),
      ('DriveCollectionFilesPage', () => DriveCollectionFilesPage(collection: _collection())),
      ('DriveLabelledPage', () => DriveLabelledPage(label: _label())),
      ('OfficeThemesPage', () => OfficeThemesPage(entry: _driveEntry())),
      ('OfficeVersionsReadOnlyPage', () => OfficeVersionsReadOnlyPage(entry: _driveEntry())),
      ('OfficeDocPage', () => OfficeDocPage(request: OfficeDocRequest(fileId: '1', name: 'a.odoc'))),
      ('AudioSongDetailPage', () => const AudioSongDetailPage(songId: '1', title: 'Song')),
      ('ChannelContentPage', () => const ChannelContentPage(channelId: 1, kind: ChannelContentKind.pinned)),
      ('DriveAdvanceSharingPage', () => const DriveAdvanceSharingPage(path: '/mydrive/a.txt', entryName: 'a.txt')),
      ('DriveCopyMovePage', () => DriveCopyMovePage(entries: [_driveEntry()], move: false)),
      ('DriveFolderPage', () => const DriveFolderPage(rootFileId: '1', title: 'F')),
      ('DriveFolderTrashPage', () => const DriveFolderTrashPage(folderId: '1', folderName: 'F')),
      ('DrivePdfMarkupPage', () => DrivePdfMarkupPage(filePath: '/a.pdf', fileName: 'a.pdf', bytes: Uint8List(0))),
      ('DriveTeamMemberListPage', () => const DriveTeamMemberListPage(teamId: '1', teamName: 'T')),
      ('NoteJoinedNotebookPage', () => NoteJoinedNotebookPage(notebook: _notebook())),
      ('NoteSharePage', () => NoteSharePage(note: _note())),
      ('NoteSmartNotesPage', () => NoteSmartNotesPage(smart: _smart())),
      ('NoteViewPage', () => NoteViewPage(note: _note())),
      ('OfficeSheetPage', () => const OfficeSheetPage(request: OfficeSheetRequest(fileId: '1', name: 'a.osheet'))),
      ('OfficeSlidesPage', () => const OfficeSlidesPage(request: OfficeSlidesRequest(fileId: '1', name: 'a.oslides'))),
      ('PhotoPersonAlbumPage', () => const PhotoPersonAlbumPage(personId: '1', name: 'P')),
      ('PhotoSmartAlbumPage', () => const PhotoSmartAlbumPage(kind: PhotoSmartAlbumKind.person, id: '1', title: 'P')),
      ('ThreadPage', () => const ThreadPage(channelId: 1, parentPostId: 1)),
      ('DriveTextEditorPage',
          () => DriveTextEditorPage(
                title: 'a.txt',
                loadText: () async => '',
                saveText: (v) async {},
              )),
];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Web 零参数页面逐页真渲染', (tester) async {
    final ok = <String>[];
    final bad = <String>[];
    for (final (name, build) in _pages) {
      try {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: const [
                AppText.delegate,
                FlutterQuillLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: {
                ...AppText.supportedLocales,
                ...FlutterQuillLocalizations.supportedLocales,
              }.toList(),
              home: build(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        final ex = tester.takeException();
        final scaffolds = find.byType(Scaffold).evaluate().length;
        final texts = find.byType(Text).evaluate().length;
        if (ex != null) {
          bad.add('$name: 构造/渲染异常 ${'$ex'.split('\n').first}');
        } else if (scaffolds == 0) {
          bad.add('$name: 没有 Scaffold（白屏）');
        } else if (texts == 0) {
          bad.add('$name: 可见 Text = 0');
        } else {
          ok.add(name);
          await binding.takeScreenshot('p_$name');
        }
      } catch (e) {
        bad.add('$name: ${'$e'.split('\n').first}');
      }
    }
    debugPrint('[pages] OK ${ok.length} / ${_pages.length}');
    for (final b in bad) {
      debugPrint('[pages] BAD $b');
    }
    debugPrint('[pages] OK_LIST ${ok.join(",")}');
  });
}
