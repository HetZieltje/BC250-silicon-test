#!/bin/bash
#
# BC-250 Silicon Quality Test
#
# Runtime-only silicon screening for an AMD BC-250.
# Instability is defined as a system hard-freeze/lock or program crash.
# This script does not install packages, change the SteamOS root filesystem,
# enable boot services, or modify persistent CPU/GPU tuning configuration.
#
# CPU backend: bc250-collective/bc250_smu_oc, using Bc250Smu directly so the
# CPU phase changes only CPU clock/scale and CPU temperature.
# GPU backend: direct Bc250Smu queue-0 calls for temporary frequency/voltage
# forcing. Any active adaptive GPU service is stopped during the test.

set -u
set -o pipefail

SCRIPT_NAME="$(basename "$0")"
STATE_FILE="${HOME}/.bc250-silicon-test.state"
LOG_FILE="${HOME}/.bc250-silicon-test.log"

# Defaults. The user is asked to confirm/change these before testing starts.
CPU_FREQ=3500
CPU_START_SCALE=-20
CPU_STEP=-1
CPU_MIN_SCALE=-50
CPU_TEST_SECONDS=30
CPU_TEST_TEMP=95

GPU_FREQ=1500
GPU_START_MV=900
GPU_STEP_MV=-10
GPU_MIN_MV=650
GPU_TEST_SECONDS=30
GPU_TEST_TEMP=90

# Stable runtime baseline after a test when no user CPU OC service was active.
BASELINE_CPU_FREQ=3500
BASELINE_CPU_SCALE=0
BASELINE_TEMP=100
CPU_BASELINE_SOURCE="stable fallback"

BC250_CONTROL_DIR="${BC250_CONTROL_DIR:-/var/lib/bc250-control}"
BC250_OC_DIR="${BC250_OC_DIR:-$BC250_CONTROL_DIR/smu-oc}"

ORIG_CPU_SERVICE_ACTIVE=0
ORIG_GPU_SERVICE_ACTIVE=0

cleanup_done=0
pause_done=0
test_initialized=0
test_passed=0
CPU_LAST_PASS="none"
CPU_LAST_PASS_VID="none"
CPU_POINT_VID="none"
CPU_VID_HISTORY=""
CPU_FAILURE_POINT="none"
CPU_FAILURE_REASON=""
GPU_LAST_PASS="none"
GPU_FAILURE_POINT="none"
GPU_FAILURE_REASON=""
GPU_NOT_RUN=0
stress_pid=""
vkmark_pid=""

SMU_RETRIES=3

# GPU SMU points must be verifiable, not just "applied". A point only counts as
# observed when the live SMU readback (frequency and voltage) matches what was
# requested, both right after applying it and again while the stressor runs.
GPU_MV_TOLERANCE=5
GPU_POINT_TRIES=2

# bc250_smu polls its mailbox a fixed number of times per command. The library
# default (100) is a few milliseconds, which is short enough that a busy SMU
# answers "no response" (status 0x00) and an otherwise fine point is retried or
# failed for no reason. Poll an order of magnitude longer instead.
SMU_MAILBOX_POLLS=4000

# Services that drive the same SMU mailbox as this test. While any of them is
# running it can (and does) re-apply its own GPU frequency/voltage on top of the
# test point, so every one has to be stopped and verified stopped.
GPU_CONFLICT_UNITS=()
CPU_CONFLICT_UNITS=()
STOPPED_GPU_UNITS=()
STOPPED_CPU_UNITS=()

# Live voltage the SMU reported for the currently applied point, and whether the
# GPU result must be reported as an invalid measurement rather than a failure.
GPU_POINT_REQ_MV="none"
GPU_POINT_LIVE_MV="none"
GPU_POINT_GOOD_SAMPLES=0
GPU_POINT_BAD_SAMPLES=0
GPU_INVALID=0
GPU_INVALID_REASON=""
RUN_CPU=1
RUN_GPU=1
USE_DEFAULT_VALUES=0
RESUME_GPU=0

# -----------------------------------------------------------------------------
# Generic helpers
# -----------------------------------------------------------------------------
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    local msg="$1"
    printf '[%s] %s\n' "$(timestamp)" "$msg" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $1"
    exit 1
}

validate_positive_int() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#${1} >= 1 ))
}

validate_int() {
    [[ "$1" =~ ^-?[0-9]+$ ]]
}

validate_temp() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#${1} >= 1 && 10#${1} <= 100 ))
}

confirm_yn() {
    local prompt="$1" value

    while true; do
        read -rp "$prompt [y/N] " value
        case "$value" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No|"") return 1 ;;
            *) echo "Invalid input. Please enter y or n." >&2 ;;
        esac
    done
}

confirm_start_test() {
    local prompt="$1"
    local value

    while true; do
        read -rp "$prompt [y/n] " value
        case "$value" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No) return 1 ;;
            *) echo "Invalid input. Please enter y or n." >&2 ;;
        esac
    done
}

choose_test_scope() {
    local choice

    echo
    echo "=============================================="
    echo "          SELECT SILICON TESTS"
    echo "=============================================="
    echo "1) Run both CPU and GPU tests"
    echo "2) Run CPU test only"
    echo "3) Run GPU test only"
    echo

    while true; do
        read -rp "Choose an option [1-3] (default: 1): " choice
        choice="${choice:-1}"
        case "$choice" in
            1)
                RUN_CPU=1
                RUN_GPU=1
                return 0
                ;;
            2)
                RUN_CPU=1
                RUN_GPU=0
                return 0
                ;;
            3)
                RUN_CPU=0
                RUN_GPU=1
                return 0
                ;;
            *)
                echo "Invalid choice. Enter 1, 2, or 3." >&2
                ;;
        esac
    done
}

choose_test_configuration() {
    local choice

    echo
    echo "=============================================="
    echo "       SELECT TEST CONFIGURATION"
    echo "=============================================="
    echo "Default values:"
    if (( RUN_CPU )); then
        echo "  CPU: ${CPU_FREQ} MHz, scale ${CPU_START_SCALE} to ${CPU_MIN_SCALE} by ${CPU_STEP}, ${CPU_TEST_SECONDS}s/point, max ${CPU_TEST_TEMP}C"
    fi
    if (( RUN_GPU )); then
        echo "  GPU: ${GPU_FREQ} MHz, ${GPU_START_MV} to ${GPU_MIN_MV} mV by ${GPU_STEP_MV}, ${GPU_TEST_SECONDS}s/point, max ${GPU_TEST_TEMP}C"
    fi
    echo
    echo "1) Use all default values"
    echo "2) Set each value manually"
    echo

    while true; do
        read -rp "Choose an option [1-2] (default: 1): " choice
        choice="${choice:-1}"
        case "$choice" in
            1)
                USE_DEFAULT_VALUES=1
                return 0
                ;;
            2)
                USE_DEFAULT_VALUES=0
                return 0
                ;;
            *)
                echo "Invalid choice. Enter 1 or 2." >&2
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# User configuration
# -----------------------------------------------------------------------------
ask_cpu_values() {
    local v
    local delta
    local step_abs

    echo
    echo "CPU sweep values"
    echo "  Frequency is fixed for the whole CPU sweep."
    echo "  Scale changes by the signed Step until the Floor is reached."
    echo

    while true; do
        read -rp "CPU clock MHz [${CPU_FREQ}]: " v
        [[ -z "$v" ]] && v="$CPU_FREQ"

        if validate_positive_int "$v" && (( v >= 100 && v <= 5000 )); then
            CPU_FREQ="$v"
            break
        fi

        echo "Invalid CPU clock. Enter a value from 100 to 5000 MHz."
    done

    while true; do
        read -rp "CPU start scale [${CPU_START_SCALE}]: " v
        [[ -z "$v" ]] && v="$CPU_START_SCALE"

        if validate_int "$v" && (( v <= 0 && v >= -50 )); then
            CPU_START_SCALE="$v"
            break
        fi

        echo "Invalid CPU start scale. Enter a value from -50 to 0."
    done

    while true; do
        read -rp "CPU step [${CPU_STEP}]: " v
        [[ -z "$v" ]] && v="$CPU_STEP"

        if validate_int "$v" && (( v < 0 )); then
            CPU_STEP="$v"
            break
        fi

        echo "Invalid CPU step. Enter a negative integer such as -1."
    done

    while true; do
        read -rp "CPU floor [${CPU_MIN_SCALE}]: " v
        [[ -z "$v" ]] && v="$CPU_MIN_SCALE"

        if validate_int "$v" && (( v <= 0 && v >= -50 && CPU_START_SCALE >= v )); then
            delta=$((CPU_START_SCALE - v))
            step_abs=$((-CPU_STEP))

            if (( delta % step_abs == 0 )); then
                CPU_MIN_SCALE="$v"
                break
            fi

            echo "CPU floor must be reached exactly by the selected step (${CPU_STEP})."
            continue
        fi

        echo "Invalid CPU floor. It must be between -50 and 0 and no lower than the start scale."
    done

    while true; do
        read -rp "CPU seconds per point [${CPU_TEST_SECONDS}]: " v
        [[ -z "$v" ]] && v="$CPU_TEST_SECONDS"

        if validate_positive_int "$v"; then
            CPU_TEST_SECONDS="$v"
            break
        fi

        echo "Invalid CPU test time. Enter a positive integer."
    done

    while true; do
        read -rp "CPU max temp C [${CPU_TEST_TEMP}]: " v
        [[ -z "$v" ]] && v="$CPU_TEST_TEMP"

        if validate_temp "$v"; then
            CPU_TEST_TEMP="$v"
            break
        fi

        echo "Invalid CPU temperature. Enter 1-100 C."
    done
}

