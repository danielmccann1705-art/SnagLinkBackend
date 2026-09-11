"""Decode only JPEG/PNG from a sealed descriptor; emit fixed JPEGs and facts."""
import json
import os
import sys
import warnings
from PIL import Image, ImageFile, ImageOps

Image.MAX_IMAGE_PIXELS = 40_000_000
ImageFile.LOAD_TRUNCATED_IMAGES = False
warnings.simplefilter("error")


def emit(image, path):
    # Recreate RGB pixels to discard EXIF, comments, ICC profiles and source info.
    clean = Image.new("RGB", image.size, "white")
    if image.mode in ("RGBA", "LA") or "transparency" in image.info:
        rgba = image.convert("RGBA")
        clean.paste(rgba, mask=rgba.getchannel("A"))
    else:
        clean.paste(image.convert("RGB"))
    with open(path, "xb") as target:
        clean.save(target, "JPEG", quality=90, subsampling=0, optimize=False, progressive=False)


def main(fd, output, mime):
    expected = {"image/jpeg": "JPEG", "image/png": "PNG"}[mime]
    # Verify container structure, then reopen the immutable descriptor for decode.
    with os.fdopen(os.dup(fd), "rb") as source:
        source.seek(0)
        with Image.open(source, formats=[expected]) as image:
            if image.format != expected or getattr(image, "n_frames", 1) != 1:
                raise ValueError("unsupported frames")
            width, height = image.size
            if min(width, height) < 1 or max(width, height) > 12000 or width * height > 40_000_000:
                raise ValueError("pixel limit")
            image.verify()
    with os.fdopen(os.dup(fd), "rb") as source:
        source.seek(0)
        with Image.open(source, formats=[expected]) as image:
            image.load()
            upright = ImageOps.exif_transpose(image)
            width, height = upright.size
            rendition = upright.copy()
            rendition.thumbnail((4096, 4096), getattr(Image, "Resampling", Image).LANCZOS)
            emit(rendition, os.path.join(output, "page-0000.jpg"))
            thumbnail = upright.copy()
            thumbnail.thumbnail((512, 512), getattr(Image, "Resampling", Image).LANCZOS)
            emit(thumbnail, os.path.join(output, "thumb-0000.jpg"))
            box = {"x": 0, "y": 0, "width": width, "height": height}
            page = {"sourcePageIndex": 0, "sourcePageLabel": "1", "geometry": {
                "mediaBox": box, "cropBox": box, "displayBox": box, "rotation": 0,
                "userUnit": 1, "width": rendition.width, "height": rendition.height,
                "sourceToDisplay": [1 / width, 0, 0, 1 / height, 0, 0],
                "coordinateSystem": "display_top_left_v1",
            }, "thumbnailWidth": thumbnail.width, "thumbnailHeight": thumbnail.height}
    with open(os.path.join(output, "pages.json"), "x", encoding="ascii") as target:
        json.dump({"pages": [page]}, target, allow_nan=False, sort_keys=True, separators=(",", ":"))


if __name__ == "__main__":
    try:
        main(int(sys.argv[1]), sys.argv[2], sys.argv[3])
    except Exception:
        # Never expose parser text, filenames or source metadata in logs/errors.
        raise SystemExit(65)
