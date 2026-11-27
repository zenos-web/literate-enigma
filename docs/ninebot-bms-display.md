# 九号 4.3 寸 BMS 显示修复

原 4.3 寸 JPEG 路径主动丢弃 BMS 图像，仅 5/7 寸 H.264 合成卡片。本次两种输出共用 InstrumentVideoCanvas；卡片更新、移动和关闭都会使 JPEG 缓存失效，地图静止时也能刷新或清除卡片。设置预览比例对应 480×272。

没有改变仪表端口、握手和视频协议。用户已反馈开发分支的九号 4.3 寸 BMS 画面正常显示。原生 macOS 验证命令为 `bash Tools/test_ninebot_canvas.sh`，检查 JPEG 像素、缓存和 H.264 编解码；不使用 iOS 模拟器。
