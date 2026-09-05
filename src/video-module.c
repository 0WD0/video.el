/* video-module.c --- GStreamer bridge for video.el  -*- c-file-style: "linux" -*-
 *
 * Copyright (C) 2026 0WD0
 *
 * This file is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version.
 */

#include <emacs-module.h>
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/play/play.h>
#include <gst/video/video-converter.h>
#include <gst/video/video.h>
#include <glib/gstdio.h>

#include "video-canvas.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

int plugin_is_GPL_compatible;

typedef enum {
	VIDEO_FIT_CONTAIN,
	VIDEO_FIT_COVER,
	VIDEO_FIT_WIDTH,
	VIDEO_FIT_HEIGHT,
	VIDEO_FIT_ACTUAL
} VideoFit;

enum { VIDEO_PLAY_FLAG_DOWNLOAD = (1 << 7) };

typedef struct VideoSession VideoSession;
typedef struct VideoTarget VideoTarget;

typedef struct {
	GObject parent;
	VideoSession *session;
	GstElement *sink;
} VideoRenderer;

typedef struct {
	GObjectClass parent_class;
} VideoRendererClass;

struct VideoTarget {
	gatomicrefcount refs;
	GMutex lock;
	VideoSession *session;
	gboolean closed;
	gint width;
	gint height;
	VideoFit fit;
	gdouble scale;
	gdouble viewport_x;
	gdouble viewport_y;
	guint64 generation;
	GstBuffer *front;
	GstBuffer *back;
	gint front_width;
	gint front_height;
	guint64 sequence;
	GstVideoConverter *converter;
	GstVideoInfo converter_input;
	GstVideoInfo converter_output;
	guint64 converter_generation;
	gboolean converter_valid;
};

struct VideoSession {
	gatomicrefcount refs;
	GMutex lock;
	GCond render_cond;
	gboolean closing;
	gboolean closed;
	gboolean render_pending;
	GThread *render_thread;
	GstSample *latest_sample;
	GPtrArray *targets;
	GstPlay *play;
	GstElement *pipeline;
	GstElement *download_buffer;
	GstBus *bus;
	GstBus *pipeline_bus;
	gulong element_setup_handler;
	gulong pipeline_message_handler;
	int notify_fd;
	GstPlayState state;
	GstClockTime position;
	GstClockTime duration;
	gboolean seeking;
	guint buffering;
	guint video_width;
	guint video_height;
	gboolean eos;
	gchar *cache_template;
	gchar *cache_location;
	gchar *error;
	GstStructure *request_headers;
};

typedef struct {
	gdouble start;
	gdouble end;
} VideoBufferedRange;

typedef enum { REAP_SESSION, REAP_TARGET } ReapKind;

typedef struct {
	ReapKind kind;
	gpointer pointer;
} ReapItem;

static GAsyncQueue *reaper_queue;
static GThread *reaper_thread;

static void video_renderer_interface_init(GstPlayVideoRendererInterface *iface);

#define VIDEO_TYPE_RENDERER (video_renderer_get_type())
G_DEFINE_TYPE_WITH_CODE(VideoRenderer, video_renderer, G_TYPE_OBJECT,
			G_IMPLEMENT_INTERFACE(GST_TYPE_PLAY_VIDEO_RENDERER,
					      video_renderer_interface_init))

static void session_ref(VideoSession *session)
{
	g_atomic_ref_count_inc(&session->refs);
}

static void target_ref(VideoTarget *target)
{
	g_atomic_ref_count_inc(&target->refs);
}

static void session_notify(VideoSession *session, char kind)
{
	if (session->notify_fd < 0)
		return;

	ssize_t result;
	do {
		result = write(session->notify_fd, &kind, 1);
	} while (result < 0 && errno == EINTR);

	if (result < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
		return;
}

static void target_destroy(VideoTarget *target);
static void session_destroy(VideoSession *session);
static void target_close(VideoTarget *target);
static void session_close(VideoSession *session);

static void session_unref(VideoSession *session)
{
	if (g_atomic_ref_count_dec(&session->refs))
		session_destroy(session);
}

static void target_unref(VideoTarget *target)
{
	if (g_atomic_ref_count_dec(&target->refs))
		target_destroy(target);
}

static gpointer reaper_main(gpointer data)
{
	GAsyncQueue *queue = data;
	for (;;) {
		ReapItem *item = g_async_queue_pop(queue);
		if (item->kind == REAP_SESSION) {
			VideoSession *session = item->pointer;
			session_close(session);
			session_unref(session);
		} else {
			VideoTarget *target = item->pointer;
			target_close(target);
			target_unref(target);
		}
		g_free(item);
	}
	return NULL;
}

static void queue_reap(ReapKind kind, gpointer pointer)
{
	ReapItem *item = g_new(ReapItem, 1);
	item->kind = kind;
	item->pointer = pointer;
	g_async_queue_push(reaper_queue, item);
}

static void session_finalizer(void *pointer)
{
	if (pointer)
		queue_reap(REAP_SESSION, pointer);
}

static void target_finalizer(void *pointer)
{
	if (pointer)
		queue_reap(REAP_TARGET, pointer);
}

static void video_renderer_finalize(GObject *object)
{
	VideoRenderer *renderer = (VideoRenderer *)object;
	gst_clear_object(&renderer->sink);
	G_OBJECT_CLASS(video_renderer_parent_class)->finalize(object);
}

static void video_renderer_class_init(VideoRendererClass *klass)
{
	GObjectClass *object_class = G_OBJECT_CLASS(klass);
	object_class->finalize = video_renderer_finalize;
}

static void video_renderer_init(VideoRenderer *renderer)
{
	renderer->session = NULL;
	renderer->sink = NULL;
}

static GstElement *video_renderer_create_sink(GstPlayVideoRenderer *iface,
					      GstPlay *play)
{
	VideoRenderer *renderer = (VideoRenderer *)iface;
	(void)play;
	return renderer->sink;
}

static void video_renderer_interface_init(GstPlayVideoRendererInterface *iface)
{
	iface->create_video_sink = video_renderer_create_sink;
}

static void session_request_render(VideoSession *session)
{
	g_mutex_lock(&session->lock);
	if (!session->closing) {
		session->render_pending = TRUE;
		g_cond_signal(&session->render_cond);
	}
	g_mutex_unlock(&session->lock);
}

static void session_store_sample(VideoSession *session, GstSample *sample)
{
	g_mutex_lock(&session->lock);
	if (!session->closing) {
		gst_clear_sample(&session->latest_sample);
		session->latest_sample = sample;
		sample = NULL;
		session->render_pending = TRUE;
		g_cond_signal(&session->render_cond);
	}
	g_mutex_unlock(&session->lock);
	if (sample)
		gst_sample_unref(sample);
}

static GstFlowReturn appsink_new_sample(GstAppSink *sink, gpointer data)
{
	VideoSession *session = data;
	GstSample *sample = gst_app_sink_pull_sample(sink);
	if (sample)
		session_store_sample(session, sample);
	return GST_FLOW_OK;
}

static GstFlowReturn appsink_new_preroll(GstAppSink *sink, gpointer data)
{
	VideoSession *session = data;
	GstSample *sample = gst_app_sink_pull_preroll(sink);
	if (sample)
		session_store_sample(session, sample);
	return GST_FLOW_OK;
}

static void appsink_eos(GstAppSink *sink, gpointer data)
{
	VideoSession *session = data;
	(void)sink;
	session_notify(session, 'e');
}

static GstBusSyncReply session_bus_sync(GstBus *bus, GstMessage *message,
					gpointer data)
{
	VideoSession *session = data;
	GstPlayMessage type;
	(void)bus;

	gst_play_message_parse_type(message, &type);
	session_notify(
		session,
		type == GST_PLAY_MESSAGE_POSITION_UPDATED ? 'p' : 'e');
	return GST_BUS_PASS;
}

static void session_element_setup(GstElement *pipeline, GstElement *element,
				  gpointer data)
{
	VideoSession *session = data;
	GstElementFactory *factory = gst_element_get_factory(element);
	const gchar *factory_name = factory
		? gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(factory))
		: NULL;
	gchar *cache_template = NULL;
	GstElement *old_download_buffer = NULL;
	(void)pipeline;

	if (session->request_headers &&
	    g_object_class_find_property(G_OBJECT_GET_CLASS(element),
					 "extra-headers"))
		g_object_set(element, "extra-headers", session->request_headers, NULL);
	if (session->request_headers &&
	    g_object_class_find_property(G_OBJECT_GET_CLASS(element),
					 "user-agent")) {
		const gchar *user_agent = gst_structure_get_string(
			session->request_headers, "User-Agent");
		if (user_agent)
			g_object_set(element, "user-agent", user_agent, NULL);
	}

	if (g_strcmp0(factory_name, "downloadbuffer") != 0)
		return;
	g_mutex_lock(&session->lock);
	if (!session->closing && session->cache_template) {
		cache_template = g_strdup(session->cache_template);
		old_download_buffer = session->download_buffer;
		session->download_buffer = gst_object_ref(element);
	}
	g_mutex_unlock(&session->lock);
	if (old_download_buffer)
		gst_object_unref(old_download_buffer);
	if (cache_template) {
		g_object_set(element, "temp-template", cache_template,
			     "temp-remove", TRUE, NULL);
		g_free(cache_template);
	}
}

