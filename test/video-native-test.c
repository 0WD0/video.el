/* Native pixel regressions; include the runtime to exercise its render worker
 * without introducing test-only entry points in the module's public API. */
#include "../src/video-runtime.c"

static void clear_target(VideoTarget *target)
{
	g_clear_pointer(&target->converter, gst_video_converter_free);
	gst_clear_buffer(&target->front);
	gst_clear_buffer(&target->back);
	g_mutex_clear(&target->lock);
}

static GstBuffer *rgba_buffer(GstVideoInfo *info, GstVideoFormat format,
                             int width, int height, const guint8 *rgba)
{
	gst_video_info_set_format(info, format, width, height);
	GstBuffer *buffer = gst_buffer_new_allocate(NULL, info->size, NULL);
	GstVideoFrame frame;
	g_assert_true(gst_video_frame_map(&frame, info, buffer, GST_MAP_WRITE));
	memset(GST_VIDEO_FRAME_PLANE_DATA(&frame, 0), 0x5a, info->size);
	for (int y = 0; y < height; ++y)
		for (int x = 0; x < width; ++x)
			for (guint c = 0; c < GST_VIDEO_INFO_N_COMPONENTS(info); ++c)
				GST_VIDEO_FRAME_COMP_DATA(&frame, c)
				        [y * GST_VIDEO_FRAME_COMP_STRIDE(&frame, c) +
				         x * GST_VIDEO_FRAME_COMP_PSTRIDE(&frame, c)] =
				        rgba[(y * width + x) * 4 + c];
	gst_video_frame_unmap(&frame);
	return buffer;
}

static void render_copy(VideoTarget *target, const GstVideoInfo *info,
                        GstBuffer *buffer, uint32_t *pixels)
{
	target_render(target, info, buffer);
	guint64 sequence = 0;
	g_assert_true(video_target_copy(target, pixels, target->view.width,
	                                target->view.height, 0, 0, 0, &sequence));
	g_assert_cmpuint(sequence, ==, target->sequence);
}

static void read_front(VideoTarget *target, uint32_t *pixels)
{
	GstVideoFrame frame;
	g_assert_true(gst_video_frame_map(&frame, &target->converter_output,
	                                  target->front, GST_MAP_READ));
	for (int y = 0; y < target->view.height; ++y)
		memcpy(pixels + y * target->view.width,
		       (guint8 *)GST_VIDEO_FRAME_PLANE_DATA(&frame, 0) +
		               y * GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0),
		       target->view.width * sizeof *pixels);
	gst_video_frame_unmap(&frame);
}

static void test_packed_alpha(void)
{
	const GstVideoFormat formats[] = {
	        GST_VIDEO_FORMAT_RGBA, GST_VIDEO_FORMAT_BGRA,
	        GST_VIDEO_FORMAT_ARGB, GST_VIDEO_FORMAT_ABGR,
	        GST_VIDEO_FORMAT_RGBx, GST_VIDEO_FORMAT_BGRx,
	        GST_VIDEO_FORMAT_xRGB, GST_VIDEO_FORMAT_xBGR};
	const guint8 rgba[] = {255, 0, 255, 0, 255, 128, 64, 128,
	                      32, 128, 255, 255, 32, 255, 128, 64};
	const uint32_t expected[] = {0, 0x80804020, 0xff2080ff, 0x40084020};
	const uint32_t opaque_expected[] = {
	        0xffff00ff, 0xffff8040, 0xff2080ff, 0xff20ff80};
	CanvasInput prepared = {0};
	for (guint i = 0; i < G_N_ELEMENTS(formats); ++i) {
		GstVideoInfo input;
		GstBuffer *buffer = rgba_buffer(&input, formats[i], 4, 1, rgba);
		const uint32_t *colors = GST_VIDEO_INFO_HAS_ALPHA(&input)
		                                ? expected : opaque_expected;
		const GstVideoInfo *info = &input;
		GstBuffer *associated = canvas_input_prepare(&prepared, &info, buffer);
		g_assert_nonnull(associated);
		VideoTarget target = {.view = {.width = 4, .height = 1,
		                                     .fit = VIDEO_FIT_CONTAIN}};
		g_mutex_init(&target.lock);
		uint32_t pixels[4];
		render_copy(&target, info, associated, pixels);
		for (guint x = 0; x < G_N_ELEMENTS(expected); ++x)
			g_assert_cmphex(pixels[x], ==, colors[x] | 0xff000000u);
		read_front(&target, pixels);
		for (guint x = 0; x < G_N_ELEMENTS(expected); ++x)
			g_assert_cmphex(pixels[x], ==, colors[x]);
		/* Already associated frames must not have their edges darkened. */
		const GstVideoInfo *again_info = info;
		GstBuffer *again = canvas_input_prepare(&prepared, &again_info, associated);
		render_copy(&target, again_info, again, pixels);
		g_assert_cmphex(pixels[1], ==, colors[1] | 0xff000000u);
		clear_target(&target);
		gst_buffer_unref(buffer);
	}
	canvas_input_clear(&prepared);
}

