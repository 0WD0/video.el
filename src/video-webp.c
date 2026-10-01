/* video-webp.c --- libwebp animation frames for the existing GstPlay source slot
 *
 * Copyright (C) 2026 0WD0
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <string.h>
#include <webp/demux.h>

#include "video-webp.h"

#define WEBP_MAX_PIXELS 33554432

/* Enough for appsrc's queue, downstream/preroll and retained display samples.
 * Allocate lazily, and reuse returned buffers rather than caching all frames. */
#define WEBP_POOL_BUFFERS 8

typedef struct {
	VideoAnimation animation;
	GMappedFile *mapped;
	WebPAnimDecoder *decoder;
	WebPIterator iterator;
	gboolean iterator_valid;
	GstBufferPool *pool;
	guint next_frame;
	gint raw_end_ms;
	GstClockTime next_time;
	GstClockTime frame_pts;
	GstClockTime frame_duration;
	guint8 *pixels;
	gboolean pending;
} VideoWebp;

static void webp_error(GError **error, const gchar *message)
{
	g_set_error_literal(error, GST_STREAM_ERROR, GST_STREAM_ERROR_DECODE,
	                    message);
}

static void webp_flush(VideoAnimation *animation)
{
	VideoWebp *webp = (VideoWebp *)animation;
	/* The pool is installed before publishing the animation.  Never acquire
	 * the animation lock: next_frame may hold it while waiting for a buffer. */
	if (webp->pool)
		gst_buffer_pool_set_flushing(webp->pool, TRUE);
}

static void webp_destroy(VideoAnimation *animation)
{
	VideoWebp *webp = (VideoWebp *)animation;
	if (webp->iterator_valid)
		WebPDemuxReleaseIterator(&webp->iterator);
	if (webp->decoder)
		WebPAnimDecoderDelete(webp->decoder);
	if (webp->mapped)
		g_mapped_file_unref(webp->mapped);
	if (webp->pool) {
		/* Outstanding buffers keep their pool/storage alive after deactivation. */
		gst_buffer_pool_set_active(webp->pool, FALSE);
		gst_object_unref(webp->pool);
	}
}

static gboolean webp_scan(VideoWebp *webp, WebPData *data, GError **error)
{
	/* Demuxing does not allocate a pixel canvas.  Check both the complete RIFF
	 * envelope and all timing/dimension bounds before creating the decoder. */
	if (data->size < 12 || memcmp(data->bytes, "RIFF", 4) != 0 ||
	    memcmp(data->bytes + 8, "WEBP", 4) != 0 ||
	    GST_READ_UINT32_LE(data->bytes + 4) < 4 ||
	    (guint64)GST_READ_UINT32_LE(data->bytes + 4) + 8 > data->size) {
		webp_error(error, "Invalid or incomplete WebP RIFF stream");
		return FALSE;
	}
	/* RIFF's declared extent is the stream; unrelated trailing bytes are not
	 * animation chunks and must not hide an incomplete declared payload. */
	data->size = (gsize)GST_READ_UINT32_LE(data->bytes + 4) + 8;
	WebPDemuxState state;
	WebPDemuxer *demux = WebPDemuxPartial(data, &state);
	gboolean valid = FALSE;
	if (!demux || state != WEBP_DEMUX_DONE ||
	    !(WebPDemuxGetI(demux, WEBP_FF_FORMAT_FLAGS) & ANIMATION_FLAG)) {
		webp_error(error, "Source is not a complete animated WebP stream");
		goto done;
	}
	VideoAnimationMetadata *metadata = &webp->animation.metadata;
	metadata->width = WebPDemuxGetI(demux, WEBP_FF_CANVAS_WIDTH);
	metadata->height = WebPDemuxGetI(demux, WEBP_FF_CANVAS_HEIGHT);
	metadata->frames = WebPDemuxGetI(demux, WEBP_FF_FRAME_COUNT);
	guint plays = WebPDemuxGetI(demux, WEBP_FF_LOOP_COUNT);
	metadata->loop_count = plays == 0 ? 0 : plays == 1 ? -1 : (gint64)plays - 1;
	if (!metadata->width || !metadata->height ||
	    (guint64)metadata->width * metadata->height > WEBP_MAX_PIXELS) {
		webp_error(error, "WebP dimensions exceed the Canvas pixel limit");
		goto done;
	}
	if (!metadata->frames || metadata->frames > G_MAXINT) {
		webp_error(error, "Invalid WebP frame count");
		goto done;
	}
	WebPIterator iterator;
	if (!WebPDemuxGetFrame(demux, 1, &iterator)) {
		webp_error(error, "WebP animation has no first frame");
		goto done;
	}
	guint frames = 0;
	guint64 raw_ms = 0, duration_ms = 0;
	do {
		if (!iterator.complete || iterator.duration < 0 ||
		    iterator.width <= 0 || iterator.height <= 0 ||
		    iterator.x_offset < 0 || iterator.y_offset < 0 ||
		    (guint64)iterator.x_offset + iterator.width > metadata->width ||
		    (guint64)iterator.y_offset + iterator.height > metadata->height) {
			webp_error(error, "Invalid WebP animation frame");
			goto release;
		}
		raw_ms += iterator.duration;
		/* Preserve every positive duration; zero means 100 ms to prevent a
		 * zero-duration playback spin.  libwebp itself still sees raw time. */
		duration_ms += iterator.duration ? iterator.duration : 100;
		/* WebPAnimDecoder returns signed int millisecond timestamps. */
		if (raw_ms > G_MAXINT || duration_ms > G_MAXINT64 / GST_MSECOND) {
			webp_error(error, "WebP duration exceeds the supported time range");
			goto release;
		}
		++frames;
	} while (WebPDemuxNextFrame(&iterator));
	if (frames != metadata->frames) {
		webp_error(error, "WebP animation has missing frames");
		goto release;
	}
	metadata->duration = duration_ms * GST_MSECOND;
	valid = TRUE;
release:
	WebPDemuxReleaseIterator(&iterator);
done:
	if (demux)
		WebPDemuxDelete(demux);
	return valid;
}

