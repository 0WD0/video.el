/* video-lottie.c --- Lottie raster frames for the existing GstPlay source slot
 *
 * Copyright (C) 2026 0WD0
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <dotlottie_player.h>
#include <math.h>
#include <string.h>

#include "video-lottie.h"

typedef struct {
	VideoAnimation animation;
	DotLottiePlayer *player;
	GstAllocator *allocator;
	GstBufferPool *pool;
	/* The renderer retains its target address.  System-memory buffers keep
	 * that address stable after unmapping, until rebinding or destruction. */
	GstBuffer *bound_buffer;
	GstBuffer *cached_buffer;
	GstBuffer *failed_buffer;
	gfloat cached_frame;
	gfloat first_frame;
	gfloat last_frame;
	guint next_frame;
} VideoLottie;

static GstBuffer *lottie_next_frame(VideoAnimation *animation, GError **error);
static gboolean lottie_seek(VideoAnimation *animation, GstClockTime offset,
                            GError **error);
static void lottie_flush(VideoAnimation *animation);
static void lottie_destroy(VideoAnimation *animation);

static const VideoAnimationOps lottie_ops = {
        .name = "Lottie",
        .block = TRUE,
        .next_frame = lottie_next_frame,
        .seek = lottie_seek,
        .flush = lottie_flush,
        .destroy = lottie_destroy,
};

static void lottie_error(GError **error, const gchar *message)
{
	g_set_error_literal(error, GST_STREAM_ERROR, GST_STREAM_ERROR_DECODE,
	                    message);
}

static void lottie_destroy(VideoAnimation *animation)
{
	VideoLottie *lottie = (VideoLottie *)animation;
	/* Destroy before releasing any possible retained render target. */
	if (lottie->player)
		dotlottie_destroy(lottie->player);
	gst_clear_buffer(&lottie->bound_buffer);
	gst_clear_buffer(&lottie->cached_buffer);
	gst_clear_buffer(&lottie->failed_buffer);
	if (lottie->pool) {
		gst_buffer_pool_set_active(lottie->pool, FALSE);
		gst_object_unref(lottie->pool);
	}
	gst_clear_object(&lottie->allocator);
}

static gboolean lottie_load(VideoLottie *lottie, const gchar *uri,
                              GError **error)
{
	gchar *path = g_filename_from_uri(uri, NULL, error);
	gchar *contents = NULL;
	gsize length = 0;
	gboolean loaded = FALSE;
	if (!path)
		return FALSE;
	if (!g_file_get_contents(path, &contents, &length, error))
		goto done;
	if (length >= 4 && memcmp(contents, "PK\003\004", 4) == 0) {
		loaded = dotlottie_load_dotlottie_data(lottie->player, contents,
		                                      length) == DOTLOTTIE_SUCCESS;
	} else if (!memchr(contents, '\0', length)) {
		loaded = dotlottie_load_animation_data(lottie->player, contents) ==
		         DOTLOTTIE_SUCCESS;
	}
	if (!loaded)
		lottie_error(error, "Could not load local Lottie animation");
done:
	g_free(contents);
	g_free(path);
	return loaded;
}

