/* video-lottie.c --- Lottie raster frames for the existing GstPlay source slot
 *
 * Copyright (C) 2026 0WD0
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <dotlottie_player.h>
#include <gst/app/gstappsrc.h>
#include <gst/video/video.h>
#include <math.h>
#include <string.h>

#include "video-lottie.h"

struct VideoLottie {
	gatomicrefcount refs;
	GMutex lock;
	DotLottiePlayer *player;
	GstAllocator *allocator;
	VideoLottieMetadata metadata;
	GstVideoInfo info;
	GstCaps *caps;
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
	gint flushing;
	gboolean failed;
};

static void lottie_error(GError **error, const gchar *message)
{
	g_set_error_literal(error, GST_STREAM_ERROR, GST_STREAM_ERROR_DECODE,
	                    message);
}

VideoLottie *video_lottie_ref(VideoLottie *lottie)
{
	g_atomic_ref_count_inc(&lottie->refs);
	return lottie;
}

void video_lottie_unref(VideoLottie *lottie)
{
	if (!lottie || !g_atomic_ref_count_dec(&lottie->refs))
		return;
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
	gst_clear_caps(&lottie->caps);
	gst_clear_object(&lottie->allocator);
	g_mutex_clear(&lottie->lock);
	g_free(lottie);
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
	/* v0.1.58 exposes milliseconds, despite the generated C comments. */
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
	if (!gst_video_info_set_format(&lottie->info, format, raster_width,
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
	GST_VIDEO_INFO_FPS_N(&lottie->info) = fps_n;
	GST_VIDEO_INFO_FPS_D(&lottie->info) = fps_d;
	lottie->info.flags |= GST_VIDEO_FLAG_PREMULTIPLIED_ALPHA;
	lottie->caps = gst_video_info_to_caps(&lottie->info);
	lottie->metadata = (VideoLottieMetadata){
	        .width = raster_width,
	        .height = raster_height,
	        .frames = (guint)ceil(clip_frames),
	        .duration = duration,
	        .loop_count = -1,
	};
	if (dotlottie_get_loop(lottie->player)) {
		guint count = dotlottie_get_loop_count(lottie->player);
		if (!count)
			lottie->metadata.loop_count = 0;
		else if (count > 1)
			lottie->metadata.loop_count = (gint64)count - 1;
	}
	return TRUE;
}

VideoLottie *video_lottie_new(const gchar *uri, GError **error)
{
	VideoLottie *lottie = g_new0(VideoLottie, 1);
	g_atomic_ref_count_init(&lottie->refs);
	g_mutex_init(&lottie->lock);
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
	if (lottie->metadata.width == 1 && lottie->metadata.height == 1) {
		gfloat current = 0;
		if (dotlottie_get_current_frame(lottie->player, &current) ==
		            DOTLOTTIE_SUCCESS) {
			lottie->cached_buffer = gst_buffer_ref(lottie->bound_buffer);
			lottie->cached_frame = current;
		}
	}
	return lottie;
failed:
	video_lottie_unref(lottie);
	return NULL;
}

const VideoLottieMetadata *video_lottie_get_metadata(VideoLottie *lottie)
{
	return &lottie->metadata;
}

static gboolean lottie_prepare_pool(VideoLottie *lottie, GError **error)
{
	if (lottie->pool)
		return TRUE;
	GstBufferPool *pool = gst_buffer_pool_new();
	GstStructure *config = gst_buffer_pool_get_config(pool);
	GstAllocationParams params;
	gst_allocation_params_init(&params);
	gst_buffer_pool_config_set_params(config, lottie->caps,
	                                  lottie->info.size, 4, 4);
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
	                            (guint64)GST_VIDEO_INFO_FPS_D(&lottie->info) *
	                                    GST_SECOND,
	                            GST_VIDEO_INFO_FPS_N(&lottie->info));
}

/* Caller holds the player lock.  New data is written exactly once, before
 * publishing; repeated poses share pixels, never writable buffer headers. */
static GstBuffer *lottie_render_frame(VideoLottie *lottie, guint index,
                                      GError **error)
{
	gfloat frame = MIN(lottie->first_frame + index, lottie->last_frame);
	GstClockTime pts = lottie_frame_time(lottie, index);
	GstClockTime end = MIN(lottie_frame_time(lottie, index + 1),
	                       lottie->metadata.duration);
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
	                            lottie->metadata.width,
	                            lottie->metadata.height, ARGB8888) !=
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

