"""Synthetic, deterministic documents; no customer or externally fetched files."""
import hashlib
import io
import struct
from PIL import Image, ImageDraw


def rc4(key,data):
    state=list(range(256)); j=0
    for i in range(256):
        j=(j+state[i]+key[i%len(key)])%256
        state[i],state[j]=state[j],state[i]
    out=bytearray(); i=j=0
    for byte in data:
        i=(i+1)%256; j=(j+state[i])%256
        state[i],state[j]=state[j],state[i]
        out.append(byte^state[(state[i]+state[j])%256])
    return bytes(out)


def pdf(rotations=(0,), *, user_unit=1, crop=(20,30,120,190), media=(10,20,150,240),
        corrupt_second=False, encrypted=False, malformed_xref=False, inherit_geometry=False):
    objects=[b"<< /Type /Catalog /Pages 2 0 R >>",b""]
    padding=bytes.fromhex("28bf4e5e4e758a4164004e56fffa01082e2e00b6d0683e802f0ca9fe6453697a")
    identity=hashlib.md5(b"synthetic-snaglist-dra02").digest()
    key=b""
    if encrypted:
        # Standard PDF security handler revision 2, empty user password. The
        # document remains encrypted even though a reader can open it unaided.
        owner=hashlib.md5((b"owner"+padding)[:32]).digest()[:5]
        o=rc4(owner,padding)
        key=hashlib.md5(padding+o+struct.pack("<i",-4)+identity).digest()[:5]
        u=rc4(key,padding)
    page_ids=[]
    for index,rotation in enumerate(rotations):
        page_id=len(objects)+1; stream_id=page_id+1; page_ids.append(page_id)
        x,y,right,top=crop; w,h=right-x,top-y
        # Asymmetric source-space blocks at known normalised positions.
        content=(f"1 1 1 rg {x} {y} {w} {h} re f\n"
                 f"1 0 0 rg {x+w*.05} {y+h*.05} {w*.3} {h*.3} re f\n"
                 f"0 1 0 rg {x+w*.65} {y+h*.05} {w*.3} {h*.3} re f\n"
                 f"0 0 1 rg {x+w*.05} {y+h*.65} {w*.3} {h*.3} re f\n"
                 f"1 1 0 rg {x+w*.65} {y+h*.65} {w*.3} {h*.3} re f\n").encode()
        if corrupt_second and index==1:
            content=b"unknownoperator\n"
        if encrypted:
            objkey=hashlib.md5(key+struct.pack("<I",stream_id)[:3]+b"\0\0").digest()[:10]
            content=rc4(objkey,content)
        box=lambda values:" ".join(str(value) for value in values)
        geometry="" if inherit_geometry else f"/MediaBox [{box(media)}] /CropBox [{box(crop)}] /Rotate {rotation}"
        objects.append((f"<< /Type /Page /Parent 2 0 R {geometry} "
                        f"/UserUnit {user_unit} /Resources << >> /Contents {stream_id} 0 R >>").encode())
        objects.append(f"<< /Length {len(content)} >>\nstream\n".encode()+content+b"endstream")
    inherited=f"/MediaBox [{' '.join(map(str,media))}] /CropBox [{' '.join(map(str,crop))}] /Rotate {rotations[0]}" if inherit_geometry else ""
    objects[1]=("<< /Type /Pages /Kids ["+" ".join(f"{i} 0 R" for i in page_ids)+f"] /Count {len(page_ids)} {inherited} >>").encode()
    encrypt_id=0
    if encrypted:
        encrypt_id=len(objects)+1
        objects.append((f"<< /Filter /Standard /V 1 /R 2 /Length 40 /O <{o.hex()}> /U <{u.hex()}> /P -4 >>").encode())
    data=bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n"); offsets=[0]
    for number,obj in enumerate(objects,1):
        offsets.append(len(data)); data.extend(f"{number} 0 obj\n".encode()+obj+b"\nendobj\n")
    xref=len(data)
    data.extend(f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]: data.extend(f"{offset:010d} 00000 n \n".encode())
    trailer=f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R"
    if encrypted: trailer+=f" /Encrypt {encrypt_id} 0 R /ID [<{identity.hex()}> <{identity.hex()}>]"
    trailer+=f" >>\nstartxref\n{0 if malformed_xref else xref}\n%%EOF\n"
    data.extend(trailer.encode())
    return bytes(data)


def raster(fmt="PNG",orientation=1,transparent=False):
    image=Image.new("RGBA" if transparent else "RGB",(80,40),(0,0,0,0) if transparent else "white")
    draw=ImageDraw.Draw(image)
    for box,colour in (((0,0,39,19),"red"),((40,0,79,19),"green"),((0,20,39,39),"blue"),((40,20,79,39),"yellow")):
        if not transparent or colour!="yellow": draw.rectangle(box,fill=colour)
    output=io.BytesIO()
    args={}
    if fmt=="JPEG":
        exif=Image.Exif(); exif[274]=orientation; exif[270]="Synthetic construction evidence"
        args={"exif":exif,"quality":98,"subsampling":0}
    image.save(output,fmt,**args)
    return output.getvalue()
