/* video-canvas.c --- Pure BGRA Canvas composition for video.el  -*- c-file-style: "linux" -*-
 *
 * Copyright (C) 2026 0WD0
 *
 * This file is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version.
 */

#include "video-canvas.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

static int clamp_int(int value, int minimum, int maximum)
{
	if (value < minimum)
		return minimum;
	if (value > maximum)
		return maximum;
	return value;
}

static double clamp_double(double value, double minimum, double maximum)
{
	if (value < minimum)
		return minimum;
	if (value > maximum)
		return maximum;
	return value;
}

/* Widen the endpoints before addition so offscreen coordinates cannot wrap. */
static bool clip_rect(int canvas_width, int canvas_height,
                      VideoCanvasRect rectangle, VideoCanvasRect *clipped)
{
	if (canvas_width <= 0 || canvas_height <= 0 ||
	    rectangle.width <= 0 || rectangle.height <= 0)
		return false;
	int64_t right = (int64_t)rectangle.x + rectangle.width;
	int64_t bottom = (int64_t)rectangle.y + rectangle.height;
	int left = rectangle.x > 0 ? rectangle.x : 0;
	int top = rectangle.y > 0 ? rectangle.y : 0;
	if (right > canvas_width)
		right = canvas_width;
	if (bottom > canvas_height)
		bottom = canvas_height;
	if (right <= left || bottom <= top)
		return false;
	*clipped = (VideoCanvasRect){left, top, (int)(right - left),
	                           (int)(bottom - top)};
	return true;
}

bool video_canvas_fill(uint32_t *canvas, int canvas_width, int canvas_height,
                       VideoCanvasRect rectangle, uint32_t background)
{
	VideoCanvasRect clipped;
	if (!canvas || !clip_rect(canvas_width, canvas_height, rectangle, &clipped))
		return false;
	uint32_t color = 0xff000000u | background;
	for (int y = 0; y < clipped.height; ++y) {
		uint32_t *row = canvas + (size_t)(clipped.y + y) * canvas_width +
		               clipped.x;
		for (int x = 0; x < clipped.width; ++x)
			row[x] = color;
	}
	return true;
}

bool video_canvas_blit_bgra(uint32_t *canvas, int canvas_width,
                            int canvas_height, const uint8_t *source,
                            int source_width, int source_height,
                            int source_stride, int destination_x,
                            int destination_y, uint32_t background)
{
	VideoCanvasRect clipped;
	VideoCanvasRect rectangle = {destination_x, destination_y,
	                             source_width, source_height};
	if (!canvas || !source ||
	    !clip_rect(canvas_width, canvas_height, rectangle, &clipped))
		return false;
	int source_x = clipped.x - destination_x;
	int source_y = clipped.y - destination_y;
	unsigned red = (background >> 16) & 255;
	unsigned green = (background >> 8) & 255;
	unsigned blue = background & 255;
	for (int y = 0; y < clipped.height; ++y) {
		uint32_t *out = canvas + (size_t)(clipped.y + y) * canvas_width +
		               clipped.x;
		const uint8_t *in = source + (size_t)(source_y + y) * source_stride +
		                    (size_t)source_x * 4;
		for (int x = 0; x < clipped.width; ++x) {
			uint32_t pixel;
			memcpy(&pixel, in + (size_t)x * 4, sizeof pixel);
			unsigned inverse = 255 - (pixel >> 24);
			if (!inverse) {
				out[x] = pixel;
				continue;
			}
			/* Never blend against old canvas content: transparent new
			 * frames must erase it, not accumulate previous colors. */
			out[x] = 0xff000000u |
			         ((((pixel >> 16) & 255) +
			           (red * inverse + 127) / 255) << 16) |
			         ((((pixel >> 8) & 255) +
			           (green * inverse + 127) / 255) << 8) |
			         ((pixel & 255) + (blue * inverse + 127) / 255);
		}
	}
	return true;
}

