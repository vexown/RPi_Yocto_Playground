/*
 * serial-logger.c — read a serial port, write what arrives to a log file.
 *
 * This is a rewrite of the Python serial_logger.py that has been running on
 * the deployed Pi Zero W. Same job, but as a ~15 KB static-ish binary with no
 * runtime dependencies, because dragging CPython + pyserial onto a 512 MB
 * ARMv6 board to do forty lines of read()/write() is most of an image.
 *
 * WHAT CHANGED FROM THE PYTHON, AND WHY
 *
 * 1. The device is an ARGUMENT, not a constant. The original hardcoded
 *    /dev/ttyUSB0, which is the node that ftdi_sio / cp210x / ch341 create.
 *    Plug in a CDC-ACM device (a Pico Debugprobe, most modern MCU boards)
 *    and the kernel calls it /dev/ttyACM0 instead, the open() fails, and
 *    with Restart=always the service crash-loops forever. udev now names
 *    the device and systemd passes it in — see serial-logger@.service.
 *
 * 2. No busy-wait. The original was:
 *        while True:
 *            if ser.in_waiting > 0:
 *                line = ser.readline()
 *    With no data arriving, that loop spins as fast as the CPU allows,
 *    asking the kernel "anything yet?" over and over. On a single 1 GHz
 *    ARMv6 core that is 100% of the machine, burning power to do nothing.
 *    Here poll() blocks until there is either data or a timeout — the CPU
 *    is genuinely idle in between.
 *
 * 3. flush() is not fsync(). The Python said:
 *        log_file.flush()   # FORCE saving to SD card immediately
 *    It does not. flush() moves bytes from the process's buffer into the
 *    kernel's page cache; they are still in RAM and still lost on a power
 *    cut. Only fsync() pushes them at the card. But fsync()-per-line would
 *    be brutal: every call is an erase-write cycle on flash, and this box
 *    is meant to survive having its power yanked, not to die of wear.
 *    So we bound the loss window instead — see FSYNC_* below.
 *
 * 4. Data goes to the file ONLY, not also to stdout. Under systemd, stdout
 *    is the journal, so the original wrote every logged byte to the SD card
 *    twice. Status and errors still go to stderr (and thus the journal),
 *    which is what you actually want to see in `journalctl`. To watch data
 *    live, tail the log file.
 *
 * ADDED IN SESSION 27
 *
 * 5. The file name CORRECTS ITSELF when the clock does. A Pi has no
 *    battery-backed RTC, and this unit starts the instant udev sees the
 *    adapter -- measured at 18.85 s on this board, against NTP landing at
 *    18.19 s on one boot and 20.34 s on the next. So whether the name is
 *    right depends on how fast wifi associated that morning, which is worse
 *    than being reliably wrong. Two bad names were observed on the card:
 *    the image's build date (first boot after a reflash, before
 *    /var/lib/systemd/timesync/clock exists) and the last-run time (every
 *    boot after). The error equals however long the board was off.
 *
 *    The fix is a timerfd on CLOCK_REALTIME created with
 *    TFD_TIMER_CANCEL_ON_SET. We are not interested in the timer firing --
 *    we are interested in the kernel CANCELLING it, which it does when
 *    something STEPS the wall clock. That surfaces as read() returning
 *    ECANCELED. At that point we know the real time and, from
 *    CLOCK_MONOTONIC, how long we have been running, so the true start time
 *    is a subtraction. Then rename() the file.
 *
 *    Why not just order the unit After=time-sync.target: because that puts
 *    the network in front of a USB reader. The device is here NOW; waiting
 *    for DHCP and NTP before logging it is the wrong trade for a tool whose
 *    entire job is catching early boot output. This approach adds no
 *    ordering dependency at all -- the unit still starts the microsecond
 *    udev fires, and the correction arrives a second or two later on its
 *    own. A slewed clock does not trigger it, which is correct: slewing
 *    never moves the clock far enough to matter for a file name.
 *
 * 6. The logger BOUNDS ITS OWN DISK USAGE, and rotates on SIGHUP. The
 *    adapter cannot be unplugged without resetting this board, so without
 *    rotation every capture accumulates into one file forever. Measured on
 *    hardware: ~77 bytes/sec, about 6.7 MB/day, against 29.5 MB free on a
 *    100 MB rootfs -- roughly four days to fill the disk. A full rootfs on
 *    an unattended logger is not degradation, it is a dead board you may
 *    not be able to ssh into to fix.
 *
 *    So: SIGHUP closes the current file and opens a fresh one (the idiom
 *    logrotate uses), a size cap rotates automatically, and a total budget
 *    deletes the oldest captures for THIS device. Note the existing
 *    O_NOCTTY on the serial port is what makes SIGHUP safe to repurpose --
 *    it is precisely why a hangup on the wire cannot deliver us one.
 *
 *    A bigger partition is NOT a fix for this. Any fixed amount of space
 *    loses to unbounded growth; it only changes the date. Bounding the
 *    growth works at any partition size.
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>     /* PATH_MAX */
#include <poll.h>
#include <signal.h>
#include <stdint.h>     /* uint64_t, for the timerfd read */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/timerfd.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

