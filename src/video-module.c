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
	gdouble zoom;
	gdouble center_x;
	gdouble center_y;
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
	GstBus *bus;
	int notify_fd;
	GstPlayState state;
	GstClockTime position;
	GstClockTime duration;
	guint buffering;
	guint video_width;
	guint video_height;
	gboolean eos;
	gchar *error;
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
	(void)bus;
	(void)message;
	session_notify(session, 'e');
	return GST_BUS_PASS;
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

static void target_compute_rectangles(VideoTarget *target,
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

	gdouble scale = MAX(0.0001, base_scale * MAX(0.01, target->zoom));
	gdouble visible_width = MIN((gdouble)in_width,
				    (gdouble)target->width / scale);
	gdouble visible_height = MIN((gdouble)in_height,
				     (gdouble)target->height / scale);
	gdouble center_x = CLAMP(target->center_x, 0.0, 1.0) * in_width;
	gdouble center_y = CLAMP(target->center_y, 0.0, 1.0) * in_height;

	*src_width = MAX(1, MIN(in_width, (gint)llround(visible_width)));
	*src_height = MAX(1, MIN(in_height, (gint)llround(visible_height)));
	*src_x = CLAMP((gint)llround(center_x - *src_width / 2.0),
		       0, in_width - *src_width);
	*src_y = CLAMP((gint)llround(center_y - *src_height / 2.0),
		       0, in_height - *src_height);
	*dst_width = MIN(target->width,
			 MAX(1, (gint)llround(*src_width * scale)));
	*dst_height = MIN(target->height,
			  MAX(1, (gint)llround(*src_height * scale)));
	*dst_x = (target->width - *dst_width) / 2;
	*dst_y = (target->height - *dst_height) / 2;
}

static gboolean target_prepare_converter(VideoTarget *target,
					 const GstVideoInfo *input,
					 guint64 generation)
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

	if (target->converter_valid &&
	    target->converter_generation == generation &&
	    gst_video_info_is_equal(&target->converter_input, input) &&
	    gst_video_info_is_equal(&target->converter_output, &output))
		return TRUE;

	if (target->converter) {
		gst_video_converter_free(target->converter);
		target->converter = NULL;
	}
	gst_clear_buffer(&target->back);

	gint src_x, src_y, src_width, src_height;
	gint dst_x, dst_y, dst_width, dst_height;
	target_compute_rectangles(target, input, &src_x, &src_y,
				  &src_width, &src_height, &dst_x, &dst_y,
				  &dst_width, &dst_height);

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

	target->converter = gst_video_converter_new(input, &output, config);
	if (!target->converter)
		return FALSE;

	target->back = gst_buffer_new_allocate(NULL, output.size, NULL);
	if (!target->back)
		return FALSE;

	target->converter_input = *input;
	target->converter_output = output;
	target->converter_generation = generation;
	target->converter_valid = TRUE;
	return TRUE;
}