VideoCanvasTransportLayout video_canvas_transport_layout(VideoCanvasRect target)
{
	int shortest =
	        target.width < target.height ? target.width : target.height;
	int radius = clamp_int(shortest / 10, 12, 32);
	int control_height = clamp_int(target.height / 8, 20, 36);
	int mute_width = clamp_int(target.width / 8, 28, 40);
	int volume_available_height = target.height - control_height;
	int volume_height = volume_available_height >= 32
	                            ? clamp_int(target.height * 2 / 5, 32, 120)
	                            : 0;
	if (volume_height > volume_available_height)
		volume_height = volume_available_height;
	int volume_width = volume_height > 0
	                           ? clamp_int(target.width / 10, 24, 36)
	                           : 0;
	VideoCanvasTransportLayout layout = {
	        .target = target,
	        .toggle =
	                {
	                        .x = target.x + target.width / 2 - radius,
	                        .y = target.y + target.height / 2 - radius,
	                        .width = radius * 2,
	                        .height = radius * 2,
	                },
	        .mute =
	                {
	                        .x = target.x,
	                        .y = target.y + target.height - control_height,
	                        .width = mute_width,
	                        .height = control_height,
	                },
	        .seek =
	                {
	                        .x = target.x + mute_width,
	                        .y = target.y + target.height - control_height,
	                        .width = target.width - mute_width - 10,
	                        .height = control_height,
	                },
	        .volume =
	                {
	                        .x = target.x + target.width - volume_width,
	                        .y = target.y +
	                             (volume_available_height - volume_height) / 2,
	                        .width = volume_width,
	                        .height = volume_height,
	                },
	        .toggle_radius = radius,
	        .progress_y = target.y + target.height - control_height / 2,
	};
	return layout;
}

static void blend_pixel(uint32_t *canvas, int canvas_width, int canvas_height,
                        int x, int y, uint8_t red, uint8_t green, uint8_t blue,
                        uint8_t alpha)
{
	if (x < 0 || y < 0 || x >= canvas_width || y >= canvas_height || !alpha)
		return;
	uint32_t *pixel = canvas + (size_t)y * canvas_width + x;
	uint8_t old_blue = *pixel & 0xff;
	uint8_t old_green = (*pixel >> 8) & 0xff;
	uint8_t old_red = (*pixel >> 16) & 0xff;
	uint8_t old_alpha = *pixel >> 24;
	unsigned inverse = 255 - alpha;
	uint8_t out_blue = (blue * alpha + old_blue * inverse + 127) / 255;
	uint8_t out_green = (green * alpha + old_green * inverse + 127) / 255;
	uint8_t out_red = (red * alpha + old_red * inverse + 127) / 255;
	uint8_t out_alpha = alpha + (old_alpha * inverse + 127) / 255;
	*pixel = ((uint32_t)out_alpha << 24) | ((uint32_t)out_red << 16) |
	         ((uint32_t)out_green << 8) | out_blue;
}

void video_canvas_round_corners(uint32_t *canvas, int canvas_width,
                                 int canvas_height, VideoCanvasRect rectangle,
                                 double radius, uint32_t background)
{
	VideoCanvasRect clipped;
	if (!(radius > 0.0) || !canvas ||
	    !clip_rect(canvas_width, canvas_height, rectangle, &clipped))
		return;
	radius = fmin(radius, fmin(rectangle.width, rectangle.height) / 2.0);
	int extent = (int)ceil(radius);
	int left = clipped.x - rectangle.x;
	int right = left + clipped.width;
	uint8_t red = (background >> 16) & 255;
	uint8_t green = (background >> 8) & 255;
	uint8_t blue = background & 255;
	for (int y = 0; y < clipped.height; ++y) {
		double local_y = clipped.y - rectangle.y + y + 0.5;
		double dy = radius - fmin(local_y, rectangle.height - local_y);
		if (dy <= 0.0)
			continue;
		/* Visit only the two corner strips.  Odd-width viewports can
		 * share a center column; assign it to the left strip once. */
		for (int side = 0; side < 2; ++side) {
			int start = side ? rectangle.width - extent : 0;
			int end = side ? rectangle.width : extent;
			if (side && start < extent)
				start = extent;
			start = start > left ? start : left;
			end = end < right ? end : right;
			for (int x = start; x < end; ++x) {
				double local_x = x + 0.5;
				double dx = radius -
				        fmin(local_x, rectangle.width - local_x);
				if (dx <= 0.0)
					continue;
				double coverage = clamp_double(
				        radius + 0.5 - hypot(dx, dy), 0.0, 1.0);
				uint8_t alpha = (uint8_t)lround((1.0 - coverage) * 255);
				blend_pixel(canvas, canvas_width, canvas_height,
				            clipped.x + (x - left), clipped.y + y,
				            red, green, blue, alpha);
			}
		}
	}
}