/* Durability policy. We fsync() when EITHER of these trips:
 *   - FSYNC_BYTES have accumulated since the last sync (busy link), or
 *   - FSYNC_IDLE_MS have passed with no new data (quiet link).
 * So the most you can lose to a power cut is the smaller of "8 KB" and
 * "two seconds of traffic" — while a chatty device costs one flash write
 * per 8 KB instead of one per line. */
#define FSYNC_BYTES    8192
#define FSYNC_IDLE_MS  2000

#define READ_CHUNK     1024

/* Self-imposed limits, both overridable from /etc/default/serial-logger.
 * Zero disables either one.
 *
 * The defaults are chosen against the board we actually have: 29.5 MB free
 * on the rootfs. A 4 MB file is big enough that rotation is rare and small
 * enough to scp off a slow link; a 16 MB total leaves well over half the
 * free space for the OS. Both are deliberately conservative -- the point is
 * that the logger cannot fill the disk, not that it should hoard. */
#define DEFAULT_MAX_FILE_BYTES   (4ULL  * 1024 * 1024)
#define DEFAULT_MAX_TOTAL_BYTES  (16ULL * 1024 * 1024)

/* How many captures we are willing to consider when pruning. Far more than
 * the budget above can hold; it exists so the scan needs no allocation. */
#define MAX_PRUNE_ENTRIES 256

/* Set by the signal handler; checked by the main loop. sig_atomic_t is the
 * only type the C standard promises can be written by a handler and read by
 * the main flow without tearing. volatile stops the compiler caching it in
 * a register across the loop. */
static volatile sig_atomic_t stop_requested   = 0;
static volatile sig_atomic_t rotate_requested = 0;

static void on_signal(int signo)
{
    (void)signo;
    stop_requested = 1;
}

/* SIGHUP means "start a new file here", the same thing it means to every
 * daemon logrotate drives. Safe to use only because the serial port is
 * opened O_NOCTTY -- see the comment at that open() -- so a hangup on the
 * wire can never deliver this to us and be mistaken for an operator. */
static void on_hangup(int signo)
{
    (void)signo;
    rotate_requested = 1;
}

/* Map a human baud rate onto the speed_t constant termios wants. There is no
 * arithmetic relationship between the two — B115200 is an opaque token, not
 * the number 115200 — so a table is the only honest way to do this. */
static int baud_to_speed(long baud, speed_t *out)
{
    static const struct { long rate; speed_t code; } table[] = {
        {   9600, B9600   }, {  19200, B19200  }, {  38400, B38400  },
        {  57600, B57600  }, { 115200, B115200 }, { 230400, B230400 },
        { 460800, B460800 }, { 921600, B921600 },
    };

    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
        if (table[i].rate == baud) {
            *out = table[i].code;
            return 0;
        }
    }
    return -1;
}

