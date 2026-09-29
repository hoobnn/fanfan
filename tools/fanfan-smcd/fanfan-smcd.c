/*
 * fanfan privileged SMC daemon.
 *
 * Registered by the app through SMAppService and reached over the XPC Mach
 * service com.hoobnn.fanfan.helper. Only clients signed by team 8FUPL8QHFH as
 * the fanfan app may connect. Each message carries one text command under
 * "line" and gets one text reply under "reply":
 *   SETV2 <fan> <rpm>
 *   AUTOV2 <fan>
 *   PINGV2               (returns protocol version + lease state)
 *   RENEWV2              (renews an active lease; never a pending restore)
 *
 * Apple Silicon (M3/M4) fan control note:
 *   thermalmonitord holds fans in F<n>Md = 3 ("system mode") and the RTKit
 *   firmware rejects direct mode writes with SMC result 0x82 (kSMCBadCommand)
 *   while in that state. To take manual control we use the diagnostic "force
 *   test" flag: write Ftst=1 (accepted even in mode 3), which makes
 *   thermalmonitord yield, then retry F<n>Md=1 until it sticks (a few seconds),
 *   then write the target RPM. Releasing the last manual fan writes Ftst=0 so
 *   the firmware reclaims control (and can idle fans to 0 RPM). M1/M5 accept a
 *   direct mode write and have no/absent Ftst, so we try direct first.
 *   A successful SET starts a 10-second lease. The app renews it with RENEWV2;
 *   expiry, the controlling connection going away (app quit or crash), daemon
 *   shutdown, or a failed SET restores firmware control.
 *   Reference: github.com/agoodkind/macos-smc-fan
 */

#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <xpc/xpc.h>
#include <IOKit/IOKitLib.h>
#include "smc.h"

#define SERVICE_NAME "com.hoobnn.fanfan.helper"
/* Only the fanfan app (release or debug build) signed by our team may talk to
 * the daemon. */
#define CLIENT_REQUIREMENT \
    "anchor apple generic and certificate leaf[subject.OU] = \"8FUPL8QHFH\" and " \
    "(identifier \"com.hoobnn.fanfan\" or identifier \"com.hoobnn.fanfan.debug\")"
/* Pre-1.4 installs: a hand-installed system LaunchDaemon on a Unix socket. */
#define LEGACY_LABEL "com.hoobnn.fanfan.smcd"
#define LEGACY_PLIST "/Library/LaunchDaemons/com.hoobnn.fanfan.smcd.plist"
#define MAX_COMMAND_LENGTH 127
#define MAX_FANS 8
#define MIN_RPM 500
#define MAX_RPM 8000
#define SAFE_FALLBACK_MIN_RPM 1000
#define SAFE_FALLBACK_MAX_RPM 5200
#define PROTOCOL_VERSION 2
#define CONTROL_LEASE_TIMEOUT_MS 10000

/* SMC firmware result codes (returned in SMCKeyData_t.result). */
#define SMC_RESULT_OK          0x00
#define SMC_RESULT_BAD_COMMAND 0x82  /* mode write rejected while system-locked */
#define SMC_RESULT_NOT_FOUND   0x84  /* key does not exist on this hardware */

/* Ftst unlock timing. Observed ~7.8 s on M4 Pro; leave generous headroom. */
#define UNLOCK_TIMEOUT_MS 12000
#define UNLOCK_STEP_MS    100

static io_connect_t g_conn = 0;
static volatile sig_atomic_t g_should_exit = 0;
static dispatch_queue_t g_queue;
/* The connection whose SET established the current lease. Compared by pointer
 * only; cleared when that connection goes away. */
static xpc_connection_t g_control_owner = NULL;

/* Capabilities probed once at startup. */
static char g_mode_fmt[8] = "F%dMd"; /* "F%dMd" (M4) or "F%dmd" (M5) */
static int  g_ftst_avail = 0;        /* whether the Ftst key exists here */
static int  g_ftst_engaged = 0;      /* whether this daemon asserted Ftst=1 */
static int  g_manual[MAX_FANS];      /* per-fan: 1 once manual control is held */
static int  g_min_rpm[MAX_FANS];
static int  g_max_rpm[MAX_FANS];
static int  g_limits_known[MAX_FANS];
static int  g_restore_pending[MAX_FANS];
typedef enum {
    LEASE_NONE = 0,
    LEASE_ACTIVE,
    LEASE_RESTORE_PENDING
} control_lease_state_t;
static control_lease_state_t g_lease_state = LEASE_NONE;
static uint64_t g_last_control_activity_ms = 0;
static uint64_t g_next_restore_attempt_ms = 0;
static uint64_t g_restore_retry_delay_ms = 1000;