static void session_pipeline_cache_message(GstBus *bus,
						 GstMessage *message,
						 gpointer data)
{
	VideoSession *session = data;
	const GstStructure *structure = gst_message_get_structure(message);
	const gchar *location;
	gboolean notify = FALSE;
	(void)bus;

	if (!structure ||
	    !gst_structure_has_name(structure, "GstCacheDownloadComplete"))
		return;
	location = gst_structure_get_string(structure, "location");
	if (!location)
		return;

	g_mutex_lock(&session->lock);
	if (!session->closing && !session->cache_location) {
		session->cache_location = g_strdup(location);
		notify = TRUE;
	}
	g_mutex_unlock(&session->lock);
	if (notify)
		session_notify(session, 'e');
}

/*
 * Small responses can reach sink EOS before downloadbuffer learns the upstream
 * byte size, so GstCacheDownloadComplete is never posted.  Confirm a contiguous
 * zero-to-size byte range as the equivalent completion signal.  At clean
 * playback EOS, the temporary file size is a safe fallback when the upstream
 * duration remains unavailable: sparse holes still prevent contiguous
 * coverage from reaching that size.
 */
static void session_detect_completed_cache(VideoSession *session)
{
	GstElement *download_buffer = NULL;
	gchar *location = NULL;
	gboolean complete = FALSE;

	g_mutex_lock(&session->lock);
	if (!session->closing && !session->cache_location &&
	    session->download_buffer)
		download_buffer = gst_object_ref(session->download_buffer);
	g_mutex_unlock(&session->lock);
	if (!download_buffer)
		return;

	g_object_get(download_buffer, "temp-location", &location, NULL);
	if (location && g_file_test(location, G_FILE_TEST_IS_REGULAR)) {
		GstQuery *query = gst_query_new_buffering(GST_FORMAT_BYTES);
		gint64 covered = 0;

		if (gst_element_query(download_buffer, query)) {
			guint count = gst_query_get_n_buffering_ranges(query);
			for (guint index = 0; index < count; ++index) {
				gint64 start;
				gint64 end;
				if (!gst_query_parse_nth_buffering_range(
					    query, index, &start, &end) ||
				    start > covered)
					break;
				if (end > covered)
					covered = end;
			}
		}
		gst_query_unref(query);

		if (covered > 0) {
			gint64 total = -1;
			if (gst_element_query_duration(
				    download_buffer, GST_FORMAT_BYTES, &total) &&
			    total > 0) {
				complete = covered >= total;
			} else if (session->eos) {
				GStatBuf file_info;
				if (g_stat(location, &file_info) == 0 &&
				    file_info.st_size > 0)
					complete =
						covered >= (gint64)file_info.st_size;
			}
		}
	}
	if (complete) {
		g_mutex_lock(&session->lock);
		if (!session->closing && !session->cache_location)
			session->cache_location = g_strdup(location);
		g_mutex_unlock(&session->lock);
	}
	g_free(location);
	gst_object_unref(download_buffer);
}

static VideoFit parse_fit_name(const char *name)
{
	if (strcmp(name, "cover") == 0)
		return VIDEO_FIT_COVER;
	if (strcmp(name, "width") == 0)
		return VIDEO_FIT_WIDTH;
	if (strcmp(name, "height") == 0)
		return VIDEO_FIT_HEIGHT;
	if (strcmp(name, "actual") == 0)
		return VIDEO_FIT_ACTUAL;
	return VIDEO_FIT_CONTAIN;
}

static gboolean target_axis_rectangle(gint input_length, gint viewport_length,
				      gdouble scale, gdouble requested_origin,
				      gint *src_position, gint *src_length,
				      gint *dst_position, gint *dst_length)
{
	gdouble scaled_length = (gdouble)input_length * scale;
	gdouble visible_start = MAX(0.0, requested_origin);
	gdouble visible_end
		= MIN(scaled_length, requested_origin + viewport_length);

	*src_position = 0;
	*src_length = 0;
	*dst_position = 0;
	*dst_length = 0;
	if (!(visible_end > visible_start))
		return FALSE;

	gint source_start = CLAMP((gint)floor(visible_start / scale),
				  0, input_length - 1);
	gint source_end = CLAMP((gint)ceil(visible_end / scale),
				source_start + 1, input_length);
	gint destination_start
		= CLAMP((gint)floor(visible_start - requested_origin),
			0, viewport_length - 1);
	gint destination_end
		= CLAMP((gint)ceil(visible_end - requested_origin),
			destination_start + 1, viewport_length);

	*src_position = source_start;
	*src_length = source_end - source_start;
	*dst_position = destination_start;
	*dst_length = destination_end - destination_start;
	return TRUE;
}

static gboolean target_compute_rectangles(VideoTarget *target,
					   const GstVideoInfo *input,
					   gint *src_x, gint *src_y,
					   gint *src_width, gint *src_height,
					   gint *dst_x, gint *dst_y,
					   gint *dst_width, gint *dst_height)
{
	gint in_width = GST_VIDEO_INFO_WIDTH(input);
	gint in_height = GST_VIDEO_INFO_HEIGHT(input);
	gdouble scale_x = (gdouble)target->width / (gdouble)in_width;
	gdouble scale_y = (gdouble)target->height / (gdouble)in_height;
	gdouble base_scale;

	switch (target->fit) {
	case VIDEO_FIT_COVER:
		base_scale = MAX(scale_x, scale_y);
		break;
	case VIDEO_FIT_WIDTH:
		base_scale = scale_x;
		break;
	case VIDEO_FIT_HEIGHT:
		base_scale = scale_y;
		break;
	case VIDEO_FIT_ACTUAL:
		base_scale = 1.0;
		break;
	case VIDEO_FIT_CONTAIN:
	default:
		base_scale = MIN(scale_x, scale_y);
		break;
	}

	gboolean explicit_scale = isfinite(target->scale) && target->scale > 0.0;
	gdouble scale = CLAMP(explicit_scale ? target->scale : base_scale,
			      0.0001, 65536.0);
	gdouble scaled_width = in_width * scale;
	gdouble scaled_height = in_height * scale;
	gdouble viewport_x = explicit_scale
				     ? target->viewport_x
				     : (scaled_width - target->width) / 2.0;
	gdouble viewport_y = explicit_scale
				     ? target->viewport_y
				     : (scaled_height - target->height) / 2.0;
	gboolean visible_x
		= target_axis_rectangle(in_width, target->width, scale, viewport_x,
					src_x, src_width, dst_x, dst_width);
	gboolean visible_y
		= target_axis_rectangle(in_height, target->height, scale, viewport_y,
					src_y, src_height, dst_y, dst_height);
	return visible_x && visible_y;
}