ask_gpu_values() {
    local v
    local delta
    local step_abs

    echo
    echo "GPU sweep values"
    echo "  Frequency is fixed for the whole GPU sweep."
    echo "  Voltage changes by the signed Step until the Floor is reached."
    echo

    while true; do
        read -rp "GPU clock MHz [${GPU_FREQ}]: " v
        [[ -z "$v" ]] && v="$GPU_FREQ"

        if validate_positive_int "$v" && (( v >= 100 && v <= 3000 )); then
            GPU_FREQ="$v"
            break
        fi

        echo "Invalid GPU clock. Enter a value from 100 to 3000 MHz."
    done

    while true; do
        read -rp "GPU start mV [${GPU_START_MV}]: " v
        [[ -z "$v" ]] && v="$GPU_START_MV"

        if validate_positive_int "$v" && (( v >= 700 && v <= 1100 )); then
            GPU_START_MV="$v"
            break
        fi

        echo "Invalid GPU start voltage. Enter a value from 700 to 1100 mV."
    done

    while true; do
        read -rp "GPU step mV [${GPU_STEP_MV}]: " v
        [[ -z "$v" ]] && v="$GPU_STEP_MV"

        if validate_int "$v" && (( v < 0 )); then
            GPU_STEP_MV="$v"
            break
        fi

        echo "Invalid GPU step. Enter a negative integer such as -10."
    done

    while true; do
        read -rp "GPU floor mV [${GPU_MIN_MV}]: " v
        [[ -z "$v" ]] && v="$GPU_MIN_MV"

        if validate_positive_int "$v" && (( v >= 600 && v <= 1129 && GPU_START_MV >= v )); then
            delta=$((GPU_START_MV - v))
            step_abs=$((-GPU_STEP_MV))

            if (( delta % step_abs == 0 )); then
                GPU_MIN_MV="$v"
                break
            fi

            echo "GPU floor must be reached exactly by the selected step (${GPU_STEP_MV})."
            continue
        fi

        echo "Invalid GPU floor. It must be between 600 and 1129 mV and no higher than the start voltage."
    done

    while true; do
        read -rp "GPU seconds per point [${GPU_TEST_SECONDS}]: " v
        [[ -z "$v" ]] && v="$GPU_TEST_SECONDS"

        if validate_positive_int "$v"; then
            GPU_TEST_SECONDS="$v"
            break
        fi

        echo "Invalid GPU test time. Enter a positive integer."
    done

    while true; do
        read -rp "GPU max temp C [${GPU_TEST_TEMP}]: " v
        [[ -z "$v" ]] && v="$GPU_TEST_TEMP"

        if validate_temp "$v"; then
            GPU_TEST_TEMP="$v"
            break
        fi

        echo "Invalid GPU temperature. Enter 1-100 C."
    done
}

show_test_summary() {
    echo
    if (( RUN_CPU )); then
        echo "=============================================="
        echo " CPU SILICON QUALITY SWEEP"
        echo "=============================================="
        echo "Clock:      ${CPU_FREQ} MHz"
        echo "Start:      ${CPU_START_SCALE}"
        echo "Step:       ${CPU_STEP}"
        echo "Floor:      ${CPU_MIN_SCALE}"
        echo "Per point:  ${CPU_TEST_SECONDS} seconds"
        echo "Max temp:   ${CPU_TEST_TEMP}C"
    fi
    if (( RUN_GPU )); then
        echo
        echo "=============================================="
        echo " GPU SILICON QUALITY SWEEP"
        echo "=============================================="
        echo "Clock:      ${GPU_FREQ} MHz"
        echo "Start:      ${GPU_START_MV} mV"
        echo "Step:       ${GPU_STEP_MV} mV"
        echo "Floor:      ${GPU_MIN_MV} mV"
        echo "Per point:  ${GPU_TEST_SECONDS} seconds"
        echo "Max temp:   ${GPU_TEST_TEMP}C"
    fi
    echo
}

show_test_report() {
    echo
    echo "=============================================="
    echo " TEST COMPLETE"
    echo "=============================================="
    echo
    if (( RUN_CPU )); then
        if [[ "$cpu_rc" -eq 0 ]]; then
            echo "CPU result: PASS"
            echo "  Tested: ${CPU_FREQ} MHz, scale ${CPU_START_SCALE} to ${CPU_MIN_SCALE} by ${CPU_STEP}"
            echo "  Point duration: ${CPU_TEST_SECONDS}s; temperature limit: ${CPU_TEST_TEMP}C"
            echo "  Last confirmed pass: ${CPU_LAST_PASS}"
            echo "  Last confirmed pass current VID: ${CPU_LAST_PASS_VID} mV"
            echo "  VID by scale: ${CPU_VID_HISTORY:-none}"
        else
            echo "CPU result: FAILED"
            echo "  Tested: ${CPU_FREQ} MHz, scale ${CPU_START_SCALE} toward ${CPU_MIN_SCALE} by ${CPU_STEP}"
            echo "  Point duration: ${CPU_TEST_SECONDS}s; temperature limit: ${CPU_TEST_TEMP}C"
            echo "  Last confirmed pass: ${CPU_LAST_PASS}"
            echo "  Last confirmed pass current VID: ${CPU_LAST_PASS_VID} mV"
            echo "  VID by scale: ${CPU_VID_HISTORY:-none}"
            echo "  Failure candidate: scale ${CPU_FAILURE_POINT}"
            echo "  Failure reason: ${CPU_FAILURE_REASON:-see preceding CPU failure details}"
            echo "  Result meaning: no conclusion below the last confirmed passing scale."
        fi
    fi

    if (( RUN_GPU )); then
        if (( GPU_NOT_RUN )); then
            echo "GPU result: SKIPPED"
            echo "  Reason: GPU phase was not started after the CPU phase failed."
        elif (( GPU_INVALID )); then
            echo "GPU result: INVALID MEASUREMENT"
            echo "  Tested: ${GPU_FREQ} MHz, ${GPU_START_MV} toward ${GPU_MIN_MV} mV by ${GPU_STEP_MV}"
            echo "  Point duration: ${GPU_TEST_SECONDS}s; temperature limit: ${GPU_TEST_TEMP}C"
            echo "  Last confirmed pass: ${GPU_LAST_PASS} mV"
            echo "  Unconfirmed point: ${GPU_FAILURE_POINT} mV"
            echo "  Reason: ${GPU_INVALID_REASON:-see preceding GPU failure details}"
            echo "  Result meaning: the sweep could not keep the requested voltage applied, so"
            echo "  this run does not support any silicon-quality conclusion."
        elif [[ "$gpu_rc" -eq 0 ]]; then
            echo "GPU result: PASS"
            echo "  Tested: ${GPU_FREQ} MHz, ${GPU_START_MV} to ${GPU_MIN_MV} mV by ${GPU_STEP_MV}"
            echo "  Point duration: ${GPU_TEST_SECONDS}s; temperature limit: ${GPU_TEST_TEMP}C"
            echo "  Last confirmed pass: ${GPU_LAST_PASS} mV"
            echo "  Last verified live voltage: ${GPU_POINT_LIVE_MV} mV at ${GPU_FREQ} MHz"
            echo "  Every point was verified against the live SMU readback for the whole interval."
        else
            echo "GPU result: FAILED"
            echo "  Tested: ${GPU_FREQ} MHz, ${GPU_START_MV} toward ${GPU_MIN_MV} mV by ${GPU_STEP_MV}"
            echo "  Point duration: ${GPU_TEST_SECONDS}s; temperature limit: ${GPU_TEST_TEMP}C"
            echo "  Last confirmed pass: ${GPU_LAST_PASS} mV"
            echo "  Failure candidate: ${GPU_FAILURE_POINT} mV"
            echo "  Failure reason: ${GPU_FAILURE_REASON:-see preceding GPU failure details}"
            echo "  Result meaning: no conclusion below the last confirmed passing voltage."
        fi
    fi

    echo
    echo "No persistent CPU/GPU tuning configuration was modified."
    echo "Interpret results as quick silicon-quality thresholds, not long-term stability certification."
}

ask_test_values() {
    echo
    echo "=============================================="
    echo "        SILICON TEST CONFIGURATION"
    echo "=============================================="

    if (( USE_DEFAULT_VALUES )); then
        echo "Using all default test values."
    else
        (( RUN_CPU )) && ask_cpu_values
        (( RUN_GPU )) && ask_gpu_values
    fi

    show_test_summary

    if confirm_start_test "Start the silicon-quality test with these values?"; then
        return 0
    fi

    echo "Test cancelled by user."
    exit 0
}

# -----------------------------------------------------------------------------
# State handling
# -----------------------------------------------------------------------------
write_state() {
    local phase="$1"
    local point="$2"
    local last_pass="$3"

    state_set_field phase "$phase"
    state_set_field point "$point"
    state_set_field last_pass "$last_pass"
    state_set_field timestamp "$(date '+%Y-%m-%d %H:%M:%S %Z')"

    if [[ "$phase" == "CPU" ]]; then
        state_set_field cpu_status "IN_PROGRESS"
        state_set_field cpu_point "$point"
        state_set_field cpu_last_pass "$last_pass"
        state_set_field cpu_last_pass_vid "$CPU_LAST_PASS_VID"
    else
        state_set_field gpu_status "IN_PROGRESS"
        state_set_field gpu_point "$point"
        state_set_field gpu_last_pass "$last_pass"
    fi
}

