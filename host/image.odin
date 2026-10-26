// Screenshots cropped to an element (takeScreenshot and assertScreenshot `cropOn`), and
// assertScreenshot's comparison: a pixel matches when its RGB distance is within 10% of the
// largest. Codecs: image/image.c (stb).
package speedrun

import "core:c"
import "core:fmt"
import "core:math"
import "core:slice"

// build.sh compiles it.
foreign import image_lib "image/build/libspeedrunimage.a"

@(default_calling_convention = "c", private = "file")
foreign image_lib {
	sr_image_decode :: proc(data: [^]u8, len: c.int, width, height: ^c.int) -> [^]u8 ---
	sr_image_png :: proc(rgba: [^]u8, width, height: c.int, len: ^c.int) -> [^]u8 ---
	sr_image_free :: proc(p: rawptr) ---
}

Image :: struct {
	pixels:        []u8, // RGBA, rows top to bottom, in context.allocator
	width, height: int,
}

image_decode :: proc(data: []byte) -> (img: Image, ok: bool) {
	if len(data) == 0 do return
	w, h: c.int
	p := sr_image_decode(raw_data(data), c.int(len(data)), &w, &h)
	if p == nil do return
	defer sr_image_free(p)
	return {slice.clone(p[:int(w) * int(h) * 4]), int(w), int(h)}, true
}

image_free :: proc(img: Image) {
	delete(img.pixels)
}

// A PNG of img, in `alloc`.
image_png :: proc(img: Image, alloc := context.allocator) -> (png: []byte, ok: bool) {
	n: c.int
	p := sr_image_png(raw_data(img.pixels), c.int(img.width), c.int(img.height), &n)
	if p == nil do return
	defer sr_image_free(p)
	return slice.clone(p[:n], alloc), true
}

// The crop: bounds in the hierarchy's units (points on iOS), scaled by
// the screenshot's height over the display's, clamped to the image. A new image.
image_crop :: proc(img: Image, left, top, right, bottom: i32, display_height: i32) -> (out: Image, err: Err) {
	scale := f64(img.height) / f64(display_height) if display_height > 0 else 1
	x := clamp(int(f64(left) * scale), 0, img.width)
	y := clamp(int(f64(top) * scale), 0, img.height)
	w := clamp(int(f64(right - left) * scale), 0, img.width - x)
	h := clamp(int(f64(bottom - top) * scale), 0, img.height - y)
	if w <= 0 || h <= 0 do return {}, fmt.aprintf("Cannot crop screenshot: invalid dimensions (width: %d, height: %d).", w, h)
	pixels := make([]u8, w * h * 4)
	for row in 0 ..< h {
		copy(pixels[row * w * 4:][:w * 4], img.pixels[((y + row) * img.width + x) * 4:][:w * 4])
	}
	return {pixels, w, h}, nil
}

// The share of pixels equal, or within the tolerance.
image_match_percent :: proc(expected, actual: Image, diff: ^[dynamic]bool = nil) -> f64 {
	total := expected.width * expected.height
	if total == 0 do return 100
	limit := math.pow(0.1 * math.sqrt(f64(255 * 255 * 3)), 2)
	if diff != nil do resize(diff, total)
	differing := 0
	for i in 0 ..< total {
		e, a := expected.pixels[i * 4:][:4], actual.pixels[i * 4:][:4]
		if e[0] == a[0] && e[1] == a[1] && e[2] == a[2] && e[3] == a[3] do continue
		dr, dg, db := int(a[0]) - int(e[0]), int(a[1]) - int(e[1]), int(a[2]) - int(e[2])
		if f64(dr * dr + dg * dg + db * db) > limit {
			differing += 1
			if diff != nil do diff[i] = true
		}
	}
	return 100 - f64(differing) / f64(total) * 100
}

// The actual image with the differing pixels in red, the rest faded: where to look.
image_diff :: proc(actual: Image, differing: []bool) -> Image {
	pixels := make([]u8, len(actual.pixels))
	for i in 0 ..< actual.width * actual.height {
		p := pixels[i * 4:][:4]
		if differing[i] {
			p[0], p[1], p[2], p[3] = 255, 0, 0, 255
		} else {
			a := actual.pixels[i * 4:][:4]
			p[0], p[1], p[2], p[3] = 128 + a[0] / 2, 128 + a[1] / 2, 128 + a[2] / 2, 255
		}
	}
	return {pixels, actual.width, actual.height}
}