/* Put the port into "raw" mode: hand us bytes exactly as they arrive.
 *
 * A tty defaults to being a TERMINAL, which means the kernel line discipline
 * is between us and the wire doing helpful things we emphatically do not
 * want in a logger — echoing input back out, translating CR to LF, buffering
 * until a newline, and treating ^C as a signal. cfmakeraw() clears that
 * entire layer in one call. */
static int configure_port(int fd, speed_t speed)
{
    struct termios tio;

    if (tcgetattr(fd, &tio) != 0)
        return -1;

    cfmakeraw(&tio);

    /* CLOCAL: don't care about modem control lines (DCD). Without it, a
     * USB adapter that isn't asserting carrier can block reads forever.
     * CREAD: actually enable the receiver. */
    tio.c_cflag |= CLOCAL | CREAD;
    /* No hardware flow control — most logging targets only wire TX/GND. */
    tio.c_cflag &= ~CRTSCTS;
    /* 8 data bits, no parity, one stop bit. */
    tio.c_cflag &= ~(PARENB | CSTOPB | CSIZE);
    tio.c_cflag |= CS8;

    /* We poll() before reading, so read() never needs to wait: return
     * whatever is available (VMIN=0, VTIME=0 is a pure non-blocking read
     * at the line-discipline level). */
    tio.c_cc[VMIN]  = 0;
    tio.c_cc[VTIME] = 0;

    if (cfsetispeed(&tio, speed) != 0 || cfsetospeed(&tio, speed) != 0)
        return -1;

    /* TCSANOW: apply immediately rather than waiting for pending output to
     * drain — there is no pending output, we never transmit. */
    return tcsetattr(fd, TCSANOW, &tio);
}

/* ------------------------------------------------------------------------
 * Time helpers
 * ------------------------------------------------------------------------ */

/* CLOCK_MONOTONIC counts since boot and is NEVER stepped by NTP, which is
 * exactly why it is the right clock for "how long have I been running".
 * CLOCK_REALTIME is the wall clock and is the one that lies. */
static long long monotonic_ms(void)
{
    struct timespec ts;

    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return 0;
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void make_stamp(time_t when, char *out, size_t outsz)
{
    struct tm tm_when;

    localtime_r(&when, &tm_when);
    strftime(out, outsz, "%Y-%m-%d_%H-%M-%S", &tm_when);
}

/* Arm (or re-arm) the cancel-on-set watch.
 *
 * TFD_TIMER_CANCEL_ON_SET only has meaning together with TFD_TIMER_ABSTIME
 * on a CLOCK_REALTIME timer -- the kernel needs an absolute deadline to
 * decide the deadline became meaningless. The deadline itself is a formality
 * here: we want the cancellation, not the expiry. A year out is used rather
 * than time_t's maximum because time_t is 32 bits on this ARMv6 target, so
 * the maximum is 2038 -- an arbitrary date that is no longer comfortably
 * far away.
 *
 * Must be re-armed after every cancellation, or we only ever notice the
 * first clock step. */
static int clock_watch_arm(int fd)
{
    struct itimerspec its;

    memset(&its, 0, sizeof(its));
    its.it_value.tv_sec = time(NULL) + 365 * 24 * 60 * 60;

    return timerfd_settime(fd, TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET,
                           &its, NULL);
}

/* ------------------------------------------------------------------------
 * Log file helpers
 * ------------------------------------------------------------------------ */

/* Open a fresh capture, stamped with the current wall clock.
 *
 * O_EXCL, not plain O_CREAT: if two files would land on the same second --
 * a rotation triggered twice quickly, or a restart inside one second -- we
 * want a second FILE, not two writers appending into one. The -N suffix is
 * the escape hatch. Returns the fd and fills in both stamp and path. */
static int open_log(const char *logdir, const char *devname,
                    char *stamp, size_t stampsz,
                    char *path,  size_t pathsz)
{
    int n;

    make_stamp(time(NULL), stamp, stampsz);

    for (n = 0; n < 100; n++) {
        int fd;

        if (n == 0)
            snprintf(path, pathsz, "%s/session_%s_%s.log",
                     logdir, devname, stamp);
        else
            snprintf(path, pathsz, "%s/session_%s_%s-%d.log",
                     logdir, devname, stamp, n);

        fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0644);
        if (fd >= 0)
            return fd;
        if (errno != EEXIST)
            break;
    }
    return -1;
}

