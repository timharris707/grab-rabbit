#!/usr/bin/env python3
import re
import sys
import xml.etree.ElementTree as ET

from reportlab import rl_config
from reportlab.pdfgen import canvas


class VectorCanvas(canvas.Canvas):
    """Create vector-only pages without ReportLab's unused default font resource."""

    def _make_preamble(self) -> None:
        self._preamble = "1 0 0 1 0 0 cm"


def draw_svg_path(target: canvas.Canvas, data: str, even_odd: bool) -> None:
    tokens = re.findall(r"[MLHVCSZ]|-?\d+(?:\.\d+)?", data)
    path = target.beginPath()
    index = 0
    command = ""
    current_x = 0.0
    current_y = 0.0
    start_x = 0.0
    start_y = 0.0

    while index < len(tokens):
        token = tokens[index]
        if token.isalpha():
            command = token
            index += 1
            if command == "Z":
                path.close()
                current_x = start_x
                current_y = start_y
                continue

        if command == "M":
            current_x = float(tokens[index])
            current_y = float(tokens[index + 1])
            start_x = current_x
            start_y = current_y
            path.moveTo(current_x, current_y)
            index += 2
            command = "L"
        elif command == "L":
            current_x = float(tokens[index])
            current_y = float(tokens[index + 1])
            path.lineTo(current_x, current_y)
            index += 2
        elif command == "H":
            current_x = float(tokens[index])
            path.lineTo(current_x, current_y)
            index += 1
        elif command == "V":
            current_y = float(tokens[index])
            path.lineTo(current_x, current_y)
            index += 1
        elif command == "C":
            values = [float(value) for value in tokens[index : index + 6]]
            path.curveTo(*values)
            current_x = values[4]
            current_y = values[5]
            index += 6
        elif command == "S":
            raise ValueError("Smooth curves are not supported in the canonical SVG")
        else:
            raise ValueError(f"Unsupported SVG path command: {command}")

    target.drawPath(path, stroke=0, fill=1, fillMode=0 if even_odd else 1)


def main() -> None:
    source, output = sys.argv[1:]
    root = ET.parse(source).getroot()

    rl_config.useA85 = 0
    pdf = VectorCanvas(output, pagesize=(18, 18), pageCompression=1, invariant=1)
    pdf.setAuthor("Grab Rabbit")
    pdf.setTitle("Grab Rabbit status-item vector template")
    pdf.setFillColorRGB(0, 0, 0)
    pdf.translate(0, 18)
    pdf.scale(18 / 1024, -18 / 1024)

    for element in root.iter("{http://www.w3.org/2000/svg}path"):
        draw_svg_path(pdf, element.attrib["d"], element.attrib.get("fill-rule") == "evenodd")

    pdf.showPage()
    pdf.save()


if __name__ == "__main__":
    main()
