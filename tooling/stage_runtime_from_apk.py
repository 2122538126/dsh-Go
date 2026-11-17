#!/usr/bin/env python3
"""从官方 APK 里取出运行环境包，铺到 runtime/out/arm64-v8a。

`flutter build apk --debug` 不打包 PRoot 运行环境，release 也要这份东西；
官方 CI 用 runtime/build-runtime.sh 现场构建，这里直接复用官方 release 的
产物（同一版本，manifest 里的校验和天然匹配）。

用法：python3 tooling/stage_runtime_from_apk.py <官方.apk> [仓库根目录]
"""
import os
import shutil
import sys
import zipfile

RUNTIME_ASSET_PREFIX = "assets/runtime/"
PROOT_LIBS = (
    "libandroid-shmem.so",
    "libproot-loader.so",
    "libproot.so",
    "libtalloc.so",
    "libtawcroot.so",
)


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    apk = argv[1]
    root = argv[2] if len(argv) > 2 else "."
    out = os.path.join(root, "runtime", "out", "arm64-v8a")
    assets = os.path.join(out, "assets")
    jni = os.path.join(out, "jniLibs", "arm64-v8a")

    with zipfile.ZipFile(apk) as z:
        names = set(z.namelist())
        if "assets/runtime/manifest.json" not in names:
            print(f"{apk}: 没有 assets/runtime/manifest.json，这不是带运行环境的包", file=sys.stderr)
            return 1

        staged_assets = 0
        for name in sorted(names):
            if not name.startswith(RUNTIME_ASSET_PREFIX):
                continue
            dst = os.path.join(assets, name[len("assets/"):])
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with z.open(name) as src, open(dst, "wb") as out_file:
                shutil.copyfileobj(src, out_file)
            staged_assets += 1

        staged_libs = 0
        for lib in PROOT_LIBS:
            name = f"lib/arm64-v8a/{lib}"
            if name not in names:
                print(f"警告：{name} 不在包里，跳过", file=sys.stderr)
                continue
            os.makedirs(jni, exist_ok=True)
            with z.open(name) as src, open(os.path.join(jni, lib), "wb") as out_file:
                shutil.copyfileobj(src, out_file)
            staged_libs += 1

    print(f"runtime 就位：{staged_assets} 个资源、{staged_libs} 个库 -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))