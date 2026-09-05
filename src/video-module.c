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
#include "video-runtime.h"
#include "video-canvas.h"

#include <math.h>
#include <string.h>
#include <unistd.h>

int plugin_is_GPL_compatible;

static void session_finalizer(void *pointer)
{
	video_session_reap(pointer);
}

static void target_finalizer(void *pointer)
{
	video_target_reap(pointer);
}

static VideoFit parse_fit_name(const char *name)
{
	if (strcmp(name, "shrink") == 0)
		return VIDEO_FIT_SHRINK;
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

static void signal_error(emacs_env *env, const char *message)
{
	emacs_value text =
	        env->make_string(env, message, (ptrdiff_t)strlen(message));
	emacs_value data =
	        env->funcall(env, env->intern(env, "list"), 1, &text);
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

static GHashTable *copy_request_headers(emacs_env *env, emacs_value value)
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

	GHashTable *headers =
	        g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
	for (ptrdiff_t index = 0; index < size; index += 2) {
		char *name = copy_string(env, env->vec_get(env, value, index));
		char *header_value =
		        copy_string(env, env->vec_get(env, value, index + 1));
		if (!name || !header_value ||
		    env->non_local_exit_check(env) !=
		            emacs_funcall_exit_return) {
			g_free(name);
			g_free(header_value);
			g_hash_table_unref(headers);
			return NULL;
		}
		g_hash_table_replace(headers, name, header_value);
	}
	return headers;
}

static VideoSession *get_session(emacs_env *env, emacs_value value)
{
	VideoSession *session = env->get_user_ptr(env, value);
	if (!session &&
	    env->non_local_exit_check(env) == emacs_funcall_exit_return)
		signal_error(env, "Closed video player");
	return session;
}

static VideoTarget *get_target(emacs_env *env, emacs_value value)
{
	VideoTarget *target = env->get_user_ptr(env, value);
	if (!target &&
	    env->non_local_exit_check(env) == emacs_funcall_exit_return)
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
	GHashTable *request_headers = NULL;
	if (!uri)
		return env->intern(env, "nil");
	if (env->is_not_nil(env, args[3])) {
		cache_template = copy_string(env, args[3]);
		if (!cache_template) {
			g_free(uri);
			return env->intern(env, "nil");
		}
	}
	if (env->is_not_nil(env, args[4])) {
		request_headers = copy_request_headers(env, args[4]);
		if (env->non_local_exit_check(env) !=
		    emacs_funcall_exit_return) {
			g_free(cache_template);
			g_free(uri);
			return env->intern(env, "nil");
		}
	}
	int fd = env->open_channel(env, args[1]);
	if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
		g_clear_pointer(&request_headers, g_hash_table_unref);
		g_free(cache_template);
		g_free(uri);
		return env->intern(env, "nil");
	}
	intmax_t cache_size = env->extract_integer(env, args[2]);
	if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
		g_clear_pointer(&request_headers, g_hash_table_unref);
		g_free(cache_template);
		g_free(uri);
		close(fd);
		return env->intern(env, "nil");
	}
	if (cache_size < 0) {
		g_clear_pointer(&request_headers, g_hash_table_unref);
		g_free(cache_template);
		g_free(uri);
		close(fd);
		signal_error(env,
		             "Video network cache size must be non-negative");
		return env->intern(env, "nil");
	}

	GError *error = NULL;
	VideoSession *session =
	        video_session_new(uri, fd, (guint64)cache_size, cache_template,
	                          request_headers, &error);
	g_free(cache_template);
	g_free(uri);
	if (!session) {
		signal_error(env, error ? error->message
		                        : "Could not create video player");
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
	video_session_close(session);
	return env->intern(env, "t");
}

static emacs_value native_play(emacs_env *env, ptrdiff_t nargs,
                               emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	if (session)
		video_session_play(session);
	return env->intern(env, "nil");
}

static emacs_value native_pause(emacs_env *env, ptrdiff_t nargs,
                                emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	if (session)
		video_session_pause(session);
	return env->intern(env, "nil");
}

static emacs_value native_stop(emacs_env *env, ptrdiff_t nargs,
                               emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	if (session)
		video_session_stop(session);
	return env->intern(env, "nil");
}