static gboolean target_prepare_converter(VideoTarget *target,
					 const GstVideoInfo *input,
					 guint64 generation,
					 gboolean *has_content)
{
	GstVideoInfo output;
#if G_BYTE_ORDER == G_LITTLE_ENDIAN
	GstVideoFormat format = GST_VIDEO_FORMAT_BGRA;
#else
	GstVideoFormat format = GST_VIDEO_FORMAT_ARGB;
#endif
	gst_video_info_set_format(&output, format, target->width, target->height);
	GST_VIDEO_INFO_FPS_N(&output) = GST_VIDEO_INFO_FPS_N(input);
	GST_VIDEO_INFO_FPS_D(&output) = GST_VIDEO_INFO_FPS_D(input);
	GST_VIDEO_INFO_PAR_N(&output) = 1;
	GST_VIDEO_INFO_PAR_D(&output) = 1;

	gint src_x, src_y, src_width, src_height;
	gint dst_x, dst_y, dst_width, dst_height;
	*has_content = target_compute_rectangles(
		target, input, &src_x, &src_y, &src_width, &src_height,
		&dst_x, &dst_y, &dst_width, &dst_height);

	if (target->converter_valid &&
	    target->converter_generation == generation &&
	    gst_video_info_is_equal(&target->converter_input, input) &&
	    gst_video_info_is_equal(&target->converter_output, &output) &&
	    ((*has_content && target->converter) ||
	     (!*has_content && !target->converter))) {
		if (!target->back)
			target->back
			    = gst_buffer_new_allocate(NULL, output.size, NULL);
		return target->back != NULL;
	}

	if (target->converter) {
		gst_video_converter_free(target->converter);
		target->converter = NULL;
	}
	gst_clear_buffer(&target->back);
	target->back = gst_buffer_new_allocate(NULL, output.size, NULL);
	if (!target->back)
		return FALSE;

	if (*has_content) {
		GstStructure *config = gst_structure_new(
			"video-converter-config",
			GST_VIDEO_CONVERTER_OPT_SRC_X, G_TYPE_INT, src_x,
			GST_VIDEO_CONVERTER_OPT_SRC_Y, G_TYPE_INT, src_y,
			GST_VIDEO_CONVERTER_OPT_SRC_WIDTH, G_TYPE_INT, src_width,
			GST_VIDEO_CONVERTER_OPT_SRC_HEIGHT, G_TYPE_INT, src_height,
			GST_VIDEO_CONVERTER_OPT_DEST_X, G_TYPE_INT, dst_x,
			GST_VIDEO_CONVERTER_OPT_DEST_Y, G_TYPE_INT, dst_y,
			GST_VIDEO_CONVERTER_OPT_DEST_WIDTH, G_TYPE_INT, dst_width,
			GST_VIDEO_CONVERTER_OPT_DEST_HEIGHT, G_TYPE_INT, dst_height,
			GST_VIDEO_CONVERTER_OPT_FILL_BORDER, G_TYPE_BOOLEAN, TRUE,
			NULL);

		target->converter
			= gst_video_converter_new(input, &output, config);
		if (!target->converter) {
			gst_clear_buffer(&target->back);
			return FALSE;
		}
	}

	target->converter_input = *input;
	target->converter_output = output;
	target->converter_generation = generation;
	target->converter_valid = TRUE;
	return TRUE;
}

static void target_clear_output(GstVideoFrame *frame, gint width, gint height)
{
	guint8 *base = GST_VIDEO_FRAME_PLANE_DATA(frame, 0);
	gint stride = GST_VIDEO_FRAME_PLANE_STRIDE(frame, 0);

	for (gint y = 0; y < height; ++y) {
		guint8 *row = base + (gsize)y * stride;
		memset(row, 0, (gsize)stride);
		for (gint x = 0; x < width; ++x) {
#if G_BYTE_ORDER == G_LITTLE_ENDIAN
			row[(gsize)x * 4 + 3] = 0xff;
#else
			row[(gsize)x * 4] = 0xff;
#endif
		}
	}
}

static void target_render(VideoTarget *target, GstSample *sample)
{
	GstCaps *caps = gst_sample_get_caps(sample);
	GstBuffer *input_buffer = gst_sample_get_buffer(sample);
	GstVideoInfo input_info;
	GstVideoFrame input_frame;
	GstVideoFrame output_frame;
	GstVideoConverter *converter;
	GstBuffer *back;
	GstVideoInfo output_info;
	gint output_height;
	guint64 generation;
	gboolean has_content;

	if (!caps || !input_buffer || !gst_video_info_from_caps(&input_info, caps))
		return;

	g_mutex_lock(&target->lock);
	if (target->closed || target->width <= 0 || target->height <= 0) {
		g_mutex_unlock(&target->lock);
		return;
	}
	generation = target->generation;
	if (!target_prepare_converter(target, &input_info, generation,
				      &has_content)) {
		g_mutex_unlock(&target->lock);
		return;
	}
	converter = target->converter;
	back = target->back;
	output_info = target->converter_output;
	output_height = target->height;
	g_mutex_unlock(&target->lock);

	if (has_content &&
	    !gst_video_frame_map(&input_frame, &input_info, input_buffer,
				 GST_MAP_READ))
		return;
	if (!gst_video_frame_map(&output_frame, &output_info,
				 back, GST_MAP_WRITE)) {
		if (has_content)
			gst_video_frame_unmap(&input_frame);
		return;
	}

	target_clear_output(&output_frame,
			    GST_VIDEO_INFO_WIDTH(&output_info), output_height);
	if (has_content)
		gst_video_converter_frame(converter, &input_frame, &output_frame);
	gst_video_frame_unmap(&output_frame);
	if (has_content)
		gst_video_frame_unmap(&input_frame);

	g_mutex_lock(&target->lock);
	if (!target->closed && target->generation == generation) {
		GstBuffer *old_front = target->front;
		target->front = back;
		target->back = old_front;
		target->front_width = GST_VIDEO_INFO_WIDTH(&output_info);
		target->front_height = GST_VIDEO_INFO_HEIGHT(&output_info);
		target->sequence++;
	} else {
		target->converter_valid = FALSE;
	}
	g_mutex_unlock(&target->lock);
}

static gpointer session_render_main(gpointer data)
{
	VideoSession *session = data;
	for (;;) {
		GstSample *sample = NULL;
		GPtrArray *targets = NULL;

		g_mutex_lock(&session->lock);
		while (!session->closing && !session->render_pending)
			g_cond_wait(&session->render_cond, &session->lock);
		if (session->closing) {
			g_mutex_unlock(&session->lock);
			break;
		}
		session->render_pending = FALSE;
		if (session->latest_sample)
			sample = gst_sample_ref(session->latest_sample);
		targets = g_ptr_array_new_with_free_func((GDestroyNotify)target_unref);
		for (guint i = 0; i < session->targets->len; ++i) {
			VideoTarget *target = g_ptr_array_index(session->targets, i);
			target_ref(target);
			g_ptr_array_add(targets, target);
		}
		g_mutex_unlock(&session->lock);

		if (sample) {
			for (guint i = 0; i < targets->len; ++i)
				target_render(g_ptr_array_index(targets, i), sample);
			gst_sample_unref(sample);
			session_notify(session, 'f');
		}
		g_ptr_array_unref(targets);
	}
	return NULL;
}

