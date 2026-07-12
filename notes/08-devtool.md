# Session 3c — devtool: edit, deploy to live target, capture

Phase 3 complete. The exercise: add a command-line greeting to hello,
test it ON THE RUNNING PI without reflashing, then land the change back
in the layer.

## The circuit

```bash
devtool modify hello        # extract sources into build-rpi5/workspace/
                            #   (workspace = a real, auto-registered layer;
                            #    sources under git, pristine state = base commit;
                            #    builds now come from this checkout)
# edit workspace/sources/hello/hello.c
devtool build hello
devtool deploy-target hello root@10.42.0.174
                            # copies the recipe's ${D} tree onto the live
                            # target over SSH; manifest kept on target so
                            # undeploy-target can cleanly remove it
devtool finish hello meta-playground
                            # diff vs base commit -> write back to layer,
                            # dissolve workspace, park sources in attic/
```

Result on target, no reflash: `hello blankmcu` → "Greetings, blankmcu!"

## Lessons & gotchas

- **deploy-target is a dev-time illusion**: the SD card no longer matches
  any built image; the *recipe* is still the truth. finish + rebuild image
  makes it real. Only the recipe's own files deploy — new library deps
  wouldn't ride along.
- **finish refused: "Source tree is not clean: ?? hello"** — our recipe
  compiles in-tree (B = S under devtool), so the built binary landed next
  to the sources as an untracked file. Fix: `rm hello` (and commit any
  source edits — finish captures COMMITTED state; commit messages become
  patch descriptions for upstream-style recipes). Don't reflex to -f.
- **Capture format depends on the source type**: file:// from our own
  layer → files/hello.c overwritten in place. Upstream tarball/git →
  .patch files appended to SRC_URI (dropbear's CVE-*.patch files are
  exactly this). Finishing into a layer that DOESN'T own the recipe →
  .bbappend + patches there (the standard way to carry local mods to
  other people's recipes, poky untouched).
- workspace/sources/<pn>/ extras: oe-workdir & oe-logs are symlinks into
  tmp/work/.../<pn>/<pv>/ (same temp/ logs as notes/07); attic/ holds
  retired source trees, delete at will.

## Why this matters for the capstone

Iteration loop on the Pi Zero W logger becomes: edit → devtool build →
deploy-target → test, seconds per cycle, no SD card shuffle. Reflash only
when the change is finished into the layer.