static kern_return_t set_fan_auto(int fan);
static uint64_t monotonic_milliseconds(void);
static void restore_owned_control(void);
static int has_outstanding_manual_control(void);

static UInt32 smc_strtoul(char *str, int size, int base)
{
    UInt32 total = 0;
    (void)base;
    for (int i = 0; i < size; i++) {
        total |= ((UInt32)(unsigned char)str[i]) << ((size - 1 - i) * 8);
    }
    return total;
}

static void smc_ultostr(char *str, UInt32 val)
{
    str[0] = '\0';
    snprintf(str, 5, "%c%c%c%c",
            (unsigned int)val >> 24,
            (unsigned int)val >> 16,
            (unsigned int)val >> 8,
            (unsigned int)val);
}

static kern_return_t smc_call(uint32_t index, SMCKeyData_t *input, SMCKeyData_t *output)
{
    size_t input_size = sizeof(SMCKeyData_t);
    size_t output_size = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(g_conn, index, input, input_size, output, &output_size);
}

static kern_return_t smc_open(void)
{
    if (g_conn != 0) {
        return kIOReturnSuccess;
    }

    io_iterator_t iterator = 0;
    io_object_t device = 0;
    kern_return_t result = IOServiceGetMatchingServices(kIOMainPortDefault,
                                                        IOServiceMatching("AppleSMC"),
                                                        &iterator);
    if (result != kIOReturnSuccess) {
        return result;
    }

    device = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (device == 0) {
        return kIOReturnNotFound;
    }

    result = IOServiceOpen(device, mach_task_self(), 0, &g_conn);
    IOObjectRelease(device);
    return result;
}

static void smc_close(void)
{
    if (g_conn != 0) {
        IOServiceClose(g_conn);
        g_conn = 0;
    }
}

static kern_return_t smc_get_key_info(UInt32 key, SMCKeyData_keyInfo_t *key_info)
{
    SMCKeyData_t input;
    SMCKeyData_t output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));

    input.key = key;
    input.data8 = SMC_CMD_READ_KEYINFO;

    kern_return_t result = smc_call(KERNEL_INDEX_SMC, &input, &output);
    if (result != kIOReturnSuccess) {
        return result;
    }
    /* The firmware reports a missing/invalid key in the result byte, not the
     * kern_return_t — surface it so capability probing can detect absent keys. */
    if (output.result != SMC_RESULT_OK) {
        return kIOReturnError;
    }
    *key_info = output.keyInfo;
    return kIOReturnSuccess;
}

static kern_return_t smc_read_key(UInt32Char_t key, SMCVal_t *val)
{
    SMCKeyData_t input;
    SMCKeyData_t output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    memset(val, 0, sizeof(*val));

    input.key = smc_strtoul(key, 4, 16);
    snprintf(val->key, sizeof(val->key), "%s", key);

    kern_return_t result = smc_get_key_info(input.key, &output.keyInfo);
    if (result != kIOReturnSuccess) {
        return result;
    }

    val->dataSize = output.keyInfo.dataSize;
    smc_ultostr(val->dataType, output.keyInfo.dataType);
    input.keyInfo.dataSize = val->dataSize;
    input.data8 = SMC_CMD_READ_BYTES;

    result = smc_call(KERNEL_INDEX_SMC, &input, &output);
    if (result != kIOReturnSuccess) {
        return result;
    }
    if (output.result != SMC_RESULT_OK) {
        return kIOReturnError;
    }

    memcpy(val->bytes, output.bytes, sizeof(output.bytes));
    return kIOReturnSuccess;
}

/*
 * Write a value to its key. Returns kIOReturnSuccess only when both the IOKit
 * transport AND the SMC firmware accept it. The firmware encodes rejection in
 * the result byte (e.g. 0x82 while system-locked); the IOKit call still returns
 * kIOReturnSuccess, so the original code mistook rejections for success. The
 * raw SMC result is reported via *smc_result for callers that need to branch.
 */