/* Read a byte count from the environment, so the limits are configurable
 * from /etc/default/serial-logger without a rebuild. */
static unsigned long long env_bytes(const char *name, unsigned long long dflt)
{
    const char        *v = getenv(name);
    char              *end;
    unsigned long long n;

    if (v == NULL || *v == '\0')
        return dflt;

    errno = 0;
    n = strtoull(v, &end, 10);
    if (end == v || errno != 0)
        return dflt;
    return n;
}

/* Join a directory and a file name, refusing to produce a truncated path.
 *
 * snprintf() truncates safely -- it will not overflow -- but a truncated
 * path still NAMES something, and in a function whose next move is unlink()
 * that is the one failure mode worth being paranoid about. logdir can be up
 * to PATH_MAX and a name up to NAME_MAX, so the sum genuinely can overflow;
 * GCC's -Wformat-truncation is right to say so. Returns 0 on success. */
static int join_path(char *out, size_t outsz, const char *dir, const char *name)
{
    size_t dirlen  = strlen(dir);
    size_t namelen = strlen(name);

    /* Checked BEFORE writing rather than after. snprintf() would be safe
     * from overflow either way, but it would also hand back a truncated
     * path that still names something -- and the caller's next move is
     * unlink(). Measuring first makes the refusal unambiguous, and it also
     * stops -Wformat-truncation complaining about a risk we had already
     * handled. +2 covers the '/' and the terminator. */
    if (dirlen + namelen + 2 > outsz)
        return -1;

    memcpy(out, dir, dirlen);
    out[dirlen] = '/';
    memcpy(out + dirlen + 1, name, namelen);
    out[dirlen + 1 + namelen] = '\0';
    return 0;
}

/* Delete the oldest captures for THIS device until the directory's total
 * for this device is within budget.
 *
 * Scoped by the "session_<dev>_" prefix on purpose: two adapters can be
 * logging at once, and an instance must not delete the other instance's
 * work. It means the budget is per device rather than per disk, which is
 * the predictable behaviour even if it is not the tightest one.
 *
 * keep_path is never deleted -- it is the file currently open for writing,
 * and it is counted toward the total so the budget stays honest.
 *
 * HOW TIGHT IS THE BUDGET, REALLY: pruning runs at rotation boundaries, so
 * between two rotations the open file keeps growing with nothing trimming
 * it. Worst-case usage is therefore budget + max_file_bytes, not budget --
 * measured at 15424 bytes against a 12288 budget in the host tests. That is
 * still BOUNDED, which is the property that matters; it is simply not a
 * hard ceiling, and sizing a partition off this number should allow for the
 * extra file. */