static gboolean webp_restart(VideoWebp *webp, GError **error)
{
	if (g_atomic_int_get(&webp->animation.flushing))
		return FALSE;
	if (webp->iterator_valid) {
		WebPDemuxReleaseIterator(&webp->iterator);
		webp->iterator_valid = FALSE;
	}
	WebPAnimDecoderReset(webp->decoder);
	webp->pixels = NULL;
	webp->pending = FALSE;
	webp->next_frame = 0;
	webp->raw_end_ms = 0;
	webp->next_time = 0;
	if (!WebPDemuxGetFrame(WebPAnimDecoderGetDemuxer(webp->decoder),
	                      1, &webp->iterator)) {
		webp_error(error, "Could not reset the WebP animation");
		return FALSE;
	}
	webp->iterator_valid = TRUE;
	return TRUE;
}

/* Decode into libwebp's reusable composited canvas.  Seek replay uses this
 * path without acquiring or copying consumer buffers. */
static gboolean webp_decode_next(VideoWebp *webp, GError **error)
{
	VideoAnimation *animation = &webp->animation;
	if (g_atomic_int_get(&animation->flushing))
		return FALSE;
	gint duration_ms = webp->iterator.duration;
	gint timestamp;
	if (duration_ms < 0 || duration_ms > G_MAXINT - webp->raw_end_ms ||
	    !WebPAnimDecoderGetNext(webp->decoder, &webp->pixels, &timestamp) ||
	    !webp->pixels || timestamp != webp->raw_end_ms + duration_ms) {
		webp_error(error, "Could not decode a complete WebP frame");
		return FALSE;
	}
	webp->frame_pts = webp->next_time;
	webp->frame_duration = (GstClockTime)(duration_ms ? duration_ms : 100) *
	                       GST_MSECOND;
	webp->next_time += webp->frame_duration;
	webp->raw_end_ms = timestamp;
	++webp->next_frame;
	if (webp->next_frame < animation->metadata.frames) {
		if (!WebPDemuxNextFrame(&webp->iterator)) {
			webp_error(error, "WebP animation has missing frames");
			return FALSE;
		}
	} else if (WebPAnimDecoderHasMoreFrames(webp->decoder) ||
	           webp->next_time != animation->metadata.duration) {
		webp_error(error, "Invalid WebP animation frame count or duration");
		return FALSE;
	}
	webp->pending = TRUE;
	return TRUE;
}

static GstBuffer *webp_next_frame(VideoAnimation *animation, GError **error)
{
	VideoWebp *webp = (VideoWebp *)animation;
	if (g_atomic_int_get(&animation->flushing) ||
	    (!webp->pending && webp->next_frame >= animation->metadata.frames))
		return NULL;
	if (!webp->pending && !webp_decode_next(webp, error))
		return NULL;
	GstBuffer *buffer = NULL;
	GstFlowReturn flow = gst_buffer_pool_acquire_buffer(webp->pool,
	                                                   &buffer, NULL);
	if (flow != GST_FLOW_OK) {
		if (flow != GST_FLOW_FLUSHING)
			webp_error(error, "Could not acquire a WebP frame");
		return NULL;
	}
	if (g_atomic_int_get(&animation->flushing)) {
		gst_buffer_unref(buffer);
		return NULL;
	}
	GstMapInfo map;
	if (!gst_buffer_map(buffer, &map, GST_MAP_WRITE)) {
		webp_error(error, "Could not map a WebP frame");
		gst_buffer_unref(buffer);
		return NULL;
	}
	/* MODE_RGBA is tightly packed, straight alpha.  The one necessary copy
	 * isolates retained samples from libwebp's mutable composition canvas. */
	memcpy(map.data, webp->pixels, animation->info.size);
	gst_buffer_unmap(buffer, &map);
	GST_BUFFER_PTS(buffer) = webp->frame_pts;
	GST_BUFFER_DURATION(buffer) = webp->frame_duration;
	webp->pending = FALSE;
	return buffer;
}

