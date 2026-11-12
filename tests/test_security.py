#!/usr/bin/env python3
"""Hostile-input tests for the Omlibria helper.

An EPUB is a zip of attacker-shaped XML, markup and file names, and Calibre's
metadata.db can come from a shared library, so both are treated as untrusted.
Each test builds a small malicious input and checks that the helper refuses it.

    python3 tests/test_security.py
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import re
import sqlite3
import struct
import sys
import tempfile
import unittest
import zipfile
import zlib

HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "omlibria")
loader = importlib.machinery.SourceFileLoader("omlibria", HELPER)
omlibria = importlib.util.module_from_spec(importlib.util.spec_from_loader("omlibria", loader))
loader.exec_module(omlibria)

CONTAINER = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
 <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""

OPF = """<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata><title>T</title></metadata>
<manifest>%s</manifest><spine>%s</spine></package>"""


def run(fn, *args):
    """Call a helper command and return what it printed."""
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        fn(*args)
    return buffer.getvalue()


def make_epub(path, files, opf_items=None):
    items = opf_items or [("ok", "ok.xhtml")]
    manifest = "".join('<item id="%s" href="%s" media-type="application/xhtml+xml"/>' % i for i in items)
    spine = "".join('<itemref idref="%s"/>' % i[0] for i in items)
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("META-INF/container.xml", CONTAINER)
        z.writestr("OEBPS/content.opf", OPF % (manifest, spine))
        for name, data in files.items():
            z.writestr(name, data)


class HelperSecurity(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.library = os.path.join(self.tmp, "lib")
        self.cache = os.path.join(self.tmp, "cache")
        os.makedirs(os.path.join(self.library, "A", "B (1)"))
        self.rel = "A/B (1)/b.epub"
        self.epub = os.path.join(self.library, self.rel)

    def tearDown(self):
        self._tmp.cleanup()

    def prepare(self):
        return json.loads(run(omlibria.prepare, self.library, self.rel, self.cache))

    def chapter(self, html, fragment=""):
        make_epub(self.epub, {"OEBPS/ok.xhtml": html})
        book = self.prepare()
        return run(omlibria.chapter, book["spine"][0]["file"], 400, 477, fragment)

    # ---- the zip itself ----------------------------------------------------

    def test_zip_slip_entry_is_not_extracted(self):
        make_epub(self.epub, {"OEBPS/ok.xhtml": "<p>x</p>", "../../../../escaped.txt": "no"})
        self.prepare()
        for root, _dirs, files in os.walk(self.tmp):
            self.assertNotIn("escaped.txt", files, "an entry escaped the cache directory")

    def test_zip_bomb_is_capped_and_cleaned_up(self):
        make_epub(self.epub, {"OEBPS/ok.xhtml": "<p>x</p>", "OEBPS/huge.bin": b"\0" * (3 * 1024 * 1024)})
        omlibria.MAX_TOTAL_BYTES = 1024 * 1024
        try:
            # `prepare` raises; the command-line wrapper turns that into a JSON error.
            with self.assertRaises(ValueError):
                run(omlibria.prepare, self.library, self.rel, self.cache)
        finally:
            omlibria.MAX_TOTAL_BYTES = 512 * 1024 * 1024
        files = [f for _r, _d, fs in os.walk(self.cache) for f in fs]
        self.assertNotIn("huge.bin", files, "the partial file should be deleted")
        self.assertNotIn(".extracted", files, "a refused book must not be marked as extracted")

    def test_entity_declarations_are_rejected(self):
        bomb = ('<?xml version="1.0"?><!DOCTYPE p [<!ENTITY a "aaaa"><!ENTITY b "&a;&a;&a;&a;">]>'
                '<package xmlns="http://www.idpf.org/2007/opf"><metadata><title>&b;</title></metadata></package>')
        path = os.path.join(self.tmp, "bomb.xml")
        with open(path, "w") as f:
            f.write(bomb)
        with self.assertRaises(ValueError):
            omlibria.read_xml(path)

    # ---- paths written inside the book ------------------------------------

    def test_spine_entry_outside_the_book_is_dropped(self):
        make_epub(self.epub, {"OEBPS/ok.xhtml": "<p>x</p>"},
                  opf_items=[("esc", "../../../../../../etc/passwd"), ("ok", "ok.xhtml")])
        book = self.prepare()
        self.assertEqual([os.path.basename(s["file"]) for s in book["spine"]], ["ok.xhtml"])

    def test_image_stylesheet_and_link_outside_the_book_are_dropped(self):
        html = ('<html><head><link rel="stylesheet" href="../../../../etc/passwd.css"/></head><body>'
                '<p>hello</p><p><img src="../../../../../../etc/hostname"/></p>'
                '<p><a href="../../../../../../etc/passwd">escape</a></p>'
                '<p><a href="ok.xhtml#x">fine</a></p></body></html>')
        out = self.chapter(html)
        self.assertNotIn("<img", out)
        self.assertNotIn("etc/passwd", out)
        self.assertIn('href="epub:', out, "a link inside the book should survive")

    def test_chapter_outside_any_book_is_refused(self):
        outside = os.path.join(self.tmp, "loose.xhtml")
        with open(outside, "w") as f:
            f.write("<p>secret</p>")
        self.assertIn("not part of the book", run(omlibria.chapter, outside, 400, 477, ""))

    def test_book_text_cannot_forge_link_sentinels(self):
        out = self.chapter("<p>a⁢b⁤c⁣d</p>")
        for sentinel in (omlibria.LINK_OPEN, omlibria.LINK_CLOSE, omlibria.MARKER):
            self.assertNotIn(sentinel, out)

    # ---- Calibre's database ------------------------------------------------

    def make_library(self, path_value):
        os.makedirs(os.path.join(self.tmp, "outside"), exist_ok=True)
        make_epub(os.path.join(self.tmp, "outside", "evil.epub"), {"OEBPS/ok.xhtml": "<p>x</p>"})
        db = sqlite3.connect(os.path.join(self.library, "metadata.db"))
        db.executescript("""
            CREATE TABLE books(id INTEGER PRIMARY KEY, title TEXT, sort TEXT, path TEXT,
                               has_cover INT, series_index REAL, timestamp TEXT);
            CREATE TABLE data(id INTEGER PRIMARY KEY, book INT, format TEXT, name TEXT);
            CREATE TABLE authors(id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE books_authors_link(id INTEGER PRIMARY KEY, book INT, author INT);
            CREATE TABLE series(id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE books_series_link(id INTEGER PRIMARY KEY, book INT, series INT);""")
        db.execute("INSERT INTO books VALUES(1,'T','t',?,1,1,'2020')", (path_value,))
        db.execute("INSERT INTO data VALUES(1,1,'EPUB','evil')")
        db.commit()
        db.close()

    def test_database_path_climbing_out_of_the_library_is_not_listed(self):
        self.make_library("../outside")
        listing = json.loads(run(omlibria.scan, self.library, self.cache))
        self.assertEqual(listing["books"], [], "a ../ path in metadata.db must not be listed")

    def test_prepare_refuses_a_relative_path_that_climbs_out(self):
        self.make_library("../outside")
        result = json.loads(run(omlibria.prepare, self.library, "../outside/evil.epub", self.cache))
        self.assertTrue(result.get("error"))

    def test_prepare_refuses_an_absolute_path(self):
        result = json.loads(run(omlibria.prepare, self.library, os.path.join(self.tmp, "outside", "evil.epub"), self.cache))
        self.assertTrue(result.get("error"))

    # ---- library size policy ----------------------------------------------

    def build_db(self, books=1, authors_per_book=1, title="T", author="A",
                 path_value="A/B (1)", epub_rows=None):
        """A metadata.db with a chosen shape, used to push each bound in turn."""
        db = sqlite3.connect(os.path.join(self.library, "metadata.db"))
        db.executescript("""
            CREATE TABLE books(id INTEGER PRIMARY KEY, title TEXT, sort TEXT, path TEXT,
                               has_cover INT, series_index REAL, timestamp TEXT);
            CREATE TABLE data(id INTEGER PRIMARY KEY, book INT, format TEXT, name TEXT);
            CREATE TABLE authors(id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE books_authors_link(id INTEGER PRIMARY KEY, book INT, author INT);
            CREATE TABLE series(id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE books_series_link(id INTEGER PRIMARY KEY, book INT, series INT);""")
        db.execute("INSERT INTO authors VALUES(1,?)", (author,))
        link = 0
        for i in range(1, books + 1):
            db.execute("INSERT INTO books VALUES(?,?,?,?,0,1,'2020')", (i, title, title, path_value))
            if epub_rows is None or i <= epub_rows:
                db.execute("INSERT INTO data VALUES(?,?,'EPUB','b')", (i, i))
            for _ in range(authors_per_book):
                link += 1
                db.execute("INSERT INTO books_authors_link VALUES(?,?,1)", (link, i))
        db.commit()
        db.close()

    def test_oversized_database_is_refused_before_opening(self):
        self.build_db()
        path = os.path.join(self.library, "metadata.db")
        with open(path, "ab") as f:                      # pad past the size policy
            f.write(b"\0" * (omlibria.MAX_DB_BYTES + 1 - os.path.getsize(path)))
        result = json.loads(run(omlibria.scan, self.library, self.cache))
        self.assertIn("larger than", result["error"])
        self.assertEqual(result["books"], [])

    def test_too_many_books_is_refused(self):
        # One EPUB row and no author links, so the books cap is the bound that fires.
        self.build_db(books=5, authors_per_book=0, epub_rows=1)
        omlibria.MAX_BOOKS = 3
        try:
            result = json.loads(run(omlibria.scan, self.library, self.cache))
        finally:
            omlibria.MAX_BOOKS = 20000
        self.assertIn("more books", result["error"])
        self.assertEqual(result["books"], [])

    def test_too_many_author_rows_is_refused(self):
        self.build_db(books=3, authors_per_book=3)
        omlibria.MAX_LINK_ROWS = 4
        try:
            result = json.loads(run(omlibria.scan, self.library, self.cache))
        finally:
            omlibria.MAX_LINK_ROWS = 200000
        self.assertIn("author entries", result["error"])
        self.assertEqual(result["books"], [])

    def test_long_text_is_truncated_by_sqlite_not_held_in_memory(self):
        huge = "T" * (2 * 1024 * 1024)
        self.build_db(title=huge, author=huge)
        make_epub(os.path.join(self.library, "A", "B (1)", "b.epub"), {"OEBPS/ok.xhtml": "<p>x</p>"})
        result = json.loads(run(omlibria.scan, self.library, self.cache))
        self.assertEqual(result["error"], "")
        book = result["books"][0]
        self.assertLessEqual(len(book["title"]), omlibria.MAX_TEXT)
        self.assertLessEqual(len(book["authors"]), omlibria.MAX_TEXT + 8)

    def test_authors_per_book_are_capped(self):
        self.build_db(books=1, authors_per_book=50, author="A" * 50)
        make_epub(os.path.join(self.library, "A", "B (1)", "b.epub"), {"OEBPS/ok.xhtml": "<p>x</p>"})
        result = json.loads(run(omlibria.scan, self.library, self.cache))
        self.assertEqual(result["error"], "")
        listed = result["books"][0]["authors"].split(", ")
        self.assertLessEqual(len(listed), omlibria.MAX_AUTHORS_PER_BOOK)

    def test_a_slow_library_hits_the_query_deadline(self):
        self.build_db(books=200, authors_per_book=2)
        omlibria.SCAN_SECONDS = 0.0                      # the deadline has already passed
        try:
            result = json.loads(run(omlibria.scan, self.library, self.cache))
        finally:
            omlibria.SCAN_SECONDS = 20.0
        self.assertIn("too long", result["error"])
        self.assertEqual(result["books"], [])

    def test_output_over_the_ceiling_is_replaced_by_a_short_refusal(self):
        omlibria.MAX_STDOUT_BYTES = 2048
        try:
            printed = run(omlibria.out, {"error": "", "books": [{"t": "x" * 8192}]})
        finally:
            omlibria.MAX_STDOUT_BYTES = 16 * 1024 * 1024
        self.assertLess(len(printed), 2048)
        self.assertIn("more data than", json.loads(printed)["error"])

    def test_ordinary_library_book_still_works(self):
        make_epub(self.epub, {"OEBPS/ok.xhtml": "<p>hello there</p>"})
        book = self.prepare()
        self.assertEqual(book["error"], "")
        self.assertEqual(len(book["spine"]), 1)

    # ---- images handed to the renderer -------------------------------------

    def png(self, chunks=(), width=1, height=1):
        """A valid 1x1 PNG, optionally carrying extra chunks."""
        def chunk(kind, payload):
            return (struct.pack(">I", len(payload)) + kind + payload
                    + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))
        ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
        body = b"".join(chunk(k, v) for k, v in chunks)
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + body
                + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00"))
                + chunk(b"IEND", b""))

    def write_image(self, name, data):
        path = os.path.join(self.library, name)
        with open(path, "wb") as f:
            f.write(data)
        open(os.path.join(self.library, ".extracted"), "w").close()
        return path

    def test_png_text_bomb_never_reaches_the_renderer(self):
        bomb = zlib.compress(b"A" * (20 * 1024 * 1024))
        data = self.png(chunks=[(b"zTXt", b"Comment\x00\x00" + bomb)])
        self.assertIn(b"zTXt", data)
        self.assertLess(len(data), 64 * 1024, "the bomb is small on disk")
        path = self.write_image("bomb.png", data)
        clean, dims, _ = omlibria.safe_image(path, self.library)
        self.assertTrue(clean)
        with open(clean, "rb") as f:
            out = f.read()
        self.assertNotIn(b"zTXt", out)
        self.assertLess(len(out), 1024, "nothing is left to expand")
        self.assertEqual(dims, (1, 1))

    def test_other_metadata_chunks_are_dropped(self):
        data = self.png(chunks=[(b"tEXt", b"K\x00v"), (b"iTXt", b"K\x00\x00\x00\x00\x00v"),
                                (b"iCCP", b"P\x00\x00" + zlib.compress(b"C" * 4096)),
                                (b"eXIf", b"E" * 64)])
        path = self.write_image("meta.png", data)
        clean, _, _ = omlibria.safe_image(path, self.library)
        with open(clean, "rb") as f:
            out = f.read()
        for kind in (b"tEXt", b"iTXt", b"iCCP", b"eXIf"):
            self.assertNotIn(kind, out)
        self.assertIn(b"IDAT", out, "the pixels survive")

    def test_png_claiming_huge_dimensions_is_refused(self):
        data = self.png(width=40000, height=40000)      # 1.6e9 pixels to decode
        path = self.write_image("huge.png", data)
        self.assertIsNone(omlibria.safe_image(path, self.library))

    def test_formats_with_their_own_decoder_are_refused(self):
        for name, blob in (("x.svg", b"<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>" + b" " * 32),
                           ("x.webp", b"RIFF\x00\x00\x00\x00WEBPVP8 " + b"\0" * 32),
                           ("x.tif", b"II*\x00" + b"\0" * 64)):
            path = self.write_image(name, blob)
            self.assertIsNone(omlibria.safe_image(path, self.library), name)

    def test_oversized_and_malformed_images_are_refused(self):
        big = self.write_image("big.png", b"\x89PNG\r\n\x1a\n" + b"\0" * 4096)
        omlibria.MAX_IMAGE_BYTES = 512
        try:
            self.assertIsNone(omlibria.safe_image(big, self.library))
        finally:
            omlibria.MAX_IMAGE_BYTES = 32 * 1024 * 1024
        truncated = self.write_image("cut.png", self.png()[:-8])   # no IEND
        self.assertIsNone(omlibria.safe_image(truncated, self.library))

    def test_jpeg_application_segments_are_stripped(self):
        payload = b"Exif\x00\x00" + b"E" * 60000
        app1 = b"\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload
        # SOF0: length, precision, height, width, component count, one component
        sof = (b"\xff\xc0" + struct.pack(">H", 11) + b"\x08" + struct.pack(">HH", 4, 4)
               + b"\x01" + b"\x01\x11\x00")
        data = b"\xff\xd8" + app1 + sof + b"\xff\xda" + struct.pack(">H", 2) + b"scan" + b"\xff\xd9"
        path = self.write_image("meta.jpg", data)
        clean, dims, _ = omlibria.safe_image(path, self.library)
        with open(clean, "rb") as f:
            out = f.read()
        self.assertEqual(dims, (4, 4))
        self.assertNotIn(b"Exif", out)
        self.assertLess(len(out), 128, "the 60 KB segment is gone")
        self.assertIn(b"scan", out, "the image data survives")

    def test_a_books_image_is_rendered_from_the_sanitized_copy(self):
        html = '<html><body><p>t</p><p><img src="x.png"/></p></body></html>'
        make_epub(self.epub, {"OEBPS/ok.xhtml": html,
                              "OEBPS/x.png": self.png(chunks=[(b"tEXt", b"K\x00v")])})
        book = self.prepare()
        out = run(omlibria.chapter, book["spine"][0]["file"], 400, 477, "")
        self.assertIn(omlibria.IMAGE_DIR_SUFFIX + "/", out, "pointed at the sanitized copy")
        self.assertNotIn("x.png", out, "never the book's own file")
        shown = re.search(r'src="file://([^"]+)"', out).group(1)
        self.assertFalse(shown.startswith(book["dir"] + os.sep),
                         "the sanitized copy must sit outside the extracted book")

    def test_a_preseeded_cache_file_is_overwritten_not_served(self):
        """The cache name is computable from a book, so its bytes are never trusted."""
        good = self.png()
        path = self.write_image("real.png", good)
        clean, _, _ = omlibria.safe_image(path, self.library)      # learn the computed name
        bomb = self.png(chunks=[(b"zTXt", b"C\x00\x00" + zlib.compress(b"A" * (8 * 1024 * 1024)))])
        with open(clean, "wb") as f:                            # preseed it, as a crafted book would
            f.write(bomb)
        served, _, _ = omlibria.safe_image(path, self.library)
        self.assertEqual(served, clean, "same name, so the poisoned file is the one in the way")
        with open(served, "rb") as f:
            out = f.read()
        self.assertNotIn(b"zTXt", out, "the preseeded bomb must not be served")
        self.assertLess(len(out), 1024)

    def test_a_book_cannot_ship_files_under_this_readers_names(self):
        make_epub(self.epub, {"OEBPS/ok.xhtml": "<p>x</p>",
                              ".extracted": "pwned",
                              ".omlibria-meta.json": '{"v": 3, "spine": []}',
                              ".omlibria-images/evil.png": "bomb"})
        book = self.prepare()
        self.assertEqual(book["error"], "")
        root = book["dir"]
        self.assertFalse(os.path.exists(os.path.join(root, ".omlibria-images")),
                         "a reserved directory from the book must not be extracted")
        with open(os.path.join(root, ".extracted")) as f:
            self.assertEqual(f.read(), "", "our own marker, not the book's")
        self.assertFalse(os.path.exists(os.path.join(root, ".omlibria-meta.json")),
                         "a reserved file from the book must not be extracted")

    # ---- the cached reading order ------------------------------------------

    def meta_path(self):
        return self.prepare()["dir"].rstrip(os.sep) + omlibria.META_SUFFIX

    def test_the_cached_listing_sits_outside_the_extracted_book(self):
        make_epub(self.epub, {"OEBPS/ok.xhtml": "<p>x</p>"})
        book = self.prepare()
        meta = book["dir"].rstrip(os.sep) + omlibria.META_SUFFIX
        self.assertTrue(os.path.isfile(meta), "the listing is cached beside the book")
        self.assertFalse(meta.startswith(book["dir"] + os.sep),
                         "nothing a book unpacks can reach the cached listing")

    def test_a_legacy_in_book_listing_is_rebuilt_not_served(self):
        """A book opened before the upgrade may have supplied its own listing."""
        make_epub(self.epub, {"OEBPS/ok.xhtml": "<p>x</p>"})
        dest = self.prepare()["dir"]                  # the extraction an older release left
        os.unlink(dest.rstrip(os.sep) + omlibria.META_SUFFIX)
        planted = os.path.join(dest, ".omlibria-meta.json")
        with open(planted, "w") as f:
            json.dump({"v": 3, "error": '<img src="http://book.example/ping.png">',
                       "dir": dest, "title": "T", "spine": [], "toc": []}, f)
        book = self.prepare()
        self.assertEqual(book["error"], "", "the planted error must never be forwarded")
        self.assertTrue(book["spine"], "the listing must be rebuilt from the book")
        self.assertFalse(os.path.exists(planted), "the legacy file must be removed")

    def test_a_tampered_cached_listing_is_rebuilt(self):
        make_epub(self.epub, {"OEBPS/ok.xhtml": "<p>x</p>"})
        meta = self.meta_path()
        for bad in ({"v": 4, "error": "<img src=x>", "spine": [], "toc": []},
                    {"v": 4, "dir": "/elsewhere", "spine": [{"file": "/etc/passwd",
                     "title": "", "chars": 1}], "toc": [{"title": "a", "spine": 0}]},
                    {"v": 99}, ["not", "a", "listing"]):
            with open(meta, "w") as f:
                json.dump(bad, f)
            book = self.prepare()
            self.assertEqual(book["error"], "", repr(bad))
            self.assertTrue(book["spine"], repr(bad))
            self.assertTrue(book["spine"][0]["file"].startswith(book["dir"] + os.sep),
                            repr(bad))

    # ---- what one section may cost the shell --------------------------------

    def big_png(self, width, height, shade):
        """A valid, highly compressible PNG: large to decode, tiny on disk."""
        def chunk(kind, payload):
            return (struct.pack(">I", len(payload)) + kind + payload
                    + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))
        row = b"\x00" + bytes((shade, shade, shade)) * width
        packer = zlib.compressobj(1)
        body = b"".join(packer.compress(row) for _ in range(height)) + packer.flush()
        return (b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", body) + chunk(b"IEND", b""))

    def test_a_sections_images_share_one_memory_budget(self):
        """Many large images in one paragraph: each passes alone, together they
        would hold gigabytes, so the section stops at its budget."""
        files = {"OEBPS/ok.xhtml": "<p>%s</p>" % "".join(
            '<img src="i%d.png"/>' % i for i in range(12))}
        for i in range(12):
            files["OEBPS/i%d.png" % i] = self.big_png(3000, 3900, i)     # 11.7 MP, 47 MB decoded
        make_epub(self.epub, files)
        book = self.prepare()
        out = run(omlibria.chapter, book["spine"][0]["file"], 400, 477, "")
        shown = len(set(re.findall(r'src="file://([^"]+)"', out)))
        cost = 3000 * 3900 * 4
        self.assertEqual(shown, omlibria.MAX_CHAPTER_IMAGE_BYTES // cost)
        self.assertLess(shown, 12)
        self.assertEqual(out.count("Some images in this section are not shown"), 1)

    def test_a_repeated_image_is_sanitized_and_counted_once(self):
        make_epub(self.epub, {"OEBPS/ok.xhtml": "<p>%s</p>" % ('<img src="x.png"/>' * 500),
                              "OEBPS/x.png": self.png()})
        book = self.prepare()
        out = run(omlibria.chapter, book["spine"][0]["file"], 400, 477, "")
        self.assertEqual(out.count("<img"), 500)
        self.assertEqual(len(os.listdir(book["dir"] + omlibria.IMAGE_DIR_SUFFIX)), 1)

    def test_tables_nested_past_the_limit_are_flattened(self):
        """Qt's table layout doubles in cost per nesting level: 20 levels freeze
        the shell for half a minute from a section of a few hundred bytes."""
        deep = "<table><tr><td>" * 40 + "inner" + "</td></tr></table>" * 40
        out = self.chapter(deep)
        self.assertEqual(out.count("<table"), omlibria.MAX_TABLE_DEPTH)
        self.assertIn("inner", out, "the text is kept, only the nesting goes")

    def test_nesting_deeper_than_any_book_is_not_reproduced(self):
        out = self.chapter("<p>" + "<b>" * 5000 + "deep" + "</b>" * 5000 + "</p>")
        self.assertLessEqual(out.count("<b>"), omlibria.MAX_NESTING)
        self.assertIn("deep", out)

    def test_a_section_stops_at_its_text_limit(self):
        out = self.chapter("<p>%s</p><p>tail-marker</p>" % ("word " * 400000))
        self.assertIn("This section is longer than Omlibria shows", out)
        self.assertNotIn("tail-marker", out)
        self.assertLess(len(out), omlibria.MAX_CHAPTER_TEXT + 4096)

    def test_a_section_stops_at_its_element_and_cell_limits(self):
        out = self.chapter("<p>x</p>" * (omlibria.MAX_CHAPTER_TAGS + 500))
        self.assertLessEqual(out.count("<p>"), omlibria.MAX_CHAPTER_TAGS)
        self.assertIn("This section is longer than Omlibria shows", out)
        cells = "<table>%s</table>" % ("<tr>%s</tr>" % ("<td>c</td>" * 100) * 100)
        out = self.chapter(cells)
        self.assertLessEqual(out.count("<td>"), omlibria.MAX_TABLE_CELLS)

    def test_a_jpeg_with_more_scans_than_any_encoder_writes_is_refused(self):
        """Each scan is a full pass over the image in the decoder, so thousands
        of tiny repeated scans hold the shell busy for minutes."""
        def segment(marker, payload):
            return b"\xff" + bytes((marker,)) + struct.pack(">H", len(payload) + 2) + payload
        head = (b"\xff\xd8" + segment(0xDB, b"\x00" + bytes(64))
                + segment(0xC2, b"\x08" + struct.pack(">HH", 16, 16) + b"\x01\x01\x11\x00"))
        scan = segment(0xDA, b"\x01\x01\x00\x00\x00\x00") + b"\x12\x34"
        fine = head + scan * 10 + b"\xff\xd9"
        bomb = head + scan * (omlibria.MAX_JPEG_SCANS + 1) + b"\xff\xd9"
        clean, dims, _ = omlibria.sanitized_jpeg(fine)
        self.assertEqual(dims, (16, 16))
        self.assertEqual(clean.count(b"\xff\xda"), 10)
        self.assertEqual(omlibria.sanitized_jpeg(bomb), (None, None, 0))

    def test_metadata_after_the_first_scan_is_stripped_too(self):
        def segment(marker, payload):
            return b"\xff" + bytes((marker,)) + struct.pack(">H", len(payload) + 2) + payload
        data = (b"\xff\xd8" + segment(0xC0, b"\x08" + struct.pack(">HH", 4, 4) + b"\x01\x01\x11\x00")
                + segment(0xDA, b"\x01\x01\x00\x00\x3f\x00") + b"\x55"
                + segment(0xFE, b"SECRET-COMMENT") + segment(0xE1, b"Exif-LATER")
                + b"\xff\xd9" + b"TRAILING-JUNK")
        clean, dims, _ = omlibria.sanitized_jpeg(data)
        self.assertEqual(dims, (4, 4))
        for junk in (b"SECRET-COMMENT", b"Exif-LATER", b"TRAILING-JUNK"):
            self.assertNotIn(junk, clean)
        self.assertTrue(clean.endswith(b"\xff\xd9"))

    def test_an_image_with_two_headers_is_refused(self):
        """The size that is checked must be the size that is decoded."""
        def chunk(kind, payload):
            return (struct.pack(">I", len(payload)) + kind + payload
                    + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))
        huge = chunk(b"IHDR", struct.pack(">IIBBBBB", 40000, 40000, 8, 2, 0, 0, 0))
        good = self.png()
        self.assertEqual(omlibria.sanitized_png(good[:8] + huge + good[8:]), (None, None, 0))
        def segment(marker, payload):
            return b"\xff" + bytes((marker,)) + struct.pack(">H", len(payload) + 2) + payload
        sof = lambda w, h: segment(0xC0, b"\x08" + struct.pack(">HH", h, w) + b"\x01\x01\x11\x00")
        two = (b"\xff\xd8" + sof(60000, 60000) + sof(1, 1)
               + segment(0xDA, b"\x01\x01\x00\x00\x3f\x00") + b"\x55\xff\xd9")
        self.assertEqual(omlibria.sanitized_jpeg(two), (None, None, 0))

    def test_sixteen_bit_images_are_costed_at_their_decoded_size(self):
        eight = omlibria.sanitized_png(self.png())
        data = bytearray(self.png())
        data[24] = 16                                   # bit depth, inside IHDR
        self.assertEqual(eight[2], 4)
        self.assertEqual(omlibria.sanitized_png(bytes(data))[2], 8)

    def test_utf16_xml_cannot_slip_an_entity_past_the_check(self):
        doc = ('<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE c [<!ENTITY a "%s">]>'
               '<container>%s</container>' % ("x" * 1000, "&a;" * 50))
        for encoding in ("utf-16", "utf-16-le", "utf-16-be", "utf-32"):
            path = os.path.join(self.tmp, "c.xml")
            with open(path, "wb") as f:
                f.write(doc.encode(encoding))
            with self.assertRaises(ValueError, msg=encoding):
                omlibria.read_xml(path)

    def test_the_helper_stops_itself_at_its_processor_limit(self):
        import subprocess
        code = ("import importlib.machinery, importlib.util, sys\n"
                "l = importlib.machinery.SourceFileLoader('omlibria', sys.argv[1])\n"
                "m = importlib.util.module_from_spec(importlib.util.spec_from_loader('omlibria', l))\n"
                "l.exec_module(m)\n"
                "m.HELPER_CPU_SECONDS['chapter'] = 1\n"
                "m.chapter = lambda *a: [None for _ in iter(int, 1)]\n"
                "sys.exit(m.main(['omlibria', 'chapter', '/nonexistent', '100']))\n")
        done = subprocess.run([sys.executable, "-I", "-c", code, HELPER],
                              capture_output=True, text=True, timeout=60)
        self.assertIn("took longer than this reader allows", done.stdout)

    # ---- scanning markup in time proportional to it ------------------------

    def assertQuick(self, fn, seconds=3.0):
        import time
        start = time.monotonic()
        fn()
        self.assertLess(time.monotonic() - start, seconds)

    def test_forward_scans_match_the_expressions_they_replace(self):
        """strip_tags, tag_blocks and parse_css must give exactly what the old
        regular expressions gave, on random markup full of edge cases."""
        import random
        rng = random.Random(7)
        atoms = ["<", ">", "<>", "<b>", "</b>", "<script>", "</script>", "<style x>", "</style>",
                 "<body>", "</body>", "<a href='x'>", "</a>", "<aside>", "<div/>", "<p x/>", "/>", "<span", "<pre/>", "{", "}", "@", "/*",
                 "*/", "a", " ", "p", ".c", ";", "font-style:italic", ",", "\n"]
        for _ in range(3000):
            t = "".join(rng.choice(atoms) for _ in range(rng.randint(0, 30)))
            self.assertEqual(omlibria.strip_tags(t, " "), re.sub(r"(?s)<[^>]+>", " ", t), t)
            self.assertEqual(omlibria.without_blocks(t, ("script", "style")),
                             re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", " ", t), t)
            want = re.search(r"(?is)<body[^>]*>(.*?)</body>", t)
            got = next(omlibria.tag_blocks(t, ("body",)), None)
            self.assertEqual(got[3] if got else None, want.group(1) if want else None, t)
            want = [(a.group(1), a.group(2)) for a in re.finditer(
                r"<a[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", t, re.S)]
            has = lambda tag: re.search(r"href=[\"']([^\"']+)[\"']", tag)
            got = [(has(tag).group(1), inner) for _, _, tag, inner
                   in omlibria.tag_blocks(t, ("a",), False, has)]
            self.assertEqual(got, want, t)
            new_rules, old_rules = {}, {}
            omlibria.parse_css(t, new_rules)
            text = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
            for m in re.finditer(r"([^{}@]+)\{([^{}]*)\}", text):
                omlibria.parse_css(m.group(1) + "{" + m.group(2) + "}", old_rules)
            self.assertEqual(new_rules, old_rules, t)
            self.assertEqual(omlibria.open_self_closing(t),
                             re.sub(r"<(div|span|p|a|section)([^>]*)/>", r"<\1\2></\1>", t), t)

    def test_unclosed_tags_do_not_make_scanning_quadratic(self):
        """320 KB of unclosed <body> tags took 38 s to weigh before."""
        for opener in ("<body>", "<script>", "<style>", "<"):
            path = os.path.join(self.tmp, "w.xhtml")
            with open(path, "w") as f:
                f.write(opener * 200000)
            self.assertQuick(lambda: omlibria.text_weight(path))
        self.assertQuick(lambda: omlibria.parse_css("a " * 400000 + "{" * 50000, {}))
        self.assertQuick(lambda: self.chapter("<style>" * 100000 + "<link href='x" * 100000))
        self.assertQuick(lambda: self.chapter("<div " * 100000 + ">"))

    def test_an_unclosed_navigation_document_is_read_in_linear_time(self):
        nav = "<nav epub:type='toc'>" + "<a href='ok.xhtml'>" * 100000
        make_epub(self.epub, {"OEBPS/ok.xhtml": "<p>x</p>", "OEBPS/nav.xhtml": nav},
                  opf_items=[("ok", "ok.xhtml")])
        with zipfile.ZipFile(self.epub, "a") as z:
            z.writestr("OEBPS/content.opf", OPF % (
                '<item id="ok" href="ok.xhtml" media-type="application/xhtml+xml"/>'
                '<item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>',
                '<itemref idref="ok"/>'))
        self.assertQuick(lambda: self.assertEqual(self.prepare()["error"], ""))

    def test_a_file_listed_many_times_in_the_spine_is_weighed_once(self):
        items = [("c%d" % i, "big.xhtml") for i in range(5000)]
        make_epub(self.epub, {"OEBPS/big.xhtml": "<p>%s</p>" % ("word " * 400000)}, opf_items=items)
        self.assertQuick(lambda: self.assertEqual(len(self.prepare()["spine"]), 5000), 10)

    # ---- the extracted-book cache --------------------------------------------

    def test_a_book_that_fails_to_extract_leaves_nothing_behind(self):
        make_epub(self.epub, {"OEBPS/ok.xhtml": "<p>x</p>", "OEBPS/a.bin": b"\0" * 4096})
        limit = omlibria.MAX_TOTAL_BYTES
        omlibria.MAX_TOTAL_BYTES = 1024
        try:
            with self.assertRaises(ValueError):
                self.prepare()
        finally:
            omlibria.MAX_TOTAL_BYTES = limit
        dest = os.path.join(self.cache, omlibria.book_key(self.rel, self.epub))
        self.assertFalse(os.path.exists(dest), "no partial book is left in the cache")

    def test_a_partial_extraction_from_a_stopped_run_is_cleared(self):
        make_epub(self.epub, {"OEBPS/ok.xhtml": "<p>x</p>"})
        dest = os.path.join(self.cache, omlibria.book_key(self.rel, self.epub))
        os.makedirs(os.path.join(dest, "OEBPS"))
        with open(os.path.join(dest, "OEBPS", "leftover.bin"), "wb") as f:
            f.write(b"\0" * 1000)                 # no .extracted marker: never finished
        self.assertEqual(self.prepare()["error"], "")
        self.assertFalse(os.path.exists(os.path.join(dest, "OEBPS", "leftover.bin")))

    def test_the_book_cache_drops_the_books_opened_longest_ago(self):
        names = []
        for i in range(4):
            name = "%016x" % i
            path = os.path.join(self.cache, name)
            os.makedirs(path)
            with open(os.path.join(path, "data.bin"), "wb") as f:
                f.truncate(1000)
            open(os.path.join(path, ".extracted"), "w").close()
            os.utime(os.path.join(path, ".extracted"), (100 + i, 100 + i))
            names.append(path)
        os.makedirs(os.path.join(self.cache, omlibria.COVER_DIR))
        ceiling = omlibria.MAX_BOOK_CACHE_BYTES
        omlibria.MAX_BOOK_CACHE_BYTES = 2500
        try:
            omlibria.prune_books(self.cache, keep=names[0])
        finally:
            omlibria.MAX_BOOK_CACHE_BYTES = ceiling
        left = [os.path.exists(p) for p in names]
        self.assertEqual(left, [True, False, False, True],
                         "oldest goes first, but never the book being opened")
        self.assertTrue(os.path.isdir(os.path.join(self.cache, omlibria.COVER_DIR)))

    def test_looking_for_libraries_stops_in_a_huge_home(self):
        home = os.path.join(self.tmp, "home")
        for i in range(300):
            os.makedirs(os.path.join(home, "d%03d" % i, "e"))
        saved = omlibria.HOME, omlibria.LIBRARY_SEARCH_DIRS
        omlibria.HOME, omlibria.LIBRARY_SEARCH_DIRS = home, 50
        try:
            self.assertEqual(json.loads(run(omlibria.libraries)), [])
        finally:
            omlibria.HOME, omlibria.LIBRARY_SEARCH_DIRS = saved

    # ---- covers, which come from the library rather than a book -----------

    def library_with_cover(self, data, folder="A/B (1)"):
        """A metadata.db with one book, and `data` written as its cover file."""
        self.build_db(path_value=folder)
        make_epub(os.path.join(self.library, folder, "b.epub"),
                  {"OEBPS/ok.xhtml": "<p>x</p>"})
        db = sqlite3.connect(os.path.join(self.library, "metadata.db"))
        db.execute("UPDATE books SET has_cover = 1")
        db.commit()
        db.close()
        cover = os.path.join(self.library, folder, "cover.jpg")
        with open(cover, "wb") as f:
            f.write(data)
        return cover

    def listed_cover(self):
        listing = json.loads(run(omlibria.scan, self.library, self.cache))
        self.assertEqual(listing["error"], "")
        self.assertEqual(len(listing["books"]), 1, listing)
        return listing["books"][0]["cover"]

    def test_a_cover_text_bomb_never_reaches_the_renderer(self):
        """A crafted shared library can put a bomb at cover.jpg, so covers are
        sanitized exactly as a book's own images are."""
        bomb = zlib.compress(b"A" * (20 * 1024 * 1024))
        data = self.png(chunks=[(b"zTXt", b"Comment\x00\x00" + bomb)])
        source = self.library_with_cover(data)
        served = self.listed_cover()
        self.assertTrue(served, "a sound cover is still listed")
        self.assertNotEqual(served, source, "never the library's own file")
        with open(served, "rb") as f:
            out = f.read()
        self.assertNotIn(b"zTXt", out, "the bomb must not be served")
        self.assertLess(len(out), 1024)

    def test_a_sanitized_cover_sits_in_this_readers_cache(self):
        source = self.library_with_cover(self.png())
        served = self.listed_cover()
        self.assertTrue(served.startswith(os.path.join(self.cache, omlibria.COVER_DIR) + os.sep),
                        "covers are cached where only this reader writes")
        self.assertFalse(served.startswith(self.library + os.sep),
                         "nothing is served out of the library itself")
        self.assertEqual(oct(os.stat(os.path.dirname(served)).st_mode & 0o777), "0o700")
        self.assertTrue(os.path.isfile(source))

    def test_a_cover_that_is_not_an_image_is_not_listed(self):
        """A decoder this reader does not sanitize is never handed anything."""
        for name, data in (("svg", b"<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>"),
                           ("webp", b"RIFF\x24\x00\x00\x00WEBPVP8 "),
                           ("empty", b""),
                           ("truncated png", b"\x89PNG\r\n\x1a\n")):
            self.library_with_cover(data)
            self.assertEqual(self.listed_cover(), "", name)
            os.unlink(os.path.join(self.library, "metadata.db"))

    def test_an_enormous_cover_is_not_listed(self):
        self.library_with_cover(self.png() + b"\x00" * (omlibria.MAX_IMAGE_BYTES + 1))
        self.assertEqual(self.listed_cover(), "")

    def test_a_cover_with_too_many_pixels_is_not_listed(self):
        self.library_with_cover(self.png(width=40000, height=40000))
        self.assertEqual(self.listed_cover(), "")

    def test_a_cover_is_not_read_from_outside_the_library(self):
        outside = os.path.join(self.tmp, "outside")
        os.makedirs(outside, exist_ok=True)
        with open(os.path.join(outside, "cover.jpg"), "wb") as f:
            f.write(self.png())
        self.build_db(path_value="../outside")
        self.assertEqual(json.loads(run(omlibria.scan, self.library, self.cache))["books"], [])

    def test_a_cached_cover_is_reused_rather_than_rewritten(self):
        self.library_with_cover(self.png())
        first = self.listed_cover()
        stamp = os.stat(first).st_mtime_ns
        self.assertEqual(self.listed_cover(), first, "same cover, same cached copy")
        self.assertEqual(os.stat(first).st_mtime_ns, stamp,
                         "a second scan must not rewrite every cover")

    def test_a_changed_cover_is_sanitized_again(self):
        self.library_with_cover(self.png())
        first = self.listed_cover()
        bomb = zlib.compress(b"A" * (8 * 1024 * 1024))
        path = os.path.join(self.library, "A/B (1)", "cover.jpg")
        with open(path, "wb") as f:
            f.write(self.png(chunks=[(b"zTXt", b"c\x00\x00" + bomb)], width=2, height=2))
        os.utime(path, (1, 1))
        second = self.listed_cover()
        self.assertNotEqual(second, first, "a different file gets a different copy")
        with open(second, "rb") as f:
            self.assertNotIn(b"zTXt", f.read())

    def test_the_cover_cache_has_a_ceiling(self):
        self.library_with_cover(self.png())
        folder = os.path.join(self.cache, omlibria.COVER_DIR)
        os.makedirs(folder, mode=0o700, exist_ok=True)
        with open(os.path.join(folder, "filler.png"), "wb") as f:
            f.truncate(omlibria.MAX_COVER_CACHE_BYTES)   # sparse: size without bytes
        self.assertEqual(self.listed_cover(), "",
                         "a library must not fill the disk one cover at a time")

    def test_a_sound_cached_listing_is_reused(self):
        make_epub(self.epub, {"OEBPS/ok.xhtml": "<p>x</p>"})
        first = self.prepare()
        os.unlink(os.path.join(first["dir"], "OEBPS", "content.opf"))
        again = self.prepare()
        self.assertEqual(again["spine"], first["spine"], "the cache is still used")


if __name__ == "__main__":
    unittest.main(verbosity=2)
