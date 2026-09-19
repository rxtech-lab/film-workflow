"""Analyze generated sprite bounds and write anchors; never modify the artwork."""
from pathlib import Path
import json
from PIL import Image

root = Path(__file__).resolve().parents[1] / 'Sources/RxPet/Resources'
image = Image.open(root / 'camera-atlas.webp').convert('RGBA')
w, h = image.size
coverage = [sum(image.getpixel((x, y))[3] > 128 for x in range(w)) for y in range(h)]
def runs(values, threshold):
    result, start = [], None
    for i, n in enumerate(values + [0]):
        if n > threshold and start is None: start = i
        if n <= threshold and start is not None: result.append((start, i)); start = None
    return result
rows = runs(coverage, 20)
assert len(rows) == 8, rows
bounds = [0] + [(rows[i-1][1] + rows[i][0]) // 2 for i in range(1, 8)] + [h]
columns = runs([sum(image.getpixel((x,y))[3] > 200 for y in range(*rows[0])) for x in range(w)], 5)
assert len(columns) == 6, columns
xbounds = [0] + [(columns[i-1][1] + columns[i][0]) // 2 for i in range(1, 6)] + [w]
frames = []
timing = [
    [2.4, .18, .28, .22, .3, 1.2],  # A relaxed blink, then a long neutral hold.
    [.5, .3, .35, .3, .35, .6],
    [1.0, .4, .4, .4, .4, 1.0],
    [.7, .6, .7, .6, .7, .8],
    [.4, .3, .35, .3, .35, .7],
    [.3, .3, .3, .3, .3, .3],
    [.35, .35, .4, .4, .35, .8],
    [1.0, .35, .35, .35, .35, 1.5],
]
for row in range(8):
    for column in range(6):
        x0, x1 = xbounds[column:column + 2]
        y0, y1 = bounds[row:row + 2]
        points = [(x, y) for y in range(y0 + int((y1-y0)*.27), y0 + int((y1-y0)*.8))
                  for x in range(x0 + int((x1-x0)*.4), x0 + int((x1-x0)*.82))
                  if (lambda c: c[3] > 200 and c[0] < 24 and c[1] < 35 and 20 < c[2] < 95)(image.getpixel((x, y)))]
        cx = sum(p[0] for p in points) / len(points)
        cy = sum(p[1] for p in points) / len(points)
        frames.append(dict(x=x0, y=y0, width=x1-x0, height=y1-y0,
                           faceX=round(cx-x0, 2), faceY=round(cy-y0, 2), faceSize=44, duration=timing[row][column]))
(root / 'camera-animation.json').write_text(json.dumps(dict(version=1, frameWidth=200, frameHeight=210, frames=frames), indent=2))
print('Registered 48 frames; row bounds:', bounds)
