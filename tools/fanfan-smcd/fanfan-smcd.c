/*
 * fanfan privileged SMC daemon.
 *
 * Keeps a root-owned AppleSMC connection open and accepts a deliberately small
 * local socket protocol:
 *   SET <fan> <rpm>
 *   AUTO <fan>
 *   PING
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
 *   Reference: github.com/agoodkind/macos-smc-fan
 */

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>
#include "smc.h"

#define SOCKET_PATH "/var/run/fanfan-smcd.sock"
#define MAX_FANS 8
#define MIN_RPM 500
#define MAX_RPM 8000

/* SMC firmware result codes (returned in SMCKeyData_t.result). */
#define SMC_RESULT_OK          0x00
#define SMC_RESULT_BAD_COMMAND 0x82  /* mode write rejected while system-locked */
#define SMC_RESULT_NOT_FOUND   0x84  /* key does not exist on this hardware */

/* Ftst unlock timing. Observed ~7.8 s on M4 Pro; leave generous headroom. */
#define UNLOCK_TIMEOUT_MS 12000
#define UNLOCK_STEP_MS    100

static io_connect_t g_conn = 0;
static int g_server_fd = -1;

/* Capabilities probed once at startup. */
static char g_mode_fmt[8] = "F%dMd"; /* "F%dMd" (M4) or "F%dmd" (M5) */
static int  g_ftst_avail = 0;        /* whether the Ftst key exists here */
static int  g_manual[MAX_FANS];      /* per-fan: 1 once manual control is held */

static UInt32 smc_strtoul(char *str, int size, int base)
{
    UInt32 total = 0;
    for (int i = 0; i < size; i++) {
        if (base == 16) {
            total += str[i] << (size - 1 - i) * 8;
        } else {
            total += ((unsigned char)str[i] << (size - 1 - i) * 8);
        }
    }
    return total;
}

static void smc_ultostr(char *str, UInt32 val)
{
    str[0] = '\0';
    sprintf(str, "%c%c%c%c",
            (unsigned int)val >> 24,
            (unsigned int)val >> 16,
            (unsigned int)val >> 8,
            (unsigned int)val);
}

static kern_return_t smc_call(int index, SMCKeyData_t *input, SMCKeyData_t *output)
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
    sprintf(val->key, "%s", key);

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
    snprintf(out, out_size, g_mode_fmt, fan);
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

    /* Fast path: already manual (the common case after the first unlock). */
    if (smc_read_u8(mkey, &cur) == 0 && cur == 1) {
        g_manual[fan] = 1;
        return kIOReturnSuccess;
    }

    /* Try a direct mode write — succeeds on M1/M5 with no unlock needed. */
    if (smc_write_u8(mkey, 1, &res) == kIOReturnSuccess &&
        smc_read_u8(mkey, &cur) == 0 && cur == 1) {
        g_manual[fan] = 1;
        return kIOReturnSuccess;
    }

    /* Locked (mode 3). Without Ftst there is no unlock path on this hardware. */
    if (!g_ftst_avail) {
        return kIOReturnNotPrivileged;
    }

    /* Engage diagnostic mode and wait for thermalmonitord to yield. */
    if (smc_write_u8("Ftst", 1, &res) != kIOReturnSuccess) {
        return kIOReturnError;
    }
    usleep(500 * 1000);

    int waited = 0;
    while (waited < UNLOCK_TIMEOUT_MS) {
        res = 0;
        kern_return_t wr = smc_write_u8(mkey, 1, &res);
        if (wr == kIOReturnSuccess && smc_read_u8(mkey, &cur) == 0 && cur == 1) {
            g_manual[fan] = 1;
            return kIOReturnSuccess;
        }
        usleep(UNLOCK_STEP_MS * 1000);
        waited += UNLOCK_STEP_MS;
    }
    return kIOReturnTimeout;
}

static kern_return_t set_fan_speed(int fan, int rpm)
{
    kern_return_t result = ensure_manual(fan);
    if (result != kIOReturnSuccess) {
        return result;
    }

    SMCVal_t val;
    char key[5];
    snprintf(key, sizeof(key), "F%dTg", fan);

    result = smc_read_key(key, &val);
    if (result != kIOReturnSuccess) {
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
        return kIOReturnUnsupported;
    }

    snprintf(val.key, sizeof(val.key), "%s", key);
    uint8_t res = 0;
    return smc_write_key(val, &res);
}

