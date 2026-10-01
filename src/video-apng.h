/* video-apng.h --- Native APNG frames for the existing GStreamer source
 *
 * Copyright (C) 2026 0WD0
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef VIDEO_APNG_H
#define VIDEO_APNG_H

#include <gst/gst.h>

typedef struct VideoApng VideoApng;

typedef struct {
	guint width;
	guint height;
	guint frames;
	GstClockTime duration;
	/* Repetitions after the first pass: -1 once, 0 forever, positive finite. */
	gint64 loop_count;
} VideoApngMetadata;

/* Local file URI only.  Packet scanning retains no animation-sized index;
 * playback retains the decoder's composition state and one pending frame. */
VideoApng *video_apng_new(const gchar *uri, GError **error);
VideoApng *video_apng_ref(VideoApng *apng);
void video_apng_unref(VideoApng *apng);
const VideoApngMetadata *video_apng_get_metadata(VideoApng *apng);
/* The appsrc callbacks own a reference independently of the session.  Output
 * is seekable time-format raw video, with straight alpha and one pass to EOS. */
gboolean video_apng_configure_source(VideoApng *apng, GstElement *source,
                                     GError **error);
/* Cancel work without acquiring the decoder lock or waiting for callbacks. */
void video_apng_flush(VideoApng *apng);
/* Immutable standalone sample; GstVideoMeta describes the actual row stride. */
GstSample *video_apng_first_frame(const gchar *uri, GError **error);

#endif
