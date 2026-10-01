/* Native APNG regressions using authored PNG chunks and real appsrc playback. */
#include "../src/video-animation.h"

#include <glib/gstdio.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#include <string.h>
#include <zlib.h>

#define TIMEOUT (5 * GST_SECOND)
#define WIDTH 3
#define HEIGHT 2

/* BACKGROUND clears the first two top pixels after frame 1. PREVIOUS restores
 * those transparent pixels after frame 2, rather than retaining its red/green.
 * Frames 2, 3 and 4 also distinguish straight from premultiplied output. */
static const guint8 expected[][WIDTH * HEIGHT * 4] = {
	{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
	 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 255},
	{127, 0, 128, 255, 0, 255, 0, 255, 0, 0, 255, 255,
	 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 255},
	{255, 0, 0, 128, 0, 255, 0, 255, 0, 0, 255, 255,
	 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 255},
	{0, 0, 0, 0, 255, 255, 255, 128, 0, 0, 255, 255,
	 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 255},
	{0, 0, 0, 0, 255, 255, 255, 128, 0, 0, 255, 255,
	 255, 0, 0, 64, 255, 255, 255, 255, 255, 255, 0, 255},
};
static const guint durations_ms[] = {100, 200, 50, 300, 150};
static const guint pts_ms[] = {0, 100, 300, 350, 650};
static const guint8 over_background[] = {0, 0, 255, 128, 0, 0, 0, 0};
static const guint8 over_previous[] = {255, 0, 0, 128, 0, 255, 0, 255};
static const guint8 over_white[] = {255, 255, 255, 128};
static const guint8 over_red[] = {255, 0, 0, 64};
static const guint8 poster[] = {
	255, 0, 255, 255, 255, 0, 255, 255, 255, 0, 255, 255,
	255, 0, 255, 255, 255, 0, 255, 255, 255, 0, 255, 255,
};

typedef struct {
	gchar *directory;
	gchar *path;
	gchar *uri;
} Fixture;

typedef struct {
	VideoAnimation *apng;
	GstElement *pipeline;
	GstElement *sink;
} Player;

static void append_u32(GByteArray *bytes, guint32 value)
{
	guint8 encoded[] = {value >> 24, value >> 16, value >> 8, value};
	g_byte_array_append(bytes, encoded, sizeof encoded);
}

static void append_u16(GByteArray *bytes, guint16 value)
{
	guint8 encoded[] = {value >> 8, value};
	g_byte_array_append(bytes, encoded, sizeof encoded);
}

static void chunk(GByteArray *png, const gchar *type, const GByteArray *data)
{
	guint length = data ? data->len : 0;
	uLong crc = crc32(0, Z_NULL, 0);
	append_u32(png, length);
	g_byte_array_append(png, (const guint8 *)type, 4);
	crc = crc32(crc, (const Bytef *)type, 4);
	if (length) {
		g_byte_array_append(png, data->data, length);
		crc = crc32(crc, data->data, length);
	}
	append_u32(png, crc);
}

static GByteArray *compressed_pixels(const guint8 *rgba, guint width,
                                    guint height)
{
	GByteArray *raw = g_byte_array_new();
	const guint8 filter = 0;
	for (guint y = 0; y < height; ++y) {
		g_byte_array_append(raw, &filter, 1);
		g_byte_array_append(raw, rgba + y * width * 4, width * 4);
	}
	uLongf size = compressBound(raw->len);
	GByteArray *compressed = g_byte_array_sized_new(size);
	g_byte_array_set_size(compressed, size);
	g_assert_cmpint(compress2(compressed->data, &size, raw->data,
	                         raw->len, Z_BEST_COMPRESSION), ==, Z_OK);
	g_byte_array_set_size(compressed, size);
	g_byte_array_unref(raw);
	return compressed;
}

