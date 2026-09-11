"""Verify the authenticated distro tree, then remove the JBIG2 decoder entirely."""
import hashlib
import json
from pathlib import Path
import sys

root=Path(sys.argv[1]); manifest=Path(sys.argv[2]); output=Path(sys.argv[3])
expected=json.loads(manifest.read_text())
if any(path.is_symlink() for path in root.rglob("*")):
    raise SystemExit("Unexpected symlink in authenticated source tree")
actual={str(path.relative_to(root)):hashlib.sha256(path.read_bytes()).hexdigest()
        for path in root.rglob("*") if path.is_file() and not path.is_symlink()}
if actual!=expected:
    raise SystemExit("Authenticated source tree mismatch")
stream=root/"poppler/Stream.cc"
source=stream.read_text()
old='''    } else if (!strcmp(name, "JBIG2Decode")) {
        Object globals;
        if (params->isDict()) {
            XRef *xref = params->getDict()->getXRef();
            obj = params->dictLookupNF("JBIG2Globals").copy();
            globals = obj.fetch(xref, recursion);
        }
        str = new JBIG2Stream(str, std::move(globals), &obj);
'''
new='''    } else if (!strcmp(name, "JBIG2Decode")) {
        // Snaglist worker policy: reject before decoder construction or globals
        // resolution. This factory is also used for object and xref streams.
        error(errSyntaxError, getPos(), "SNAGLIST_UNSUPPORTED_JBIG2");
        str = wrapEOFStream(str);
'''
if source.count(old)!=1: raise SystemExit("Expected unique filter factory branch")
stream.write_text(source.replace(old,new))
cmake=root/"CMakeLists.txt"; content=cmake.read_text()
if content.count("  poppler/JBIG2Stream.cc\n")!=1: raise SystemExit("Expected unique decoder compile unit")
cmake.write_text(content.replace("  poppler/JBIG2Stream.cc\n",""))
constructors=[str(path.relative_to(root)) for path in (root/"poppler").glob("*.cc")
              if path.name!="JBIG2Stream.cc" and "new JBIG2Stream" in path.read_text()]
if constructors: raise SystemExit("Unexpected remaining constructor")
record={"policy":"jbig2-rejected-before-construction-v1","distributionSource":"22.02.0-2ubuntu0.13",
        "sourceTreeSHA256":hashlib.sha256(manifest.read_bytes()).hexdigest(),
        "patchScriptSHA256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "patchedFiles":{str(path.relative_to(root)):hashlib.sha256(path.read_bytes()).hexdigest() for path in (stream,cmake)},
        "decoderCompileUnitRemoved":True,"remainingConstructorReferences":constructors,
        "limitation":"PDFs that require JBIG2 decoding are unsupported; original bytes must be retained"}
output.write_text(json.dumps(record,sort_keys=True,separators=(",",":"))+"\n")
