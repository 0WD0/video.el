/* video-apng.c --- libavcodec APNG frames for the existing GstPlay source slot
 *
 * Copyright (C) 2026 0WD0
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <gst/app/gstappsrc.h>
#include <gst/video/video.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/crc.h>
#include <libavutil/error.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mathematics.h>
#include <libswscale/swscale.h>
#include <string.h>

#include "video-apng.h"

#define APNG_MAX_PIXELS 33554432

struct VideoApng {
	gatomicrefcount refs;
	GMutex lock;
	gchar *path;
	AVFormatContext *format;
	AVCodecContext *decoder;
	AVPacket *packet;
	AVFrame *frame;
	AVFrame *converted;
	struct SwsContext *sws;
	VideoApngMetadata metadata;
	AVRational time_base;
	gint64 total_ticks;
	gint64 next_ticks;
	guint next_frame;
	GstClockTime frame_pts;
	GstClockTime frame_duration;
	GstVideoInfo info;
	GstCaps *caps;
	gboolean pending;
	gboolean failed;
	gint flushing;
};

static void apng_error(GError **error, const gchar *message)
{
	g_set_error_literal(error, GST_STREAM_ERROR, GST_STREAM_ERROR_DECODE,
	                    message);
}

static void apng_av_error(GError **error, const gchar *message, gint code)
{
	gchar detail[AV_ERROR_MAX_STRING_SIZE];
	av_strerror(code, detail, sizeof(detail));
	g_set_error(error, GST_STREAM_ERROR, GST_STREAM_ERROR_DECODE,
	            "%s: %s", message, detail);
}

VideoApng *video_apng_ref(VideoApng *apng)
{
	g_atomic_ref_count_inc(&apng->refs);
	return apng;
}

void video_apng_unref(VideoApng *apng)
{
	if (!apng || !g_atomic_ref_count_dec(&apng->refs))
		return;
	avcodec_free_context(&apng->decoder);
	avformat_close_input(&apng->format);
	av_packet_free(&apng->packet);
	av_frame_free(&apng->frame);
	av_frame_free(&apng->converted);
	sws_freeContext(apng->sws);
	gst_clear_caps(&apng->caps);
	g_free(apng->path);
	g_mutex_clear(&apng->lock);
	g_free(apng);
}

static int apng_interrupted(void *data)
{
	VideoApng *apng = data;
	return g_atomic_int_get(&apng->flushing);
}

static gboolean apng_open_input(VideoApng *apng, GError **error)
{
	const AVInputFormat *demuxer = av_find_input_format("apng");
	if (!demuxer) {
		apng_error(error, "The system FFmpeg has no APNG demuxer");
		return FALSE;
	}
	apng->format = avformat_alloc_context();
	if (!apng->format) {
		apng_error(error, "Could not allocate the APNG demuxer");
		return FALSE;
	}
	apng->format->interrupt_callback = (AVIOInterruptCB){
	        .callback = apng_interrupted, .opaque = apng,
	};
	/* Seeks rebuild from the start; do not retain an animation-sized index. */
	apng->format->max_index_size = 2 * sizeof(AVIndexEntry);
	AVDictionary *options = NULL;
	av_dict_set(&options, "protocol_whitelist", "file", 0);
	av_dict_set(&options, "ignore_loop", "1", 0);
	av_dict_set(&options, "max_fps", "0", 0);
	/* Match FFmpeg's zero-delay convention, without clamping other delays. */
	av_dict_set(&options, "default_fps", "15", 0);
	int result = avformat_open_input(&apng->format, apng->path,
	                                 demuxer, &options);
	av_dict_free(&options);
	if (result < 0) {
		apng_av_error(error, "Could not open local APNG animation", result);
		return FALSE;
	}
	if (apng->format->nb_streams != 1 || !apng->format->pb ||
	    !(apng->format->pb->seekable & AVIO_SEEKABLE_NORMAL) ||
	    apng->format->streams[0]->codecpar->codec_id != AV_CODEC_ID_APNG) {
		apng_error(error, "Source is not a seekable APNG animation");
		return FALSE;
	}
	return TRUE;
}

