"""Internal Linux drawing byte pipeline. No API, DB, queue or object-store calls.

An immutable sealed memfd is the only source handed to parsers. Inputs are read
relative to an already-open trusted directory fd; names are one component. The
caller retains its original file on success and every failure. Run only in the
dedicated isolated worker image, never with backend secrets mounted/inherited.
"""
from dataclasses import dataclass
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

MIB = 1024 * 1024
MAX_OUTPUT = 256 * MIB
MAX_LOG = 16 * 1024
MAX_METADATA = MIB
PROFILE_VERSION = "drawing-linux-byte-v1"


class ProcessingError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


@dataclass(frozen=True)
class Allocation:
    sha256: str
    byte_count: int
    mime: str

    def validate(self):
        if not isinstance(self.mime,str) or not isinstance(self.sha256,str):
            raise ProcessingError("source_allocation_invalid")
        limit = {"application/pdf": 50 * MIB, "image/jpeg": 10 * MIB, "image/png": 10 * MIB}.get(self.mime)
        if limit is None or type(self.byte_count) is not int or not 0 < self.byte_count <= limit:
            raise ProcessingError("source_allocation_invalid")
        if not re.fullmatch("[0-9a-f]{64}", self.sha256):
            raise ProcessingError("source_allocation_invalid")


class VerifiedSource:
    def __init__(self, fd, allocation):
        self.fd, self.allocation = fd, allocation

    def close(self):
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def _identity(st):
    return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns


