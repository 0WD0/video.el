/* video-animation.c --- Shared native animation ingestion for GStreamer
 *
 * Copyright (C) 2026 0WD0
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <gst/app/gstappsrc.h>

#include "video-animation.h"
#include "video-apng.h"
#include "video-lottie.h"

void video_animation_init(VideoAnimation *animation,
                          const VideoAnimationOps *ops)
{
	g_atomic_ref_count_init(&animation->refs);
	g_mutex_init(&animation->lock);
	animation->ops = ops;
}

VideoAnimation *video_animation_new(VideoSourceFormat format,
                                    const gchar *uri, GError **error)
{
	switch (format) {
	case VIDEO_SOURCE_LOTTIE:
		return video_lottie_new(uri, error);
	case VIDEO_SOURCE_APNG:
		return video_apng_new(uri, error);
	default:
		g_set_error_literal(error, GST_STREAM_ERROR, GST_STREAM_ERROR_DECODE,
		                    "Source is not a native animation");
		return NULL;
	}
}

VideoAnimation *video_animation_ref(VideoAnimation *animation)
{
	g_atomic_ref_count_inc(&animation->refs);
	return animation;
}

void video_animation_unref(VideoAnimation *animation)
{
	if (!animation || !g_atomic_ref_count_dec(&animation->refs))
		return;
	animation->ops->destroy(animation);
	gst_clear_caps(&animation->caps);
	g_mutex_clear(&animation->lock);
	g_free(animation);
}

static void source_need_data(GstAppSrc *source, guint length, gpointer data)
{
	VideoAnimation *animation = data;
	(void)length;
	GError *error = NULL;
	GstBuffer *buffer = NULL;
	gboolean eos = FALSE;
	g_mutex_lock(&animation->lock);
	if (!g_atomic_int_get(&animation->flushing) && !animation->failed) {
		buffer = animation->ops->next_frame(animation, &error);
		if (error)
			animation->failed = TRUE;
		else if (!buffer)
			eos = TRUE;
	}
	g_mutex_unlock(&animation->lock);
	if (g_atomic_int_get(&animation->flushing)) {
		gst_clear_buffer(&buffer);
		g_clear_error(&error);
		return;
	}
	if (error) {
		GST_ELEMENT_ERROR(source, STREAM, DECODE,
		                  ("%s", error->message), (NULL));
		g_error_free(error);
	} else if (buffer) {
		/* Push outside the decoder lock; appsrc consumes our reference even
		 * when shutting down.  Cancellation must never wait for this push. */
		GstFlowReturn flow = gst_app_src_push_buffer(source, buffer);
		if (flow != GST_FLOW_OK && flow != GST_FLOW_FLUSHING &&
		    flow != GST_FLOW_EOS &&
		    !g_atomic_int_get(&animation->flushing))
			GST_ELEMENT_ERROR(source, STREAM, FAILED,
			                  ("Could not publish a %s frame",
			                   animation->ops->name),
			                  ("%s", gst_flow_get_name(flow)));
	} else if (eos) {
		gst_app_src_end_of_stream(source);
	}
}

static gboolean source_seek_data(GstAppSrc *source, guint64 offset,
                                  gpointer data)
{
	VideoAnimation *animation = data;
	if (offset > animation->metadata.duration ||
	    g_atomic_int_get(&animation->flushing))
		return FALSE;
	GError *error = NULL;
	g_mutex_lock(&animation->lock);
	gboolean ready = !g_atomic_int_get(&animation->flushing) &&
	                 !animation->failed &&
	                 animation->ops->seek(animation, offset, &error);
	if (error)
		animation->failed = TRUE;
	g_mutex_unlock(&animation->lock);
	if (error) {
		if (!g_atomic_int_get(&animation->flushing))
			GST_ELEMENT_ERROR(source, STREAM, DECODE,
			                  ("%s", error->message), (NULL));
		g_error_free(error);
	}
	return ready;
}

static void source_release(gpointer data)
{
	video_animation_unref(data);
}

gboolean video_animation_configure_source(VideoAnimation *animation,
                                           GstElement *source, GError **error)
{
	if (!GST_IS_APP_SRC(source)) {
		g_set_error(error, GST_STREAM_ERROR, GST_STREAM_ERROR_DECODE,
		            "%s playback source is not appsrc", animation->ops->name);
		return FALSE;
	}
	GError *failure = NULL;
	g_mutex_lock(&animation->lock);
	gboolean ready = !g_atomic_int_get(&animation->flushing) &&
	                 !animation->failed &&
	                 animation->ops->seek(animation, 0, &failure);
	if (failure)
		animation->failed = TRUE;
	g_mutex_unlock(&animation->lock);
	if (!ready) {
		if (failure)
			g_propagate_error(error, failure);
		else
			g_set_error(error, GST_STREAM_ERROR, GST_STREAM_ERROR_DECODE,
			            "%s playback source is closed", animation->ops->name);
		return FALSE;
	}
	gst_app_src_set_caps(GST_APP_SRC(source), animation->caps);
	gst_app_src_set_duration(GST_APP_SRC(source), animation->metadata.duration);
	/* TIME-addressed raw frames have no useful byte-addressed file size. */
	g_object_set(source, "format", GST_FORMAT_TIME,
	             "stream-type", GST_APP_STREAM_TYPE_SEEKABLE,
	             "is-live", FALSE, "block", animation->ops->block,
	             "max-bytes", (guint64)0, "max-buffers", (guint64)2,
	             "emit-signals", FALSE, NULL);
	GstAppSrcCallbacks callbacks = {
	        .need_data = source_need_data,
	        .seek_data = source_seek_data,
	};
	gst_app_src_set_callbacks(GST_APP_SRC(source), &callbacks,
	                           video_animation_ref(animation), source_release);
	return TRUE;
}

void video_animation_flush(VideoAnimation *animation)
{
	g_atomic_int_set(&animation->flushing, TRUE);
	if (animation->ops->flush)
		animation->ops->flush(animation);
}

GstSample *video_animation_first_frame(VideoSourceFormat format,
                                       const gchar *uri, GError **error)
{
	VideoAnimation *animation = video_animation_new(format, uri, error);
	if (!animation)
		return NULL;
	GstSample *sample = NULL;
	g_mutex_lock(&animation->lock);
	if (animation->ops->seek(animation, 0, error)) {
		GstBuffer *buffer = animation->ops->next_frame(animation, error);
		if (buffer) {
			sample = gst_sample_new(buffer, animation->caps, NULL, NULL);
			gst_buffer_unref(buffer);
		}
	}
	g_mutex_unlock(&animation->lock);
	video_animation_unref(animation);
	return sample;
}