static gboolean lottie_read_info(VideoLottie *lottie, GError **error)
{
	gfloat width = 0.0f, height = 0.0f, frames = 0.0f, duration_ms = 0.0f;
	if (dotlottie_get_animation_size(lottie->player, &width, &height) !=
	            DOTLOTTIE_SUCCESS ||
	    dotlottie_get_total_frames(lottie->player, &frames) !=
	            DOTLOTTIE_SUCCESS ||
	    dotlottie_get_duration(lottie->player, &duration_ms) !=
	            DOTLOTTIE_SUCCESS ||
	    !isfinite(width) || !isfinite(height) || !isfinite(frames) ||
	    !isfinite(duration_ms) || width <= 0 || height <= 0 || frames < 1 ||
	    duration_ms <= 0 || width > G_MAXINT || height > G_MAXINT ||
	    (gdouble)frames > G_MAXUINT ||
	    duration_ms >= (gdouble)GST_CLOCK_TIME_NONE / GST_MSECOND) {
		lottie_error(error, "Invalid Lottie dimensions or timing");
		return FALSE;
	}
	guint raster_width = (guint)ceil((gdouble)width);
	guint raster_height = (guint)ceil((gdouble)height);
	if ((guint64)raster_width * raster_height > 33554432) {
		lottie_error(error, "Lottie surface exceeds the Canvas pixel limit");
		return FALSE;
	}
	lottie->first_frame = 0.0f;
	lottie->last_frame = frames - 1.0f;
	gfloat segment[2];
	if (dotlottie_get_segment(lottie->player, &segment) == DOTLOTTIE_SUCCESS) {
		if (!isfinite(segment[0]) || !isfinite(segment[1]) ||
		    segment[0] < 0 || segment[1] < segment[0] ||
		    segment[1] > frames - 1.0f) {
			lottie_error(error, "Invalid Lottie animation segment");
			return FALSE;
		}
		lottie->first_frame = segment[0];
		lottie->last_frame = segment[1];
	}
	gdouble clip_frames = (gdouble)lottie->last_frame -
	                      lottie->first_frame + 1.0;
	/* The source renderer converts ThorVG seconds to milliseconds. */
	GstClockTime duration = (GstClockTime)
	        ((gdouble)duration_ms * GST_MSECOND * clip_frames / frames);
	if (!duration) {
		lottie_error(error, "Lottie duration is shorter than one nanosecond");
		return FALSE;
	}
	GstVideoFormat format;
#if G_BYTE_ORDER == G_LITTLE_ENDIAN
	format = GST_VIDEO_FORMAT_BGRA;
#else
	format = GST_VIDEO_FORMAT_ARGB;
#endif
	if (!gst_video_info_set_format(&lottie->animation.info, format, raster_width,
	                               raster_height)) {
		lottie_error(error, "Could not describe Lottie pixels");
		return FALSE;
	}
	gint fps_n = 0, fps_d = 0;
	gst_util_double_to_fraction((gdouble)frames * 1000.0 / duration_ms,
	                           &fps_n, &fps_d);
	if (fps_n <= 0 || fps_d <= 0) {
		lottie_error(error, "Invalid Lottie frame rate");
		return FALSE;
	}
	GST_VIDEO_INFO_FPS_N(&lottie->animation.info) = fps_n;
	GST_VIDEO_INFO_FPS_D(&lottie->animation.info) = fps_d;
	lottie->animation.info.flags |= GST_VIDEO_FLAG_PREMULTIPLIED_ALPHA;
	lottie->animation.caps = gst_video_info_to_caps(&lottie->animation.info);
	lottie->animation.metadata = (VideoAnimationMetadata){
	        .width = raster_width,
	        .height = raster_height,
	        .frames = (guint)ceil(clip_frames),
	        .duration = duration,
	        .loop_count = -1,
	};
	if (dotlottie_get_loop(lottie->player)) {
		guint count = dotlottie_get_loop_count(lottie->player);
		if (!count)
			lottie->animation.metadata.loop_count = 0;
		else if (count > 1)
			lottie->animation.metadata.loop_count = (gint64)count - 1;
	}
	return TRUE;
}

VideoAnimation *video_lottie_new(const gchar *uri, GError **error)
{
	VideoLottie *lottie = g_new0(VideoLottie, 1);
	video_animation_init(&lottie->animation, &lottie_ops);
	lottie->allocator = gst_allocator_find(GST_ALLOCATOR_SYSMEM);
	lottie->player = dotlottie_new_player(0);
	if (!lottie->allocator || !lottie->player) {
		lottie_error(error, "Could not initialize the Lottie renderer");
		goto failed;
	}
	lottie->bound_buffer = gst_buffer_new_allocate(lottie->allocator, 4, NULL);
	GstMapInfo map;
	if (!lottie->bound_buffer ||
	    !gst_buffer_map(lottie->bound_buffer, &map, GST_MAP_WRITE)) {
		lottie_error(error, "Could not allocate the Lottie metadata target");
		goto failed;
	}
	gboolean loaded =
	        dotlottie_set_sw_target(lottie->player, (uint32_t *)map.data,
	                                1, 1, ARGB8888) == DOTLOTTIE_SUCCESS &&
	        lottie_load(lottie, uri, error);
	gst_buffer_unmap(lottie->bound_buffer, &map);
	if (!loaded) {
		if (error && !*error)
			lottie_error(error, "Could not bind the Lottie metadata target");
		goto failed;
	}
	if (!lottie_read_info(lottie, error))
		goto failed;
	if (lottie->animation.metadata.width == 1 && lottie->animation.metadata.height == 1) {
		gfloat current = 0;
		if (dotlottie_get_current_frame(lottie->player, &current) ==
		            DOTLOTTIE_SUCCESS) {
			lottie->cached_buffer = gst_buffer_ref(lottie->bound_buffer);
			lottie->cached_frame = current;
		}
	}
	return &lottie->animation;
failed:
	video_animation_unref(&lottie->animation);
	return NULL;
}

static gboolean lottie_prepare_pool(VideoLottie *lottie, GError **error)
{
	if (lottie->pool)
		return TRUE;
	GstBufferPool *pool = gst_buffer_pool_new();
	GstStructure *config = gst_buffer_pool_get_config(pool);
	GstAllocationParams params;
	gst_allocation_params_init(&params);
	gst_buffer_pool_config_set_params(config, lottie->animation.caps,
	                                  lottie->animation.info.size, 4, 4);
	gst_buffer_pool_config_set_allocator(config, lottie->allocator, &params);
	if (!gst_buffer_pool_set_config(pool, config) ||
	    !gst_buffer_pool_set_active(pool, TRUE)) {
		gst_object_unref(pool);
		lottie_error(error, "Could not prepare the Lottie frame pool");
		return FALSE;
	}
	lottie->pool = pool;
	return TRUE;
}

