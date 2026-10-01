/* video-lottie.h --- Caller-owned Lottie frames for GStreamer
 *
 * Copyright (C) 2026 0WD0
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef VIDEO_LOTTIE_H
#define VIDEO_LOTTIE_H

#include "video-animation.h"

/* Local file URI; JSON and dotLottie ZIP contents are distinguished by magic.
 * Loading renders only the one-pixel metadata probe, not the complete clip. */
VideoAnimation *video_lottie_new(const gchar *uri, GError **error);

#endif
