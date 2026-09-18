#!/bin/bash
# ============================================================================
#  RootWord · 词根单词 —— 编译打包脚本（无需 Xcode 工程）
#
#  为什么不用 .xcodeproj：
#    本 App 零第三方依赖、无 Asset Catalog、无 Storyboard，
#    用 swiftc 直接编译成 arm64 可执行文件 + 手工组装 .app 更透明、更易审计，
#    也方便在命令行环境反复构建。若你更习惯 Xcode，见 README 的「Xcode 工程」一节。
#
#  用法：
#    ./build-and-package.sh            # 编译 + 组装 .app + 打包 .ipa
#    ./build-and-package.sh --app-only # 只出 .app（自定义签名时用）
#
#  产物：build/RootWord.app 和 build/RootWord.ipa
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. 路径与参数
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/Sources"
RES_DIR="$SCRIPT_DIR/Resources"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="RootWord"
DEPLOYMENT_TARGET="15.4"

APP_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --app-only) APP_ONLY=1 ;;
    *) echo "未知参数：$arg"; exit 1 ;;
  esac
done

if [ ! -d "$SRC_DIR" ]; then
  echo "✗ 找不到源码目录：$SRC_DIR"
  exit 1
fi

echo "==> RootWord 构建开始"
echo "    源码：$SRC_DIR"

# ---------------------------------------------------------------------------
# 1. 环境检查
# ---------------------------------------------------------------------------
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  echo "✗ 未找到 iOS SDK。请先安装 Xcode 并执行： sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "    SDK ：$SDK_PATH"

# ---------------------------------------------------------------------------
# 2. 清理旧产物
# ---------------------------------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# 3. 编译（arm64 / iOS 15.4 / 纯系统框架）
#    -parse-as-library : 因为 RootWordApp.swift 使用 @main
#    -swift-version 5  : 与 Xcode 工程默认 Swift 5 语言模式一致
# ---------------------------------------------------------------------------
echo "==> 编译 Swift 源码"

# 注意：工程路径含空格，必须用数组传递，禁止裸 $SWIFT_FILES 展开
SWIFT_FILES=()
while IFS= read -r line; do
  [ -n "$line" ] && SWIFT_FILES+=("$line")
done < <(find "$SRC_DIR" -name '*.swift' | sort)
echo "    共 ${#SWIFT_FILES[@]} 个源文件"

xcrun -sdk iphoneos swiftc \
  -target arm64-apple-ios${DEPLOYMENT_TARGET} \
  -sdk "$SDK_PATH" \
  -parse-as-library \
  -swift-version 5 \
  -O \
  -warnings-as-errors \
  -o "$BUILD_DIR/$APP_NAME" \
  "${SWIFT_FILES[@]}"

echo "✓ 编译通过：$BUILD_DIR/$APP_NAME"

# ---------------------------------------------------------------------------
# 4. 组装 .app
# ---------------------------------------------------------------------------
echo "==> 组装 App Bundle"

APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
mkdir -p "$APP_BUNDLE"
mv "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/$APP_NAME"
chmod +x "$APP_BUNDLE/$APP_NAME"

# Info.plist 必须在 bundle 根目录
cp "$RES_DIR/Info.plist" "$APP_BUNDLE/Info.plist"

# 词根库：只读资源，App 通过 Bundle.main.url(forResource:) 读取
cp "$RES_DIR/RootLibrary.json" "$APP_BUNDLE/RootLibrary.json"

# 图标：iOS 在 bundle 根目录按 AppIcon60x60@2x/@3x 命名查找
if [ -d "$RES_DIR/Icons" ]; then
  cp "$RES_DIR/Icons/"*.png "$APP_BUNDLE/" 2>/dev/null || true
fi

# 校验 Info.plist 是合法 plist
plutil -lint "$APP_BUNDLE/Info.plist" >/dev/null || { echo "✗ Info.plist 格式错误"; exit 1; }

# 从 Info.plist 读版本号，用于 IPA 命名
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Info.plist" 2>/dev/null || echo "1.1.0")

echo "✓ Bundle 组装完成：$APP_BUNDLE"
ls -1 "$APP_BUNDLE" | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 5. 签名
#    TrollStore 会自动用 fakesign(ldid) 重新签名，这里先做 ad-hoc 签名保证
#    bundle 结构完整、可通过校验；若你有开发者证书，改下面这行即可：
#    codesign -f -s "Apple Development: 你的名字 (XXXXXXXXXX)" "$APP_BUNDLE"
# ---------------------------------------------------------------------------
echo "==> 签名（ad-hoc）"
if command -v codesign >/dev/null 2>&1; then
  codesign -f -s - --timestamp=none "$APP_BUNDLE" 2>/dev/null \
    && echo "✓ ad-hoc 签名完成" \
    || echo "! ad-hoc 签名失败（TrollStore 安装时会自动 fakesign，可继续）"
else
  echo "! 未找到 codesign，跳过"
fi

# ---------------------------------------------------------------------------
# 6. 打包 IPA（TrollStore 直接安装）
#    结构：Payload/RootWord.app
# ---------------------------------------------------------------------------
if [ "$APP_ONLY" -eq 1 ]; then
  echo "==> 已指定 --app-only，跳过 IPA 打包"
  echo "完成：$APP_BUNDLE"
  exit 0
fi

echo "==> 打包 IPA"
PAYLOAD="$BUILD_DIR/Payload"
mkdir -p "$PAYLOAD"
cp -R "$APP_BUNDLE" "$PAYLOAD/"

IPA_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.tipa"
(cd "$BUILD_DIR" && zip -qry "$(basename "$IPA_PATH")" Payload)
rm -rf "$PAYLOAD"

echo ""
echo "=================================================="
echo " 构建成功"
echo " App ：$APP_BUNDLE"
echo " IPA ：$IPA_PATH"
echo "=================================================="
echo " 安装（TrollStore）：把 IPA 传到手机，用 TrollStore 打开安装"
echo " 安装（命令行）：  ios-deploy --bundle \"$APP_BUNDLE\"   （需已连接设备）"