/* The demuxer does not check PNG CRCs, including those in its extradata. */
static gboolean apng_check_chunks(const guint8 *data, gsize size,
                                   GError **error)
{
	const AVCRC *table = av_crc_get_table(AV_CRC_32_IEEE_LE);
	while (size) {
		if (size < 12)
			goto invalid;
		guint32 length = AV_RB32(data);
		if (length > G_MAXINT32 || length > size - 12 ||
		    AV_RB32(data + 8 + length) !=
		            ~av_crc(table, G_MAXUINT32, data + 4,
		                    (gsize)length + 4))
			goto invalid;
		data += (gsize)length + 12;
		size -= (gsize)length + 12;
	}
	return TRUE;
invalid:
	apng_error(error, "Invalid APNG chunk length or CRC");
	return FALSE;
}

static gboolean apng_header(VideoApng *apng, VideoApngMetadata *metadata,
                             GError **error)
{
	AVCodecParameters *parameters = apng->format->streams[0]->codecpar;
	if (parameters->width <= 0 || parameters->height <= 0 ||
	    (guint64)parameters->width * parameters->height > APNG_MAX_PIXELS) {
		apng_error(error, "APNG dimensions exceed the Canvas pixel limit");
		return FALSE;
	}
	if (!parameters->extradata || parameters->extradata_size < 25 ||
	    !apng_check_chunks(parameters->extradata,
	                       parameters->extradata_size, error)) {
		if (error && !*error)
			apng_error(error, "Missing APNG header");
		return FALSE;
	}
	*metadata = (VideoApngMetadata){
	        .width = parameters->width, .height = parameters->height,
	};
	const guint8 *data = parameters->extradata;
	gsize size = parameters->extradata_size;
	while (size) {
		guint32 length = AV_RB32(data);
		if (memcmp(data + 4, "acTL", 4) == 0) {
			if (length != 8 || metadata->frames || !AV_RB32(data + 8)) {
				apng_error(error, "Invalid APNG animation control chunk");
				return FALSE;
			}
			metadata->frames = AV_RB32(data + 8);
			guint32 plays = AV_RB32(data + 12);
			metadata->loop_count = plays == 0 ? 0 :
			                       plays == 1 ? -1 : (gint64)plays - 1;
		}
		data += (gsize)length + 12;
		size -= (gsize)length + 12;
	}
	if (!metadata->frames) {
		apng_error(error, "PNG source has no APNG animation control chunk");
		return FALSE;
	}
	return TRUE;
}

static gboolean apng_time(VideoApng *apng, gint64 ticks, GstClockTime *time,
                           GError **error)
{
	gint64 ns = av_rescale_q(ticks, apng->time_base,
	                        (AVRational){1, GST_SECOND});
	/* av_rescale_q returns INT64_MIN on overflow.  Gst seeks are signed. */
	if (ticks < 0 || ns < 0) {
		apng_error(error, "APNG duration exceeds the supported time range");
		return FALSE;
	}
	*time = (GstClockTime)ns;
	return TRUE;
}

static gboolean apng_packet_timing(VideoApng *apng, gint64 ticks,
                                    gint64 *end, GError **error)
{
	AVPacket *packet = apng->packet;
	if (packet->stream_index != 0 || packet->duration <= 0 ||
	    packet->duration > G_MAXINT64 - ticks ||
	    packet->size < 38 || AV_RB32(packet->data) != 26 ||
	    memcmp(packet->data + 4, "fcTL", 4) != 0 ||
	    (packet->flags & AV_PKT_FLAG_CORRUPT)) {
		apng_error(error, "Invalid APNG animation packet or timing");
		return FALSE;
	}
	*end = ticks + packet->duration;
	return TRUE;
}