static GByteArray *png_header(void)
{
	const guint8 signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
	const guint8 format[] = {8, 6, 0, 0, 0};
	GByteArray *png = g_byte_array_new();
	GByteArray *header = g_byte_array_new();
	g_byte_array_append(png, signature, sizeof signature);
	append_u32(header, WIDTH);
	append_u32(header, HEIGHT);
	g_byte_array_append(header, format, sizeof format);
	chunk(png, "IHDR", header);
	g_byte_array_unref(header);
	return png;
}

static void frame(GByteArray *png, guint32 *sequence, guint index,
                  guint width, guint height, guint x, guint y,
                  guint8 dispose, guint8 blend, const guint8 *pixels,
                  gboolean idat)
{
	GByteArray *control = g_byte_array_new();
	append_u32(control, (*sequence)++);
	append_u32(control, width);
	append_u32(control, height);
	append_u32(control, x);
	append_u32(control, y);
	append_u16(control, durations_ms[index]);
	append_u16(control, 1000);
	g_byte_array_append(control, &dispose, 1);
	g_byte_array_append(control, &blend, 1);
	chunk(png, "fcTL", control);
	g_byte_array_unref(control);
	GByteArray *compressed = compressed_pixels(pixels, width, height);
	if (idat) {
		chunk(png, "IDAT", compressed);
	} else {
		GByteArray *data = g_byte_array_new();
		append_u32(data, (*sequence)++);
		g_byte_array_append(data, compressed->data, compressed->len);
		chunk(png, "fdAT", data);
		g_byte_array_unref(data);
	}
	g_byte_array_unref(compressed);
}

static GByteArray *animation(guint32 plays, gboolean separate_poster)
{
	GByteArray *png = png_header();
	GByteArray *control = g_byte_array_new();
	append_u32(control, G_N_ELEMENTS(expected));
	append_u32(control, plays);
	chunk(png, "acTL", control);
	g_byte_array_unref(control);
	if (separate_poster) {
		GByteArray *data = compressed_pixels(poster, WIDTH, HEIGHT);
		chunk(png, "IDAT", data);
		g_byte_array_unref(data);
	}
	guint32 sequence = 0;
	frame(png, &sequence, 0, WIDTH, HEIGHT, 0, 0, 0, 0,
	      expected[0], !separate_poster);
	frame(png, &sequence, 1, 2, 1, 0, 0, 1, 1, over_background, FALSE);
	frame(png, &sequence, 2, 2, 1, 0, 0, 2, 1, over_previous, FALSE);
	frame(png, &sequence, 3, 1, 1, 1, 0, 0, 1, over_white, FALSE);
	frame(png, &sequence, 4, 1, 1, 0, 1, 0, 1, over_red, FALSE);
	chunk(png, "IEND", NULL);
	return png;
}

static Fixture fixture_new(GByteArray *bytes)
{
	GError *error = NULL;
	Fixture fixture = {0};
	fixture.directory = g_dir_make_tmp("video-apng-test-XXXXXX", &error);
	g_assert_no_error(error);
	fixture.path = g_build_filename(fixture.directory, "fixture.png", NULL);
	g_assert_true(g_file_set_contents(fixture.path, (const gchar *)bytes->data,
	                                  bytes->len, &error));
	g_assert_no_error(error);
	fixture.uri = g_filename_to_uri(fixture.path, NULL, &error);
	g_assert_no_error(error);
	g_byte_array_unref(bytes);
	return fixture;
}

static void fixture_clear(Fixture *fixture)
{
	g_assert_cmpint(g_unlink(fixture->path), ==, 0);
	g_assert_cmpint(g_rmdir(fixture->directory), ==, 0);
	g_free(fixture->uri);
	g_free(fixture->path);
	g_free(fixture->directory);
}