static VideoSession *session_new(const gchar *uri, int notify_fd,
				 guint64 network_cache_size,
				 const gchar *cache_template,
				 GstStructure *request_headers, GError **error)
{
	VideoSession *session = g_new0(VideoSession, 1);
	session->request_headers = request_headers;
	g_atomic_ref_count_init(&session->refs);
	g_mutex_init(&session->lock);
	g_cond_init(&session->render_cond);
	session->notify_fd = notify_fd;
	session->state = GST_PLAY_STATE_STOPPED;
	session->position = GST_CLOCK_TIME_NONE;
	session->duration = GST_CLOCK_TIME_NONE;
	session->buffering = 100;
	session->targets = g_ptr_array_new_with_free_func((GDestroyNotify)target_unref);
	session->cache_template = g_strdup(cache_template);

	GstElement *sink = gst_element_factory_make("appsink", NULL);
	if (!sink) {
		g_set_error_literal(error, GST_CORE_ERROR, GST_CORE_ERROR_MISSING_PLUGIN,
				    "GStreamer appsink is unavailable");
		session_unref(session);
		return NULL;
	}

	GstCaps *caps = gst_caps_new_empty_simple("video/x-raw");
	gst_app_sink_set_caps(GST_APP_SINK(sink), caps);
	gst_caps_unref(caps);
	g_object_set(sink, "sync", TRUE, "max-buffers", 1u,
		     "drop", TRUE, "enable-last-sample", FALSE, NULL);
	GstAppSinkCallbacks callbacks = {
		.eos = appsink_eos,
		.new_preroll = appsink_new_preroll,
		.new_sample = appsink_new_sample,
	};
	gst_app_sink_set_callbacks(GST_APP_SINK(sink), &callbacks, session, NULL);

	VideoRenderer *renderer = g_object_new(VIDEO_TYPE_RENDERER, NULL);
	renderer->session = session;
	renderer->sink = gst_object_ref_sink(sink);
	session->play = gst_play_new(GST_PLAY_VIDEO_RENDERER(renderer));
	if (!session->play) {
		g_set_error_literal(error, GST_CORE_ERROR, GST_CORE_ERROR_FAILED,
				    "Could not create GstPlay");
		session_unref(session);
		return NULL;
	}

	session->pipeline = gst_play_get_pipeline(session->play);
	if (session->pipeline && (cache_template || request_headers) &&
	    g_signal_lookup("element-setup",
			    G_OBJECT_TYPE(session->pipeline)) != 0)
		session->element_setup_handler =
			g_signal_connect(session->pipeline, "element-setup",
					 G_CALLBACK(session_element_setup),
					 session);
	if (session->pipeline && cache_template) {
		session->pipeline_bus = gst_element_get_bus(session->pipeline);
		if (session->pipeline_bus) {
			gst_bus_enable_sync_message_emission(session->pipeline_bus);
			session->pipeline_message_handler =
				g_signal_connect(
					session->pipeline_bus,
					"sync-message::element",
					G_CALLBACK(
						session_pipeline_cache_message),
					session);
		}
	}

	if (network_cache_size > 0 && session->pipeline) {
		guint flags = 0;
		g_object_get(session->pipeline, "flags", &flags, NULL);
		flags |= VIDEO_PLAY_FLAG_DOWNLOAD;
		g_object_set(session->pipeline, "flags", flags,
			     "ring-buffer-max-size", network_cache_size, NULL);
	}

	session->bus = gst_play_get_message_bus(session->play);
	gst_bus_set_sync_handler(session->bus, session_bus_sync, session, NULL);
	gst_play_set_uri(session->play, uri);
	session->render_thread = g_thread_new("video-render", session_render_main,
					      session);
	return session;
}

static void target_mark_closed(VideoTarget *target)
{
	g_mutex_lock(&target->lock);
	target->closed = TRUE;
	g_mutex_unlock(&target->lock);
}

static void session_close(VideoSession *session)
{
	g_mutex_lock(&session->lock);
	if (session->closed || session->closing) {
		g_mutex_unlock(&session->lock);
		return;
	}
	session->closing = TRUE;
	g_cond_signal(&session->render_cond);
	g_mutex_unlock(&session->lock);
	if (session->element_setup_handler && session->pipeline) {
		g_signal_handler_disconnect(session->pipeline,
					    session->element_setup_handler);
		session->element_setup_handler = 0;
	}
	if (session->pipeline_message_handler && session->pipeline_bus) {
		g_signal_handler_disconnect(session->pipeline_bus,
					    session->pipeline_message_handler);
		session->pipeline_message_handler = 0;
	}
	if (session->pipeline_bus)
		gst_bus_disable_sync_message_emission(session->pipeline_bus);


	if (session->play)
		gst_play_stop(session->play);
	if (session->render_thread) {
		g_thread_join(session->render_thread);
		session->render_thread = NULL;
	}

	g_mutex_lock(&session->lock);
	for (guint i = 0; i < session->targets->len; ++i)
		target_mark_closed(g_ptr_array_index(session->targets, i));
	g_ptr_array_set_size(session->targets, 0);
	gst_clear_sample(&session->latest_sample);
	session->closed = TRUE;
	g_mutex_unlock(&session->lock);

	if (session->bus) {
		gst_bus_set_sync_handler(session->bus, NULL, NULL, NULL);
		gst_bus_set_flushing(session->bus, TRUE);
		gst_clear_object(&session->bus);
	}
	gst_clear_object(&session->pipeline_bus);
	gst_clear_object(&session->download_buffer);
	gst_clear_object(&session->pipeline);
	g_clear_object(&session->play);
	if (session->notify_fd >= 0) {
		close(session->notify_fd);
		session->notify_fd = -1;
	}
}

static void session_destroy(VideoSession *session)
{
	session_close(session);
	g_clear_pointer(&session->targets, g_ptr_array_unref);
	g_clear_pointer(&session->cache_template, g_free);
	g_clear_pointer(&session->cache_location, g_free);
	g_clear_pointer(&session->error, g_free);
	g_clear_pointer(&session->request_headers, gst_structure_free);
	g_cond_clear(&session->render_cond);
	g_mutex_clear(&session->lock);
	g_free(session);
}

static void target_close(VideoTarget *target)
{
	VideoSession *session = target->session;
	target_mark_closed(target);

	g_mutex_lock(&session->lock);
	for (guint i = 0; i < session->targets->len; ++i) {
		if (g_ptr_array_index(session->targets, i) == target) {
			g_ptr_array_remove_index(session->targets, i);
			break;
		}
	}
	g_mutex_unlock(&session->lock);
}

static void target_destroy(VideoTarget *target)
{
	target_mark_closed(target);
	if (target->converter)
		gst_video_converter_free(target->converter);
	gst_clear_buffer(&target->front);
	gst_clear_buffer(&target->back);
	g_mutex_clear(&target->lock);
	session_unref(target->session);
	g_free(target);
}

static VideoTarget *target_new(VideoSession *session, gint width, gint height,
			       VideoFit fit, gdouble scale,
			       gdouble viewport_x, gdouble viewport_y)
{
	VideoTarget *target = g_new0(VideoTarget, 1);
	g_atomic_ref_count_init(&target->refs);
	g_mutex_init(&target->lock);
	target->session = session;
	session_ref(session);
	target->width = width;
	target->height = height;
	target->fit = fit;
	target->scale = isfinite(scale) && scale > 0.0
				? CLAMP(scale, 0.0001, 65536.0)
				: 0.0;
	target->viewport_x = isfinite(viewport_x) ? viewport_x : 0.0;
	target->viewport_y = isfinite(viewport_y) ? viewport_y : 0.0;
	target->generation = 1;

	g_mutex_lock(&session->lock);
	target_ref(target);
	g_ptr_array_add(session->targets, target);
	session->render_pending = TRUE;
	g_cond_signal(&session->render_cond);
	g_mutex_unlock(&session->lock);
	return target;
}

static void signal_error(emacs_env *env, const char *message)
{
	emacs_value text = env->make_string(env, message, (ptrdiff_t)strlen(message));
	emacs_value data = env->funcall(env, env->intern(env, "list"), 1, &text);
	env->non_local_exit_signal(env, env->intern(env, "error"), data);
}

static char *copy_string(emacs_env *env, emacs_value value)
{
	ptrdiff_t size = 0;
	env->copy_string_contents(env, value, NULL, &size);
	if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
		return NULL;
	char *text = g_malloc((gsize)size);
	env->copy_string_contents(env, value, text, &size);
	if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
		g_free(text);
		return NULL;
	}
	return text;
}

