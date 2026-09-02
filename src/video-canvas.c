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

bool video_canvas_blit_bgra(uint32_t *canvas, int canvas_width,
			    int canvas_height, const uint8_t *source,
			    int source_width, int source_height,
			    int source_stride, int destination_x,
			    int destination_y)
{
	int source_x = destination_x < 0 ? -destination_x : 0;
	int source_y = destination_y < 0 ? -destination_y : 0;
	int canvas_x = destination_x > 0 ? destination_x : 0;
	int canvas_y = destination_y > 0 ? destination_y : 0;
	int copy_width = source_width - source_x;
	int copy_height = source_height - source_y;
	if (copy_width > canvas_width - canvas_x)
		copy_width = canvas_width - canvas_x;
	if (copy_height > canvas_height - canvas_y)
		copy_height = canvas_height - canvas_y;
	if (!canvas || !source || copy_width <= 0 || copy_height <= 0)
		return false;

	for (int row = 0; row < copy_height; ++row)
		memcpy(canvas + (size_t)(canvas_y + row) * canvas_width + canvas_x,
		       source + (size_t)(source_y + row) * source_stride +
			       (size_t)source_x * 4,
		       (size_t)copy_width * 4);
	return true;
}

VideoCanvasTransportLayout
video_canvas_transport_layout(VideoCanvasRect target)
{
	int shortest = target.width < target.height ? target.width : target.height;
	int radius = clamp_int(shortest / 10, 12, 32);
	int control_height = clamp_int(target.height / 8, 20, 36);
	int mute_width = clamp_int(target.width / 8, 28, 40);
	VideoCanvasTransportLayout layout = {
		.target = target,
		.toggle = {
			.x = target.x + target.width / 2 - radius,
			.y = target.y + target.height / 2 - radius,
			.width = radius * 2,
			.height = radius * 2,
		},
		.mute = {
			.x = target.x,
			.y = target.y + target.height - control_height,
			.width = mute_width,
			.height = control_height,
		},
		.seek = {
			.x = target.x + mute_width,
			.y = target.y + target.height - control_height,
			.width = target.width - mute_width - 10,
			.height = control_height,
		},
		.toggle_radius = radius,
		.progress_y = target.y + target.height - control_height / 2,
	};
	return layout;
}

static void blend_pixel(uint32_t *canvas, int canvas_width, int canvas_height,
			int x, int y, uint8_t red, uint8_t green,
			uint8_t blue, uint8_t alpha)
{
	if (x < 0 || y < 0 || x >= canvas_width || y >= canvas_height || !alpha)
		return;
	uint32_t *pixel = canvas + (size_t)y * canvas_width + x;
	uint8_t old_blue = *pixel & 0xff;
	uint8_t old_green = (*pixel >> 8) & 0xff;
	uint8_t old_red = (*pixel >> 16) & 0xff;
	unsigned inverse = 255 - alpha;
	uint8_t out_blue = (blue * alpha + old_blue * inverse) / 255;
	uint8_t out_green = (green * alpha + old_green * inverse) / 255;
	uint8_t out_red = (red * alpha + old_red * inverse) / 255;
	*pixel = 0xff000000u | ((uint32_t)out_red << 16) |
		 ((uint32_t)out_green << 8) | out_blue;
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
			int center_x, int center_y, int radius,
			uint8_t red, uint8_t green, uint8_t blue,
			uint8_t alpha)
{
	int radius_squared = radius * radius;
	for (int y = -radius; y <= radius; ++y)
		for (int x = -radius; x <= radius; ++x)
			if (x * x + y * y <= radius_squared)
				blend_pixel(canvas, canvas_width, canvas_height,
					    center_x + x, center_y + y,
					    red, green, blue, alpha);
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
		fill_rect(canvas, canvas_width, canvas_height, point,
			  red, green, blue, alpha);
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
		fill_rect(canvas, canvas_width, canvas_height, left,
			  255, 255, 255, icon_alpha);
		fill_rect(canvas, canvas_width, canvas_height, right,
			  255, 255, 255, icon_alpha);
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
		fill_rect(canvas, canvas_width, canvas_height, segment,
			  255, 255, 255, icon_alpha);
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
	fill_rect(canvas, canvas_width, canvas_height, bar,
		  0, 0, 0, panel_alpha);

	int center_x = layout->mute.x + layout->mute.width / 2;
	int center_y = layout->mute.y + layout->mute.height / 2;
	int icon_size = layout->mute.height / 3 > 8
			? layout->mute.height / 3
			: 8;
	VideoCanvasRect speaker = {
		.x = center_x - icon_size / 2,
		.y = center_y - icon_size / 4,
		.width = icon_size / 3,
		.height = icon_size / 2,
	};
	fill_rect(canvas, canvas_width, canvas_height, speaker,
		  255, 255, 255, icon_alpha);
	draw_line(canvas, canvas_width, canvas_height,
		  center_x - icon_size / 6, center_y,
		  center_x + icon_size / 3, center_y - icon_size / 3,
		  2, 255, 255, 255, icon_alpha);
	draw_line(canvas, canvas_width, canvas_height,
		  center_x - icon_size / 6, center_y,
		  center_x + icon_size / 3, center_y + icon_size / 3,
		  2, 255, 255, 255, icon_alpha);
	if (state->muted)
		draw_line(canvas, canvas_width, canvas_height,
			  center_x - icon_size / 2, center_y - icon_size / 2,
			  center_x + icon_size / 2, center_y + icon_size / 2,
			  3, 255, 96, 96, icon_alpha);

	int progress_x = layout->seek.x;
	int progress_width = layout->seek.width > 0 ? layout->seek.width : 1;
	VideoCanvasRect track = {
		.x = progress_x,
		.y = layout->progress_y - 2,
		.width = progress_width,
		.height = 4,
	};
	fill_rect(canvas, canvas_width, canvas_height, track,
		  112, 112, 112, icon_alpha);
	for (size_t index = 0; index < state->buffered_range_count; ++index) {
		double start = clamp_double(
			state->buffered_ranges[index].start, 0.0, 1.0);
		double end = clamp_double(
			state->buffered_ranges[index].end, start, 1.0);
		VideoCanvasRect buffered = track;
		buffered.x += (int)round(progress_width * start);
		buffered.width = (int)round(progress_width * end) -
				 (buffered.x - track.x);
		fill_rect(canvas, canvas_width, canvas_height, buffered,
			  190, 190, 190, icon_alpha);
	}
	int played_width = (int)round(progress_width *
				     clamp_double(state->progress, 0.0, 1.0));
	VideoCanvasRect played = track;
	played.width = played_width;
	fill_rect(canvas, canvas_width, canvas_height, played,
		  255, 255, 255, icon_alpha);
	fill_circle(canvas, canvas_width, canvas_height,
		    progress_x + played_width, layout->progress_y, 4,
		    255, 255, 255, icon_alpha);
}

static void draw_waiting_indicator(
	uint32_t *canvas, int canvas_width, int canvas_height,
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
		double angle = (6.283185307179586 * index / 12.0) -
			       1.5707963267948966;
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
	if (state->waiting && !state->has_frame)
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
		draw_bottom_bar(canvas, canvas_width, canvas_height, layout, state,
				bar_alpha, icon_alpha);
	}
	if (state->waiting)
		draw_waiting_indicator(canvas, canvas_width, canvas_height,
				       layout, state);
}