static void source_need_data(GstAppSrc *source, guint length, gpointer data)
{
	VideoLottie *lottie = data;
	(void)length;
	GError *error = NULL;
	GstBuffer *buffer = NULL;
	gboolean eos = FALSE;
	g_mutex_lock(&lottie->lock);
	if (!g_atomic_int_get(&lottie->flushing) && !lottie->failed) {
		if (lottie->next_frame >= lottie->metadata.frames ||
		    lottie_frame_time(lottie, lottie->next_frame) >=
		            lottie->metadata.duration) {
			eos = TRUE;
		} else {
			buffer = lottie_render_frame(lottie, lottie->next_frame,
			                             &error);
			if (buffer)
				++lottie->next_frame;
			else if (error)
				lottie->failed = TRUE;
		}
	}
	g_mutex_unlock(&lottie->lock);
	if (error) {
		GST_ELEMENT_ERROR(source, STREAM, DECODE,
		                  ("%s", error->message), (NULL));
		g_error_free(error);
	} else if (buffer) {
		/* push_buffer consumes our reference, including when flushing. */
		GstFlowReturn flow = gst_app_src_push_buffer(source, buffer);
		if (flow != GST_FLOW_OK && flow != GST_FLOW_FLUSHING &&
		    flow != GST_FLOW_EOS)
			GST_ELEMENT_ERROR(source, STREAM, FAILED,
			                  ("Could not publish a Lottie frame"),
			                  ("%s", gst_flow_get_name(flow)));
	} else if (eos) {
		gst_app_src_end_of_stream(source);
	}
}

static gboolean source_seek_data(GstAppSrc *source, guint64 offset,
                                  gpointer data)
{
	VideoLottie *lottie = data;
	(void)source;
	if (offset > lottie->metadata.duration ||
	    g_atomic_int_get(&lottie->flushing))
		return FALSE;
	g_mutex_lock(&lottie->lock);
	guint64 frame = gst_util_uint64_scale(
	        offset, GST_VIDEO_INFO_FPS_N(&lottie->info),
	        (guint64)GST_VIDEO_INFO_FPS_D(&lottie->info) * GST_SECOND);
	lottie->next_frame = offset == lottie->metadata.duration
	                             ? lottie->metadata.frames
	                             : MIN(frame, lottie->metadata.frames);
	g_mutex_unlock(&lottie->lock);
	return TRUE;
}

static void source_release(gpointer data)
{
	video_lottie_unref(data);
}

gboolean video_lottie_configure_source(VideoLottie *lottie, GstElement *source,
                                        GError **error)
{
	if (!GST_IS_APP_SRC(source)) {
		lottie_error(error, "Lottie playback source is not appsrc");
		return FALSE;
	}
	g_mutex_lock(&lottie->lock);
	gboolean ready = !g_atomic_int_get(&lottie->flushing) &&
	                 !lottie->failed && lottie_prepare_pool(lottie, error);
	if (ready)
		lottie->next_frame = 0;
	g_mutex_unlock(&lottie->lock);
	if (!ready) {
		if (error && !*error)
			lottie_error(error, "Lottie playback source is closed");
		return FALSE;
	}
	gst_app_src_set_caps(GST_APP_SRC(source), lottie->caps);
	gst_app_src_set_duration(GST_APP_SRC(source), lottie->metadata.duration);
	gst_app_src_set_size(GST_APP_SRC(source),
	                     (gint64)lottie->metadata.frames * lottie->info.size);
	g_object_set(source, "format", GST_FORMAT_TIME,
	             "stream-type", GST_APP_STREAM_TYPE_SEEKABLE,
	             "is-live", FALSE, "block", TRUE,
	             "max-bytes", (guint64)0, "max-buffers", (guint64)2,
	             "emit-signals", FALSE, NULL);
	GstAppSrcCallbacks callbacks = {
	        .need_data = source_need_data,
	        .seek_data = source_seek_data,
	};
	gst_app_src_set_callbacks(GST_APP_SRC(source), &callbacks,
	                           video_lottie_ref(lottie), source_release);
	return TRUE;
}

void video_lottie_flush(VideoLottie *lottie)
{
	g_atomic_int_set(&lottie->flushing, TRUE);
	/* Pool is installed before publishing the source to the session.  Do
	 * not acquire the player lock: its streaming callback may wait here. */
	if (lottie->pool)
		gst_buffer_pool_set_flushing(lottie->pool, TRUE);
}

gboolean video_lottie_read_metadata(const gchar *uri,
                                     VideoLottieMetadata *metadata,
                                     GError **error)
{
	VideoLottie *lottie = video_lottie_new(uri, error);
	if (!lottie)
		return FALSE;
	*metadata = lottie->metadata;
	video_lottie_unref(lottie);
	return TRUE;
}

GstSample *video_lottie_first_frame(const gchar *uri, GError **error)
{
	VideoLottie *lottie = video_lottie_new(uri, error);
	if (!lottie)
		return NULL;
	GstSample *sample = NULL;
	if (lottie_prepare_pool(lottie, error)) {
		GstBuffer *buffer = lottie_render_frame(lottie, 0, error);
		if (buffer) {
			sample = gst_sample_new(buffer, lottie->caps, NULL, NULL);
			gst_buffer_unref(buffer);
		}
	}
	video_lottie_unref(lottie);
	return sample;
}
