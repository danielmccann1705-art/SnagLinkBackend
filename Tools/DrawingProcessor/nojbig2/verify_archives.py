"""Archive identities established through authenticated Ubuntu apt source indexes."""
import hashlib
from pathlib import Path
import sys

ARCHIVES={
    "poppler_22.02.0.orig.tar.xz":"e390c8b806f6c9f0e35c8462033e0a738bb2460ebd660bdb8b6dca01556193e1",
    "poppler_22.02.0-2ubuntu0.13.debian.tar.xz":"bfc89f306a074e2ba93c350fe1664fec8e3dc2aa20e03cd169e5919c3cac9c7c",
    "poppler_22.02.0-2ubuntu0.13.dsc":"5c5ce31fa0239ae512e25ff168e1a8de3d7f7932cea7ca97fd27c2ed4f16128a",
}


def verify(directory):
    for name,expected in ARCHIVES.items():
        path=Path(directory)/name
        if path.is_symlink() or not path.is_file() or path.stat().st_size>5*1024*1024:
            raise ValueError("Source archive is missing or invalid: "+name)
        if hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
            raise ValueError("Source archive identity mismatch: "+name)


if __name__=="__main__": verify(sys.argv[1])
