#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG_FILE=${1:-"$SCRIPT_DIR/config.yaml"}

if [[ ! -r "$CONFIG_FILE" ]]; then
    printf '配置文件不可读: %s\n' "$CONFIG_FILE" >&2
    exit 1
fi

# 使用 Ruby 标准库解析 YAML，避免把配置内容当作 shell 代码执行。
if ! command -v ruby >/dev/null 2>&1; then
    printf '未找到 Ruby，无法解析 YAML 配置文件。\n' >&2
    exit 1
fi

config_values=$(ruby -r yaml -e '
data = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
abort("YAML 顶层必须是对象/映射") unless data.is_a?(Hash)
data.each do |key, value|
  key = key.to_s
  abort("YAML 键名无效: #{key}") unless key.match?(/\A[A-Z][A-Z0-9_]*\z/)
  value = case value
          when true then "1"
          when false then "0"
          when nil then ""
          else value.to_s
          end
  puts "#{key}\t#{value}"
end
' "$CONFIG_FILE") || {
    printf 'YAML 配置解析失败: %s\n' "$CONFIG_FILE" >&2
    exit 1
}

while IFS=$'\t' read -r key value; do
    [[ -z "$key" ]] && continue
    case "$key" in
        DEVICE|USB_VENDOR|USB_MODEL_ID|USB_SERIAL|SET_VIDEO_FORMAT|IMAGE_WIDTH|IMAGE_HEIGHT|PIXEL_FORMAT|SET_FRAME_RATE|FRAME_RATE_FPS|POWER_LINE_FREQUENCY_HZ|DISABLE_AUTO_WHITE_BALANCE|WHITE_BALANCE_TEMPERATURE_K|EXPOSURE_AUTO_VALUE|EXPOSURE_TIME_US|BRIGHTNESS)
            printf -v "$key" '%s' "$value"
            ;;
        *)
            printf 'YAML 包含未知配置项: %s\n' "$key" >&2
            exit 1
            ;;
    esac
done <<< "$config_values"

: "${DEVICE:?配置缺少 DEVICE}"
: "${USB_VENDOR:?配置缺少 USB_VENDOR}"
: "${USB_MODEL_ID:?配置缺少 USB_MODEL_ID}"
: "${USB_SERIAL:?配置缺少 USB_SERIAL}"
: "${SET_VIDEO_FORMAT:?配置缺少 SET_VIDEO_FORMAT}"
: "${IMAGE_WIDTH:?配置缺少 IMAGE_WIDTH}"
: "${IMAGE_HEIGHT:?配置缺少 IMAGE_HEIGHT}"
: "${PIXEL_FORMAT:?配置缺少 PIXEL_FORMAT}"
: "${POWER_LINE_FREQUENCY_HZ:?配置缺少 POWER_LINE_FREQUENCY_HZ}"
: "${FRAME_RATE_FPS:?配置缺少 FRAME_RATE_FPS}"
: "${DISABLE_AUTO_WHITE_BALANCE:?配置缺少 DISABLE_AUTO_WHITE_BALANCE}"
: "${WHITE_BALANCE_TEMPERATURE_K:?配置缺少 WHITE_BALANCE_TEMPERATURE_K}"
: "${EXPOSURE_AUTO_VALUE:?配置缺少 EXPOSURE_AUTO_VALUE}"
: "${EXPOSURE_TIME_US:?配置缺少 EXPOSURE_TIME_US}"
# 可选，缺省用硬件默认值 4。
: "${BRIGHTNESS:=4}"

if ! command -v v4l2-ctl >/dev/null 2>&1; then
    printf '未找到 v4l2-ctl，请安装 v4l-utils。\n' >&2
    exit 1
fi