static void test_scaled_alpha(void)
{
	/* Hidden blue must not pollute the red edge during interpolation. */
	const guint8 rgba[] = {255, 0, 0, 255, 0, 0, 255, 0};
	GstVideoInfo input;
	GstBuffer *buffer = rgba_buffer(&input, GST_VIDEO_FORMAT_RGBA, 2, 1, rgba);
	CanvasInput prepared = {0};
	const GstVideoInfo *info = &input;
	GstBuffer *associated = canvas_input_prepare(&prepared, &info, buffer);
	g_assert_nonnull(associated);
	VideoTarget target = {.view = {.width = 8, .height = 4,
	                                     .fit = VIDEO_FIT_CONTAIN}};
	g_mutex_init(&target.lock);
	uint32_t pixels[32];
	render_copy(&target, info, associated, pixels);
	read_front(&target, pixels);
	gboolean has_edge = FALSE;
	for (guint i = 0; i < G_N_ELEMENTS(pixels); ++i) {
		guint alpha = pixels[i] >> 24;
		g_assert_cmpuint((pixels[i] >> 16) & 255, ==, alpha);
		g_assert_cmpuint(pixels[i] & 0xffff, ==, 0);
		has_edge |= alpha > 0 && alpha < 255;
	}
	g_assert_true(has_edge);
	g_assert_cmphex(pixels[0], ==, 0xffff0000);
	g_assert_cmphex(pixels[7], ==, 0);
	clear_target(&target);
	canvas_input_clear(&prepared);
	gst_buffer_unref(buffer);
}

static void test_opaque_contain_and_pan(void)
{
	const guint8 rgba[] = {32, 128, 255, 255, 32, 128, 255, 255};
	GstVideoInfo input;
	GstBuffer *buffer = rgba_buffer(&input, GST_VIDEO_FORMAT_RGBx, 2, 1, rgba);
	CanvasInput prepared = {0};
	const GstVideoInfo *info = &input;
	GstBuffer *opaque = canvas_input_prepare(&prepared, &info, buffer);
	VideoTarget target = {.view = {.width = 4, .height = 4,
	                                     .fit = VIDEO_FIT_CONTAIN}};
	g_mutex_init(&target.lock);
	uint32_t pixels[16];
	render_copy(&target, info, opaque, pixels);
	for (int y = 0; y < 4; ++y)
		for (int x = 0; x < 4; ++x)
			g_assert_cmphex(pixels[y * 4 + x], ==,
			                y == 1 || y == 2 ? 0xff2080ff : 0xff000000);
	/* Reused front/back frames must erase old content after panning away. */
	target.view.scale = 1;
	target.view.viewport_x = 100;
	target.generation++;
	for (int frame = 0; frame < 3; ++frame) {
		render_copy(&target, info, opaque, pixels);
		for (guint i = 0; i < G_N_ELEMENTS(pixels); ++i)
			g_assert_cmphex(pixels[i], ==, 0xff000000);
	}
	target.view.viewport_x = -1;
	target.view.viewport_y = -2;
	target.generation++;
	render_copy(&target, info, opaque, pixels);
	for (int y = 0; y < 4; ++y)
		for (int x = 0; x < 4; ++x)
			g_assert_cmphex(pixels[y * 4 + x], ==,
			                y == 2 && (x == 1 || x == 2) ?
			                        0xff2080ff : 0xff000000);
	clear_target(&target);
	canvas_input_clear(&prepared);
	gst_buffer_unref(buffer);
}

static void test_controls_source_over(void)
{
	uint32_t pixels[200 * 100] = {0};
	VideoCanvasTransportLayout layout = video_canvas_transport_layout(
	        (VideoCanvasRect){.width = 200, .height = 100});
	VideoCanvasTransportState state = {
	        .playing = TRUE, .has_frame = TRUE, .opacity = 0.5};
	video_canvas_draw_transport(pixels, 200, 100, &layout, &state);
	g_assert_cmphex(pixels[0], ==, 0);
	g_assert_cmphex(pixels[38 * 200 + 100], ==, 0x58000000);
	g_assert_cmphex(pixels[44 * 200 + 96], ==, 0xac808080);
	const uint32_t backgrounds[] = {0x80402010, 0xff402010};
	const uint32_t expected[] = {0xd7140a05, 0xff140a05};
	state.opacity = 1;
	for (guint n = 0; n < G_N_ELEMENTS(backgrounds); ++n) {
		for (guint i = 0; i < G_N_ELEMENTS(pixels); ++i)
			pixels[i] = backgrounds[n];
		video_canvas_draw_transport(pixels, 200, 100, &layout, &state);
		g_assert_cmphex(pixels[38 * 200 + 100], ==, expected[n]);
		g_assert_cmphex(pixels[44 * 200 + 96], ==, 0xffffffff);
		g_assert_cmphex(pixels[0], ==, backgrounds[n]);
	}
}

