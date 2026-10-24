// speedrun's image codecs for takeScreenshot's cropOn and assertScreenshot: stb_image
// decodes (PNG, JPEG, GIF, BMP...), stb_image_write encodes PNG (both public domain,
// vendored here). The pixel work is in host/image.odin; build.sh compiles this file into
// image/build/libspeedrunimage.a.
#include <stdlib.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"

// RGBA pixels (4 bytes each, rows top to bottom), malloc'd; NULL when the data is not an image.
unsigned char *sr_image_decode(const unsigned char *data, int len, int *width, int *height) {
	int channels;
	return stbi_load_from_memory(data, len, width, height, &channels, 4);
}

// A PNG of RGBA pixels, malloc'd; NULL on failure.
unsigned char *sr_image_png(const unsigned char *rgba, int width, int height, int *len) {
	return stbi_write_png_to_mem(rgba, width * 4, width, height, 4, len);
}

void sr_image_free(void *p) {
	free(p);
}
