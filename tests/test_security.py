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
import sqlite3
import sys
import tempfile
import unittest
import zipfile

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
        listing = json.loads(run(omlibria.scan, self.library))
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
        result = json.loads(run(omlibria.scan, self.library))
        self.assertIn("larger than", result["error"])
        self.assertEqual(result["books"], [])

    def test_too_many_books_is_refused(self):
        # One EPUB row and no author links, so the books cap is the bound that fires.
        self.build_db(books=5, authors_per_book=0, epub_rows=1)
        omlibria.MAX_BOOKS = 3
        try:
            result = json.loads(run(omlibria.scan, self.library))
        finally:
            omlibria.MAX_BOOKS = 20000
        self.assertIn("more books", result["error"])
        self.assertEqual(result["books"], [])

    def test_too_many_author_rows_is_refused(self):
        self.build_db(books=3, authors_per_book=3)
        omlibria.MAX_LINK_ROWS = 4
        try:
            result = json.loads(run(omlibria.scan, self.library))
        finally:
            omlibria.MAX_LINK_ROWS = 200000
        self.assertIn("author entries", result["error"])
        self.assertEqual(result["books"], [])

    def test_long_text_is_truncated_by_sqlite_not_held_in_memory(self):
        huge = "T" * (2 * 1024 * 1024)
        self.build_db(title=huge, author=huge)
        make_epub(os.path.join(self.library, "A", "B (1)", "b.epub"), {"OEBPS/ok.xhtml": "<p>x</p>"})
        result = json.loads(run(omlibria.scan, self.library))
        self.assertEqual(result["error"], "")
        book = result["books"][0]
        self.assertLessEqual(len(book["title"]), omlibria.MAX_TEXT)
        self.assertLessEqual(len(book["authors"]), omlibria.MAX_TEXT + 8)

    def test_authors_per_book_are_capped(self):
        self.build_db(books=1, authors_per_book=50, author="A" * 50)
        make_epub(os.path.join(self.library, "A", "B (1)", "b.epub"), {"OEBPS/ok.xhtml": "<p>x</p>"})
        result = json.loads(run(omlibria.scan, self.library))
        self.assertEqual(result["error"], "")
        listed = result["books"][0]["authors"].split(", ")
        self.assertLessEqual(len(listed), omlibria.MAX_AUTHORS_PER_BOOK)

    def test_a_slow_library_hits_the_query_deadline(self):
        self.build_db(books=200, authors_per_book=2)
        omlibria.SCAN_SECONDS = 0.0                      # the deadline has already passed
        try:
            result = json.loads(run(omlibria.scan, self.library))
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