static void fill_rect(uint32_t *canvas, int canvas_width, int canvas_height,
                      VideoCanvasRect rectangle, uint8_t red, uint8_t green,
                      uint8_t blue, uint8_t alpha)
{
	int left = rectangle.x > 0 ? rectangle.x : 0;
	int top = rectangle.y > 0 ? rectangle.y : 0;
	int right = rectangle.x + rectangle.width;
	int bottom = rectangle.y + rectangle.height;
	if (right > canvas_width)
		right = canvas_width;
	if (bottom > canvas_height)
		bottom = canvas_height;
	for (int y = top; y < bottom; ++y)
		for (int x = left; x < right; ++x)
			blend_pixel(canvas, canvas_width, canvas_height, x, y,
			            red, green, blue, alpha);
}

static void fill_circle(uint32_t *canvas, int canvas_width, int canvas_height,
                        int center_x, int center_y, int radius, uint8_t red,
                        uint8_t green, uint8_t blue, uint8_t alpha)
{
	int radius_squared = radius * radius;
	for (int y = -radius; y <= radius; ++y)
		for (int x = -radius; x <= radius; ++x)
			if (x * x + y * y <= radius_squared)
				blend_pixel(canvas, canvas_width, canvas_height,
				            center_x + x, center_y + y, red,
				            green, blue, alpha);
}

static void draw_line(uint32_t *canvas, int canvas_width, int canvas_height,
                      int x0, int y0, int x1, int y1, int thickness,
                      uint8_t red, uint8_t green, uint8_t blue, uint8_t alpha)
{
	int dx = abs(x1 - x0);
	int sx = x0 < x1 ? 1 : -1;
	int dy = -abs(y1 - y0);
	int sy = y0 < y1 ? 1 : -1;
	int error = dx + dy;
	for (;;) {
		VideoCanvasRect point = {
		        .x = x0 - thickness / 2,
		        .y = y0 - thickness / 2,
		        .width = thickness,
		        .height = thickness,
		};
		fill_rect(canvas, canvas_width, canvas_height, point, red,
		          green, blue, alpha);
		if (x0 == x1 && y0 == y1)
			break;
		int doubled = 2 * error;
		if (doubled >= dy) {
			error += dy;
			x0 += sx;
		}
		if (doubled <= dx) {
			error += dx;
			y0 += sy;
		}
	}
}

static void draw_toggle(uint32_t *canvas, int canvas_width, int canvas_height,
                        const VideoCanvasTransportLayout *layout,
                        const VideoCanvasTransportState *state,
                        uint8_t panel_alpha, uint8_t icon_alpha)
{
	int radius = layout->toggle_radius;
	int center_x = layout->toggle.x + layout->toggle.width / 2;
	int center_y = layout->toggle.y + layout->toggle.height / 2;
	fill_circle(canvas, canvas_width, canvas_height, center_x, center_y,
	            radius, 0, 0, 0, panel_alpha);
	if (state->playing) {
		int bar_width = radius / 5 > 3 ? radius / 5 : 3;
		VideoCanvasRect left = {
		        .x = center_x - radius / 3,
		        .y = center_y - radius / 2,
		        .width = bar_width,
		        .height = radius,
		};
		VideoCanvasRect right = left;
		right.x = center_x + radius / 3 - bar_width;
		fill_rect(canvas, canvas_width, canvas_height, left, 255, 255,
		          255, icon_alpha);
		fill_rect(canvas, canvas_width, canvas_height, right, 255, 255,
		          255, icon_alpha);
		return;
	}

	int left = center_x - radius / 4;
	int half_height = radius / 2;
	for (int row = -half_height; row <= half_height; ++row) {
		int span = (half_height - abs(row)) * radius /
		           (half_height * 2 > 0 ? half_height * 2 : 1);
		VideoCanvasRect segment = {
		        .x = left,
		        .y = center_y + row,
		        .width = span > 0 ? span : 1,
		        .height = 1,
		};
		fill_rect(canvas, canvas_width, canvas_height, segment, 255,
		          255, 255, icon_alpha);
	}
}