static void test_blit_replaces_transparency(void)
{
	const uint32_t source[] = {0xffffffff, 0x80800000, 0xff00ff00, 0};
	uint32_t pixels[] = {0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff};
	for (int repeat = 0; repeat < 3; ++repeat) {
		g_assert_true(video_canvas_blit_bgra(
		        pixels, 2, 2, (const uint8_t *)source, 2, 2, 8, -1, 0,
		        0x204060));
		g_assert_cmphex(pixels[0], ==, 0xff902030);
		g_assert_cmphex(pixels[2], ==, 0xff204060);
		g_assert_cmphex(pixels[1], ==, 0xffffffff);
		g_assert_cmphex(pixels[3], ==, 0xffffffff);
	}
	g_assert_true(video_canvas_blit_bgra(
	        pixels, 2, 2, (const uint8_t *)source, 2, 2, 8, 1, -1, 0xf0e0c0));
	g_assert_cmphex(pixels[1], ==, 0xff00ff00);
	g_assert_cmphex(pixels[0], ==, 0xff902030);
	g_assert_cmphex(pixels[2], ==, 0xff204060);
	g_assert_cmphex(pixels[3], ==, 0xffffffff);
	g_assert_false(video_canvas_blit_bgra(
	        pixels, 2, 2, (const uint8_t *)source, 2, 2, 8, G_MININT, 0, 0));
	g_assert_false(video_canvas_blit_bgra(
	        pixels, 2, 2, (const uint8_t *)source, 2, 2, 8, G_MAXINT, 0, 0));
}

static void test_background_fill(void)
{
	uint32_t pixels[] = {1, 2, 3, 4, 5, 6};
	g_assert_true(video_canvas_fill(
	        pixels, 3, 2, (VideoCanvasRect){-1, 1, 3, 2}, 0xf0e0c0));
	const uint32_t expected[] = {1, 2, 3, 0xfff0e0c0, 0xfff0e0c0, 6};
	g_assert_cmpmem(pixels, sizeof pixels, expected, sizeof expected);
	g_assert_false(video_canvas_fill(
	        pixels, 3, 2, (VideoCanvasRect){G_MAXINT, 0, 3, 2}, 0));
	g_assert_false(video_canvas_fill(
	        pixels, 3, 2, (VideoCanvasRect){G_MININT, 0, 3, 2}, 0));
	g_assert_false(video_canvas_fill(
	        pixels, 3, 2, (VideoCanvasRect){0, 0, 0, 2}, 0));
	g_assert_cmpmem(pixels, sizeof pixels, expected, sizeof expected);
}

static void test_target_backgrounds(void)
{
	const guint8 rgba[] = {255, 0, 0, 128, 80, 160, 240, 255,
	                      255, 0, 255, 0};
	GstVideoInfo input;
	GstBuffer *buffer = rgba_buffer(&input, GST_VIDEO_FORMAT_RGBA, 3, 1, rgba);
	CanvasInput prepared = {0};
	const GstVideoInfo *info = &input;
	GstBuffer *associated = canvas_input_prepare(&prepared, &info, buffer);
	VideoTarget target = {.view = {.width = 3, .height = 1,
	                                     .fit = VIDEO_FIT_CONTAIN}};
	g_mutex_init(&target.lock);
	target_render(&target, info, associated);
	uint32_t dark[3], light[3], raw[3];
	const uint32_t expected_dark[] = {0xff902030, 0xff50a0f0, 0xff204060};
	const uint32_t expected_light[] = {0xfff87060, 0xff50a0f0, 0xfff0e0c0};
	const uint32_t expected_raw[] = {0x80800000, 0xff50a0f0, 0};
	guint64 sequence;
	for (int repeat = 0; repeat < 3; ++repeat) {
		g_assert_true(video_target_copy(&target, dark, 3, 1, 0, 0,
		                                0x204060, &sequence));
		g_assert_cmpuint(sequence, ==, target.sequence);
		g_assert_true(video_target_copy(&target, light, 3, 1, 0, 0,
		                                0xf0e0c0, &sequence));
		g_assert_cmpmem(dark, sizeof dark, expected_dark, sizeof expected_dark);
		g_assert_cmpmem(light, sizeof light, expected_light, sizeof expected_light);
		read_front(&target, raw);
		g_assert_cmpmem(raw, sizeof raw, expected_raw, sizeof expected_raw);
	}
	/* A later transparent frame erases even the previous opaque center. */
	const guint8 invisible[12] = {0};
	GstBuffer *transparent = rgba_buffer(
	        &input, GST_VIDEO_FORMAT_RGBA, 3, 1, invisible);
	info = &input;
	associated = canvas_input_prepare(&prepared, &info, transparent);
	for (int repeat = 0; repeat < 3; ++repeat) {
		target_render(&target, info, associated);
		g_assert_true(video_target_copy(&target, dark, 3, 1, 0, 0,
		                                0x204060, &sequence));
		for (guint x = 0; x < G_N_ELEMENTS(dark); ++x)
			g_assert_cmphex(dark[x], ==, 0xff204060);
	}
	clear_target(&target);
	canvas_input_clear(&prepared);
	gst_buffer_unref(transparent);
	gst_buffer_unref(buffer);
}

