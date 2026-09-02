/* video-canvas.h --- Pure BGRA Canvas composition for video.el  -*- c-file-style: "linux" -*- */

#ifndef VIDEO_CANVAS_H
#define VIDEO_CANVAS_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
	int x;
	int y;
	int width;
	int height;
} VideoCanvasRect;

typedef struct {
	VideoCanvasRect target;
	VideoCanvasRect toggle;
	VideoCanvasRect mute;
	VideoCanvasRect seek;
	int toggle_radius;
	int progress_y;
} VideoCanvasTransportLayout;

typedef struct {
	bool playing;
	bool muted;
	double progress;
	double opacity;
} VideoCanvasTransportState;

bool video_canvas_blit_bgra(uint32_t *canvas, int canvas_width,
			    int canvas_height, const uint8_t *source,
			    int source_width, int source_height,
			    int source_stride, int destination_x,
			    int destination_y);

VideoCanvasTransportLayout
video_canvas_transport_layout(VideoCanvasRect target);

void video_canvas_draw_transport(uint32_t *canvas, int canvas_width,
				 int canvas_height,
				 const VideoCanvasTransportLayout *layout,
				 const VideoCanvasTransportState *state);

#endif /* VIDEO_CANVAS_H */
