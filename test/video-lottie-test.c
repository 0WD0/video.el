/* Native Lottie regressions using authored JSON and independent real players. */
#include "../src/video-animation.h"

#include <glib/gstdio.h>
#include <string.h>

#define WORKERS 4
#define ROUNDS 64
#define BARRIER_TIMEOUT (30 * G_TIME_SPAN_SECOND)

typedef struct {
	guint width;
	guint height;
	guint8 red;
	guint8 green;
	guint8 blue;
} FrameSpec;

/* Integer-aligned rectangles have a two-pixel transparent border.  Primary
 * channels and full opacity make every expected byte exact, without depending
 * on antialiasing or fractional-opacity rounding conventions. */
static const FrameSpec specs[WORKERS] = {
	{8, 8, 255, 0, 0},
	{10, 12, 0, 255, 0},
	{12, 16, 0, 0, 255},
	{14, 20, 255, 255, 0},
};

typedef struct {
	gchar *directory;
	gchar *path;
	gchar *uri;
	const FrameSpec *spec;
} Fixture;

typedef struct {
	GMutex lock;
	GCond cond;
	guint arrived;
	guint generation;
} Barrier;

typedef struct {
	Barrier *barrier;
	const Fixture *fixtures;
	guint index;
} Worker;

static Fixture fixture_new(const FrameSpec *spec, const gchar *color)
{
	gchar *json = g_strdup_printf(
	        "{\"v\":\"5.7.4\",\"fr\":5,\"ip\":0,\"op\":5,\"w\":%u,\"h\":%u,"
	        "\"nm\":\"authored rectangle\",\"ddd\":0,\"assets\":[],\"layers\":[{"
	        "\"ddd\":0,\"ind\":1,\"ty\":4,\"sr\":1,"
	        "\"ks\":{\"o\":{\"a\":0,\"k\":100},\"r\":{\"a\":0,\"k\":0},"
	        "\"p\":{\"a\":0,\"k\":[%u,%u,0]},\"a\":{\"a\":0,\"k\":[0,0,0]},"
	        "\"s\":{\"a\":0,\"k\":[100,100,100]}},\"shapes\":[{"
	        "\"ty\":\"rc\",\"d\":1,\"p\":{\"a\":0,\"k\":[0,0]},"
	        "\"s\":{\"a\":0,\"k\":[%u,%u]},\"r\":{\"a\":0,\"k\":0}},{"
	        "\"ty\":\"fl\",\"c\":%s,\"o\":{\"a\":0,\"k\":100},\"r\":1}],"
	        "\"ip\":0,\"op\":5,\"st\":0,\"bm\":0}]}",
	        spec->width, spec->height, spec->width / 2, spec->height / 2,
	        spec->width - 4, spec->height - 4, color);
	GError *error = NULL;
	Fixture fixture = {.spec = spec};
	fixture.directory = g_dir_make_tmp("video-lottie-test-XXXXXX", &error);
	g_assert_no_error(error);
	g_assert_nonnull(fixture.directory);
	fixture.path = g_build_filename(fixture.directory, "fixture.json", NULL);
	g_assert_true(g_file_set_contents(fixture.path, json, -1, &error));
	g_assert_no_error(error);
	g_free(json);
	fixture.uri = g_filename_to_uri(fixture.path, NULL, &error);
	g_assert_no_error(error);
	g_assert_nonnull(fixture.uri);
	return fixture;
}

