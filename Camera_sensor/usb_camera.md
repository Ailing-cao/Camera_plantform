# USB 摄像头配置

`config.yaml` 是当前识别到的 Xitech USB 2M GS camera 的配置。默认值为：

- 关闭自动白平衡，固定色温 `4500 K`
- 出图分辨率 `1920x1080`
- 出图格式 `MJPG`
- 50 Hz 防闪烁频率（中国大陆常用值）
- 30 fps 帧率
- 手动曝光 `10000 us`（10 ms）

摄像头连接后，在终端执行：

```bash
chmod +x ./camera_config.sh
 ./Camera_sensor/camera_config.sh
```

如果设备节点变化，脚本会按 USB 厂商、型号和序列号自动查找同一摄像头。若提示权限不足，将当前用户加入 `video` 组后重新登录，或使用有权限的账户执行。

参数在 `config.yaml` 中修改：`IMAGE_WIDTH` 和 `IMAGE_HEIGHT` 设置分辨率，`PIXEL_FORMAT` 设置出图格式（如 `MJPG` 或 `YUYV`），`POWER_LINE_FREQUENCY_HZ` 可改为 `60`，`FRAME_RATE_FPS` 调整出图频率，`EXPOSURE_TIME_US` 调整曝光时长（必须是 100 的整数倍）。V4L2 的曝光控件通常以 100 微秒为单位，脚本会自动换算。

当前运行环境只暴露了摄像头的 sysfs 信息，没有 `/dev/video4` 设备节点，因此无法在这里实际下发控件；脚本会在摄像头节点可用时检查支持的控件并报告未支持的项目。