static void test_png_poster_and_target(void)
{
	const gchar *encoded =
	        "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAGUlEQVR4nGP4zwCEDQ4N"
	        "Cg3//ysAGQzoAgApmxF1gOQJKAAAAABJRU5ErkJggg==";
	gsize size;
	guchar *png = g_base64_decode(encoded, &size);
	gchar *filename = NULL;
	GError *error = NULL;
	int fd = g_file_open_tmp("video-alpha-XXXXXX.png", &filename, &error);
	g_assert_no_error(error);
	g_assert_cmpint(fd, >=, 0);
	close(fd);
	g_assert_true(g_file_set_contents(filename, (const gchar *)png, size, &error));
	g_assert_no_error(error);
	g_free(png);
	gchar *uri = g_filename_to_uri(filename, NULL, &error);
	g_assert_no_error(error);
	VideoViewConfig view = {.width = 4, .height = 4, .fit = VIDEO_FIT_CONTAIN};
	uint32_t poster[16];
	g_assert_true(video_runtime_draw_uri(uri, &view, poster, 4, 4, 0, 0,
	                                     0x204060));
	const uint32_t expected[] = {
	        0xff204060, 0xff906050, 0xff2080ff, 0xff207068};
	for (int y = 0; y < 4; ++y)
		for (int x = 0; x < 4; ++x)
			g_assert_cmphex(poster[y * 4 + x], ==,
			                y == 1 || y == 2 ? expected[x] : 0xff204060);
	GstSample *sample = decode_uri_preroll(uri);
	g_assert_nonnull(sample);
	GstVideoInfo input;
	g_assert_true(gst_video_info_from_caps(&input, gst_sample_get_caps(sample)));
	CanvasInput prepared = {0};
	const GstVideoInfo *info = &input;
	GstBuffer *associated = canvas_input_prepare(
	        &prepared, &info, gst_sample_get_buffer(sample));
	g_assert_nonnull(associated);
	VideoTarget target = {.view = view};
	g_mutex_init(&target.lock);
	uint32_t pixels[16];
	target_render(&target, info, associated);
	guint64 sequence;
	g_assert_true(video_target_copy(&target, pixels, 4, 4, 0, 0,
	                                0x204060, &sequence));
	g_assert_cmpmem(pixels, sizeof pixels, poster, sizeof poster);
	clear_target(&target);
	canvas_input_clear(&prepared);
	gst_sample_unref(sample);
	view.scale = 1;
	view.viewport_x = 100;
	g_assert_true(video_runtime_draw_uri(uri, &view, poster, 4, 4, 0, 0,
	                                     0xf0e0c0));
	for (guint i = 0; i < G_N_ELEMENTS(poster); ++i)
		g_assert_cmphex(poster[i], ==, 0xfff0e0c0);
	g_unlink(filename);
	g_free(filename);
	g_free(uri);
}

int main(int argc, char **argv)
{
	gst_init(&argc, &argv);
	g_test_init(&argc, &argv, NULL);
	g_test_add_func("/video/alpha/packed", test_packed_alpha);
	g_test_add_func("/video/alpha/scaled-edge", test_scaled_alpha);
	g_test_add_func("/video/alpha/opaque-contain-pan", test_opaque_contain_and_pan);
	g_test_add_func("/video/alpha/controls", test_controls_source_over);
	g_test_add_func("/video/alpha/blit", test_blit_replaces_transparency);
	g_test_add_func("/video/alpha/background-fill", test_background_fill);
	g_test_add_func("/video/alpha/target-backgrounds", test_target_backgrounds);
	g_test_add_func("/video/alpha/png-poster-target", test_png_poster_and_target);
	return g_test_run();
}
