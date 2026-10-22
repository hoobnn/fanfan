/* Replay delayed firmware mode changes through the real daemon command path.
 * Only IOKit and time are replaced; parsing, writes, verification and rollback
 * run unmodified. No hardware is opened by this test. */
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

static kern_return_t fake_io_call(mach_port_t, uint32_t, const void *, size_t, void *, size_t *);
static int fake_usleep(useconds_t);
static int fake_clock_gettime(clockid_t, struct timespec *);
#define IOConnectCallStructMethod fake_io_call
#define usleep fake_usleep
#define clock_gettime fake_clock_gettime
#define main unused_daemon_main
#include "../../tools/fanfan-smcd/fanfan-smcd.c"
#undef main
#undef clock_gettime
#undef usleep
#undef IOConnectCallStructMethod

typedef struct {
    UInt8 mode;
    UInt8 requested_mode;
    uint64_t apply_at;
    int target;
} FakeFan;
static FakeFan fans[2];
static uint64_t fake_now;
static unsigned delay_ms;
static int reject_manual;
static int require_ftst;
static int ftst;
static int fail_reads_after_write;
static int read_failures;
static int mode_writes;
static int auto_writes;
static int target_writes;
static uint64_t shutdown_at;

static void advance(unsigned ms)
{
    fake_now += ms;
    if (shutdown_at && fake_now >= shutdown_at) g_should_exit = 1;
    for (int fan = 0; fan < 2; fan++) {
        if (fans[fan].apply_at && fake_now >= fans[fan].apply_at) {
            fans[fan].mode = fans[fan].requested_mode;
            fans[fan].apply_at = 0;
        }
    }
}

static int fake_usleep(useconds_t microseconds)
{
    advance((microseconds + 999) / 1000);
    return 0;
}

static int fake_clock_gettime(clockid_t clock_id, struct timespec *out)
{
    (void)clock_id;
    out->tv_sec = (time_t)(fake_now / 1000);
    out->tv_nsec = (long)(fake_now % 1000) * 1000000;
    return 0;
}

static kern_return_t fake_io_call(mach_port_t connection, uint32_t selector,
                                 const void *input_data, size_t input_size,
                                 void *output_data, size_t *output_size)
{
    (void)connection;
    if (selector != KERNEL_INDEX_SMC || input_size != sizeof(SMCKeyData_t) ||
        *output_size != sizeof(SMCKeyData_t)) return kIOReturnBadArgument;
    const SMCKeyData_t *input = input_data;
    SMCKeyData_t *output = output_data;
    memset(output, 0, sizeof(*output));
    advance(0);
    char key[5]; smc_ultostr(key, input->key);
    int is_ftst = strcmp(key, "Ftst") == 0 && require_ftst;
    int fan = key[0] == 'F' && key[1] >= '0' && key[1] <= '1' ? key[1] - '0' : -1;
    int is_mode = fan >= 0 && strcmp(key + 2, "Md") == 0;
    int is_target = fan >= 0 && strcmp(key + 2, "Tg") == 0;
    if (!is_ftst && !is_mode && !is_target) {
        output->result = SMC_RESULT_NOT_FOUND;
        return kIOReturnSuccess;
    }
    if (input->data8 == SMC_CMD_READ_KEYINFO) {
        output->keyInfo.dataSize = is_target ? 4 : 1;
        output->keyInfo.dataType = smc_strtoul(is_target ? "flt " : "ui8 ", 4, 16);
    } else if (input->data8 == SMC_CMD_READ_BYTES) {
        if (is_mode && read_failures) {
            if (read_failures > 0) read_failures--;
            output->result = SMC_RESULT_NOT_FOUND;
        } else if (is_mode) {
            output->bytes[0] = fans[fan].mode;
        } else if (is_ftst) {
            output->bytes[0] = (UInt8)ftst;
        } else {
            float target = (float)fans[fan].target;
            memcpy(output->bytes, &target, sizeof(target));
        }
    } else if (input->data8 == SMC_CMD_WRITE_BYTES) {
        if (is_mode) {
            if (input->bytes[0] == 1 && (reject_manual || (require_ftst && !ftst))) {
                output->result = SMC_RESULT_BAD_COMMAND;
                return kIOReturnSuccess;
            }
            mode_writes++;
            if (input->bytes[0] == 0) auto_writes++;
            fans[fan].requested_mode = input->bytes[0];
            fans[fan].apply_at = fake_now + delay_ms;
            read_failures = fail_reads_after_write;
            advance(0);
        } else if (is_ftst) {
            ftst = input->bytes[0];
        } else {
            if (fans[fan].mode != 1) {
                output->result = SMC_RESULT_BAD_COMMAND;
            } else {
                float target; memcpy(&target, input->bytes, sizeof(target));
                fans[fan].target = (int)target;
                target_writes++;
            }
        }
    } else return kIOReturnBadArgument;
    return kIOReturnSuccess;
}

