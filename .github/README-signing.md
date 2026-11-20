# 固定签名

`dsh-debug.keystore` 是**公开的 debug 签名**（密码 `android`，别名 `androiddebugkey`），
不含任何真实密钥。它存在的唯一目的：让每个构建出来的 APK 签名一致，这样新版本能
**直接覆盖安装**，不用卸载、不丢数据。

workflow 在开跑前把它复制到 `~/.android/debug.keystore`；

    keytool -list -v -keystore .github/dsh-debug.keystore -storepass android

能查到证书指纹 `75:4E:77:23:21:B9:90:57:93:37:31:4C:DB:B2:38:A9:24:97:22:47:0D:DA:AA:80:27:BB:9D:30:8E:A3:E0:A1`，
装出来的每个包都应该是它。

要换成自己的正式签名：把 `KEYSTORE_BASE64` 等 secret 配上，workflow 会走正式签名，
不再用这个文件。