static GstStructure *copy_request_headers(emacs_env *env, emacs_value value)
{
	ptrdiff_t size = env->vec_size(env, value);
	if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
		return NULL;
	if (size == 0)
		return NULL;
	if (size % 2 != 0) {
		signal_error(env, "Video request header vector has odd length");
		return NULL;
	}

	GstStructure *headers = gst_structure_new_empty("request-headers");
	for (ptrdiff_t index = 0; index < size; index += 2) {
		char *name = copy_string(env, env->vec_get(env, value, index));
		char *header_value =
			copy_string(env, env->vec_get(env, value, index + 1));
		if (!name || !header_value ||
		    env->non_local_exit_check(env) != emacs_funcall_exit_return) {
			g_free(name);
			g_free(header_value);
			gst_structure_free(headers);
			return NULL;
		}
		gst_structure_set(headers, name, G_TYPE_STRING, header_value, NULL);
		g_free(name);
		g_free(header_value);
	}
	return headers;
}

static VideoSession *get_session(emacs_env *env, emacs_value value)
{
	VideoSession *session = env->get_user_ptr(env, value);
	if (!session && env->non_local_exit_check(env) == emacs_funcall_exit_return)
		signal_error(env, "Closed video player");
	return session;
}

static VideoTarget *get_target(emacs_env *env, emacs_value value)
{
	VideoTarget *target = env->get_user_ptr(env, value);
	if (!target && env->non_local_exit_check(env) == emacs_funcall_exit_return)
		signal_error(env, "Closed video target");
	return target;
}

static emacs_value native_create(emacs_env *env, ptrdiff_t nargs,
				 emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	char *uri = copy_string(env, args[0]);
	char *cache_template = NULL;
	GstStructure *request_headers = NULL;
	if (!uri)
		return env->intern(env, "nil");
	if (!gst_uri_is_valid(uri)) {
		g_free(uri);
		signal_error(env, "Video source must be an absolute URI");
		return env->intern(env, "nil");
	}
	if (env->is_not_nil(env, args[3])) {
		cache_template = copy_string(env, args[3]);
		if (!cache_template) {
			g_free(uri);
			return env->intern(env, "nil");
		}
	}
	if (env->is_not_nil(env, args[4])) {
		request_headers = copy_request_headers(env, args[4]);
		if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
			g_free(cache_template);
			g_free(uri);
			return env->intern(env, "nil");
		}
	}
	int fd = env->open_channel(env, args[1]);
	if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
		g_clear_pointer(&request_headers, gst_structure_free);
		g_free(cache_template);
		g_free(uri);
		return env->intern(env, "nil");
	}
	intmax_t cache_size = env->extract_integer(env, args[2]);
	if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
		g_clear_pointer(&request_headers, gst_structure_free);
		g_free(cache_template);
		g_free(uri);
		close(fd);
		return env->intern(env, "nil");
	}
	if (cache_size < 0) {
		g_clear_pointer(&request_headers, gst_structure_free);
		g_free(cache_template);
		g_free(uri);
		close(fd);
		signal_error(env, "Video network cache size must be non-negative");
		return env->intern(env, "nil");
	}
	int flags = fcntl(fd, F_GETFL, 0);
	if (flags >= 0)
		(void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);

	GError *error = NULL;
	VideoSession *session = session_new(uri, fd, (guint64)cache_size,
					    cache_template, request_headers,
					    &error);
	g_free(cache_template);
	g_free(uri);
	if (!session) {
		close(fd);
		signal_error(env, error ? error->message : "Could not create video player");
		g_clear_error(&error);
		return env->intern(env, "nil");
	}
	return env->make_user_ptr(env, session_finalizer, session);
}

static emacs_value native_close(emacs_env *env, ptrdiff_t nargs,
				emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	if (!session)
		return env->intern(env, "nil");
	env->set_user_ptr(env, args[0], NULL);
	env->set_user_finalizer(env, args[0], NULL);
	session_close(session);
	session_unref(session);
	return env->intern(env, "t");
}

static emacs_value native_play(emacs_env *env, ptrdiff_t nargs,
			       emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	if (session) {
		session->eos = FALSE;
		g_clear_pointer(&session->error, g_free);
		gst_play_play(session->play);
	}
	return env->intern(env, "nil");
}

static emacs_value native_pause(emacs_env *env, ptrdiff_t nargs,
				emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	if (session)
		gst_play_pause(session->play);
	return env->intern(env, "nil");
}

static emacs_value native_stop(emacs_env *env, ptrdiff_t nargs,
			       emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	if (session) {
		session->eos = FALSE;
		session->seeking = FALSE;
		gst_play_stop(session->play);
	}
	return env->intern(env, "nil");
}

static emacs_value native_seek(emacs_env *env, ptrdiff_t nargs,
			       emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	double seconds = env->extract_float(env, args[1]);
	if (session && seconds >= 0.0) {
		GstClockTime position = (GstClockTime)(seconds * GST_SECOND);
		session->eos = FALSE;
		session->seeking = TRUE;
		session->position = position;
		gst_play_seek(session->play, position);
	}
	return env->intern(env, "nil");
}

static void append_buffered_ranges(GstElement *pipeline, GstFormat format,
				   gdouble duration, GArray *ranges)
{
	GstQuery *query = gst_query_new_buffering(format);
	if (!gst_element_query(pipeline, query)) {
		gst_query_unref(query);
		return;
	}

	guint count = gst_query_get_n_buffering_ranges(query);
	for (guint index = 0; index < count; ++index) {
		gint64 start;
		gint64 end;
		if (!gst_query_parse_nth_buffering_range(query, index, &start, &end) ||
		    start < 0 || end <= start)
			continue;

		VideoBufferedRange range;
		if (format == GST_FORMAT_TIME) {
			range.start = (gdouble)start / GST_SECOND;
			range.end = (gdouble)end / GST_SECOND;
		} else if (format == GST_FORMAT_PERCENT && duration > 0.0) {
			range.start =
				duration * (gdouble)start / GST_FORMAT_PERCENT_MAX;
			range.end =
				duration * (gdouble)end / GST_FORMAT_PERCENT_MAX;
		} else {
			continue;
		}
		g_array_append_val(ranges, range);
	}
	gst_query_unref(query);
}

static emacs_value native_buffered_ranges(emacs_env *env, ptrdiff_t nargs,
					  emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	if (!session)
		return env->intern(env, "nil");

	GstElement *pipeline = gst_play_get_pipeline(session->play);
	if (!pipeline)
		return env->intern(env, "nil");

	GArray *ranges = g_array_new(FALSE, FALSE, sizeof(VideoBufferedRange));
	append_buffered_ranges(pipeline, GST_FORMAT_TIME, 0.0, ranges);
	if (ranges->len == 0) {
		gint64 duration = GST_CLOCK_TIME_NONE;
		if (gst_element_query_duration(pipeline, GST_FORMAT_TIME, &duration) &&
		    GST_CLOCK_TIME_IS_VALID(duration))
			append_buffered_ranges(pipeline, GST_FORMAT_PERCENT,
					       (gdouble)duration / GST_SECOND, ranges);
	}
	gst_object_unref(pipeline);

	emacs_value result = env->intern(env, "nil");
	emacs_value cons = env->intern(env, "cons");
	for (guint index = ranges->len; index > 0; --index) {
		VideoBufferedRange range =
			g_array_index(ranges, VideoBufferedRange, index - 1);
		emacs_value endpoints[] = {
			env->make_float(env, range.start),
			env->make_float(env, range.end),
		};
		emacs_value pair = env->funcall(env, cons, 2, endpoints);
		emacs_value cells[] = { pair, result };
		result = env->funcall(env, cons, 2, cells);
		if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
			break;
	}
	g_array_unref(ranges);
	return result;
}

static emacs_value native_set_volume(emacs_env *env, ptrdiff_t nargs,
				     emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	double volume = env->extract_float(env, args[1]);
	if (session)
		gst_play_set_volume(session->play, CLAMP(volume, 0.0, 1.0));
	return env->intern(env, "nil");
}

static emacs_value native_set_muted(emacs_env *env, ptrdiff_t nargs,
				    emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	if (session)
		gst_play_set_mute(session->play,
				  !env->eq(env, args[1], env->intern(env, "nil")));
	return env->intern(env, "nil");
}