static kern_return_t set_fan_auto(int fan)
{
    char mkey[8];
    fan_mode_key(fan, mkey, sizeof(mkey));

    /* Only act if the fan is actually in manual mode; AUTO is otherwise a no-op. */
    UInt8 cur = 0;
    uint8_t res = 0;
    if (smc_read_u8(mkey, &cur) == 0 && cur == 1) {
        smc_write_u8(mkey, 0, &res); /* accepted while Ftst=1 */
    }
    g_manual[fan] = 0;

    /* Once no fan is held manual, hand control back so thermalmonitord can idle
     * fans to 0 RPM. (The firmware otherwise reclaims only when Ftst clears.) */
    int any_manual = 0;
    for (int i = 0; i < MAX_FANS; i++) {
        if (g_manual[i]) {
            any_manual = 1;
            break;
        }
    }
    if (!any_manual && g_ftst_avail) {
        uint8_t r2 = 0;
        smc_write_u8("Ftst", 0, &r2);
    }

    return kIOReturnSuccess;
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

static void write_response(int fd, const char *message)
{
    (void)write(fd, message, strlen(message));
}

static void handle_client(int fd)
{
    char buffer[128];
    ssize_t n = read(fd, buffer, sizeof(buffer) - 1);
    if (n <= 0) {
        return;
    }
    buffer[n] = '\0';
    buffer[strcspn(buffer, "\r\n")] = '\0';

    char *cmd = strtok(buffer, " ");
    if (cmd == NULL) {
        write_response(fd, "ERR empty\n");
        return;
    }

    if (strcmp(cmd, "PING") == 0) {
        write_response(fd, "OK pong\n");
        return;
    }

    char *fan_s = strtok(NULL, " ");
    int fan = -1;
    if (fan_s == NULL || !parse_int(fan_s, &fan) || fan < 0 || fan >= MAX_FANS) {
        write_response(fd, "ERR invalid-fan\n");
        return;
    }

    kern_return_t result = kIOReturnError;
    if (strcmp(cmd, "SET") == 0) {
        char *rpm_s = strtok(NULL, " ");
        int rpm = -1;
        if (rpm_s == NULL || !parse_int(rpm_s, &rpm) || rpm < MIN_RPM || rpm > MAX_RPM) {
            write_response(fd, "ERR invalid-rpm\n");
            return;
        }
        result = set_fan_speed(fan, rpm);
    } else if (strcmp(cmd, "AUTO") == 0) {
        result = set_fan_auto(fan);
    } else {
        write_response(fd, "ERR unknown-command\n");
        return;
    }

    if (result == kIOReturnSuccess) {
        write_response(fd, "OK\n");
    } else {
        char response[64];
        snprintf(response, sizeof(response), "ERR iokit-%08x\n", result);
        write_response(fd, response);
    }
}

static void cleanup(int sig)
{
    (void)sig;
    if (g_server_fd >= 0) {
        close(g_server_fd);
    }
    unlink(SOCKET_PATH);
    smc_close();
    exit(0);
}

int main(void)
{
    signal(SIGINT, cleanup);
    signal(SIGTERM, cleanup);

    kern_return_t result = smc_open();
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "fanfan-smcd: cannot open SMC: %08x\n", result);
        return 1;
    }

    probe_capabilities();

    unlink(SOCKET_PATH);
    g_server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (g_server_fd < 0) {
        perror("socket");
        cleanup(0);
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (bind(g_server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        cleanup(0);
    }
    chmod(SOCKET_PATH, 0660);
    chown(SOCKET_PATH, 0, 80); // root:admin

    if (listen(g_server_fd, 16) < 0) {
        perror("listen");
        cleanup(0);
    }

    for (;;) {
        int client_fd = accept(g_server_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("accept");
            break;
        }
        handle_client(client_fd);
        close(client_fd);
    }

    cleanup(0);
    return 0;
}
