# RootWord · 词根单词

> 一款**原生 SwiftUI** 的 iOS 背单词 App：以词根词缀拆解为核心，内置 **OCR 拍照识别导入**、**EC Dictionary 离线词典校验纠错**与 **77 万词条大词库选词**。使用 `swiftc` 直接编译，无需 Xcode 工程依赖，可打包为 **.ipa** 通过 **AltStore 自签安装**（免费 Apple ID，7 天自动续签）。

![platform](https://img.shields.io/badge/platform-iOS%2015.4%20%7C%20arm64-blue)

![build](https://img.shields.io/badge/build-swiftc%20%2F%20no%20Xcode-orange)

![license](https://img.shields.io/badge/license-MIT-green)

---

## 项目简介

RootWord（背多分）是一个本地优先的 iOS 背单词应用。与传统"背单词 App"不同，它围绕**词根词缀记忆法**组织学习内容：单词按词根拆解、派生词成组学习，配合 SRS 间隔复习调度与本地 TTS 朗读。

App 同时提供两条高效的**导入词库路径**：

- **拍照识别**：对准单词书页拍照或从相册选图，Vision 框架本地 OCR 自动提取「单词 + 中文释义」，经离线词典三层校验标注可疑词/生僻词；
- **大词库选词**：内置 ECDICT 精简版（约 77 万词条），按前缀浏览常用词（考试词表），勾选即导入。

所有数据只保存在本机，无账号、无网络依赖、无数据上传。

## 核心功能

| 功能                       | 说明                                                                                      |
| ------------------------ | --------------------------------------------------------------------------------------- |
| **词根背单词**                | 词根词缀拆解 + 派生词成组学习，内置词根词缀库（RootLibrary.json）                                              |
| **OCR 拍照识别导入**           | Vision 双 Pass OCR（中文优先保释义、英文优先提单词），行聚类解析为「单词 + 释义」，结果可逐行修正后导入                           |
| **EC Dictionary 词典校验纠错** | 内置离线词库三层校验：① 存在性 ② 常用度（考试词表 / 词频）③ 释义一致性（CJK 重叠率）；可疑词标 ⚠、生僻词标 ?，附编辑距离 ≤ 2 候选提示          |
| **大词库选词**                | 按前缀实时浏览 77 万词条中的常用词，勾选批量导入，自动去重                                                         |
| **SRS 间隔复习**             | 基于记忆曲线的调度复习，进度本地持久化                                                                     |
| **TTS 朗读**               | 本地语音合成朗读单词，无需网络                                                                         |
| **灵活导入**                 | 支持大众格式「单词:释义」（如 `disease:n. 疾病，病`），粘贴零配置；词根由 App 自动解析（内置 15 万词条预计算索引），旧 @/CSV/JSON 格式兼容 |

## 技术栈与兼容性

- **UI 框架**：SwiftUI（原生声明式 UI，遵循系统设计语言，支持深色模式）
- **编译方式**：`swiftc` 命令行直接编译（arm64-apple-ios15.4），**不依赖 Xcode 工程**（同时保留 RootWord.xcodeproj 便于 Xcode 打开调试）
- **系统要求**：iOS 15.4 及以上，arm64 设备
- **依赖**：零第三方依赖，仅系统框架（SwiftUI / Vision / UIKit / AVFoundation / NaturalLanguage 等）
- **隐私**：全本地运行，相机/相册权限仅用于 OCR 识别，图片不上传

## 构建方法

工程根目录执行：

```bash
# 完整构建：编译 + 组装 .app + 打包 .ipa
bash build-and-package.sh

# 仅编译 + 组装 .app（自定义签名场景）
bash build-and-package.sh --app-only
```

**产物说明**

| 产物         | 路径                         | 说明                                     |
| ---------- | -------------------------- | -------------------------------------- |
| App Bundle | `build/RootWord.app`       | 已组装完整、ad-hoc 签名的应用包                    |
| 安装包        | `build/RootWord-<版本号>.ipa` | AltStore 自签安装包（含 Payload/RootWord.app） |

打包的 `.ipa` 已内置 **ecdict_light.tsv 大词库（约 36MB）** 与 **precomputed_roots.tsv 预计算词根索引（约 3.7MB，15 万词条）**，最终安装包约 15MB。

## AltStore 自签安装说明

1. 构建产物为 `build/RootWord-<版本号>.ipa`（含 Payload/RootWord.app）；
2. 电脑安装 [AltServer](https://altstore.io/)、手机安装 AltStore（App Store 或 AltServer 引导安装），两者保持同一 Wi-Fi 或数据线连接；
3. 将 `.ipa` 传到手机，在 **AltStore** 中打开，登录 **Apple ID** 完成签名安装；
4. 安装完成后即可在桌面找到「背多分」；免费 Apple ID 签名的应用**每 7 天需续签**，打开 AltStore（需连接同一 Wi-Fi 下的 AltServer 或数据线）可自动/手动刷新。

> 说明：AltStore 使用你的 Apple ID 对 `.ipa` 重新签名（AltStore 会覆盖 ad-hoc 签名），免费账号最多同时保留 3 个自签应用。

## 目录结构

```
rootword/
├── Sources/                  # Swift 源码
│   ├── App/                  # 入口（@main）
│   ├── Core/                 # 核心逻辑
│   │   ├── AppState.swift    # 全局状态
│   │   ├── Store.swift       # 本地持久化
│   │   ├── Importer.swift    # 导入解析（去重 / 预览）
│   │   ├── OCRService.swift  # Vision OCR + UITextChecker 纠错
│   │   ├── ECDictValidator.swift # ECDICT 三层校验 / 大词库检索
│   │   ├── RootParser.swift  # 词根词缀解析
│   │   ├── SRScheduler.swift # 间隔复习调度
│   │   ├── Speech.swift      # TTS 朗读
│   │   └── Haptics.swift     # 触觉反馈
│   ├── Models/               # 数据模型
│   └── Views/                # SwiftUI 视图
│       ├── OcrImportView.swift      # OCR 识别导入页
│       ├── ECDictPickerView.swift   # 大词库选词页
│       ├── ImportView.swift         # 导入入口 / 预览确认
│       └── ...                      # 学习 / 词单 / 设置等页面
├── Resources/
│   ├── Info.plist            # 应用配置（权限声明、版本号）
│   ├── RootLibrary.json      # 词根词缀库
│   ├── ecdict_light.tsv      # ECDICT 大词库（word/tag/frq/translation）
│   ├── precomputed_roots.tsv # 预计算词根索引（导入时 O(1) 命中）
│   └── Icons/                # App 图标
├── RootWord.xcodeproj/       # Xcode 工程（可选，swiftc 编译不依赖）
├── docs/                     # 产品设计文档
├── build-and-package.sh      # 编译打包脚本
└── .gitignore
```

## 词库说明

- **来源**：[ECDICT](https://github.com/skywind3000/ECDICT)（开源英汉词典数据库），裁剪为 **ecdict_light.tsv** 随包内置；
- **格式**：TSV 四列 `word \t tag \t frq \t translation`（约 77 万词条，36MB）；
  - `tag`：考试标签（zk 中考 / gk 高考 / cet4 / cet6 / ky 考研 / toefl / ielts 等），空格分隔；
  - `frq`：词频（越大越常用）；
  - `translation`：中文释义；
- **用途**：
  1. OCR 结果三层校验（存在性 / 常用度 / 释义一致性）与纠错候选；
  2. 「大词库选词」功能按前缀浏览**常用词**（tag 命中考试标签或 frq > 0），勾选导入；
- 词库缺失时 App 自动降级：校验功能静默跳过，不误报。

## 预计算词根索引

- **文件**：`Resources/precomputed_roots.tsv`（`word<TAB>词根拆解`，约 15 万词条 / 3.7MB）；
- **生成**：离线脚本 `scripts/generate_precomputed_roots.py` 读取 ecdict_light.tsv，调用与 App `RootParser` 相同的 S2–S7 拆解逻辑，仅保留成功拆解 ≥2 片段的词；
- **作用**：导入单词时 O(1) 命中词根拆解，未命中再走在线解析；配合「单词:释义」大众格式实现**零配置自动分配词根**。

## 已知限制

- **OCR 场景**：针对印刷体单词书页优化，手写体、艺术字体、低对比度照片识别率下降；拍照时请尽量保证页面平整、光线充足；
- **OCR 校验**：词典校验仅覆盖英文单词/常见词组；释义一致性判断依赖识别出的中文，释义行缺失时不判可疑（避免误报）；
- **生僻词**：不在常见考试词表且词频为 0 的单词会标 `?`，属正常提示，可手动确认后导入；
- **大词库体积**：内置 36MB 词库使安装包增大（ipa 约 15MB），首次进入 OCR/选词页加载词库需数秒；
- **自签限制**：使用免费 Apple ID 通过 AltStore 自签安装，每 7 天需续签；App 本身未做 Apple App Store 签名适配（无法直接上架 App Store）；
- **多义词**：词库释义为 ECDICT 标准释义，OCR 书页释义若为个性化简写，可能触发"释义不一致"标记，属保守策略。

## 许可证

本项目采用 **MIT License**，详见 [LICENSE](LICENSE) 文件。

```text
MIT License
Copyright (c) 2026 lxsffy
```

词库数据来源于 [ECDICT](https://github.com/skywind3000/ECDICT)（开源英汉词典数据库，其本身亦开放使用，请遵守其许可证）。  
*（内容由AI生成，仅供参考）*
