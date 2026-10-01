/* video-webp.h --- Native WebP frames for the existing GStreamer source
 *
 * Copyright (C) 2026 0WD0
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef VIDEO_WEBP_H
#define VIDEO_WEBP_H

#include "video-animation.h"

/* Local file URI only.  Compressed input stays mapped; composited frames are
 * copied once into a bounded, reusable pool independent of decoder lifetime. */
VideoAnimation *video_webp_new(const gchar *uri, GError **error);

#endif
