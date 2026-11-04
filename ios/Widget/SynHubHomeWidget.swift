// SynHub 主屏小组件（WidgetKit · r688）。
//
// ## 它做什么
//
// 把 App 已经算好的「工作台快照」显示在主屏上：小号 = 四个快捷入口；
// 中号 = 快捷入口 ＋ 笔记/待办计数；大号 = 再加一行「最近一条笔记」。
//
// ## 数据从哪来（这条链路是 iOS 与 Android 最大的不同）
//
// Android 的小组件进程与 App 共享文件系统，直接读 `WidgetSnapshotStore` 落的
// JSON 就算完事。iOS 的扩展是**另一个进程**，只能看 App Group 的
// `UserDefaults` ⇒ 本仓库的约定：
//
//   * App 侧（`ios/Runner/WidgetBridge.swift`）把 Dart 传来的快照 JSON 写进
//     `UserDefaults(suiteName: "group.com.openviewai.synhub.ios")` 的 `snapshot` 键，
//     然后 `WidgetCenter.shared.reloadAllTimelines()`；
//   * 扩展侧（本文件）只读同一个 suite 的同一个键，绝不自己发网络请求
//     （扩展跑在极短的时间窗里，且没有 App 的登录态）。
//
// ## 为什么点击落点是**专用 scheme**
//
// Android 那边用显式 Intent（`ACTION_OPEN`），刻意不蹭 `synochat://` 那四条官方
// 深链的语义。iOS 的等价物是 `.widgetURL(URL)`：这里用 `synhubwidget://open?target=…`，
// 由 `ios/Runner/WidgetBridge.swift` 解析 —— **复用它会把"登录到某台 NAS"的语义
// 污染成"打开某个 tab"**，那正是 Android 侧文件头里写下的那条教训。
//
// ## 验过的部分与没验的部分（诚实分界）
//
// * 验过：扩展随包编译、`PlugIns/SynHubWidget.appex` 在产物里、App 侧真的把快照
//   写进 App Group、`reloadAllTimelines` 不报错（见 `docs/platform-ios.md` §26）；
// * **没验**：把小组件拖到主屏、以及系统何时刷新时间线 —— 这两步需要手指在模拟器/
//   真机上操作，无头模拟器给不出（`simctl` 没有"加小组件"的 verb）。

import SwiftUI
import WidgetKit

/// 快照里的一项快捷入口。
struct SynHubShortcut: Codable, Identifiable {
  let id: String
  let title: String
  let symbol: String
}

/// App 写进 App Group 的整份快照。
struct SynHubSnapshot: Codable {
  var noteCount: Int = 0
  var todoCount: Int = 0
  var recentNoteTitle: String = ""
  var shortcuts: [SynHubShortcut] = []
  /// 由 App 写入的生成时刻（秒）；0 = 还没有快照。
  var updatedAt: Double = 0

  static let empty = SynHubSnapshot()

  /// 默认的四个入口（与 Android `QuickstartWidgetProvider` 的四格一致）。
  static let defaultShortcuts: [SynHubShortcut] = [
    SynHubShortcut(id: "notes", title: "笔记", symbol: "note.text"),
    SynHubShortcut(id: "files", title: "文件", symbol: "folder"),
    SynHubShortcut(id: "photos", title: "相册", symbol: "photo"),
    SynHubShortcut(id: "chat", title: "聊天", symbol: "bubble.left"),
  ]
}

enum SynHubWidgetStore {
  /// ★ 必须与 `ios/Runner/Runner.entitlements` / `Widget.entitlements` 里的
  /// `com.apple.security.application-groups` 逐字一致，也必须与
  /// `ios/Runner/WidgetBridge.swift` 的 `suiteName` 一致。
  static let appGroup = "group.com.openviewai.synhub.ios"
  static let snapshotKey = "snapshot"

