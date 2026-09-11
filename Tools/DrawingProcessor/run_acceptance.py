#!/usr/bin/env python3
"""Repeatable LOCAL acceptance, using exact original source archives.

No source-tree checkout, database, secrets, R2, pushing or production deployment.
The local base image must already exist and match its reviewed immutable ID.
"""
import argparse
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/"nojbig2"))
from verify_archives import ARCHIVES,verify


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archives",required=True,type=Path,help="Cache containing the three authenticated Ubuntu source archives")
    parser.add_argument("--output",required=True,type=Path,help="New evidence directory; must not already exist")
    parser.add_argument("--docker",default=shutil.which("docker"))
    parser.add_argument("--base-image",default="snaglist-unified-staging:91a53d9")
    parser.add_argument("--expected-base-id",default="sha256:11b2587710a73da3c7dc3dff0e6e29b4b4a62d2ef698c6eaf7c850b5017128dc")
    args=parser.parse_args()
    if not args.docker: raise SystemExit("A permitted local Docker executable is required")
    verify(args.archives)
    args.output.mkdir(parents=True,exist_ok=False)
    output=args.output.resolve()
    inspect=lambda reference:json.loads(subprocess.check_output([args.docker,"image","inspect",reference],text=True))[0]
    base=inspect(args.base_image)
    if base["Id"]!=args.expected_base_id or base["Os"]!="linux" or base["Architecture"]!="amd64":
        raise SystemExit("Local base differs from the reviewed immutable Linux amd64 image")
    record={"startedUTC":datetime.now(timezone.utc).isoformat(),"baseImageId":base["Id"],
            "sourceArchives":ARCHIVES,"scope":"local synthetic acceptance only; no production isolation or feature activation"}
    (output/"base-image.json").write_text(json.dumps(base,indent=2)+"\n")
    def persist(): (output/"run.json").write_text(json.dumps(record,indent=2)+"\n")
    def execute(command,log):
        with (output/log).open("wb") as stream:
            return subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT).returncode
    identifier=uuid.uuid4().hex
    intermediate="snaglist-drawing-build:"+identifier
    final="snaglist-drawing-acceptance:"+identifier
    try:
        with tempfile.TemporaryDirectory(prefix="snaglist-drawing-context-") as directory:
            context=Path(directory)
            for folder in ("processor","runtime","tests","nojbig2"):
                shutil.copytree(ROOT/folder,context/folder,ignore=shutil.ignore_patterns("__pycache__","*.pyc"))
            (context/"upstream").mkdir()
            for name in ARCHIVES: shutil.copyfile(args.archives/name,context/"upstream"/name)
            record["sourceFiles"]={str(path.relative_to(context)):hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in sorted(context.rglob("*")) if path.is_file() and "upstream" not in path.parts}
            record["harnessSHA256"]=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(); persist()
            record["intermediateBuildExitCode"]=execute([args.docker,"build","--platform","linux/amd64","--progress","plain",
                "--build-arg","BASE_IMAGE="+args.base_image,"-f",str(context/"runtime/Dockerfile"),"-t",intermediate,str(context)],"build-intermediate.log")
            persist()
            if record["intermediateBuildExitCode"]: raise SystemExit(1)
            record["intermediateImageId"]=inspect(intermediate)["Id"]
            record["candidateBuildExitCode"]=execute([args.docker,"build","--platform","linux/amd64","--progress","plain",
                "--build-arg","PROCESSOR_BASE_IMAGE="+intermediate,"-f",str(context/"nojbig2/Dockerfile"),"-t",final,str(context)],"build-candidate.log")
            persist()
            if record["candidateBuildExitCode"]: raise SystemExit(1)
        candidate=inspect(final)
        if candidate["Os"]!="linux" or candidate["Architecture"]!="amd64": raise SystemExit("Unexpected candidate platform")
        record["candidateImageId"]=candidate["Id"]
        (output/"candidate-image.json").write_text(json.dumps(candidate,indent=2)+"\n")
        confinement=[args.docker,"run","--rm","--platform","linux/amd64","--network","none","--read-only",
            "--tmpfs","/tmp:rw,noexec,nosuid,nodev,size=512m,mode=1777","--cap-drop","ALL",
            "--security-opt","no-new-privileges","--pids-limit","32","--memory","1536m","--cpus","1"]
        record["runtimeArguments"]=confinement+[candidate["Id"]]
        started=time.monotonic(); persist()
        record["testsExitCode"]=execute(record["runtimeArguments"],"tests.log")
        record["testsWallSeconds"]=round(time.monotonic()-started,3)
        profile=subprocess.check_output(confinement+['--entrypoint','/usr/bin/python3',candidate["Id"],"-c",
            "from pathlib import Path; print(Path('/opt/snaglist-drawing/runtime-profile.json').read_text(),end='')"])
        (output/"runtime-profile.json").write_bytes(profile)
        record["runtimeProfileSHA256"]=hashlib.sha256(profile).hexdigest()
        if record["testsExitCode"]: raise SystemExit(1)
    finally:
        record["stoppedUTC"]=datetime.now(timezone.utc).isoformat(); persist()


if __name__=="__main__": main()