static gboolean apng_scan(VideoApng *apng, GError **error)
{
	if (!apng_header(apng, &apng->metadata, error))
		return FALSE;
	apng->time_base = apng->format->streams[0]->time_base;
	if (apng->time_base.num <= 0 || apng->time_base.den <= 0) {
		apng_error(error, "Invalid APNG time base");
		return FALSE;
	}
	guint frames = 0;
	gint64 ticks = 0, packet_end = -1;
	int result;
	while ((result = av_read_frame(apng->format, apng->packet)) >= 0) {
		AVPacket *packet = apng->packet;
		gint64 end;
		gboolean valid = apng_packet_timing(apng, ticks, &end, error) &&
		                 apng_check_chunks(packet->data, packet->size, error);
		if (valid && (frames >= apng->metadata.frames || packet->pos < 0 ||
		              packet->pos > G_MAXINT64 - packet->size)) {
			apng_error(error, "Invalid APNG frame count or packet position");
			valid = FALSE;
		}
		if (valid) {
			++frames;
			ticks = end;
			packet_end = packet->pos + packet->size;
		}
		av_packet_unref(packet);
		if (!valid)
			return FALSE;
	}
	if (result != AVERROR_EOF) {
		apng_av_error(error, "Could not scan APNG animation", result);
		return FALSE;
	}
	if (frames != apng->metadata.frames || !ticks) {
		apng_error(error, "APNG animation has missing frames");
		return FALSE;
	}
	/* APNG's demuxer stops before IEND and accepts a truncated terminator.
	 * Validate it at the end of the last packet, not merely at file EOF. */
	guint8 iend[12];
	if (avio_seek(apng->format->pb, packet_end, SEEK_SET) != packet_end ||
	    avio_read(apng->format->pb, iend, sizeof(iend)) != (int)sizeof(iend) ||
	    AV_RB32(iend) != 0 || memcmp(iend + 4, "IEND", 4) != 0) {
		apng_error(error, "APNG animation has no complete IEND chunk");
		return FALSE;
	}
	if (!apng_check_chunks(iend, sizeof(iend), error) ||
	    !apng_time(apng, ticks, &apng->metadata.duration, error))
		return FALSE;
	if (!apng->metadata.duration) {
		apng_error(error, "APNG duration is shorter than one nanosecond");
		return FALSE;
	}
	apng->total_ticks = ticks;
	return TRUE;
}

static VideoApng *apng_load(const gchar *uri, GError **error)
{
	VideoApng *apng = g_new0(VideoApng, 1);
	g_atomic_ref_count_init(&apng->refs);
	g_mutex_init(&apng->lock);
	gchar *hostname = NULL;
	apng->path = g_filename_from_uri(uri, &hostname, error);
	gboolean local = !hostname || !*hostname ||
	                 g_ascii_strcasecmp(hostname, "localhost") == 0;
	g_free(hostname);
	if (!apng->path)
		goto failed;
	if (!local || !g_file_test(apng->path, G_FILE_TEST_IS_REGULAR)) {
		apng_error(error, "APNG playback requires a local regular file URI");
		goto failed;
	}
	apng->packet = av_packet_alloc();
	if (!apng->packet) {
		apng_error(error, "Could not allocate an APNG packet");
		goto failed;
	}
	if (!apng_open_input(apng, error) || !apng_scan(apng, error))
		goto failed;
	return apng;
failed:
	video_apng_unref(apng);
	return NULL;
}

/* Reopening is intentional: generic demux seeks can choose a frame whose
 * dispose/blend dependencies precede it, and avcodec_flush_buffers does not
 * reset every version of the APNG decoder's private composition state. */
