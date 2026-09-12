#!/bin/bash
#
# BC-250 Silicon Quality Test
#
# Runtime-only silicon screening for an AMD BC-250.
# Instability is defined as a system hard-freeze/lock.
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
GPU_MIN_MV=600
GPU_TEST_SECONDS=30
GPU_TEST_TEMP=90

# Stable runtime baseline after a test when no user CPU OC service was active.
BASELINE_CPU_FREQ=3500
BASELINE_CPU_SCALE=0
BASELINE_TEMP=100
CPU_BASELINE_SOURCE="stable fallback"

BC250_CONTROL_DIR="${BC250_CONTROL_DIR:-/var/lib/bc250-control}"
BC250_OC_DIR="${BC250_OC_DIR:-$BC250_CONTROL_DIR/smu-oc}"

GPU_GOVERNOR_UNIT=""
CPU_SERVICE_UNIT=""

ORIG_CPU_SERVICE_ACTIVE=0
ORIG_GPU_SERVICE_ACTIVE=0

cleanup_done=0
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

        if validate_positive_int "$v" && (( v >= 600 && v <= 1100 )); then
            GPU_START_MV="$v"
            break
        fi

        echo "Invalid GPU start voltage. Enter a value from 600 to 1100 mV."
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

        if validate_positive_int "$v" && (( v >= 600 && v <= 1100 && GPU_START_MV >= v )); then
            delta=$((GPU_START_MV - v))
            step_abs=$((-GPU_STEP_MV))

            if (( delta % step_abs == 0 )); then
                GPU_MIN_MV="$v"
                break
            fi

            echo "GPU floor must be reached exactly by the selected step (${GPU_STEP_MV})."
            continue
        fi

        echo "Invalid GPU floor. It must be between 600 and 1100 mV and no higher than the start voltage."
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
        elif [[ "$gpu_rc" -eq 0 ]]; then
            echo "GPU result: PASS"
            echo "  Tested: ${GPU_FREQ} MHz, ${GPU_START_MV} to ${GPU_MIN_MV} mV by ${GPU_STEP_MV}"
            echo "  Point duration: ${GPU_TEST_SECONDS}s; temperature limit: ${GPU_TEST_TEMP}C"
            echo "  Last confirmed pass: ${GPU_LAST_PASS} mV"
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
        echo
        echo "The previous CPU phase was interrupted before it completed."
        echo "The CPU cutoff is already recorded; the GPU phase can continue."
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
            CPU_FAILURE_REASON="CPU phase was interrupted by a reboot before the saved point completed."
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
        CPU_FAILURE_REASON="${saved_cpu_failure_reason:-CPU phase was interrupted by a reboot before the saved point completed.}"
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
        GPU_FAILURE_REASON="${saved_gpu_failure_reason:-GPU phase was interrupted by a reboot before the saved point completed.}"
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

find_services() {
    if systemctl list-unit-files --type=service --no-legend 2>/dev/null |
        awk '{print $1}' |
        grep -qx 'cyan-skillfish-governor-smu.service'; then

        GPU_GOVERNOR_UNIT="cyan-skillfish-governor-smu.service"
    fi

    if systemctl list-unit-files --type=service --no-legend 2>/dev/null |
        awk '{print $1}' |
        grep -qx 'bc250-smu-oc.service'; then

        CPU_SERVICE_UNIT="bc250-smu-oc.service"
    fi
}