log() { printf '%s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }

camera_device=$DEVICE

# Resolve the same USB camera when /dev/video4 has changed after reconnecting.
if [[ ! -e "$camera_device" ]]; then
    camera_device=
    for candidate in /dev/video*; do
        [[ -e "$candidate" ]] || continue
        properties=$(udevadm info -q property -n "$candidate" 2>/dev/null || true)
        if grep -q "^ID_VENDOR=${USB_VENDOR}$" <<<"$properties" \
            && grep -q "^ID_MODEL_ID=${USB_MODEL_ID}$" <<<"$properties" \
            && grep -q "^ID_SERIAL_SHORT=${USB_SERIAL}$" <<<"$properties"; then
            camera_device=$candidate
            break
        fi
    done
fi

if [[ -z "$camera_device" || ! -e "$camera_device" ]]; then
    printf '找不到目标 USB 摄像头（%s %s，序列号 %s）。\n' \
        "$USB_VENDOR" "$USB_MODEL_ID" "$USB_SERIAL" >&2
    printf '请检查摄像头是否已连接，以及当前用户是否有 video 设备权限。\n' >&2
    exit 1
fi

controls=$(v4l2-ctl -d "$camera_device" --list-ctrls-menus 2>/dev/null || true)
if [[ -z "$controls" ]]; then
    printf '无法读取 V4L2 控件: %s\n' "$camera_device" >&2
    exit 1
fi

has_control() {
    grep -Eq "(^|[[:space:]])$1([[:space:]]|$)" <<<"$controls"
}

# 同一个 V4L2 控件在不同 v4l-utils 版本里名字不同（例如 exposure_absolute →
# exposure_time_absolute、exposure_auto → auto_exposure）。按顺序尝试别名，
# 全部找不到才认为摄像头不支持。
set_control_if_supported() {
    local value=$1
    shift
    local name
    for name in "$@"; do
        if has_control "$name"; then
            if v4l2-ctl -d "$camera_device" --set-ctrl "${name}=${value}"; then
                log "已设置 ${name}=${value}"
            else
                warn "设置 ${name}=${value} 失败"
            fi
            return 0
        fi
    done
    local aliases
    printf -v aliases '%s/' "$@"
    warn "摄像头不支持控件 ${aliases%/}，已跳过"
}

if [[ "${SET_VIDEO_FORMAT}" == 1 ]]; then
    if ! [[ "$IMAGE_WIDTH" =~ ^[0-9]+$ && "$IMAGE_HEIGHT" =~ ^[0-9]+$ ]]; then
        printf 'IMAGE_WIDTH 和 IMAGE_HEIGHT 必须是正整数。\n' >&2
        exit 1
    fi
    case "${PIXEL_FORMAT^^}" in
        MJPG|YUYV|UYVY|NV12) ;;
        *)
            printf 'PIXEL_FORMAT 目前支持 MJPG、YUYV、UYVY 或 NV12。\n' >&2
            exit 1
            ;;
    esac
    if v4l2-ctl -d "$camera_device" \
        --set-fmt-video="width=${IMAGE_WIDTH},height=${IMAGE_HEIGHT},pixelformat=${PIXEL_FORMAT^^}" \
        >/dev/null 2>&1; then
        log "已设置出图格式 ${IMAGE_WIDTH}x${IMAGE_HEIGHT} ${PIXEL_FORMAT^^}"
    else
        warn "设置出图格式 ${IMAGE_WIDTH}x${IMAGE_HEIGHT} ${PIXEL_FORMAT^^} 失败；请用 v4l2-ctl --list-formats-ext 查看支持的组合"
    fi
fi

# 图像亮度（数字增益）。范围 -64~64，数值越大画面越亮、高光越容易削顶。
if ! [[ "$BRIGHTNESS" =~ ^-?[0-9]+$ ]]; then
    printf 'BRIGHTNESS 必须是整数（范围 -64 到 64）。\n' >&2
    exit 1
fi
set_control_if_supported "$BRIGHTNESS" brightness

if [[ "$DISABLE_AUTO_WHITE_BALANCE" == 1 ]]; then
    # 自动白平衡开启时，驱动会锁住 white_balance_temperature（写入返回 EACCES），
    # 所以必须先关自动再设色温。
    set_control_if_supported 0 white_balance_automatic white_balance_temperature_auto
fi
set_control_if_supported "$WHITE_BALANCE_TEMPERATURE_K" white_balance_temperature

case "$POWER_LINE_FREQUENCY_HZ" in
    50) power_line_frequency=1 ;;
    60) power_line_frequency=2 ;;
    0)  power_line_frequency=0 ;;
    *)  printf 'POWER_LINE_FREQUENCY_HZ 只能是 0、50 或 60。\n' >&2; exit 1 ;;
esac
set_control_if_supported "$power_line_frequency" power_line_frequency

if ! [[ "$EXPOSURE_TIME_US" =~ ^[0-9]+$ ]] || (( EXPOSURE_TIME_US < 100 )) || (( EXPOSURE_TIME_US % 100 != 0 )); then
    printf 'EXPOSURE_TIME_US 必须是 100 的正整数倍。\n' >&2
    exit 1
fi
# 同理：自动曝光开启时驱动会锁住手动曝光时长，必须先切到手动模式。
set_control_if_supported "$EXPOSURE_AUTO_VALUE" auto_exposure exposure_auto
exposure_value=$((EXPOSURE_TIME_US / 100))
set_control_if_supported "$exposure_value" exposure_time_absolute exposure_absolute

if [[ "${SET_FRAME_RATE:-1}" == 1 ]]; then
    if v4l2-ctl -d "$camera_device" --set-parm "$FRAME_RATE_FPS" >/dev/null 2>&1; then
        log "已设置帧率 ${FRAME_RATE_FPS} fps"
    else
        warn "设置帧率 ${FRAME_RATE_FPS} fps 失败；请确认当前分辨率/像素格式支持该帧率"
    fi
fi

log "配置完成: $camera_device"
v4l2-ctl -d "$camera_device" --get-parm 2>/dev/null || true
