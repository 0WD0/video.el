/* video-lottie.h --- Caller-owned Lottie frames for GStreamer
 *
 * Copyright (C) 2026 0WD0
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef VIDEO_LOTTIE_H
#define VIDEO_LOTTIE_H

#include <gst/gst.h>

typedef struct VideoLottie VideoLottie;

typedef struct {
	guint width;
	guint height;
	guint frames;
	GstClockTime duration;
	/* Repetitions after the first pass: -1 once, 0 forever, positive finite. */
	gint64 loop_count;
} VideoLottieMetadata;

/* Local file URI; JSON and dotLottie ZIP contents are distinguished by magic.
 * Loading renders only the one-pixel metadata probe, not the complete clip. */
VideoLottie *video_lottie_new(const gchar *uri, GError **error);
VideoLottie *video_lottie_ref(VideoLottie *lottie);
void video_lottie_unref(VideoLottie *lottie);
const VideoLottieMetadata *video_lottie_get_metadata(VideoLottie *lottie);
/* Configure each appsrc created by playbin's source-setup signal.  The appsrc
 * callbacks retain their own reference; no source reference is retained here. */
gboolean video_lottie_configure_source(VideoLottie *lottie, GstElement *source,
                                        GError **error);
/* Unblock a pool acquisition before joining/disposal of the pipeline. */
void video_lottie_flush(VideoLottie *lottie);
/* Synchronous metadata and immutable first-frame sample, independent of a
 * player.  Samples contain native-endian premultiplied ARGB32 pixels. */
gboolean video_lottie_read_metadata(const gchar *uri,
                                     VideoLottieMetadata *metadata,
                                     GError **error);
GstSample *video_lottie_first_frame(const gchar *uri, GError **error);

#endif
