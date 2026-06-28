from pathlib import Path
import math

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "system_architecture_overview.png"

W, H = 2400, 1350
BG = "#f7f9fc"
INK = "#172033"
MUTED = "#5e6a7d"
LINE = "#c7d0dd"
BLUE = "#356dcc"
BLUE_DARK = "#214b94"
GREEN = "#1f8a63"
GREEN_DARK = "#136348"
ORANGE = "#d9822b"
HOST_FILL = "#eaf2ff"
FPGA_FILL = "#eaf8f1"
CARD_FILL = "#ffffff"


def font(size, bold=False):
    candidates = [
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc" if bold else "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Bold.ttc" if bold else "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
    ]
    for name in candidates:
        p = Path(name)
        if p.exists():
            return ImageFont.truetype(str(p), size)
    return ImageFont.load_default()


F_TITLE = font(54, True)
F_H1 = font(38, True)
F_H2 = font(28, True)
F_TEXT = font(24)
F_SMALL = font(19)
F_TINY = font(16)


def rounded(draw, xy, r, fill, outline=None, width=2):
    draw.rounded_rectangle(xy, radius=r, fill=fill, outline=outline, width=width)


def text_center(draw, xy, text, fnt, fill=INK, spacing=8, anchor="mm"):
    draw.multiline_text(xy, text, font=fnt, fill=fill, anchor=anchor, align="center", spacing=spacing)


def text_box(draw, xy, text, fnt, fill=INK, margin=26, spacing=7):
    x1, y1, x2, y2 = xy
    lines = text.split("\n")
    line_heights = []
    max_w = 0
    for line in lines:
        bb = draw.textbbox((0, 0), line, font=fnt)
        max_w = max(max_w, bb[2] - bb[0])
        line_heights.append(bb[3] - bb[1])
    total_h = sum(line_heights) + spacing * (len(lines) - 1)
    y = y1 + (y2 - y1 - total_h) / 2
    for line, lh in zip(lines, line_heights):
        bb = draw.textbbox((0, 0), line, font=fnt)
        x = x1 + (x2 - x1 - (bb[2] - bb[0])) / 2
        draw.text((x, y), line, font=fnt, fill=fill)
        y += lh + spacing


def arrow(draw, start, end, fill=INK, width=4, dashed=False, head=18):
    x1, y1 = start
    x2, y2 = end
    if dashed:
        dash = 18
        gap = 12
        dx = x2 - x1
        dy = y2 - y1
        length = math.hypot(dx, dy)
        if length == 0:
            return
        ux, uy = dx / length, dy / length
        pos = 0
        while pos < length - head:
            a = pos
            b = min(pos + dash, length - head)
            draw.line((x1 + ux * a, y1 + uy * a, x1 + ux * b, y1 + uy * b), fill=fill, width=width)
            pos += dash + gap
    else:
        draw.line((x1, y1, x2, y2), fill=fill, width=width)
    ang = math.atan2(y2 - y1, x2 - x1)
    pts = [
        (x2, y2),
        (x2 - head * math.cos(ang - math.pi / 6), y2 - head * math.sin(ang - math.pi / 6)),
        (x2 - head * math.cos(ang + math.pi / 6), y2 - head * math.sin(ang + math.pi / 6)),
    ]
    draw.polygon(pts, fill=fill)


def flow(draw, boxes, color, fill):
    for i, (x, y, w, h, label) in enumerate(boxes):
        rounded(draw, (x, y, x + w, y + h), 18, fill, color, 3)
        text_box(draw, (x + 10, y + 8, x + w - 10, y + h - 8), label, F_TEXT)
        if i < len(boxes) - 1:
            nx = boxes[i + 1][0]
            arrow(draw, (x + w + 8, y + h / 2), (nx - 16, y + h / 2), color, 4, False, 16)


def draw_server(draw):
    x, y, w, h = 95, 250, 650, 820
    rounded(draw, (x, y, x + w, y + h), 26, "#ffffff", "#a9b4c3", 4)
    draw.rectangle((x + 36, y + 52, x + w - 36, y + h - 52), fill="#f0f4f8", outline="#c6d0dd", width=2)
    text_center(draw, (x + w / 2, y + 58), "服务器 / 主机", F_H1)

    # Rack ears and front slots
    draw.rectangle((x - 25, y + 145, x, y + h - 145), fill="#dce4ee", outline="#aeb9c8", width=2)
    draw.rectangle((x + w, y + 145, x + w + 25, y + h - 145), fill="#dce4ee", outline="#aeb9c8", width=2)
    for row in range(4):
        yy = y + 165 + row * 68
        rounded(draw, (x + 74, yy, x + 312, yy + 42), 7, "#ffffff", "#b8c3d0", 2)
        draw.ellipse((x + 92, yy + 13, x + 108, yy + 29), fill="#3ac47d")
        draw.line((x + 132, yy + 21, x + 284, yy + 21), fill="#ccd4df", width=5)

    # Host compute block
    rounded(draw, (x + 355, y + 145, x + 575, y + 330), 18, "#eaf2ff", BLUE, 3)
    text_center(draw, (x + 465, y + 205), "HOST", F_H2, BLUE_DARK)
    for i, label in enumerate(["SSD", "内存"]):
        rounded(draw, (x + 382 + i * 92, y + 238, x + 452 + i * 92, y + 292), 8, "#ffffff", "#9fb4d4", 2)
        text_center(draw, (x + 417 + i * 92, y + 265), label, F_SMALL)

    # PCIe lane
    draw.line((x + 245, y + 525, x + 520, y + 525), fill="#97a4b5", width=10)
    text_center(draw, (x + 382, y + 555), "PCIe", F_SMALL, MUTED)

    # FPGA card
    card = (x + 190, y + 585, x + 560, y + 785)
    rounded(draw, card, 18, "#eaf8f1", GREEN, 4)
    draw.rectangle((card[0] - 34, card[1] + 60, card[0], card[1] + 140), fill="#c5ccd6", outline="#8d98a8", width=2)
    text_center(draw, ((card[0] + card[2]) / 2, card[1] + 50), "FPGA加速卡", F_H2, GREEN_DARK)
    for i in range(3):
        rounded(draw, (card[0] + 36 + i * 97, card[1] + 93, card[0] + 103 + i * 97, card[1] + 151), 10, "#ffffff", "#9bd0bb", 2)
    draw.line((card[0] + 38, card[1] + 174, card[2] - 42, card[1] + 174), fill=GREEN, width=7)
    text_center(draw, ((card[0] + card[2]) / 2, card[1] + 185), "DDR / CMAC / 控制逻辑", F_SMALL, GREEN_DARK)

    # Optical egress
    arrow(draw, (card[2] + 18, card[1] + 100), (x + w + 85, card[1] + 100), GREEN, 5, False, 20)
    text_center(draw, (x + w + 115, card[1] + 100), "100G\n出口", F_SMALL, GREEN_DARK)

    return {
        "host": (x + 465, y + 238),
        "fpga": ((card[0] + card[2]) / 2, card[1] + 92),
    }


