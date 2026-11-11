#!/usr/bin/env python3
# tpu-exec: run bionic vendor binaries on the Arch host without poisoning it.
# Why: tools/tpu-tachyon-run exports LD_PRELOAD with /system/lib64 shims that
# now exist on the host (to run bionic binaries like tpu-compile directly).
# glibc then loads the bionic .so into every host child (sleep, pkill,
# chroot itself) and they all segfault. Here python starts with a clean env,
# does chroot(2) itself, and only the exec'd bionic target sees LD_PRELOAD.
# Usage:
#   tpu-exec.py daemon  NAME PATH [ARGS...]   start a service detached
#   tpu-exec.py run PATH [ARGS...]            run foreground, wait <=60s
# Env knobs: R, UID, GID, PRELOAD, LOG, plus any extra VARs passed through
# (HANDLE, TYPES, GFILE, ORDER2, UORDER, ...). LD_LIBRARY_PATH fixed below.
import os
import sys
import time

R = os.environ.get("R", "/usr/lib/omamobile-vendor/edgetpu/root")
LP = ("/apex/com.android.tethering/lib64:/system_ext/lib64:/vendor/lib64:"
      "/system/lib64:/apex/com.android.runtime/lib64/bionic")


def base_env():
    env = {"LD_LIBRARY_PATH": LP,
           "PATH": "/system/bin:/vendor/bin",
           "ANDROID_ROOT": "/system",
           "ANDROID_DATA": "/data"}
    if "PRELOAD" in os.environ:
        env["LD_PRELOAD"] = os.environ["PRELOAD"]
    # test knobs pass through into the chroot target
    for k, v in os.environ.items():
        if k in ("HANDLE", "FDH", "TYPE", "TYPES", "GFILE", "SFILE", "SSIZE",
                 "ORDER", "ORDER2", "UORDER", "LOC", "TAG", "BTYPE", "BIDX",
                 "BSIZE", "CH", "SH", "IH", "RH", "SAME", "SETUP", "SETUP_N",
                 "SETUP_ADDR", "STYPE", "CVER_MAJOR", "CVER_MINOR", "RUN_UID",
                 "TPU_VLOG", "DELEGATE_UID", "H2", "FDH2", "IVH", "CH", "H3", "FDH3", "J2"):
            env[k] = v
    return env


def child_exec(path, args, uid, gid, logpath, foreground):
    r = w = None
    if foreground:
        r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        try:
            os.setsid()
            if foreground:
                os.close(r)
                os.dup2(w, 1)
                os.dup2(w, 2)
                os.close(w)
            else:
                log = os.open(logpath,
                              os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
                os.dup2(log, 1)
                os.dup2(log, 2)
            nul = os.open("/dev/null", os.O_RDONLY)
            os.dup2(nul, 0)
            os.chroot(R)
            os.chdir("/")
            if gid is not None and gid >= 0:
                os.setgid(gid)
            if uid is not None and uid >= 0:
                os.setuid(uid)
            os.execve(path, [path] + args, base_env())
        except Exception as e:  # noqa: BLE001
            try:
                os.write(2, ("tpu-exec fail: %r\n" % (e,)).encode())
            except OSError:
                pass
        os._exit(127)
    if foreground:
        os.close(w)
        return pid, r
    return pid, None


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    if mode == "daemon":
        # daemon NAME PATH [ARGS...]
        name, path = argv[2], argv[3]
        args = argv[4:]
        uid = int(os.environ.get("TPU_UID", "0"))
        gid = int(os.environ.get("TPU_GID", str(uid)))
        log = os.environ.get("LOG", "/tmp/tpu-%s.log" % name)
        pid, _ = child_exec(path, args, uid, gid, log, False)
        time.sleep(0.3)
        # re-check: dead at once means exec failed; log has the reason
        done, status = os.waitpid(pid, os.WNOHANG)
        if done == pid:
            print("%s failed at once rc=%d (see %s)"
                  % (name, os.waitstatus_to_exitcode(status), log))
            return 1
        print("%s pid: %d" % (name, pid))
        return 0
    if mode == "run":
        # run PATH [ARGS...], foreground with 60s timeout
        path, args = argv[2], argv[3:]
        uid = int(os.environ.get("TPU_UID", "1000"))
        gid = int(os.environ.get("TPU_GID", str(uid)))
        pid, rfd = child_exec(path, args, uid, gid, "", True)
        os.set_blocking(rfd, False)
        limit = float(os.environ.get("TPU_TIMEOUT", "60"))
        deadline = time.time() + limit
        rc = None
        buf = b""
        while time.time() < deadline:
            try:
                chunk = os.read(rfd, 65536)
                if chunk:
                    buf += chunk
                elif chunk == b"":
                    pass
            except BlockingIOError:
                pass
            except OSError:
                pass
            done, status = os.waitpid(pid, os.WNOHANG)
            if done == pid:
                rc = os.waitstatus_to_exitcode(status)
                break
            time.sleep(0.2)
        # drain what is left
        try:
            while True:
                chunk = os.read(rfd, 65536)
                if not chunk:
                    break
                buf += chunk
        except OSError:
            pass
        os.close(rfd)
        if rc is None:
            try:
                os.kill(pid, 9)
            except OSError:
                pass
            _, status = os.waitpid(pid, 0)
            sys.stdout.write(buf.decode("utf-8", "replace"))
            sys.stdout.write("TIMEOUT after %.0fs, killed\n" % limit)
            return 124
        sys.stdout.write(buf.decode("utf-8", "replace"))
        sys.stdout.write("rc: %d\n" % rc)
        return 0 if rc == 0 else 1
    print("usage: tpu-exec.py daemon NAME PATH [ARGS] | run PATH [ARGS]")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