static emacs_value native_set_rate(emacs_env *env, ptrdiff_t nargs,
				   emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	double rate = env->extract_float(env, args[1]);
	if (session && rate > 0.0)
		gst_play_set_rate(session->play, rate);
	return env->intern(env, "nil");
}

static emacs_value clock_value(emacs_env *env, GstClockTime value)
{
	if (!GST_CLOCK_TIME_IS_VALID(value))
		return env->intern(env, "nil");
	return env->make_float(env, (double)value / GST_SECOND);
}

static void session_poll_bus(VideoSession *session)
{
	GstMessage *message;
	while ((message = gst_bus_pop(session->bus))) {
		GstPlayMessage type;
		gst_play_message_parse_type(message, &type);
		switch (type) {
		case GST_PLAY_MESSAGE_POSITION_UPDATED: {
			GstClockTime position;
			gst_play_message_parse_position_updated(message, &position);
			if (!session->seeking)
				session->position = position;
			break;
		}
		case GST_PLAY_MESSAGE_SEEK_DONE:
			gst_play_message_parse_seek_done(message, &session->position);
			session->seeking = FALSE;
			break;
		case GST_PLAY_MESSAGE_DURATION_CHANGED:
			gst_play_message_parse_duration_changed(message, &session->duration);
			break;
		case GST_PLAY_MESSAGE_STATE_CHANGED:
			gst_play_message_parse_state_changed(message, &session->state);
			break;
		case GST_PLAY_MESSAGE_BUFFERING:
			gst_play_message_parse_buffering(message, &session->buffering);
			break;
		case GST_PLAY_MESSAGE_VIDEO_DIMENSIONS_CHANGED:
			gst_play_message_parse_video_dimensions_changed(
				message, &session->video_width, &session->video_height);
			break;
		case GST_PLAY_MESSAGE_END_OF_STREAM:
			session->eos = TRUE;
			break;
		case GST_PLAY_MESSAGE_ERROR: {
			GError *error = NULL;
			GstStructure *details = NULL;
			gst_play_message_parse_error(message, &error, &details);
			g_free(session->error);
			session->error = g_strdup(error ? error->message : "Playback failed");
			session->seeking = FALSE;
			g_clear_error(&error);
			if (details)
				gst_structure_free(details);
			break;
		}
		default:
			break;
		}
		gst_message_unref(message);
	}
}

static void session_query_capabilities(VideoSession *session,
				       gboolean *seekable, gboolean *live)
{
	*seekable = FALSE;
	*live = FALSE;
	if (!session->play)
		return;

	GstPlayMediaInfo *info = gst_play_get_media_info(session->play);
	if (!info)
		return;
	*seekable = gst_play_media_info_is_seekable(info);
	*live = gst_play_media_info_is_live(info);
	g_object_unref(info);
}

static emacs_value native_poll(emacs_env *env, ptrdiff_t nargs,
			       emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	if (!session)
		return env->intern(env, "nil");
	session_poll_bus(session);
	session_detect_completed_cache(session);

	gboolean seekable;
	gboolean live;
	session_query_capabilities(session, &seekable, &live);

	g_mutex_lock(&session->lock);
	gchar *cache_location = g_steal_pointer(&session->cache_location);
	g_mutex_unlock(&session->lock);
	const char *state_name = gst_play_state_get_name(session->state);
	emacs_value state_string = env->make_string(
		env, state_name, (ptrdiff_t)strlen(state_name));
	emacs_value state_symbol = env->intern(env, state_name);
	(void)state_string;
	emacs_value error = session->error
		? env->make_string(env, session->error,
				   (ptrdiff_t)strlen(session->error))
		: env->intern(env, "nil");
	emacs_value cache = cache_location
		? env->make_string(env, cache_location,
				   (ptrdiff_t)strlen(cache_location))
		: env->intern(env, "nil");
	emacs_value values[] = {
		env->intern(env, ":state"), state_symbol,
		env->intern(env, ":position"), clock_value(env, session->position),
		env->intern(env, ":duration"), clock_value(env, session->duration),
		env->intern(env, ":seekable"), seekable ? env->intern(env, "t") : env->intern(env, "nil"),
		env->intern(env, ":live"), live ? env->intern(env, "t") : env->intern(env, "nil"),
		env->intern(env, ":buffering"), env->make_integer(env, session->buffering),
		env->intern(env, ":width"), env->make_integer(env, session->video_width),
		env->intern(env, ":height"), env->make_integer(env, session->video_height),
		env->intern(env, ":eos"), session->eos ? env->intern(env, "t") : env->intern(env, "nil"),
		env->intern(env, ":cache-location"), cache,
		env->intern(env, ":error"), error,
	};
	emacs_value result = env->funcall(
		env, env->intern(env, "list"),
		(ptrdiff_t)G_N_ELEMENTS(values), values);
	g_free(cache_location);
	return result;
}

static emacs_value native_target_create(emacs_env *env, ptrdiff_t nargs,
					emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	gint width = (gint)env->extract_integer(env, args[1]);
	gint height = (gint)env->extract_integer(env, args[2]);
	char *fit_name = copy_string(env, args[3]);
	double scale = env->extract_float(env, args[4]);
	double viewport_x = env->extract_float(env, args[5]);
	double viewport_y = env->extract_float(env, args[6]);
	if (!session || !fit_name)
		return env->intern(env, "nil");
	if (width <= 0 || height <= 0 || (gint64)width * height > 33554432) {
		g_free(fit_name);
		signal_error(env, "Invalid video target dimensions");
		return env->intern(env, "nil");
	}
	VideoTarget *target = target_new(session, width, height,
					 parse_fit_name(fit_name), scale,
					 viewport_x, viewport_y);
	g_free(fit_name);
	return env->make_user_ptr(env, target_finalizer, target);
}

static emacs_value native_target_close(emacs_env *env, ptrdiff_t nargs,
				       emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoTarget *target = get_target(env, args[0]);
	if (!target)
		return env->intern(env, "nil");
	env->set_user_ptr(env, args[0], NULL);
	env->set_user_finalizer(env, args[0], NULL);
	target_close(target);
	target_unref(target);
	return env->intern(env, "t");
}

static emacs_value native_target_set_view(emacs_env *env, ptrdiff_t nargs,
					  emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoTarget *target = get_target(env, args[0]);
	gint width = (gint)env->extract_integer(env, args[1]);
	gint height = (gint)env->extract_integer(env, args[2]);
	char *fit_name = copy_string(env, args[3]);
	double scale = env->extract_float(env, args[4]);
	double viewport_x = env->extract_float(env, args[5]);
	double viewport_y = env->extract_float(env, args[6]);
	if (!target || !fit_name)
		return env->intern(env, "nil");
	if (width <= 0 || height <= 0 || (gint64)width * height > 33554432) {
		g_free(fit_name);
		signal_error(env, "Invalid video target dimensions");
		return env->intern(env, "nil");
	}
	g_mutex_lock(&target->lock);
	target->width = width;
	target->height = height;
	target->fit = parse_fit_name(fit_name);
	target->scale = isfinite(scale) && scale > 0.0
				? CLAMP(scale, 0.0001, 65536.0)
				: 0.0;
	target->viewport_x = isfinite(viewport_x) ? viewport_x : 0.0;
	target->viewport_y = isfinite(viewport_y) ? viewport_y : 0.0;
	target->generation++;
	target->converter_valid = FALSE;
	g_mutex_unlock(&target->lock);
	g_free(fit_name);
	session_request_render(target->session);
	return env->intern(env, "t");
}

static emacs_value rect_value(emacs_env *env, VideoCanvasRect rectangle)
{
	emacs_value coordinates[] = {
		env->make_integer(env, rectangle.x),
		env->make_integer(env, rectangle.y),
		env->make_integer(env, rectangle.width),
		env->make_integer(env, rectangle.height),
	};
	return env->funcall(env, env->intern(env, "vector"), 4, coordinates);
}