def main():
    img = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(img)

    draw.text((90, 62), "流量回放系统总体架构", font=F_TITLE, fill=INK)
    draw.text((92, 132), "PCAP 场景处理在 HOST 侧完成，高精度定时与发包在 FPGA 侧完成", font=F_TEXT, fill=MUTED)

    anchors = draw_server(draw)

    # Right side panels
    rx, rw = 875, 1430
    uy, uh = 210, 455
    ly, lh = 735, 455

    rounded(draw, (rx, uy, rx + rw, uy + uh), 28, "#ffffff", "#b8c6d8", 3)
    rounded(draw, (rx + 22, uy + 22, rx + rw - 22, uy + uh - 22), 24, HOST_FILL, "#d3e2f7", 1)
    draw.text((rx + 48, uy + 42), "HOST：PCAP 处理与缓存调度", font=F_H1, fill=BLUE_DARK)

    rounded(draw, (rx, ly, rx + rw, ly + lh), 28, "#ffffff", "#b8c6d8", 3)
    rounded(draw, (rx + 22, ly + 22, rx + rw - 22, ly + lh - 22), 24, FPGA_FILL, "#cce8da", 1)
    draw.text((rx + 48, ly + 42), "FPGA：高速装载、高精度回放、100G 发包", font=F_H1, fill=GREEN_DARK)

    # Dashed ownership arrows
    arrow(draw, (rx + 4, uy + 118), (anchors["host"][0] + 72, anchors["host"][1]), BLUE, 4, True, 18)
    text_center(draw, (806, uy + 104), "运行在\nHOST", F_SMALL, BLUE_DARK)
    arrow(draw, (rx + 4, ly + 118), (anchors["fpga"][0] + 160, anchors["fpga"][1]), GREEN, 4, True, 18)
    text_center(draw, (806, ly + 104), "运行在\nFPGA", F_SMALL, GREEN_DARK)

    # Host flow
    host_boxes = [
        (rx + 70, uy + 162, 210, 118, "原始\nPCAP"),
        (rx + 335, uy + 162, 245, 118, "依赖图\n构建"),
        (rx + 635, uy + 162, 265, 118, "场景编辑\nIP / 链路"),
        (rx + 955, uy + 162, 285, 118, "一致性传播\n校验"),
    ]
    flow(draw, host_boxes, BLUE, "#ffffff")
    rounded(draw, (rx + 280, uy + 325, rx + 1220, uy + 395), 18, "#ffffff", "#a9bbd5", 2)
    text_center(draw, (rx + 750, uy + 360), "动态缓存：HOST SSD  →  HOST 内存  →  FPGA DDR", F_TEXT, BLUE_DARK)

    # FPGA flow
    fpga_boxes = [
        (rx + 85, ly + 160, 285, 120, "接收/装载\nTrace 分片"),
        (rx + 445, ly + 160, 285, 120, "DDR 队列\n循环/预加载"),
        (rx + 805, ly + 160, 285, 120, "时间戳调度\n间隔控制"),
        (rx + 1165, ly + 160, 120, 120, "CMAC\n100G"),
    ]
    flow(draw, fpga_boxes, GREEN, "#ffffff")
    rounded(draw, (rx + 225, ly + 325, rx + 1110, ly + 395), 18, "#ffffff", "#aad2c0", 2)
    text_center(draw, (rx + 667, ly + 360), "控制面选择：预加载模式 / 主机流式模式 / DDR 循环模式", F_TEXT, GREEN_DARK)

    # Small mode badge between layers
    rounded(draw, (rx + 515, 668, rx + 1115, 724), 16, "#fff8ed", "#e3ad6a", 2)
    text_center(draw, (rx + 815, 696), "命令行控制：装载、启动、停止、状态读取", F_SMALL, ORANGE)

    # Main data direction
    arrow(draw, (760, 665), (845, 665), "#7b8798", 5, False, 18)
    text_center(draw, (802, 628), "协同", F_SMALL, MUTED)

    # Bottom caption
    draw.text((94, 1240), "抽象层次：左侧表示一台服务器中插入 FPGA 加速卡；右侧只展示两条主路径，不展开具体 IP 核和寄存器细节。", font=F_SMALL, fill=MUTED)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT, quality=95)
    print(OUT)


if __name__ == "__main__":
    main()