static void target_render(VideoTarget *target, GstSample *sample)
{
	GstCaps *caps = gst_sample_get_caps(sample);
	GstBuffer *input_buffer = gst_sample_get_buffer(sample);
	GstVideoInfo input_info;
	GstVideoFrame input_frame;
	GstVideoFrame output_frame;
	guint64 generation;

	if (!caps || !input_buffer || !gst_video_info_from_caps(&input_info, caps))
		return;

	g_mutex_lock(&target->lock);
	if (target->closed || target->width <= 0 || target->height <= 0) {
		g_mutex_unlock(&target->lock);
		return;
	}
	generation = target->generation;
	if (!target_prepare_converter(target, &input_info, generation)) {
		g_mutex_unlock(&target->lock);
		return;
	}
	g_mutex_unlock(&target->lock);
	if (!target->back)
		target->back = gst_buffer_new_allocate(
			NULL, target->converter_output.size, NULL);
	if (!target->back)
		return;


	if (!gst_video_frame_map(&input_frame, &input_info, input_buffer,
				 GST_MAP_READ))
		return;
	if (!gst_video_frame_map(&output_frame, &target->converter_output,
				 target->back, GST_MAP_WRITE)) {
		gst_video_frame_unmap(&input_frame);
		return;
	}

	memset(GST_VIDEO_FRAME_PLANE_DATA(&output_frame, 0), 0,
	       (gsize)GST_VIDEO_FRAME_PLANE_STRIDE(&output_frame, 0) *
		       target->height);
	gst_video_converter_frame(target->converter, &input_frame, &output_frame);
	gst_video_frame_unmap(&output_frame);
	gst_video_frame_unmap(&input_frame);

	g_mutex_lock(&target->lock);
	if (!target->closed && target->generation == generation) {
		GstBuffer *old_front = target->front;
		target->front = target->back;
		target->back = old_front;
		target->front_width = target->width;
		target->front_height = target->height;
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

static VideoSession *session_new(const gchar *uri, int notify_fd, GError **error)
{
	VideoSession *session = g_new0(VideoSession, 1);
	g_atomic_ref_count_init(&session->refs);
	g_mutex_init(&session->lock);
	g_cond_init(&session->render_cond);
	session->notify_fd = notify_fd;
	session->state = GST_PLAY_STATE_STOPPED;
	session->position = GST_CLOCK_TIME_NONE;
	session->duration = GST_CLOCK_TIME_NONE;
	session->buffering = 100;
	session->targets = g_ptr_array_new_with_free_func((GDestroyNotify)target_unref);

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
	g_clear_pointer(&session->error, g_free);
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
				       VideoFit fit, gdouble zoom,
				       gdouble center_x, gdouble center_y)
{
	VideoTarget *target = g_new0(VideoTarget, 1);
	g_atomic_ref_count_init(&target->refs);
	g_mutex_init(&target->lock);
	target->session = session;
	session_ref(session);
	target->width = width;
	target->height = height;
	target->fit = fit;
	target->zoom = zoom;
	target->center_x = center_x;
	target->center_y = center_y;
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
	if (!uri)
		return env->intern(env, "nil");
	if (!gst_uri_is_valid(uri)) {
		g_free(uri);
		signal_error(env, "Video source must be an absolute URI");
		return env->intern(env, "nil");
	}
	int fd = env->open_channel(env, args[1]);
	if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
		g_free(uri);
		return env->intern(env, "nil");
	}
	int flags = fcntl(fd, F_GETFL, 0);
	if (flags >= 0)
		(void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);

	GError *error = NULL;
	VideoSession *session = session_new(uri, fd, &error);
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
	if (session)
		gst_play_play(session->play);
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
	if (session)
		gst_play_stop(session->play);
	return env->intern(env, "nil");
}

static emacs_value native_seek(emacs_env *env, ptrdiff_t nargs,
			       emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	double seconds = env->extract_float(env, args[1]);
	if (session && seconds >= 0.0)
		gst_play_seek(session->play, (GstClockTime)(seconds * GST_SECOND));
	return env->intern(env, "nil");
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
		case GST_PLAY_MESSAGE_POSITION_UPDATED:
			gst_play_message_parse_position_updated(message, &session->position);
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

static emacs_value native_poll(emacs_env *env, ptrdiff_t nargs,
			       emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	if (!session)
		return env->intern(env, "nil");
	session_poll_bus(session);

	const char *state_name = gst_play_state_get_name(session->state);
	emacs_value state_string = env->make_string(
		env, state_name, (ptrdiff_t)strlen(state_name));
	emacs_value state_symbol = env->intern(env, state_name);
	(void)state_string;
	emacs_value error = session->error
		? env->make_string(env, session->error,
				   (ptrdiff_t)strlen(session->error))
		: env->intern(env, "nil");
	emacs_value values[] = {
		env->intern(env, ":state"), state_symbol,
		env->intern(env, ":position"), clock_value(env, session->position),
		env->intern(env, ":duration"), clock_value(env, session->duration),
		env->intern(env, ":buffering"), env->make_integer(env, session->buffering),
		env->intern(env, ":width"), env->make_integer(env, session->video_width),
		env->intern(env, ":height"), env->make_integer(env, session->video_height),
		env->intern(env, ":eos"), session->eos ? env->intern(env, "t") : env->intern(env, "nil"),
		env->intern(env, ":error"), error,
	};
	return env->funcall(env, env->intern(env, "list"),
			    (ptrdiff_t)G_N_ELEMENTS(values), values);
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
	double zoom = env->extract_float(env, args[4]);
	double center_x = env->extract_float(env, args[5]);
	double center_y = env->extract_float(env, args[6]);
	if (!session || !fit_name)
		return env->intern(env, "nil");
	if (width <= 0 || height <= 0 || (gint64)width * height > 33554432) {
		g_free(fit_name);
		signal_error(env, "Invalid video target dimensions");
		return env->intern(env, "nil");
	}
	VideoTarget *target = target_new(session, width, height,
					 parse_fit_name(fit_name), zoom,
					 center_x, center_y);
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
	double zoom = env->extract_float(env, args[4]);
	double center_x = env->extract_float(env, args[5]);
	double center_y = env->extract_float(env, args[6]);
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
	target->zoom = MAX(0.01, zoom);
	target->center_x = CLAMP(center_x, 0.0, 1.0);
	target->center_y = CLAMP(center_y, 0.0, 1.0);
	target->generation++;
	target->converter_valid = FALSE;
	g_mutex_unlock(&target->lock);
	g_free(fit_name);
	session_request_render(target->session);
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
	    target->front_height != target->height || dest_x < 0 || dest_y < 0 ||
	    dest_x + target->width > canvas_width ||
	    dest_y + target->height > canvas_height) {
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
	const guint8 *source = GST_VIDEO_FRAME_PLANE_DATA(&frame, 0);
	gint stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
	for (gint y = 0; y < target->height; ++y) {
		memcpy(canvas + (gsize)(dest_y + y) * canvas_width + dest_x,
		       source + (gsize)y * stride,
		       (gsize)target->width * 4);
	}
	gst_video_frame_unmap(&frame);
	guint64 sequence = target->sequence;
	g_mutex_unlock(&target->lock);
	return env->make_integer(env, (intmax_t)sequence);
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

	bind_function(env, "video-native-create", native_create, 2, 2,
		      "Create a native video player for URI and PIPE-PROCESS.");
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

	emacs_value feature = env->intern(env, "video-module");
	env->funcall(env, env->intern(env, "provide"), 1, &feature);
	return env->non_local_exit_check(env) == emacs_funcall_exit_return ? 0 : 1;
}
