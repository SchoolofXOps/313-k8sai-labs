#!/usr/bin/env python3
"""spike-02 four-path storage probe.

ONE implementation measures all four paths. Invoked inside a client Pod as:

    python3 /probe/probe.py fs   <target-dir> <size-mb> <tag>
    python3 /probe/probe.py s3   <endpoint>   <size-mb> <tag> <bucket>

Emits exactly one JSON object on stdout. Every duration is time.monotonic
(a monotonic clock, immune to NTP steps mid-measurement); every throughput is
bytes actually transferred divided by the measured elapsed time, never a
nominal size divided by a time.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

MIB = 1024 * 1024
CHUNK = 8 * MIB
# The payload source. Deliberately a tmpfs (emptyDir medium: Memory) file, so
# that reading the source during a timed write costs RAM speed and the write
# figure is dominated by the TARGET path, not by the source.
SRC = "/payload/payload.bin"

# A constant byte buffer, which is 304's `head -c N /dev/zero | tr '\0' 'x'`
# payload pattern expressed in-process: identical generation cost for every
# path, and never random data (a random generator's cost would land inside the
# comparison and would differ run to run).
FILLER = b"x" * CHUNK


def ensure_source(size_mb):
    """Generate the payload once per probe invocation, OUTSIDE every timed
    region, and report how long it took so the cost is visible rather than
    merely excluded."""
    want = size_mb * MIB
    t0 = time.monotonic()
    os.makedirs(os.path.dirname(SRC), exist_ok=True)
    if os.path.exists(SRC) and os.path.getsize(SRC) == want:
        return {"generated": False, "seconds": 0.0, "bytes": want}
    with open(SRC, "wb") as f:
        left = want
        while left > 0:
            n = CHUNK if left > CHUNK else left
            f.write(FILLER[:n])
            left -= n
        f.flush()
        os.fsync(f.fileno())
    return {"generated": True, "seconds": time.monotonic() - t0, "bytes": want}


def evict(path):
    """Drop this file's clean page-cache pages.

    POSIX_FADV_DONTNEED needs no privilege, unlike /proc/sys/vm/drop_caches
    which is not writable from inside a Pod. It is advisory: the kernel drops
    clean pages it can, which after an fsync is all of them. Returns the
    mechanism name, or the reason it was unavailable — never silently nothing.
    """
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError as exc:
        return "unavailable: open failed: %s" % exc
    try:
        os.fsync(fd)
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        return "posix_fadvise(POSIX_FADV_DONTNEED) after fsync"
    except (AttributeError, OSError) as exc:
        return "unavailable: %s" % exc
    finally:
        os.close(fd)


def measure_fs(target_dir, size_mb, tag):
    dst = os.path.join(target_dir, "payload-%s.bin" % tag)
    out = {"target": dst}

    # --- sequential write, fsync INSIDE the timed region ---------------------
    wrote = 0
    t0 = time.monotonic()
    with open(SRC, "rb") as fin, open(dst, "wb") as fout:
        while True:
            buf = fin.read(CHUNK)
            if not buf:
                break
            fout.write(buf)
            wrote += len(buf)
        fout.flush()
        os.fsync(fout.fileno())
    out["write_seconds"] = time.monotonic() - t0
    out["write_bytes"] = wrote

    # --- first-byte latency: open(2) + the first read, on a cold file --------
    out["evict_mechanism"] = evict(dst)
    t0 = time.monotonic()
    fd = os.open(dst, os.O_RDONLY)
    got = os.read(fd, 1)
    out["first_byte_seconds"] = time.monotonic() - t0
    os.close(fd)
    out["first_byte_bytes"] = len(got)

    # --- sequential read, from a cold file again -----------------------------
    evict(dst)
    read = 0
    t0 = time.monotonic()
    with open(dst, "rb") as f:
        while True:
            buf = f.read(CHUNK)
            if not buf:
                break
            read += len(buf)
    out["read_seconds"] = time.monotonic() - t0
    out["read_bytes"] = read

    os.remove(dst)
    return out


class _CountingReader(object):
    """Pass-through file wrapper that counts the bytes actually read out of it.

    urllib streams a file-like `data` by calling read(); wrapping it is the
    only way to learn how many bytes really went to the socket, as opposed to
    how many were intended to.
    """

    def __init__(self, f):
        self.f = f
        self.n = 0

    def read(self, k=-1):
        b = self.f.read(k)
        self.n += len(b)
        return b


def _put(url, body, length):
    req = urllib.request.Request(url, method="PUT", data=body)
    req.add_header("Content-Length", str(length))
    req.add_header("Content-Type", "application/octet-stream")
    return urllib.request.urlopen(req, timeout=900)


def measure_s3(endpoint, size_mb, tag, bucket):
    key = "payload-%s.bin" % tag
    obj = "%s/%s/%s" % (endpoint.rstrip("/"), bucket, key)
    out = {"target": obj}

    # Bucket create, UNTIMED and retried: a one-off control-plane call, not
    # part of the data path being compared. Retried because `weed server -s3`
    # opens its S3 port before its filer and volume server have registered
    # with the master, so the TCP readiness probe can go green a second or two
    # before the first object write would actually succeed. Waiting here keeps
    # that startup race out of the measured write.
    deadline = time.monotonic() + 120.0
    out["bucket_note"] = "not created"
    while time.monotonic() < deadline:
        try:
            _put("%s/%s" % (endpoint.rstrip("/"), bucket), b"", 0).read()
            out["bucket_note"] = "created or already present"
            break
        except urllib.error.HTTPError as exc:
            # 409 only: urlopen raises HTTPError for status >= 400, so a 200
            # could never be seen here (IN-04).
            if exc.code in (409,):
                out["bucket_note"] = "already present (HTTP %s)" % exc.code
                break
            out["bucket_note"] = "PUT bucket -> HTTP %s" % exc.code
            time.sleep(2)
        except Exception as exc:                   # noqa: BLE001 - retried, then reported
            out["bucket_note"] = "PUT bucket -> %s" % exc
            time.sleep(2)

    nbytes = size_mb * MIB

    # --- sequential write: one streaming PUT, timed to the response ---------
    # write_bytes is COUNTED, not assumed. The docstring above promises "every
    # throughput is bytes actually transferred divided by the measured elapsed
    # time, never a nominal size divided by a time", and the fs paths keep that
    # promise by accumulating len(buf). This path used to set
    # write_bytes = size_mb * MIB — exactly the nominal figure the docstring
    # forbids — so a 2xx short write would have published full-size
    # throughput. CountingReader wraps the file object urlopen streams from, so
    # the number reported is the number of bytes handed to the socket.
    with open(SRC, "rb") as raw:
        body = _CountingReader(raw)
        t0 = time.monotonic()
        resp = _put(obj, body, nbytes)
        resp.read()
        out["write_seconds"] = time.monotonic() - t0
        out["write_status"] = resp.status
        out["write_bytes"] = body.n
    # write_status was captured and never asserted. A non-2xx here is not a
    # measurement, it is a failure, and urlopen only raises for >= 400 — so a
    # 3xx would otherwise have been reported as a successful write.
    if resp.status // 100 != 2:
        raise RuntimeError("PUT %s returned HTTP %s" % (obj, resp.status))
    if out["write_bytes"] != nbytes:
        raise RuntimeError(
            "short write to %s: sent %d bytes, expected %d"
            % (obj, out["write_bytes"], nbytes))

    # --- first-byte latency: TCP connect + request + first body byte --------
    # Not evictable from here: the object store's own page cache lives in
    # another Pod. Stated in harness-config.md rather than papered over.
    out["evict_mechanism"] = "not available to the client (server-side cache)"
    t0 = time.monotonic()
    resp = urllib.request.urlopen(obj, timeout=900)
    got = resp.read(1)
    out["first_byte_seconds"] = time.monotonic() - t0
    resp.close()
    out["first_byte_bytes"] = len(got)

    # --- sequential read: one GET drained to EOF ----------------------------
    t0 = time.monotonic()
    resp = urllib.request.urlopen(obj, timeout=900)
    read = 0
    while True:
        buf = resp.read(CHUNK)
        if not buf:
            break
        read += len(buf)
    out["read_seconds"] = time.monotonic() - t0
    out["read_bytes"] = read
    resp.close()

    try:
        urllib.request.urlopen(
            urllib.request.Request(obj, method="DELETE"), timeout=120).read()
    except urllib.error.HTTPError:
        pass
    return out


def main():
    kind = sys.argv[1]
    target = sys.argv[2]
    size_mb = int(sys.argv[3])
    tag = sys.argv[4]
    result = {"kind": kind, "size_mb": size_mb, "tag": tag,
              "chunk_bytes": CHUNK, "clock": "time.monotonic"}
    try:
        result["payload"] = ensure_source(size_mb)
        if kind == "fs":
            result.update(measure_fs(target, size_mb, tag))
        elif kind == "s3":
            result.update(measure_s3(target, size_mb, tag, sys.argv[5]))
        else:
            raise SystemExit("unknown probe kind: %s" % kind)
        result["ok"] = True
    except Exception as exc:                       # noqa: BLE001 - reported, not swallowed
        result["ok"] = False
        result["error"] = "%s: %s" % (type(exc).__name__, exc)
    finally:
        # Free the 256 MiB tmpfs payload immediately: it is charged to the
        # Pod's memory cgroup, and only one client should ever hold one.
        try:
            os.remove(SRC)
        except OSError:
            pass
    print(json.dumps(result))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
