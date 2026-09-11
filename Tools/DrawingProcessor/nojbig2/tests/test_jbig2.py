import hashlib
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import unittest

sys.path.insert(0,"/opt/snaglist-drawing")
from worker import Allocation,ProcessingError,process_file,open_private_directory
from fixtures import pdf


def serialise(objects, *, xref_filter=None, compressed_page=False):
    result=bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n"); positions={}
    for number,content in sorted(objects.items()):
        positions[number]=len(result)
        result.extend(f"{number} 0 obj\n".encode()+content+b"\nendobj\n")
    number=max(objects)+1; xref=len(result)
    if xref_filter is not None or compressed_page:
        positions[number]=xref
        entries=[]
        for i in range(number+1):
            if i==0: entries.append(struct.pack(">BIH",0,0,65535))
            elif compressed_page and i==3: entries.append(struct.pack(">BIH",2,4,0))
            else: entries.append(struct.pack(">BIH",1,positions[i],0))
        payload=b"".join(entries)
        filter_part=(" /Filter "+xref_filter) if xref_filter else ""
        record=f"<< /Type /XRef /Size {number+1} /Root 1 0 R /W [1 4 2]{filter_part} /Length {len(payload)} >>\nstream\n".encode()+payload+b"\nendstream"
        result.extend(f"{number} 0 obj\n".encode()+record+b"\nendobj\n")
    else:
        result.extend(f"xref\n0 {number}\n0000000000 65535 f \n".encode())
        for i in range(1,number): result.extend(f"{positions[i]:010d} 00000 n \n".encode())
        result.extend(f"trailer\n<< /Size {number} /Root 1 0 R >>\n".encode())
    result.extend(f"startxref\n{xref}\n%%EOF\n".encode())
    return bytes(result)


def filtered(kind):
    catalog=b"<< /Type /Catalog /Pages 2 0 R >>"
    pages=b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
    page=b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Contents 4 0 R >>"
    if kind=="xref":
        return serialise({1:catalog,2:pages,3:page,4:b"<< /Length 0 >>\nstream\n\nendstream"},xref_filter="/JBIG2Decode")
    if kind=="object":
        embedded=b"3 0 << /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>"
        stream=f"<< /Type /ObjStm /N 1 /First 4 /Filter /JBIG2Decode /Length {len(embedded)} >>\nstream\n".encode()+embedded+b"\nendstream"
        return serialise({1:catalog,2:pages,4:stream},compressed_page=True)
    filter_key="/F" if kind=="abbreviated" else "/Filter"
    filter_value={"array":"[/ASCIIHexDecode /JBIG2Decode]","escaped":"/JBIG2#44ecode","indirect":"5 0 R"}.get(kind,"/JBIG2Decode")
    globals_part="/DecodeParms << /JBIG2Globals 4 0 R >>" if kind=="globals" else ""
    stream=f"<< {filter_key} {filter_value} {globals_part} /Length 3 >>\nstream\n00>\nendstream".encode()
    objects={1:catalog,2:pages,3:page,4:stream}
    if kind=="indirect": objects[5]=b"/JBIG2Decode"
    return serialise(objects)


class JBIG2Tests(unittest.TestCase):
    def test_all_filter_entry_paths_reject_before_decoder_with_specific_safe_code(self):
        for kind in ("content","array","escaped","indirect","abbreviated","globals","object","xref"):
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as directory:
                root=Path(directory); source=root/"input"; source.mkdir(mode=0o700)
                jobs=root/"jobs"; jobs.mkdir(mode=0o700)
                data=filtered(kind); (source/"source").write_bytes(data)
                allocation=Allocation(hashlib.sha256(data).hexdigest(),len(data),"application/pdf")
                fd=open_private_directory(source)
                try:
                    with self.assertRaises(ProcessingError) as error:
                        process_file(fd,"source",allocation,jobs,"/opt/snaglist-drawing")
                    self.assertEqual(error.exception.code,"unsupported_pdf_filter")
                    self.assertEqual((source/"source").read_bytes(),data)
                    self.assertEqual(list(jobs.iterdir()),[])
                finally: os.close(fd)

    def test_filter_name_in_harmless_pdf_comment_is_not_a_byte_scan_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); source=root/"input"; source.mkdir(mode=0o700)
            jobs=root/"jobs"; jobs.mkdir(mode=0o700)
            data=pdf()+b"% harmless mention /JBIG2Decode /JBIG2Globals\n%%EOF\n"
            (source/"source").write_bytes(data)
            allocation=Allocation(hashlib.sha256(data).hexdigest(),len(data),"application/pdf")
            fd=open_private_directory(source)
            try:
                result=process_file(fd,"source",allocation,jobs,"/opt/snaglist-drawing")
                self.assertEqual(len(result["manifest"]["pages"]),1)
            finally: os.close(fd)


if __name__=="__main__": unittest.main()
