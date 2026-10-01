/* Native WebP regressions using authored lossless frames and real appsrc. */
#include "../src/video-animation.h"

#include <glib/gstdio.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#include <string.h>
#include <webp/encode.h>
#include <webp/mux.h>

#define TIMEOUT (5 * GST_SECOND)
#define WIDTH 3
#define HEIGHT 2

/* Frame 1 blends blue over red and leaves green untouched, then disposes its
 * two-pixel rectangle to transparent.  Frame 2 must blend onto that cleared
 * rectangle, not the old colors.  Frame 3 replaces blue with transparency;
 * frame 4 blends straight-alpha red onto it.  WebP's integer source-over blend
 * rounds the opaque red/blue result down to 126/127. */
static const guint8 expected[][WIDTH * HEIGHT * 4] = {
	{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
	 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 255},
	{126, 0, 127, 255, 0, 255, 0, 255, 0, 0, 255, 255,
	 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 255},
	{255, 0, 0, 128, 0, 255, 0, 255, 0, 0, 255, 255,
	 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 255},
	{255, 0, 0, 128, 0, 255, 0, 255, 0, 0, 0, 0,
	 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 255},
	{255, 0, 0, 128, 0, 255, 0, 255, 255, 0, 0, 64,
	 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 255},
};
static const guint durations_ms[] = {1, 27, 100, 250, 7};
static const guint pts_ms[] = {0, 1, 28, 128, 378};
static const guint8 over_blue[] = {0, 0, 255, 128, 0, 0, 0, 0};
static const guint8 over_cleared[] = {255, 0, 0, 128, 0, 255, 0, 255};
static const guint8 transparent[] = {0, 0, 0, 0};
static const guint8 over_red[] = {255, 0, 0, 64};

typedef struct {
	gchar *directory;
	gchar *path;
	gchar *uri;
} Fixture;

typedef struct {
	VideoAnimation *animation;
	GstElement *pipeline;
	GstElement *sink;
} Player;

static void frame(WebPMux *mux, guint width, guint height, guint x,
                  guint duration, WebPMuxAnimDispose dispose,
                  WebPMuxAnimBlend blend, const guint8 *pixels)
{
	guint8 *encoded = NULL;
	size_t size = WebPEncodeLosslessRGBA(pixels, width, height, width * 4,
	                                    &encoded);
	g_assert_cmpuint(size, >, 0);
	WebPMuxFrameInfo info = {
		.bitstream = {.bytes = encoded, .size = size},
		.x_offset = x,
		.duration = duration,
		.id = WEBP_CHUNK_ANMF,
		.dispose_method = dispose,
		.blend_method = blend,
	};
	g_assert_cmpint(WebPMuxPushFrame(mux, &info, 1), ==, WEBP_MUX_OK);
	WebPFree(encoded);
}

static GByteArray *assemble(WebPMux *mux)
{
	WebPData data = {0};
	g_assert_cmpint(WebPMuxAssemble(mux, &data), ==, WEBP_MUX_OK);
	GByteArray *bytes = g_byte_array_sized_new(data.size);
	g_byte_array_append(bytes, data.bytes, data.size);
	WebPDataClear(&data);
	WebPMuxDelete(mux);
	return bytes;
}

static WebPMux *new_mux(guint plays, guint width, guint height)
{
	WebPMux *mux = WebPMuxNew();
	g_assert_nonnull(mux);
	WebPMuxAnimParams params = {.loop_count = plays};
	g_assert_cmpint(WebPMuxSetAnimationParams(mux, &params), ==, WEBP_MUX_OK);
	g_assert_cmpint(WebPMuxSetCanvasSize(mux, width, height), ==, WEBP_MUX_OK);
	return mux;
}