static void draw_bottom_bar(uint32_t *canvas, int canvas_width,
                            int canvas_height,
                            const VideoCanvasTransportLayout *layout,
                            const VideoCanvasTransportState *state,
                            uint8_t panel_alpha, uint8_t icon_alpha)
{
	VideoCanvasRect bar = {
	        .x = layout->target.x,
	        .y = layout->mute.y,
	        .width = layout->target.width,
	        .height = layout->mute.height,
	};
	fill_rect(canvas, canvas_width, canvas_height, bar, 0, 0, 0,
	          panel_alpha);

	int center_x = layout->mute.x + layout->mute.width / 2;
	int center_y = layout->mute.y + layout->mute.height / 2;
	int icon_size =
	        layout->mute.height / 3 > 8 ? layout->mute.height / 3 : 8;
	VideoCanvasRect speaker = {
	        .x = center_x - icon_size / 2,
	        .y = center_y - icon_size / 4,
	        .width = icon_size / 3,
	        .height = icon_size / 2,
	};
	fill_rect(canvas, canvas_width, canvas_height, speaker, 255, 255, 255,
	          icon_alpha);
	draw_line(canvas, canvas_width, canvas_height, center_x - icon_size / 6,
	          center_y, center_x + icon_size / 3, center_y - icon_size / 3,
	          2, 255, 255, 255, icon_alpha);
	draw_line(canvas, canvas_width, canvas_height, center_x - icon_size / 6,
	          center_y, center_x + icon_size / 3, center_y + icon_size / 3,
	          2, 255, 255, 255, icon_alpha);
	if (state->muted)
		draw_line(canvas, canvas_width, canvas_height,
		          center_x - icon_size / 2, center_y - icon_size / 2,
		          center_x + icon_size / 2, center_y + icon_size / 2, 3,
		          255, 96, 96, icon_alpha);
	if (!state->seekable)
		return;

	int progress_x = layout->seek.x;
	int progress_width = layout->seek.width > 0 ? layout->seek.width : 1;
	VideoCanvasRect track = {
	        .x = progress_x,
	        .y = layout->progress_y - 2,
	        .width = progress_width,
	        .height = 4,
	};
	fill_rect(canvas, canvas_width, canvas_height, track, 112, 112, 112,
	          icon_alpha);
	for (size_t index = 0; index < state->buffered_range_count; ++index) {
		double start = clamp_double(state->buffered_ranges[index].start,
		                            0.0, 1.0);
		double end = clamp_double(state->buffered_ranges[index].end,
		                          start, 1.0);
		VideoCanvasRect buffered = track;
		buffered.x += (int)round(progress_width * start);
		buffered.width = (int)round(progress_width * end) -
		                 (buffered.x - track.x);
		fill_rect(canvas, canvas_width, canvas_height, buffered, 190,
		          190, 190, icon_alpha);
	}
	int played_width = (int)round(progress_width *
	                              clamp_double(state->progress, 0.0, 1.0));
	VideoCanvasRect played = track;
	played.width = played_width;
	fill_rect(canvas, canvas_width, canvas_height, played, 255, 255, 255,
	          icon_alpha);
	fill_circle(canvas, canvas_width, canvas_height,
	            progress_x + played_width, layout->progress_y, 4, 255, 255,
	            255, icon_alpha);
}