static kern_return_t smc_write_key(SMCVal_t write_val, uint8_t *smc_result)
{
    if (smc_result) {
        *smc_result = 0xff;
    }

    SMCVal_t read_val;
    kern_return_t result = smc_read_key(write_val.key, &read_val);
    if (result != kIOReturnSuccess) {
        return result;
    }
    if (read_val.dataSize != write_val.dataSize) {
        return kIOReturnError;
    }

    SMCKeyData_t input;
    SMCKeyData_t output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));

    input.key = smc_strtoul(write_val.key, 4, 16);
    input.data8 = SMC_CMD_WRITE_BYTES;
    input.keyInfo.dataSize = write_val.dataSize;
    memcpy(input.bytes, write_val.bytes, sizeof(write_val.bytes));

    result = smc_call(KERNEL_INDEX_SMC, &input, &output);
    if (smc_result) {
        *smc_result = (uint8_t)output.result;
    }
    if (result != kIOReturnSuccess) {
        return result;
    }
    if (output.result != SMC_RESULT_OK) {
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

/* Read a one-byte key into *out. Returns 0 on success. */
static int smc_read_u8(const char *key, UInt8 *out)
{
    SMCVal_t val;
    char k[5];
    snprintf(k, sizeof(k), "%s", key);
    if (smc_read_key(k, &val) != kIOReturnSuccess) {
        return -1;
    }
    if (val.dataSize != 1) {
        return -1;
    }
    *out = val.bytes[0];
    return 0;
}

static int smc_value_to_rpm(const SMCVal_t *val, int *rpm)
{
    if (strcmp(val->dataType, DATATYPE_FLT) == 0 && val->dataSize == 4) {
        float speed = 0;
        memcpy(&speed, val->bytes, sizeof(speed));
        if (!isfinite(speed) || speed < 0 || speed > 100000) {
            return 0;
        }
        *rpm = (int)speed;
        return 1;
    }
    if (strcmp(val->dataType, DATATYPE_FPE2) == 0 && val->dataSize == 2) {
        UInt16 encoded = (UInt16)(((UInt16)val->bytes[0] << 8) | val->bytes[1]);
        *rpm = (int)(encoded >> 2);
        return 1;
    }
    return 0;
}

static int probe_fan_limit(int fan)
{
    g_min_rpm[fan] = SAFE_FALLBACK_MIN_RPM;
    g_max_rpm[fan] = SAFE_FALLBACK_MAX_RPM;

    char key[5];
    SMCVal_t value;
    int rpm = 0;
    int min_known = 0;
    int max_known = 0;

    snprintf(key, sizeof(key), "F%dMn", fan);
    if (smc_read_key(key, &value) == kIOReturnSuccess &&
        smc_value_to_rpm(&value, &rpm) && rpm >= 0 && rpm <= MAX_RPM) {
        g_min_rpm[fan] = rpm > MIN_RPM ? rpm : MIN_RPM;
        min_known = 1;
    }

    snprintf(key, sizeof(key), "F%dMx", fan);
    if (smc_read_key(key, &value) == kIOReturnSuccess &&
        smc_value_to_rpm(&value, &rpm) && rpm >= g_min_rpm[fan] && rpm <= MAX_RPM) {
        g_max_rpm[fan] = rpm;
        max_known = 1;
    }
    g_limits_known[fan] = min_known && max_known;
    return g_limits_known[fan];
}

static void probe_fan_limits(void)
{
    for (int fan = 0; fan < MAX_FANS; fan++) {
        (void)probe_fan_limit(fan);
    }
}

/* Write a one-byte value to a key; surfaces the SMC result via *smc_result. */
static kern_return_t smc_write_u8(const char *key, UInt8 byte, uint8_t *smc_result)
{
    SMCVal_t val;
    char k[5];
    snprintf(k, sizeof(k), "%s", key);

    kern_return_t result = smc_read_key(k, &val);
    if (result != kIOReturnSuccess) {
        return result;
    }
    if (val.dataSize != 1) {
        return kIOReturnError;
    }
    val.bytes[0] = byte;
    snprintf(val.key, sizeof(val.key), "%s", key);
    return smc_write_key(val, smc_result);
}

static void fan_mode_key(int fan, char *out, size_t out_size)
{
    if (strcmp(g_mode_fmt, "F%dmd") == 0) {
        snprintf(out, out_size, "F%dmd", fan);
    } else {
        snprintf(out, out_size, "F%dMd", fan);
    }
}

/* Probe hardware-specific keys once: mode-key casing and Ftst availability. */
static void probe_capabilities(void)
{
    SMCVal_t v;
    if (smc_read_key("F0Md", &v) == kIOReturnSuccess) {
        snprintf(g_mode_fmt, sizeof(g_mode_fmt), "F%%dMd");
    } else if (smc_read_key("F0md", &v) == kIOReturnSuccess) {
        snprintf(g_mode_fmt, sizeof(g_mode_fmt), "F%%dmd");
    } else {
        snprintf(g_mode_fmt, sizeof(g_mode_fmt), "F%%dMd");
    }

    g_ftst_avail = (smc_read_key("Ftst", &v) == kIOReturnSuccess) ? 1 : 0;
    probe_fan_limits();
}

static void reconcile_startup_control(void)
{
    int found_stale_control = 0;
    for (int fan = 0; fan < MAX_FANS; fan++) {
        char mode_key[8];
        UInt8 mode = 0;
        fan_mode_key(fan, mode_key, sizeof(mode_key));
        if (smc_read_u8(mode_key, &mode) == 0 && mode == 1) {
            g_manual[fan] = 1;
            found_stale_control = 1;
        }
    }

    UInt8 ftst = 0;
    if (g_ftst_avail && smc_read_u8("Ftst", &ftst) == 0 && ftst != 0) {
        g_ftst_engaged = 1;
        found_stale_control = 1;
    }

    if (found_stale_control) {
        fprintf(stderr, "fanfan-smcd: stale manual state found at startup; restoring firmware control\n");
        restore_owned_control();
    }
}

/*
 * Ensure fan <fan> is in manual mode (F<n>Md = 1), applying the Ftst unlock if a
 * direct mode write is rejected. Idempotent and self-healing: it re-asserts
 * Ftst=1 every time it has to unlock, so manual control is re-established after
 * the firmware resets Ftst across sleep/wake.
 */
static kern_return_t ensure_manual(int fan)
{
    char mkey[8];
    fan_mode_key(fan, mkey, sizeof(mkey));

    UInt8 cur = 0;
    uint8_t res = 0;

    if (smc_read_u8(mkey, &cur) != 0) {
        char alternate[8];
        if (strcmp(g_mode_fmt, "F%dmd") == 0) {
            snprintf(alternate, sizeof(alternate), "F%dMd", fan);
        } else {
            snprintf(alternate, sizeof(alternate), "F%dmd", fan);
        }
        if (smc_read_u8(alternate, &cur) == 0) {
            snprintf(g_mode_fmt, sizeof(g_mode_fmt), "%s",
                     strstr(alternate, "md") != NULL ? "F%dmd" : "F%dMd");
            snprintf(mkey, sizeof(mkey), "%s", alternate);
        }
    }

    /* Fast path: already manual (the common case after the first unlock). */
    if (smc_read_u8(mkey, &cur) == 0 && cur == 1) {
        g_manual[fan] = 1;
        g_restore_pending[fan] = 0;
        return kIOReturnSuccess;
    }

    /* Try a direct mode write — succeeds on M1/M5 with no unlock needed. */
    kern_return_t direct_write = smc_write_u8(mkey, 1, &res);
    if (direct_write == kIOReturnSuccess) {
        if (smc_read_u8(mkey, &cur) == 0 && cur == 1) {
            g_manual[fan] = 1;
            g_restore_pending[fan] = 0;
            return kIOReturnSuccess;
        }
        /* The write may have succeeded even though verification failed. Never
         * continue as if firmware still owned the fan. */
        g_restore_pending[fan] = 1;
        (void)set_fan_auto(fan);
        return kIOReturnError;
    }

    /* Locked (mode 3). Without Ftst there is no unlock path on this hardware. */
    if (!g_ftst_avail) {
        SMCVal_t value;
        g_ftst_avail = (smc_read_key("Ftst", &value) == kIOReturnSuccess) ? 1 : 0;
        if (!g_ftst_avail) {
            return kIOReturnNotPrivileged;
        }
    }

    /* Engage diagnostic mode and wait for thermalmonitord to yield. */
    uint64_t started_at = monotonic_milliseconds();
    /* Mark the flag engaged *before* the write: a failure return can still mean
     * the command reached the hardware (transport OK, firmware rejected), and a
     * silently-set Ftst that nobody clears leaves the machine in diagnostic mode
     * until reboot. Claiming it early only costs one redundant Ftst=0 on
     * restore, which is harmless. */
    if (g_ftst_avail) {
        g_ftst_engaged = 1;
    }
    if (smc_write_u8("Ftst", 1, &res) != kIOReturnSuccess) {
        return kIOReturnError;
    }
    usleep(500 * 1000);

    int waited = 0;
    while (waited < UNLOCK_TIMEOUT_MS) {
        if (g_should_exit) {
            g_restore_pending[fan] = 1;
            return kIOReturnAborted;
        }
        uint64_t now = monotonic_milliseconds();
        if (started_at != 0 && now != 0 && now - started_at >= UNLOCK_TIMEOUT_MS) {
            break;
        }
        res = 0;
        kern_return_t wr = smc_write_u8(mkey, 1, &res);
        if (wr == kIOReturnSuccess) {
            g_restore_pending[fan] = 1;
        }
        if (wr == kIOReturnSuccess && smc_read_u8(mkey, &cur) == 0 && cur == 1) {
            g_manual[fan] = 1;
            g_restore_pending[fan] = 0;
            return kIOReturnSuccess;
        }
        usleep(UNLOCK_STEP_MS * 1000);
        waited += UNLOCK_STEP_MS;
    }
    // We may have partially acquired manual mode while a verification read was
    // failing. Best-effort rollback keeps a failed SET from leaving stale control.
    g_manual[fan] = 1;
    g_restore_pending[fan] = 1;
    (void)set_fan_auto(fan);
    return kIOReturnTimeout;
}

static kern_return_t set_fan_speed(int fan, int rpm)
{
    if (!g_limits_known[fan]) {
        (void)probe_fan_limit(fan);
    }
    if (rpm < g_min_rpm[fan] || rpm > g_max_rpm[fan]) {
        return kIOReturnBadArgument;
    }

    kern_return_t result = ensure_manual(fan);
    if (result != kIOReturnSuccess) {
        return result;
    }

    SMCVal_t val;
    char key[5];
    snprintf(key, sizeof(key), "F%dTg", fan);

    result = smc_read_key(key, &val);
    if (result != kIOReturnSuccess) {
        (void)set_fan_auto(fan);
        return result;
    }

    if (strcmp(val.dataType, DATATYPE_FLT) == 0 && val.dataSize == 4) {
        float speed = (float)rpm;
        memcpy(val.bytes, &speed, sizeof(speed));
    } else if (strcmp(val.dataType, DATATYPE_FPE2) == 0 && val.dataSize == 2) {
        UInt16 encoded = (UInt16)(rpm << 2);
        val.bytes[0] = (encoded >> 8) & 0xFF;
        val.bytes[1] = encoded & 0xFF;
    } else {
        (void)set_fan_auto(fan);
        return kIOReturnUnsupported;
    }

    snprintf(val.key, sizeof(val.key), "%s", key);
    uint8_t res = 0;
    result = smc_write_key(val, &res);
    if (result != kIOReturnSuccess) {
        (void)set_fan_auto(fan);
    } else {
        g_restore_pending[fan] = 0;
    }
    return result;
}

static void schedule_restore_retry(int fan)
{
    if (fan >= 0 && fan < MAX_FANS) {
        g_restore_pending[fan] = 1;
    }
    g_lease_state = LEASE_RESTORE_PENDING;
    g_last_control_activity_ms = 0;
    g_next_restore_attempt_ms = 0;
}

static kern_return_t set_fan_auto(int fan)
{
    char mkey[8];
    fan_mode_key(fan, mkey, sizeof(mkey));

    /* Only act if the fan is actually in manual mode; AUTO is otherwise a no-op. */
    UInt8 cur = 0;
    uint8_t res = 0;
    if (smc_read_u8(mkey, &cur) != 0) {
        schedule_restore_retry(fan);
        return kIOReturnError;
    }
    if (cur == 1) {
        kern_return_t result = smc_write_u8(mkey, 0, &res); /* accepted while Ftst=1 */
        if (result != kIOReturnSuccess) {
            schedule_restore_retry(fan);
            return result;
        }
        if (smc_read_u8(mkey, &cur) != 0 || cur == 1) {
            schedule_restore_retry(fan);
            return kIOReturnError;
        }
    }
    g_manual[fan] = 0;
    g_restore_pending[fan] = 0;

    /* Once no fan is held manual, hand control back so thermalmonitord can idle
     * fans to 0 RPM. (The firmware otherwise reclaims only when Ftst clears.)
     *
     * "No fan held" must count fans still awaiting a retry, not just the ones
     * currently flagged manual: on a multi-fan machine, clearing Ftst while a
     * peer's restore is still pending drops the unlock that the pending restore
     * needs, stranding that fan at a fixed RPM until the next daemon start
     * reconciles it. `has_outstanding_manual_control` is the same predicate
     * `restore_owned_control` uses, so both paths agree on when it is safe. */
    int outstanding = 0;
    for (int i = 0; i < MAX_FANS; i++) {
        if (g_manual[i] || g_restore_pending[i]) {
            outstanding = 1;
            break;
        }
    }
    if (!outstanding && g_ftst_avail) {
        uint8_t r2 = 0;
        kern_return_t result = smc_write_u8("Ftst", 0, &r2);
        if (result != kIOReturnSuccess) {
            g_ftst_engaged = 1;
            schedule_restore_retry(-1);
            return result;
        }
        g_ftst_engaged = 0;
    }

    if (!has_outstanding_manual_control()) {
        g_lease_state = LEASE_NONE;
    }

    return kIOReturnSuccess;
}

static uint64_t monotonic_milliseconds(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return (uint64_t)now.tv_sec * 1000u + (uint64_t)now.tv_nsec / 1000000u;
}

static void renew_control_lease(void)
{
    g_lease_state = LEASE_ACTIVE;
    g_last_control_activity_ms = monotonic_milliseconds();
    g_next_restore_attempt_ms = 0;
    g_restore_retry_delay_ms = 1000;
}

static const char *control_lease_state_name(void)
{
    switch (g_lease_state) {
    case LEASE_ACTIVE: return "active";
    case LEASE_RESTORE_PENDING: return "restoring";
    case LEASE_NONE:
    default: return "idle";
    }
}

static int has_outstanding_manual_control(void)
{
    for (int fan = 0; fan < MAX_FANS; fan++) {
        if (g_manual[fan] || g_restore_pending[fan]) {
            return 1;
        }
    }
    return g_ftst_engaged;
}

static void restore_owned_control(void)
{
    int restore_failed = 0;
    for (int fan = 0; fan < MAX_FANS; fan++) {
        if (g_manual[fan] || g_restore_pending[fan]) {
            if (set_fan_auto(fan) != kIOReturnSuccess) {
                restore_failed = 1;
            }
        }
    }
    if (g_ftst_engaged && g_ftst_avail) {
        uint8_t result = 0;
        if (smc_write_u8("Ftst", 0, &result) == kIOReturnSuccess) {
            g_ftst_engaged = 0;
        } else {
            restore_failed = 1;
        }
    }
    if (restore_failed || has_outstanding_manual_control()) {
        g_lease_state = LEASE_RESTORE_PENDING;
        uint64_t now = monotonic_milliseconds();
        g_next_restore_attempt_ms = now == 0 ? 0 : now + g_restore_retry_delay_ms;
        if (g_restore_retry_delay_ms < 60000) {
            g_restore_retry_delay_ms *= 2;
            if (g_restore_retry_delay_ms > 60000) {
                g_restore_retry_delay_ms = 60000;
            }
        }
    } else {
        g_lease_state = LEASE_NONE;
        g_last_control_activity_ms = 0;
        g_next_restore_attempt_ms = 0;
        g_restore_retry_delay_ms = 1000;
    }
}

static void enforce_control_lease(void)
{
    uint64_t now = monotonic_milliseconds();
    if (g_lease_state == LEASE_ACTIVE && now != 0 &&
        (g_last_control_activity_ms == 0 ||
         now - g_last_control_activity_ms >= CONTROL_LEASE_TIMEOUT_MS)) {
        g_lease_state = LEASE_RESTORE_PENDING;
        g_next_restore_attempt_ms = 0;
    }
    if (g_lease_state == LEASE_RESTORE_PENDING &&
        (g_next_restore_attempt_ms == 0 || now == 0 || now >= g_next_restore_attempt_ms)) {
        fprintf(stderr, "fanfan-smcd: restoring firmware fan control\n");
        restore_owned_control();
    }
}

static int parse_int(const char *s, int *out)
{
    char *end = NULL;
    long value = strtol(s, &end, 10);
    if (s == end || *end != '\0' || value < INT32_MIN || value > INT32_MAX) {
        return 0;
    }
    *out = (int)value;
    return 1;
}

static const char *handle_command(char *buffer, xpc_connection_t peer,
                                  char *response, size_t response_size)
{
    char *cmd = strtok(buffer, " ");
    if (cmd == NULL) {
        return "ERR empty";
    }

    if (strcmp(cmd, "PINGV2") == 0) {
        if (strtok(NULL, " ") != NULL) {
            return "ERR trailing-arguments";
        }
        /* Health checks must stay fast. Lease restoration performs synchronous
         * IOKit writes and can take longer than the client's one-second health
         * timeout. The lease timer enforces it every second, so PING only
         * reports the current state. */
        snprintf(response, response_size, "OK pong %d %s",
                 PROTOCOL_VERSION, control_lease_state_name());
        return response;
    }
    if (strcmp(cmd, "RENEWV2") == 0) {
        if (strtok(NULL, " ") != NULL) {
            return "ERR trailing-arguments";
        }
        enforce_control_lease();
        if (g_lease_state != LEASE_ACTIVE) {
            return "ERR lease-inactive";
        }
        renew_control_lease();
        return "OK";
    }

    char *fan_s = strtok(NULL, " ");
    int fan = -1;
    if (fan_s == NULL || !parse_int(fan_s, &fan) || fan < 0 || fan >= MAX_FANS) {
        return "ERR invalid-fan";
    }

    kern_return_t result = kIOReturnError;
    if (strcmp(cmd, "SETV2") == 0) {
        char *rpm_s = strtok(NULL, " ");
        int rpm = -1;
        if (rpm_s == NULL || !parse_int(rpm_s, &rpm) || rpm < MIN_RPM || rpm > MAX_RPM) {
            return "ERR invalid-rpm";
        }
        if (strtok(NULL, " ") != NULL) {
            return "ERR trailing-arguments";
        }
        result = set_fan_speed(fan, rpm);
    } else if (strcmp(cmd, "AUTOV2") == 0) {
        if (strtok(NULL, " ") != NULL) {
            return "ERR trailing-arguments";
        }
        result = set_fan_auto(fan);
    } else {
        return "ERR unknown-command";
    }

    if (result == kIOReturnSuccess) {
        if (strcmp(cmd, "SETV2") == 0) {
            if (g_lease_state == LEASE_RESTORE_PENDING) {
                return "ERR restore-pending";
            }
            renew_control_lease();
            g_control_owner = peer;
        } else if (strcmp(cmd, "AUTOV2") == 0 && g_lease_state == LEASE_ACTIVE) {
            renew_control_lease();
        }
        return "OK";
    }
    snprintf(response, response_size, "ERR iokit-%08x", result);
    return response;
}

static void cleanup(int sig)
{
    (void)sig;
    for (int attempt = 0; attempt < 3; attempt++) {
        restore_owned_control();
        if (g_lease_state == LEASE_NONE) {
            break;
        }
        usleep(100 * 1000);
    }
    smc_close();
    exit(0);
}

static void request_shutdown(int sig)
{
    (void)sig;
    g_should_exit = 1;
}

static void handle_message(xpc_connection_t peer, xpc_object_t message)
{
    xpc_object_t reply = xpc_dictionary_create_reply(message);
    if (reply == NULL) {
        return;
    }

    char buffer[MAX_COMMAND_LENGTH + 1];
    char response[64];
    const char *line = xpc_dictionary_get_string(message, "line");
    const char *answer;
    if (line == NULL) {
        answer = "ERR empty";
    } else if (strlen(line) > MAX_COMMAND_LENGTH) {
        answer = "ERR command-too-long";
    } else {
        snprintf(buffer, sizeof(buffer), "%s", line);
        answer = handle_command(buffer, peer, response, sizeof(response));
    }
    xpc_dictionary_set_string(reply, "reply", answer);
    xpc_connection_send_message(peer, reply);
    xpc_release(reply);
    enforce_control_lease();
}

static void peer_disconnected(xpc_connection_t peer)
{
    if (peer != g_control_owner) {
        return;
    }
    /* The app quit or crashed while holding control. Give the fans back now
     * instead of waiting out the lease. */
    g_control_owner = NULL;
    if (g_lease_state == LEASE_ACTIVE) {
        fprintf(stderr, "fanfan-smcd: controlling client disconnected\n");
        g_lease_state = LEASE_RESTORE_PENDING;
        g_next_restore_attempt_ms = 0;
        enforce_control_lease();
    }
}

static void accept_peer(xpc_connection_t peer)
{
    if (xpc_connection_set_peer_code_signing_requirement(peer, CLIENT_REQUIREMENT) != 0) {
        fprintf(stderr, "fanfan-smcd: cannot set client requirement; rejecting\n");
        xpc_connection_cancel(peer);
        return;
    }
    xpc_retain(peer);
    xpc_connection_set_target_queue(peer, g_queue);
    xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
        xpc_type_t type = xpc_get_type(event);
        if (type == XPC_TYPE_DICTIONARY) {
            handle_message(peer, event);
        } else if (event == XPC_ERROR_CONNECTION_INVALID) {
            /* Also delivered when the client fails the signing requirement. */
            peer_disconnected(peer);
            xpc_release(peer);
        }
    });
    xpc_connection_resume(peer);
}