static void prune_old_logs(const char *logdir, const char *devname,
                           const char *keep_path, unsigned long long budget)
{
    struct { char name[NAME_MAX + 1]; time_t mtime; off_t size; }
                        ents[MAX_PRUNE_ENTRIES];
    char                prefix[NAME_MAX + 1];
    const char         *keep_name;
    unsigned long long  total = 0;
    int                 count = 0;
    DIR                *d;
    struct dirent      *de;

    if (budget == 0)                 /* 0 means "no limit" */
        return;

    snprintf(prefix, sizeof(prefix), "session_%s_", devname);

    keep_name = strrchr(keep_path, '/');
    keep_name = keep_name ? keep_name + 1 : keep_path;

    d = opendir(logdir);
    if (d == NULL)
        return;

    while ((de = readdir(d)) != NULL && count < MAX_PRUNE_ENTRIES) {
        char        full[PATH_MAX];
        struct stat st;

        if (strncmp(de->d_name, prefix, strlen(prefix)) != 0)
            continue;

        if (join_path(full, sizeof(full), logdir, de->d_name) != 0)
            continue;
        if (stat(full, &st) != 0 || !S_ISREG(st.st_mode))
            continue;

        total += (unsigned long long)st.st_size;

        /* The open file counts toward the total but is not a candidate. */
        if (strcmp(de->d_name, keep_name) == 0)
            continue;

        snprintf(ents[count].name, sizeof(ents[count].name), "%s", de->d_name);
        ents[count].mtime = st.st_mtime;
        ents[count].size  = st.st_size;
        count++;
    }
    closedir(d);

    /* Repeatedly take the oldest remaining candidate. A selection scan is
     * O(n^2), which for a handful of files is free and avoids qsort and a
     * comparison function for no benefit. */
    while (total > budget && count > 0) {
        char full[PATH_MAX];
        int  oldest = 0, i;

        for (i = 1; i < count; i++)
            if (ents[i].mtime < ents[oldest].mtime)
                oldest = i;

        if (join_path(full, sizeof(full), logdir, ents[oldest].name) != 0) {
            /* Cannot name it safely, so do not touch it -- and drop it from
             * the candidate list so the loop still terminates. */
            ents[oldest] = ents[count - 1];
            count--;
            continue;
        }
        if (unlink(full) == 0) {
            total -= (unsigned long long)ents[oldest].size;
            /* Say so in the journal. Deleting someone's capture silently
             * would be the wrong kind of helpful. */
            fprintf(stderr, "pruned %s (%lld bytes) to stay under %llu\n",
                    ents[oldest].name, (long long)ents[oldest].size, budget);
        } else {
            fprintf(stderr, "cannot remove %s: %s\n", full, strerror(errno));
            /* Do not spin on a file we cannot delete. */
            total = 0;
        }
        ents[oldest] = ents[count - 1];
        count--;
    }
}