state_set_field() {
    local field="$1"
    local value="$2"
    local tmp="${STATE_FILE}.tmp"
    local found=0
    local key
    local old_value

    : > "$tmp"
    if [[ -f "$STATE_FILE" ]]; then
        while IFS='=' read -r key old_value; do
            [[ "$key" == "$field" ]] && {
                printf '%s=%s\n' "$field" "$value" >> "$tmp"
                found=1
                continue
            }
            printf '%s=%s\n' "$key" "$old_value" >> "$tmp"
        done < "$STATE_FILE"
    fi

    (( found )) || printf '%s=%s\n' "$field" "$value" >> "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

state_remove_field() {
    local field="$1"
    local tmp="${STATE_FILE}.tmp"
    local key
    local value

    [[ -f "$STATE_FILE" ]] || return 0
    : > "$tmp"
    while IFS='=' read -r key value; do
        [[ "$key" == "$field" ]] && continue
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    done < "$STATE_FILE"
    mv -f "$tmp" "$STATE_FILE"
}

mark_phase_result() {
    local phase="$1"
    local status="$2"

    state_set_field "${phase,,}_status" "$status"
    state_set_field timestamp "$(date '+%Y-%m-%d %H:%M:%S %Z')"
}

clear_state() {
    rm -f "$STATE_FILE"
}

show_previous_state() {
    [[ -f "$STATE_FILE" ]] || return 0

    echo
    echo "Previous test result found:"
    local saved_phase
    local saved_cpu_status
    local saved_gpu_status
    local saved_gpu_point
    saved_phase="$(awk -F= '$1 == "phase" {print $2}' "$STATE_FILE")"
    saved_cpu_status="$(awk -F= '$1 == "cpu_status" {print $2}' "$STATE_FILE")"
    saved_gpu_status="$(awk -F= '$1 == "gpu_status" {print $2}' "$STATE_FILE")"
    saved_gpu_point="$(awk -F= '$1 == "gpu_point" {print $2}' "$STATE_FILE")"

    if [[ "$saved_phase" == "CPU" &&
        ( "$saved_cpu_status" == "IN_PROGRESS" || "$saved_cpu_status" == "FAILED_INTERRUPTED" ) ]]; then
        local saved_cpu_last_pass
        local saved_cpu_last_pass_vid
        local saved_cpu_vid_history
        local saved_cpu_point

        saved_cpu_last_pass="$(awk -F= '$1 == "cpu_last_pass" {print $2}' "$STATE_FILE")"
        saved_cpu_last_pass_vid="$(awk -F= '$1 == "cpu_last_pass_vid" {print $2}' "$STATE_FILE")"
        saved_cpu_vid_history="$(awk -F= '$1 == "cpu_vid_history" {print $2}' "$STATE_FILE")"
        saved_cpu_point="$(awk -F= '$1 == "cpu_point" {print $2}' "$STATE_FILE")"

        echo
        echo "The previous CPU phase was interrupted before it completed."
        echo "CPU result: FAILED (test stopped before completion)"
        echo "  Last confirmed pass: ${saved_cpu_last_pass:-none}"
        echo "  Last confirmed pass current VID: ${saved_cpu_last_pass_vid:-none} mV"
        echo "  VID by scale: ${saved_cpu_vid_history:-none}"
        echo "  Failure candidate: scale ${saved_cpu_point:-unknown}"
        echo "  Failure reason: the CPU phase stopped before the current point completed."
        echo "  Result meaning: no conclusion below the last confirmed passing scale."
        echo
        read -rp "Continue the previous run with the GPU test? [Y/n] " ans
        if [[ ! "$ans" =~ ^[Nn]$ ]]; then
            RESUME_GPU=1
            RUN_CPU=0
            RUN_GPU=1
            state_set_field cpu_status "FAILED_INTERRUPTED"
            state_set_field timestamp "$(date '+%Y-%m-%d %H:%M:%S %Z')"
            echo "Resuming with the GPU phase."
            return 0
        fi

        echo "Previous state retained. Returning to test selection."
        return 0
    fi

    if [[ "$saved_phase" == "GPU" && "$saved_gpu_status" == "IN_PROGRESS" &&
        "$saved_gpu_point" =~ ^[0-9]+$ ]]; then
        local saved_gpu_last_pass
        local saved_cpu_last_pass
        local saved_cpu_status

        echo
        echo "The previous GPU phase was interrupted before it completed."
        echo "The saved GPU point is treated as the GPU cutoff: ${saved_gpu_point} mV."
        echo
        read -rp "Record ${saved_gpu_point} mV as the GPU failure cutoff? [Y/n] " ans
        if [[ "$ans" =~ ^[Nn]$ ]]; then
            echo "Previous state retained. Returning to test selection."
            return 0
        fi

        saved_gpu_last_pass="$(awk -F= '$1 == "gpu_last_pass" {print $2}' "$STATE_FILE")"
        saved_cpu_status="$(awk -F= '$1 == "cpu_status" {print $2}' "$STATE_FILE")"
        saved_cpu_last_pass="$(awk -F= '$1 == "cpu_last_pass" {print $2}' "$STATE_FILE")"
        state_set_field gpu_status "FAILED"
        state_set_field gpu_failure_point "$saved_gpu_point"
        state_set_field gpu_failure_reason "System hard-locked during the GPU point; ${saved_gpu_point} mV is the cutoff."
        state_set_field phase "GPU"
        state_set_field point "$saved_gpu_point"
        state_set_field timestamp "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "GPU cutoff recorded at ${saved_gpu_point} mV."
        echo "Last confirmed GPU pass: ${saved_gpu_last_pass:-none} mV"
        echo "The interrupted GPU point will not be retried."
        # Preserve the CPU result from before the GPU phase. The CPU may have
        # been interrupted on an earlier reboot, but its cutoff remains valid.
        RUN_CPU=1
        RUN_GPU=1
        CPU_LAST_PASS="${saved_cpu_last_pass:-none}"
        CPU_LAST_PASS_VID="$(awk -F= '$1 == "cpu_last_pass_vid" {print $2}' "$STATE_FILE")"
        CPU_VID_HISTORY="$(awk -F= '$1 == "cpu_vid_history" {print $2}' "$STATE_FILE")"
        CPU_FAILURE_POINT="$(awk -F= '$1 == "cpu_point" {print $2}' "$STATE_FILE")"
        if [[ ( -z "$CPU_LAST_PASS_VID" || "$CPU_LAST_PASS_VID" == "none" ) &&
            -n "$CPU_VID_HISTORY" ]]; then
            CPU_LAST_PASS_VID="$(printf '%s\n' "$CPU_VID_HISTORY" |
                awk -v target="scale=${CPU_LAST_PASS}:" 'BEGIN {RS=", "}
                    $0 ~ target {
                        sub(/^.*current=/, "")
                        sub(/mV.*$/, "")
                        print
                    }')"
        fi
        CPU_LAST_PASS_VID="${CPU_LAST_PASS_VID:-none}"
        if [[ "$saved_cpu_status" == "PASS" ]]; then
            cpu_rc=0
        else
            cpu_rc=10
            CPU_FAILURE_REASON="CPU phase stopped before the saved point completed."
        fi
        gpu_rc=12
        GPU_LAST_PASS="${saved_gpu_last_pass:-none}"
        GPU_FAILURE_POINT="$saved_gpu_point"
        GPU_FAILURE_REASON="System hard-locked during the GPU point; ${saved_gpu_point} mV is the cutoff."
        show_test_report
        exit 0
    fi

    local saved_cpu_last_pass
    local saved_cpu_last_pass_vid
    local saved_cpu_vid_history
    local saved_cpu_failure_point
    local saved_cpu_failure_reason
    local saved_gpu_last_pass
    local saved_gpu_failure_point
    local saved_gpu_failure_reason

    RUN_CPU=0
    RUN_GPU=0
    GPU_NOT_RUN=0

    if [[ -n "$saved_cpu_status" ]]; then
        RUN_CPU=1
        saved_cpu_last_pass="$(awk -F= '$1 == "cpu_last_pass" {print $2}' "$STATE_FILE")"
        saved_cpu_last_pass_vid="$(awk -F= '$1 == "cpu_last_pass_vid" {print $2}' "$STATE_FILE")"
        saved_cpu_vid_history="$(awk -F= '$1 == "cpu_vid_history" {print $2}' "$STATE_FILE")"
        saved_cpu_failure_point="$(awk -F= '$1 == "cpu_failure_point" {print $2}' "$STATE_FILE")"
        saved_cpu_failure_reason="$(awk -F= '$1 == "cpu_failure_reason" {print $2}' "$STATE_FILE")"
        CPU_LAST_PASS="${saved_cpu_last_pass:-none}"
        CPU_LAST_PASS_VID="${saved_cpu_last_pass_vid:-none}"
        CPU_VID_HISTORY="${saved_cpu_vid_history:-}"
        CPU_FAILURE_POINT="${saved_cpu_failure_point:-$(awk -F= '$1 == "cpu_point" {print $2}' "$STATE_FILE")}"
        CPU_FAILURE_REASON="${saved_cpu_failure_reason:-CPU phase stopped before the saved point completed.}"
        if [[ "$CPU_LAST_PASS_VID" == "none" && -n "$CPU_VID_HISTORY" ]]; then
            CPU_LAST_PASS_VID="$(printf '%s\n' "$CPU_VID_HISTORY" |
                awk -v target="scale=${CPU_LAST_PASS}:" 'BEGIN {RS=", "}
                    $0 ~ target {
                        sub(/^.*current=/, "")
                        sub(/mV.*$/, "")
                        print
                    }')"
            CPU_LAST_PASS_VID="${CPU_LAST_PASS_VID:-none}"
        fi
        if [[ "$saved_cpu_status" == "PASS" ]]; then
            cpu_rc=0
        else
            cpu_rc=10
        fi
    fi

    if [[ -n "$saved_gpu_status" ]]; then
        RUN_GPU=1
        saved_gpu_last_pass="$(awk -F= '$1 == "gpu_last_pass" {print $2}' "$STATE_FILE")"
        saved_gpu_failure_point="$(awk -F= '$1 == "gpu_failure_point" {print $2}' "$STATE_FILE")"
        saved_gpu_failure_reason="$(awk -F= '$1 == "gpu_failure_reason" {print $2}' "$STATE_FILE")"
        GPU_LAST_PASS="${saved_gpu_last_pass:-none}"
        GPU_FAILURE_POINT="${saved_gpu_failure_point:-$(awk -F= '$1 == "gpu_point" {print $2}' "$STATE_FILE")}"
        GPU_FAILURE_REASON="${saved_gpu_failure_reason:-GPU phase stopped before the saved point completed.}"
        if [[ "$saved_gpu_status" == "PASS" ]]; then
            gpu_rc=0
        else
            gpu_rc=12
        fi
    fi

    show_test_report

    read -rp "Discard the previous state and start fresh? [Y/n] " ans

    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
        clear_state
        log "Previous state discarded."
        return 0
    fi

    echo "Previous state retained. Exiting."
    exit 0
}

install_missing_dependencies() {
    local packages=("$@")
    local readonly_disabled=0

    echo
    echo "The following packages are missing:"
    printf '  %s\n' "${packages[@]}"
    echo
    echo "Installing them modifies the system package database and may modify"
    echo "the SteamOS root filesystem temporarily. The filesystem will be relocked"
    echo "afterward when steamos-readonly is available."

    if ! confirm_yn "Install the missing packages with pacman -Syu now?"; then
        die "Required test dependencies are missing."
    fi

    if command -v steamos-readonly >/dev/null 2>&1; then
        steamos-readonly disable ||
            die "Could not disable the SteamOS read-only filesystem."
        readonly_disabled=1
    fi

    if command -v pacman-key >/dev/null 2>&1; then
        pacman-key --init ||
            {
                (( readonly_disabled )) && steamos-readonly enable || true
                die "pacman-key --init failed."
            }
        pacman-key --populate ||
            {
                (( readonly_disabled )) && steamos-readonly enable || true
                die "pacman-key --populate failed."
            }
    fi

    if ! pacman -Syu --noconfirm --needed "${packages[@]}"; then
        (( readonly_disabled )) && steamos-readonly enable || true
        die "Package installation failed."
    fi

    if (( readonly_disabled )); then
        steamos-readonly enable ||
            die "Packages were installed, but the SteamOS root filesystem could not be relocked."
    fi
}

check_test_dependencies() {
    local missing=()

    if (( RUN_CPU )) && ! command -v stress-ng >/dev/null 2>&1; then
        missing+=("stress-ng")
    fi
    if (( RUN_GPU )) && ! command -v vkmark >/dev/null 2>&1; then
        missing+=("vkmark")
    fi

    (( ${#missing[@]} == 0 )) && return 0

    install_missing_dependencies "${missing[@]}"

    local package
    for package in "${missing[@]}"; do
        command -v "$package" >/dev/null 2>&1 ||
            die "Package installation completed, but ${package} is still unavailable."
    done
}

# -----------------------------------------------------------------------------
# Toolkit discovery
# -----------------------------------------------------------------------------
find_cpu_backend() {
    if [[ ! -f "$BC250_OC_DIR/bc250_smu/api.py" ]]; then
        die "bc250_smu_oc runtime files are missing from $BC250_OC_DIR. Install them before running this test."
    fi

    [[ -f "$BC250_OC_DIR/bc250_smu/api.py" ]] ||
        die "bc250_smu library is still missing."

    log "Using bc250_smu_oc backend: $BC250_OC_DIR"
}

capture_cpu_baseline() {
    local values

    values="$(
        PYTHONPATH="$BC250_OC_DIR${PYTHONPATH:+:$PYTHONPATH}" \
            python3 - 2>/dev/null <<'PY'
from bc250_smu import Bc250Smu

smu = Bc250Smu(use_flock=True)
try:
    print(smu.q3_0x43_get_core_freq(0), smu.q3_0x40_get_cpu_temp_max())
finally:
    smu.close()
PY
    )"

    read -r BASELINE_CPU_FREQ BASELINE_TEMP <<< "$values"
    if [[ "$BASELINE_CPU_FREQ" =~ ^[0-9]+$ ]] &&
        [[ "$BASELINE_TEMP" =~ ^[0-9]+$ ]]; then
        log "SMU CPU clock/temperature found, but the VID-curve scale has no SMU readback API."
        log "Using the complete stable CPU fallback because the SMU baseline is incomplete."
        BASELINE_CPU_FREQ=3500
        BASELINE_CPU_SCALE=0
        BASELINE_TEMP=100
        CPU_BASELINE_SOURCE="stable fallback (SMU curve unavailable)"
        return 1
    fi

    BASELINE_CPU_FREQ=3500
    BASELINE_CPU_SCALE=0
    BASELINE_TEMP=100
    CPU_BASELINE_SOURCE="stable fallback"
    log "SMU CPU baseline readback unavailable; using stable fallback after testing."
    return 1
}

find_direct_gpu_backend() {
    [[ -f "$BC250_OC_DIR/bc250_smu/api_q0.py" ]] ||
        die "bc250_smu queue-0 GPU API is missing from $BC250_OC_DIR"

    log "Using direct bc250_smu queue-0 GPU backend: $BC250_OC_DIR"
}

unit_exists() {
    local wanted="$1"

    [[ -n "$wanted" ]] || return 1

    # awk has to consume the whole stream. `systemctl ... | awk | grep -qx`
    # fails under `set -o pipefail`: as soon as grep -q matches it closes the
    # pipe, awk dies of SIGPIPE (141) and the pipeline reports failure even
    # though the unit was found. That silently disabled every service stop, so
    # the GPU governor kept running through the whole sweep.
    systemctl list-unit-files --type=service --no-legend 2>/dev/null |
        awk -v wanted="$wanted" '$1 == wanted { found = 1 } END { exit !found }'
}

smu_config_path() {
    printf '/sys/bus/pci/devices/0000:00:00.0/config'
}

smu_client_pids() {
    # PIDs that currently hold the SMU PCI config file open. bc250_smu and the
    # cyan-skillfish governor both drive the same mailbox through this file, so
    # any process listed here can overwrite a test point mid-interval.
    local config

    config="$(smu_config_path)"

    if command -v lsof >/dev/null 2>&1; then
        lsof -t "$config" 2>/dev/null | sort -u
        return 0
    fi

    pgrep -f 'cyan-skillfish-governor' 2>/dev/null | sort -u
}

find_services() {
    local unit

    for unit in cyan-skillfish-governor-smu.service \
        cyan-skillfish-governor.service \
        cyan-skillfish-governor-tt.service \
        oberon-governor.service; do

        if unit_exists "$unit"; then
            GPU_CONFLICT_UNITS+=("$unit")
        fi
    done

    for unit in bc250-smu-oc.service; do
        if unit_exists "$unit"; then
            CPU_CONFLICT_UNITS+=("$unit")
        fi
    done

    if (( ${#GPU_CONFLICT_UNITS[@]} == 0 )); then
        log "WARNING: no known GPU SMU governor unit found; a competing SMU client would invalidate the sweep."
    fi
}

stop_unit_and_verify() {
    local unit="$1"
    local attempt

    log "Stopping conflicting SMU service: $unit"

    systemctl stop "$unit" || return 1

    for ((attempt = 1; attempt <= 20; attempt++)); do
        if ! systemctl is-active --quiet "$unit"; then
            log "Confirmed stopped: $unit"
            return 0
        fi
        sleep 0.5
    done

    log "ERROR: $unit is still active after systemctl stop."
    return 1
}

stop_conflicting_services() {
    local unit

    for unit in "${GPU_CONFLICT_UNITS[@]}"; do
        if systemctl is-active --quiet "$unit"; then
            ORIG_GPU_SERVICE_ACTIVE=1

            stop_unit_and_verify "$unit" ||
                die "Could not stop GPU SMU client $unit. The sweep would measure that client's voltage instead of the test point."

            STOPPED_GPU_UNITS+=("$unit")
        fi
    done

    for unit in "${CPU_CONFLICT_UNITS[@]}"; do
        if systemctl is-active --quiet "$unit"; then
            ORIG_CPU_SERVICE_ACTIVE=1

            stop_unit_and_verify "$unit" ||
                die "Could not stop CPU OC service $unit."

            STOPPED_CPU_UNITS+=("$unit")
        fi
    done
}

verify_smu_exclusive() {
    # Confirm that nothing else still drives the SMU mailbox. Called before the
    # GPU sweep starts; a false pass here is what made the old results look
    # healthy while the governor was forcing its own point.
    local attempt
    local pids
    local clean_samples=0

    for ((attempt = 1; attempt <= 10; attempt++)); do
        pids="$(smu_client_pids)"

        if [[ -z "$pids" ]]; then
            clean_samples=$((clean_samples + 1))
            if (( clean_samples >= 2 )); then
                return 0
            fi
        else
            clean_samples=0
        fi

        sleep 0.5
    done

    for pids in $(smu_client_pids); do
        log "ERROR: PID ${pids} ($(ps -o comm= -p "$pids" 2>/dev/null || printf 'unknown')) holds $(smu_config_path)."
    done

    return 1
}

assert_smu_exclusive() {
    # Cheap single-shot version used before each GPU point.
    local pids

    pids="$(smu_client_pids)"
    [[ -z "$pids" ]] && return 0

    log "ERROR: another SMU client is active again: $(ps -o pid=,comm= -p $pids 2>/dev/null | awk '{printf "%s(%s) ", $1, $2}')"
    return 1
}

# -----------------------------------------------------------------------------
# CPU: bc250_smu_oc direct CPU-only SMU operations
# -----------------------------------------------------------------------------
set_cpu_point() {
    local scale="$1"
    local applied_vid
    local error_file="/tmp/bc250-silicon-cpu-point-$$.err"

    applied_vid="$(
        PYTHONPATH="$BC250_OC_DIR${PYTHONPATH:+:$PYTHONPATH}" \
        python3 - "$CPU_FREQ" "$scale" "$CPU_TEST_TEMP" 2>"$error_file" <<'PY'
import sys
import time
from bc250_smu import Bc250Smu

frequency = int(sys.argv[1])
scale = int(sys.argv[2])
cpu_temp = int(sys.argv[3])

smu = Bc250Smu(use_flock=True)

try:
    smu.check_test_message()
    smu.q3_0x8b_set_cpu_max_temperature(cpu_temp)
    time.sleep(1.0)
    applied_temp = smu.q3_0x40_get_cpu_temp_max()
    if applied_temp != cpu_temp:
        raise RuntimeError(
            f"CPU temperature readback was {applied_temp} C, expected {cpu_temp} C"
        )

    # Match bc250_smu_oc's apply sequence. This is required before changing
    # the CPU VID curve, but does not set a GPU temperature or GPU clock.
    smu.disable_extra_cpu_gpu_voltage(True)
    smu.q3_0x50_scale_f_vid_curve(scale)
    smu.q3_0x8f_set_max_cpu_boost_clk(frequency)
    time.sleep(1.0)
    print(smu.q3_0x36_get_current_cpu_voltage())
except Exception as error:
    print(f"CPU SMU point failed: {error}", file=sys.stderr)
    raise SystemExit(1)
finally:
    smu.close()
PY
    )"
    local status=$?
    if (( status != 0 )); then
        if [[ -s "$error_file" ]]; then
            log "CPU SMU point attempt failed: $(<"$error_file")"
        else
            log "CPU SMU point attempt failed without an error message."
        fi
        rm -f "$error_file"
        return "$status"
    fi
    rm -f "$error_file"

    [[ "$applied_vid" =~ ^[0-9]+$ ]] || {
        log "ERROR: CPU VID readback was invalid: ${applied_vid:-empty}"
        return 1
    }
    CPU_POINT_VID="$applied_vid"
}

retry_smu_operation() {
    local description="$1"
    shift
    local attempt

    for ((attempt = 1; attempt <= SMU_RETRIES; attempt++)); do
        if "$@"; then
            return 0
        fi
        local status=$?
        if (( status == 2 )); then
            return 2
        fi

        if (( attempt < SMU_RETRIES )); then
            log "Retrying ${description} (${attempt}/${SMU_RETRIES})..."
            sleep 1
        fi
    done

    log "Unable to complete ${description} after ${SMU_RETRIES} attempts."
    return 1
}

restore_cpu_baseline() {
    PYTHONPATH="$BC250_OC_DIR${PYTHONPATH:+:$PYTHONPATH}" \
        python3 - "$BASELINE_CPU_FREQ" "$BASELINE_CPU_SCALE" "$BASELINE_TEMP" 2>/dev/null <<'PY'
import sys
import time
from bc250_smu import Bc250Smu

frequency = int(sys.argv[1])
scale = int(sys.argv[2])
temp = int(sys.argv[3])

last_error = None

# A stressor failure can leave the SMU mailbox in the middle of a command.
# Reconnect and probe it before retrying the complete, ordered baseline
# sequence instead of reusing a session with a stale mailbox state.
for attempt in range(3):
    smu = None
    try:
        smu = Bc250Smu(use_flock=True)
        smu.check_test_message()
        smu.q3_0x8b_set_cpu_max_temperature(temp)
        time.sleep(1.0)
        if smu.q3_0x40_get_cpu_temp_max() != temp:
            raise RuntimeError("CPU baseline temperature readback mismatch")
        smu.disable_extra_cpu_gpu_voltage(True)
        smu.q3_0x50_scale_f_vid_curve(scale)
        smu.q3_0x8f_set_max_cpu_boost_clk(frequency)
        time.sleep(1.0)
        applied_clock = smu.q3_0x43_get_core_freq(0)
        if not int(frequency * 0.9) <= applied_clock <= int(frequency * 1.1):
            raise RuntimeError("CPU baseline clock readback mismatch")
        break
    except (OSError, RuntimeError) as error:
        last_error = error
        if attempt == 2:
            raise
        time.sleep(0.5)
    finally:
        if smu is not None:
            smu.close()
else:
    raise RuntimeError("CPU baseline restoration failed") from last_error
PY
}

start_cpu_stress() {
    log "Starting CPU stressor: stress-ng --cpu 0"

    stress-ng --cpu 0 --timeout 0 \
        >/tmp/bc250-silicon-stress-ng.log 2>&1 &

    stress_pid=$!

    sleep 1

    kill -0 "$stress_pid" 2>/dev/null ||
        die "stress-ng exited immediately."
}

stop_cpu_stress() {
    if [[ -n "$stress_pid" ]] &&
        kill -0 "$stress_pid" 2>/dev/null; then

        kill "$stress_pid" 2>/dev/null || true
        wait "$stress_pid" 2>/dev/null || true
    fi

    stress_pid=""
}

read_cpu_temperature() {
    local path
    local hwmon_dir
    local name
    local value

    for path in /sys/class/hwmon/hwmon*/temp*_input; do
        [[ -r "$path" ]] || continue
        hwmon_dir="${path%/*}"
        name="$(cat "$hwmon_dir/name" 2>/dev/null || true)"
        [[ "$name" == k10temp ]] || continue
        value="$(<"$path")"
        [[ "$value" =~ ^[0-9]+$ ]] || continue
        awk -v value="$value" 'BEGIN { printf "%.1fC", value / 1000 }'
        return 0
    done

    for path in /sys/class/thermal/thermal_zone*/temp; do
        [[ -r "$path" ]] || continue
        value="$(<"$path")"
        [[ "$value" =~ ^[0-9]+$ ]] || continue
        awk -v value="$value" 'BEGIN { printf "%.1fC", value / 1000 }'
        return 0
    done

    printf 'unavailable'
}

read_cpu_clock() {
    local clock

    clock="$(awk -F: '/^[[:space:]]*cpu MHz[[:space:]]*:/ {
        gsub(/[[:space:]]/, "", $2)
        printf "%.0fMHz", $2
        exit
    }' /proc/cpuinfo 2>/dev/null)"
    printf '%s' "${clock:-unavailable}"
}

read_cpu_voltage() {
    local voltage

    voltage="$(
        PYTHONPATH="$BC250_OC_DIR${PYTHONPATH:+:$PYTHONPATH}" \
            python3 - <<'PY' 2>/dev/null
from bc250_smu import Bc250Smu

smu = Bc250Smu(use_flock=True)
try:
    print(smu.q3_0x36_get_current_cpu_voltage())
finally:
    smu.close()
PY
    )"

    [[ "$voltage" =~ ^[0-9]+$ ]] && printf '%smV' "$voltage" || printf 'unavailable'
}

read_gpu_temperature() {
    local path
    local hwmon_dir
    local name
    local value

    for path in /sys/class/hwmon/hwmon*/temp*_input; do
        [[ -r "$path" ]] || continue
        hwmon_dir="${path%/*}"
        name="$(cat "$hwmon_dir/name" 2>/dev/null || true)"
        [[ "$name" == amdgpu* || "$name" == *gpu* ]] || continue
        value="$(<"$path")"
        [[ "$value" =~ ^[0-9]+$ ]] || continue
        awk -v value="$value" 'BEGIN { printf "%.1fC", value / 1000 }'
        return 0
    done

    printf 'unavailable'
}

read_gpu_point_state() {
    # One SMU session per sample (the governor and other clients own the
    # transport at other times), returning "<clock_mhz> <voltage_mv>".
    PYTHONPATH="$BC250_OC_DIR${PYTHONPATH:+:$PYTHONPATH}" \
        python3 - "$SMU_MAILBOX_POLLS" <<'PY' 2>/dev/null
import sys
from bc250_smu import Bc250Smu

polls = int(sys.argv[1])
smu = Bc250Smu(allow_queue0=True, use_flock=True, timeout=polls)
try:
    print(int(smu.get_gfx_frequency()), int(smu.q3_0x37_get_current_gpu_voltage()))
finally:
    smu.close()
PY
}

read_gpu_clock() {
    local state clock

    state="$(read_gpu_point_state)"

    # Queue-0 0x37 returns the live SMU-reported GFX clock, not GPU_FREQ.
    read -r clock _ <<< "$state"

    [[ "$clock" =~ ^[0-9]+$ ]] && printf '%sMHz' "$clock" || printf 'unavailable'
}

read_gpu_voltage() {
    local state voltage

    state="$(read_gpu_point_state)"

    read -r _ voltage <<< "$state"

    if [[ "$voltage" =~ ^[0-9]+$ ]]; then
        printf '%smV' "$voltage"
    else
        printf 'unavailable'
    fi
}

read_gpu_voltage_mv() {
    local state voltage

    state="$(read_gpu_point_state)"

    read -r _ voltage <<< "$state"

    [[ "$voltage" =~ ^[0-9]+$ ]] && printf '%s' "$voltage" || printf 'unavailable'
}

throttle_warning() {
    local temperature="$1"
    local clock="$2"
    local max_temperature="$3"
    local requested_clock="$4"
    local temperature_margin=1
    local clock_margin=50
    local temperature_value="${temperature%C}"
    local clock_value="${clock%MHz}"

    [[ "$temperature_value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
    [[ "$clock_value" =~ ^[0-9]+$ ]] || return 0

    if awk -v temperature="$temperature_value" -v limit="$max_temperature" \
        -v temp_margin="$temperature_margin" -v clock="$clock_value" \
        -v requested="$requested_clock" -v clock_margin="$clock_margin" \
        'BEGIN { exit !(temperature >= limit - temp_margin && clock <= requested - clock_margin) }'; then
        printf ' [WARNING: possible thermal throttling]'
    fi
}

gpu_sample_matches_target() {
    # $1 live clock (MHz), $2 live voltage (mV), $3 requested clock, $4 requested mV
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    [[ "$2" =~ ^[0-9]+$ ]] || return 1
    [[ "$3" =~ ^[0-9]+$ ]] || return 1
    [[ "$4" =~ ^[0-9]+$ ]] || return 1

    (( 10#$1 == 10#$3 )) || return 1
    (( 10#$2 >= 10#$4 - GPU_MV_TOLERANCE )) || return 1
    (( 10#$2 <= 10#$4 + GPU_MV_TOLERANCE )) || return 1
}

verify_gpu_point() {
    local requested_clock="$1"
    local requested_mv="$2"
    local state
    local last_state=""
    local observed_clock
    local observed_mv
    local attempt
    local verified=0

    # The governor ramps from the previous point, so poll instead of treating
    # the first instantaneous sample as the applied setting. Both the clock and
    # the voltage must match: a point can sit at 1500 MHz while another SMU
    # client (or the firmware) has pushed the voltage back to its own value -
    # that is exactly the case that used to be logged as a PASS.
    for ((attempt = 1; attempt <= 10; attempt++)); do
        state="$(read_gpu_point_state)"
        read -r observed_clock observed_mv <<< "$state"

        if gpu_sample_matches_target "$observed_clock" "$observed_mv" \
            "$requested_clock" "$requested_mv"; then

            log "GPU point verified under stress: ${observed_clock} MHz / ${observed_mv} mV (requested ${requested_clock} MHz / ${requested_mv} mV)."
            GPU_POINT_LIVE_MV="$observed_mv"
            verified=1
            break
        fi

        if [[ "$observed_clock" =~ ^[0-9]+$ ]] && [[ "$observed_mv" =~ ^[0-9]+$ ]]; then
            # Only report a change (or the last attempt): the SMU ramps in
            # small steps and one line per poll is just noise.
            if [[ "$state" != "$last_state" || "$attempt" -eq 10 ]]; then
                log "Waiting for the GPU point to settle: live ${observed_clock} MHz / ${observed_mv} mV, requested ${requested_clock} MHz / ${requested_mv} mV."
                last_state="$state"
            fi
        else
            log "Waiting for a valid GPU readback: '${state:-empty}'."
        fi

        (( attempt < 10 )) && sleep 0.5
    done

    if (( ! verified )); then
        log "ERROR: the GPU point did not hold ${requested_clock} MHz / ${requested_mv} mV within the settling window."
        return 1
    fi
}

report_telemetry() {
    local phase="$1"
    local elapsed="$2"
    local temperature
    local state
    local clock
    local voltage
    local warning
    local verdict

    if [[ "$phase" == "CPU" ]]; then
        temperature="$(read_cpu_temperature)"
        clock="$(read_cpu_clock)"
        voltage="$(read_cpu_voltage)"
        warning="$(throttle_warning "$temperature" "$clock" "$CPU_TEST_TEMP" "$CPU_FREQ")"
        printf '  [%s/%ss] CPU telemetry: temp %s, clock %s, current voltage %s%s\n' \
            "$elapsed" "$CPU_TEST_SECONDS" "$temperature" "$clock" "$voltage" "$warning"
    else
        temperature="$(read_gpu_temperature)"
        state="$(read_gpu_point_state)"
        read -r clock voltage <<< "$state"
        warning="$(throttle_warning "$temperature" "${clock}MHz" "$GPU_TEST_TEMP" "$GPU_FREQ")"

        if gpu_sample_matches_target "$clock" "$voltage" \
            "$GPU_FREQ" "$GPU_POINT_REQ_MV"; then

            verdict=""
            GPU_POINT_GOOD_SAMPLES=$((GPU_POINT_GOOD_SAMPLES + 1))
        else
            verdict=" <-- MISMATCH, point was not held"
            GPU_POINT_BAD_SAMPLES=$((GPU_POINT_BAD_SAMPLES + 1))
        fi

        printf '  [%s/%ss] GPU telemetry: temp %s, SMU clock %sMHz, live voltage %smV (requested %sMHz / %smV)%s%s\n' \
            "$elapsed" "$GPU_TEST_SECONDS" "$temperature" "${clock:-unavailable}" \
            "${voltage:-unavailable}" "$GPU_FREQ" "$GPU_POINT_REQ_MV" "$warning" "$verdict"
    fi
}

run_test_interval() {
    local phase="$1"
    local duration="$2"
    local elapsed=0
    local interval

    while (( elapsed < duration )); do
        interval=5
        (( duration - elapsed < interval )) && interval=$((duration - elapsed))
        if [[ "$phase" == "GPU" ]] &&
            ! kill -0 "$vkmark_pid" 2>/dev/null; then
            return 2
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        if [[ "$phase" == "GPU" ]] &&
            ! kill -0 "$vkmark_pid" 2>/dev/null; then
            return 2
        fi
        report_telemetry "$phase" "$elapsed"
    done
}

run_cpu_test() {
    local scale="$CPU_START_SCALE"
    local last_pass=""
    local interval_status=0
    local point_status=0
    CPU_LAST_PASS="none"
    CPU_LAST_PASS_VID="none"
    CPU_POINT_VID="none"
    CPU_VID_HISTORY=""
    CPU_FAILURE_POINT="none"
    CPU_FAILURE_REASON=""

    echo
    echo "=============================================="
    echo " CPU SILICON QUALITY SWEEP"
    echo "=============================================="
    echo "Clock:      ${CPU_FREQ} MHz"
    echo "Start:      ${CPU_START_SCALE}"
    echo "Step:       ${CPU_STEP}"
    echo "Floor:      ${CPU_MIN_SCALE}"
    echo "Per point:  ${CPU_TEST_SECONDS} seconds"
    echo "Max temp:   ${CPU_TEST_TEMP}C"
    echo

    start_cpu_stress

    while (( scale >= CPU_MIN_SCALE )); do
        # State is written before applying the point because applying a point
        # may hard-freeze the machine before the script can write anything else.
        write_state CPU "$scale" "$last_pass"

        log "Applying CPU scale ${scale} (CPU temp ${CPU_TEST_TEMP} C)"

        point_status=0
        retry_smu_operation "CPU scale ${scale}" set_cpu_point "$scale" ||
            point_status=$?
        if (( point_status != 0 )); then
            stop_cpu_stress

            echo
            echo "CPU: FAILURE"
            echo "CPU failure candidate = ${scale}"
            echo "CPU last confirmed pass = ${last_pass:-none}"
            echo "Reason: the CPU SMU point could not be applied after ${SMU_RETRIES} attempts."
            echo "The point is classified as a failed CPU test setup."
            CPU_FAILURE_REASON="CPU SMU point could not be applied after ${SMU_RETRIES} attempts."
            CPU_LAST_PASS="${last_pass:-none}"
            CPU_FAILURE_POINT="$scale"
            restore_cpu_baseline ||
                die "CPU SMU setup failure detected, but CPU baseline restoration failed."
            return 13
        fi

        state_set_field cpu_vid_mv "$CPU_POINT_VID"
        CPU_VID_HISTORY+="${CPU_VID_HISTORY:+, }scale=${scale}:current=${CPU_POINT_VID}mV"
        state_set_field cpu_vid_history "$CPU_VID_HISTORY"
        log "CPU point active: ${CPU_FREQ} MHz / scale ${scale} / current ${CPU_POINT_VID} mV / CPU ${CPU_TEST_TEMP} C"

        interval_status=0
        run_test_interval CPU "$CPU_TEST_SECONDS" || interval_status=$?

        if ! kill -0 "$stress_pid" 2>/dev/null; then
            stop_cpu_stress

            echo
            echo "CPU: FAILURE"
            echo "CPU failure candidate = ${scale}"
            echo "CPU last confirmed pass = ${last_pass:-none}"
            echo "Reason: stress-ng exited unexpectedly during the ${scale} test point."
            echo "The point is classified as a failed silicon-quality test point."
            echo "Restoring the CPU baseline before continuing."
            CPU_LAST_PASS="${last_pass:-none}"
            CPU_FAILURE_POINT="$scale"
            CPU_FAILURE_REASON="stress-ng exited unexpectedly during the ${scale} test point."

            if ! restore_cpu_baseline; then
                log "WARNING: CPU baseline restoration was not confirmed; continuing to GPU silicon testing."
            fi

            return 10
        fi

        last_pass="$scale"
        CPU_LAST_PASS="$last_pass"
        CPU_LAST_PASS_VID="$CPU_POINT_VID"

        echo "  CPU ${CPU_FREQ} MHz / ${scale}: PASS"
        write_state CPU "$scale" "$last_pass"

        scale=$((scale + CPU_STEP))
    done

    stop_cpu_stress

    echo
    echo "CPU sweep reached configured floor without a quick hard-lock."
    return 0
}

# -----------------------------------------------------------------------------
# GPU: direct Bc250Smu queue-0 backend
# -----------------------------------------------------------------------------
write_gpu_temp_limit() {
    local temp="$1"
    local error_file="/tmp/bc250-silicon-gpu-temp-$$.err"

    PYTHONPATH="$BC250_OC_DIR${PYTHONPATH:+:$PYTHONPATH}" \
        python3 - "$temp" "$SMU_MAILBOX_POLLS" 2>"$error_file" <<'__PY__'
import sys
import time
from bc250_smu import Bc250Smu

target = int(sys.argv[1])
polls = int(sys.argv[2])
smu = Bc250Smu(allow_queue0=True, use_flock=True, timeout=polls)
try:
    smu.q3_0x8c_set_gpu_max_temperature(target)
    time.sleep(0.5)
finally:
    smu.close()
__PY__
    local rc=$?
    if (( rc != 0 )); then
        [[ -s "$error_file" ]] && log "GPU temperature SMU error: $(<"$error_file")"
        rm -f "$error_file"
        return "$rc"
    fi
    rm -f "$error_file"

    local hwmon_max
    hwmon_max="$(read_gpu_hwmon_max_temperature 2>/dev/null || true)"
    if [[ "$hwmon_max" =~ ^[0-9]+$ ]]; then
        if (( hwmon_max != temp )); then
            log "ERROR: GPU hwmon temperature limit reads ${hwmon_max}C, expected ${temp}C."
            return 1
        fi
        log "GPU temperature limit independently verified at ${hwmon_max}C via hwmon."
    else
        log "GPU temperature limit command accepted, but the kernel exposes no temp*_max readback to confirm it; treat the ${temp}C limit as unverified and watch the telemetry temperature."
    fi
}

write_gpu_temp_baseline() {
    local temp="${1:-90}"
    write_gpu_temp_limit "$temp"
}

read_gpu_hwmon_max_temperature() {
    local path hwmon_dir name value
    for path in /sys/class/hwmon/hwmon*/temp*_max; do
        [[ -r "$path" ]] || continue
        hwmon_dir="${path%/*}"
        name="$(cat "$hwmon_dir/name" 2>/dev/null || true)"
        [[ "$name" == amdgpu* || "$name" == *gpu* ]] || continue
        value="$(<"$path")"
        [[ "$value" =~ ^[0-9]+$ ]] || continue
        printf '%d\n' "$((value / 1000))"
        return 0
    done
    return 1
}

apply_gpu_point() {
    local mv="$1"
    local quiet="${2:-0}"
    local attempt
    local output_file="/tmp/bc250-silicon-gpu-apply-$$.out"
    local error_file="/tmp/bc250-silicon-gpu-apply-$$.err"
    local live_mv

    (( quiet )) || log "Applying GPU SMU point at ${GPU_FREQ} MHz / ${mv} mV"
    for ((attempt = 1; attempt <= SMU_RETRIES; attempt++)); do
        : > "$output_file"
        if PYTHONPATH="$BC250_OC_DIR${PYTHONPATH:+:$PYTHONPATH}" \
                python3 - "$GPU_FREQ" "$mv" "$SMU_MAILBOX_POLLS" "$GPU_MV_TOLERANCE" \
                1>"$output_file" 2>"$error_file" <<'__PY__'
import sys
import time
from bc250_smu import Bc250Smu

frequency = int(sys.argv[1])
voltage_mv = int(sys.argv[2])
polls = int(sys.argv[3])
tolerance_mv = int(sys.argv[4])

# IMPORTANT: bc250_smu's force_gfx_vid() already converts millivolts to
# the SVI2 VID code internally. Passing a pre-converted VID here would
# double-convert the voltage and can cause a severe undervoltage/crash.
# A longer mailbox poll budget keeps a busy SMU from being reported as
# "no response" (status 0x00) while a stressor hammers the GPU.
smu = Bc250Smu(allow_queue0=True, use_flock=True, timeout=polls)
try:
    smu.check_test_message()

    # Match cyan-skillfish-governor-smu's proven initialization/point order:
    # clear previous forced state, then voltage, then frequency.
    smu.unforce_gfx_freq()
    smu.unforce_gfx_vid()
    time.sleep(0.15)

    smu.force_gfx_vid(voltage_mv)
    time.sleep(0.10)
    smu.force_gfx_freq(frequency)

    # Poll instead of sampling once: the SMU ramps to the new point and a
    # single immediate read is what made this fail intermittently.
    deadline = time.time() + 5.0
    live_freq = 0
    live_mv = 0
    while True:
        live_freq = int(smu.get_gfx_frequency())
        live_mv = int(smu.q3_0x37_get_current_gpu_voltage())

        if live_freq == frequency and abs(live_mv - voltage_mv) <= tolerance_mv:
            break
        if time.time() >= deadline:
            break
        time.sleep(0.25)

    if live_freq != frequency:
        raise RuntimeError(
            f"GPU frequency verification failed: requested {frequency}MHz, "
            f"live {live_freq}MHz"
        )

    if abs(live_mv - voltage_mv) > tolerance_mv:
        raise RuntimeError(
            f"GPU voltage verification failed: requested {voltage_mv}mV, "
            f"live {live_mv}mV (maximum allowed deviation is {tolerance_mv}mV)"
        )

    print(f"{live_freq} {live_mv}")
except Exception as error:
    print(f"GPU SMU apply/verify failed: {error}", file=sys.stderr)
    raise SystemExit(1)
finally:
    smu.close()
__PY__
        then
            live_mv="$(awk '{print $2}' "$output_file")"
            rm -f "$error_file"
            GPU_POINT_LIVE_MV="${live_mv:-none}"

            if (( attempt > 1 )); then
                log "GPU SMU apply/verification succeeded on retry attempt ${attempt}."
            fi

            log "GPU point applied and verified: ${GPU_FREQ} MHz / ${mv} mV requested, live ${live_mv:-unknown} mV."
            return 0
        fi
        if [[ -s "$error_file" ]]; then
            log "GPU SMU apply/verification attempt ${attempt} failed: $(<"$error_file")"
        else
            log "GPU SMU apply/verification attempt ${attempt} failed without an error message."
        fi
        (( attempt < SMU_RETRIES )) && sleep 0.75
    done

    rm -f "$output_file" "$error_file"
    log "Unable to apply and independently verify GPU point after ${SMU_RETRIES} attempts."
    return 14
}


start_gpu_point() {
    local mv="$1"

    if ! retry_smu_operation "GPU temperature limit ${GPU_TEST_TEMP} C" \
        write_gpu_temp_limit "$GPU_TEST_TEMP"; then
        log "ERROR: Could not apply/verify GPU temperature limit ${GPU_TEST_TEMP} C after ${SMU_RETRIES} attempts."
        return 13
    fi

    apply_gpu_point "$mv" ||
        return 14

}

clear_gpu_point() {
    PYTHONPATH="$BC250_OC_DIR${PYTHONPATH:+:$PYTHONPATH}" \
        python3 - 2>/dev/null <<'__PY__'
import time
from bc250_smu import Bc250Smu

smu = Bc250Smu(allow_queue0=True, use_flock=True)
try:
    smu.unforce_gfx_freq()
    smu.unforce_gfx_vid()
    time.sleep(0.5)
finally:
    smu.close()
__PY__
}

start_gpu_stress() {
    local vk_args=()
    local forced_winsys=0

    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        vk_args+=(--winsys wayland)
        forced_winsys=1
    elif [[ -n "${DISPLAY:-}" ]]; then
        vk_args+=(--winsys xcb)
        forced_winsys=1
    fi

    if (( forced_winsys )); then
        log "Starting GPU stressor: vkmark ${vk_args[*]} --run-forever"
    else
        log "Starting GPU stressor: vkmark --run-forever (automatic window system)"
    fi

    vkmark "${vk_args[@]}" --run-forever \
        >/tmp/bc250-silicon-vkmark.log 2>&1 &

    vkmark_pid=$!

    sleep 2

    if ! kill -0 "$vkmark_pid" 2>/dev/null; then
        wait "$vkmark_pid" 2>/dev/null || true

        # Some vkmark packages ship the KMS option but not its runtime
        # plugin. Retry with backend auto-selection before reporting a
        # genuine GPU stressor failure.
        if (( forced_winsys )) &&
            grep -qE 'Failed to find specified window system|window system plugin' \
                /tmp/bc250-silicon-vkmark.log; then
            log "vkmark ${vk_args[*]} backend unavailable; retrying automatic selection."

            vk_args=()
            log "Starting GPU stressor: vkmark --run-forever (automatic window system)"
            vkmark --run-forever \
                >/tmp/bc250-silicon-vkmark.log 2>&1 &
            vkmark_pid=$!
            sleep 2
        fi
    fi

    kill -0 "$vkmark_pid" 2>/dev/null ||
        die "vkmark exited immediately. Check /tmp/bc250-silicon-vkmark.log"
}

stop_gpu_stress() {
    if [[ -n "$vkmark_pid" ]] &&
        kill -0 "$vkmark_pid" 2>/dev/null; then

        kill "$vkmark_pid" 2>/dev/null || true
        wait "$vkmark_pid" 2>/dev/null || true
    fi

    vkmark_pid=""
}

report_gpu_point_failure() {
    local mv="$1"
    local last_pass="$2"
    local reason="$3"

    echo
    echo "GPU: FAILURE"
    echo "GPU failure candidate = ${mv} mV"
    echo "GPU last confirmed pass = ${last_pass:-none} mV"
    echo "Reason: ${reason}"

    if (( GPU_INVALID )); then
        echo "This point is reported as an INVALID MEASUREMENT, not a silicon failure:"
        echo "the GPU did not keep the forced test point, so this point says nothing"
        echo "about silicon quality either way."
    else
        echo "The point is classified as a failed silicon-quality test point."
    fi

    GPU_LAST_PASS="${last_pass:-none}"
    GPU_FAILURE_POINT="$mv"
    GPU_FAILURE_REASON="$reason"
}

run_gpu_test() {
    local mv="$GPU_START_MV"
    local last_pass=""
    local interval_status=0
    local point_status=0
    local point_try
    local point_ok
    local samples_total

    GPU_LAST_PASS="none"
    GPU_FAILURE_POINT="none"
    GPU_FAILURE_REASON=""
    GPU_INVALID=0
    GPU_INVALID_REASON=""

    # Hard gate: the sweep is only meaningful while this test is the only SMU
    # client. Everything below assumes the forced point survives the interval.
    if ! verify_smu_exclusive; then
        GPU_INVALID=1
        GPU_INVALID_REASON="another process was still driving the SMU mailbox when the sweep started"

        report_gpu_point_failure "${mv}" "none" \
            "the sweep was not started because another SMU client is active."
        return 15
    fi

    log "SMU mailbox confirmed exclusive to this test."

    echo
    echo "=============================================="
    echo " GPU SILICON QUALITY SWEEP"
    echo "=============================================="
    echo "Clock:      ${GPU_FREQ} MHz"
    echo "Start:      ${GPU_START_MV} mV"
    echo "Step:       ${GPU_STEP_MV} mV"
    echo "Floor:      ${GPU_MIN_MV} mV"
    echo "Per point:  ${GPU_TEST_SECONDS} seconds"
    echo "Max temp:   ${GPU_TEST_TEMP}C"
    echo

    while (( mv >= GPU_MIN_MV )); do
        # State is written before applying the SMU point because the operation
        # may hard-freeze the machine.
        write_state GPU "$mv" "$last_pass"

        # Any other SMU client would overwrite the point mid-interval, which is
        # how the sweep used to report PASSes for a voltage it never applied.
        if ! assert_smu_exclusive; then
            GPU_INVALID=1
            GPU_INVALID_REASON="another SMU client took the mailbox during the sweep"

            report_gpu_point_failure "$mv" "$last_pass" \
                "another SMU client is active again, so the ${mv} mV point cannot be measured."
            return 15
        fi

        point_ok=0
        for ((point_try = 1; point_try <= GPU_POINT_TRIES; point_try++)); do
            GPU_POINT_REQ_MV="$mv"
            GPU_POINT_LIVE_MV="none"
            GPU_POINT_GOOD_SAMPLES=0
            GPU_POINT_BAD_SAMPLES=0

            point_status=0
            start_gpu_point "$mv" || point_status=$?
            if (( point_status != 0 )); then
                if (( point_try < GPU_POINT_TRIES )); then
                    log "Restarting the ${mv} mV point from the start (${point_try}/${GPU_POINT_TRIES})."
                    stop_gpu_stress
                    sleep 1
                    continue
                fi

                if (( point_status == 13 )); then
                    report_gpu_point_failure "$mv" "$last_pass" \
                        "the GPU temperature limit could not be applied before this test point."
                    return 13
                fi

                GPU_INVALID=1
                GPU_INVALID_REASON="the GPU SMU point could not be applied and verified"

                report_gpu_point_failure "$mv" "$last_pass" \
                    "the GPU SMU point ${GPU_FREQ} MHz / ${mv} mV could not be applied and verified."
                return 14
            fi

            start_gpu_stress

            log "GPU point active: ${GPU_FREQ} MHz / ${mv} mV / GPU ${GPU_TEST_TEMP}C"

            if ! verify_gpu_point "$GPU_FREQ" "$mv"; then
                stop_gpu_stress

                if (( point_try < GPU_POINT_TRIES )); then
                    log "The ${mv} mV point did not hold; restarting it (${point_try}/${GPU_POINT_TRIES})."
                    sleep 1
                    continue
                fi

                GPU_INVALID=1
                GPU_INVALID_REASON="live SMU readback never matched the requested point under stress"

                report_gpu_point_failure "$mv" "$last_pass" \
                    "the live SMU readback never matched the requested ${GPU_FREQ} MHz / ${mv} mV while the stressor was running."
                return 14
            fi

            interval_status=0
            run_test_interval GPU "$GPU_TEST_SECONDS" || interval_status=$?

            if ! kill -0 "$vkmark_pid" 2>/dev/null; then
                interval_status=2
            fi

            stop_gpu_stress

            if (( interval_status == 2 )); then
                if (( point_try < GPU_POINT_TRIES )); then
                    log "vkmark exited during the ${mv} mV point; restarting it (${point_try}/${GPU_POINT_TRIES})."
                    sleep 1
                    continue
                fi

                report_gpu_point_failure "$mv" "$last_pass" \
                    "vkmark exited unexpectedly during the ${mv} mV test point."
                return 12
            fi

            samples_total=$((GPU_POINT_GOOD_SAMPLES + GPU_POINT_BAD_SAMPLES))

            if (( GPU_POINT_BAD_SAMPLES > 0 )); then
                if (( point_try < GPU_POINT_TRIES )); then
                    log "The ${mv} mV point was not held for ${GPU_POINT_BAD_SAMPLES} of ${samples_total} samples; restarting it (${point_try}/${GPU_POINT_TRIES})."
                    sleep 1
                    continue
                fi

                GPU_INVALID=1
                GPU_INVALID_REASON="telemetry samples disagreed with the forced GPU point"

                report_gpu_point_failure "$mv" "$last_pass" \
                    "the forced point was not held: ${GPU_POINT_BAD_SAMPLES} of ${samples_total} samples disagreed with the requested ${GPU_FREQ} MHz / ${mv} mV."
                return 15
            fi

            point_ok=1
            break
        done

        if (( ! point_ok )); then
            GPU_INVALID=1
            GPU_INVALID_REASON="the ${mv} mV point could not be confirmed as applied"

            report_gpu_point_failure "$mv" "$last_pass" \
                "the ${mv} mV point could not be confirmed as applied and held."
            return 15
        fi

        last_pass="$mv"
        GPU_LAST_PASS="$last_pass"

        echo "  GPU ${GPU_FREQ} MHz / ${mv} mV: PASS (live ${GPU_POINT_LIVE_MV} mV, ${GPU_POINT_GOOD_SAMPLES} samples held the point)"
        write_state GPU "$mv" "$last_pass"

        mv=$((mv + GPU_STEP_MV))
    done

    echo
    echo "GPU sweep reached configured floor without a quick hard-lock."
    return 0
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
restore_services() {
    local unit

    for unit in "${STOPPED_CPU_UNITS[@]}"; do
        log "Restoring previously active CPU OC service: $unit"
        systemctl start "$unit" 2>/dev/null || true
    done

    if (( ORIG_CPU_SERVICE_ACTIVE != 1 )) && (( RUN_CPU )); then
        if ! restore_cpu_baseline 2>/dev/null; then
            log "WARNING: Failed to restore CPU baseline during cleanup."
        fi
    fi

    for unit in "${STOPPED_GPU_UNITS[@]}"; do
        log "Restoring previously active GPU SMU service: $unit"
        systemctl start "$unit" 2>/dev/null || true
    done

    if (( ORIG_GPU_SERVICE_ACTIVE != 1 )) && (( RUN_GPU )); then
        # No GPU governor was active before the test. Restore the test-only
        # thermal change to the stock runtime limit.
        if ! write_gpu_temp_baseline 90 2>/dev/null; then
            log "WARNING: Failed to restore GPU temperature baseline during cleanup."
        fi
    fi
}

cleanup() {
    [[ "$cleanup_done" -eq 1 ]] && return
    [[ "$test_initialized" -eq 1 ]] || return

    cleanup_done=1

    stop_cpu_stress
    stop_gpu_stress
    if (( RUN_GPU )); then
        if ! clear_gpu_point 2>/dev/null; then
            log "WARNING: Failed to clear direct GPU SMU force state during cleanup."
        fi
    fi


    restore_services
    (( test_passed )) && clear_state
}

pause_before_exit() {
    [[ "$pause_done" -eq 1 ]] && return
    pause_done=1
    echo
    read -r -n 1 -s -p "Press any key to close this terminal..."
    echo
}

on_exit() {
    cleanup
    pause_before_exit
}

trap on_exit EXIT
trap 'on_exit; exit 130' INT
trap 'on_exit; exit 143' TERM

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    if [[ $EUID -ne 0 ]]; then
        echo "This test needs root access."
        echo "Run: sudo ./${SCRIPT_NAME}"
        exit 1
    fi

    echo "=============================================="
    echo "       BC-250 SILICON QUALITY TEST"
    echo "=============================================="
    echo
    echo "This test finds the quick silicon-quality threshold"
    echo "where the system hard-freezes/locks."
    echo "An unexpected stress/backend program exit during a test point is classified as a failed test point."
    echo
    echo "Missing stress-ng/vkmark packages can be installed on request with pacman -Syu."
    echo "Package installation modifies the system and temporarily unlocks SteamOS root."
    echo "Nothing will be enabled at boot by this script."
    echo "CPU and GPU tuning are applied through their respective"
    echo "SMU backends with temporary runtime-only test state."
    echo

    show_previous_state
    if (( RESUME_GPU == 0 )); then
        choose_test_scope
    fi
    choose_test_configuration
    check_test_dependencies
    (( RUN_CPU )) && find_cpu_backend
    (( RUN_GPU )) && find_direct_gpu_backend
    find_services
    (( RUN_CPU )) && capture_cpu_baseline || true

    ask_test_values
    stop_conflicting_services

    test_initialized=1

    # -------------------------------------------------------------------------
    # CPU phase
    # -------------------------------------------------------------------------
    cpu_rc=0
    if (( RUN_CPU && ! RESUME_GPU )); then
        run_cpu_test
        cpu_rc=$?
        if [[ "$cpu_rc" -eq 0 ]]; then
            mark_phase_result CPU PASS
        else
            mark_phase_result CPU FAILED
        fi
    elif (( RESUME_GPU == 1 )); then
        cpu_rc=10
        CPU_LAST_PASS="$(awk -F= '$1 == "cpu_last_pass" {print $2}' "$STATE_FILE")"
        CPU_FAILURE_POINT="$(awk -F= '$1 == "cpu_point" {print $2}' "$STATE_FILE")"
        CPU_FAILURE_REASON="CPU phase stopped before the saved point completed."
        echo
        echo "CPU phase resumed as interrupted; skipping directly to GPU."
    else
        echo
        echo "CPU test skipped."
        mark_phase_result CPU SKIPPED
    fi

    if (( RUN_CPU )) && [[ "$cpu_rc" -eq 10 ]]; then
        echo
        echo "CPU silicon-quality failure detected."
        echo "The CPU baseline restore was attempted before continuing."
        echo "If restoration was not confirmed, the GPU result may be affected."
        echo "Continuing to GPU phase."
    elif (( RUN_CPU )) && [[ "$cpu_rc" -ne 0 ]]; then
        GPU_NOT_RUN=1
        echo
        echo "CPU phase failed before the GPU phase could start."
        echo "The final report will record the GPU phase as skipped."
    elif (( RUN_CPU && RUN_GPU )); then
        echo
        echo "CPU phase complete; restoring ${CPU_BASELINE_SOURCE} before GPU phase."

        # Do not restart the original CPU service yet: the GPU phase still
        # needs exclusive SMU access during its sweep.
        restore_cpu_baseline ||
            die "Failed to restore CPU baseline before GPU test."
    fi

    # -------------------------------------------------------------------------
    # GPU phase
    # -------------------------------------------------------------------------
    gpu_rc=0
    if (( RUN_GPU && !GPU_NOT_RUN )); then
        run_gpu_test
        gpu_rc=$?
        if [[ "$gpu_rc" -eq 0 ]]; then
            mark_phase_result GPU PASS
        else
            mark_phase_result GPU FAILED
        fi
    else
        echo
        echo "GPU test skipped."
        mark_phase_result GPU SKIPPED
    fi

    if [[ "$gpu_rc" -ne 0 ]]; then
        echo
        if (( GPU_INVALID )); then
            echo "GPU measurement invalid: this run does not support a silicon-quality conclusion."
        else
            echo "GPU silicon-quality failure detected."
        fi
    fi

    show_test_report

    if [[ "$cpu_rc" -eq 0 && "$gpu_rc" -eq 0 ]]; then
        test_passed=1
    fi

    # Return a failure status if either phase failed.
    if [[ "$cpu_rc" -ne 0 ]]; then
        exit "$cpu_rc"
    fi

    if [[ "$gpu_rc" -ne 0 ]]; then
        exit "$gpu_rc"
    fi
}

main "$@"
