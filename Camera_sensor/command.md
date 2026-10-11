查看相机设备序号数： v4l2-ctl --list-devices //GS代表globol shutter表示外部相机
查看相机全部细节命令：v4l2-ctl -d /dev/video4 --list-formats-ext //MJPG为压缩格式，YUYV为原始格式