stop_conflicting_services() {
    if [[ -n "$GPU_GOVERNOR_UNIT" ]] &&
        systemctl is-active --quiet "$GPU_GOVERNOR_UNIT"; then

        ORIG_GPU_SERVICE_ACTIVE=1

        log "Stopping active GPU governor temporarily: $GPU_GOVERNOR_UNIT"
        systemctl stop "$GPU_GOVERNOR_UNIT" ||
            die "Could not stop GPU governor."
    fi

    if [[ -n "$CPU_SERVICE_UNIT" ]] &&
        systemctl is-active --quiet "$CPU_SERVICE_UNIT"; then

        ORIG_CPU_SERVICE_ACTIVE=1

        log "Stopping active CPU OC service temporarily: $CPU_SERVICE_UNIT"
        systemctl stop "$CPU_SERVICE_UNIT" ||
            die "Could not stop CPU OC service."
    fi
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

read_gpu_clock() {
    local clock

    # Queue-0 0x37 returns the live SMU-reported GFX clock, not GPU_FREQ.
    clock="$(
        PYTHONPATH="$BC250_OC_DIR${PYTHONPATH:+:$PYTHONPATH}" \
            python3 - <<'PY' 2>/dev/null
from bc250_smu import Bc250Smu

smu = Bc250Smu(allow_queue0=True, use_flock=True)
try:
    print(smu.get_gfx_frequency())
finally:
    smu.close()
PY
    )"

    [[ "$clock" =~ ^[0-9]+$ ]] && printf '%sMHz' "$clock" || printf 'unavailable'
}

read_gpu_voltage() {
    local voltage

    voltage="$(read_gpu_voltage_mv)"
    if [[ "$voltage" =~ ^[0-9]+$ ]]; then
        printf '%smV' "$voltage"
    else
        printf 'unavailable'
    fi
}

read_gpu_voltage_mv() {
    local voltage
    local attempt

    for ((attempt = 1; attempt <= SMU_RETRIES; attempt++)); do
        voltage="$(
            PYTHONPATH="$BC250_OC_DIR${PYTHONPATH:+:$PYTHONPATH}" \
                python3 - <<'PY' 2>/dev/null
from bc250_smu import Bc250Smu

smu = Bc250Smu(use_flock=True)
try:
    print(smu.q3_0x37_get_current_gpu_voltage())
finally:
    smu.close()
PY
        )"

        if [[ "$voltage" =~ ^[0-9]+$ ]]; then
            printf '%s' "$voltage"
            return 0
        fi
        (( attempt < SMU_RETRIES )) && sleep 0.2
    done

    printf 'unavailable'
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

verify_gpu_point() {
    local requested_clock="$1"
    local observed_clock
    local observed_mhz
    local attempt
    local clock_verified=0

    # The governor ramps from the previous point. Poll instead of treating the
    # first instantaneous frequency sample as the final applied setting.
    for ((attempt = 1; attempt <= 10; attempt++)); do
        observed_clock="$(read_gpu_clock)"
        if [[ "$observed_clock" != "unavailable" ]]; then
            observed_mhz="${observed_clock%MHz}"
            if [[ "$observed_mhz" =~ ^[0-9]+$ ]]; then
                if (( observed_mhz == requested_clock )); then
                    log "GPU live SMU clock readback verified at ${observed_clock}."
                    clock_verified=1
                    break
                fi
                log "Waiting for GPU clock to settle: live read ${observed_clock}, requested ${requested_clock}MHz."
            else
                log "Waiting for valid GPU clock readback: ${observed_clock}."
            fi
        else
            log "Waiting for GPU clock readback; current value is unavailable."
        fi
        (( attempt < 10 )) && sleep 0.5
    done

    if (( ! clock_verified )); then
        log "ERROR: GPU live SMU clock did not reach ${requested_clock}MHz within the settling window."
        return 1
    fi
}

report_telemetry() {
    local phase="$1"
    local elapsed="$2"
    local temperature
    local clock
    local voltage
    local warning

    if [[ "$phase" == "CPU" ]]; then
        temperature="$(read_cpu_temperature)"
        clock="$(read_cpu_clock)"
        voltage="$(read_cpu_voltage)"
        warning="$(throttle_warning "$temperature" "$clock" "$CPU_TEST_TEMP" "$CPU_FREQ")"
        printf '  [%s/%ss] CPU telemetry: temp %s, clock %s, current voltage %s%s\n' \
            "$elapsed" "$CPU_TEST_SECONDS" "$temperature" "$clock" "$voltage" "$warning"
    else
        temperature="$(read_gpu_temperature)"
        clock="$(read_gpu_clock)"
        voltage="$(read_gpu_voltage)"
        warning="$(throttle_warning "$temperature" "$clock" "$GPU_TEST_TEMP" "$GPU_FREQ")"
        printf '  [%s/%ss] GPU telemetry: temp %s, SMU clock %s, current voltage %s%s\n' \
            "$elapsed" "$GPU_TEST_SECONDS" "$temperature" "$clock" "$voltage" "$warning"
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

    PYTHONPATH="$BC250_OC_DIR${PYTHONPATH:+:$PYTHONPATH}" \
        python3 - "$temp" 2>/dev/null <<'PY'
import sys
import time
from bc250_smu import Bc250Smu

smu = Bc250Smu(use_flock=True)

try:
    smu.q3_0x8c_set_gpu_max_temperature(int(sys.argv[1]))
    time.sleep(1.0)
finally:
    smu.close()
PY
}