static void reset(void)
{
    memset(fans, 0, sizeof(fans));
    memset(g_manual, 0, sizeof(g_manual));
    memset(g_restore_pending, 0, sizeof(g_restore_pending));
    g_conn = 1; fake_now = 1000; delay_ms = 120;
    g_should_exit = 0; g_ftst_avail = 0; g_ftst_engaged = 0;
    g_lease_state = LEASE_NONE; g_last_control_activity_ms = 0;
    g_next_restore_attempt_ms = 0; g_restore_retry_delay_ms = 1000;
    g_control_owner = NULL;
    snprintf(g_mode_fmt, sizeof(g_mode_fmt), "F%%dMd");
    for (int fan = 0; fan < MAX_FANS; fan++) {
        g_min_rpm[fan] = 1200; g_max_rpm[fan] = 6000; g_limits_known[fan] = 1;
    }
    reject_manual = require_ftst = ftst = 0;
    fail_reads_after_write = read_failures = 0;
    mode_writes = auto_writes = target_writes = 0;
    shutdown_at = 0;
}

static int command_ok(const char *command)
{
    char input[128], response[64];
    snprintf(input, sizeof(input), "%s", command);
    return strcmp(handle_command(input, NULL, response, sizeof(response)), "OK") == 0;
}

#define CHECK(condition, message) do { if (!(condition)) { \
    fprintf(stderr, "FAIL: %s: %s\n", __func__, message); return 1; } } while (0)

static int delayed_manual_then_target(void)
{
    reset();
    CHECK(command_ok("SETV2 0 5779"), "accepted manual mode must settle before SET is judged");
    CHECK(fans[0].mode == 1 && fans[0].target == 5779, "target must reach firmware after mode change");
    CHECK(target_writes == 1 && g_lease_state == LEASE_ACTIVE, "successful SET must establish its lease");
    return 0;
}

static int delayed_system_restore(void)
{
    reset(); fans[0].mode = 1; g_manual[0] = 1; g_lease_state = LEASE_ACTIVE;
    CHECK(command_ok("AUTOV2 0"), "AUTO must wait for the accepted mode write");
    CHECK(fans[0].mode == 0 && g_lease_state == LEASE_NONE, "AUTO success requires a verified handoff");
    return 0;
}

static int transient_verification_read_failure(void)
{
    reset(); fail_reads_after_write = 1;
    CHECK(command_ok("SETV2 0 5779"), "a transient verification read must be retried");
    CHECK(fans[0].target == 5779, "verification retry must allow the real target write");
    return 0;
}

static int timed_out_manual_request_is_cancelled(void)
{
    reset(); delay_ms = 1500;
    CHECK(!command_ok("SETV2 0 5779"), "an unobserved mode transition must not report SET success");
    CHECK(target_writes == 0, "never write a target without confirmed manual mode");
    CHECK(auto_writes > 0, "rollback must supersede a queued manual write even while mode still reads 0");
    advance(3000);
    CHECK(fans[0].mode == 0, "a delayed manual write must not strand the fan after failure");
    return 0;
}