static GstClockTime lottie_frame_time(VideoLottie *lottie, guint frame)
{
	return gst_util_uint64_scale(frame,
	                            (guint64)GST_VIDEO_INFO_FPS_D(&lottie->animation.info) *
	                                    GST_SECOND,
	                            GST_VIDEO_INFO_FPS_N(&lottie->animation.info));
}

/* Caller holds the player lock.  New data is written exactly once, before
 * publishing; repeated poses share pixels, never writable buffer headers. */
static GstBuffer *lottie_render_frame(VideoLottie *lottie, guint index,
                                      GError **error)
{
	gfloat frame = MIN(lottie->first_frame + index, lottie->last_frame);
	GstClockTime pts = lottie_frame_time(lottie, index);
	GstClockTime end = MIN(lottie_frame_time(lottie, index + 1),
	                       lottie->animation.metadata.duration);
	if (lottie->cached_buffer &&
	    fabsf(frame - lottie->cached_frame) <= 0.0009f) {
		GstBuffer *buffer = lottie->cached_buffer;
		if (GST_BUFFER_PTS(buffer) == pts &&
		    GST_BUFFER_DURATION(buffer) == end - pts)
			return gst_buffer_ref(buffer);
		/* gst_buffer_copy shares memory; only the timestamp header is new. */
		buffer = gst_buffer_copy(buffer);
		GST_BUFFER_PTS(buffer) = pts;
		GST_BUFFER_DURATION(buffer) = end - pts;
		return buffer;
	}

	GstBuffer *buffer = NULL;
	GstFlowReturn flow = gst_buffer_pool_acquire_buffer(lottie->pool,
	                                                   &buffer, NULL);
	if (flow != GST_FLOW_OK) {
		if (flow != GST_FLOW_FLUSHING)
			lottie_error(error, "Could not acquire a Lottie frame");
		return NULL;
	}
	GST_BUFFER_PTS(buffer) = pts;
	GST_BUFFER_DURATION(buffer) = end - pts;
	GstMapInfo map;
	if (!gst_buffer_map(buffer, &map, GST_MAP_WRITE)) {
		lottie_error(error, "Could not map a Lottie frame");
		gst_buffer_unref(buffer);
		return NULL;
	}
	if (dotlottie_set_sw_target(lottie->player, (uint32_t *)map.data,
	                            lottie->animation.metadata.width,
	                            lottie->animation.metadata.height, ARGB8888) !=
	            DOTLOTTIE_SUCCESS) {
		/* A failed target call may have changed either side of the binding.
		 * Keep both allocations valid until destruction. */
		lottie->failed_buffer = gst_buffer_ref(buffer);
		lottie_error(error, "Could not bind a Lottie frame target");
		goto failed;
	}
	gst_clear_buffer(&lottie->bound_buffer);
	lottie->bound_buffer = gst_buffer_ref(buffer);
	gfloat current = 0;
	if (dotlottie_get_current_frame(lottie->player, &current) !=
	            DOTLOTTIE_SUCCESS ||
	    (fabsf(frame - current) > 0.0009f &&
	     dotlottie_set_frame(lottie->player, frame) != DOTLOTTIE_SUCCESS) ||
	    dotlottie_render(lottie->player) != DOTLOTTIE_SUCCESS) {
		lottie_error(error, "Could not render a Lottie frame");
		goto failed;
	}
	gst_clear_buffer(&lottie->cached_buffer);
	lottie->cached_buffer = gst_buffer_ref(buffer);
	lottie->cached_frame = frame;
	gst_buffer_unmap(buffer, &map);
	return buffer;
failed:
	gst_buffer_unmap(buffer, &map);
	gst_buffer_unref(buffer);
	return NULL;
}

static GstBuffer *lottie_next_frame(VideoAnimation *animation, GError **error)
{
	VideoLottie *lottie = (VideoLottie *)animation;
	if (lottie->next_frame >= animation->metadata.frames ||
	    lottie_frame_time(lottie, lottie->next_frame) >=
	            animation->metadata.duration)
		return NULL;
	GstBuffer *buffer = lottie_render_frame(lottie, lottie->next_frame, error);
	if (buffer)
		++lottie->next_frame;
	return buffer;
}

static gboolean lottie_seek(VideoAnimation *animation, GstClockTime offset,
                            GError **error)
{
	VideoLottie *lottie = (VideoLottie *)animation;
	if (!lottie_prepare_pool(lottie, error))
		return FALSE;
	guint64 frame = gst_util_uint64_scale(
	        offset, GST_VIDEO_INFO_FPS_N(&animation->info),
	        (guint64)GST_VIDEO_INFO_FPS_D(&animation->info) * GST_SECOND);
	lottie->next_frame = offset == animation->metadata.duration
	                             ? animation->metadata.frames
	                             : MIN(frame, animation->metadata.frames);
	return TRUE;
}

static void lottie_flush(VideoAnimation *animation)
{
	VideoLottie *lottie = (VideoLottie *)animation;
	/* Pool is installed before publishing the source to the session.  Do
	 * not acquire the player lock: its streaming callback may wait here. */
	if (lottie->pool)
		gst_buffer_pool_set_flushing(lottie->pool, TRUE);
}