static void draw_volume_control(uint32_t *canvas, int canvas_width,
                                int canvas_height,
                                const VideoCanvasTransportLayout *layout,
                                const VideoCanvasTransportState *state,
                                uint8_t panel_alpha, uint8_t icon_alpha)
{
	if (layout->volume.width <= 0 || layout->volume.height <= 0)
		return;

	fill_rect(canvas, canvas_width, canvas_height, layout->volume, 0, 0, 0,
	          panel_alpha / 2);
	int center_x = layout->volume.x + layout->volume.width / 2;
	int track_top = layout->volume.y + 6;
	int track_height = layout->volume.height - 12;
	if (track_height < 1)
		track_height = 1;
	VideoCanvasRect track = {
	        .x = center_x - 2,
	        .y = track_top,
	        .width = 4,
	        .height = track_height,
	};
	fill_rect(canvas, canvas_width, canvas_height, track, 112, 112, 112,
	          icon_alpha);

	double volume = clamp_double(state->volume, 0.0, 1.0);
	int thumb_y = track_top + (int)round((1.0 - volume) * track_height);
	VideoCanvasRect filled = track;
	filled.y = thumb_y;
	filled.height = track_top + track_height - thumb_y;
	fill_rect(canvas, canvas_width, canvas_height, filled, 255, 255, 255,
	          icon_alpha);
	fill_circle(canvas, canvas_width, canvas_height, center_x, thumb_y, 5,
	            255, 255, 255, icon_alpha);
}

static void draw_waiting_indicator(uint32_t *canvas, int canvas_width,
                                   int canvas_height,
                                   const VideoCanvasTransportLayout *layout,
                                   const VideoCanvasTransportState *state)
{
	int shortest = layout->target.width < layout->target.height
	                       ? layout->target.width
	                       : layout->target.height;
	int radius = clamp_int(shortest / 12, 12, 26);
	int dot_radius = clamp_int(radius / 6, 2, 4);
	int center_x = layout->target.x + layout->target.width / 2;
	int center_y = layout->target.y + layout->target.height / 2;
	int active = ((int)floor(state->spinner_phase * 12.0)) % 12;
	uint8_t panel_alpha = state->has_frame ? 150 : 220;
	fill_circle(canvas, canvas_width, canvas_height, center_x, center_y,
	            radius + dot_radius * 3, 0, 0, 0, panel_alpha);
	for (int index = 0; index < 12; ++index) {
		double angle =
		        (6.283185307179586 * index / 12.0) - 1.5707963267948966;
		int age = (active - index + 12) % 12;
		double brightness = 1.0 - (double)age / 14.0;
		uint8_t alpha = (uint8_t)round(255.0 * brightness);
		int x = center_x + (int)round(cos(angle) * radius);
		int y = center_y + (int)round(sin(angle) * radius);
		fill_circle(canvas, canvas_width, canvas_height, x, y,
		            dot_radius, 255, 255, 255, alpha);
	}
}

void video_canvas_draw_transport(uint32_t *canvas, int canvas_width,
                                 int canvas_height,
                                 const VideoCanvasTransportLayout *layout,
                                 const VideoCanvasTransportState *state)
{
	if (!canvas || !layout || !state || canvas_width <= 0 ||
	    canvas_height <= 0 || layout->target.width <= 0 ||
	    layout->target.height <= 0 ||
	    (state->opacity <= 0.0 && !state->waiting))
		return;
	if (!state->has_frame)
		fill_rect(canvas, canvas_width, canvas_height, layout->target,
		          0, 0, 0, 255);
	double opacity = clamp_double(state->opacity, 0.0, 1.0);
	if (opacity > 0.0) {
		uint8_t panel_alpha = (uint8_t)round(175.0 * opacity);
		uint8_t bar_alpha = (uint8_t)round(155.0 * opacity);
		uint8_t icon_alpha = (uint8_t)round(255.0 * opacity);
		if (!state->waiting)
			draw_toggle(canvas, canvas_width, canvas_height, layout,
			            state, panel_alpha, icon_alpha);
		draw_bottom_bar(canvas, canvas_width, canvas_height, layout,
		                state, bar_alpha, icon_alpha);
		draw_volume_control(canvas, canvas_width, canvas_height, layout,
		                    state, bar_alpha, icon_alpha);
	}
	if (state->waiting)
		draw_waiting_indicator(canvas, canvas_width, canvas_height,
		                       layout, state);
}
