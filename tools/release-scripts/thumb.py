import sys
from PIL import Image, ImageDraw, ImageFont

out = sys.argv[1]
S = 512
img = Image.new("RGB", (S, S), (9, 16, 24))
d = ImageDraw.Draw(img)

def font(name, size):
    return ImageFont.truetype("C:/Windows/Fonts/" + name, size)

bold = font("segoeuib.ttf", 58)
mid = font("segoeuib.ttf", 24)
small = font("segoeui.ttf", 21)

# frame
d.rectangle([14, 14, S - 15, S - 15], outline=(60, 170, 200), width=3)

# title
d.text((S // 2, 78), "PASSIVE", font=bold, fill=(235, 245, 250), anchor="mm")
d.text((S // 2, 140), "TRANSFER", font=bold, fill=(90, 200, 230), anchor="mm")

# two pal cards with passive rows
def card(x, title, rows, hi):
    d.rounded_rectangle([x, 200, x + 190, 420], radius=10, fill=(20, 34, 46), outline=(50, 80, 100), width=2)
    d.text((x + 95, 224), title, font=mid, fill=(235, 245, 250), anchor="mm")
    for i, on in enumerate(rows):
        y = 250 + i * 40
        fill = (240, 190, 60) if i == hi else ((46, 70, 88) if on else (26, 42, 56))
        d.rounded_rectangle([x + 14, y, x + 176, y + 30], radius=6, fill=fill)

card(36, "Pal A", [True, True, True, False], None)
card(286, "Pal B", [True, True, True, True], 3)

# the moved passive: empty dashed slot on A, arrow to B
d.rounded_rectangle([50, 370, 212, 400], radius=6, outline=(240, 190, 60), width=2)
ay = 385
d.line([(232, ay), (270, ay)], fill=(240, 190, 60), width=6)
d.polygon([(268, ay - 14), (286, ay), (268, ay + 14)], fill=(240, 190, 60))

d.text((S // 2, 462), "Move a passive. The giver loses it.", font=small, fill=(170, 195, 210), anchor="mm")

img.save(out, optimize=True)
print("saved", out, img.size)