static gboolean apng_restart(VideoApng *apng, GError **error)
{
	avcodec_free_context(&apng->decoder);
	avformat_close_input(&apng->format);
	av_packet_unref(apng->packet);
	av_frame_unref(apng->frame);
	apng->pending = FALSE;
	apng->next_frame = 0;
	apng->next_ticks = 0;
	if (g_atomic_int_get(&apng->flushing))
		return FALSE;
	if (!apng_open_input(apng, error))
		return FALSE;
	VideoApngMetadata metadata;
	if (!apng_header(apng, &metadata, error))
		return FALSE;
	AVStream *stream = apng->format->streams[0];
	if (metadata.width != apng->metadata.width ||
	    metadata.height != apng->metadata.height ||
	    metadata.frames != apng->metadata.frames ||
	    metadata.loop_count != apng->metadata.loop_count ||
	    av_cmp_q(stream->time_base, apng->time_base) != 0) {
		apng_error(error, "APNG source changed after its metadata was read");
		return FALSE;
	}
	const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_APNG);
	if (!codec) {
		apng_error(error, "The system FFmpeg has no APNG decoder");
		return FALSE;
	}
	apng->decoder = avcodec_alloc_context3(codec);
	if (!apng->decoder) {
		apng_error(error, "Could not allocate the APNG decoder");
		return FALSE;
	}
	int result = avcodec_parameters_to_context(apng->decoder, stream->codecpar);
	if (result >= 0) {
		/* APNG emits one frame per packet; avoid frame-thread lookahead. */
		apng->decoder->thread_count = 1;
		apng->decoder->max_pixels = APNG_MAX_PIXELS;
		apng->decoder->pkt_timebase = apng->time_base;
		apng->decoder->err_recognition = AV_EF_CRCCHECK | AV_EF_EXPLODE;
		result = avcodec_open2(apng->decoder, codec, NULL);
	}
	if (result < 0) {
		apng_av_error(error, "Could not initialize the APNG decoder", result);
		return FALSE;
	}
	return TRUE;
}

/* Caller holds the decoder lock.  Demuxed durations, not a nominal FPS,
 * determine timestamps.  The nonanimated default IDAT remains in extradata;
 * libavcodec's APNG entry skips it instead of returning it as frame zero. */
static gboolean apng_decode_next(VideoApng *apng, GError **error)
{
	if (g_atomic_int_get(&apng->flushing))
		return FALSE;
	int result = av_read_frame(apng->format, apng->packet);
	if (result < 0) {
		apng_av_error(error, "Could not read an APNG frame", result);
		return FALSE;
	}
	gint64 end;
	if (!apng_packet_timing(apng, apng->next_ticks, &end, error)) {
		av_packet_unref(apng->packet);
		return FALSE;
	}
	GstClockTime pts, end_time;
	if (end > apng->total_ticks ||
	    (apng->next_frame + 1 == apng->metadata.frames &&
	     end != apng->total_ticks)) {
		apng_error(error, "APNG frame timing changed during playback");
		av_packet_unref(apng->packet);
		return FALSE;
	}
	if (!apng_time(apng, apng->next_ticks, &pts, error) ||
	    !apng_time(apng, end, &end_time, error)) {
		av_packet_unref(apng->packet);
		return FALSE;
	}
	apng->packet->pts = apng->packet->dts = apng->next_ticks;
	result = avcodec_send_packet(apng->decoder, apng->packet);
	av_packet_unref(apng->packet);
	if (result >= 0)
		result = avcodec_receive_frame(apng->decoder, apng->frame);
	if (result < 0) {
		apng_av_error(error, "Could not decode an APNG frame", result);
		return FALSE;
	}
	if (apng->frame->width != (gint)apng->metadata.width ||
	    apng->frame->height != (gint)apng->metadata.height ||
	    !apng->frame->buf[0] || end_time <= pts ||
	    apng->frame->decode_error_flags ||
	    (apng->frame->flags & AV_FRAME_FLAG_CORRUPT)) {
		apng_error(error, "Invalid decoded APNG frame");
		return FALSE;
	}
	apng->frame_pts = pts;
	apng->frame_duration = end_time - pts;
	apng->next_ticks = end;
	++apng->next_frame;
	apng->pending = TRUE;
	return TRUE;
}

