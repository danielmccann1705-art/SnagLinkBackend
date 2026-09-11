import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import struct
import sys
import tempfile
import time
import unittest
from unittest import mock
import zlib
from PIL import Image

sys.path.insert(0,"/opt/snaglist-drawing")
from worker import (Allocation,ProcessingError,verify_source,open_private_directory,bounded_run,
                    collect_manifest,process_file,runtime_profile)
from fixtures import pdf,raster

PROCESSOR=Path("/opt/snaglist-drawing")


class ProcessorTests(unittest.TestCase):
    def setUp(self):
        self.tmp=Path(tempfile.mkdtemp(prefix="dra02-"))
        self.input=self.tmp/"input"; self.input.mkdir(mode=0o700)
        self.jobs=self.tmp/"jobs"; self.jobs.mkdir(mode=0o700)
        self.fd=open_private_directory(self.input)

    def tearDown(self):
        os.close(self.fd)
        shutil.rmtree(self.tmp)

    def source(self,data,mime):
        path=self.input/"source"
        path.write_bytes(data)
        path.chmod(0o600)
        return Allocation(hashlib.sha256(data).hexdigest(),len(data),mime)

    def run_source(self,data,mime="application/pdf"):
        allocation=self.source(data,mime)
        result=process_file(self.fd,"source",allocation,self.jobs,PROCESSOR)
        self.assertEqual((self.input/"source").read_bytes(),data)
        return result

    def rejects(self,data,mime="application/pdf"):
        allocation=self.source(data,mime)
        mode=stat.S_IMODE((self.input/"source").stat().st_mode)
        def existing_outputs():
            return {str(path.relative_to(self.jobs)):hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in self.jobs.rglob("*") if path.is_file()}
        prior_directories=set(self.jobs.iterdir())
        prior_outputs=existing_outputs()
        with self.assertRaises(ProcessingError):
            process_file(self.fd,"source",allocation,self.jobs,PROCESSOR)
        self.assertEqual((self.input/"source").read_bytes(),data)
        self.assertEqual(stat.S_IMODE((self.input/"source").stat().st_mode),mode)
        self.assertEqual(set(self.jobs.iterdir()),prior_directories)
        self.assertEqual(existing_outputs(),prior_outputs)

    def colour(self,result,page,point,expected):
        with Image.open(Path(result["directory"])/f"page-{page:04d}.jpg") as image:
            image.load()
            pixel=image.getpixel((min(image.width-1,int(point[0]*image.width)),min(image.height-1,int(point[1]*image.height))))
            self.assertTrue(all(abs(a-b)<12 for a,b in zip(pixel,expected)),(point,pixel,expected))

    def test_actual_pdf_crop_rotations_userunit_and_pin_pixels(self):
        result=self.run_source(pdf((0,90,180,270),user_unit=2.5))
        pages=result["manifest"]["pages"]
        self.assertEqual(len(pages),4)
        mapping={0:lambda u,v:(u,1-v),90:lambda u,v:(v,u),180:lambda u,v:(1-u,v),270:lambda u,v:(1-v,1-u)}
        for index,rotation in enumerate((0,90,180,270)):
            page=pages[index]; g=page["geometry"]
            self.assertEqual(g["rotation"],rotation)
            self.assertEqual(g["userUnit"],2.5)
            self.assertEqual(g["mediaBox"],{"x":10,"y":20,"width":140,"height":220})
            self.assertEqual(g["displayBox"],{"x":20,"y":30,"width":100,"height":160})
            self.assertEqual(g["cropBox"],g["displayBox"])
            for u,v,colour in ((.2,.2,(255,0,0)),(.8,.2,(0,255,0)),(.2,.8,(0,0,255)),(.8,.8,(255,255,0))):
                point=mapping[rotation](u,v)
                self.colour(result,index,point,colour)
                x,y=20+100*u,30+160*v
                a,b,c,d,tx,ty=g["sourceToDisplay"]
                self.assertAlmostEqual(a*x+c*y+tx,point[0],places=10)
                self.assertAlmostEqual(b*x+d*y+ty,point[1],places=10)
            with Image.open(Path(result["directory"])/f"thumb-{index:04d}.jpg") as thumb:
                self.assertLessEqual(max(thumb.size),512)
                self.assertEqual(thumb.getexif(),{})

    def test_repeat_processing_has_identical_profile_geometry_and_bytes(self):
        data=pdf((90,),user_unit=3)
        first=self.run_source(data); second=self.run_source(data)
        self.assertNotEqual(first["directory"],second["directory"])
        self.assertEqual(first["manifest"],second["manifest"])
        for path in Path(first["directory"]).iterdir():
            self.assertEqual(path.read_bytes(),(Path(second["directory"])/path.name).read_bytes())
        self.assertRegex(first["manifest"]["processorProfile"],r"^drawing-linux-byte-v1:[a-f0-9]{64}$")

    def test_jpeg_all_exif_orientations_and_metadata_removal(self):
        mappings={1:lambda u,v:(u,v),2:lambda u,v:(1-u,v),3:lambda u,v:(1-u,1-v),4:lambda u,v:(u,1-v),
                  5:lambda u,v:(v,u),6:lambda u,v:(1-v,u),7:lambda u,v:(1-v,1-u),8:lambda u,v:(v,1-u)}
        for orientation in range(1,9):
            with self.subTest(orientation=orientation):
                result=self.run_source(raster("JPEG",orientation),"image/jpeg")
                g=result["manifest"]["pages"][0]["geometry"]
                self.assertEqual((g["width"],g["height"]),(40,80) if orientation>=5 else (80,40))
                self.assertEqual(g["rotation"],0)
                self.colour(result,0,mappings[orientation](.2,.2),(255,0,0))
                self.colour(result,0,mappings[orientation](.2,.8),(0,0,255))
                with Image.open(Path(result["directory"])/"page-0000.jpg") as image:
                    self.assertEqual(dict(image.getexif()),{})
                    self.assertNotIn("icc_profile",image.info)

    def test_transparent_png_flattens_to_white(self):
        result=self.run_source(raster(transparent=True),"image/png")
        self.colour(result,0,(.8,.8),(255,255,255))
        self.colour(result,0,(.2,.2),(255,0,0))

    def test_declared_hash_mime_size_and_signature_fail_without_touching_original(self):
        data=raster(); original=self.source(data,"image/png")
        for allocation in (Allocation("0"*64,len(data),"image/png"),Allocation(original.sha256,len(data)+1,"image/png"),
                           Allocation(original.sha256,len(data),"application/pdf"),Allocation(original.sha256,len(data),"image/svg+xml")):
            with self.subTest(allocation=allocation), self.assertRaises(ProcessingError):
                with verify_source(self.fd,"source",allocation): pass
            self.assertEqual((self.input/"source").read_bytes(),data)
        self.rejects(b"%PDF-1.7\ntruncated")
        self.rejects(data[:-8],"image/png")
        self.rejects(raster("JPEG")[:-20],"image/jpeg")

    def test_corrupt_png_crc_rejected_by_decoder(self):
        data=bytearray(raster()); marker=data.index(b"IDAT")
        length=struct.unpack(">I",data[marker-4:marker])[0]
        data[marker+4+length]^=0xff
        self.rejects(bytes(data),"image/png")

    def test_animated_png_rejected(self):
        output=io.BytesIO()
        first=Image.new("RGB",(20,30),"red"); second=Image.new("RGB",(20,30),"blue")
        first.save(output,"PNG",save_all=True,append_images=[second],duration=100)
        self.rejects(output.getvalue(),"image/png")

    def test_excessive_declared_pixels_rejected_before_allocation(self):
        data=bytearray(raster()); data[16:24]=struct.pack(">II",12001,1)
        data[29:33]=struct.pack(">I",zlib.crc32(data[12:29]))
        self.rejects(bytes(data),"image/png")

    def test_encrypted_pdf_even_with_empty_password_is_rejected(self):
        self.rejects(pdf(encrypted=True))

    def test_zero_and_excessive_pdf_page_counts_rejected(self):
        self.rejects(pdf(()))
        self.rejects(pdf((0,)*101))

    def test_reconstructed_xref_and_bad_page_are_rejected_and_partial_outputs_removed(self):
        self.rejects(pdf(malformed_xref=True))
        self.rejects(pdf((0,90),corrupt_second=True))

    def test_invalid_pdf_userunit_is_rejected(self):
        for unit in (0,-1,75001):
            with self.subTest(unit=unit): self.rejects(pdf(user_unit=unit))

    def test_raw_crop_outside_media_is_preserved_with_intersection_display(self):
        result=self.run_source(pdf(crop=(0,0,120,190)))
        g=result["manifest"]["pages"][0]["geometry"]
        self.assertEqual(g["cropBox"],{"x":0,"y":0,"width":120,"height":190})
        self.assertEqual(g["displayBox"],{"x":10,"y":20,"width":110,"height":170})
        # Crop source red patch centre(24,38) remains at this measured display point.
        self.colour(result,0,((24-10)/110,1-(38-20)/170),(255,0,0))

    def test_valid_inheritance_and_malformed_inherited_geometry(self):
        result=self.run_source(pdf((90,),inherit_geometry=True))
        self.assertEqual(result["manifest"]["pages"][0]["geometry"]["rotation"],90)
        self.colour(result,0,(.2,.2),(255,0,0))
        for kwargs in ({"rotations":(45,)},{"rotations":(360,)},{"media":(150,20,10,240)},
                       {"crop":(120,30,20,190)},{"media":(10,20,10,240)}):
            with self.subTest(kwargs=kwargs): self.rejects(pdf(inherit_geometry=True,**kwargs))

    def test_source_symlink_hardlink_fifo_and_traversal_reject_without_blocking(self):
        allocation=self.source(raster(),"image/png")
        os.symlink("source",self.input/"link")
        os.mkfifo(self.input/"fifo")
        for name in ("link","fifo","../input/source","/source",".",".."):
            started=time.monotonic()
            with self.subTest(name=name),self.assertRaises(ProcessingError):
                with verify_source(self.fd,name,allocation): pass
            self.assertLess(time.monotonic()-started,1)
        os.link(self.input/"source",self.input/"hard")
        with self.assertRaises(ProcessingError):
            with verify_source(self.fd,"hard",allocation): pass

    def test_workspace_rejects_symlink_in_any_path_component(self):
        alias=self.tmp/"alias"; alias.symlink_to(self.input,target_is_directory=True)
        with self.assertRaises((ProcessingError,OSError)): open_private_directory(alias)
        sub=self.input/"sub"; sub.mkdir(mode=0o700)
        with self.assertRaises((ProcessingError,OSError)): open_private_directory(alias/"sub")

    def test_verified_source_is_sealed_and_path_replacement_cannot_change_it(self):
        data=raster(); allocation=self.source(data,"image/png")
        with verify_source(self.fd,"source",allocation) as source:
            with self.assertRaises(OSError): os.write(source.fd,b"x")
            with self.assertRaises(OSError): os.ftruncate(source.fd,0)
            replacement=self.input/"new"; replacement.write_bytes(b"replaced")
            os.replace(replacement,self.input/"source")
            self.assertEqual(os.read(source.fd,len(data)+1),data)

    def test_mid_read_mutation_is_detected_even_if_file_length_unchanged(self):
        data=raster(); allocation=self.source(data,"image/png")
        original_read=os.read; changed=False
        def read(fd,size):
            nonlocal changed
            result=original_read(fd,size)
            if result and not changed:
                changed=True
                with open(self.input/"source","r+b") as target:
                    target.seek(20); target.write(b"X")
            return result
        with mock.patch("worker.os.read",side_effect=read),self.assertRaises(ProcessingError) as error:
            with verify_source(self.fd,"source",allocation): pass
        self.assertEqual(error.exception.code,"source_changed")

    def test_directory_fd_remains_anchored_after_rename(self):
        data=raster(); allocation=self.source(data,"image/png")
        renamed=self.tmp/"renamed"; self.input.rename(renamed)
        with verify_source(self.fd,"source",allocation) as source:
            self.assertEqual(os.read(source.fd,len(data)),data)

    def test_processor_timeout_preserves_original_and_cleans_own_outputs(self):
        data=pdf((0,90,180,270)); allocation=self.source(data,"application/pdf")
        with self.assertRaises(ProcessingError) as error:
            process_file(self.fd,"source",allocation,self.jobs,PROCESSOR,timeout=.001)
        self.assertEqual(error.exception.code,"processor_timeout")
        self.assertEqual((self.input/"source").read_bytes(),data)
        self.assertEqual(list(self.jobs.iterdir()),[])

    def test_output_hashes_are_measured_from_encoded_files(self):
        result=self.run_source(pdf())
        page=result["manifest"]["pages"][0]
        for prefix,key in (("page","rendition"),("thumb","thumbnail")):
            data=(Path(result["directory"])/f"{prefix}-0000.jpg").read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(),page[key+"SHA256"])
            self.assertEqual(len(data),page[key+"Bytes"])

    def test_forged_metadata_cannot_misstate_encoded_dimensions(self):
        data=raster(); result=self.run_source(data,"image/png")
        directory=Path(result["directory"])
        metadata=json.loads((directory/"pages.json").read_text())
        metadata["pages"][0]["geometry"]["width"]*=2
        metadata["pages"][0]["geometry"]["height"]*=2
        (directory/"pages.json").write_text(json.dumps(metadata))
        fd=open_private_directory(directory)
        try:
            with self.assertRaises(ProcessingError) as error:
                collect_manifest(fd,Allocation(hashlib.sha256(data).hexdigest(),len(data),"image/png"),"synthetic-profile")
            self.assertEqual(error.exception.code,"processor_output_invalid")
        finally: os.close(fd)

    def test_duplicate_geometry_keys_and_output_metadata_are_rejected(self):
        data=raster(); result=self.run_source(data,"image/png")
        directory=Path(result["directory"])
        metadata=(directory/"pages.json").read_text()
        (directory/"pages.json").write_text(metadata.replace('"rotation":0','"rotation":0,"rotation":90'))
        fd=open_private_directory(directory)
        try:
            with self.assertRaises(ProcessingError):
                collect_manifest(fd,Allocation(hashlib.sha256(data).hexdigest(),len(data),"image/png"),"synthetic-profile")
            (directory/"pages.json").write_text(metadata)
            path=directory/"page-0000.jpg"; encoded=path.read_bytes()
            path.write_bytes(encoded[:2]+b'\xff\xfe\x00\x08SECRET'+encoded[2:])
            with self.assertRaises(ProcessingError):
                collect_manifest(fd,Allocation(hashlib.sha256(data).hexdigest(),len(data),"image/png"),"synthetic-profile")
        finally: os.close(fd)


