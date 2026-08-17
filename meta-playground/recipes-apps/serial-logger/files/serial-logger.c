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
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>     /* PATH_MAX */
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
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

/* Set by the signal handler; checked by the main loop. sig_atomic_t is the
 * only type the C standard promises can be written by a handler and read by
 * the main flow without tearing. volatile stops the compiler caching it in
 * a register across the loop. */
static volatile sig_atomic_t stop_requested = 0;

static void on_signal(int signo)
{
    (void)signo;
    stop_requested = 1;
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

int main(int argc, char **argv)
{
    const char *device, *logdir;
    long        baud;
    speed_t     speed;
    char        path[PATH_MAX];
    char        stamp[32];
    const char *devname;
    struct tm   tm_now;
    time_t      now;
    int         serial_fd, log_fd;
    size_t      unsynced = 0;
    struct sigaction sa;
    struct pollfd pfd;

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
     * cannot collide — the old single-instance design could not do this.
     *
     * CAVEAT worth knowing on this board: a Pi has no battery-backed RTC.
     * Until systemd-timesyncd talks to an NTP server, the clock is whatever
     * it was restored to from /var/lib/systemd/timesync/clock — roughly the
     * last shutdown time, not the truth. Early-boot log names can therefore
     * be wrong by however long the box was off. Correct answer if that ever
     * matters is a real RTC; this is just a note so it isn't a surprise. */
    devname = strrchr(device, '/');
    devname = devname ? devname + 1 : device;

    now = time(NULL);
    localtime_r(&now, &tm_now);
    strftime(stamp, sizeof(stamp), "%Y-%m-%d_%H-%M-%S", &tm_now);

    /* One level is enough: /var/log exists, we only add the last component.
     * EEXIST is the normal case on every boot after the first. */
    if (mkdir(logdir, 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, "cannot create %s: %s\n", logdir, strerror(errno));
        close(serial_fd);
        return 1;
    }

    snprintf(path, sizeof(path), "%s/session_%s_%s.log", logdir, devname, stamp);

    log_fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (log_fd < 0) {
        fprintf(stderr, "cannot open %s: %s\n", path, strerror(errno));
        close(serial_fd);
        return 1;
    }

    fprintf(stderr, "logging %s at %ld baud to %s\n", device, baud, path);

    pfd.fd     = serial_fd;
    pfd.events = POLLIN;

    while (!stop_requested) {
        int ready = poll(&pfd, 1, FSYNC_IDLE_MS);

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

        /* POLLHUP/POLLERR is how an unplug shows up. Exit cleanly and let
         * systemd's BindsTo= tear the unit down — no crash loop. */
        if (pfd.revents & (POLLHUP | POLLERR | POLLNVAL)) {
            fprintf(stderr, "%s disappeared\n", device);
            break;
        }

        if (pfd.revents & POLLIN) {
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
            if (unsynced >= FSYNC_BYTES) {
                fsync(log_fd);
                unsynced = 0;
            }
        }
    }

done:
    if (unsynced > 0)
        fsync(log_fd);

    close(log_fd);
    close(serial_fd);

    fprintf(stderr, "stopped logging %s\n", device);
    return 0;
}
