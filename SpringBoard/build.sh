#!/usr/bin/env bash
# 把 QFSpeedOverlay.m 编成注入 SpringBoard 的 dylib，并打成 deb。
# 依赖：Xcode 命令行工具（clang / codesign / xcrun）。
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="build"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> SDK: $SDK"

# 单架构 arm64：多架构 fat 会让注入端解析签名/权限时出岔子。
# Tweak 源码是标准 ObjC（无 Logos 宏），直接 clang 编动态库即可。
clang -arch arm64 \
      -dynamiclib \
      -fobjc-arc \
      -O2 \
      -isysroot "$SDK" \
      -miphoneos-version-min=14.0 \
      -framework UIKit \
      -framework Foundation \
      -framework QuartzCore \
      -Wl,-undefined,dynamic_lookup \
      -I. \
      -o "$OUT/QFSpeedOverlay.dylib" \
      QFSpeedOverlay.m

echo "==> 编译完成"
ls -l "$OUT/QFSpeedOverlay.dylib"
file "$OUT/QFSpeedOverlay.dylib" || true

# 签名：有 ldid 就用 ldid（越狱生态标准），没有就退回 codesign 的临时签名。
if command -v ldid >/dev/null 2>&1; then
  ldid -S"entitlements.plist" "$OUT/QFSpeedOverlay.dylib"
  echo "==> ldid 签名完成"
else
  codesign -f -s - "$OUT/QFSpeedOverlay.dylib"
  echo "==> codesign 临时签名完成"
fi

# ---- 打 deb（手工拼 ar，不依赖 dpkg-deb）----
PKG="$OUT/pkg"
rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN"
mkdir -p "$PKG/Library/MobileSubstrate/DynamicLibraries"

cp "$OUT/QFSpeedOverlay.dylib" "$PKG/Library/MobileSubstrate/DynamicLibraries/"
cp "QFSpeedOverlay.plist"      "$PKG/Library/MobileSubstrate/DynamicLibraries/"
chmod 755 "$PKG/Library/MobileSubstrate/DynamicLibraries/QFSpeedOverlay.dylib"
chmod 644 "$PKG/Library/MobileSubstrate/DynamicLibraries/QFSpeedOverlay.plist"

# 依赖说明：
#   不同越狱的注入框架不一样 —— palera1n rootful 常用 Substitute（提供 mobilesubstrate），
#   rootless 常用 ElleKit（包名 ellekit）。用可选依赖把三种都覆盖，
#   否则 Sileo 会因为「找不到 mobilesubstrate」直接拒绝安装。
# 注意：control 文件本身不能写注释行（dpkg 不支持 #），字段必须干净。
cat > "$PKG/DEBIAN/control" <<'CTRL'
Package: com.qfspeed.overlay
Name: QFSpeed Overlay
Version: 2.1.6
Architecture: iphoneos-arm64
Description: QFSpeed 常驻浮窗 —— 全局拖动 + 跨 App 常驻（窗口生在 SpringBoard 进程内）
Maintainer: qfspeed
Author: qfspeed
Section: Tweaks
Depends: mobilesubstrate | ellekit | substrate
CTRL

python3 - "$PKG" "$OUT/QFSpeedOverlay_2.1.6_iphoneos-arm64.deb" <<'PY'
import io, os, sys, tarfile, gzip, struct

pkg, out = sys.argv[1], sys.argv[2]

def build_tar(root, out_path, exclude=()):
    """把 root 下的树打成 tar.gz，保留权限位。

    exclude 用来剔除不该进这个包的东西：data.tar 里绝不能有 DEBIAN/，
    也不能把打包过程中生成的 control.tar.gz / data.tar.gz 自己裹进去。
    """
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as tf:
        entries = []
        for dirpath, dirnames, filenames in os.walk(root):
            for n in filenames:
                entries.append(os.path.join(dirpath, n))
        for path in sorted(entries):
            arc = os.path.relpath(path, root)
            head = arc.split(os.sep)[0]
            if arc in exclude or head in exclude:
                continue
            ti = tf.gettarinfo(path, arcname=arc)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = 'root'
            ti.mtime = 0
            with open(path, 'rb') as f:
                tf.addfile(ti, f)
    raw = buf.getvalue()
    with gzip.GzipFile(out_path, 'wb', mtime=0) as gz:
        gz.write(raw)

build_tar(os.path.join(pkg, 'DEBIAN'), os.path.join(pkg, 'control.tar.gz'))
build_tar(pkg, os.path.join(pkg, 'data.tar.gz'),
          exclude=('DEBIAN', 'control.tar.gz', 'data.tar.gz'))

def ar_member(name, data):
    hdr = b'!<arch>\n'
    body = name.ljust(16).encode()
    body += b'0'.ljust(12)          # mtime
    body += b'0'.ljust(6)           # uid
    body += b'0'.ljust(6)           # gid
    body += b'100644'.ljust(8)      # mode
    body += str(len(data)).ljust(10).encode()
    body += b'`\n'
    payload = body + data
    if len(data) % 2:
        payload += b'\n'
    return payload

parts = [b'!<arch>\n']
parts.append(ar_member('debian-binary', b'2.0\n'))
for name in ('control.tar.gz', 'data.tar.gz'):
    with open(os.path.join(pkg, name), 'rb') as f:
        parts.append(ar_member(name, f.read()))
with open(out, 'wb') as f:
    f.write(b''.join(parts))
print('deb 已生成:', out, os.path.getsize(out), '字节')
PY

# 清理中间产物，方便 CI 上传
rm -f "$OUT/pkg/control.tar.gz" "$OUT/pkg/data.tar.gz"

echo "==> 全部完成"
ls -lh "$OUT"/*.dylib "$OUT"/*.deb
