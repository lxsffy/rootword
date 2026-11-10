---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: d08810df37746fbf6c9181f5580a2793_304e5991cf1611f19f8752540064ee0f
    ReservedCode1: W+dVkbq9OrenZt1L71iLSMeWOjXSgALEj2WbJ7HZ6rNq2Q2oDY6X6IpgARibWtSMYDtIMAhN/WcB1TsMn4XTOOZwu5ymehDQSDZq+hHTr7KCAA5++ab2OQMqMHLJVV6UdQXyWSM6rsLKGVuo7cSMxiKbPBUZNBXY6N/lpEWamY3MaaofKLr/vwKbc/I=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: d08810df37746fbf6c9181f5580a2793_304e5991cf1611f19f8752540064ee0f
    ReservedCode2: W+dVkbq9OrenZt1L71iLSMeWOjXSgALEj2WbJ7HZ6rNq2Q2oDY6X6IpgARibWtSMYDtIMAhN/WcB1TsMn4XTOOZwu5ymehDQSDZq+hHTr7KCAA5++ab2OQMqMHLJVV6UdQXyWSM6rsLKGVuo7cSMxiKbPBUZNBXY6N/lpEWamY3MaaofKLr/vwKbc/I=
---

# RootWord · 背多分

> 一款**原生 SwiftUI** 的 iOS 背单词 App：以词根词缀拆解为核心，内置 **拍照 / 相册 OCR 识别导入**、**77 万词条 SQLite 大词库核对纠错**与**艾宾浩斯间隔复习调度**。使用 `swiftc` 命令行直接编译（免 Xcode 工程），可打包为 **.ipa** 通过 **AltStore 自签安装**。