static GstVideoFormat apng_video_format(enum AVPixelFormat format)
{
	switch (format) {
	case AV_PIX_FMT_RGBA: return GST_VIDEO_FORMAT_RGBA;
	case AV_PIX_FMT_BGRA: return GST_VIDEO_FORMAT_BGRA;
	case AV_PIX_FMT_ARGB: return GST_VIDEO_FORMAT_ARGB;
	case AV_PIX_FMT_ABGR: return GST_VIDEO_FORMAT_ABGR;
	case AV_PIX_FMT_RGB24: return GST_VIDEO_FORMAT_RGB;
	case AV_PIX_FMT_BGR24: return GST_VIDEO_FORMAT_BGR;
	case AV_PIX_FMT_GRAY8: return GST_VIDEO_FORMAT_GRAY8;
	case AV_PIX_FMT_GRAY16BE: return GST_VIDEO_FORMAT_GRAY16_BE;
	case AV_PIX_FMT_GRAY16LE: return GST_VIDEO_FORMAT_GRAY16_LE;
	case AV_PIX_FMT_RGBA64BE: return GST_VIDEO_FORMAT_RGBA64_BE;
	case AV_PIX_FMT_RGBA64LE: return GST_VIDEO_FORMAT_RGBA64_LE;
	case AV_PIX_FMT_BGRA64BE: return GST_VIDEO_FORMAT_BGRA64_BE;
	case AV_PIX_FMT_BGRA64LE: return GST_VIDEO_FORMAT_BGRA64_LE;
	default: return GST_VIDEO_FORMAT_UNKNOWN;
	}
}

static void apng_release_frame(gpointer data)
{
	AVFrame *frame = data;
	av_frame_free(&frame);
}

static GstBuffer *apng_frame_buffer(VideoApng *apng, GError **error)
{
	AVFrame *frame = apng->frame;
	GstVideoFormat format = apng_video_format(frame->format);
	if (format == GST_VIDEO_FORMAT_UNKNOWN) {
		apng->sws = sws_getCachedContext(apng->sws,
		        frame->width, frame->height, frame->format,
		        frame->width, frame->height, AV_PIX_FMT_RGBA,
		        SWS_POINT, NULL, NULL, NULL);
		if (!apng->sws) {
			apng_error(error, "Could not convert APNG pixel format");
			return NULL;
		}
		/* Retained samples must stay immutable.  Reuse the target when
		 * unshared, otherwise replace it without copying obsolete pixels. */
		if (!av_frame_is_writable(apng->converted)) {
			av_frame_unref(apng->converted);
			apng->converted->format = AV_PIX_FMT_RGBA;
			apng->converted->width = frame->width;
			apng->converted->height = frame->height;
			int result = av_frame_get_buffer(apng->converted, 32);
			if (result < 0) {
				apng_av_error(error, "Could not allocate APNG pixels", result);
				return NULL;
			}
		}
		if (sws_scale(apng->sws, (const uint8_t * const *)frame->data,
		              frame->linesize, 0, frame->height,
		              apng->converted->data, apng->converted->linesize) !=
		    frame->height) {
			apng_error(error, "Could not convert an APNG frame");
			return NULL;
		}
		frame = apng->converted;
		format = GST_VIDEO_FORMAT_RGBA;
	}
	if (format != GST_VIDEO_INFO_FORMAT(&apng->info)) {
		apng_error(error, "APNG pixel format changed during playback");
		return NULL;
	}
	gint stride = frame->linesize[0];
	gsize row = (gsize)frame->width *
	            GST_VIDEO_FORMAT_INFO_PSTRIDE(apng->info.finfo, 0);
	AVBufferRef *plane = av_frame_get_plane_buffer(frame, 0);
	if (!plane || stride <= 0 || (gsize)stride < row ||
	    frame->data[0] < plane->data ||
	    (gsize)(frame->data[0] - plane->data) > plane->size) {
		apng_error(error, "Invalid APNG pixel stride or allocation");
		return NULL;
	}
	gsize offset = frame->data[0] - plane->data;
	guint64 size = (guint64)stride * frame->height;
	if (size > plane->size - offset) {
		apng_error(error, "APNG frame allocation is shorter than its stride");
		return NULL;
	}
	AVFrame *retained = av_frame_clone(frame);
	if (!retained) {
		apng_error(error, "Could not retain APNG pixels");
		return NULL;
	}
	GstBuffer *buffer = gst_buffer_new_wrapped_full(
	        GST_MEMORY_FLAG_READONLY, frame->data[0], (gsize)size,
	        0, (gsize)size, retained, apng_release_frame);
	if (!buffer) {
		apng_release_frame(retained);
		apng_error(error, "Could not wrap APNG pixels");
		return NULL;
	}
	gsize offsets[GST_VIDEO_MAX_PLANES] = {0};
	gint strides[GST_VIDEO_MAX_PLANES] = {stride};
	if (!gst_buffer_add_video_meta_full(buffer, GST_VIDEO_FRAME_FLAG_NONE,
	                                    format, frame->width, frame->height,
	                                    1, offsets, strides)) {
		gst_buffer_unref(buffer);
		apng_error(error, "Could not describe APNG pixel strides");
		return NULL;
	}
	GST_BUFFER_PTS(buffer) = apng->frame_pts;
	GST_BUFFER_DURATION(buffer) = apng->frame_duration;
	apng->pending = FALSE;
	return buffer;
}