write_gpu_temp_baseline() {
    local temp="${1:-100}"
    write_gpu_temp_limit "$temp"
}

apply_gpu_point() {
    local mv="$1"
    local quiet="${2:-0}"
    local attempt
    local error_file="/tmp/bc250-silicon-gpu-apply-$$.err"

    (( quiet )) || log "Applying direct GPU SMU point at ${GPU_FREQ} MHz / ${mv} mV"
    for ((attempt = 1; attempt <= SMU_RETRIES; attempt++)); do
        if PYTHONPATH="$BC250_OC_DIR${PYTHONPATH:+:$PYTHONPATH}" \
                python3 - "$GPU_FREQ" "$mv" 2>"$error_file" <<'PY'
import sys
import time
from bc250_smu import Bc250Smu

frequency = int(sys.argv[1])
voltage = int(sys.argv[2])
smu = Bc250Smu(allow_queue0=True, use_flock=True)
try:
    smu.force_gfx_freq(frequency)
    smu.force_gfx_vid(voltage)
    # The queue-0 VID query is a live voltage reading, not a readback of the
    # forced VID command. Validate the programmed point through the live clock
    # and record live voltage later while the GPU is under stress.
    time.sleep(1.0)
    # The live clock is load-dependent. It is verified after vkmark starts,
    # when the GPU is actually exercising the forced point.
except Exception as error:
    print(f"GPU SMU apply failed: {error}", file=sys.stderr)
    raise SystemExit(1)
finally:
    smu.close()
PY
        then
            rm -f "$error_file"
            if (( attempt > 1 )); then
                log "GPU SMU apply succeeded on retry attempt ${attempt}."
            fi
            return 0
        fi
        if [[ -s "$error_file" ]]; then
            log "GPU SMU apply attempt ${attempt} failed: $(<"$error_file")"
        else
            log "GPU SMU apply attempt ${attempt} failed without an error message."
        fi
        (( attempt < SMU_RETRIES )) && sleep 0.5
    done

    rm -f "$error_file"
    log "Unable to apply GPU point after ${SMU_RETRIES} attempts."
    return 14
}

start_gpu_point() {
    local mv="$1"

    if ! retry_smu_operation "GPU temperature limit ${GPU_TEST_TEMP} C" \
        write_gpu_temp_limit "$GPU_TEST_TEMP"; then
        log "ERROR: Could not set GPU temperature limit to ${GPU_TEST_TEMP} C after ${SMU_RETRIES} attempts."
        return 13
    fi

    apply_gpu_point "$mv" ||
        return 14

}