static emacs_value native_seek(emacs_env *env, ptrdiff_t nargs,
                               emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	double seconds = env->extract_float(env, args[1]);
	if (session)
		video_session_seek(session, seconds);
	return env->intern(env, "nil");
}

static emacs_value native_buffered_ranges(emacs_env *env, ptrdiff_t nargs,
                                          emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	if (!session)
		return env->intern(env, "nil");

	GArray *ranges = video_session_buffered_ranges(session);

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
		emacs_value cells[] = {pair, result};
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
		video_session_set_volume(session, volume);
	return env->intern(env, "nil");
}

static emacs_value native_set_muted(emacs_env *env, ptrdiff_t nargs,
                                    emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	if (session)
		video_session_set_muted(
		        session,
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
	if (session)
		video_session_set_rate(session, rate);
	return env->intern(env, "nil");
}

static emacs_value clock_value(emacs_env *env, gdouble value)
{
	if (isnan(value))
		return env->intern(env, "nil");
	return env->make_float(env, value);
}

static emacs_value native_poll(emacs_env *env, ptrdiff_t nargs,
                               emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;
	VideoSession *session = get_session(env, args[0]);
	if (!session)
		return env->intern(env, "nil");
	VideoSessionStatus status;
	video_session_poll(session, &status);
	emacs_value state_symbol = env->intern(env, status.state);
	emacs_value error =
	        status.error ? env->make_string(env, status.error,
	                                        (ptrdiff_t)strlen(status.error))
	                     : env->intern(env, "nil");
	emacs_value cache =
	        status.cache_location
	                ? env->make_string(
	                          env, status.cache_location,
	                          (ptrdiff_t)strlen(status.cache_location))
	                : env->intern(env, "nil");
	emacs_value values[] = {
	        env->intern(env, ":state"),
	        state_symbol,
	        env->intern(env, ":position"),
	        clock_value(env, status.position),
	        env->intern(env, ":duration"),
	        clock_value(env, status.duration),
	        env->intern(env, ":seekable"),
	        status.seekable ? env->intern(env, "t")
	                        : env->intern(env, "nil"),
	        env->intern(env, ":live"),
	        status.live ? env->intern(env, "t") : env->intern(env, "nil"),
	        env->intern(env, ":buffering"),
	        env->make_integer(env, status.buffering),
	        env->intern(env, ":width"),
	        env->make_integer(env, status.width),
	        env->intern(env, ":height"),
	        env->make_integer(env, status.height),
	        env->intern(env, ":eos"),
	        status.eos ? env->intern(env, "t") : env->intern(env, "nil"),
	        env->intern(env, ":cache-location"),
	        cache,
	        env->intern(env, ":error"),
	        error,
	};
	emacs_value result =
	        env->funcall(env, env->intern(env, "list"),
	                     (ptrdiff_t)G_N_ELEMENTS(values), values);
	video_session_status_clear(&status);
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
	if (!session || !fit_name ||
	    env->non_local_exit_check(env) != emacs_funcall_exit_return) {
		g_free(fit_name);
		return env->intern(env, "nil");
	}
	if (width <= 0 || height <= 0 || (gint64)width * height > 33554432) {
		g_free(fit_name);
		signal_error(env, "Invalid video target dimensions");
		return env->intern(env, "nil");
	}
	VideoViewConfig view = {
	        .width = width,
	        .height = height,
	        .fit = parse_fit_name(fit_name),
	        .scale = scale,
	        .viewport_x = viewport_x,
	        .viewport_y = viewport_y,
	};
	VideoTarget *target = video_target_new(session, &view);
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
	video_target_close(target);
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
	if (!target || !fit_name ||
	    env->non_local_exit_check(env) != emacs_funcall_exit_return) {
		g_free(fit_name);
		return env->intern(env, "nil");
	}
	if (width <= 0 || height <= 0 || (gint64)width * height > 33554432) {
		g_free(fit_name);
		signal_error(env, "Invalid video target dimensions");
		return env->intern(env, "nil");
	}
	VideoViewConfig view = {
	        .width = width,
	        .height = height,
	        .fit = parse_fit_name(fit_name),
	        .scale = scale,
	        .viewport_x = viewport_x,
	        .viewport_y = viewport_y,
	};
	video_target_set_view(target, &view);
	g_free(fit_name);
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

static emacs_value native_canvas_draw_controls(emacs_env *env, ptrdiff_t nargs,
                                               emacs_value *args, void *data)
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
		        env,
		        env->vec_get(env, args[16], (ptrdiff_t)(index * 2)));
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
	if (canvas_width <= 0 || canvas_height <= 0 || target.width <= 0 ||
	    target.height <= 0 || (state.opacity <= 0.0 && !state.waiting))
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

	uint32_t *canvas = env->canvas_data(env, args[1]);
	if (!canvas ||
	    env->non_local_exit_check(env) != emacs_funcall_exit_return)
		return env->intern(env, "nil");
	guint64 sequence;
	gboolean copied =
	        video_target_copy(target, canvas, canvas_width, canvas_height,
	                          dest_x, dest_y, &sequence);
	return copied ? env->make_integer(env, (intmax_t)sequence)
	              : env->intern(env, "nil");
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
	gboolean copied = FALSE;
	if (!uri || !fit_name ||
	    env->non_local_exit_check(env) != emacs_funcall_exit_return)
		goto done;
	if (canvas_width <= 0 || canvas_height <= 0 || width <= 0 ||
	    height <= 0 || (gint64)canvas_width * canvas_height > 33554432)
		goto done;
	uint32_t *canvas = env->canvas_data(env, args[0]);
	if (!canvas ||
	    env->non_local_exit_check(env) != emacs_funcall_exit_return)
		goto done;
	VideoViewConfig view = {
	        .width = width,
	        .height = height,
	        .fit = parse_fit_name(fit_name),
	};
	copied = video_runtime_draw_uri(uri, &view, canvas, canvas_width,
	                                canvas_height, dest_x, dest_y);
done:
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
	emacs_value arguments[] = {symbol, lambda};
	env->funcall(env, env->intern(env, "defalias"), 2, arguments);
}