static Fixture static_fixture_new(const FrameSpec *spec, gboolean expressions)
{
	guint red = spec->red / 255;
	guint green = spec->green / 255;
	guint blue = spec->blue / 255;
	/* Expression fixtures have a black fallback, so disabling expression
	 * evaluation cannot make the concurrent rendering regression pass. */
	gchar *expression = expressions
	        ? g_strdup_printf(
	                  ",\"x\":\"var $bm_rt; $bm_rt = [%u,%u,%u,1];\"",
	                  red, green, blue)
	        : NULL;
	gchar *color = g_strdup_printf("{\"a\":0,\"k\":[%u,%u,%u,1]%s}",
	                                expressions ? 0 : red, expressions ? 0 : green,
	                                expressions ? 0 : blue, expression ? expression : "");
	Fixture fixture = fixture_new(spec, color);
	g_free(color);
	g_free(expression);
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

static GstSample *first_frame(const Fixture *fixture)
{
	GError *error = NULL;
	/* This public entry point creates, loads, renders and destroys a player;
	 * only the returned immutable sample survives the call. */
	GstSample *sample = video_animation_first_frame(
	        VIDEO_SOURCE_LOTTIE, fixture->uri, &error);
	g_assert_no_error(error);
	g_assert_nonnull(sample);
	return sample;
}

static void assert_frame(GstSample *sample, const FrameSpec *spec)
{
	GstCaps *caps = gst_sample_get_caps(sample);
	g_assert_nonnull(caps);
	g_assert_true(gst_caps_is_fixed(caps));
	g_assert_cmpuint(gst_caps_get_size(caps), ==, 1);
	g_assert_true(gst_structure_has_name(gst_caps_get_structure(caps, 0),
	                                     "video/x-raw"));
	GstVideoInfo info;
	g_assert_true(gst_video_info_from_caps(&info, caps));
	g_assert_cmpuint(GST_VIDEO_INFO_WIDTH(&info), ==, spec->width);
	g_assert_cmpuint(GST_VIDEO_INFO_HEIGHT(&info), ==, spec->height);
#if G_BYTE_ORDER == G_LITTLE_ENDIAN
	g_assert_cmpint(GST_VIDEO_INFO_FORMAT(&info), ==, GST_VIDEO_FORMAT_BGRA);
#else
	g_assert_cmpint(GST_VIDEO_INFO_FORMAT(&info), ==, GST_VIDEO_FORMAT_ARGB);
#endif
	g_assert_true(GST_VIDEO_INFO_HAS_ALPHA(&info));
	g_assert_cmpint(GST_VIDEO_INFO_FPS_N(&info), ==, 5);
	g_assert_cmpint(GST_VIDEO_INFO_FPS_D(&info), ==, 1);
	GstBuffer *buffer = gst_sample_get_buffer(sample);
	g_assert_nonnull(buffer);
	g_assert_cmpuint(GST_BUFFER_PTS(buffer), ==, 0);
	g_assert_cmpuint(GST_BUFFER_DURATION(buffer), ==, GST_SECOND / 5);
	GstVideoFrame frame;
	g_assert_true(gst_video_frame_map(&frame, &info, buffer, GST_MAP_READ));
	gint stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
	g_assert_cmpint(stride, >=, (gint)(spec->width * 4));
	const guint8 *pixels = GST_VIDEO_FRAME_PLANE_DATA(&frame, 0);
	guint32 foreground = 0xff000000u | ((guint32)spec->red << 16) |
	                     ((guint32)spec->green << 8) | spec->blue;
	for (guint y = 0; y < spec->height; ++y) {
		for (guint x = 0; x < spec->width; ++x) {
			gboolean inside = x >= 2 && x < spec->width - 2 &&
			                  y >= 2 && y < spec->height - 2;
			guint32 actual;
			memcpy(&actual, pixels + (gsize)y * stride + x * 4,
			       sizeof actual);
			g_assert_cmphex(actual, ==, inside ? foreground : 0);
		}
	}
	gst_video_frame_unmap(&frame);
}

static void barrier_wait(Barrier *barrier)
{
	g_mutex_lock(&barrier->lock);
	guint generation = barrier->generation;
	if (++barrier->arrived == WORKERS) {
		barrier->arrived = 0;
		++barrier->generation;
		g_cond_broadcast(&barrier->cond);
	} else {
		gint64 deadline = g_get_monotonic_time() + BARRIER_TIMEOUT;
		while (barrier->generation == generation) {
			if (!g_cond_wait_until(&barrier->cond, &barrier->lock, deadline) &&
			    barrier->generation == generation)
				g_error("Lottie workers stalled at barrier generation %u",
				        generation);
		}
	}
	g_mutex_unlock(&barrier->lock);
}

static gpointer render_worker(gpointer data)
{
	const Worker *worker = data;
	GstSample *retained = NULL;
	const FrameSpec *retained_spec = NULL;
	for (guint round = 0; round < ROUNDS; ++round) {
		/* Rotate inputs so every thread also changes its color and dimensions.
		 * Within a round no two independent players have the same input. */
		const Fixture *fixture = &worker->fixtures[
		        (worker->index + round) % WORKERS];
		barrier_wait(worker->barrier);
		GstSample *sample = first_frame(fixture);
		assert_frame(sample, fixture->spec);
		/* Every player has now been destroyed before the second pixel check.
		 * Keep exactly one older sample per worker to expose target reuse. */
		barrier_wait(worker->barrier);
		assert_frame(sample, fixture->spec);
		if (retained) {
			assert_frame(retained, retained_spec);
		} else {
			retained = gst_sample_ref(sample);
			retained_spec = fixture->spec;
		}
		gst_sample_unref(sample);
	}
	gst_sample_unref(retained);
	return NULL;
}

static void test_concurrent(gconstpointer data)
{
	gboolean expressions = GPOINTER_TO_INT(data);
	Fixture fixtures[WORKERS];
	for (guint i = 0; i < WORKERS; ++i)
		fixtures[i] = static_fixture_new(&specs[i], expressions);
	Barrier barrier = {0};
	g_mutex_init(&barrier.lock);
	g_cond_init(&barrier.cond);
	Worker workers[WORKERS];
	GThread *threads[WORKERS];
	for (guint i = 0; i < WORKERS; ++i) {
		workers[i] = (Worker){&barrier, fixtures, i};
		threads[i] = g_thread_new("lottie-first-frame", render_worker, &workers[i]);
	}
	for (guint i = 0; i < WORKERS; ++i)
		g_thread_join(threads[i]);
	g_cond_clear(&barrier.cond);
	g_mutex_clear(&barrier.lock);
	for (guint i = 0; i < WORKERS; ++i)
		fixture_clear(&fixtures[i]);
}

static void test_keyframed_first_frame(void)
{
	/* Static concurrency fixtures cannot distinguish the first and last
	 * animation frames.  This animation changes from red to green, so its
	 * initial pixels, PTS and duration independently check frame selection. */
	const gchar *color =
	        "{\"a\":1,\"k\":[{\"t\":0,\"s\":[1,0,0,1],\"e\":[0,1,0,1],"
	        "\"o\":{\"x\":0.33,\"y\":0},\"i\":{\"x\":0.67,\"y\":1}},"
	        "{\"t\":4,\"s\":[0,1,0,1]}]}";
	Fixture fixture = fixture_new(&specs[0], color);
	GstSample *sample = first_frame(&fixture);
	fixture_clear(&fixture);
	/* Neither the decoder nor its input file remains alive here. */
	assert_frame(sample, &specs[0]);
	gst_sample_unref(sample);
}

int main(int argc, char **argv)
{
	gst_init(&argc, &argv);
	g_test_init(&argc, &argv, NULL);
	/* Run concurrent cold initialization before any synchronous Lottie load. */
	g_test_add_data_func("/video/lottie/concurrent/plain", GINT_TO_POINTER(FALSE),
	                     test_concurrent);
	g_test_add_data_func("/video/lottie/concurrent/expressions", GINT_TO_POINTER(TRUE),
	                     test_concurrent);
	g_test_add_func("/video/lottie/first-frame/keyframed", test_keyframed_first_frame);
	return g_test_run();
}