![platform](https://img.shields.io/badge/platform-iOS%2015.4%20%7C%20arm64-blue)

![build](https://img.shields.io/badge/build-swiftc%20%2F%20no%20Xcode-orange)

![license](https://img.shields.io/badge/license-MIT-green)

---

## 一、项目简介

RootWord（背多分）是一个本地优先的 iOS 背单词应用。核心使用场景：**学生手机拍照课本单词表 → OCR 自动识别导入 → 快速背诵卡片流 + 艾宾浩斯遗忘曲线调度复习**。

App 提供四条高效的**导入路径**：

- **拍照 OCR**：对准课本单词表拍照，Vision 框架本地 OCR 自动提取「单词 + 中文释义」，经词典三层校验标注可疑词/生僻词；
- **照片 OCR**：从相册选择单词表照片，走与拍照完全相同的识别链路；
- **粘贴文本**：复制单词表文本（`单词:释义` 等格式）直接粘贴导入；
- **文件导入**：通过文件 App 选择 **txt / csv / json** 文件导入（UTF-8 / GB18030 编码自动识别）。

所有数据只保存在本机，无账号、无网络依赖、无数据上传。

## 二、功能特性

| 功能 | 说明 |
| --- | --- |
| **快速背诵卡片流** | 沉浸式卡片：顶部单词 + 音标 + 发音固定不动，中部展开释义 / 词根拆解 / 记忆法 / 例句，底部固定高度三档评分（记得 / 模糊 / 忘记），评分时实时预览下次复习间隔 |
| **艾宾浩斯遗忘曲线调度** | 固定 8 档间隔 `5min → 30min → 12h → 1d → 2d → 4d → 7d → 15d`；记得升档、模糊降档、忘记/模糊在预算内回到本轮队尾再练（每日上限 2 次，超出顺延次日 04:00，UI 显示「本轮稍后」）；完成 15 天档即标记「已掌握」；凌晨 4 点为日界 |
| **拍照 / 相册 OCR 导入** | Vision 双 Pass OCR（中文优先保释义、英文优先提单词），降采样 + 行聚类解析为「单词 + 释义」，低置信行裁剪 3 倍放大重识别，结果可逐行修正后导入 |
| **词库门控纠错** | 拼写纠正以离线词库为门控：词库查得到即保留原文，查不到且纠正候选命中词库才采纳，杜绝把教材专名/变体改错（如 haven→heaven） |
| **SQLite 大词库核对纠错** | 内置 768,739 词条离线词典，三层校验：① 存在性 ② 常用度（priority）③ 释义一致性（CJK 重叠率）；可疑词标 ⚠、生僻词标 ?，附候选提示 |
| **粘贴 / 文件导入** | 支持 `单词:释义` 等分隔符格式与 JSON / CSV / TXT 文件，表头别名映射、编码嗅探（UTF-8 / GB18030）、去重与释义补全 |
| **词根词缀拆解** | 内置词根词缀库（RootLibrary.json）+ 15.6 万词条预计算索引（roots.sqlite，SQLite 按需查询），未命中回退 S2–S7 在线解析，派生词成组学习 |
| **SRS 间隔复习** | 复习进度本地持久化（JSON 原子落盘 + 自动备份），支持未来 7 天复习量预测与逾期自动降档 |
| **TTS 朗读** | AVSpeechSynthesizer 本地语音合成，遵守静音拨片，不自动朗读 |

## 三、技术架构

- **UI**：SwiftUI 原生声明式 UI（iOS 15.4 兼容，不使用任何 iOS 16+ API），深色模式自适应；
- **编译**：`swiftc` 命令行直接编译为 `arm64-apple-ios15.4` 可执行文件 + 手工组装 .app，**零第三方依赖**（仅系统框架 SwiftUI / Vision / UIKit / AVFoundation / NaturalLanguage / SQLite3），免 Xcode 工程（同时保留 `RootWord.xcodeproj` 便于 Xcode 调试）；
- **词典**：`Dictionary.sqlite`（768,739 词，WITHOUT ROWID + NOCASE 主键），`SQLiteDict` 懒加载只读连接 + NSLock，按需查询替代旧版 tsv 全量载入内存；
- **词根索引**：`roots.sqlite`（156,813 条，构建期由 `precomputed_roots.tsv` 幂等转换生成，对齐安卓端 roots.db 方案）；`SQLiteRootIndex` 懒加载只读连接 + NSLock + 预编译语句按需查询，替代旧版 TSV 全量载入内存，bundle 缺资源时回退在线解析；
- **OCR 链路**：降采样 → Vision 双 Pass（zh-Hans / en-US）→ 双通道合并（行号纠错、低置信裁剪 3x 重识别、三级配对补行、释义修复）→ 行解析 → 词典三层校验标注 → 预览确认落库；
- **调度算法**：`SRScheduler` 为纯函数集合（无状态、无副作用），`shouldReinsert` 统一重插判定供按钮预览 / Toast / 入队共用，`buildQueue(currentDeckID:)` 在排序内实现当前词单新词优先；内置 DEBUG 自检（SRSchedulerSelfCheck / RootParserSelfCheck / ImportSelfCheck）；
- **持久化**：`Store.swift` 全量 JSON 原子落盘，备份导出回读自检，损坏自动备份恢复，CSV 导出（BOM + 转义）。

**源码目录（30 个 Swift 文件）**

```
Sources/
├── App/
│   └── RootWordApp.swift          # @main 入口：启动 → 引导 → 主 Tab（今日/词单/词根/我的）
├── Core/
│   ├── AppState.swift             # 全局状态：会话装配、评分写路径、导入落库
│   ├── Store.swift                # 持久化：JSON 原子落盘、备份、CSV 导出
│   ├── SRScheduler.swift          # 艾宾浩斯 8 档间隔调度（纯函数 + DEBUG 自检）
│   ├── SQLiteDict.swift           # 词典只读查询：精确 + 变体兜底 + 常用词前缀扫描
│   ├── SQLiteRootIndex.swift      # 词根索引只读查询：roots.sqlite 预编译语句按需命中
│   ├── UserDataStore.swift        # UserData.sqlite 迁移层（默认不启用，带备份与校验）
│   ├── ECDictValidator.swift      # 词典三层校验：存在性 / 常用度 / 释义一致性
│   ├── OCRService.swift           # 双 Pass OCR + 合并纠错 + 行解析
│   ├── Importer.swift             # 导入解析：JSON / CSV / TXT / 粘贴文本
│   ├── RootParser.swift           # 词根拆解（SQLite 索引命中 + S2–S7 在线兜底 + 自检）
│   ├── Speech.swift               # TTS 朗读（AVSpeechSynthesizer）
│   └── Haptics.swift              # 触觉反馈
├── Models/
│   ├── Word.swift                 # 单词 / SRS 状态 / 拆解段 / 例句 数据模型
│   ├── RootEntry.swift            # 词根词缀库模型
│   └── Settings.swift             # 设置模型
└── Views/                         # 14 个视图/组件文件：卡片流、导入、OCR、词根库、设置等
```

## 四、目录结构说明

```
rootword-sqlite/
├── Sources/                 # Swift 源码（30 个文件，见上文）
├── Resources/
│   ├── Info.plist           # App 配置：显示名「背多分」、相机/相册权限声明、版本号
│   ├── Dictionary.sqlite    # 大词典（768,739 词 + 音标，约 55.5 MB）
│   ├── roots.sqlite         # 词根预计算索引（156,813 条，约 4.9 MB，随 bundle 发布）
│   ├── precomputed_roots.tsv# 词根索引源数据（约 3.7 MB，仅构建期输入，不进 bundle）
│   ├── RootLibrary.json     # 词根词缀库（约 58 KB）
│   ├── Icons/               # App 图标（60/76/83.5/1024 各尺寸）
│   ├── Dictionary.sqlite.bak# 词典增强前备份（46.2 MB）
│   └── roots.db             # 安卓端对齐产物（不参与 iOS 打包）
├── scripts/
│   ├── build_version.txt    # 打包版本状态文件（自动递增基准）
│   └── generate_precomputed_roots.py  # 预计算词根索引生成脚本
├── tools/
│   └── convert_roots_tsv_to_sqlite.py # tsv → sqlite 幂等转换 + 完整性校验
├── Tests/                   # 独立回归测试（swiftc 直接编译，不参与 App 构建）
├── build/                   # 构建输出（每次构建自动清理重建）
├── docs/
│   ├── RootWord-产品设计文档.md
│   └── SQLite大修日志-1.4.0.md
├── build-and-package.sh     # 一键编译打包脚本
├── README.md                # 本文件
└── LICENSE                  # MIT License
```

## 五、构建打包方法

工程根目录执行：

```bash
# 完整构建：编译 + 组装 .app + 签名 + 打包 .ipa
bash build-and-package.sh

# 仅编译 + 组装 .app（自定义签名场景）
bash build-and-package.sh --app-only
```

**编译参数（swiftc）**

| 参数 | 值 | 说明 |
| --- | --- | --- |
| target | `arm64-apple-ios15.4` | iOS 15.4+ / arm64 |
| SDK | `xcrun --sdk iphoneos` | 系统 iOS SDK（需安装 Xcode） |
| 模式 | `-parse-as-library` / `-swift-version 5` | `@main` 入口支持 |
| 优化 | `-O` | 全量优化 |
| 告警 | `-warnings-as-errors` | 有警告即构建失败（保证零警告产出） |
| 链接 | `-l sqlite3` | SQLite3 系统库 |

**版本号自动递增**：每次打包 patch +1（1.4.4 → 1.4.5，patch 到 9 进位 minor），同步写回 `Resources/Info.plist` 与状态文件 `scripts/build_version.txt`，产物文件名带版本号。

**构建期额外动作**：`tools/convert_roots_tsv_to_sqlite.py` 幂等转换 `precomputed_roots.tsv → roots.sqlite`（已存在且最新则跳过，含行数 / 抽样 / NOCASE 完整性校验）；`roots.sqlite` 生成或复制失败即中止构建，bundle 内不再包含 `precomputed_roots.tsv`（约省 3.9 MB）；资源完整性由脚本 `ls` 与 `plutil -lint` 校验。

**产物**

| 产物 | 路径 | 说明 |
| --- | --- | --- |
| App Bundle | `build/RootWord.app` | ad-hoc 签名、结构完整的应用包 |
| IPA | `build/RootWord-<版本>.ipa` | 打包脚本默认输出，AltStore 自签安装（Payload/RootWord.app） |
| TIPA | `build/RootWord-1.4.5.tipa`（当前产物） | 由 IPA 直接重命名，内容完全相同；供 TrollStore 安装。脚本不自动生成，需手动改名 |

安装方式：把 `.tipa` 传到手机用 TrollStore 安装；若改用 AltStore 自签，把扩展名改回 `.ipa` 即可（两者是同一份 zip）。命令行安装：`ios-deploy --bundle build/RootWord.app`。

### 独立回归测试

不依赖 Xcode / XCTest，直接编译纯逻辑层（Foundation / SQLite3）在 macOS 上运行：

```bash
bash Tests/run-tests.sh
```

覆盖 SRS 边界（连续忘记 / 模糊 / 忘记的重插次数、凌晨 4 点日界、15 天掌握、当前词单优先）、词根拆解、SQLite 索引完整性与统计、JSON 持久化与会话恢复、导入解析，共 5 组测试；同时打印今日任务生成、索引查询、JSON 写盘、批量导入的耗时基线，便于每次发布比较性能是否退步。`Tests/` 不会被 `build-and-package.sh` 或 Xcode target 编入 App。

## 六、数据资源说明

> **从 Git 仓库 clone 后请先读这一段**：为控制仓库体积与第三方数据授权，公开仓库**不包含** `Resources/Dictionary.sqlite`（约 55.5 MB）、`Resources/roots.sqlite`、`Resources/roots.db`，也不含 `背多分App-项目提示词.md` 与 `flashcard_demo.py`（内部资料）。
>
> - `roots.sqlite` **无需手动准备**：`build-and-package.sh` 会用仓库内的 `Resources/precomputed_roots.tsv` 调用 `tools/convert_roots_tsv_to_sqlite.py` 在构建期幂等生成；
> - `Dictionary.sqlite` 需自行准备并放到 `Resources/`（表结构见 `Sources/Core/SQLiteDict.swift` 头部与下文）；缺失时构建仍可通过（脚本按存在性复制），但 OCR 词典校验、大词库选词与音标查询会不可用；
> - 其余源码、工程文件、`Tests/`、`docs/` 与构建脚本均完整入库。

### Dictionary.sqlite（大词典，768,739 词 / 约 55.5 MB）

- 表结构：`english_entries(word TEXT PRIMARY KEY COLLATE NOCASE, translation TEXT NOT NULL, phonetic TEXT NOT NULL DEFAULT '', priority INTEGER NOT NULL)`，WITHOUT ROWID；
- 查询：主键按需查询（精确 + 常见变体兜底），`priority <= 80` 判定为常用词（考试词表 / 词频）；
- **词典增强历史**（1.4.2）：基线 727,062 词 / 音标覆盖 6.46% → 引入 ECDICT（770,612 行）经 CSV 解析去重追加，新增 41,677 词（priority=101），补全音标 180,618 条（只补空不覆盖），最终 768,739 词、音标覆盖 **29.71%**，`integrity_check` 通过；
- 1.4.0 起由 tsv 全量加载改为 SQLite 主键按需查询，新增 phonetic 音标列；旧库备份为 `Dictionary.sqlite.bak`。

### roots.sqlite（词根预计算索引，156,813 条 / 约 4.9 MB）

- 由 `precomputed_roots.tsv`（156,813 行，word + spec 两列，无重复词）构建期转换生成；
- 表结构：`precomputed_roots(word TEXT PRIMARY KEY COLLATE NOCASE, spec TEXT NOT NULL)` WITHOUT ROWID；
- 运行时由 `SQLiteRootIndex` 以只读连接 + NSLock + 预编译语句按需查询（大小写不敏感），不再把 15.6 万条 TSV 全量载入内存，对齐安卓端 `roots.db` 方案；资源缺失时所有查询返回 nil，`RootParser` 自动回退在线解析，不中断功能；
- `build-and-package.sh` 接入构建期自动转换 + bundle 内存在性硬校验；`precomputed_roots.tsv` 仅作构建输入，不随 bundle 发布。

### 其他资源

- `RootLibrary.json`：词根词缀知识库（在线解析的兜底来源）；
- `precomputed_roots.tsv`：词根索引源数据（离线预解析 ecdict_light.tsv 生成，仅构建期使用）；
- `Info.plist`：已声明 `NSCameraUsageDescription` / `NSPhotoLibraryUsageDescription` 两项隐私权限，以及文件共享（UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace）用于文件导入。

## 七、版本记录

| 版本 | 说明 |
| --- | --- |
| 1.2.0 | OCR 拍照/相册识别导入、EC 词库离线校验、ipa/tipa 打包（AltStore 自签） |
| 1.2.4 ~ 1.2.9 | OCR 识别率与词典校验迭代优化 |
| 1.3.0 ~ 1.3.3 | 词根解析补全、导入格式扩展与覆盖修复、卡片流界面迭代 |
| 1.4.0 | 大修：SQLite 词典按需查询替代 tsv 全量加载，新增音标列（docs/SQLite大修日志-1.4.0.md） |
| 1.4.2 | 词典增强：ECDICT 补词至 768,739 词、音标覆盖提升至 29.71%；roots.sqlite 词根索引构建期转换 |
| 1.4.3 | 艾宾浩斯档位映射修复、OCR 词库门控纠错、OCR 结果保持书页顺序 |
| 1.4.4 | 词根索引接入 SQLite 运行时、重插边界统一、重插文案诚实化、当前词单新词优先；TSV 不再进 bundle；修复打包脚本版本号回显（详见下） |
| **1.4.5（当前）** | 独立回归测试、索引完整性保护、会话恢复、词根缓存与掌握度、体验精修、UserData.sqlite 迁移层预置；已完整打包发版（详见下） |

### 1.4.4 变更说明（2026-11-09）

> 版本号 `1.4.4` / build `22`（历史版本）。当时产物为 `RootWord-1.4.4.ipa`；`build/` 每次构建前会清空，现已被 1.4.5 产物替换。

| 项 | 内容 |
| --- | --- |
| **词根索引接入** | 新增 `SQLiteRootIndex.swift`；`RootParser` 改查 `roots.sqlite`，移除 15.6 万条 TSV 内存字典；`precomputed_roots.tsv` 仅作构建输入，不再进入 bundle（约省 3.9 MB） |
| **重插边界统一** | `SRScheduler.shouldReinsert` 统一「每天最多 2 次」判定，按钮预览 / Toast / 入队共用同一规则，修复第 2 次「忘记」提示会重练却未入队的问题 |
| **重插文案诚实化** | 「5 分钟后」改为「本轮稍后 / 明天」。当前仍是会话内队尾即时重练，**不是定时 5 分钟延迟**；`dueAt` 档位排期不变，真正的延迟队列需与学习会话持久化一并实现 |
| **当前词单优先** | `buildQueue` 新增 `currentDeckID`，当前词单的新词在排序内排最前，且先排序再按 `dailyNewLimit` 截断，不再被截掉 |
| **打包脚本修复** | `build-and-package.sh` 版本号回显处的变量改用 `${VAR}` 包裹，修复 `set -u` 下中文全角标点被并入变量名、导致构建在编译通过后中断的问题 |

**验证**：完整构建通过（29 个源文件，`-O -warnings-as-errors` 零警告零错误）；bundle 内 `Info.plist` 为 1.4.4 / build 22 且 `plutil -lint` 通过，可执行文件为 arm64 Mach-O，`codesign --verify --deep --strict` 通过；bundle 内 `roots.sqlite` 156,813 行、`Dictionary.sqlite` 768,739 行均可只读查询且与源资源一致，`precomputed_roots.tsv` 未进 bundle；IPA 为 `Payload/RootWord.app` 结构（14 个条目）。

### 1.4.5 变更说明（2026-11-10）

> 版本号 `1.4.5` / build `23`，已通过 `build-and-package.sh` 完整构建。产物：`build/RootWord.app`（67 MB）、`build/RootWord-1.4.5.tipa`（28 MB，由默认输出的 `.ipa` 重命名而来，ad-hoc 签名，供 TrollStore 安装）。下列源码修订全部随本版本发出，编译 30 个源文件。

- **测试**：新增 `Tests/` 独立 swiftc 回归脚本（`bash Tests/run-tests.sh`），5 组 68 项覆盖 SRS 全部边界、词根拆解、SQLite 索引、JSON 持久化与导入，并输出性能基线；
- **索引加固**：`SQLiteRootIndex` 检查 `sqlite3_bind_text` / `step` 返回值、用 `PRAGMA table_info` 验证表结构、DEBUG 记录命中 / 未命中 / 在线回退 / 打开失败 / 查询错误；
- **会话恢复**：`StudySession` 可落盘到 `session.json`，App 被回收或重启后从当前词继续；`Store.persist` 改为按文件差异写入，评分不再重写 decks/settings；
- **词根体验**：`[rootID: Set<wordID>]` 反向索引缓存（导入 / 删除 / 恢复时重建），词根详情页展示关联词数、已掌握 / 学习中 / 未学习与掌握进度，只统计可靠拆解结果；
- **体验精修**：首页进度动画（支持「减弱动态效果」）、开始学习触觉反馈、评分按钮明确「下次复习」语义并完善 VoiceOver；沿用 `dsFont` 动态字号与语义色体系，未推翻现有设计；
- **1.5.0 数据层预置**：新增 `UserDataStore.swift`，实现 `words / decks / srs_states / review_logs / word_roots / study_sessions / settings` 表、schema 版本号、单事务、迁移前 JSON 备份与回读、迁移后逐表校验、失败回退。**默认不启用**（`UserDefaults.rootword.useSQLiteUserData`），JSON 仍是主数据源与备份 / 导入导出格式，正式切换留待 1.5.0 独立发布。

**修订验证**：30 个源文件 Release / DEBUG `swiftc -warnings-as-errors` 零警告零错误；回归测试 68/68 通过；`xcodebuild` 真实构建成功（30 个目标文件、两个 SQLite 资源进包）。完整打包生成 1.4.5 / build 23：bundle 内 `Info.plist` 与 `plutil -lint` 正常、可执行文件为 arm64 Mach-O、`codesign --verify --deep --strict` 通过；`roots.sqlite`（156,813 行）与源资源 SHA-256 一致、`Dictionary.sqlite`（768,739 行）只读查询正常、`precomputed_roots.tsv` 未进 bundle；TIPA（由 IPA 重命名）为 `Payload/RootWord.app` 结构（14 个条目），`unzip -t` 完整性通过。

**后续待办**：真 5 分钟延迟队列、`SQLiteDict` 预编译语句缓存与锁边界、OCR 三色审核 UI、1.5.0 正式切换 UserData.sqlite 读写。

## License

[MIT](LICENSE) — Copyright (c) 2026 lxsffy
*（内容由AI生成，仅供参考）*