VideoApng *video_apng_new(const gchar *uri, GError **error)
{
	VideoApng *apng = apng_load(uri, error);
	if (!apng)
		return NULL;
	apng->frame = av_frame_alloc();
	apng->converted = av_frame_alloc();
	if (!apng->frame || !apng->converted) {
		apng_error(error, "Could not allocate APNG frame state");
		goto failed;
	}
	if (!apng_restart(apng, error) || !apng_decode_next(apng, error))
		goto failed;
	GstVideoFormat format = apng_video_format(apng->frame->format);
	if (format == GST_VIDEO_FORMAT_UNKNOWN)
		format = GST_VIDEO_FORMAT_RGBA;
	if (!gst_video_info_set_format(&apng->info, format,
	                               apng->metadata.width,
	                               apng->metadata.height)) {
		apng_error(error, "Could not describe APNG pixels");
		goto failed;
	}
	/* Variable rate, straight alpha.  GstVideoMeta supplies decoder stride. */
	GST_VIDEO_INFO_FPS_N(&apng->info) = 0;
	GST_VIDEO_INFO_FPS_D(&apng->info) = 1;
	apng->caps = gst_video_info_to_caps(&apng->info);
	if (!apng->caps) {
		apng_error(error, "Could not create APNG video caps");
		goto failed;
	}
	return apng;
failed:
	video_apng_unref(apng);
	return NULL;
}

const VideoApngMetadata *video_apng_get_metadata(VideoApng *apng)
{
	return &apng->metadata;
}

static gboolean apng_seek(VideoApng *apng, GstClockTime offset,
                           GError **error)
{
	if (offset == apng->metadata.duration) {
		apng->pending = FALSE;
		apng->next_frame = apng->metadata.frames;
		av_frame_unref(apng->frame);
		return TRUE;
	}
	/* appsrc normally seeks to zero immediately after configuration. */
	if (!offset && apng->pending && apng->next_frame == 1)
		return TRUE;
	if (!apng_restart(apng, error))
		return FALSE;
	do {
		if (!apng_decode_next(apng, error))
			return FALSE;
	} while (apng->frame_pts + apng->frame_duration <= offset);
	return TRUE;
}