clear_gpu_point() {
    PYTHONPATH="$BC250_OC_DIR${PYTHONPATH:+:$PYTHONPATH}" \
        python3 - 2>/dev/null <<'PY'
import time
from bc250_smu import Bc250Smu

smu = Bc250Smu(allow_queue0=True, use_flock=True)
try:
    smu.unforce_gfx_freq()
    smu.unforce_gfx_vid()
    time.sleep(1.0)
finally:
    smu.close()
PY
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

run_gpu_test() {
    local mv="$GPU_START_MV"
    local last_pass=""
    local interval_status=0
    local point_status=0
    GPU_LAST_PASS="none"
    GPU_FAILURE_POINT="none"
    GPU_FAILURE_REASON=""

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

        point_status=0
        start_gpu_point "$mv" || point_status=$?
        if (( point_status != 0 )); then

            echo
            echo "GPU: FAILURE"
            echo "GPU failure candidate = ${mv} mV"
            echo "GPU last confirmed pass = ${last_pass:-none} mV"
            GPU_LAST_PASS="${last_pass:-none}"
            GPU_FAILURE_POINT="$mv"
            if (( point_status == 13 )); then
                echo "Reason: the GPU temperature limit could not be applied."
                echo "The point is classified as a failed GPU temperature setup."
                GPU_FAILURE_REASON="GPU temperature limit could not be applied before this test point."
            else
                echo "Reason: the GPU SMU clock could not be independently verified before this test point."
                echo "The point is classified as a failed GPU setup verification."
                GPU_FAILURE_REASON="GPU SMU clock could not be independently verified before this test point."
            fi

            return 13
        fi

        start_gpu_stress

        log "GPU point active: ${GPU_FREQ} MHz / ${mv} mV / GPU ${GPU_TEST_TEMP}C"

        if ! verify_gpu_point "$GPU_FREQ"; then
            stop_gpu_stress
            echo
            echo "GPU: FAILURE"
            echo "GPU failure candidate = ${mv} mV"
            echo "GPU last confirmed pass = ${last_pass:-none} mV"
            echo "Reason: the live GPU clock did not reach the requested frequency under stress."
            echo "The point is classified as a failed GPU clock verification."
            GPU_LAST_PASS="${last_pass:-none}"
            GPU_FAILURE_POINT="$mv"
            GPU_FAILURE_REASON="Live GPU clock did not reach ${GPU_FREQ} MHz under stress."
            return 14
        fi

        interval_status=0
        run_test_interval GPU "$GPU_TEST_SECONDS" || interval_status=$?

        if (( interval_status == 2 )); then
            stop_gpu_stress

            echo
            echo "GPU: FAILURE"
            echo "GPU failure candidate = ${mv} mV"
            echo "GPU last confirmed pass = ${last_pass:-none} mV"
            echo "Reason: vkmark exited unexpectedly during the ${mv} mV test point."
            echo "The point is classified as a failed GPU silicon-quality test point."
            GPU_LAST_PASS="${last_pass:-none}"
            GPU_FAILURE_POINT="$mv"
            GPU_FAILURE_REASON="vkmark exited unexpectedly during the ${mv} mV test point."
            return 12
        fi

        if ! kill -0 "$vkmark_pid" 2>/dev/null; then
            stop_gpu_stress

            echo
            echo "GPU: FAILURE"
            echo "GPU failure candidate = ${mv} mV"
            echo "GPU last confirmed pass = ${last_pass:-none} mV"
            echo "Reason: vkmark exited unexpectedly during the ${mv} mV test point."
            echo "The point is classified as a failed silicon-quality test point."
            GPU_LAST_PASS="${last_pass:-none}"
            GPU_FAILURE_POINT="$mv"
            GPU_FAILURE_REASON="vkmark exited unexpectedly during the ${mv} mV test point."

            return 12
        fi

        last_pass="$mv"
        GPU_LAST_PASS="$last_pass"

        echo "  GPU ${GPU_FREQ} MHz / ${mv} mV: PASS"
        write_state GPU "$mv" "$last_pass"

        stop_gpu_stress

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
    if [[ "$ORIG_CPU_SERVICE_ACTIVE" -eq 1 ]] &&
        [[ -n "$CPU_SERVICE_UNIT" ]]; then

        log "Restoring previously active CPU OC service."
        systemctl start "$CPU_SERVICE_UNIT" 2>/dev/null || true
    elif (( RUN_CPU )); then
        if ! restore_cpu_baseline 2>/dev/null; then
            log "WARNING: Failed to restore CPU baseline during cleanup."
        fi
    fi

    if [[ "$ORIG_GPU_SERVICE_ACTIVE" -eq 1 ]] &&
        [[ -n "$GPU_GOVERNOR_UNIT" ]]; then

        log "Restoring previously active GPU governor."
        systemctl start "$GPU_GOVERNOR_UNIT" 2>/dev/null || true
    elif (( RUN_GPU )); then
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

on_exit() {
    cleanup
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
        CPU_FAILURE_REASON="CPU phase was interrupted by a reboot before the saved point completed."
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
        echo "GPU silicon-quality failure detected."
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