  static func load() -> SynHubSnapshot {
    guard
      let raw = UserDefaults(suiteName: appGroup)?.string(forKey: snapshotKey),
      let data = raw.data(using: .utf8),
      let snap = try? JSONDecoder().decode(SynHubSnapshot.self, from: data)
    else {
      return .empty
    }
    return snap
  }
}

struct SynHubEntry: TimelineEntry {
  let date: Date
  let snapshot: SynHubSnapshot
}

struct SynHubProvider: TimelineProvider {
  func placeholder(in context: Context) -> SynHubEntry {
    SynHubEntry(date: Date(), snapshot: .empty)
  }

  func getSnapshot(in context: Context, completion: @escaping (SynHubEntry) -> Void) {
    completion(SynHubEntry(date: Date(), snapshot: SynHubWidgetStore.load()))
  }

  func getTimeline(
    in context: Context, completion: @escaping (Timeline<SynHubEntry>) -> Void
  ) {
    let entry = SynHubEntry(date: Date(), snapshot: SynHubWidgetStore.load())
    // 半小时一次兜底；App 每次 `reloadAllTimelines()` 会立刻重取（见文件头）。
    let next = Date().addingTimeInterval(30 * 60)
    completion(Timeline(entries: [entry], policy: .after(next)))
  }
}

struct SynHubWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: SynHubEntry

  private var shortcuts: [SynHubShortcut] {
    entry.snapshot.shortcuts.isEmpty
      ? SynHubSnapshot.defaultShortcuts : entry.snapshot.shortcuts
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "sparkles").font(.caption)
        Text("星枢").font(.caption.bold())
        Spacer()
        if entry.snapshot.noteCount > 0 {
          Text("\(entry.snapshot.noteCount) 条笔记").font(.caption2).foregroundStyle(.secondary)
        }
      }
      if family == .systemSmall {
        shortcutGrid(columns: 2, limit: 4, iconSize: 20)
      } else {
        shortcutGrid(columns: 4, limit: 4, iconSize: 22)
        HStack(spacing: 12) {
          counter("待办", entry.snapshot.todoCount)
          counter("笔记", entry.snapshot.noteCount)
        }
        if family == .systemLarge, !entry.snapshot.recentNoteTitle.isEmpty {
          Text(entry.snapshot.recentNoteTitle)
            .font(.caption2)
            .lineLimit(1)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(12)
    .widgetURL(URL(string: urlForFamily()))
  }

  private func counter(_ title: String, _ value: Int) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(value)").font(.headline)
      Text(title).font(.caption2).foregroundStyle(.secondary)
    }
  }

  private func shortcutGrid(columns: Int, limit: Int, iconSize: CGFloat) -> some View {
    let items = Array(shortcuts.prefix(limit))
    return LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns),
      spacing: 8
    ) {
      ForEach(items) { item in
        VStack(spacing: 3) {
          Image(systemName: item.symbol).font(.system(size: iconSize))
          Text(item.title).font(.caption2).lineLimit(1)
        }
      }
    }
  }

  /// 点击落点：`target` 与 Dart 侧 `parseWidgetTarget` 认识的取值一致。
  private func urlForFamily() -> String {
    switch family {
    case .systemSmall: return "synhubwidget://open?target=quickstart"
    case .systemLarge: return "synhubwidget://open?target=home"
    default: return "synhubwidget://open?target=home"
    }
  }
}

struct SynHubHomeWidget: Widget {
  let kind = "SynHubHomeWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: SynHubProvider()) { entry in
      if #available(iOS 17.0, *) {
        SynHubWidgetView(entry: entry)
          .containerBackground(.fill.tertiary, for: .widget)
      } else {
        SynHubWidgetView(entry: entry)
          .padding()
          .background(Color(.secondarySystemBackground))
      }
    }
    .configurationDisplayName("星枢工作台")
    .description("快捷入口与笔记/待办计数。")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

@main
struct SynHubWidgetBundle: WidgetBundle {
  var body: some Widget {
    SynHubHomeWidget()
  }
}
