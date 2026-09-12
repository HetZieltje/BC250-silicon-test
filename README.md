# BC-250 Silicon Quality Test

`test_silicon.sh` is an interactive, runtime-only silicon screening tool for
AMD BC-250 systems. It sweeps CPU voltage-curve scales and/or GPU voltages
while applying fixed CPU/GPU clocks and running a workload.

This is a quick stability screen, not a certification of long-term stability.
A hard freeze, unexpected stressor exit, or invalid SMU setup is treated as a
failure or interruption according to the point at which it occurs.

## Requirements

- AMD BC-250 hardware
- Root access
- The direct BC-250 SMU Python backend at:
  `/var/lib/bc250-control/smu-oc`
- `stress-ng` for CPU testing
- `vkmark` for GPU testing
- A working graphical or automatic Vulkan backend for `vkmark`

If `stress-ng` or `vkmark` is missing, the script offers to install the
missing packages. Installation is explicit and opt-in.

On SteamOS, installation temporarily disables the read-only root filesystem,
initializes/populates the pacman keyring, and runs:

```bash
pacman -Syu --noconfirm --needed stress-ng vkmark
```

The root filesystem is relocked afterward when `steamos-readonly` is
available. Package installation changes the system package database and may
perform a synchronized system upgrade; review the prompt before accepting it.

## Running

From this directory:

```bash
sudo ./test_silicon.sh
```

The script:

1. Displays any saved test state before test selection.
2. Lets you choose CPU, GPU, or both.
3. Lets you use defaults or configure each sweep.
4. Shows a final confirmation before changing SMU runtime settings.
5. Runs the selected sweep and prints a final result.

## Default settings

### CPU

- Clock: `3500 MHz`
- Starting scale: `-30`
- Step: `-1`
- Floor: `-50`
- Duration: `30 seconds` per point
- Temperature limit: `95 C`

The CPU clock is fixed for the sweep while the VID-curve scale is reduced one
point at a time. The measured current CPU voltage is recorded for each scale.

CPU clock input accepts values from `100` to `4500 MHz`. The script does not
reject a point based on an immediate clock readback because clock readback can
be transition- or load-dependent. Actual clock and voltage are shown during
the loaded telemetry interval.

### GPU

- Clock: `1500 MHz`
- Starting voltage: `850 mV`
- Step: `-10 mV`
- Floor: `600 mV`
- Duration: `30 seconds` per point
- Temperature limit: `90 C`

The GPU sweep applies a fixed clock and steps the forced GPU voltage downward.
The GPU clock is verified after `vkmark` starts, while the GPU is under load.
GPU voltage shown in telemetry is a live measured voltage; it is not a
readback of the requested/programmed voltage.

## Telemetry

Every five seconds the script reports:

- Temperature
- Live CPU or GPU clock
- Measured current voltage

A possible-throttling warning is shown when both conditions are met:

- Temperature is within `1 C` of the configured maximum, including above it.
- Live clock is at least `50 MHz` below the requested clock.

GPU clock values come from a live queue-0 SMU query. The firmware reports
integer, quantized clock states, so the value is not sub-MHz precision.

## Test interpretation

The last confirmed pass is the lowest point that completed its full interval.
The next point is the failure candidate when the stressor exits, the system
locks, or the required live clock cannot be verified.

A failed point does not prove that every lower point is unstable. It identifies
the boundary found by this sweep and workload.

CPU `stress-ng` exiting unexpectedly is treated as the CPU silicon cutoff and
allows a combined run to continue to the GPU phase. A GPU `vkmark` exit is
treated as a failed GPU point.

## Interrupted runs and reboot recovery

The script saves checkpoint state in:

```text
~/.bc250-silicon-test.state
```

It also appends operational logs to:

```text
~/.bc250-silicon-test.log
```

State is written before risky SMU operations. If the machine hard-locks and
you reboot and rerun the script:

- An interrupted CPU phase can be marked interrupted and continued directly
  with the GPU phase.
- An interrupted GPU point is recorded as the GPU cutoff and is not retried.
- Recovery prints the same final test report as a normal completion, including
  the cutoff and last confirmed passing voltage before exiting.
- Declining recovery returns to test selection without discarding saved state.

Use the saved state display to confirm the phase, point, and last confirmed pass
before choosing a recovery action.

## Runtime safety and cleanup

The script:

- Does not modify the SteamOS root filesystem.
- Does not install packages without explicit confirmation.
- If package installation is accepted, temporarily unlocks SteamOS root,
  initializes the pacman keyring, synchronizes packages, and relocks root.
- Does not enable services at boot.
- Does not write persistent CPU/GPU tuning configuration.
- Temporarily stops conflicting CPU/GPU tuning services when necessary.
- Restores the CPU baseline and GPU force state during cleanup.
- Handles `SIGINT` and `SIGTERM` cleanup paths.

Do not run other CPU/GPU tuning tools simultaneously with the test. A hard
lock can require a physical reboot, and no software can checkpoint work that
was not written before the lock.

## Configuration and backend overrides

The SMU backend location can be overridden for testing:

```bash
sudo BC250_CONTROL_DIR=/path/to/bc250-control ./test_silicon.sh
```

The script uses `${BC250_CONTROL_DIR}/smu-oc` unless `BC250_OC_DIR` is set
explicitly.