/* Boot out and delete the pre-1.4 LaunchDaemon. Its SIGTERM handler hands the
 * fans back to firmware before it exits. */
static void remove_legacy_daemon(void)
{
    if (access(LEGACY_PLIST, F_OK) != 0) {
        return;
    }
    fprintf(stderr, "fanfan-smcd: removing legacy daemon\n");
    char *argv[] = {"/bin/launchctl", "bootout", "system/" LEGACY_LABEL, NULL};
    pid_t pid = 0;
    if (posix_spawn(&pid, argv[0], NULL, NULL, argv, NULL) == 0) {
        int status = 0;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
        }
    }
    unlink(LEGACY_PLIST);
    unlink("/Library/PrivilegedHelperTools/fanfan-smcd");
    unlink("/usr/local/libexec/fanfan-smcd");
    unlink("/var/run/fanfan-smcd.sock");
}

/* launchd runs this binary straight out of the app bundle. When an update or
 * uninstall replaces or removes it, hand the fans back and exit; KeepAlive
 * relaunches whatever binary is there now. */
static void watch_own_executable(void)
{
    char path[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) {
        return;
    }
    int fd = open(path, O_EVTONLY);
    if (fd < 0) {
        return;
    }
    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
        DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME |
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_REVOKE,
        g_queue);
    if (source == NULL) {
        close(fd);
        return;
    }
    dispatch_source_set_event_handler(source, ^{
        fprintf(stderr, "fanfan-smcd: executable replaced; restarting\n");
        cleanup(0);
    });
    dispatch_resume(source);
}