int main(int argc, char **argv)
{
    const char *device, *logdir;
    long        baud;
    speed_t     speed;
    char        path[PATH_MAX];
    char        stamp[32];
    const char *devname;
    int         serial_fd, log_fd, clock_fd;
    size_t      unsynced = 0;
    unsigned long long written = 0;
    unsigned long long max_file_bytes, max_total_bytes;
    long long   mono_start;
    struct sigaction sa;
    struct pollfd pfds[2];

    if (argc < 2 || argc > 4) {
        fprintf(stderr, "usage: %s <device> [baud] [logdir]\n", argv[0]);
        return 2;
    }

    device = argv[1];
    baud   = (argc > 2) ? strtol(argv[2], NULL, 10) : 115200;
    logdir = (argc > 3) ? argv[3] : "/var/log/serial-logger";

    if (baud_to_speed(baud, &speed) != 0) {
        fprintf(stderr, "unsupported baud rate %ld\n", baud);
        return 2;
    }

    /* Terminate on SIGTERM/SIGINT rather than dying where we stand, so the
     * final fsync() at the bottom actually runs. Deliberately NOT using
     * SA_RESTART: we WANT poll() to return EINTR so the loop notices. */
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);

    /* SIGHUP is rotation, not shutdown. Same struct, different handler. */
    sa.sa_handler = on_hangup;
    sigaction(SIGHUP, &sa, NULL);

    /* O_NOCTTY matters: without it, opening a tty from a process without a
     * controlling terminal (which is every systemd service) would make this
     * port our controlling terminal, and a hangup on the wire would then
     * deliver SIGHUP to us. */
    serial_fd = open(device, O_RDWR | O_NOCTTY);
    if (serial_fd < 0) {
        fprintf(stderr, "cannot open %s: %s\n", device, strerror(errno));
        return 1;
    }

    if (configure_port(serial_fd, speed) != 0) {
        fprintf(stderr, "cannot configure %s: %s\n", device, strerror(errno));
        close(serial_fd);
        return 1;
    }

    /* Log file name carries the device, so two adapters logging at once
     * cannot collide — the old single-instance design could not do this. */
    devname = strrchr(device, '/');
    devname = devname ? devname + 1 : device;

    /* Baseline for the clock correction (point 5 at the top). Taken BEFORE
     * the file is opened, so "how long have I been running" is never an
     * underestimate. CLOCK_MONOTONIC cannot be stepped, which is the whole
     * reason this works. */
    mono_start = monotonic_ms();

    max_file_bytes  = env_bytes("LOGGER_MAX_FILE_BYTES",  DEFAULT_MAX_FILE_BYTES);
    max_total_bytes = env_bytes("LOGGER_MAX_TOTAL_BYTES", DEFAULT_MAX_TOTAL_BYTES);

    /* One level is enough: /var/log exists, we only add the last component.
     * EEXIST is the normal case on every boot after the first. */
    if (mkdir(logdir, 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, "cannot create %s: %s\n", logdir, strerror(errno));
        close(serial_fd);
        return 1;
    }

    log_fd = open_log(logdir, devname, stamp, sizeof(stamp),
                      path, sizeof(path));
    if (log_fd < 0) {
        fprintf(stderr, "cannot open a log in %s: %s\n", logdir, strerror(errno));
        close(serial_fd);
        return 1;
    }

    /* Make room before writing, not after filling the disk. */
    prune_old_logs(logdir, devname, path, max_total_bytes);

    fprintf(stderr, "logging %s at %ld baud to %s\n", device, baud, path);
    fprintf(stderr, "limits: %llu bytes/file, %llu bytes total (0 = unlimited)\n",
            max_file_bytes, max_total_bytes);

    /* The clock watch. Failing to create it is NOT fatal: the logger's job
     * is capturing bytes, and a wrong file name is worth far less than a
     * missed boot. We log it and carry on with a negative fd, which poll()
     * ignores. */
    clock_fd = timerfd_create(CLOCK_REALTIME, TFD_NONBLOCK | TFD_CLOEXEC);
    if (clock_fd < 0) {
        fprintf(stderr, "no clock watch (%s); file name will not self-correct\n",
                strerror(errno));
    } else if (clock_watch_arm(clock_fd) != 0) {
        fprintf(stderr, "cannot arm clock watch: %s\n", strerror(errno));
        close(clock_fd);
        clock_fd = -1;
    }

    pfds[0].fd     = serial_fd;
    pfds[0].events = POLLIN;
    pfds[1].fd     = clock_fd;    /* negative when unavailable; poll skips it */
    pfds[1].events = POLLIN;

    while (!stop_requested) {
        int ready;

        /* Rotation happens here, at the top, rather than inside the signal
         * handler -- a handler may only set a flag. Reached either from
         * SIGHUP or from the size cap below. */
        if (rotate_requested) {
            rotate_requested = 0;

            if (unsynced > 0)
                fsync(log_fd);
            close(log_fd);

            /* The file just closed is now an ordinary candidate for
             * pruning, so pass no keep_path. */
            prune_old_logs(logdir, devname, "", max_total_bytes);

            log_fd = open_log(logdir, devname, stamp, sizeof(stamp),
                              path, sizeof(path));
            if (log_fd < 0) {
                fprintf(stderr, "rotate: cannot open a new log: %s\n",
                        strerror(errno));
                break;
            }
            unsynced = 0;
            written  = 0;
            /* New file, new baseline: if the clock is still wrong, the
             * correction should fix THIS file's name, not the old one's. */
            mono_start = monotonic_ms();
            fprintf(stderr, "rotated to %s\n", path);
        }

        ready = poll(pfds, 2, FSYNC_IDLE_MS);

        if (ready < 0) {
            if (errno == EINTR)     /* a signal arrived; loop re-checks the flag */
                continue;
            fprintf(stderr, "poll failed: %s\n", strerror(errno));
            break;
        }

        if (ready == 0) {
            /* Quiet link. If anything is sitting in the page cache, this is
             * the cheapest possible moment to push it at the card. */
            if (unsynced > 0) {
                fsync(log_fd);
                unsynced = 0;
            }
            continue;
        }

        /* --- the wall clock was stepped (point 5 at the top) ------------ */
        if (clock_fd >= 0 && (pfds[1].revents & POLLIN)) {
            uint64_t ticks;
            ssize_t  r = read(clock_fd, &ticks, sizeof(ticks));

            /* ECANCELED is the signal we actually want: the kernel is
             * telling us the absolute deadline became meaningless because
             * CLOCK_REALTIME jumped. A successful read means the timer
             * merely expired, which we do not care about. */
            if (r < 0 && errno == ECANCELED) {
                long long elapsed_ms = monotonic_ms() - mono_start;
                time_t    true_start = time(NULL) - (time_t)(elapsed_ms / 1000);
                char      new_stamp[32];
                char      new_path[PATH_MAX];

                make_stamp(true_start, new_stamp, sizeof(new_stamp));

                if (strcmp(new_stamp, stamp) != 0) {
                    snprintf(new_path, sizeof(new_path),
                             "%s/session_%s_%s.log", logdir, devname, new_stamp);

                    if (access(new_path, F_OK) == 0) {
                        fprintf(stderr, "clock stepped, but %s exists; "
                                        "keeping %s\n", new_path, path);
                    } else if (rename(path, new_path) == 0) {
                        /* An open fd refers to the FILE, not to the name,
                         * so the rename is invisible to the writing we are
                         * doing: no reopen, no gap, not a byte lost. */
                        snprintf(path,  sizeof(path),  "%s", new_path);
                        snprintf(stamp, sizeof(stamp), "%s", new_stamp);
                        fprintf(stderr, "clock stepped; renamed log to %s\n",
                                path);
                    } else {
                        fprintf(stderr, "cannot rename %s -> %s: %s\n",
                                path, new_path, strerror(errno));
                    }
                }
            }

            /* Re-arm unconditionally, or we would only ever notice the
             * first step of the clock. */
            clock_watch_arm(clock_fd);
        }

        /* POLLHUP/POLLERR is how an unplug shows up. Exit cleanly and let
         * systemd's BindsTo= tear the unit down — no crash loop. */
        if (pfds[0].revents & (POLLHUP | POLLERR | POLLNVAL)) {
            fprintf(stderr, "%s disappeared\n", device);
            break;
        }

        if (pfds[0].revents & POLLIN) {
            char    buf[READ_CHUNK];
            ssize_t n = read(serial_fd, buf, sizeof(buf));

            if (n < 0) {
                if (errno == EINTR || errno == EAGAIN)
                    continue;
                /* EIO is what a yanked USB serial adapter usually gives. */
                fprintf(stderr, "read from %s failed: %s\n", device, strerror(errno));
                break;
            }
            if (n == 0)
                continue;           /* spurious wakeup; poll() again */

            /* write() may be partial — it is not an error, it just means
             * "I took this much". Loop until the buffer is gone. */
            {
                ssize_t off = 0;
                while (off < n) {
                    ssize_t w = write(log_fd, buf + off, (size_t)(n - off));
                    if (w < 0) {
                        if (errno == EINTR)
                            continue;
                        fprintf(stderr, "write to log failed: %s\n", strerror(errno));
                        goto done;
                    }
                    off += w;
                }
            }

            unsynced += (size_t)n;
            written  += (unsigned long long)n;

            if (unsynced >= FSYNC_BYTES) {
                fsync(log_fd);
                unsynced = 0;
            }

            /* Size cap. Handled by setting the same flag SIGHUP sets, so
             * there is exactly one rotation path to reason about. */
            if (max_file_bytes != 0 && written >= max_file_bytes)
                rotate_requested = 1;
        }
    }

done:
    if (unsynced > 0)
        fsync(log_fd);

    close(log_fd);
    close(serial_fd);
    if (clock_fd >= 0)
        close(clock_fd);

    fprintf(stderr, "stopped logging %s\n", device);
    return 0;
}
