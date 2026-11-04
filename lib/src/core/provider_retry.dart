/// Riverpod 3 的 `FutureProvider` 会对**失败**做指数退避**自动重试**：
/// 源码 `riverpod-3.4.3/lib/src/core/provider_container.dart:983` 的
/// `defaultRetry` 只对 `Exception` 子类重试（最多 10 次，200ms→6.4s，
/// 累计二十余秒），对 `Error`（含 `StateError`）不重试。
///
/// 我们的网络 / API 层抛的是自定义 `Exception` ⇒ 只要不显式关掉，读取失败会被
/// 反复重试，界面在这期间一直停在骨架屏，等于"把失败渲染成空 / 无限转圈"。
/// 本项目的政策是**失败立刻可见、重试交给用户点按钮**（见
/// `docs/agent-batch-protocol.md` §1.8），所以凡是带失败态的 `FutureProvider`
/// 统一写 `retry: noRetry`。
///
/// 用法：`FutureProvider(..., retry: noRetry)`。
Duration? noRetry(int retryCount, Object error) => null;
