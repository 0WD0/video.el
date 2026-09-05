/* video-runtime.h --- Native playback and frame ownership for video.el
 *
 * Copyright (C) 2026 0WD0
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef VIDEO_RUNTIME_H
#define VIDEO_RUNTIME_H

#include <glib.h>
#include <stdint.h>

typedef struct VideoSession VideoSession;
typedef struct VideoTarget VideoTarget;

typedef enum {
	VIDEO_FIT_CONTAIN,
	VIDEO_FIT_SHRINK,
	VIDEO_FIT_COVER,
	VIDEO_FIT_WIDTH,
	VIDEO_FIT_HEIGHT,
	VIDEO_FIT_ACTUAL
} VideoFit;

typedef struct {
	gint width;
	gint height;
	VideoFit fit;
	gdouble scale;
	gdouble viewport_x;
	gdouble viewport_y;
} VideoViewConfig;

typedef struct {
	gdouble start;
	gdouble end;
} VideoBufferedRange;

typedef struct {
	/* State is static; error is borrowed until the next session operation.
	 * Cache location is consumed from the session; clear after use. */
	const gchar *state;
	const gchar *error;
	gchar *cache_location;
	/* Unknown timestamps are NAN; known timestamps are seconds. */
	gdouble position;
	gdouble duration;
	gboolean seekable;
	gboolean live;
	guint buffering;
	guint width;
	guint height;
	gboolean eos;
} VideoSessionStatus;

gboolean video_runtime_init(GError **error);

/* Control/query operations run on the caller's single control thread.
 * URI and cache template are borrowed for this call.  Construction consumes
 * notify_fd and request_headers (alternating non-null name/value strings
 * terminated by NULL), even on failure.
 * A successful result owns one caller reference. */
VideoSession *video_session_new(const gchar *uri, int notify_fd,
                                guint64 network_cache_size,
                                const gchar *cache_template,
                                GStrv request_headers, GError **error);
/* Both consume the caller reference: close synchronously, reap asynchronously. */
void video_session_close(VideoSession *session);
void video_session_reap(VideoSession *session);
void video_session_play(VideoSession *session);
void video_session_pause(VideoSession *session);
void video_session_stop(VideoSession *session);
void video_session_seek(VideoSession *session, gdouble seconds);
void video_session_set_volume(VideoSession *session, gdouble volume);
void video_session_set_muted(VideoSession *session, gboolean muted);
void video_session_set_rate(VideoSession *session, gdouble rate);
void video_session_poll(VideoSession *session, VideoSessionStatus *status);
void video_session_status_clear(VideoSessionStatus *status);
/* Returns an owned array of VideoBufferedRange; release with g_array_unref. */
GArray *video_session_buffered_ranges(VideoSession *session);

VideoTarget *video_target_new(VideoSession *session,
                              const VideoViewConfig *view);
void video_target_close(VideoTarget *target);
void video_target_reap(VideoTarget *target);
void video_target_set_view(VideoTarget *target, const VideoViewConfig *view);
/* Pixels are borrowed only for the call.  A failed copy leaves them untouched;
 * a successful copy returns the published frame sequence through sequence. */
gboolean video_target_copy(VideoTarget *target, uint32_t *pixels, gint width,
                           gint height, gint x, gint y, guint64 *sequence);
gboolean video_runtime_draw_uri(const gchar *uri, const VideoViewConfig *view,
                                uint32_t *pixels, gint width, gint height,
                                gint x, gint y);

#endif