static void assert_frame(GstSample *sample, guint index)
{
	g_assert_nonnull(sample);
	GstBuffer *buffer = gst_sample_get_buffer(sample);
	g_assert_nonnull(buffer);
	g_assert_cmpuint(GST_BUFFER_PTS(buffer), ==, pts_ms[index] * GST_MSECOND);
	g_assert_cmpuint(GST_BUFFER_DURATION(buffer), ==,
	                 durations_ms[index] * GST_MSECOND);
	GstVideoInfo info;
	g_assert_true(gst_video_info_from_caps(&info, gst_sample_get_caps(sample)));
	g_assert_cmpuint(GST_VIDEO_INFO_WIDTH(&info), ==, WIDTH);
	g_assert_cmpuint(GST_VIDEO_INFO_HEIGHT(&info), ==, HEIGHT);
	g_assert_true(GST_VIDEO_INFO_IS_RGB(&info));
	g_assert_true(GST_VIDEO_INFO_HAS_ALPHA(&info));
	g_assert_cmpuint(GST_VIDEO_INFO_N_COMPONENTS(&info), ==, 4);
	GstVideoFrame mapped;
	g_assert_true(gst_video_frame_map(&mapped, &info, buffer, GST_MAP_READ));
	guint8 actual[WIDTH * HEIGHT * 4];
	for (guint y = 0; y < HEIGHT; ++y)
		for (guint x = 0; x < WIDTH; ++x)
			for (guint c = 0; c < 4; ++c)
				actual[(y * WIDTH + x) * 4 + c] =
				        GST_VIDEO_FRAME_COMP_DATA(&mapped, c)
				                [y * GST_VIDEO_FRAME_COMP_STRIDE(&mapped, c) +
				                 x * GST_VIDEO_FRAME_COMP_PSTRIDE(&mapped, c)];
	g_assert_cmpmem(actual, sizeof actual, expected[index], sizeof expected[index]);
	gst_video_frame_unmap(&mapped);
}

static void assert_metadata(const VideoAnimationMetadata *metadata, gint64 loops)
{
	g_assert_nonnull(metadata);
	g_assert_cmpuint(metadata->width, ==, WIDTH);
	g_assert_cmpuint(metadata->height, ==, HEIGHT);
	g_assert_cmpuint(metadata->frames, ==, G_N_ELEMENTS(expected));
	g_assert_cmpuint(metadata->duration, ==, 800 * GST_MSECOND);
	g_assert_cmpint(metadata->loop_count, ==, loops);
}

static void state(Player *player, GstState requested)
{
	g_assert_cmpint(gst_element_set_state(player->pipeline, requested), !=,
	                GST_STATE_CHANGE_FAILURE);
	GstState current;
	g_assert_cmpint(gst_element_get_state(player->pipeline, &current, NULL,
	                                     TIMEOUT), ==, GST_STATE_CHANGE_SUCCESS);
	g_assert_cmpint(current, ==, requested);
}

static Player player_new(const gchar *uri, GstState initial)
{
	GError *error = NULL;
	Player player = {0};
	player.apng = video_animation_new(VIDEO_SOURCE_APNG, uri, &error);
	g_assert_no_error(error);
	g_assert_nonnull(player.apng);
	player.pipeline = gst_pipeline_new(NULL);
	GstElement *source = gst_element_factory_make("appsrc", NULL);
	player.sink = gst_element_factory_make("appsink", NULL);
	g_assert_nonnull(source);
	g_assert_nonnull(player.sink);
	g_object_set(player.sink, "sync", FALSE, "max-buffers", 1u,
	             "drop", FALSE, "wait-on-eos", FALSE, NULL);
	gst_bin_add_many(GST_BIN(player.pipeline), source, player.sink, NULL);
	g_assert_true(gst_element_link(source, player.sink));
	g_assert_true(video_animation_configure_source(player.apng, source, &error));
	g_assert_no_error(error);
	state(&player, initial);
	return player;
}

static void player_clear(Player *player)
{
	/* Release blocked source acquisitions before waiting for streaming tasks. */
	video_animation_flush(player->apng);
	state(player, GST_STATE_NULL);
	gst_object_unref(player->pipeline);
	video_animation_unref(player->apng);
}

