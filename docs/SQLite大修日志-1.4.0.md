---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: d08810df37746fbf6c9181f5580a2793_033c71efcd6411f1afbb52540064ee0f
    ReservedCode1: WfSWvWCOMUQEahs7HtkdNNi/ycH9shUGhbJabgPTQWVUumCafkyYt9DTg5C1A8fspPAnjhwXXJvFd4D1DfTdOiI+Re9umfGOJ79cG0iljRUOaT2M6Iddp8DQg+q9cn6exfVydIvLahlb/yB4IA3oWwHK9W4GmNs9qJ8WxM6s8iLwYK5xxf+1TMw9nLI=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: d08810df37746fbf6c9181f5580a2793_033c71efcd6411f1afbb52540064ee0f
    ReservedCode2: WfSWvWCOMUQEahs7HtkdNNi/ycH9shUGhbJabgPTQWVUumCafkyYt9DTg5C1A8fspPAnjhwXXJvFd4D1DfTdOiI+Re9umfGOJ79cG0iljRUOaT2M6Iddp8DQg+q9cn6exfVydIvLahlb/yB4IA3oWwHK9W4GmNs9qJ8WxM6s8iLwYK5xxf+1TMw9nLI=
---

# RootWord 1.4.0 大修日志：SQLite 词典替换全量 tsv 加载

> 日期：2026-10-21
> 修改等级：**大修**（架构级替换：词典数据访问模式由「全量加载进内存」改为「SQLite 按需查询」）
> 修改位置：`/Users/lxsffy/Desktop/rootword-sqlite`（桌面隔离副本，无 .git，防止 GitHub 误传）
> 产物：`RootWord-1.4.0.tipa`

## 一、动因（为什么要大修）

旧实现把 `ecdict_light.tsv`（36MB / 约 77 万词条）在 App 内**全量解析为 Swift 字典**：

- 内存峰值估算 150MB+，是此前拍照 OCR 触发 Jetsam OOM（per-process-limit）的根源之一；
- tsv 数据**无音标列**，导入词条无法补全 phonetic；
- 每次冷启动或首次选词都要啃 36MB 文本，耗时且浪费内存。

## 二、方案（第一性原理：词典是「查询」，不是「加载」）

数据源切换为 `Dictionary.sqlite`（源文件 Dictionary.sqlite 来自 FlashCardApp 逆向）（46MB，727,062 词条，`english_entries.word` 主键 COLLATE NOCASE）：

- 词典常驻磁盘，**SQLite 主键查询 O(log n)**，不再整库载入内存；
- `english_entries` 提供 `phonetic` 列（46,961 条覆盖），导入富化获得音标；
- `english_variants`（101,968 条）提供变体兜底（variant → lemma）；
- 连接懒加载 + NSLock 串行化，只读打开一次复用。

## 三、改动清单

| 文件 | 改动 |
|------|------|
| `Sources/Core/SQLiteDict.swift` | **新增**。SQLite 查询层：`ensureOpen()` / `lookup()`（含变体兜底）/ `commonWords(prefix:)`（主键范围扫描）/ `commonCandidates(prefix:)`（编辑距离候选池，priority<=80） |
| `Sources/Core/ECDictValidator.swift` | **重写**。删除 `loadDict()` 全量加载；`DictEntry.tag/frq` → `priority`（常用度判定改为 priority<=80）；查询全部走 `SQLiteDict`；`validateResult` 改为无 dict 参数签名 |
| `Sources/Core/Importer.swift` | `makeWords` 富化改造：`pos` 补全改用 `ECDictValidator.lookup`；**新增 phonetic 补全**（导入缺音标时从词典获取） |
| `Sources/Core/OCRService.swift` | 三层校验调用移除全量 `loadDict`，直接 `validateResult(word:def:)` 按需查询 |
| `Sources/Views/ECDictPickerView.swift` | 预加载改为 `ensureOpen()`（毫秒级）；词条取释义改 `lookup(word)` |
| `build-and-package.sh` | 编译加 `-l sqlite3`；资源拷贝由 `ecdict_light.tsv` 切换为 `Dictionary.sqlite` |
| `Resources/` | 新增 `Dictionary.sqlite`（46MB）；**移除 `ecdict_light.tsv`（36MB）** |
| `scripts/build_version.txt` | 1.3.9 → 自动递增产出 **1.4.0** |

## 四、数据核对证据（大修前）

- `english_entries` 727,062 条，`word` 主键 NOCASE；`phonetic` 非空 46,961 条（覆盖率 6.5%，音标词集中于常用词）；
- priority 分布：20=668,744 / 80=44,092（合计 98%），101+ 为生僻扩展词 → 常用度阈值取 `priority <= 80`；
- `EXPLAIN QUERY PLAN` 确认 `WHERE word=?` 走 PRIMARY KEY；前缀检索走主键范围扫描（`word > ? AND word < ?`）；
- 变体表 `english_variants` 101,968 条，可作词组/变体兜底。

## 五、验收结果

- 编译：`swiftc -O -warnings-as-errors` 通过，28 个源文件，**零警告零错误**；
- Bundle 组装：`Dictionary.sqlite` 已随 .app 内置（`ls build/RootWord.app/` 可见）；
- 产物：`build/RootWord-1.4.0.ipa` → `RootWord-1.4.0.tipa`（含 46MB 词典）；
- 富化数据抽查（sqlite 直接核对）：

| 词 | phonetic | translation 前缀 |
|----|----------|------------------|
| climb | /klaɪm/ | v. 攀登… |
| difference | /ˈdɪfrənts/ | n. 不同… |
| inspiring | /ˌɪnˈspaɪərɪŋ/ | a. 鼓舞人心的 |
| kilometre | /ˌkɪˈlɒˌmɪtə/, /ˌkɪləˈmiːtə/ | n. 公里… |
| seek | /siːk/ | vt. 寻求… |
| sick | /sɪk/ | n. 病人… |

→ 导入时 `pos` 与 `phonetic` 均可按需补全。

## 六、性能与体积对比

| 维度 | 旧（1.3.x，tsv 全量加载） | 新（1.4.0，SQLite 按需查询） |
|------|---------------------------|------------------------------|
| 词典加载内存 | ~150MB+（77 万条 Swift 字典） | 趋近于零（磁盘常驻） |
| 查询路径 | 内存字典哈希 | SQLite 主键 O(log n) |
| 启动/首击延迟 | 首次啃 36MB 文本 | 连接打开毫秒级 |
| 音标数据 | 无 | 46,961 条（常用词集中） |
| bundle 体积 | ~52MB（tsv+词根库） | ~62MB（sqlite+词根库） |

## 七、风险与备注

- 常用度判定由 tsv 的 `tag/frq` 语义改为 sqlite `priority <= 80` 近似（98% 覆盖），考试标签信息不可复现，仅影响「生僻 ?」标记粒度；
- `english_variants` 覆盖有限（主要为连字符/数字变体），词组直查失败时按空格逐 token 校验逻辑保留不变；
- 旧 tsv 仅从隔离副本移除，原工程 `/Users/lxsffy/Desktop/rootword` 未动，GitHub 仓库不受影响。
*（内容由AI生成，仅供参考）*
