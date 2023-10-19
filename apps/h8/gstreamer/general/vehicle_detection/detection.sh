#!/bin/bash
set -e

function init_variables() {
    print_help_if_needed $@

    script_dir=$(dirname $(realpath "$0"))
    source $script_dir/../../../../../scripts/misc/checks_before_run.sh

    # Basic Directories
    readonly POSTPROCESS_DIR="$TAPPAS_WORKSPACE/apps/h8/gstreamer/libs/post_processes"
    readonly APPS_LIBS_DIR="$TAPPAS_WORKSPACE/apps/h8/gstreamer/libs/apps/license_plate_recognition/"
    readonly CROPPING_ALGORITHMS_DIR="$POSTPROCESS_DIR/cropping_algorithms"
    readonly RESOURCES_DIR="$TAPPAS_WORKSPACE/apps/h8/gstreamer/general/license_plate_recognition/resources"
    readonly DEFAULT_VEHICLE_JSON_CONFIG_PATH="$RESOURCES_DIR/configs/yolov5_vehicle_detection.json" 

    # Default Video
    readonly DEFAULT_VIDEO_SOURCE="$RESOURCES_DIR/lpr_ayalon.mp4"

    # Vehicle Detection Macros
    readonly VEHICLE_DETECTION_HEF="$RESOURCES_DIR/yolov5m_vehicles.hef"
    readonly VEHICLE_DETECTION_POST_SO="$POSTPROCESS_DIR/libyolo_hailortpp_post.so"
    readonly VEHICLE_DETECTION_POST_FUNC="yolov5m_vehicles"

    video_sink_element=$([ "$XV_SUPPORTED" = "true" ] && echo "xvimagesink" || echo "ximagesink")
    input_source=$DEFAULT_VIDEO_SOURCE

    print_gst_launch_only=false
    additional_parameters=""
    stats_element=""
    debug_stats_export=""
    sync_pipeline=true
    video_sink="fpsdisplaysink video-sink=$video_sink_element text-overlay=false "
    device_id_prop=""
    tee_name="context_tee"
    internal_offset=false
    pipeline_1=""
    car_json_config_path=$DEFAULT_VEHICLE_JSON_CONFIG_PATH 
    tcp_host=""
    tcp_port=""
}

function print_help_if_needed() {
    while test $# -gt 0; do
        if [ "$1" = "--help" ] || [ "$1" == "-h" ]; then
            print_usage
        fi

        shift
    done
}

function print_usage() {
    echo "Vehicle detection pipeline usage:"
    echo ""
    echo "Options:"
    echo "  -h --help                  Show this help"
    echo "  --show-fps                 Print fps"
    echo "  --print-gst-launch         Print the ready gst-launch command without running it"
    echo "  --print-device-stats       Print the power and temperature measured"
    echo "  --tcp-address              Used for TAPPAS GUI, switchs the sink to TCP client"
    exit 0
}

function parse_args() {
    while test $# -gt 0; do
        if [ "$1" = "--print-gst-launch" ]; then
            print_gst_launch_only=true
        elif [ "$1" = "--print-device-stats" ]; then
            hailo_bus_id=$(hailortcli scan | awk '{ print $NF }' | tail -n 1)
            device_id_prop="device_id=$hailo_bus_id"
            stats_element="hailodevicestats $device_id_prop"
            debug_stats_export="GST_DEBUG=hailodevicestats:5"
        elif [ "$1" = "--tcp-address" ]; then
            tcp_host=$(echo $2 | awk -F':' '{print $1}')
            tcp_port=$(echo $2 | awk -F':' '{print $2}')
            video_sink="queue name=queue_before_sink leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
                        videoscale ! video/x-raw,width=836,height=546,format=RGB ! \
                        queue max-size-bytes=0 max-size-time=0 ! tcpclientsink host=$tcp_host port=$tcp_port" 
            shift
        elif [ "$1" = "--show-fps" ]; then
            echo "Printing fps"
            additional_parameters="-v | grep -e hailo_display -e hailodevicestats"
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

source_element="filesrc location=$input_source name=src_0 ! decodebin"
internal_offset=true

PIPELINE="${debug_stats_export} gst-launch-1.0 ${stats_element} \
    $source_element ! \
    videoscale ! video/x-raw, pixel-aspect-ratio=1/1 ! videoconvert ! \
    queue leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
    hailonet hef-path=$VEHICLE_DETECTION_HEF vdevice-key=1 scheduling-algorithm=1 scheduler-threshold=1 scheduler-timeout-ms=100 nms-score-threshold=0.3 nms-iou-threshold=0.45 output-format-type=HAILO_FORMAT_TYPE_FLOAT32 ! \
    queue leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
    hailofilter so-path=$VEHICLE_DETECTION_POST_SO function-name=$VEHICLE_DETECTION_POST_FUNC config-path=$car_json_config_path qos=false ! \
    queue leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
    hailotracker name=hailo_tracker keep-past-metadata=true kalman-dist-thr=.5 iou-thr=.6 keep-tracked-frames=2 keep-lost-frames=2 ! \
    queue leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
    tee name=$tee_name \
    $tee_name. ! \
    queue leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
    videobox top=1 bottom=1 ! \
    queue leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
    hailooverlay line-thickness=3 font-thickness=1 qos=false ! \
    videoconvert ! \
    $video_sink name=hailo_display sync=$sync_pipeline \
    fakesink sync=false async=false  ${additional_parameters}"

echo "Running vehicle detection pipeline."
echo ${PIPELINE}

if [ "$print_gst_launch_only" = true ]; then
    exit 0
fi

eval ${PIPELINE}
