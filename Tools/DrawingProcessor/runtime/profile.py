"""Build-time exact runtime identity. Not a claim that all packages lack CVEs."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from PIL import Image, features
import PIL

root = Path(sys.argv[1])
if sys.platform != "linux" or os.uname().machine != "x86_64":
    raise SystemExit("This processor profile requires the verified Linux amd64 runtime")
files = {path.resolve() for path in root.glob("*.py")}
files.add((root / "drawing-pdf").resolve())
files.add(Path(sys.executable).resolve())
files.update(path.resolve() for path in Path(PIL.__path__[0]).glob("*.so"))
files.update(path.resolve() for path in Path(PIL.__path__[0]).glob("*.py"))
files.update(path.resolve() for path in Path("/usr/share/fonts").rglob("*") if path.is_file())
files.update(path.resolve() for path in Path("/etc/fonts").rglob("*") if path.is_file())
files.update(path.resolve() for path in Path("/usr/share/poppler").rglob("*") if path.is_file())
for binary in list(files):
    if binary.suffix == ".so" or binary.name in ("drawing-pdf",Path(sys.executable).resolve().name):
        output = subprocess.check_output(["/usr/bin/ldd",str(binary)],text=True)
        for line in output.splitlines():
            for part in line.split():
                if part.startswith("/") and Path(part).is_file():
                    files.add(Path(part).resolve())
packages = subprocess.check_output(["/usr/bin/dpkg-query","-W","-f=${Package}\t${Version}\t${Architecture}\n"],text=True)
record = {"profileVersion":"drawing-linux-byte-v1","platform":"linux/amd64",
          "packages":sorted(packages.splitlines()),"python":sys.version,"pillow":PIL.__version__,
          "jpeg":features.version_codec("jpg"),"zlib":features.version_codec("zlib"),
          "encoding":{"quality":90,"subsampling":"4:4:4","progressive":False,"optimise":False,"background":"white",
                      "previewMaximumSide":4096,"thumbnailMaximumSide":512,"pdf":"Splash RGB8; effective crop; document rotation"},
          "files":{str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(files)}}
(root/"runtime-profile.json").write_text(json.dumps(record,sort_keys=True,separators=(",",":"))+"\n")