def verify_source(directory_fd, name, allocation):
    allocation.validate()
    if not isinstance(name, str) or name in ("", ".", "..") or "/" in name or "\0" in name:
        raise ProcessingError("source_path_invalid")
    original_fd = sealed_fd = -1
    try:
        # NONBLOCK avoids waiting on a FIFO before fstat rejects its type.
        original_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory_fd)
        before = os.fstat(original_fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size != allocation.byte_count:
            raise ProcessingError("source_size_or_type_invalid")
        sealed_fd = os.memfd_create("snaglist-drawing", os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
        digest, count, prefix, tail = hashlib.sha256(), 0, b"", b""
        while True:
            chunk = os.read(original_fd, min(65536, allocation.byte_count + 1 - count))
            if not chunk:
                break
            count += len(chunk)
            if count > allocation.byte_count:
                raise ProcessingError("source_size_or_type_invalid")
            digest.update(chunk)
            prefix = (prefix + chunk)[:16]
            tail = (tail + chunk)[-1024:]
            view = memoryview(chunk)
            while view:
                written = os.write(sealed_fd, view)
                view = view[written:]
        if _identity(before) != _identity(os.fstat(original_fd)):
            raise ProcessingError("source_changed")
        if count != allocation.byte_count or digest.hexdigest() != allocation.sha256:
            raise ProcessingError("source_identity_mismatch")
        valid = ((allocation.mime == "image/png" and prefix.startswith(b"\x89PNG\r\n\x1a\n")) or
                 (allocation.mime == "image/jpeg" and prefix.startswith(b"\xff\xd8\xff") and tail.endswith(b"\xff\xd9")) or
                 (allocation.mime == "application/pdf" and re.match(rb"%PDF-(?:1\.[0-7]|2\.0)[\r\n ]", prefix)
                  and tail.rstrip(b"\x00\t\r\n ").endswith(b"%%EOF")))
        if not valid:
            raise ProcessingError("source_signature_invalid")
        seals = fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
        fcntl.fcntl(sealed_fd, fcntl.F_ADD_SEALS, seals)
        if fcntl.fcntl(sealed_fd, fcntl.F_GET_SEALS) != seals:
            raise ProcessingError("source_sealing_failed")
        os.lseek(sealed_fd, 0, os.SEEK_SET)
        result = VerifiedSource(sealed_fd, allocation)
        sealed_fd = -1
        return result
    except OSError:
        raise ProcessingError("source_access_failed") from None
    finally:
        for fd in (original_fd, sealed_fd):
            if fd >= 0:
                os.close(fd)


def open_private_directory(path):
    """Open every absolute path component without following symlinks."""
    path = os.fspath(path)
    if not path.startswith("/") or any(p in (".", "..") for p in path.split("/")):
        raise ProcessingError("workspace_invalid")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for part in filter(None, path.split("/")):
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        st = os.fstat(fd)
        if st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
            raise ProcessingError("workspace_invalid")
        return fd
    except Exception:
        os.close(fd)
        raise


def bounded_run(command, pass_fds=(), cwd=None, timeout=120, output_limit=MAX_OUTPUT):
    """Drain bounded diagnostic pipes while running; kill the entire process group."""
    if not command or not os.path.isabs(command[0]):
        raise ProcessingError("processor_configuration_invalid")
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               close_fds=True, pass_fds=pass_fds, start_new_session=True, cwd=cwd,
                               env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"})
    streams, total, deadline = selectors.DefaultSelector(), 0, time.monotonic() + timeout
    try:
        for stream in (process.stdout, process.stderr):
            os.set_blocking(stream.fileno(), False)
            streams.register(stream, selectors.EVENT_READ)
        while streams.get_map() or process.poll() is None:
            if time.monotonic() >= deadline:
                raise ProcessingError("processor_timeout")
            if cwd:
                entries = list(os.scandir(cwd))
                if len(entries) > 202 or sum(entry.stat(follow_symlinks=False).st_size for entry in entries) > output_limit:
                    raise ProcessingError("processor_output_limit")
            for key, _ in streams.select(min(0.05, max(0, deadline - time.monotonic()))):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if chunk:
                    total += len(chunk)
                    if total > MAX_LOG:
                        raise ProcessingError("processor_log_limit")
                else:
                    streams.unregister(key.fileobj)
        status=process.wait()
        if status != 0:
            raise ProcessingError({66:"unsupported_pdf_filter",67:"pdf_parse_failed",68:"pdf_geometry_unsupported",
                                   69:"pdf_render_failed",70:"source_descriptor_invalid",71:"page_encoding_failed"}.get(status,"processor_rejected"))
    finally:
        # Also kill descendants retaining a pipe or still running after parent exit.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
        streams.close()
        process.stdout.close()
        process.stderr.close()


def _read_regular(dir_fd, name, limit):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=dir_fd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or not 0 < st.st_size <= limit:
            raise ProcessingError("processor_output_invalid")
        chunks, count = [], 0
        while True:
            chunk = os.read(fd, min(65536, limit + 1 - count))
            if not chunk:
                break
            chunks.append(chunk)
            count += len(chunk)
            if count > limit:
                raise ProcessingError("processor_output_invalid")
        if _identity(st) != _identity(os.fstat(fd)):
            raise ProcessingError("processor_output_invalid")
        return b"".join(chunks)
    finally:
        os.close(fd)


def _reject_constant(_):
    raise ProcessingError("processor_output_invalid")


def _object_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProcessingError("processor_output_invalid")
        result[key] = value
    return result


def jpeg_dimensions(data):
    """Bounded JPEG marker validation; full byte decoding occurs in fixture tests.

    Admit only our baseline RGB encoder output and reject EXIF/ICC/comment payloads.
    Dimensions are read from actual encoded bytes, not trusted from child JSON.
    """
    if not data.startswith(b"\xff\xd8") or not data.endswith(b"\xff\xd9"):
        raise ValueError()
    offset,dimensions=2,None
    while offset+4 <= len(data):
        if data[offset]!=255: raise ValueError()
        while offset < len(data) and data[offset]==255: offset+=1
        if offset>=len(data): raise ValueError()
        marker=data[offset]; offset+=1
        if marker in (0,0xd8,0xd9) or 0xd0<=marker<=0xd7: raise ValueError()
        length=int.from_bytes(data[offset:offset+2],"big")
        if length<2 or offset+length>len(data): raise ValueError()
        payload=data[offset+2:offset+length]
        if marker==0xc0:
            if dimensions is not None or len(payload)!=15 or payload[0]!=8 or payload[5]!=3: raise ValueError()
            height,width=int.from_bytes(payload[1:3],"big"),int.from_bytes(payload[3:5],"big")
            if not 1<=width<=4096 or not 1<=height<=4096: raise ValueError()
            dimensions=(width,height)
        elif marker==0xe0:
            if len(payload)!=14 or not payload.startswith(b"JFIF\0") or payload[-2:]!=b"\0\0": raise ValueError()
        elif marker not in (0xc4,0xdb,0xdd,0xda):
            raise ValueError()
        if marker==0xda:
            if dimensions is None: raise ValueError()
            return dimensions
        offset+=length
    raise ValueError()


def validate_geometry(g, mime):
    """Same source→normalised convention as committed DrawingGeometryValidation."""
    def number(x):
        return type(x) in (int, float) and math.isfinite(x)
    if set(g) != {"mediaBox", "cropBox", "displayBox", "rotation", "userUnit", "width", "height", "sourceToDisplay", "coordinateSystem"}:
        raise ValueError()
    for key in ("mediaBox", "cropBox", "displayBox"):
        box = g[key]
        if set(box) != {"x", "y", "width", "height"} or not all(number(x) for x in box.values()):
            raise ValueError()
        if min(box["width"], box["height"]) <= 0 or not all(number(box[a]+box[b]) and box[a]+box[b] > box[a] for a,b in (("x","width"),("y","height"))):
            raise ValueError()
    b, m, c = g["displayBox"], g["mediaBox"], g["cropBox"]
    x,y,w,h = (b[k] for k in ("x","y","width","height"))
    rotation = g["rotation"]
    if type(rotation) is not int or rotation not in (0,90,180,270) or not number(g["userUnit"]) or not 0 < g["userUnit"] <= 75000:
        raise ValueError()
    if any(type(g[k]) is not int or not 1 <= g[k] <= 4096 for k in ("width","height")) or g["width"]*g["height"] > 40_000_000:
        raise ValueError()
    if mime == "application/pdf":
        left, bottom = max(m["x"],c["x"]), max(m["y"],c["y"])
        right, top = min(m["x"]+m["width"],c["x"]+c["width"]), min(m["y"]+m["height"],c["y"]+c["height"])
        sw,sh = right-left,top-bottom
        if min(sw,sh) <= 0 or any(abs(v)>1e-10 for v in ((x-left)/sw,(y-bottom)/sh,w/sw-1,h/sh-1)):
            raise ValueError()
        expected = {0:[1/w,0,0,-1/h,-x/w,1+y/h],90:[0,1/w,1/h,0,-y/h,-x/w],
                    180:[-1/w,0,0,1/h,1+x/w,-y/h],270:[0,-1/w,-1/h,0,1+y/h,1+x/w]}[rotation]
    else:
        if rotation != 0 or g["userUnit"] != 1 or not m == c == b or x != 0 or y != 0 or int(w) != w or int(h) != h:
            raise ValueError()
        expected = [1/w,0,0,1/h,0,0]
    t = g["sourceToDisplay"]
    if not isinstance(t,list) or len(t) != 6 or not all(number(v) for v in t) or g["coordinateSystem"] != "display_top_left_v1":
        raise ValueError()
    if any(abs((a-b)*scale)>1e-10 for a,b,scale in zip(t,expected,(w,w,h,h,1,1))):
        raise ValueError()
    determinant=t[0]*t[3]-t[1]*t[2]
    if not math.isfinite(determinant) or determinant==0: raise ValueError()
    if mime=="application/pdf":
        corners={0:((0,1),(1,1),(1,0),(0,0)),90:((0,0),(0,1),(1,1),(1,0)),
                 180:((1,0),(0,0),(0,1),(1,1)),270:((1,1),(1,0),(0,0),(0,1))}[rotation]
    else:
        corners=((0,0),(1,0),(1,1),(0,1))
    for point,corner in zip(((x,y),(x+w,y),(x+w,y+h),(x,y+h)),corners):
        px,py=t[0]*point[0]+t[2]*point[1]+t[4],t[1]*point[0]+t[3]*point[1]+t[5]
        if not math.isfinite(px) or not math.isfinite(py) or abs(px-corner[0])>1e-7 or abs(py-corner[1])>1e-7:
            raise ValueError()
    aspect = h/w if rotation in (90,270) else w/h
    if not math.isfinite(aspect) or aspect<=0 or abs(g["width"]-g["height"]*aspect) > max(1,aspect)+1e-10:
        raise ValueError()


def collect_manifest(output_fd, allocation, profile):
    try:
        metadata = json.loads(_read_regular(output_fd,"pages.json",MAX_METADATA), parse_constant=_reject_constant, object_pairs_hook=_object_pairs)
        if set(metadata) != {"pages"} or not isinstance(metadata["pages"],list) or not 1 <= len(metadata["pages"]) <= 100:
            raise ValueError()
        if allocation.mime != "application/pdf" and len(metadata["pages"]) != 1:
            raise ValueError()
        pages, total, names = [], 0, {"pages.json"}
        for index, page in enumerate(metadata["pages"]):
            if set(page) != {"sourcePageIndex","sourcePageLabel","geometry","thumbnailWidth","thumbnailHeight"}:
                raise ValueError()
            if type(page["sourcePageIndex"]) is not int or page["sourcePageIndex"] != index or page["sourcePageLabel"] != str(index+1):
                raise ValueError()
            validate_geometry(page["geometry"],allocation.mime)
            if any(type(page[k]) is not int or not 1 <= page[k] <= 512 for k in ("thumbnailWidth","thumbnailHeight")):
                raise ValueError()
            result = {k:page[k] for k in ("sourcePageIndex","sourcePageLabel","geometry")}
            for prefix,label in (("page","rendition"),("thumb","thumbnail")):
                name = f"{prefix}-{index:04d}.jpg"
                data = _read_regular(output_fd,name,10*MIB)
                actual=jpeg_dimensions(data)
                expected=(page["geometry"]["width"],page["geometry"]["height"]) if label=="rendition" else (page["thumbnailWidth"],page["thumbnailHeight"])
                if actual != expected:
                    raise ValueError()
                result[label+"SHA256"] = hashlib.sha256(data).hexdigest()
                result[label+"Bytes"] = len(data)
                total += len(data)
                names.add(name)
            pages.append(result)
        if total > MAX_OUTPUT or set(os.listdir(output_fd)) != names:
            raise ValueError()
        return {"sourceSHA256":allocation.sha256,"sourceBytes":allocation.byte_count,"sourceMIME":allocation.mime,
                "processorProfile":profile,"pages":pages}
    except (OSError, ValueError, TypeError, KeyError, OverflowError, ZeroDivisionError):
        raise ProcessingError("processor_output_invalid") from None


def runtime_profile(processor_root):
    raw = (Path(processor_root)/"runtime-profile.json").read_bytes()
    data = json.loads(raw)
    if data.get("profileVersion") != PROFILE_VERSION or not isinstance(data.get("files"),dict):
        raise ProcessingError("processor_profile_invalid")
    for path, expected in data["files"].items():
        if not os.path.isabs(path) or hashlib.sha256(Path(path).read_bytes()).hexdigest() != expected:
            raise ProcessingError("processor_profile_mismatch")
    return PROFILE_VERSION + ":" + hashlib.sha256(raw).hexdigest()


def process_file(input_dir_fd, name, allocation, workspace, processor_root, *, timeout=120):
    """Return verified fixed-file artefacts. Caller persists them before cleanup.

    No DRA-01 readiness call: the profile must first be negotiated and immutable
    originals/renditions persisted by the separately authorised storage worker.
    """
    profile = runtime_profile(processor_root)
    root_fd = open_private_directory(workspace)
    job_name, output_fd = "job-"+os.urandom(16).hex(), -1
    try:
        with verify_source(input_dir_fd,name,allocation) as source:
            os.mkdir(job_name,0o700,dir_fd=root_fd)
            output_fd = os.open(job_name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC,dir_fd=root_fd)
            # fd-derived paths remain bound to these directories even if an ancestor is renamed.
            output_path = f"/proc/self/fd/{output_fd}"
            if allocation.mime == "application/pdf":
                command = [str(Path(processor_root)/"drawing-pdf"),str(source.fd),output_path]
            else:
                command = ["/usr/bin/python3",str(Path(processor_root)/"raster.py"),str(source.fd),output_path,allocation.mime]
            launcher = ["/usr/bin/python3",str(Path(processor_root)/"limits.py")]
            bounded_run(launcher+command,pass_fds=(source.fd,output_fd),cwd=output_path,timeout=timeout)
            manifest = collect_manifest(output_fd,allocation,profile)
            return {"manifest":manifest,"directory":os.path.join(os.fspath(workspace),job_name)}
    except Exception:
        # Remove only the directory we created. Never remove, chmod or rewrite input.
        if output_fd >= 0:
            for entry in os.listdir(output_fd):
                try:
                    os.unlink(entry,dir_fd=output_fd)
                except OSError:
                    pass
            try:
                os.rmdir(job_name,dir_fd=root_fd)
            except OSError:
                pass
        raise
    finally:
        if output_fd >= 0:
            os.close(output_fd)
        os.close(root_fd)