static GstSample *pull(Player *player, gboolean preroll, guint index)
{
	GstSample *sample = preroll ?
	        gst_app_sink_try_pull_preroll(GST_APP_SINK(player->sink), TIMEOUT) :
	        gst_app_sink_try_pull_sample(GST_APP_SINK(player->sink), TIMEOUT);
	assert_frame(sample, index);
	return sample;
}

static void assert_eos(Player *player)
{
	GstSample *extra = gst_app_sink_try_pull_sample(
	        GST_APP_SINK(player->sink), TIMEOUT);
	g_assert_null(extra);
	g_assert_true(gst_app_sink_is_eos(GST_APP_SINK(player->sink)));
	GstBus *bus = gst_element_get_bus(player->pipeline);
	GstMessage *message = gst_bus_timed_pop_filtered(
	        bus, TIMEOUT, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
	g_assert_nonnull(message);
	g_assert_cmpuint(GST_MESSAGE_TYPE(message), ==, GST_MESSAGE_EOS);
	gst_message_unref(message);
	gst_object_unref(bus);
}

static void test_metadata(gconstpointer data)
{
	guint plays = GPOINTER_TO_UINT(data);
	gint64 loops = plays == 0 ? 0 : plays == 1 ? -1 : (gint64)plays - 1;
	Fixture fixture = fixture_new(animation(plays, FALSE));
	GError *error = NULL;
	VideoAnimation *apng = video_animation_new(VIDEO_SOURCE_APNG,
	                                          fixture.uri, &error);
	g_assert_no_error(error);
	g_assert_nonnull(apng);
	assert_metadata(&apng->metadata, loops);
	video_animation_unref(apng);
	fixture_clear(&fixture);
}

static void test_playback(gconstpointer data)
{
	gboolean separate_poster = GPOINTER_TO_INT(data);
	/* Even an infinitely looping APNG must deliver exactly one source pass. */
	Fixture fixture = fixture_new(animation(0, separate_poster));
	GError *error = NULL;
	GstSample *first = video_animation_first_frame(VIDEO_SOURCE_APNG,
	                                               fixture.uri, &error);
	g_assert_no_error(error);
	assert_frame(first, 0);
	Player player = player_new(fixture.uri, GST_STATE_PLAYING);
	assert_metadata(&player.apng->metadata, 0);
	GstSample *held_first = pull(&player, FALSE, 0);
	GstSample *held_partial = NULL;
	for (guint i = 1; i < G_N_ELEMENTS(expected); ++i) {
		GstSample *sample = pull(&player, FALSE, i);
		if (i == 2)
			held_partial = sample;
		else
			gst_sample_unref(sample);
		assert_frame(held_first, 0);
	}
	assert_eos(&player);
	assert_frame(held_partial, 2);
	player_clear(&player);
	/* Samples own their storage independently of decoder and pipeline life. */
	assert_frame(first, 0);
	assert_frame(held_first, 0);
	assert_frame(held_partial, 2);
	gst_sample_unref(first);
	gst_sample_unref(held_first);
	gst_sample_unref(held_partial);
	fixture_clear(&fixture);
}

static void seek(Player *player, guint position_ms, gboolean paused,
                 guint expected_index)
{
	g_assert_true(gst_element_seek(player->pipeline, 1.0, GST_FORMAT_TIME,
	                               GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE,
	                               GST_SEEK_TYPE_SET, position_ms * GST_MSECOND,
	                               GST_SEEK_TYPE_NONE, GST_CLOCK_TIME_NONE));
	GstState current;
	g_assert_cmpint(gst_element_get_state(player->pipeline, &current, NULL,
	                                     TIMEOUT), ==, GST_STATE_CHANGE_SUCCESS);
	g_assert_cmpint(current, ==, paused ? GST_STATE_PAUSED : GST_STATE_PLAYING);
	GstSample *sample = pull(player, paused, expected_index);
	gst_sample_unref(sample);
}

static void test_seek(gconstpointer data)
{
	gboolean paused = GPOINTER_TO_INT(data);
	Fixture fixture = fixture_new(animation(1, FALSE));
	Player player = player_new(fixture.uri,
	                           paused ? GST_STATE_PAUSED : GST_STATE_PLAYING);
	GstSample *held = pull(&player, paused, 0);
	seek(&player, 400, paused, 3);
	seek(&player, 150, paused, 1);
	seek(&player, 325, paused, 2);
	assert_frame(held, 0);
	if (paused) {
		state(&player, GST_STATE_PLAYING);
		GstSample *sample = pull(&player, FALSE, 2);
		gst_sample_unref(sample);
	}
	for (guint i = 3; i < G_N_ELEMENTS(expected); ++i) {
		GstSample *sample = pull(&player, FALSE, i);
		gst_sample_unref(sample);
	}
	assert_eos(&player);
	/* Restart from EOS as well as from an active decoder. */
	seek(&player, 700, FALSE, 4);
	assert_eos(&player);
	player_clear(&player);
	assert_frame(held, 0);
	gst_sample_unref(held);
	fixture_clear(&fixture);
}

static void test_close_with_sample(void)
{
	Fixture fixture = fixture_new(animation(0, FALSE));
	Player player = player_new(fixture.uri, GST_STATE_PLAYING);
	GstSample *held = pull(&player, FALSE, 0);
	/* Do not drain appsink: shutdown must work with downstream backpressure. */
	player_clear(&player);
	assert_frame(held, 0);
	gst_sample_unref(held);
	fixture_clear(&fixture);
}

static void assert_rejected(GByteArray *bytes)
{
	Fixture fixture = fixture_new(bytes);
	GError *error = NULL;
	VideoAnimation *apng = video_animation_new(VIDEO_SOURCE_APNG,
	                                          fixture.uri, &error);
	g_assert_null(apng);
	g_assert_nonnull(error);
	g_clear_error(&error);
	fixture_clear(&fixture);
}

static void test_static_png(void)
{
	GByteArray *png = png_header();
	GByteArray *pixels = compressed_pixels(poster, WIDTH, HEIGHT);
	chunk(png, "IDAT", pixels);
	g_byte_array_unref(pixels);
	chunk(png, "IEND", NULL);
	assert_rejected(png);
}

static void test_truncated(void)
{
	GByteArray *png = animation(1, FALSE);
	/* A valid first frame must not disguise a later incomplete frame stream. */
	g_byte_array_set_size(png, png->len - 20);
	assert_rejected(png);
}

static void test_corrupt(void)
{
	GByteArray *png = animation(1, FALSE);
	/* Damage the last fdAT CRC while leaving the complete first frame intact. */
	png->data[png->len - 13] ^= 0x80;
	assert_rejected(png);
}

int main(int argc, char **argv)
{
	gst_init(&argc, &argv);
	g_test_init(&argc, &argv, NULL);
	g_test_add_data_func("/video/apng/metadata/forever", GUINT_TO_POINTER(0),
	                     test_metadata);
	g_test_add_data_func("/video/apng/metadata/once", GUINT_TO_POINTER(1),
	                     test_metadata);
	g_test_add_data_func("/video/apng/metadata/finite", GUINT_TO_POINTER(4),
	                     test_metadata);
	g_test_add_data_func("/video/apng/playback/disposal", GINT_TO_POINTER(FALSE),
	                     test_playback);
	g_test_add_data_func("/video/apng/playback/excluded-default", GINT_TO_POINTER(TRUE),
	                     test_playback);
	g_test_add_data_func("/video/apng/seek/paused", GINT_TO_POINTER(TRUE), test_seek);
	g_test_add_data_func("/video/apng/seek/playing", GINT_TO_POINTER(FALSE), test_seek);
	g_test_add_func("/video/apng/lifetime/retained-sample-close", test_close_with_sample);
	g_test_add_func("/video/apng/reject/static", test_static_png);
	g_test_add_func("/video/apng/reject/truncated", test_truncated);
	g_test_add_func("/video/apng/reject/corrupt", test_corrupt);
	return g_test_run();
}
