/* video-apng.h --- Native APNG frames for the existing GStreamer source
 *
 * Copyright (C) 2026 0WD0
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef VIDEO_APNG_H
#define VIDEO_APNG_H

#include "video-animation.h"

/* Local file URI only.  Packet scanning retains no animation-sized index;
 * playback retains the decoder's composition state and one pending frame. */
VideoAnimation *video_apng_new(const gchar *uri, GError **error);

#endif