int emacs_module_init(struct emacs_runtime *runtime)
{
	emacs_env *env = runtime->get_environment(runtime);
	GError *error = NULL;
	if (!video_runtime_init(&error)) {
		if (error)
			g_error_free(error);
		return 1;
	}

	bind_function(env, "video-native-create", native_create, 5, 5,
	              "Create a native video player for URI, PIPE-PROCESS, "
	              "CACHE-SIZE, CACHE-TEMPLATE, and REQUEST-HEADERS.");
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
	bind_function(env, "video-native-buffered-ranges",
	              native_buffered_ranges, 1, 1,
	              "Return buffered native video PLAYER time ranges.");
	bind_function(env, "video-native-set-volume", native_set_volume, 2, 2,
	              "Set native video PLAYER volume.");
	bind_function(env, "video-native-set-muted", native_set_muted, 2, 2,
	              "Set native video PLAYER mute state.");
	bind_function(env, "video-native-set-rate", native_set_rate, 2, 2,
	              "Set native video PLAYER rate.");
	bind_function(env, "video-native-poll", native_poll, 1, 1,
	              "Return current native video PLAYER state.");
	bind_function(env, "video-native-target-create", native_target_create,
	              7, 7, "Create a render target for native video PLAYER.");
	bind_function(env, "video-native-target-close", native_target_close, 1,
	              1, "Close native render TARGET.");
	bind_function(env, "video-native-target-set-view",
	              native_target_set_view, 7, 7,
	              "Set native TARGET viewport geometry.");
	bind_function(env, "video-native-target-copy", native_target_copy, 6, 6,
	              "Copy current-view TARGET pixels into CANVAS at a "
	              "destination.\n"
	              "Return the frame sequence, or nil without changing "
	              "CANVAS when no current frame is available.");
	bind_function(env, "video-native-canvas-draw-uri",
	              native_canvas_draw_uri, 9, 9,
	              "Draw one decoded URI into a Canvas rectangle.");
	bind_function(
	        env, "video-native-control-layout", native_control_layout, 4, 4,
	        "Return transport control rectangles for a video region.");
	bind_function(env, "video-native-canvas-draw-controls",
	              native_canvas_draw_controls, 17, 17,
	              "Draw transport, buffered ranges, and waiting state into "
	              "a Canvas video rectangle.");

	emacs_value feature = env->intern(env, "video-module");
	env->funcall(env, env->intern(env, "provide"), 1, &feature);
	return env->non_local_exit_check(env) == emacs_funcall_exit_return ? 0
	                                                                   : 1;
}
