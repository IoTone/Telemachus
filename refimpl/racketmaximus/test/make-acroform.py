#!/usr/bin/env python3
"""Write a minimal PDF carrying AcroForm fields, for the #88 req 2 smoke block.

HAND-BUILT, not produced by pdfcpu's own `create`: a form filled by the same
program that wrote it proves only that the program agrees with itself, and the
documents `doc_fill_form` exists for come out of Acrobat, LibreOffice and a
government website. The same argument, and the same four fields, as the fixture
in test/pdfform-tests.rkt — this copy exists because the smoke drives the
platform over HTTP and has no Racket to hand. Two fixtures, not two rules: the
rule they exercise lives in domain/repo/pdfform.rkt.

The checkbox carries its /AP appearance dictionary, without which nothing can
toggle it (the engine refuses by name, which the unit suite asserts).

    python3 -I test/make-acroform.py out.pdf
    python3 -I test/make-acroform.py --plain out.pdf   # the same shape, no form

`--plain` is the other half of the discovery contract: a PDF with no AcroForm at
all, which the endpoint must answer with an EMPTY LIST rather than an error —
whether a document is a form is exactly the question being asked. A document
that is not a PDF is the third case and is a 400, because those are two
different mistakes.
"""
import sys

def assemble(objs):
    out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offs = []
    for n, body in objs:
        offs.append((n, len(out)))
        out += b"%d 0 obj\n" % n + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n" % (len(objs) + 1)
    out += b"0000000000 65535 f \n"
    for _n, at in offs:
        out += b"%010d 00000 n \n" % at
    out += (b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
            % (len(objs) + 1, xref))
    return bytes(out)


def stream(dict_src, body):
    return (("<< %s /Length %d >>\nstream\n" % (dict_src, len(body))).encode()
            + body + b"\nendstream")


def build_plain():
    return assemble([
        (1, b"<< /Type /Catalog /Pages 2 0 R >>"),
        (2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
        (3, b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources "
            b"<< /Font << /Helv 4 0 R >> >> /Contents 5 0 R >>"),
        (4, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        (5, stream("", b"BT /Helv 12 Tf 60 700 Td (an ordinary PDF, not a form) Tj ET\n")),
    ])


def build():
    off_ap = b"q 1 1 12 12 re W n Q"
    on_ap = b"q BT /ZaDb 10 Tf 0 g 2 2 Td (4) Tj ET Q"

    def text_field(name, y):
        return ("<< /Type /Annot /Subtype /Widget /FT /Tx /T (%s) /V () "
                "/Rect [120 %d 400 %d] /F 4 /DA (/Helv 11 Tf 0 g) /P 3 0 R "
                "/MK << /BC [0 0 0] >> >>" % (name, y, y + 20)).encode()

    content = (b"BT /Helv 16 Tf 60 700 Td (Acme Service Request) Tj ET\n"
               b"BT /Helv 11 Tf 60 606 Td (Applicant) Tj ET\n"
               b"BT /Helv 11 Tf 60 566 Td (Reference) Tj ET\n"
               b"BT /Helv 11 Tf 60 522 Td (Urgent) Tj ET\n"
               b"BT /Helv 11 Tf 60 476 Td (Region) Tj ET\n")

    objs = [
        (1, b"<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R 6 0 R 7 0 R 8 0 R] "
            b"/DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R /ZaDb 11 0 R >> >> "
            b"/NeedAppearances true >> >>"),
        (2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
        (3, b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources "
            b"<< /Font << /Helv 4 0 R /ZaDb 11 0 R >> >> /Contents 9 0 R "
            b"/Annots [5 0 R 6 0 R 7 0 R 8 0 R] >>"),
        (4, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        (5, text_field("applicant", 600)),
        (6, text_field("reference", 560)),
        (7, b"<< /Type /Annot /Subtype /Widget /FT /Btn /T (urgent) /V /Off /AS /Off "
            b"/Rect [120 520 134 534] /F 4 /DA (/ZaDb 0 Tf 0 g) /P 3 0 R "
            b"/MK << /BC [0 0 0] /CA (4) >> /AP << /N << /Off 10 0 R /Yes 12 0 R >> >> >>"),
        (8, b"<< /Type /Annot /Subtype /Widget /FT /Ch /T (region) /V (emea) "
            b"/Opt [(amer) (emea) (apac)] /Rect [120 470 300 490] /F 4 /Ff 131072 "
            b"/DA (/Helv 11 Tf 0 g) /P 3 0 R >>"),
        (9, stream("", content)),
        (10, stream("/Type /XObject /Subtype /Form /BBox [0 0 14 14] "
                    "/Resources << /Font << /ZaDb 11 0 R >> >>", off_ap)),
        (11, b"<< /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats >>"),
        (12, stream("/Type /XObject /Subtype /Form /BBox [0 0 14 14] "
                    "/Resources << /Font << /ZaDb 11 0 R >> >>", on_ap)),
    ]

    return assemble(objs)


if __name__ == "__main__":
    args = sys.argv[1:]
    plain = "--plain" in args
    path = [a for a in args if not a.startswith("--")][0]
    open(path, "wb").write(build_plain() if plain else build())
