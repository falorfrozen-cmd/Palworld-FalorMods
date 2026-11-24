import sys
from PIL import Image, ImageDraw, ImageFont

out = sys.argv[1]
S = 512
img = Image.new("RGB", (S, S), (9, 16, 24))
d = ImageDraw.Draw(img)

def font(name, size):
    return ImageFont.truetype("C:/Windows/Fonts/" + name, size)

big = font("segoeuib.ttf", 60)
mid = font("segoeuib.ttf", 30)
row = font("segoeui.ttf", 19)
small = font("segoeui.ttf", 19)

d.rectangle([14, 14, S - 15, S - 15], outline=(60, 170, 200), width=3)
d.text((S // 2, 62), "FALOR'S", font=big, fill=(235, 245, 250), anchor="mm")
d.text((S // 2, 122), "QoL PACK", font=big, fill=(90, 200, 230), anchor="mm")
d.text((S // 2, 172), "12 mods in one subscription", font=small, fill=(240, 190, 60), anchor="mm")

left = ["Unlock All Waypoints", "Unlock All Technology", "Boss Respawn", "Big Inventory", "Global Base Storage", "Pickup Boost"]
right = ["Fast Breeding", "Speed Boost", "Time of Day", "Teleport to Player", "Salvage With Any Pal", "Unlock All Blueprints"]
y0, step = 206, 40
for i, t in enumerate(left):
    y = y0 + i * step
    d.rounded_rectangle([34, y, 250, y + 31], radius=6, fill=(20, 34, 46), outline=(50, 80, 100), width=1)
    d.text((142, y + 15), t, font=row, fill=(225, 235, 242), anchor="mm")
for i, t in enumerate(right):
    y = y0 + i * step
    d.rounded_rectangle([262, y, 478, y + 31], radius=6, fill=(20, 34, 46), outline=(50, 80, 100), width=1)
    d.text((370, y + 15), t, font=row, fill=(225, 235, 242), anchor="mm")

d.text((S // 2, 470), "Each one has its own page in Mod Options", font=small, fill=(170, 195, 210), anchor="mm")
img.save(out, optimize=True)
print("saved", out)
