#!/bin/bash
set -e

CURRENT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

function init_variables() {
    readonly RESOURCES_DIR="${CURRENT_DIR}/resources"
    readonly POSTPROCESS_DIR="/usr/lib/hailo-post-processes"
    readonly DEFAULT_POSTPROCESS_SO="$POSTPROCESS_DIR/libyolo_post.so"
    readonly DEFAULT_NETWORK_NAME="yolov5"
    readonly DEFAULT_VIDEO_SOURCE="/dev/video0"
    readonly DEFAULT_HEF_PATH="${RESOURCES_DIR}/yolov5m_wo_spp_60p_nv12.hef"
    readonly DEFAULT_JSON_CONFIG_PATH="$RESOURCES_DIR/configs/yolov5.json" 
    readonly DEFAULT_FRONTEND_CONFIG_FILE_PATH="$RESOURCES_DIR/configs/frontend_config.json"
    readonly DEFAULT_UDP_PORT=5000
    readonly DEFAULT_UDP_HOST_IP="10.0.0.2"
    readonly DEFAULT_FRAMERATE="30/1"
    readonly DEFAULT_BITRATE=25000000

    postprocess_so=$DEFAULT_POSTPROCESS_SO
    network_name=$DEFAULT_NETWORK_NAME
    input_source=$DEFAULT_VIDEO_SOURCE
    hef_path=$DEFAULT_HEF_PATH
    json_config_path=$DEFAULT_JSON_CONFIG_PATH
    frontend_config_file_path=$DEFAULT_FRONTEND_CONFIG_FILE_PATH
    udp_port=$DEFAULT_UDP_PORT
    udp_host_ip=$DEFAULT_UDP_HOST_IP
    sync_pipeline=false

    framerate=$DEFAULT_FRAMERATE
    max_buffers_size=5

    bitrate=$DEFAULT_BITRATE
    encoding_hrd="hrd=false"

    print_gst_launch_only=false
    additional_parameters=""

    # Limit the encoding bitrate to 20Mbps to support weak host.
    # Comment this out if you encounter a large latency in the host side
    # Tune the value down to reach the desired latency (will decrease the video quality).
    # ----------------------------------------------
    # bitrate=20000000
    # encoding_hrd="hrd=true hrd-cpb-size=$bitrate"
    # ----------------------------------------------
}

function print_usage() {
    echo "Hailo15 Detection pipeline usage:"
    echo ""
    echo "Options:"
    echo "  --help                  Show this help"
    echo "  -i INPUT --input INPUT  Set the camera source (default $input_source)"
    echo "  --show-fps              Print fps"
    echo "  --print-gst-launch      Print the ready gst-launch command without running it"
    exit 0
}

function parse_args() {
    while test $# -gt 0; do
        if [ "$1" = "--help" ] || [ "$1" == "-h" ]; then
            print_usage
            exit 0
        elif [ "$1" = "--print-gst-launch" ]; then
            print_gst_launch_only=true
        elif [ "$1" = "--show-fps" ]; then
            echo "Printing fps"
            additional_parameters="-v | grep hailo_display"
        elif [ "$1" = "--input" ] || [ "$1" = "-i" ]; then
            input_source="$2"
            shift
        else
            echo "Received invalid argument: $1. See expected arguments below:"
            print_usage
            exit 1
        fi

        shift
    done
}

init_variables $@

parse_args $@

UDP_SINK="udpsink host=$udp_host_ip port=$udp_port"

PIPELINE="gst-launch-1.0 \
    v4l2src device=$input_source io-mode=mmap ! video/x-raw,format=NV12,width=3840,height=2160, framerate=$framerate ! \
    queue leaky=downstream max-size-buffers=$max_buffers_size max-size-bytes=0 max-size-time=0 ! \
    hailofrontend config-file-path=$frontend_config_file_path name=frontend \
    frontend. ! \
    queue leaky=no max-size-buffers=$max_buffers_size max-size-bytes=0 max-size-time=0 ! \
    hailonet hef-path=$hef_path ! \
    queue leaky=no max-size-buffers=$max_buffers_size max-size-bytes=0 max-size-time=0 ! \
    hailofilter function-name=$network_name config-path=$json_config_path so-path=$postprocess_so qos=false ! \
    queue leaky=no max-size-buffers=$max_buffers_size max-size-bytes=0 max-size-time=0 ! \
    hailooverlay qos=false ! \
    queue leaky=no max-size-buffers=$max_buffers_size max-size-bytes=0 max-size-time=0 ! \
    hailoh264enc bitrate=$bitrate $encoding_hrd ! h264parse config-interval=-1 ! \
    video/x-h264,framerate=$framerate ! \
    tee name=udp_tee \
    udp_tee. ! \
        queue leaky=no max-size-buffers=$max_buffers_size max-size-bytes=0 max-size-time=0 ! \
        rtph264pay ! 'application/x-rtp, media=(string)video, encoding-name=(string)H264' ! \
        $UDP_SINK name=udp_sink sync=$sync_pipeline \
    udp_tee. ! \
        queue leaky=no max-size-buffers=$max_buffers_size max-size-bytes=0 max-size-time=0 ! \
        fpsdisplaysink video-sink=fakesink name=hailo_display sync=$sync_pipeline text-overlay=false \
    ${additional_parameters}"

echo "Running $network_name"
echo ${PIPELINE}

if [ "$print_gst_launch_only" = true ]; then
    exit 0
fi

eval ${PIPELINE}