static emacs_value native_control_layout(emacs_env *env, ptrdiff_t nargs,
					 emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoCanvasRect target = {
		.x = (int)env->extract_integer(env, args[0]),
		.y = (int)env->extract_integer(env, args[1]),
		.width = (int)env->extract_integer(env, args[2]),
		.height = (int)env->extract_integer(env, args[3]),
	};
	if (target.width <= 0 || target.height <= 0)
		return env->intern(env, "nil");
	VideoCanvasTransportLayout layout =
		video_canvas_transport_layout(target);
	emacs_value rectangles[] = {
		rect_value(env, layout.toggle),
		rect_value(env, layout.mute),
		rect_value(env, layout.seek),
	};
	return env->funcall(env, env->intern(env, "vector"), 3, rectangles);
}

static emacs_value native_canvas_draw_controls(
	emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	int canvas_width = (int)env->extract_integer(env, args[1]);
	int canvas_height = (int)env->extract_integer(env, args[2]);
	VideoCanvasRect target = {
		.x = (int)env->extract_integer(env, args[3]),
		.y = (int)env->extract_integer(env, args[4]),
		.width = (int)env->extract_integer(env, args[5]),
		.height = (int)env->extract_integer(env, args[6]),
	};
	double position = env->extract_float(env, args[8]);
	double duration = env->extract_float(env, args[9]);
	VideoCanvasRange ranges[64];
	ptrdiff_t range_values = env->vec_size(env, args[16]);
	if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
		return env->intern(env, "nil");
	size_t range_count = (size_t)(range_values / 2);
	if (range_count > G_N_ELEMENTS(ranges))
		range_count = G_N_ELEMENTS(ranges);
	for (size_t index = 0; index < range_count; ++index) {
		ranges[index].start = env->extract_float(
			env, env->vec_get(env, args[16],
					  (ptrdiff_t)(index * 2)));
		ranges[index].end = env->extract_float(
			env, env->vec_get(env, args[16],
					  (ptrdiff_t)(index * 2 + 1)));
	}
	if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
		return env->intern(env, "nil");
	VideoCanvasTransportState state = {
		.playing = env->is_not_nil(env, args[7]),
		.muted = env->is_not_nil(env, args[10]),
		.waiting = env->is_not_nil(env, args[12]),
		.has_frame = env->is_not_nil(env, args[14]),
		.seekable = env->is_not_nil(env, args[15]),
		.progress = duration > 0.0 ? position / duration : 0.0,
		.buffering = env->extract_float(env, args[13]) / 100.0,
		.spinner_phase = fmod(
			(double)g_get_monotonic_time() / G_USEC_PER_SEC, 1.0),
		.opacity = env->extract_float(env, args[11]),
		.buffered_ranges = ranges,
		.buffered_range_count = range_count,
	};
	if (canvas_width <= 0 || canvas_height <= 0 ||
	    target.width <= 0 || target.height <= 0 ||
	    (state.opacity <= 0.0 && !state.waiting))
		return env->intern(env, "nil");
	uint32_t *canvas = env->canvas_data(env, args[0]);
	if (!canvas ||
	    env->non_local_exit_check(env) != emacs_funcall_exit_return)
		return env->intern(env, "nil");
	VideoCanvasTransportLayout layout =
		video_canvas_transport_layout(target);
	video_canvas_draw_transport(canvas, canvas_width, canvas_height,
				    &layout, &state);
	return env->intern(env, "t");
}

static emacs_value native_target_copy(emacs_env *env, ptrdiff_t nargs,
				      emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoTarget *target = get_target(env, args[0]);
	gint canvas_width = (gint)env->extract_integer(env, args[2]);
	gint canvas_height = (gint)env->extract_integer(env, args[3]);
	gint dest_x = (gint)env->extract_integer(env, args[4]);
	gint dest_y = (gint)env->extract_integer(env, args[5]);
	if (!target)
		return env->intern(env, "nil");

	g_mutex_lock(&target->lock);
	if (!target->front || target->front_width != target->width ||
	    target->front_height != target->height ||
	    canvas_width <= 0 || canvas_height <= 0 ||
	    dest_x >= canvas_width || dest_y >= canvas_height ||
	    dest_x + target->width <= 0 || dest_y + target->height <= 0) {
		g_mutex_unlock(&target->lock);
		return env->intern(env, "nil");
	}

	uint32_t *canvas = env->canvas_data(env, args[1]);
	if (!canvas || env->non_local_exit_check(env) != emacs_funcall_exit_return) {
		g_mutex_unlock(&target->lock);
		return env->intern(env, "nil");
	}
	GstVideoFrame frame;
	if (!gst_video_frame_map(&frame, &target->converter_output,
				 target->front, GST_MAP_READ)) {
		g_mutex_unlock(&target->lock);
		return env->intern(env, "nil");
	}
	gboolean copied = video_canvas_blit_bgra(
		canvas, canvas_width, canvas_height,
		GST_VIDEO_FRAME_PLANE_DATA(&frame, 0),
		target->width, target->height,
		GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0),
		dest_x, dest_y);
	gst_video_frame_unmap(&frame);
	guint64 sequence = target->sequence;
	g_mutex_unlock(&target->lock);
	return copied ? env->make_integer(env, (intmax_t)sequence)
		      : env->intern(env, "nil");
}

static GstSample *decode_uri_preroll(const gchar *uri)
{
	GstElement *playbin = gst_element_factory_make("playbin3", NULL);
	GstElement *sink = gst_element_factory_make("appsink", NULL);
	GstElement *audio_sink = gst_element_factory_make("fakesink", NULL);
	GstSample *sample = NULL;

	if (!playbin || !sink || !audio_sink)
		goto done;

	gst_object_ref_sink(sink);
	gst_object_ref_sink(audio_sink);
	GstCaps *caps = gst_caps_new_empty_simple("video/x-raw");
	gst_app_sink_set_caps(GST_APP_SINK(sink), caps);
	gst_caps_unref(caps);
	g_object_set(sink, "sync", FALSE, "max-buffers", 1u,
		     "drop", TRUE, NULL);
	g_object_set(playbin, "uri", uri, "video-sink", sink,
		     "audio-sink", audio_sink, NULL);
	if (gst_element_set_state(playbin, GST_STATE_PAUSED) ==
	    GST_STATE_CHANGE_FAILURE)
		goto done;
	if (gst_element_get_state(
		    playbin, NULL, NULL, 5 * GST_SECOND) ==
	    GST_STATE_CHANGE_FAILURE)
		goto done;
	sample = gst_app_sink_try_pull_preroll(
		GST_APP_SINK(sink), 5 * GST_SECOND);

done:
	if (playbin) {
		gst_element_set_state(playbin, GST_STATE_NULL);
		gst_object_unref(playbin);
	}
	if (sink)
		gst_object_unref(sink);
	if (audio_sink)
		gst_object_unref(audio_sink);
	return sample;
}

