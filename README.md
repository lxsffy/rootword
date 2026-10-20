\---  
AIGC:  
    Label: "1"  
    ContentProducer: 001191440300708461136T1XGW3  
    ProduceID: d08810df37746fbf6c9181f5580a2793_c698431bccb911f1b76f525400638852  
    ReservedCode1: nqDrqC6//oM31trLDmk3fIhNChD02tKqL6q5WFscz/OUPhTqRJldUSQafRREtOqLHu6wv58Pt+cgSmpJ92TMIXz6RffngtXmYOz+1N90fhu3M2IhKXVKROYyPO1dQz1SWqlVRuIm/5liXpUhQlV906Mhna7Zu9a/OQwSOF4JcidG9fCyXOZPrdDmkec=  
    ContentPropagator: 001191440300708461136T1XGW3  
    PropagateID: d08810df37746fbf6c9181f5580a2793_c698431bccb911f1b76f525400638852  
    ReservedCode2: nqDrqC6//oM31trLDmk3fIhNChD02tKqL6q5WFscz/OUPhTqRJldUSQafRREtOqLHu6wv58Pt+cgSmpJ92TMIXz6RffngtXmYOz+1N90fhu3M2IhKXVKROYyPO1dQz1SWqlVRuIm/5liXpUhQlV906Mhna7Zu9a/OQwSOF4JcidG9fCyXOZPrdDmkec=  
\---

# RootWord · 词根单词

> 一款**原生 SwiftUI** 的 iOS 背单词 App：以词根词缀拆解为核心，内置 **OCR 拍照识别导入**、**EC Dictionary 离线词典校验纠错**与 **77 万词条大词库选词**。使用 `swiftc` 直接编译，无需 Xcode 工程依赖，可打包为 **.tipa** 通过 **TrollStore（巨魔）** 免签名安装。

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

| 功能                       | 说明                                                                             |
| ------------------------ | ------------------------------------------------------------------------------ |
| **词根背单词**                | 词根词缀拆解 + 派生词成组学习，内置词根词缀库（RootLibrary.json）                                     |
| **OCR 拍照识别导入**           | Vision 双 Pass OCR（中文优先保释义、英文优先提单词），行聚类解析为「单词 + 释义」，结果可逐行修正后导入                  |
| **EC Dictionary 词典校验纠错** | 内置离线词库三层校验：① 存在性 ② 常用度（考试词表 / 词频）③ 释义一致性（CJK 重叠率）；可疑词标 ⚠、生僻词标 ?，附编辑距离 ≤ 2 候选提示 |
| **大词库选词**                | 按前缀实时浏览 77 万词条中的常用词，勾选批量导入，自动去重                                                |
| **SRS 间隔复习**             | 基于记忆曲线的调度复习，进度本地持久化                                                            |
| **TTS 朗读**               | 本地语音合成朗读单词，无需网络                                                                |
| **灵活导入**                 | 支持粘贴文本 / 文件（txt、csv、json）/ 示例模板三种来源，导入前去重、预览确认                                 |

## 技术栈与兼容性

- **UI 框架**：SwiftUI（原生声明式 UI，遵循系统设计语言，支持深色模式）
- **编译方式**：`swiftc` 命令行直接编译（arm64-apple-ios15.4），**不依赖 Xcode 工程**（同时保留 RootWord.xcodeproj 便于 Xcode 打开调试）
- **系统要求**：iOS 15.4 及以上（TrollStore 支持范围），arm64 设备
- **依赖**：零第三方依赖，仅系统框架（SwiftUI / Vision / UIKit / AVFoundation / NaturalLanguage 等）
- **隐私**：全本地运行，相机/相册权限仅用于 OCR 识别，图片不上传

## 构建方法

工程根目录执行：

```bash
# 完整构建：编译 + 组装 .app + 打包 .tipa
bash build-and-package.sh

# 仅编译 + 组装 .app（自定义签名场景）
bash build-and-package.sh --app-only
```

**产物说明**

| 产物         | 路径                          | 说明                                          |
| ---------- | --------------------------- | ------------------------------------------- |
| App Bundle | `build/RootWord.app`        | 已组装完整、ad-hoc 签名的应用包                         |
| 安装包        | `build/RootWord-<版本号>.tipa` | TrollStore 直接安装的压缩包（含 Payload/RootWord.app） |

打包的 `.tipa` 已内置 **ecdict_light.tsv 大词库（约 36MB）**，最终安装包约 15MB。

## TrollStore 安装说明

1. 将 `build/RootWord-1.2.0.tipa` 通过 AirDrop / 数据线 / 网盘传到手机；
2. 在手机上用 **TrollStore** 打开该文件；
3. 点击 **Install**，安装完成后即可在桌面找到「背多分」；
4. TrollStore 会自动使用 fakesign（ldid）重签名，**无需 Apple 开发者证书**。

> 支持 TrollStore 的设备：iOS 14.0 ~ 17.0 的 arm64 设备（越狱 / 利用巨魔漏洞安装）。

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

## 已知限制

- **OCR 场景**：针对印刷体单词书页优化，手写体、艺术字体、低对比度照片识别率下降；拍照时请尽量保证页面平整、光线充足；
- **OCR 校验**：词典校验仅覆盖英文单词/常见词组；释义一致性判断依赖识别出的中文，释义行缺失时不判可疑（避免误报）；
- **生僻词**：不在常见考试词表且词频为 0 的单词会标 `?`，属正常提示，可手动确认后导入；
- **大词库体积**：内置 36MB 词库使安装包增大（tipa 约 15MB），首次进入 OCR/选词页加载词库需数秒；
- **TrollStore 范围**：仅支持已安装 TrollStore 且系统版本在支持范围内的设备，App 本身未做 Apple App Store 签名适配；
- **多义词**：词库释义为 ECDICT 标准释义，OCR 书页释义若为个性化简写，可能触发"释义不一致"标记，属保守策略。

## 许可证

本项目采用 **MIT License**，详见 [LICENSE](LICENSE) 文件。

```text
MIT License
Copyright (c) 2026 lxsffy
```

词库数据来源于 [ECDICT](https://github.com/skywind3000/ECDICT)（开源英汉词典数据库，其本身亦开放使用，请遵守其许可证）。