int main(void)
{
    signal(SIGINT, request_shutdown);
    signal(SIGTERM, request_shutdown);
    signal(SIGPIPE, SIG_IGN);

    remove_legacy_daemon();

    kern_return_t result = smc_open();
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "fanfan-smcd: cannot open SMC: %08x\n", result);
        return 1;
    }

    probe_capabilities();
    reconcile_startup_control();

    /* One serial queue owns all SMC state: client messages, the lease timer
     * and shutdown never run concurrently. */
    g_queue = dispatch_queue_create("com.hoobnn.fanfan.helper", DISPATCH_QUEUE_SERIAL);

    xpc_connection_t listener = xpc_connection_create_mach_service(
        SERVICE_NAME, g_queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (listener == NULL) {
        fprintf(stderr, "fanfan-smcd: cannot create XPC listener\n");
        cleanup(0);
    }
    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_CONNECTION) {
            accept_peer((xpc_connection_t)event);
        }
    });

    /* Signal handlers only set a flag; this timer turns it into a clean
     * shutdown and enforces the lease while idle. */
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{
        if (g_should_exit) {
            cleanup(0);
        }
        enforce_control_lease();
    });
    dispatch_resume(timer);

    watch_own_executable();
    xpc_connection_resume(listener);
    dispatch_main();
}