static GByteArray *animation(guint plays, gboolean zero_delay)
{
	WebPMux *mux = new_mux(plays, WIDTH, HEIGHT);
	frame(mux, WIDTH, HEIGHT, 0, zero_delay ? 0 : durations_ms[0],
	      WEBP_MUX_DISPOSE_NONE, WEBP_MUX_NO_BLEND, expected[0]);
	frame(mux, 2, 1, 0, durations_ms[1],
	      WEBP_MUX_DISPOSE_BACKGROUND, WEBP_MUX_BLEND, over_blue);
	frame(mux, 2, 1, 0, zero_delay ? 0 : durations_ms[2],
	      WEBP_MUX_DISPOSE_NONE, WEBP_MUX_BLEND, over_cleared);
	frame(mux, 1, 1, 2, durations_ms[3],
	      WEBP_MUX_DISPOSE_NONE, WEBP_MUX_NO_BLEND, transparent);
	frame(mux, 1, 1, 2, durations_ms[4],
	      WEBP_MUX_DISPOSE_NONE, WEBP_MUX_BLEND, over_red);
	return assemble(mux);
}

static Fixture fixture_new(GByteArray *bytes)
{
	GError *error = NULL;
	Fixture fixture = {0};
	fixture.directory = g_dir_make_tmp("video-webp-test-XXXXXX", &error);
	g_assert_no_error(error);
	/* Deliberately misleading suffix: the native backend decodes content. */
	fixture.path = g_build_filename(fixture.directory, "fixture.gif", NULL);
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

static VideoAnimation *open_animation(const gchar *uri)
{
	GError *error = NULL;
	VideoAnimation *webp = video_animation_new(VIDEO_SOURCE_WEBP, uri, &error);
	g_assert_no_error(error);
	g_assert_nonnull(webp);
	return webp;
}

static void assert_pixels(GstSample *sample, guint index)
{
	g_assert_nonnull(sample);
	GstVideoInfo info;
	g_assert_true(gst_video_info_from_caps(&info, gst_sample_get_caps(sample)));
	g_assert_cmpuint(GST_VIDEO_INFO_WIDTH(&info), ==, WIDTH);
	g_assert_cmpuint(GST_VIDEO_INFO_HEIGHT(&info), ==, HEIGHT);
	g_assert_true(GST_VIDEO_INFO_IS_RGB(&info));
	g_assert_true(GST_VIDEO_INFO_HAS_ALPHA(&info));
	g_assert_false(info.flags & GST_VIDEO_FLAG_PREMULTIPLIED_ALPHA);
	GstVideoFrame mapped;
	g_assert_true(gst_video_frame_map(&mapped, &info, gst_sample_get_buffer(sample),
	                                 GST_MAP_READ));
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

static void assert_frame(GstSample *sample, guint index)
{
	assert_pixels(sample, index);
	GstBuffer *buffer = gst_sample_get_buffer(sample);
	g_assert_cmpuint(GST_BUFFER_PTS(buffer), ==, pts_ms[index] * GST_MSECOND);
	g_assert_cmpuint(GST_BUFFER_DURATION(buffer), ==,
	                 durations_ms[index] * GST_MSECOND);
}

static GstSample *next_sample(VideoAnimation *webp)
{
	GError *error = NULL;
	g_mutex_lock(&webp->lock);
	GstBuffer *buffer = webp->ops->next_frame(webp, &error);
	g_mutex_unlock(&webp->lock);
	g_assert_no_error(error);
	if (!buffer)
		return NULL;
	GstSample *sample = gst_sample_new(buffer, webp->caps, NULL, NULL);
	gst_buffer_unref(buffer);
	return sample;
}

static void seek_animation(VideoAnimation *webp, GstClockTime position)
{
	GError *error = NULL;
	g_mutex_lock(&webp->lock);
	g_assert_true(webp->ops->seek(webp, position, &error));
	g_mutex_unlock(&webp->lock);
	g_assert_no_error(error);
}

static void test_metadata(gconstpointer data)
{
	guint plays = GPOINTER_TO_UINT(data);
	Fixture fixture = fixture_new(animation(plays, FALSE));
	VideoAnimation *webp = open_animation(fixture.uri);
	g_assert_cmpuint(webp->metadata.width, ==, WIDTH);
	g_assert_cmpuint(webp->metadata.height, ==, HEIGHT);
	g_assert_cmpuint(webp->metadata.frames, ==, G_N_ELEMENTS(expected));
	g_assert_cmpuint(webp->metadata.duration, ==, 385 * GST_MSECOND);
	g_assert_cmpint(webp->metadata.loop_count, ==,
	                plays == 0 ? 0 : plays == 1 ? -1 : (gint64)plays - 1);
	video_animation_unref(webp);
	fixture_clear(&fixture);
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
	Player player = {.animation = open_animation(uri)};
	player.pipeline = gst_pipeline_new(NULL);
	GstElement *source = gst_element_factory_make("appsrc", NULL);
	player.sink = gst_element_factory_make("appsink", NULL);
	g_assert_nonnull(source);
	g_assert_nonnull(player.sink);
	g_object_set(player.sink, "sync", FALSE, "max-buffers", 1u,
	             "drop", FALSE, "wait-on-eos", FALSE, NULL);
	gst_bin_add_many(GST_BIN(player.pipeline), source, player.sink, NULL);
	g_assert_true(gst_element_link(source, player.sink));
	g_assert_true(video_animation_configure_source(player.animation, source, &error));
	g_assert_no_error(error);
	state(&player, initial);
	return player;
}

static void player_clear(Player *player)
{
	video_animation_flush(player->animation);
	state(player, GST_STATE_NULL);
	gst_object_unref(player->pipeline);
	video_animation_unref(player->animation);
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
	g_assert_null(gst_app_sink_try_pull_sample(GST_APP_SINK(player->sink), TIMEOUT));
	g_assert_true(gst_app_sink_is_eos(GST_APP_SINK(player->sink)));
	GstBus *bus = gst_element_get_bus(player->pipeline);
	GstMessage *message = gst_bus_timed_pop_filtered(
	        bus, TIMEOUT, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
	g_assert_nonnull(message);
	g_assert_cmpuint(GST_MESSAGE_TYPE(message), ==, GST_MESSAGE_EOS);
	gst_message_unref(message);
	gst_object_unref(bus);
}

static void test_playback(void)
{
	Fixture fixture = fixture_new(animation(0, FALSE));
	GError *error = NULL;
	GstSample *first = video_animation_first_frame(VIDEO_SOURCE_WEBP,
	                                               fixture.uri, &error);
	g_assert_no_error(error);
	assert_frame(first, 0);
	Player player = player_new(fixture.uri, GST_STATE_PLAYING);
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
	/* Loop metadata belongs to the session; a source yields only one pass. */
	assert_eos(&player);
	player_clear(&player);
	assert_frame(first, 0);
	assert_frame(held_first, 0);
	assert_frame(held_partial, 2);
	gst_sample_unref(first);
	gst_sample_unref(held_first);
	gst_sample_unref(held_partial);
	fixture_clear(&fixture);
}

static void seek_player(Player *player, guint ms, gboolean paused, guint index)
{
	g_assert_true(gst_element_seek(player->pipeline, 1.0, GST_FORMAT_TIME,
	                               GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE,
	                               GST_SEEK_TYPE_SET, ms * GST_MSECOND,
	                               GST_SEEK_TYPE_NONE, GST_CLOCK_TIME_NONE));
	GstState current;
	g_assert_cmpint(gst_element_get_state(player->pipeline, &current, NULL,
	                                     TIMEOUT), ==, GST_STATE_CHANGE_SUCCESS);
	g_assert_cmpint(current, ==, paused ? GST_STATE_PAUSED : GST_STATE_PLAYING);
	GstSample *sample = pull(player, paused, index);
	gst_sample_unref(sample);
}

static void test_transport_seek(gconstpointer data)
{
	gboolean paused = GPOINTER_TO_INT(data);
	Fixture fixture = fixture_new(animation(1, FALSE));
	Player player = player_new(fixture.uri,
	                           paused ? GST_STATE_PAUSED : GST_STATE_PLAYING);
	GstSample *held = pull(&player, paused, 0);
	seek_player(&player, 140, paused, 3);
	seek_player(&player, 2, paused, 1);
	seek_player(&player, 28, paused, 2);
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
	seek_player(&player, 384, FALSE, 4);
	assert_eos(&player);
	player_clear(&player);
	assert_frame(held, 0);
	gst_sample_unref(held);
	fixture_clear(&fixture);
}

static void test_seek_boundaries(void)
{
	Fixture fixture = fixture_new(animation(1, FALSE));
	VideoAnimation *webp = open_animation(fixture.uri);
	for (guint i = 0; i < G_N_ELEMENTS(expected); ++i) {
		seek_animation(webp, pts_ms[i] * GST_MSECOND);
		GstSample *sample = next_sample(webp);
		assert_frame(sample, i);
		gst_sample_unref(sample);
		/* The final nanosecond still belongs to this frame, not its successor. */
		seek_animation(webp, (pts_ms[i] + durations_ms[i]) * GST_MSECOND - 1);
		sample = next_sample(webp);
		assert_frame(sample, i);
		gst_sample_unref(sample);
	}
	seek_animation(webp, webp->metadata.duration);
	g_assert_null(next_sample(webp));
	g_assert_null(next_sample(webp));
	GError *error = NULL;
	g_mutex_lock(&webp->lock);
	g_assert_false(webp->ops->seek(webp, webp->metadata.duration + 1, &error));
	g_mutex_unlock(&webp->lock);
	g_assert_error(error, GST_STREAM_ERROR, GST_STREAM_ERROR_DECODE);
	g_clear_error(&error);
	seek_animation(webp, 0);
	GstSample *sample = next_sample(webp);
	assert_frame(sample, 0);
	video_animation_unref(webp);
	assert_frame(sample, 0);
	gst_sample_unref(sample);
	fixture_clear(&fixture);
}

static void test_zero_delay(void)
{
	Fixture fixture = fixture_new(animation(1, TRUE));
	VideoAnimation *webp = open_animation(fixture.uri);
	const guint delays[] = {100, 27, 100, 250, 7};
	guint elapsed = 0;
	g_assert_cmpuint(webp->metadata.duration, ==, 484 * GST_MSECOND);
	for (guint i = 0; i < G_N_ELEMENTS(expected); ++i) {
		GstSample *sample = next_sample(webp);
		assert_pixels(sample, i);
		GstBuffer *buffer = gst_sample_get_buffer(sample);
		g_assert_cmpuint(GST_BUFFER_PTS(buffer), ==, elapsed * GST_MSECOND);
		g_assert_cmpuint(GST_BUFFER_DURATION(buffer), ==, delays[i] * GST_MSECOND);
		elapsed += delays[i];
		gst_sample_unref(sample);
	}
	g_assert_null(next_sample(webp));
	seek_animation(webp, 126 * GST_MSECOND);
	GstSample *sample = next_sample(webp);
	assert_pixels(sample, 1);
	g_assert_cmpuint(GST_BUFFER_PTS(gst_sample_get_buffer(sample)), ==,
	                 100 * GST_MSECOND);
	gst_sample_unref(sample);
	video_animation_unref(webp);
	fixture_clear(&fixture);
}

static void test_close_backpressure(void)
{
	Fixture fixture = fixture_new(animation(0, FALSE));
	Player player = player_new(fixture.uri, GST_STATE_PLAYING);
	GstSample *held = pull(&player, FALSE, 0);
	/* Do not drain downstream; source cancellation precedes joining tasks. */
	player_clear(&player);
	assert_frame(held, 0);
	gst_sample_unref(held);
	fixture_clear(&fixture);
}

typedef struct {
	VideoAnimation *webp;
	GAsyncQueue *samples;
} Producer;

static gpointer produce_retained_frames(gpointer data)
{
	Producer *producer = data;
	while (!g_atomic_int_get(&producer->webp->flushing)) {
		GError *error = NULL;
		g_mutex_lock(&producer->webp->lock);
		gboolean ready = producer->webp->ops->seek(producer->webp, 0, &error);
		g_mutex_unlock(&producer->webp->lock);
		g_assert_no_error(error);
		if (!ready)
			break;
		for (guint i = 0; i < G_N_ELEMENTS(expected); ++i) {
			GstSample *sample = next_sample(producer->webp);
			if (!sample)
				return NULL;
			g_async_queue_push(producer->samples, sample);
		}
	}
	return NULL;
}

static void test_cancel_retained_frames(void)
{
	if (!g_test_subprocess()) {
		/* A lock-order regression must fail promptly, not hang the suite. */
		g_test_trap_subprocess(NULL, 5 * G_USEC_PER_SEC, 0);
		g_test_trap_assert_passed();
		return;
	}
	Fixture fixture = fixture_new(animation(0, FALSE));
	Producer producer = {.webp = open_animation(fixture.uri),
	                     .samples = g_async_queue_new()};
	GPtrArray *held = g_ptr_array_new_with_free_func((GDestroyNotify)gst_sample_unref);
	GThread *thread = g_thread_new("webp-retained", produce_retained_frames, &producer);
	/* Retain frames until the producer is backpressured, without depending on
	 * the pool's particular capacity.  These tiny frames cannot exhaust RAM. */
	for (guint i = 0; i < 256; ++i) {
		GstSample *sample = g_async_queue_timeout_pop(producer.samples,
		                                             i ? 100000 : G_USEC_PER_SEC);
		if (!sample)
			break;
		assert_frame(sample, i % G_N_ELEMENTS(expected));
		g_ptr_array_add(held, sample);
	}
	video_animation_flush(producer.webp);
	g_thread_join(thread);
	GstSample *sample;
	while ((sample = g_async_queue_try_pop(producer.samples)))
		g_ptr_array_add(held, sample);
	g_mutex_lock(&producer.webp->lock);
	/* Flush is also safe when the caller already owns the decoder lock. */
	video_animation_flush(producer.webp);
	GError *error = NULL;
	g_assert_false(producer.webp->ops->seek(producer.webp, 0, &error));
	g_assert_null(producer.webp->ops->next_frame(producer.webp, &error));
	g_assert_no_error(error);
	g_mutex_unlock(&producer.webp->lock);
	video_animation_unref(producer.webp);
	for (guint i = 0; i < held->len; ++i)
		assert_frame(g_ptr_array_index(held, i), i % G_N_ELEMENTS(expected));
	g_ptr_array_unref(held);
	g_async_queue_unref(producer.samples);
	fixture_clear(&fixture);
}

static void assert_rejected(GByteArray *bytes)
{
	Fixture fixture = fixture_new(bytes);
	GError *error = NULL;
	VideoAnimation *webp = video_animation_new(VIDEO_SOURCE_WEBP, fixture.uri, &error);
	g_assert_null(webp);
	g_assert_error(error, GST_STREAM_ERROR, GST_STREAM_ERROR_DECODE);
	g_clear_error(&error);
	fixture_clear(&fixture);
}

static gsize find_chunk(GByteArray *bytes, const gchar *fourcc, guint nth)
{
	for (gsize offset = 12; offset + 8 <= bytes->len;) {
		guint size = GST_READ_UINT32_LE(bytes->data + offset + 4);
		g_assert_cmpuint(size, <=, bytes->len - offset - 8);
		if (memcmp(bytes->data + offset, fourcc, 4) == 0 && !--nth)
			return offset;
		offset += 8 + size + (size & 1);
	}
	g_error("Fixture has no requested chunk");
	return 0;
}

static void test_truncated(gconstpointer data)
{
	GByteArray *bytes = animation(1, FALSE);
	if (GPOINTER_TO_INT(data)) {
		/* Complete outer RIFF cannot excuse a truncated final ANMF payload. */
		g_byte_array_set_size(bytes, bytes->len - 3);
		GST_WRITE_UINT32_LE(bytes->data + 4, bytes->len - 8);
	} else {
		g_byte_array_set_size(bytes, 21);
	}
	assert_rejected(bytes);
}

static void test_corrupt_later_frame(void)
{
	GByteArray *bytes = animation(1, FALSE);
	gsize offset = find_chunk(bytes, "ANMF", G_N_ELEMENTS(expected));
	gsize payload = offset + 8 + 16;
	g_assert_cmpmem(bytes->data + payload, 4, "VP8L", 4);
	guint length = GST_READ_UINT32_LE(bytes->data + payload + 4);
	g_assert_cmpuint(length, >, 5);
	/* Preserve RIFF, ANMF, VP8L lengths and dimensions.  The demuxer sees a
	 * complete frame; only entropy decoding detects the damaged last image. */
	memset(bytes->data + payload + 8 + 5, 0xff, length - 5);
	Fixture fixture = fixture_new(bytes);
	VideoAnimation *webp = open_animation(fixture.uri);
	for (guint i = 0; i + 1 < G_N_ELEMENTS(expected); ++i) {
		GstSample *sample = next_sample(webp);
		assert_frame(sample, i);
		gst_sample_unref(sample);
	}
	GError *error = NULL;
	g_mutex_lock(&webp->lock);
	GstBuffer *buffer = webp->ops->next_frame(webp, &error);
	g_mutex_unlock(&webp->lock);
	g_assert_null(buffer);
	g_assert_error(error, GST_STREAM_ERROR, GST_STREAM_ERROR_DECODE);
	g_clear_error(&error);
	video_animation_unref(webp);
	fixture_clear(&fixture);
}

static void test_canvas_limit(void)
{
	GByteArray *bytes = animation(1, FALSE);
	gsize offset = find_chunk(bytes, "VP8X", 1);
	/* 8192 x 8192 is legal WebP but exceeds the shared 33554432-pixel limit. */
	const guint8 dimensions[] = {0xff, 0x1f, 0, 0xff, 0x1f, 0};
	memcpy(bytes->data + offset + 8 + 4, dimensions, sizeof dimensions);
	assert_rejected(bytes);
}

static void test_timestamp_overflow(void)
{
	WebPMux *mux = new_mux(1, 1, 1);
	/* 129 maximum 24-bit durations exceed WebPAnimDecoder's signed int time. */
	for (guint i = 0; i < 129; ++i)
		frame(mux, 1, 1, 0, 0xffffff, WEBP_MUX_DISPOSE_NONE,
		      WEBP_MUX_NO_BLEND, over_red);
	assert_rejected(assemble(mux));
}

static void test_static(void)
{
	guint8 *encoded = NULL;
	size_t size = WebPEncodeLosslessRGBA(expected[0], WIDTH, HEIGHT, WIDTH * 4,
	                                    &encoded);
	g_assert_cmpuint(size, >, 0);
	GByteArray *bytes = g_byte_array_new();
	g_byte_array_append(bytes, encoded, size);
	WebPFree(encoded);
	assert_rejected(bytes);
}

static void test_trailing_data(void)
{
	GByteArray *bytes = animation(1, FALSE);
	const guint8 trailing[] = {'A', 'N', 'M', 'F', 255, 255, 255, 255};
	g_byte_array_append(bytes, trailing, sizeof trailing);
	Fixture fixture = fixture_new(bytes);
	VideoAnimation *webp = open_animation(fixture.uri);
	g_assert_cmpuint(webp->metadata.frames, ==, G_N_ELEMENTS(expected));
	seek_animation(webp, 378 * GST_MSECOND);
	GstSample *sample = next_sample(webp);
	assert_frame(sample, 4);
	gst_sample_unref(sample);
	g_assert_null(next_sample(webp));
	video_animation_unref(webp);
	fixture_clear(&fixture);
}

int main(int argc, char **argv)
{
	gst_init(&argc, &argv);
	g_test_init(&argc, &argv, NULL);
	g_test_add_data_func("/video/webp/metadata/forever", GUINT_TO_POINTER(0), test_metadata);
	g_test_add_data_func("/video/webp/metadata/once", GUINT_TO_POINTER(1), test_metadata);
	g_test_add_data_func("/video/webp/metadata/finite", GUINT_TO_POINTER(4), test_metadata);
	g_test_add_func("/video/webp/playback/composition", test_playback);
	g_test_add_data_func("/video/webp/seek/paused", GINT_TO_POINTER(TRUE), test_transport_seek);
	g_test_add_data_func("/video/webp/seek/playing", GINT_TO_POINTER(FALSE), test_transport_seek);
	g_test_add_func("/video/webp/seek/boundaries", test_seek_boundaries);
	g_test_add_func("/video/webp/timing/zero-delay", test_zero_delay);
	g_test_add_func("/video/webp/lifetime/backpressure", test_close_backpressure);
	g_test_add_func("/video/webp/lifetime/cancel-retained", test_cancel_retained_frames);
	g_test_add_data_func("/video/webp/reject/truncated-header", GINT_TO_POINTER(FALSE), test_truncated);
	g_test_add_data_func("/video/webp/reject/truncated-frame", GINT_TO_POINTER(TRUE), test_truncated);
	g_test_add_func("/video/webp/playback/corrupt-later-frame", test_corrupt_later_frame);
	g_test_add_func("/video/webp/reject/canvas-limit", test_canvas_limit);
	g_test_add_func("/video/webp/reject/timestamp-overflow", test_timestamp_overflow);
	g_test_add_func("/video/webp/reject/static", test_static);
	g_test_add_func("/video/webp/playback/trailing-data", test_trailing_data);
	return g_test_run();
}
