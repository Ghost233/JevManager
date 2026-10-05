# 2026-10-05 本机交付核对

对应规格 #10 和交付工单 #20。以下分别记录真实公网/文件系统、容器替身测试、Mac 原生应用与 Codex 客户端证据；不互相替代。

| 范围 | 证据 | 已验证的结果 |
| --- | --- | --- |
| 任意 HF 搜索与固定版本 | [HF 搜索](hf-search.md) | 实际关键词/仓库 API、固定 revision、缓存与失败状态 |
| 模型包及内部文件解析 | [模型包](model-package-live.md) | 选择包与变体，不逐文件勾选；必要文件由内部解析 |
| 下载、共享目录及来源 | [下载](model-download-live.md)、[最新桌面](desktop-ui-revision.md) | Kev/Laya 实际完整权重与全量哈希；共享目录文件复用；设置在任务创建时固定 |
| 本地识别与删除保护 | [模型库](model-library-live.md) | 实际文件识别/全量指纹，确认准确删除范围，取消及在用保护 |
| 管理与实际引擎选择 | [职责修订](ui-flow-redesign.md)、[原生引擎](official-provider-live.md) | 安装与关联不等于兼容；在模型库运行弹窗选择真实登记的引擎 |
| 两席并发与综合 | [真实委员会](council-live.md)、[失败](council-failures-live.md) | 同一请求并发派发，保留真实概率/原始输出，平均及分歧；截止/失败不伪造意见 |
| Codex MCP | [客户端](codex-mcp-live.md)、[桌面生命周期](manager-lifecycle-live.md) | 真正发现、调用及回复使用结果；GUI 与客户端共用同一实例 PID |
| 关窗、重开与退出 | [生命周期](manager-lifecycle-live.md)、[公开摘要](results/gui-lifecycle.json) | 关窗后原客户端及新 Codex 调用，重开同一 PID，明确退出无受管进程或 MCP 遗留；LM Studio 原服务保留 |
| 中文对照与资源 | [中文基准](chinese-benchmark.md)、[原始结果](../../benchmarks/results/2026-10-05/chinese.jsonl) | 两真实模型与综合同一 12 案例，冷热、分位数与 RSS 口径分别记录 |

## 运行与已知限制

- 标准 Flutter macOS 本机 `.app`，SDK 位于 `~/flutter` 和 `~/dart`，Release 不启用 App Sandbox。`./scripts/run-desktop.sh` 构建并打开；应先明确退出正在运行的同一路径应用，再重编译，避免替换其正在使用的 framework。
- 下载来源、模型存放路径只在设置编辑。现有目录为 `/Users/ghost233/.lmstudio/models`。没有自动移动、改名、覆盖或清空共享模型；没有训练。
- 当前 LM Studio 2.50.0 内置标准 llama-server 可关联，实际 Kev 与 Laya 的 typed-head 加载不兼容，准确失败；本机成功组合使用官方 b11381。模型和引擎组合必须实际准入，不能由 GGUF 或安装来源推断。
- HF 完整权重下载与独立全量哈希已测；代理的小文件、真实大权重传输及 Range 续传已测。最后补齐了 [代理完整 Laya 模型包](proxy-package-live.md)：449,397,600 bytes 经生产下载器实际传输到全新空目录，独立读回 SHA 与固定元数据一致，未复用已有文件。
- Kev 中文合成案例 12/12，Laya 8/12，等权综合 11/12。综合本轮弱于 Kev；这些不是训练集、真实业务、泛化、校准或独立性收益证据。
- 冷启动指新进程至 typed-ready，包含资产重核验；热样本各 12 次。RSS 是 Darwin 进程驻留页采样，不是绝对峰值、GPU 分配或机器总内存，后者未测。
- Codex CLI 0.160.0 的真实调用已验证；当前 Codex 桌面聊天的配置热导入未验证。接入配置可从 MCP 页复制，客户端自身审批规则仍有效。
- 未进行 App Store、分发签名、公证、公开发布、云托管或额外桌面平台。

## 最终检查门槛

UI 修订后 109 项容器测试通过（run-HI2Sb7），Mac release 构建通过（46.2 MB），实际桌面验收包含搜索灰度、设置入口、任务页职责、引擎管理、运行选项、两模型启动与完整生命周期。

工作区新增工程规范及 lint 后发现的 125 项 info（包括 benchmark 导入）及格式化后暴露的 63 项均已修复。随后从真实 Widget 复现并修复运行弹窗 Escape 与最小窗口放大文字的侧栏溢出。

冻结前最终 format 53 文件零改动（run-Jt01Q4），完整 analyze 零诊断（run-HEPjLb），143 项测试通过（run-Nhi8KD），其中 34 个生产页面/弹窗/shell 布局与交互病例。独立 [布局记录](desktop-layout.md) 明确区分 Linux QA 字体渲染与 Mac 原生外观。最新原生 release 编译通过（46.2 MB），未使用 prototype_main.dart 作为入口。

三份独立审查及 Git 本地/远端最终状态需在交付前补齐。本页不提前宣称这些门槛已通过。

历史 `.scratch` 迁移来源按其 manifest 的原字节保留，不为消除旧 Markdown 的末尾空行而改变来源哈希。提交空白检查覆盖正式源码、测试、脚本和当前文档，排除这些冻结的历史来源；Dart 格式与静态检查仍覆盖全部 lib/test/benchmarks。
