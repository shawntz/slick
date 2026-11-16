#!/usr/bin/env python3
"""Writes and checks appcast.xml, the feed Sparkle reads to find a new version.

    appcast.py write key=value...   write the feed for one release
    appcast.py check key=value...   check a feed, and print its signature on success

Keys for write: output, name, version, build, minimum (the oldest macOS, such as 26.0), url,
length, signature, notes (a file with the changelog section in Markdown), date (optional, as
"Sun, 15 Nov 2026 21:00:00 +0000"; default now) and hardware (optional, such as arm64).

Keys for check: appcast, and every write key but output, notes and date, each the value the feed
must carry. check makes sure the file is well-formed XML with one channel and one item, and that
every field is present and equal to what was given. It prints the item's signature, so the caller
can verify it against the public key with scripts/update-signature.swift.

The feed has one item, in the elements Sparkle 2.9.6 documents in SUAppcastItem.h and its
SampleAppcast.xml: title, pubDate, sparkle:version (the build number), sparkle:shortVersionString,
sparkle:minimumSystemVersion, sparkle:hardwareRequirements, a description in HTML, and an enclosure
with url, length, type and sparkle:edSignature. The description names no format. SUAppcastItem.h
calls the attribute sparkle:descriptionFormat while Sparkle's parser reads sparkle:format, and both
read a description without one as HTML.

The release notes become plain HTML: headings, paragraphs, lists, inline code and https links.
Every character of the changelog's text is escaped, so markup in a note shows as text and never
reaches the release notes window as HTML. A link that is not http or https shows as its text.

Standard library only. It makes no network request.
"""

import base64
import datetime
import email.utils
import html
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def fail(message):
    sys.exit("appcast: " + message)


def sparkle(name):
    return "{%s}%s" % (SPARKLE, name)


def parse_pairs(pairs):
    values = {}
    for pair in pairs:
        key, sep, value = pair.partition("=")
        if not sep:
            fail("expected key=value, got " + pair)
        values[key] = value
    return values


def need(values, key):
    if key not in values or values[key] == "":
        fail("no %s given" % key)
    return values[key]


def system_version(text):
    """Sparkle wants three parts, such as 26.0.0."""
    parts = text.split(".")
    if not 1 <= len(parts) <= 3 or not all(part.isdigit() for part in parts):
        fail("the oldest macOS %r is not a version such as 26.0" % text)
    return ".".join(parts + ["0"] * (3 - len(parts)))


def is_rfc822(date):
    """True for a date as RSS and Sparkle write it, such as "Sun, 15 Nov 2026 21:00:00 +0000"."""
    try:
        return email.utils.parsedate_to_datetime(date) is not None
    except (TypeError, ValueError):
        return False


def check_inputs(values):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", need(values, "version")):
        fail("the version %r is not X.Y.Z" % values["version"])
    if not re.fullmatch(r"[1-9][0-9]*", need(values, "build")):
        fail("the build number %r is not a positive number" % values["build"])
    if not need(values, "url").startswith("https://"):
        fail("the download address does not use https")
    if not re.fullmatch(r"[1-9][0-9]*", need(values, "length")):
        fail("the length %r is not a positive number of bytes" % values["length"])
    try:
        signature = base64.b64decode(need(values, "signature"), validate=True)
    except ValueError:
        signature = b""
    if len(signature) != 64:
        fail("the signature is not base64 of 64 bytes")


# --- Release notes -------------------------------------------------------------------------------

# Inline code, or a link whose target may hold one level of parentheses.
INLINE = re.compile(r"`([^`]+)`|\[([^\]]+)\]\(((?:[^()\s]|\([^()\s]*\))+)\)")


def inline(text):
    """Escapes every character of a line of Markdown, keeping inline code and http(s) links."""
    out = []
    position = 0
    for match in INLINE.finditer(text):
        out.append(html.escape(text[position:match.start()], quote=True))
        code, label, target = match.groups()
        if code is not None:
            out.append("<code>%s</code>" % html.escape(code, quote=True))
        elif re.match(r"https?://", target):
            out.append('<a href="%s">%s</a>' % (html.escape(target, quote=True), html.escape(label, quote=True)))
        else:
            out.append(html.escape(label, quote=True))
        position = match.end()
    out.append(html.escape(text[position:], quote=True))
    return "".join(out)


def notes_html(markdown):
    """Headings, paragraphs and lists of a changelog section, as HTML."""
    out = []
    paragraph = []
    items = []

    def flush_paragraph():
        if paragraph:
            out.append("<p>%s</p>" % inline(" ".join(paragraph)))
            paragraph.clear()

    def flush_items():
        if items:
            out.append("<ul>%s</ul>" % "".join("<li>%s</li>" % inline(" ".join(item)) for item in items))
            items.clear()

    for raw in markdown.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped:
            flush_paragraph()
            flush_items()
            continue
        heading = re.match(r"#{1,6}\s+(.*)", stripped)
        bullet = re.match(r"[-*]\s+(.*)", stripped)
        if heading:
            flush_paragraph()
            flush_items()
            out.append("<h3>%s</h3>" % inline(heading.group(1)))
        elif bullet and not line.startswith("  "):
            flush_paragraph()
            items.append([bullet.group(1)])
        elif items and line.startswith(" "):
            items[-1].append(stripped)
        else:
            flush_items()
            paragraph.append(stripped)
    flush_paragraph()
    flush_items()
    return "\n".join(out)