static gboolean webp_seek(VideoAnimation *animation, GstClockTime offset,
                           GError **error)
{
	VideoWebp *webp = (VideoWebp *)animation;
	if (g_atomic_int_get(&animation->flushing))
		return FALSE;
	if (offset > animation->metadata.duration) {
		webp_error(error, "WebP seek is outside the animation duration");
		return FALSE;
	}
	if (offset == animation->metadata.duration) {
		webp->pending = FALSE;
		webp->pixels = NULL;
		webp->next_frame = animation->metadata.frames;
		return TRUE;
	}
	/* Reusing the current canvas also avoids decoding appsrc's initial
	 * zero seek twice.  Replaying earlier frames publishes no skipped pixels. */
	if (webp->pixels && offset >= webp->frame_pts && offset < webp->next_time) {
		webp->pending = TRUE;
		return TRUE;
	}
	if ((offset < webp->next_time ||
	     webp->next_frame >= animation->metadata.frames) &&
	    !webp_restart(webp, error))
		return FALSE;
	do {
		if (!webp_decode_next(webp, error))
			return FALSE;
	} while (webp->next_time <= offset);
	return TRUE;
}

static const VideoAnimationOps webp_ops = {
	.name = "WebP",
	.block = TRUE,
	.next_frame = webp_next_frame,
	.seek = webp_seek,
	.flush = webp_flush,
	.destroy = webp_destroy,
};

VideoAnimation *video_webp_new(const gchar *uri, GError **error)
{
	VideoWebp *webp = g_new0(VideoWebp, 1);
	VideoAnimation *animation = &webp->animation;
	video_animation_init(animation, &webp_ops);
	gchar *hostname = NULL;
	gchar *path = g_filename_from_uri(uri, &hostname, error);
	gboolean local = !hostname || !*hostname ||
	                 g_ascii_strcasecmp(hostname, "localhost") == 0;
	g_free(hostname);
	if (!path)
		goto failed;
	if (!local || !g_file_test(path, G_FILE_TEST_IS_REGULAR)) {
		g_free(path);
		webp_error(error, "WebP playback requires a local regular file URI");
		goto failed;
	}
	webp->mapped = g_mapped_file_new(path, FALSE, error);
	g_free(path);
	if (!webp->mapped)
		goto failed;
	WebPData data = {
		.bytes = (const guint8 *)g_mapped_file_get_contents(webp->mapped),
		.size = g_mapped_file_get_length(webp->mapped),
	};
	if (!webp_scan(webp, &data, error))
		goto failed;
	WebPAnimDecoderOptions options;
	if (!WebPAnimDecoderOptionsInit(&options)) {
		webp_error(error, "Could not initialize the WebP decoder options");
		goto failed;
	}
	options.color_mode = MODE_RGBA;
	webp->decoder = WebPAnimDecoderNew(&data, &options);
	if (!webp->decoder) {
		webp_error(error, "Could not create the WebP animation decoder");
		goto failed;
	}
	if (!webp_restart(webp, error))
		goto failed;
	if (!gst_video_info_set_format(&animation->info, GST_VIDEO_FORMAT_RGBA,
	                               animation->metadata.width,
	                               animation->metadata.height)) {
		webp_error(error, "Could not describe WebP pixels");
		goto failed;
	}
	GST_VIDEO_INFO_FPS_N(&animation->info) = 0;
	GST_VIDEO_INFO_FPS_D(&animation->info) = 1;
	animation->caps = gst_video_info_to_caps(&animation->info);
	if (!animation->caps) {
		webp_error(error, "Could not create WebP video caps");
		goto failed;
	}
	webp->pool = gst_buffer_pool_new();
	GstStructure *config = gst_buffer_pool_get_config(webp->pool);
	gst_buffer_pool_config_set_params(config, animation->caps,
	                                  animation->info.size, 0,
	                                  WEBP_POOL_BUFFERS);
	if (!gst_buffer_pool_set_config(webp->pool, config) ||
	    !gst_buffer_pool_set_active(webp->pool, TRUE)) {
		webp_error(error, "Could not prepare the WebP frame pool");
		goto failed;
	}
	return animation;
failed:
	video_animation_unref(animation);
	return NULL;
}