static void source_need_data(GstAppSrc *source, guint length, gpointer data)
{
	VideoApng *apng = data;
	(void)length;
	GError *error = NULL;
	GstBuffer *buffer = NULL;
	gboolean eos = FALSE;
	g_mutex_lock(&apng->lock);
	if (!g_atomic_int_get(&apng->flushing) && !apng->failed) {
		if (!apng->pending && apng->next_frame >= apng->metadata.frames)
			eos = TRUE;
		else if (apng->pending || apng_decode_next(apng, &error))
			buffer = apng_frame_buffer(apng, &error);
		if (error)
			apng->failed = TRUE;
	}
	g_mutex_unlock(&apng->lock);
	if (g_atomic_int_get(&apng->flushing)) {
		gst_clear_buffer(&buffer);
		g_clear_error(&error);
		return;
	}
	if (error) {
		GST_ELEMENT_ERROR(source, STREAM, DECODE,
		                  ("%s", error->message), (NULL));
		g_error_free(error);
	} else if (buffer) {
		GstFlowReturn flow = gst_app_src_push_buffer(source, buffer);
		if (flow != GST_FLOW_OK && flow != GST_FLOW_FLUSHING &&
		    flow != GST_FLOW_EOS)
			GST_ELEMENT_ERROR(source, STREAM, FAILED,
			                  ("Could not publish an APNG frame"),
			                  ("%s", gst_flow_get_name(flow)));
	} else if (eos) {
		gst_app_src_end_of_stream(source);
	}
}

static gboolean source_seek_data(GstAppSrc *source, guint64 offset,
                                  gpointer data)
{
	VideoApng *apng = data;
	if (offset > apng->metadata.duration ||
	    g_atomic_int_get(&apng->flushing))
		return FALSE;
	GError *error = NULL;
	g_mutex_lock(&apng->lock);
	gboolean ready = !g_atomic_int_get(&apng->flushing) && !apng->failed &&
	                 apng_seek(apng, offset, &error);
	if (error)
		apng->failed = TRUE;
	g_mutex_unlock(&apng->lock);
	if (error) {
		if (!g_atomic_int_get(&apng->flushing))
			GST_ELEMENT_ERROR(source, STREAM, DECODE,
			                  ("%s", error->message), (NULL));
		g_error_free(error);
	}
	return ready;
}

static void source_release(gpointer data)
{
	video_apng_unref(data);
}

gboolean video_apng_configure_source(VideoApng *apng, GstElement *source,
                                     GError **error)
{
	if (!GST_IS_APP_SRC(source)) {
		apng_error(error, "APNG playback source is not appsrc");
		return FALSE;
	}
	g_mutex_lock(&apng->lock);
	gboolean ready = !g_atomic_int_get(&apng->flushing) && !apng->failed &&
	                 apng_seek(apng, 0, error);
	g_mutex_unlock(&apng->lock);
	if (!ready) {
		if (error && !*error)
			apng_error(error, "APNG playback source is closed");
		return FALSE;
	}
	gst_app_src_set_caps(GST_APP_SRC(source), apng->caps);
	gst_app_src_set_duration(GST_APP_SRC(source), apng->metadata.duration);
	/* Padded/converted raw frames have no useful byte-addressed file size. */
	gst_app_src_set_size(GST_APP_SRC(source), -1);
	g_object_set(source, "format", GST_FORMAT_TIME,
	             "stream-type", GST_APP_STREAM_TYPE_SEEKABLE,
	             "is-live", FALSE, "block", FALSE,
	             "max-bytes", (guint64)0, "max-buffers", (guint64)2,
	             "emit-signals", FALSE, NULL);
	GstAppSrcCallbacks callbacks = {
	        .need_data = source_need_data,
	        .seek_data = source_seek_data,
	};
	gst_app_src_set_callbacks(GST_APP_SRC(source), &callbacks,
	                           video_apng_ref(apng), source_release);
	return TRUE;
}

void video_apng_flush(VideoApng *apng)
{
	/* No bounded pool acquisition or blocking push runs under the decoder
	 * lock.  Shutdown can interrupt I/O without waiting for that lock. */
	g_atomic_int_set(&apng->flushing, TRUE);
}

GstSample *video_apng_first_frame(const gchar *uri, GError **error)
{
	VideoApng *apng = video_apng_new(uri, error);
	if (!apng)
		return NULL;
	GstSample *sample = NULL;
	GstBuffer *buffer = apng_frame_buffer(apng, error);
	if (buffer) {
		sample = gst_sample_new(buffer, apng->caps, NULL, NULL);
		gst_buffer_unref(buffer);
	}
	video_apng_unref(apng);
	return sample;
}
