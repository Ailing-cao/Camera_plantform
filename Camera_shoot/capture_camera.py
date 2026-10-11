#!/usr/bin/env python3
"""预览 USB 摄像头，并在按下 s 时保存一张图片。"""

from __future__ import annotations

import argparse
import datetime as dt
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Any, NoReturn


DEFAULT_CONFIG = Path(__file__).with_name("config.yaml")


def fail(message: str) -> NoReturn:
    print(f"错误: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_yaml(path: Path) -> dict[str, Any]:
    try:
        import yaml
    except ImportError:
        fail("缺少 PyYAML，请先执行: python3 -m pip install -r requirements.txt")

    if not path.is_file():
        fail(f"找不到配置文件: {path}")
    try:
        with path.open("r", encoding="utf-8") as stream:
            data = yaml.safe_load(stream)
    except yaml.YAMLError as exc:
        fail(f"YAML 配置解析失败 ({path}): {exc}")
    except OSError as exc:
        fail(f"读取配置文件失败 ({path}): {exc}")
    if not isinstance(data, dict):
        fail(f"配置文件顶层必须是 YAML 映射: {path}")
    return data


def require_string(data: dict[str, Any], key: str, source: Path) -> str:
    value = data.get(key)
    if not isinstance(value, str) or not value.strip():
        fail(f"{source} 缺少有效的 {key}")
    return value.strip()


def positive_int(data: dict[str, Any], key: str, default: int) -> int:
    value = data.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        fail(f"{key} 必须是正整数")
    return value


def resolve_device(camera: dict[str, Any], camera_file: Path) -> str:
    """返回 V4L2 设备节点，并在设备编号变化时按 USB 身份查找。"""
    configured = camera.get("DEVICE")
    if not isinstance(configured, str) or not configured.strip():
        fail(f"{camera_file} 缺少 DEVICE，无法打开摄像头")
    configured = configured.strip()
    if Path(configured).exists():
        return configured

    vendor = camera.get("USB_VENDOR")
    model_id = camera.get("USB_MODEL_ID")
    serial = camera.get("USB_SERIAL")
    if not all(isinstance(item, (str, int)) for item in (vendor, model_id, serial)):
        return configured
    for candidate in sorted(Path("/dev").glob("video*")):
        try:
            properties = subprocess.run(
                ["udevadm", "info", "-q", "property", "-n", str(candidate)],
                check=False,
                capture_output=True,
                text=True,
            ).stdout.splitlines()
        except OSError:
            break
        values = dict(line.split("=", 1) for line in properties if "=" in line)
        if (
            values.get("ID_VENDOR") == str(vendor)
            and values.get("ID_MODEL_ID") == str(model_id)
            and values.get("ID_SERIAL_SHORT") == str(serial)
        ):
            print(f"配置设备 {configured} 不存在，已找到同一摄像头: {candidate}")
            return str(candidate)
    return configured


def run_camera_config(script: Path, camera_file: Path) -> None:
    if not script.is_file():
        fail(f"找不到相机配置脚本: {script}")
    if not os.access(script, os.X_OK):
        fail(f"相机配置脚本没有执行权限: {script}")

    print(f"正在应用相机参数: {camera_file}")
    try:
        result = subprocess.run(
            [str(script), str(camera_file)],
            check=False,
            text=True,
        )
    except OSError as exc:
        fail(f"执行相机配置脚本失败: {exc}")
    if result.returncode != 0:
        fail("相机参数应用失败。请确认摄像头已连接，并且当前用户有 /dev/video* 权限。")


def import_opencv():
    try:
        import cv2
    except ImportError:
        fail("缺少 OpenCV，请先执行: python3 -m pip install -r requirements.txt")
    except Exception as exc:
        fail(
            "OpenCV 无法加载，通常是 NumPy/OpenCV 二进制版本不兼容。"
            f"请重新安装依赖后再试（详细信息: {exc}）"
        )
    return cv2


def next_image_path(directory: Path, prefix: str, extension: str) -> Path:
    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:-3]
    candidate = directory / f"{prefix}_{stamp}{extension}"
    suffix = 1
    while candidate.exists():
        candidate = directory / f"{prefix}_{stamp}_{suffix}{extension}"
        suffix += 1
    return candidate


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "-c",
        "--config",
        type=Path,
        default=DEFAULT_CONFIG,
        help=f"拍摄程序配置文件（默认: {DEFAULT_CONFIG}）",
    )
    parser.add_argument(
        "--skip-camera-config",
        action="store_true",
        help="跳过执行 camera_config.sh（仅用于已经手动设置好相机的情况）",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    app_config = load_yaml(args.config)

    camera_file = Path(require_string(app_config, "camera_config_file", args.config)).expanduser()
    camera_script = Path(require_string(app_config, "camera_config_script", args.config)).expanduser()
    save_directory = Path(require_string(app_config, "save_directory", args.config)).expanduser()
    prefix = require_string(app_config, "filename_prefix", args.config)
    extension = require_string(app_config, "image_extension", args.config).lower()
    if extension not in {".jpg", ".jpeg", ".png"}:
        fail("image_extension 目前只支持 .jpg、.jpeg 或 .png")
    jpeg_quality = positive_int(app_config, "jpeg_quality", 95)
    if jpeg_quality > 100:
        fail("jpeg_quality 必须不大于 100")
    warmup_frames = int(app_config.get("warmup_frames", 10))
    if warmup_frames < 0:
        fail("warmup_frames 不能小于 0")

    if not args.skip_camera_config:
        run_camera_config(camera_script, camera_file)
    camera = load_yaml(camera_file)
    device = resolve_device(camera, camera_file)
    if not Path(device).exists():
        fail(f"找不到摄像头设备: {device}")

    cv2 = import_opencv()
    try:
        save_directory.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        fail(f"无法创建图片保存目录 {save_directory}: {exc}")

    capture = cv2.VideoCapture(device, cv2.CAP_V4L2)
    if not capture.isOpened():
        capture.release()
        fail(f"无法打开摄像头: {device}")

    width = camera.get("IMAGE_WIDTH")
    height = camera.get("IMAGE_HEIGHT")
    fps = camera.get("FRAME_RATE_FPS")
    if isinstance(width, int) and width > 0:
        capture.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    if isinstance(height, int) and height > 0:
        capture.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    if isinstance(fps, (int, float)) and fps > 0:
        capture.set(cv2.CAP_PROP_FPS, fps)

    window_name = "USB Camera - press S to save, Q/Esc to quit"
    print(f"预览已启动: {device}")
    print(f"保存目录: {save_directory}")
    print("按 s 拍照，按 q 或 Esc 退出。")
    saved_count = 0
    try:
        for _ in range(warmup_frames):
            ok, _ = capture.read()
            if not ok:
                fail("摄像头读取帧失败，请检查连接、权限和分辨率格式")

        while True:
            ok, frame = capture.read()
            if not ok:
                print("警告: 读取摄像头帧失败", file=sys.stderr)
                time.sleep(0.05)
                continue
            cv2.imshow(window_name, frame)
            key = cv2.waitKey(1) & 0xFF
            if key in (ord("q"), 27):
                break
            if key in (ord("s"), ord("S")):
                output_path = next_image_path(save_directory, prefix, extension)
                params = []
                if extension in {".jpg", ".jpeg"}:
                    params = [cv2.IMWRITE_JPEG_QUALITY, jpeg_quality]
                if not cv2.imwrite(str(output_path), frame, params):
                    print(f"错误: 图片保存失败: {output_path}", file=sys.stderr)
                    continue
                saved_count += 1
                print(f"已保存 ({saved_count}): {output_path}")
    finally:
        capture.release()
        cv2.destroyAllWindows()
    return 0


if __name__ == "__main__":
    main()
