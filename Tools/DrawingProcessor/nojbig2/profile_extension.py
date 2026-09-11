import hashlib
import json
from pathlib import Path
import sys

root=Path(sys.argv[1]); path=root/"runtime-profile.json"
record=json.loads(path.read_text())
policy=json.loads((root/"decoder-policy.json").read_text())
if policy["policy"]!="jbig2-rejected-before-construction-v1" or not policy["decoderCompileUnitRemoved"]:
    raise SystemExit("Expected decoder policy")
libraries=[p for p in record["files"] if "libpoppler.so" in p]
if len(libraries)!=1 or not libraries[0].startswith("/opt/snaglist-poppler/lib/"):
    raise SystemExit("Helper must bind the custom decoder library")
record["decoderPolicy"]=policy
for name in ("decoder-policy.json","core-symbols.txt"):
    file=root/name
    record["files"][str(file)]=hashlib.sha256(file.read_bytes()).hexdigest()
path.write_text(json.dumps(record,sort_keys=True,separators=(",",":"))+"\n")
