/* video-runtime.c --- Playback and frame ownership for video.el  -*- c-file-style: "linux" -*-
 *
 * Copyright (C) 2026 0WD0
 *
 * This file is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version.
 */

#include <gst/app/gstappsink.h>
#include <gst/play/play.h>
#include <gst/video/video-converter.h>
#include <gst/video/video.h>
#include <glib/gstdio.h>

#include "video-runtime.h"
#include "video-canvas.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <string.h>
#include <unistd.h>

enum { VIDEO_PLAY_FLAG_DOWNLOAD = (1 << 7) };

typedef struct {
	GObject parent;
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
	VideoViewConfig view;
	guint64 generation;
	GstBuffer *front;
	GstBuffer *back;
	gint front_width;
	gint front_height;
	guint64 front_generation;
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
	g_mutex_lock(&session->lock);
	if (!session->closing && session->notify_fd >= 0) {
		ssize_t result;
		do {
			result = write(session->notify_fd, &kind, 1);
		} while (result < 0 && errno == EINTR);
	}
	g_mutex_unlock(&session->lock);
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

static void session_closure_unref(gpointer data, GClosure *closure)
{
	(void)closure;
	session_unref(data);
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
	session_notify(session,
	               type == GST_PLAY_MESSAGE_POSITION_UPDATED ? 'p' : 'e');
	return GST_BUS_PASS;
}

static void session_element_setup(GstElement *pipeline, GstElement *element,
                                  gpointer data)
{
	VideoSession *session = data;
	GstElementFactory *factory = gst_element_get_factory(element);
	const gchar *factory_name =
	        factory ? gst_plugin_feature_get_name(
	                          GST_PLUGIN_FEATURE(factory))
	                : NULL;
	gchar *cache_template = NULL;
	GstElement *old_download_buffer = NULL;
	(void)pipeline;

	if (session->request_headers &&
	    g_object_class_find_property(G_OBJECT_GET_CLASS(element),
	                                 "extra-headers"))
		g_object_set(element, "extra-headers", session->request_headers,
		             NULL);
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

static void session_pipeline_cache_message(GstBus *bus, GstMessage *message,
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
			if (gst_element_query_duration(download_buffer,
			                               GST_FORMAT_BYTES,
			                               &total) &&
			    total > 0) {
				complete = covered >= total;
			} else if (session->eos) {
				GStatBuf file_info;
				if (g_stat(location, &file_info) == 0 &&
				    file_info.st_size > 0)
					complete = covered >=
					           (gint64)file_info.st_size;
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

static gboolean view_axis_rectangle(gint input_length, gint viewport_length,
                                    gdouble scale, gdouble requested_origin,
                                    gint *src_position, gint *src_length,
                                    gint *dst_position, gint *dst_length)
{
	gdouble scaled_length = (gdouble)input_length * scale;
	gdouble visible_start = MAX(0.0, requested_origin);
	gdouble visible_end =
	        MIN(scaled_length, requested_origin + viewport_length);

	*src_position = 0;
	*src_length = 0;
	*dst_position = 0;
	*dst_length = 0;
	if (!(visible_end > visible_start))
		return FALSE;

	gint source_start =
	        CLAMP((gint)floor(visible_start / scale), 0, input_length - 1);
	gint source_end = CLAMP((gint)ceil(visible_end / scale),
	                        source_start + 1, input_length);
	gint destination_start =
	        CLAMP((gint)floor(visible_start - requested_origin), 0,
	              viewport_length - 1);
	gint destination_end = CLAMP((gint)ceil(visible_end - requested_origin),
	                             destination_start + 1, viewport_length);

	*src_position = source_start;
	*src_length = source_end - source_start;
	*dst_position = destination_start;
	*dst_length = destination_end - destination_start;
	return TRUE;
}

static gboolean view_compute_rectangles(const VideoViewConfig *view,
                                        const GstVideoInfo *input, gint *src_x,
                                        gint *src_y, gint *src_width,
                                        gint *src_height, gint *dst_x,
                                        gint *dst_y, gint *dst_width,
                                        gint *dst_height)
{
	gint in_width = GST_VIDEO_INFO_WIDTH(input);
	gint in_height = GST_VIDEO_INFO_HEIGHT(input);
	gdouble scale_x = (gdouble)view->width / (gdouble)in_width;
	gdouble scale_y = (gdouble)view->height / (gdouble)in_height;
	gdouble base_scale;

	switch (view->fit) {
	case VIDEO_FIT_SHRINK:
		base_scale = MIN(1.0, MIN(scale_x, scale_y));
		break;
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

	gboolean explicit_scale = isfinite(view->scale) && view->scale > 0.0;
	gdouble scale = CLAMP(explicit_scale ? view->scale : base_scale, 0.0001,
	                      65536.0);
	gdouble scaled_width = in_width * scale;
	gdouble scaled_height = in_height * scale;
	gdouble viewport_x = explicit_scale
	                             ? view->viewport_x
	                             : (scaled_width - view->width) / 2.0;
	gdouble viewport_y = explicit_scale
	                             ? view->viewport_y
	                             : (scaled_height - view->height) / 2.0;
	gboolean visible_x =
	        view_axis_rectangle(in_width, view->width, scale, viewport_x,
	                            src_x, src_width, dst_x, dst_width);
	gboolean visible_y =
	        view_axis_rectangle(in_height, view->height, scale, viewport_y,
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
	gst_video_info_set_format(&output, format, target->view.width,
	                          target->view.height);
	GST_VIDEO_INFO_FPS_N(&output) = GST_VIDEO_INFO_FPS_N(input);
	GST_VIDEO_INFO_FPS_D(&output) = GST_VIDEO_INFO_FPS_D(input);
	GST_VIDEO_INFO_PAR_N(&output) = 1;
	GST_VIDEO_INFO_PAR_D(&output) = 1;

	gint src_x, src_y, src_width, src_height;
	gint dst_x, dst_y, dst_width, dst_height;
	*has_content = view_compute_rectangles(
	        &target->view, input, &src_x, &src_y, &src_width, &src_height,
	        &dst_x, &dst_y, &dst_width, &dst_height);

	if (target->converter_valid &&
	    target->converter_generation == generation &&
	    gst_video_info_is_equal(&target->converter_input, input) &&
	    gst_video_info_is_equal(&target->converter_output, &output) &&
	    ((*has_content && target->converter) ||
	     (!*has_content && !target->converter))) {
		if (!target->back)
			target->back = gst_buffer_new_allocate(
			        NULL, output.size, NULL);
		return target->back != NULL;
	}

	if (target->converter) {
		gst_video_converter_free(target->converter);
		target->converter = NULL;
	}
	if (target->back && gst_buffer_get_size(target->back) != output.size)
		gst_clear_buffer(&target->back);
	if (!target->back)
		target->back = gst_buffer_new_allocate(NULL, output.size, NULL);
	if (!target->back)
		return FALSE;

	if (*has_content) {
		GstStructure *config = gst_structure_new(
		        "video-converter-config", GST_VIDEO_CONVERTER_OPT_SRC_X,
		        G_TYPE_INT, src_x, GST_VIDEO_CONVERTER_OPT_SRC_Y,
		        G_TYPE_INT, src_y, GST_VIDEO_CONVERTER_OPT_SRC_WIDTH,
		        G_TYPE_INT, src_width,
		        GST_VIDEO_CONVERTER_OPT_SRC_HEIGHT, G_TYPE_INT,
		        src_height, GST_VIDEO_CONVERTER_OPT_DEST_X, G_TYPE_INT,
		        dst_x, GST_VIDEO_CONVERTER_OPT_DEST_Y, G_TYPE_INT,
		        dst_y, GST_VIDEO_CONVERTER_OPT_DEST_WIDTH, G_TYPE_INT,
		        dst_width, GST_VIDEO_CONVERTER_OPT_DEST_HEIGHT,
		        G_TYPE_INT, dst_height,
		        GST_VIDEO_CONVERTER_OPT_FILL_BORDER, G_TYPE_BOOLEAN,
		        TRUE, NULL);

		target->converter =
		        gst_video_converter_new(input, &output, config);
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

	if (!caps || !input_buffer ||
	    !gst_video_info_from_caps(&input_info, caps))
		return;

	g_mutex_lock(&target->lock);
	if (target->closed || target->view.width <= 0 ||
	    target->view.height <= 0) {
		g_mutex_unlock(&target->lock);
		return;
	}
	generation = target->generation;
	if (!target_prepare_converter(target, &input_info, generation,
	                              &has_content)) {
		g_mutex_unlock(&target->lock);
		return;
	}
	/* Only this session's render worker writes converter/back.  View changes
	 * invalidate without freeing them; the worker's target reference keeps
	 * both alive while conversion runs outside the lock. */
	converter = target->converter;
	back = target->back;
	output_info = target->converter_output;
	output_height = target->view.height;
	g_mutex_unlock(&target->lock);

	if (has_content && !gst_video_frame_map(&input_frame, &input_info,
	                                        input_buffer, GST_MAP_READ))
		return;
	if (!gst_video_frame_map(&output_frame, &output_info, back,
	                         GST_MAP_WRITE)) {
		if (has_content)
			gst_video_frame_unmap(&input_frame);
		return;
	}

	target_clear_output(&output_frame, GST_VIDEO_INFO_WIDTH(&output_info),
	                    output_height);
	if (has_content)
		gst_video_converter_frame(converter, &input_frame,
		                          &output_frame);
	gst_video_frame_unmap(&output_frame);
	if (has_content)
		gst_video_frame_unmap(&input_frame);

	g_mutex_lock(&target->lock);
	if (!target->closed && target->generation == generation) {
		GstBuffer *old_front = target->front;
		/* A resized front must not recycle the previous geometry's
		 * buffer: the next frame would fail to map after growing. */
		if (target->front_width != GST_VIDEO_INFO_WIDTH(&output_info) ||
		    target->front_height != GST_VIDEO_INFO_HEIGHT(&output_info))
			gst_clear_buffer(&old_front);
		target->front = back;
		target->back = old_front;
		target->front_width = GST_VIDEO_INFO_WIDTH(&output_info);
		target->front_height = GST_VIDEO_INFO_HEIGHT(&output_info);
		target->front_generation = generation;
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
		targets = g_ptr_array_new_with_free_func(
		        (GDestroyNotify)target_unref);
		for (guint i = 0; i < session->targets->len; ++i) {
			VideoTarget *target =
			        g_ptr_array_index(session->targets, i);
			target_ref(target);
			g_ptr_array_add(targets, target);
		}
		g_mutex_unlock(&session->lock);

		if (sample) {
			for (guint i = 0; i < targets->len; ++i)
				target_render(g_ptr_array_index(targets, i),
				              sample);
			gst_sample_unref(sample);
			session_notify(session, 'f');
		}
		g_ptr_array_unref(targets);
	}
	return NULL;
}

VideoSession *video_session_new(const gchar *uri, int notify_fd,
                                guint64 network_cache_size,
                                const gchar *cache_template,
                                GStrv request_headers, GError **error)
{
	VideoSession *session = g_new0(VideoSession, 1);
	if (request_headers) {
		/* The bridge already supplies alternating field names and values. */
		session->request_headers =
		        gst_structure_new_empty("request-headers");
		for (gsize index = 0; request_headers[index]; index += 2)
			gst_structure_set(session->request_headers,
			                  request_headers[index], G_TYPE_STRING,
			                  request_headers[index + 1], NULL);
		g_strfreev(request_headers);
	}
	g_atomic_ref_count_init(&session->refs);
	g_mutex_init(&session->lock);
	g_cond_init(&session->render_cond);
	session->notify_fd = notify_fd;
	session->state = GST_PLAY_STATE_STOPPED;
	session->position = GST_CLOCK_TIME_NONE;
	session->duration = GST_CLOCK_TIME_NONE;
	session->buffering = 100;
	session->targets =
	        g_ptr_array_new_with_free_func((GDestroyNotify)target_unref);
	session->cache_template = g_strdup(cache_template);

	if (!gst_uri_is_valid(uri)) {
		g_set_error_literal(error, GST_CORE_ERROR,
		                    GST_CORE_ERROR_FAILED,
		                    "Video source must be an absolute URI");
		session_unref(session);
		return NULL;
	}
	int flags = fcntl(notify_fd, F_GETFL, 0);
	if (flags >= 0)
		(void)fcntl(notify_fd, F_SETFL, flags | O_NONBLOCK);

	GstElement *sink = gst_element_factory_make("appsink", NULL);
	if (!sink) {
		g_set_error_literal(error, GST_CORE_ERROR,
		                    GST_CORE_ERROR_MISSING_PLUGIN,
		                    "GStreamer appsink is unavailable");
		session_unref(session);
		return NULL;
	}

	GstCaps *caps = gst_caps_new_empty_simple("video/x-raw");
	gst_app_sink_set_caps(GST_APP_SINK(sink), caps);
	gst_caps_unref(caps);
	g_object_set(sink, "sync", TRUE, "max-buffers", 1u, "drop", TRUE,
	             "enable-last-sample", FALSE, NULL);

	VideoRenderer *renderer = g_object_new(VIDEO_TYPE_RENDERER, NULL);
	renderer->sink = gst_object_ref_sink(sink);
	session->play = gst_play_new(GST_PLAY_VIDEO_RENDERER(renderer));
	if (!session->play) {
		g_set_error_literal(error, GST_CORE_ERROR,
		                    GST_CORE_ERROR_FAILED,
		                    "Could not create GstPlay");
		session_unref(session);
		return NULL;
	}

	GstAppSinkCallbacks callbacks = {
	        .eos = appsink_eos,
	        .new_preroll = appsink_new_preroll,
	        .new_sample = appsink_new_sample,
	};
	/* Appsink and in-flight callbacks can outlive GstPlay's renderer. */
	session_ref(session);
	gst_app_sink_set_callbacks(GST_APP_SINK(sink), &callbacks, session,
	                           (GDestroyNotify)session_unref);

	session->pipeline = gst_play_get_pipeline(session->play);
	if (session->pipeline && (cache_template || session->request_headers) &&
	    g_signal_lookup("element-setup",
	                    G_OBJECT_TYPE(session->pipeline)) != 0) {
		session_ref(session);
		session->element_setup_handler = g_signal_connect_data(
		        session->pipeline, "element-setup",
		        G_CALLBACK(session_element_setup), session,
		        session_closure_unref, 0);
	}
	if (session->pipeline && cache_template) {
		session->pipeline_bus = gst_element_get_bus(session->pipeline);
		if (session->pipeline_bus) {
			gst_bus_enable_sync_message_emission(
			        session->pipeline_bus);
			session_ref(session);
			session->pipeline_message_handler =
			        g_signal_connect_data(
			                session->pipeline_bus,
			                "sync-message::element",
			                G_CALLBACK(
			                        session_pipeline_cache_message),
			                session, session_closure_unref, 0);
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
	session_ref(session);
	gst_bus_set_sync_handler(session->bus, session_bus_sync, session,
	                         (GDestroyNotify)session_unref);
	gst_play_set_uri(session->play, uri);
	session->render_thread =
	        g_thread_new("video-render", session_render_main, session);
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
		/* API messages own GstPlay references.  Flushing here could
		 * release the last one on its worker, whose dispose cannot join
		 * itself.  Drain on this thread instead, keeping the bus open
		 * until GstPlay's dispose has joined its worker. */
		GstPlay *play = session->play;
		g_object_add_weak_pointer(G_OBJECT(play), (gpointer *)&play);
		g_clear_object(&session->play);
		while (play) {
			GstMessage *message = gst_bus_timed_pop(
			        session->bus, GST_CLOCK_TIME_NONE);
			gst_message_unref(message);
		}
		gst_clear_object(&session->bus);
	}
	gst_clear_object(&session->pipeline_bus);
	gst_clear_object(&session->download_buffer);
	gst_clear_object(&session->pipeline);
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

VideoTarget *video_target_new(VideoSession *session,
                              const VideoViewConfig *view)
{
	VideoTarget *target = g_new0(VideoTarget, 1);
	g_atomic_ref_count_init(&target->refs);
	g_mutex_init(&target->lock);
	target->session = session;
	session_ref(session);
	target->view = *view;
	target->view.scale = isfinite(view->scale) && view->scale > 0.0
	                             ? CLAMP(view->scale, 0.0001, 65536.0)
	                             : 0.0;
	target->view.viewport_x =
	        isfinite(view->viewport_x) ? view->viewport_x : 0.0;
	target->view.viewport_y =
	        isfinite(view->viewport_y) ? view->viewport_y : 0.0;
	target->generation = 1;

	g_mutex_lock(&session->lock);
	target_ref(target);
	g_ptr_array_add(session->targets, target);
	session->render_pending = TRUE;
	g_cond_signal(&session->render_cond);
	g_mutex_unlock(&session->lock);
	return target;
}

/* Public close consumes exactly the reference held by the foreign handle. */
void video_session_close(VideoSession *session)
{
	session_close(session);
	session_unref(session);
}

void video_target_close(VideoTarget *target)
{
	target_close(target);
	target_unref(target);
}

void video_session_reap(VideoSession *session)
{
	if (session)
		queue_reap(REAP_SESSION, session);
}

void video_target_reap(VideoTarget *target)
{
	if (target)
		queue_reap(REAP_TARGET, target);
}

void video_session_play(VideoSession *session)
{
	session->eos = FALSE;
	g_clear_pointer(&session->error, g_free);
	gst_play_play(session->play);
}

void video_session_pause(VideoSession *session)
{
	gst_play_pause(session->play);
}

void video_session_stop(VideoSession *session)
{
	session->eos = FALSE;
	session->seeking = FALSE;
	gst_play_stop(session->play);
}

void video_session_seek(VideoSession *session, gdouble seconds)
{
	if (seconds >= 0.0) {
		GstClockTime position = (GstClockTime)(seconds * GST_SECOND);
		session->eos = FALSE;
		session->seeking = TRUE;
		session->position = position;
		gst_play_seek(session->play, position);
	}
}

void video_session_set_volume(VideoSession *session, gdouble volume)
{
	gst_play_set_volume(session->play, CLAMP(volume, 0.0, 1.0));
}

void video_session_set_muted(VideoSession *session, gboolean muted)
{
	gst_play_set_mute(session->play, muted);
}

void video_session_set_rate(VideoSession *session, gdouble rate)
{
	if (rate > 0.0)
		gst_play_set_rate(session->play, rate);
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
		if (!gst_query_parse_nth_buffering_range(query, index, &start,
		                                         &end) ||
		    start < 0 || end <= start)
			continue;

		VideoBufferedRange range;
		if (format == GST_FORMAT_TIME) {
			range.start = (gdouble)start / GST_SECOND;
			range.end = (gdouble)end / GST_SECOND;
		} else if (format == GST_FORMAT_PERCENT && duration > 0.0) {
			range.start = duration * (gdouble)start /
			              GST_FORMAT_PERCENT_MAX;
			range.end = duration * (gdouble)end /
			            GST_FORMAT_PERCENT_MAX;
		} else {
			continue;
		}
		g_array_append_val(ranges, range);
	}
	gst_query_unref(query);
}

GArray *video_session_buffered_ranges(VideoSession *session)
{
	GstElement *pipeline = gst_play_get_pipeline(session->play);
	if (!pipeline)
		return g_array_new(FALSE, FALSE, sizeof(VideoBufferedRange));

	GArray *ranges = g_array_new(FALSE, FALSE, sizeof(VideoBufferedRange));
	append_buffered_ranges(pipeline, GST_FORMAT_TIME, 0.0, ranges);
	if (ranges->len == 0) {
		gint64 duration = GST_CLOCK_TIME_NONE;
		if (gst_element_query_duration(pipeline, GST_FORMAT_TIME,
		                               &duration) &&
		    GST_CLOCK_TIME_IS_VALID(duration))
			append_buffered_ranges(pipeline, GST_FORMAT_PERCENT,
			                       (gdouble)duration / GST_SECOND,
			                       ranges);
	}
	gst_object_unref(pipeline);
	return ranges;
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
			gst_play_message_parse_position_updated(message,
			                                        &position);
			if (!session->seeking)
				session->position = position;
			break;
		}
		case GST_PLAY_MESSAGE_SEEK_DONE:
			gst_play_message_parse_seek_done(message,
			                                 &session->position);
			session->seeking = FALSE;
			break;
		case GST_PLAY_MESSAGE_DURATION_CHANGED:
			gst_play_message_parse_duration_changed(
			        message, &session->duration);
			break;
		case GST_PLAY_MESSAGE_STATE_CHANGED:
			gst_play_message_parse_state_changed(message,
			                                     &session->state);
			break;
		case GST_PLAY_MESSAGE_BUFFERING:
			gst_play_message_parse_buffering(message,
			                                 &session->buffering);
			break;
		case GST_PLAY_MESSAGE_VIDEO_DIMENSIONS_CHANGED:
			gst_play_message_parse_video_dimensions_changed(
			        message, &session->video_width,
			        &session->video_height);
			break;
		case GST_PLAY_MESSAGE_END_OF_STREAM:
			session->eos = TRUE;
			break;
		case GST_PLAY_MESSAGE_ERROR: {
			GError *error = NULL;
			GstStructure *details = NULL;
			gst_play_message_parse_error(message, &error, &details);
			g_free(session->error);
			session->error = g_strdup(error ? error->message
			                                : "Playback failed");
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

void video_session_poll(VideoSession *session, VideoSessionStatus *status)
{
	session_poll_bus(session);
	session_detect_completed_cache(session);
	session_query_capabilities(session, &status->seekable, &status->live);
	g_mutex_lock(&session->lock);
	status->cache_location = g_steal_pointer(&session->cache_location);
	g_mutex_unlock(&session->lock);
	status->state = gst_play_state_get_name(session->state);
	status->error = session->error;
	status->position = GST_CLOCK_TIME_IS_VALID(session->position)
	                           ? (gdouble)session->position / GST_SECOND
	                           : NAN;
	status->duration = GST_CLOCK_TIME_IS_VALID(session->duration)
	                           ? (gdouble)session->duration / GST_SECOND
	                           : NAN;
	status->buffering = session->buffering;
	status->width = session->video_width;
	status->height = session->video_height;
	status->eos = session->eos;
}

void video_session_status_clear(VideoSessionStatus *status)
{
	g_clear_pointer(&status->cache_location, g_free);
}

void video_target_set_view(VideoTarget *target, const VideoViewConfig *view)
{
	g_mutex_lock(&target->lock);
	target->view = *view;
	target->view.scale = isfinite(view->scale) && view->scale > 0.0
	                             ? CLAMP(view->scale, 0.0001, 65536.0)
	                             : 0.0;
	target->view.viewport_x =
	        isfinite(view->viewport_x) ? view->viewport_x : 0.0;
	target->view.viewport_y =
	        isfinite(view->viewport_y) ? view->viewport_y : 0.0;
	target->generation++;
	target->converter_valid = FALSE;
	g_mutex_unlock(&target->lock);
	/* Never acquire the session lock while holding the target lock. */
	session_request_render(target->session);
}

gboolean video_target_copy(VideoTarget *target, uint32_t *canvas,
                           gint canvas_width, gint canvas_height, gint dest_x,
                           gint dest_y, guint64 *sequence)
{
	g_mutex_lock(&target->lock);
	/* Leave the existing canvas untouched until this view has a frame,
	 * including same-size fit, zoom, and pan changes. */
	if (!target->front || target->front_generation != target->generation ||
	    target->front_width != target->view.width ||
	    target->front_height != target->view.height || canvas_width <= 0 ||
	    canvas_height <= 0 || dest_x >= canvas_width ||
	    dest_y >= canvas_height || dest_x + target->view.width <= 0 ||
	    dest_y + target->view.height <= 0) {
		g_mutex_unlock(&target->lock);
		return FALSE;
	}
	GstVideoFrame frame;
	if (!gst_video_frame_map(&frame, &target->converter_output,
	                         target->front, GST_MAP_READ)) {
		g_mutex_unlock(&target->lock);
		return FALSE;
	}
	gboolean copied = video_canvas_blit_bgra(
	        canvas, canvas_width, canvas_height,
	        GST_VIDEO_FRAME_PLANE_DATA(&frame, 0), target->view.width,
	        target->view.height, GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0),
	        dest_x, dest_y);
	gst_video_frame_unmap(&frame);
	if (copied)
		*sequence = target->sequence;
	g_mutex_unlock(&target->lock);
	return copied;
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
	g_object_set(sink, "sync", FALSE, "max-buffers", 1u, "drop", TRUE,
	             NULL);
	g_object_set(playbin, "uri", uri, "video-sink", sink, "audio-sink",
	             audio_sink, NULL);
	if (gst_element_set_state(playbin, GST_STATE_PAUSED) ==
	    GST_STATE_CHANGE_FAILURE)
		goto done;
	if (gst_element_get_state(playbin, NULL, NULL, 5 * GST_SECOND) ==
	    GST_STATE_CHANGE_FAILURE)
		goto done;
	sample = gst_app_sink_try_pull_preroll(GST_APP_SINK(sink),
	                                       5 * GST_SECOND);

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

gboolean video_runtime_draw_uri(const gchar *uri, const VideoViewConfig *view,
                                uint32_t *canvas, gint canvas_width,
                                gint canvas_height, gint dest_x, gint dest_y)
{
	gint width = view->width;
	gint height = view->height;
	GstSample *sample = NULL;
	GstVideoConverter *converter = NULL;
	GstBuffer *output_buffer = NULL;
	GstVideoFrame input_frame;
	GstVideoFrame output_frame;
	gboolean input_mapped = FALSE;
	gboolean output_mapped = FALSE;
	gboolean copied = FALSE;

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
	gint src_x, src_y, src_width, src_height;
	gint out_x, out_y, out_width, out_height;
	view_compute_rectangles(view, &input_info, &src_x, &src_y, &src_width,
	                        &src_height, &out_x, &out_y, &out_width,
	                        &out_height);
	GstStructure *config = gst_structure_new(
	        "video-converter-config", GST_VIDEO_CONVERTER_OPT_SRC_X,
	        G_TYPE_INT, src_x, GST_VIDEO_CONVERTER_OPT_SRC_Y, G_TYPE_INT,
	        src_y, GST_VIDEO_CONVERTER_OPT_SRC_WIDTH, G_TYPE_INT, src_width,
	        GST_VIDEO_CONVERTER_OPT_SRC_HEIGHT, G_TYPE_INT, src_height,
	        GST_VIDEO_CONVERTER_OPT_DEST_X, G_TYPE_INT, out_x,
	        GST_VIDEO_CONVERTER_OPT_DEST_Y, G_TYPE_INT, out_y,
	        GST_VIDEO_CONVERTER_OPT_DEST_WIDTH, G_TYPE_INT, out_width,
	        GST_VIDEO_CONVERTER_OPT_DEST_HEIGHT, G_TYPE_INT, out_height,
	        GST_VIDEO_CONVERTER_OPT_FILL_BORDER, G_TYPE_BOOLEAN, TRUE,
	        NULL);
	converter = gst_video_converter_new(&input_info, &output_info, config);
	if (!converter)
		goto done;
	output_buffer = gst_buffer_new_allocate(NULL, output_info.size, NULL);
	if (!output_buffer)
		goto done;
	if (!gst_video_frame_map(&input_frame, &input_info, input_buffer,
	                         GST_MAP_READ))
		goto done;
	input_mapped = TRUE;
	if (!gst_video_frame_map(&output_frame, &output_info, output_buffer,
	                         GST_MAP_WRITE))
		goto done;
	output_mapped = TRUE;
	memset(GST_VIDEO_FRAME_PLANE_DATA(&output_frame, 0), 0,
	       (gsize)GST_VIDEO_FRAME_PLANE_STRIDE(&output_frame, 0) * height);
	gst_video_converter_frame(converter, &input_frame, &output_frame);

	copied = video_canvas_blit_bgra(
	        canvas, canvas_width, canvas_height,
	        GST_VIDEO_FRAME_PLANE_DATA(&output_frame, 0), width, height,
	        GST_VIDEO_FRAME_PLANE_STRIDE(&output_frame, 0), dest_x, dest_y);

done:
	if (output_mapped)
		gst_video_frame_unmap(&output_frame);
	if (input_mapped)
		gst_video_frame_unmap(&input_frame);
	if (converter)
		gst_video_converter_free(converter);
	gst_clear_buffer(&output_buffer);
	gst_clear_sample(&sample);
	return copied;
}

gboolean video_runtime_init(GError **error)
{
	if (!gst_init_check(NULL, NULL, error))
		return FALSE;
	if (!reaper_queue) {
		reaper_queue = g_async_queue_new();
		reaper_thread =
		        g_thread_new("video-reaper", reaper_main, reaper_queue);
	}
	return TRUE;
}