static int rejected_write_is_not_accepted(void)
{
    reset(); reject_manual = 1;
    CHECK(!command_ok("SETV2 0 5779"), "firmware rejection must remain a failure");
    CHECK(target_writes == 0 && fans[0].mode == 0, "a rejected mode write must not write a target");
    return 0;
}

static int unreadable_restore_stays_pending(void)
{
    reset(); fans[0].mode = 1; g_manual[0] = 1; fail_reads_after_write = -1;
    CHECK(!command_ok("AUTOV2 0"), "unreadable verification must not report success");
    CHECK(g_lease_state == LEASE_RESTORE_PENDING && g_restore_pending[0], "failed handoff must remain retryable");
    CHECK(fake_now <= 2100, "verification must have a finite deadline");
    return 0;
}

static int shutdown_still_confirms_restore(void)
{
    reset(); fans[0].mode = 1; g_manual[0] = 1; g_should_exit = 1;
    CHECK(command_ok("AUTOV2 0"), "shutdown must not abort its own firmware handoff");
    CHECK(fans[0].mode == 0, "shutdown handoff must finish the asynchronous change");
    return 0;
}

static int ftst_unlock_waits_after_acceptance(void)
{
    reset(); require_ftst = 1; g_ftst_avail = 1;
    CHECK(command_ok("SETV2 0 5779"), "Ftst path must also wait for an accepted mode write");
    CHECK(fans[0].target == 5779 && ftst == 1, "unlock must precede the verified target write");
    CHECK(command_ok("SETV2 1 6000"), "second fan must also acquire manual control");
    CHECK(command_ok("AUTOV2 0"), "Ftst handoff must confirm system mode");
    CHECK(fans[0].mode == 0 && fans[1].mode == 1 && ftst == 1, "keep Ftst while another fan remains manual");
    CHECK(command_ok("AUTOV2 1"), "second fan must also finish its handoff");
    CHECK(fans[1].mode == 0 && ftst == 0, "clear Ftst only after the last confirmed handoff");
    return 0;
}

static int existing_system_mode_is_a_fast_noop(void)
{
    reset(); fans[0].mode = 3;
    CHECK(command_ok("AUTOV2 0"), "firmware system mode 3 is already automatic");
    CHECK(mode_writes == 0 && fake_now == 1000, "leave an unowned system fan untouched");
    return 0;
}

static int shutdown_cancels_acquisition_and_restores(void)
{
    reset(); shutdown_at = 1060;
    CHECK(!command_ok("SETV2 0 5779"), "shutdown must cancel acquisition");
    CHECK(target_writes == 0 && auto_writes > 0, "cancel the queued manual request before shutdown");
    advance(1000);
    CHECK(fans[0].mode == 0, "shutdown rollback must leave firmware in control");
    return 0;
}

static int synchronous_firmware_does_not_wait(void)
{
    reset(); delay_ms = 0;
    CHECK(command_ok("SETV2 0 5779") && command_ok("AUTOV2 0"), "synchronous firmware must still work");
    CHECK(fake_now == 1000, "already-confirmed transitions need no artificial delay");
    return 0;
}

int main(void)
{
    int (*cases[])(void) = { delayed_manual_then_target, delayed_system_restore,
        transient_verification_read_failure, timed_out_manual_request_is_cancelled,
        rejected_write_is_not_accepted, unreadable_restore_stays_pending,
        shutdown_still_confirms_restore, ftst_unlock_waits_after_acceptance,
        existing_system_mode_is_a_fast_noop, shutdown_cancels_acquisition_and_restores,
        synchronous_firmware_does_not_wait };
    int failures = 0;
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        int result = cases[i](); failures += result;
        if (!result) printf("PASS: SMC transition case %u\n", i + 1);
    }
    if (failures) return 1;
    puts("11 SMC mode-transition regressions passed");
    return 0;
}
