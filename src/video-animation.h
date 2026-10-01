/* video-animation.h --- Shared native animation ingestion for GStreamer
 *
 * Copyright (C) 2026 0WD0
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef VIDEO_ANIMATION_H
#define VIDEO_ANIMATION_H

#include <gst/video/video.h>

typedef enum {
	VIDEO_SOURCE_MEDIA,
	VIDEO_SOURCE_LOTTIE,
	VIDEO_SOURCE_APNG
} VideoSourceFormat;

typedef struct {
	guint width;
	guint height;
	guint frames;
	GstClockTime duration;
	/* Repetitions after the first pass: -1 once, 0 forever, positive finite. */
	gint64 loop_count;
} VideoAnimationMetadata;

typedef struct VideoAnimation VideoAnimation;

typedef struct {
	const gchar *name;
	gboolean block;
	/* Called with the common lock held.  NULL without an error is EOS or
	 * cancellation; a returned buffer transfers ownership to the caller. */
	GstBuffer *(*next_frame)(VideoAnimation *, GError **);
	/* Accepts [0, duration], with exact duration positioning at EOS. */
	gboolean (*seek)(VideoAnimation *, GstClockTime, GError **);
	/* Optional, called without the lock after setting atomic flushing. */
	void (*flush)(VideoAnimation *);
	/* Backend resources only; unref frees the common state and allocation. */
	void (*destroy)(VideoAnimation *);
} VideoAnimationOps;

/* First member of each zero-initialized concrete decoder allocation. */
struct VideoAnimation {
	gatomicrefcount refs;
	GMutex lock;
	const VideoAnimationOps *ops;
	VideoAnimationMetadata metadata;
	GstVideoInfo info;
	GstCaps *caps;
	gint flushing;
	gboolean failed;
};

void video_animation_init(VideoAnimation *animation,
                          const VideoAnimationOps *ops);
VideoAnimation *video_animation_new(VideoSourceFormat format,
                                    const gchar *uri, GError **error);
VideoAnimation *video_animation_ref(VideoAnimation *animation);
void video_animation_unref(VideoAnimation *animation);
/* Each appsrc retains an independent callback reference, not vice versa. */
gboolean video_animation_configure_source(VideoAnimation *animation,
                                           GstElement *source, GError **error);
/* Cancel before joining/disposal; can unblock a decoder waiting for pixels. */
void video_animation_flush(VideoAnimation *animation);
/* The immutable sample retains its pixels independently of the decoder. */
GstSample *video_animation_first_frame(VideoSourceFormat format,
                                       const gchar *uri, GError **error);

#endif