class IsolationTests(unittest.TestCase):
    def test_actual_container_is_nonroot_readonly_and_without_network(self):
        self.assertNotEqual(os.getuid(),0)
        with self.assertRaises(OSError): Path("/opt/snaglist-drawing/write-probe").write_text("x")
        with socket.socket() as connection:
            connection.settimeout(.2)
            with self.assertRaises(OSError): connection.connect(("1.1.1.1",443))
        self.assertFalse(Path("/Users/danielmccann").exists())
        self.assertEqual(Path("/sys/fs/cgroup/pids.max").read_text().strip(),"32")

    def test_stdout_and_stderr_flood_are_drained_and_capped(self):
        for fd in (1,2):
            with self.subTest(fd=fd),self.assertRaises(ProcessingError) as error:
                bounded_run(["/usr/bin/python3","-c",f"import os; os.write({fd},b'x'*2000000)"],timeout=3)
            self.assertEqual(error.exception.code,"processor_log_limit")

    def test_wall_deadline_kills_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            marker=Path(directory)/"orphan"
            code="import os,time; child=os.fork(); time.sleep(.4 if child==0 else 5); open('orphan','w').write('x')"
            with self.assertRaises(ProcessingError) as error:
                bounded_run(["/usr/bin/python3","-c",code],cwd=directory,timeout=.05)
            self.assertEqual(error.exception.code,"processor_timeout")
            time.sleep(.5)
            self.assertFalse(marker.exists())

    def test_file_and_memory_limits_are_real_child_failures(self):
        launcher=["/usr/bin/python3",str(PROCESSOR/"limits.py"),"/usr/bin/python3","-c"]
        with tempfile.TemporaryDirectory() as directory:
            for code in ("open('oversize','wb').write(b'x'*(11*1024*1024))","x=bytearray(1024*1024*1024)"):
                with self.subTest(code=code),self.assertRaises(ProcessingError) as error:
                    bounded_run(launcher+[code],cwd=directory,timeout=3)
                self.assertEqual(error.exception.code,"processor_rejected")

    def test_total_output_size_is_bounded_while_child_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ProcessingError) as error:
                bounded_run(["/usr/bin/python3","-c","import time; open('out','wb').write(b'x'*65536); time.sleep(1)"],cwd=directory,output_limit=1024)
            self.assertEqual(error.exception.code,"processor_output_limit")

    def test_runtime_identity_checks_current_helper_libraries_fonts_and_code(self):
        profile=runtime_profile(PROCESSOR)
        raw=(PROCESSOR/"runtime-profile.json").read_bytes()
        self.assertTrue(profile.endswith(hashlib.sha256(raw).hexdigest()))
        data=json.loads(raw)
        paths=list(data["files"])
        self.assertTrue(any("libpoppler" in p for p in paths))
        self.assertTrue(any("libjpeg" in p for p in paths))
        self.assertTrue(any("DejaVuSans.ttf" in p for p in paths))
        self.assertIn(str(PROCESSOR/"drawing-pdf"),paths)


if __name__=="__main__": unittest.main()
