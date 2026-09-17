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
- Starting scale: `-20`
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
- Starting voltage: `900 mV`
- Step: `-10 mV`
- Floor: `650 mV`
- Duration: `30 seconds` per point
- Temperature limit: `90 C`

The GPU sweep applies a fixed clock and steps the forced GPU voltage downward.
Every point is verified against the live SMU readback three times over:

1. Immediately after applying it (frequency and voltage, polled until the SMU
   settles instead of sampled once).
2. Again after `vkmark` starts, so a point that does not survive the load is
   never accepted.
3. On every five-second telemetry sample for the whole interval.

A point counts as a pass only when all of those samples report the requested
clock and a voltage within `5 mV` of the requested value. The pass line prints
the live voltage that was actually measured.

If the readback disagrees with the requested point, the point is restarted once
from scratch. If it disagrees again the sweep stops and reports
`GPU result: INVALID MEASUREMENT` - not a pass and not a silicon failure -
because a point that was not held says nothing about silicon quality either way.

## SMU exclusivity

The GPU governor and this test drive the same SMU mailbox over the BC-250 PCI
config file, and the governor re-applies its own point (its top safe point is
`1500 MHz / 900 mV`) as soon as the GPU gets busy - which is exactly when a test
point starts. With the governor running, a sweep that forces `870 mV` can end up
running at `900 mV` and still report a pass.

Before the GPU sweep the script therefore:

- detects the governor units (`cyan-skillfish-governor-smu.service`, and the
  plain/tt/oberon variants) plus `bc250-smu-oc.service`, using a
  pipefail-safe lookup,
- stops each active one and waits until systemd reports it inactive,
- confirms that no process still holds
  `/sys/bus/pci/devices/0000:00:00.0/config`,
- re-checks before every point, and aborts with an invalid measurement if an
  SMU client reappears.

All stopped services are restarted during cleanup. If you need the governor to
stay up, hand the SMU over with its own D-Bus test mode instead of forcing the
point behind its back - TestMode disables automatic adjustment while keeping
thermal throttling active:

```bash
sudo busctl --system call com.cyanskillfish.Governor /com/cyanskillfish/Governor \
    com.cyanskillfish.Governor.TestMode SetTestMode uu 1500 870
```

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

A GPU point whose live SMU readback does not match the requested clock and
voltage - before the interval, after `vkmark` starts, or during it - is
reported as `INVALID MEASUREMENT`. That means another SMU client or the
firmware overrode the test point; the run says nothing about silicon quality
and should be repeated with exclusive SMU access before drawing conclusions.

## Interrupted runs and recovery

The script saves checkpoint state in:

```text
~/.bc250-silicon-test.state
```

It also appends operational logs to:

```text
~/.bc250-silicon-test.log
```

State is written before risky SMU operations. If a test crashes, stops
unexpectedly, or the machine hard-locks and you reboot before rerunning the
script:

- An interrupted CPU phase can be marked interrupted and continued directly
  with the GPU phase.
- An interrupted GPU point is recorded as the GPU cutoff and is not retried.
- Recovery prints the same final test report as a normal completion, including
  the cutoff and last confirmed passing voltage before exiting.
- Declining recovery returns to test selection without discarding saved state.

Use the saved state display to confirm the phase, point, and last confirmed pass
before choosing a recovery action.

The script waits for the user to press a key before exiting, including after a
successful test, a failed test, cancellation, or an error. This keeps the
terminal open long enough to review the result.

## Runtime safety and cleanup

The script:

- Does not modify the SteamOS root filesystem.
- Does not install packages without explicit confirmation.
- If package installation is accepted, temporarily unlocks SteamOS root,
  initializes the pacman keyring, synchronizes packages, and relocks root.
- Does not enable services at boot.
- Does not write persistent CPU/GPU tuning configuration.
- Temporarily stops conflicting CPU/GPU tuning services, verifies each one is
  really stopped, and restarts it during cleanup.
- Restores the CPU baseline and GPU force state during cleanup.
- Handles `SIGINT` and `SIGTERM` cleanup paths.

Do not run other CPU/GPU tuning tools simultaneously with the test: anything
else driving the SMU mailbox invalidates the point being measured. A hard
lock can require a physical reboot, and no software can checkpoint work that
was not written before the lock.

## Configuration and backend overrides

The SMU backend location can be overridden for testing:

```bash
sudo BC250_CONTROL_DIR=/path/to/bc250-control ./test_silicon.sh
```

The script uses `${BC250_CONTROL_DIR}/smu-oc` unless `BC250_OC_DIR` is set
explicitly.