static emacs_value native_canvas_draw_uri(emacs_env *env, ptrdiff_t nargs,
					  emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	gint canvas_width = (gint)env->extract_integer(env, args[1]);
	gint canvas_height = (gint)env->extract_integer(env, args[2]);
	char *uri = copy_string(env, args[3]);
	gint dest_x = (gint)env->extract_integer(env, args[4]);
	gint dest_y = (gint)env->extract_integer(env, args[5]);
	gint width = (gint)env->extract_integer(env, args[6]);
	gint height = (gint)env->extract_integer(env, args[7]);
	char *fit_name = copy_string(env, args[8]);
	GstSample *sample = NULL;
	GstVideoConverter *converter = NULL;
	GstBuffer *output_buffer = NULL;
	GstVideoFrame input_frame;
	GstVideoFrame output_frame;
	gboolean input_mapped = FALSE;
	gboolean output_mapped = FALSE;
	gboolean copied = FALSE;

	if (!uri || !fit_name)
		goto done;
	if (canvas_width <= 0 || canvas_height <= 0 ||
	    width <= 0 || height <= 0 ||
	    (gint64)canvas_width * canvas_height > 33554432)
		goto done;

	sample = decode_uri_preroll(uri);
	if (!sample)
		goto done;
	GstCaps *caps = gst_sample_get_caps(sample);
	GstBuffer *input_buffer = gst_sample_get_buffer(sample);
	GstVideoInfo input_info;
	if (!caps || !input_buffer ||
	    !gst_video_info_from_caps(&input_info, caps))
		goto done;

	GstVideoInfo output_info;
#if G_BYTE_ORDER == G_LITTLE_ENDIAN
	GstVideoFormat format = GST_VIDEO_FORMAT_BGRA;
#else
	GstVideoFormat format = GST_VIDEO_FORMAT_ARGB;
#endif
	gst_video_info_set_format(&output_info, format, width, height);
	GST_VIDEO_INFO_FPS_N(&output_info) = GST_VIDEO_INFO_FPS_N(&input_info);
	GST_VIDEO_INFO_FPS_D(&output_info) = GST_VIDEO_INFO_FPS_D(&input_info);
	GST_VIDEO_INFO_PAR_N(&output_info) = 1;
	GST_VIDEO_INFO_PAR_D(&output_info) = 1;

	VideoTarget geometry = {
		.width = width,
		.height = height,
		.fit = parse_fit_name(fit_name),
		.scale = 0.0,
		.viewport_x = 0.0,
		.viewport_y = 0.0,
	};
	gint src_x, src_y, src_width, src_height;
	gint out_x, out_y, out_width, out_height;
	target_compute_rectangles(
		&geometry, &input_info, &src_x, &src_y,
		&src_width, &src_height, &out_x, &out_y,
		&out_width, &out_height);
	GstStructure *config = gst_structure_new(
		"video-converter-config",
		GST_VIDEO_CONVERTER_OPT_SRC_X, G_TYPE_INT, src_x,
		GST_VIDEO_CONVERTER_OPT_SRC_Y, G_TYPE_INT, src_y,
		GST_VIDEO_CONVERTER_OPT_SRC_WIDTH, G_TYPE_INT, src_width,
		GST_VIDEO_CONVERTER_OPT_SRC_HEIGHT, G_TYPE_INT, src_height,
		GST_VIDEO_CONVERTER_OPT_DEST_X, G_TYPE_INT, out_x,
		GST_VIDEO_CONVERTER_OPT_DEST_Y, G_TYPE_INT, out_y,
		GST_VIDEO_CONVERTER_OPT_DEST_WIDTH, G_TYPE_INT, out_width,
		GST_VIDEO_CONVERTER_OPT_DEST_HEIGHT, G_TYPE_INT, out_height,
		GST_VIDEO_CONVERTER_OPT_FILL_BORDER, G_TYPE_BOOLEAN, TRUE,
		NULL);
	converter = gst_video_converter_new(
		&input_info, &output_info, config);
	if (!converter)
		goto done;
	output_buffer = gst_buffer_new_allocate(NULL, output_info.size, NULL);
	if (!output_buffer)
		goto done;
	if (!gst_video_frame_map(&input_frame, &input_info,
				 input_buffer, GST_MAP_READ))
		goto done;
	input_mapped = TRUE;
	if (!gst_video_frame_map(&output_frame, &output_info,
				 output_buffer, GST_MAP_WRITE))
		goto done;
	output_mapped = TRUE;
	memset(GST_VIDEO_FRAME_PLANE_DATA(&output_frame, 0), 0,
	       (gsize)GST_VIDEO_FRAME_PLANE_STRIDE(&output_frame, 0) *
		       height);
	gst_video_converter_frame(converter, &input_frame, &output_frame);

	uint32_t *canvas = env->canvas_data(env, args[0]);
	if (!canvas ||
	    env->non_local_exit_check(env) != emacs_funcall_exit_return)
		goto done;
	copied = video_canvas_blit_bgra(
		canvas, canvas_width, canvas_height,
		GST_VIDEO_FRAME_PLANE_DATA(&output_frame, 0),
		width, height,
		GST_VIDEO_FRAME_PLANE_STRIDE(&output_frame, 0),
		dest_x, dest_y);

done:
	if (output_mapped)
		gst_video_frame_unmap(&output_frame);
	if (input_mapped)
		gst_video_frame_unmap(&input_frame);
	if (converter)
		gst_video_converter_free(converter);
	gst_clear_buffer(&output_buffer);
	gst_clear_sample(&sample);
	g_free(uri);
	g_free(fit_name);
	return copied ? env->intern(env, "t") : env->intern(env, "nil");
}

static void bind_function(emacs_env *env, const char *name,
			  emacs_value (*function)(emacs_env *, ptrdiff_t,
						  emacs_value *, void *),
			  ptrdiff_t minimum, ptrdiff_t maximum,
			  const char *documentation)
{
	emacs_value symbol = env->intern(env, name);
	emacs_value lambda = env->make_function(env, minimum, maximum, function,
						documentation, NULL);
	emacs_value arguments[] = { symbol, lambda };
	env->funcall(env, env->intern(env, "defalias"), 2, arguments);
}

int emacs_module_init(struct emacs_runtime *runtime)
{
	emacs_env *env = runtime->get_environment(runtime);
	GError *error = NULL;
	if (!gst_init_check(NULL, NULL, &error)) {
		if (error)
			g_error_free(error);
		return 1;
	}
	if (!reaper_queue) {
		reaper_queue = g_async_queue_new();
		reaper_thread = g_thread_new("video-reaper", reaper_main, reaper_queue);
		(void)reaper_thread;
	}

	bind_function(env, "video-native-create", native_create, 5, 5,
		      "Create a native video player for URI, PIPE-PROCESS, CACHE-SIZE, CACHE-TEMPLATE, and REQUEST-HEADERS.");
	bind_function(env, "video-native-close", native_close, 1, 1,
		      "Close native video PLAYER.");
	bind_function(env, "video-native-play", native_play, 1, 1,
		      "Start native video PLAYER.");
	bind_function(env, "video-native-pause", native_pause, 1, 1,
		      "Pause native video PLAYER.");
	bind_function(env, "video-native-stop", native_stop, 1, 1,
		      "Stop native video PLAYER.");
	bind_function(env, "video-native-seek", native_seek, 2, 2,
		      "Seek native video PLAYER to SECONDS.");
	bind_function(env, "video-native-buffered-ranges", native_buffered_ranges,
		      1, 1,
		      "Return buffered native video PLAYER time ranges.");
	bind_function(env, "video-native-set-volume", native_set_volume, 2, 2,
		      "Set native video PLAYER volume.");
	bind_function(env, "video-native-set-muted", native_set_muted, 2, 2,
		      "Set native video PLAYER mute state.");
	bind_function(env, "video-native-set-rate", native_set_rate, 2, 2,
		      "Set native video PLAYER rate.");
	bind_function(env, "video-native-poll", native_poll, 1, 1,
		      "Return current native video PLAYER state.");
	bind_function(env, "video-native-target-create", native_target_create, 7, 7,
		      "Create a render target for native video PLAYER.");
	bind_function(env, "video-native-target-close", native_target_close, 1, 1,
		      "Close native render TARGET.");
	bind_function(env, "video-native-target-set-view", native_target_set_view,
		      7, 7, "Set native TARGET viewport geometry.");
	bind_function(env, "video-native-target-copy", native_target_copy, 6, 6,
		      "Copy native TARGET pixels into CANVAS at a destination.");
	bind_function(env, "video-native-canvas-draw-uri",
		      native_canvas_draw_uri, 9, 9,
		      "Draw one decoded URI into a Canvas rectangle.");
	bind_function(env, "video-native-control-layout",
		      native_control_layout, 4, 4,
		      "Return transport control rectangles for a video region.");
	bind_function(env, "video-native-canvas-draw-controls",
		      native_canvas_draw_controls, 17, 17,
		      "Draw transport, buffered ranges, and waiting state into a Canvas video rectangle.");

	emacs_value feature = env->intern(env, "video-module");
	env->funcall(env, env->intern(env, "provide"), 1, &feature);
	return env->non_local_exit_check(env) == emacs_funcall_exit_return ? 0 : 1;
}