# --- Write ---------------------------------------------------------------------------------------


def write(values):
    check_inputs(values)
    output = need(values, "output")
    with open(need(values, "notes"), encoding="utf-8") as handle:
        notes = notes_html(handle.read())
    if not notes:
        fail("the release notes are empty")
    date = values.get("date") or email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
    if not is_rfc822(date):
        fail("the date %r is not an RFC 822 date" % date)

    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = need(values, "name")
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "Version %s" % values["version"]
    ET.SubElement(item, "pubDate").text = date
    ET.SubElement(item, sparkle("version")).text = values["build"]
    ET.SubElement(item, sparkle("shortVersionString")).text = values["version"]
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = system_version(need(values, "minimum"))
    # An app without an Intel slice must not be offered to an Intel Mac.
    if values.get("hardware"):
        ET.SubElement(item, sparkle("hardwareRequirements")).text = values["hardware"]
    # No format attribute: Sparkle reads a description without one as HTML.
    ET.SubElement(item, "description").text = notes
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": values["url"],
            "length": values["length"],
            "type": "application/octet-stream",
            sparkle("edSignature"): values["signature"],
        },
    )
    ET.indent(rss)
    ET.ElementTree(rss).write(output, encoding="utf-8", xml_declaration=True)


# --- Check ---------------------------------------------------------------------------------------


def check(values):
    path = need(values, "appcast")
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as error:
        fail("%s is not well-formed XML: %s" % (path, error))
    problems = []

    def same(what, actual, wanted):
        if actual != wanted:
            problems.append("%s is %r, expected %r" % (what, actual, wanted))

    same("the root element", root.tag, "rss")
    same("the rss version", root.get("version"), "2.0")
    channels = root.findall("channel")
    if len(channels) != 1:
        fail("expected one channel, found %d" % len(channels))
    items = channels[0].findall("item")
    if len(items) != 1:
        fail("expected one item, found %d" % len(items))
    item = items[0]

    def text(tag):
        found = item.findall(tag)
        if len(found) != 1:
            problems.append("expected one %s, found %d" % (tag, len(found)))
            return None
        return (found[0].text or "").strip()

    same("the channel's title", (channels[0].findtext("title") or "").strip(), need(values, "name"))
    same("the item's title", text("title"), "Version %s" % need(values, "version"))
    date = text("pubDate")
    if date is not None and not is_rfc822(date):
        problems.append("pubDate %r is not an RFC 822 date" % date)
    same("sparkle:version", text(sparkle("version")), need(values, "build"))
    same("sparkle:shortVersionString", text(sparkle("shortVersionString")), values["version"])
    same("sparkle:minimumSystemVersion", text(sparkle("minimumSystemVersion")), system_version(need(values, "minimum")))
    hardware = item.findall(sparkle("hardwareRequirements"))
    same(
        "sparkle:hardwareRequirements",
        (hardware[0].text or "").strip() if hardware else "",
        values.get("hardware", ""),
    )
    descriptions = item.findall("description")
    if len(descriptions) != 1 or not (descriptions[0].text or "").strip():
        problems.append("expected one description with the release notes")
    else:
        same("the description's attributes", dict(descriptions[0].attrib), {})
        if re.search(r"<\s*(script|style|iframe|img|object)", descriptions[0].text, re.IGNORECASE):
            problems.append("the release notes carry markup other than text, lists and links")
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        fail("expected one enclosure, found %d" % len(enclosures))
    enclosure = enclosures[0]
    same("the enclosure's url", enclosure.get("url"), need(values, "url"))
    same("the enclosure's length", enclosure.get("length"), need(values, "length"))
    same("the enclosure's type", enclosure.get("type"), "application/octet-stream")
    signature = enclosure.get(sparkle("edSignature")) or ""
    try:
        decoded = base64.b64decode(signature, validate=True)
    except ValueError:
        decoded = b""
    if len(decoded) != 64:
        problems.append("the enclosure's sparkle:edSignature is not base64 of 64 bytes")
    if values.get("signature"):
        same("the enclosure's sparkle:edSignature", signature, values["signature"])
    if problems:
        for problem in problems:
            print("appcast: " + problem, file=sys.stderr)
        sys.exit(1)
    print(signature)


def main(argv):
    if len(argv) < 2 or argv[1] not in ("write", "check"):
        fail("usage: appcast.py write|check key=value...")
    values = parse_pairs(argv[2:])
    if argv[1] == "write":
        write(values)
    else:
        check(values)


if __name__ == "__main__":
    main(sys.argv)
