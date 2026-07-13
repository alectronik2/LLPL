#!/bin/sh
# Automated, no-human-typing proof that VFS.llpl's filesystem survives a
# reboot: boot once against a *fresh* disk image (self-formats,
# VFS.selftest() creates /selftest/proof.txt and reports SELFTEST: PASS),
# then boot a *second* time against that *same* image (not recreated) and
# confirm selftest() finds /selftest/proof.txt still there
# (PERSISTENCE: PASS) instead of reporting a first-boot SKIP.
#
# Kept as a standalone script rather than a build.yaml pipeline step -
# this is a bespoke integration test (boot twice, grep serial-log output
# for specific markers), not a build-pipeline shape the generic
# YAML schema is meant to model (see tools/llplbuild's own design notes).
# It shells out to llplbuild for the actual build/ISO steps, matching
# exactly what the old Makefile's `test-persistence` target did.

set -e
cd "$(dirname "$0")"
LLPLBUILD=../../tools/llplbuild/llplbuild

rm -f disk.img /tmp/llpl_persistence_boot1.log /tmp/llpl_persistence_boot2.log
"$LLPLBUILD" build

echo "Boot 1 (fresh disk) ..."
timeout 10 qemu-system-x86_64 -cdrom kernel.iso -drive file=disk.img,format=raw,if=ide \
    -serial file:/tmp/llpl_persistence_boot1.log -display none -m 256 || true

if grep -q "PERSISTENCE: SKIP (first boot)" /tmp/llpl_persistence_boot1.log; then
    echo "  boot 1: PERSISTENCE: SKIP (first boot) - expected"
else
    echo "  boot 1: FAILED - expected a first-boot SKIP"
    cat /tmp/llpl_persistence_boot1.log
    exit 1
fi

if grep -q "SELFTEST: PASS" /tmp/llpl_persistence_boot1.log; then
    echo "  boot 1: SELFTEST: PASS"
else
    echo "  boot 1: FAILED - SELFTEST did not pass"
    cat /tmp/llpl_persistence_boot1.log
    exit 1
fi

echo "Boot 2 (same disk image) ..."
timeout 10 qemu-system-x86_64 -cdrom kernel.iso -drive file=disk.img,format=raw,if=ide \
    -serial file:/tmp/llpl_persistence_boot2.log -display none -m 256 || true

if grep -q "PERSISTENCE: PASS" /tmp/llpl_persistence_boot2.log; then
    echo "  boot 2: PERSISTENCE: PASS - proof.txt survived the reboot"
else
    echo "  boot 2: FAILED - proof.txt did not survive"
    cat /tmp/llpl_persistence_boot2.log
    exit 1
fi

if grep -q "SELFTEST: PASS" /tmp/llpl_persistence_boot2.log; then
    echo "  boot 2: SELFTEST: PASS"
else
    echo "  boot 2: FAILED - SELFTEST did not pass"
    cat /tmp/llpl_persistence_boot2.log
    exit 1
fi

echo "test-persistence: ALL PASS"
