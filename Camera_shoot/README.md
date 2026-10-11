# USB 摄像头拍照

`capture_camera.py` 会读取当前目录的 `config.yaml`，先调用
`/home/ailing/Tools/Camera_sensor/camera_config.sh` 应用相机参数，然后打开预览窗口。

安装依赖：

```bash
cd /home/ailing/Tools/Camera_shoot
python3 -m pip install -r requirements.txt
```

启动：

```bash
python3 /home/ailing/Tools/Camera_shoot/capture_camera.py
```

预览窗口中按 `s` 保存一张图片，按 `q` 或 `Esc` 退出。图片默认保存到：

```text
/home/ailing/ballon/yolo_dataset/calib_dataset
```

保存目录、文件名前缀和 JPEG 质量在 `config.yaml` 中修改。相机分辨率、像素格式、帧率、曝光等参数继续在 `/home/ailing/Tools/Camera_sensor/config.yaml` 中修改。

如果已经手动执行过相机配置脚本，也可以跳过重复配置：

```bash
python3 capture_camera.py --skip-camera-config
```

运行前请确认当前用户有摄像头设备权限（通常需要加入 `video` 用户组），并确认相机已经连接。
