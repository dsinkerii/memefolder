#ifndef MEL_FFI_H
#define MEL_FFI_H

#include <stdint.h>

#ifdef _WIN32
  #define MEL_FFI_EXPORT __declspec(dllexport)
#else
  #define MEL_FFI_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* CLAP mel spectrogram parameters */
#define CLAP_SAMPLE_RATE   48000
#define CLAP_MAX_SAMPLES   480000   /* 10 seconds */
#define CLAP_N_FFT         1024
#define CLAP_HOP_LENGTH    480
#define CLAP_N_MELS        64
#define CLAP_N_FRAMES      1001     /* (max_samples + n_fft) / hop_length */
/* Internally: padded length = max_samples + n_fft = 481024 */
/* Number of frames = (padded - n_fft) / hop_length + 1 */
/*                  = (481024 - 1024) / 480 + 1 = 480000/480 + 1 = 1001 */

/* CLIP image parameters */
#define CLIP_IMAGE_SIZE    224
#define CLIP_MEAN_R        0.48145466f
#define CLIP_MEAN_G        0.4578275f
#define CLIP_MEAN_B        0.40821073f
#define CLIP_STD_R         0.26862954f
#define CLIP_STD_G         0.26130258f
#define CLIP_STD_B         0.27577711f

/*
 * Initialize mel_ffi: install crash handlers.
 * Must be called once before any other function.
 */
MEL_FFI_EXPORT void mel_init(void);

/*
 * Compute CLAP log-mel spectrogram from raw PCM audio.
 *
 * pcm: 48kHz mono PCM samples (float32, range [-1, 1])
 * num_samples: number of input samples
 * output: pre-allocated array of CLAP_N_FRAMES * CLAP_N_MELS floats
 *         output is row-major: [frame][mel_band]
 *
 * Handles truncation to 10s and padding internally.
 */
MEL_FFI_EXPORT void compute_clap_mel(const float* pcm, int num_samples, float* output);

/*
 * Preprocess image for CLIP vision encoder.
 *
 * image_data: raw image file bytes (JPEG, PNG, etc.)
 * data_len: length of image_data
 * output: pre-allocated array of 3 * CLIP_IMAGE_SIZE * CLIP_IMAGE_SIZE floats
 *         output is channel-major: [C][H][W] = RGB order
 *
 * Returns 0 on success, -1 on error.
 */
MEL_FFI_EXPORT int preprocess_clip_image(const unsigned char* image_data, int data_len, float* output);

/* Whisper mel spectrogram parameters */
#define WHISPER_SAMPLE_RATE   16000
#define WHISPER_MAX_SAMPLES   480000   /* 30 seconds */
#define WHISPER_N_FFT         400
#define WHISPER_HOP_LENGTH    160
#define WHISPER_N_MELS        80
#define WHISPER_N_FRAMES      3000     /* 30s / 10ms hop */

/*
 * Compute Whisper log-mel spectrogram from raw PCM audio.
 *
 * pcm: 16kHz mono PCM samples (float32, range [-1, 1])
 * num_samples: number of input samples
 * output: pre-allocated array of WHISPER_N_FRAMES * WHISPER_N_MELS floats
 *         output is row-major: [frame][mel_band]
 *
 * Handles truncation to 30s and zero-padding internally.
 * Uses reflection padding at signal boundaries.
 */
MEL_FFI_EXPORT void compute_whisper_mel(const float* pcm, int num_samples, float* output);

#ifdef __cplusplus
}
#endif

#endif /* MEL_FFI_H */
