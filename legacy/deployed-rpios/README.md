# The deployed system this project replaces

Recovered from the Raspberry Pi OS SD card that ran in the Pi Zero W before
the Yocto image existed, immediately before that card was reflashed
(2026-08-25). It should have been saved in session 19, when `notes/19` was
written *about* these files — keeping the critique and discarding the subject
is not much of a record.

Nothing here is built, installed or referenced by any recipe. It is kept as
the "before" half of the capstone, so the comparison in `notes/19` and
`notes/20` can be checked against the real artifact rather than against
quoted fragments.

## What it is

A Python serial logger and a hand-written systemd unit, both created by hand
on a running Raspberry Pi OS box and existing nowhere else — which is
precisely the problem the rest of this repository exists to solve.

## What was wrong with it, in one place

Measured and argued in `notes/19`; summarised here so the files are not
mistaken for a working reference:

  - **100% of a core while idle.** `readline()` already blocks for
    `timeout=1`; the `in_waiting` guard turns a blocking read into a spin
    loop. 5.0 s idle cost 5.0000 s of CPU, against 0.0009 s for the C
    replacement — on a single-core board, the entire machine.
  - **`flush()` is not `fsync()`.** The comment claimed data was safe from a
    power cut. It reached the page cache, not the card.
  - **`After=network.target`** on a unit that reads a USB device and never
    opens a socket, ordering it behind a 43-second NetworkManager wait.
  - **`/dev/ttyUSB0` hardcoded** inside the script, so a CDC-ACM device — a
    Pico Debugprobe on `/dev/ttyACM0` — was invisible to it. The Yocto
    replacement matches on USB *ancestry* in a udev rule instead, and that is
    the device it was first proven with.
  - **`Restart=always`** with no device dependency, so an absent adapter
    produced an infinite crash loop writing an error line to the SD card on
    every lap. `BindsTo=dev-%i.device` replaces it.

Two further details, visible only now the files are here rather than quoted:

  - **Logs went to `/home/blankmcu/logs`**, not `/var/log`. The captures lived
    in a user's home directory, which is why nothing about the deployment was
    reproducible — the data and the program were both in the same
    hand-made place.
  - **`User=blankmcu`**, so it ran unprivileged and depended on that account
    being in `dialout`. The Yocto replacement runs as root for want of an
    unprivileged user on the image, which is a regression the unit's own
    comments admit to and propose fixing with `useradd.bbclass`.

The error path is worth reading next to `Restart=always`: any exception —
including the USB adapter being unplugged — appends a line to `error.log` and
exits 1, whereupon systemd restarts it three seconds later to do the same
thing again, forever, writing to the SD card each lap.

The replacement is `meta-playground/recipes-apps/serial-logger`.
