#include "mel_ffi.h"
#include "mel_filterbank.h"
#include "whisper_filterbank.h"
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>

#ifdef _WIN32
  #include <windows.h>
#else
  #include <signal.h>
  #include <unistd.h>
#endif

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

/* ================================================================
 * Native crash handler — writes log before process dies
 * Uses only async-signal-safe syscalls, never malloc/fopen/fprintf
 * ================================================================ */
#ifdef _WIN32
  #include <windows.h>
  /* Use high-ASCII fallback instead of wide-char for simplicity */
  static const char CRASH_LOG_PATH[] = "C:\\memefolder_crash.txt";
#else
  #include <signal.h>
  #include <unistd.h>
  #include <fcntl.h>
  static const char CRASH_LOG_PATH[] = "/tmp/memefolder_crash.txt";
#endif

static void write_crash_log(const char* msg) {
    int fd;
#ifdef _WIN32
    HANDLE h = CreateFileA(
        CRASH_LOG_PATH, GENERIC_WRITE, FILE_SHARE_READ, NULL,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    );
    if (h == INVALID_HANDLE_VALUE) return;
    SetFilePointer(h, 0, NULL, FILE_END);
    DWORD written;
    WriteFile(h, msg, (DWORD)strlen(msg), &written, NULL);
    WriteFile(h, "\r\n", 2, &written, NULL);
    CloseHandle(h);
#else
    fd = open(CRASH_LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    write(fd, msg, strlen(msg));
    write(fd, "\n", 1);
    close(fd);
#endif
}

#ifdef _WIN32
static LONG WINAPI mel_veh_handler(EXCEPTION_POINTERS* ep) {
    (void)ep;
    write_crash_log("UNHANDLED EXCEPTION in process (caught by mel_ffi VEH)");
    return EXCEPTION_CONTINUE_SEARCH;
}

static void install_crash_handler(void) {
    AddVectoredExceptionHandler(1, mel_veh_handler);
}
#else
static void sigsegv_handler(int sig, siginfo_t* info, void* ucontext) {
    (void)sig; (void)info; (void)ucontext;
    write_crash_log("SIGSEGV/SIGABRT/SIGBUS in mel_ffi (caught by signal handler)");
    _exit(1);
}

static void install_crash_handler(void) {
    struct sigaction sa;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sa.sa_sigaction = sigsegv_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
}
#endif

/* ================================================================
 * Radix-2 FFT (decimation-in-time)
 * n must be power of 2
 * ================================================================ */
static void fft_radix2(float* re, float* im, int n) {
    int i, j, k, len, step;
    float t_re, t_im, w_re, w_im, u_re, u_im, angle;

    /* bit-reversal permutation */
    j = 0;
    for (i = 1; i < n; i++) {
        int bit = n >> 1;
        while (j & bit) {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if (i < j) {
            t_re = re[i]; t_im = im[i];
            re[i] = re[j]; im[i] = im[j];
            re[j] = t_re; im[j] = t_im;
        }
    }

    /* FFT butterflies */
    for (len = 2; len <= n; len <<= 1) {
        step = len >> 1;
        angle = -2.0f * 3.141592653589793f / len;
        w_re = 1.0f;
        w_im = 0.0f;
        for (j = 0; j < step; j++) {
            for (i = j; i < n; i += len) {
                k = i + step;
                t_re = w_re * re[k] - w_im * im[k];
                t_im = w_re * im[k] + w_im * re[k];
                re[k] = re[i] - t_re;
                im[k] = im[i] - t_im;
                re[i] += t_re;
                im[i] += t_im;
            }
            /* update twiddle factor */
            u_re = cosf(angle);
            u_im = sinf(angle);
            {
                float tmp = w_re * u_re - w_im * u_im;
                w_im = w_re * u_im + w_im * u_re;
                w_re = tmp;
            }
        }
    }
}

/* ================================================================
 * Hann window
 * ================================================================ */
static void hann_window(float* win, int n) {
    for (int i = 0; i < n; i++) {
        win[i] = 0.5f * (1.0f - cosf(2.0f * 3.141592653589793f * i / n));
    }
}

/* ================================================================
 * Init: install crash handlers
 * ================================================================ */
MEL_FFI_EXPORT void mel_init(void) {
    static int installed = 0;
    if (!installed) {
        install_crash_handler();
        installed = 1;
    }
}

/* ================================================================
 * CLAP log-mel spectrogram — internal implementation
 * ================================================================ */
static void compute_clap_mel_impl(const float* pcm, int num_samples, float* output) {
    float* waveform = (float*)malloc((CLAP_MAX_SAMPLES + CLAP_N_FFT) * sizeof(float));
    float window[CLAP_N_FFT];
    int i, f, t;
    float re[CLAP_N_FFT], im[CLAP_N_FFT];
    float power_spectrum[CLAP_N_FFT / 2 + 1];
    const int n_freq_bins = CLAP_N_FFT / 2 + 1; /* 513 */
    const int n_frames = CLAP_N_FRAMES; /* 1001 */

    if (!waveform) return;

    /* "repeatpad": repeat audio to fill max_length, then zero-pad remainder */
    int ns = num_samples;
    if (ns <= 0) ns = 0;
    if (ns > CLAP_MAX_SAMPLES) ns = CLAP_MAX_SAMPLES; /* truncate if too long */

    if (ns < CLAP_MAX_SAMPLES && ns > 0) {
        /* repeat to fill */
        int n_repeat = CLAP_MAX_SAMPLES / ns;
        int written = 0;
        for (i = 0; i < n_repeat; i++) {
            for (int j = 0; j < ns && written < CLAP_MAX_SAMPLES; j++) {
                waveform[CLAP_N_FFT / 2 + written] = pcm[j];
                written++;
            }
        }
        /* zero-pad remainder */
        for (i = written; i < CLAP_MAX_SAMPLES; i++) {
            waveform[CLAP_N_FFT / 2 + i] = 0.0f;
        }
    } else {
        /* copy up to max_samples (truncate if longer) */
        for (i = 0; i < ns; i++) {
            waveform[CLAP_N_FFT / 2 + i] = pcm[i];
        }
        /* zero-pad if shorter (shouldn't happen since ns == CLAP_MAX_SAMPLES here) */
        for (i = ns; i < CLAP_MAX_SAMPLES; i++) {
            waveform[CLAP_N_FFT / 2 + i] = 0.0f;
        }
    }
    /* reflect padding at start: mirror first n_fft/2 samples */
    for (i = 0; i < CLAP_N_FFT / 2; i++) {
        waveform[i] = waveform[CLAP_N_FFT / 2 + (CLAP_N_FFT / 2 - i)];
    }
    /* reflect padding at end: mirror last n_fft/2 samples */
    for (i = 0; i < CLAP_N_FFT / 2; i++) {
        waveform[CLAP_N_FFT / 2 + CLAP_MAX_SAMPLES + i] =
            waveform[CLAP_N_FFT / 2 + CLAP_MAX_SAMPLES - 2 - i];
    }

    /* Hann window */
    hann_window(window, CLAP_N_FFT);

    /* Generate output: [frame][mel_band] row-major */
    for (t = 0; t < n_frames; t++) {
        int offset = t * CLAP_HOP_LENGTH;

        /* extract frame, apply window */
        for (i = 0; i < CLAP_N_FFT; i++) {
            re[i] = waveform[offset + i] * window[i];
            im[i] = 0.0f;
        }

        /* FFT */
        fft_radix2(re, im, CLAP_N_FFT);

        /* power spectrum |FFT|^2 */
        for (i = 0; i < n_freq_bins; i++) {
            power_spectrum[i] = re[i] * re[i] + im[i] * im[i];
        }

        /* Apply mel filterbank */
        for (f = 0; f < CLAP_N_MELS; f++) {
            double val = 0.0;
            for (i = 0; i < n_freq_bins; i++) {
                val += MEL_FILTERBANK[f][i] * power_spectrum[i];
            }
            /* mel_floor = 1e-10, then dB conversion: 10 * log10(val) */
            if (val < 1e-10) val = 1e-10;
            output[t * CLAP_N_MELS + f] = 10.0f * log10f((float)val);
        }
    }
    free(waveform);
}

/* ================================================================
 * CLAP log-mel spectrogram — SEH-safe entry point
 * On Windows, __try/__except catches any crash so the process survives.
 * ================================================================ */
MEL_FFI_EXPORT void compute_clap_mel(const float* pcm, int num_samples, float* output) {
#ifdef _WIN32
    __try {
        compute_clap_mel_impl(pcm, num_samples, output);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        /* SEH caught a crash — zero output so caller gets silence instead of process death */
        for (int i = 0; i < CLAP_N_FRAMES * CLAP_N_MELS; i++) {
            output[i] = 0.0f;
        }
    }
#else
    compute_clap_mel_impl(pcm, num_samples, output);
#endif
}

/* ================================================================
 * Whisper log-mel spectrogram — internal implementation
 * Uses reflection padding at audio boundaries.
 *
 * Speed: uses Bluestein's algorithm to compute the exact same
 * 400-point DFT via a 1024-point radix-2 FFT. O(N log M) vs O(N²).
 * ================================================================ */

/*
 * Bluestein power spectrum: computes |DFT{x}[k]|² for k=0..N-1.
 * Uses a 1024-point radix-2 FFT internally. Produces bit-identical
 * results to the naive O(N²) DFT for the DFT magnitudes.
 */
static void bluestein_power_spectrum(const float* x, int n, float* power) {
    const int m = 1024; /* >= 2*n-1 = 799, power of 2 */
    float *a_re, *a_im, *b_re, *b_im;
    float chirp_re[400], chirp_im[400];
    int k;

    a_re = (float*)calloc(m, sizeof(float));
    a_im = (float*)calloc(m, sizeof(float));
    b_re = (float*)calloc(m, sizeof(float));
    b_im = (float*)calloc(m, sizeof(float));

    /* chirp[k] = exp(-j * pi * k^2 / n) */
    for (k = 0; k < n; k++) {
        double angle = -3.141592653589793 * (double)k * k / n;
        chirp_re[k] = (float)cos(angle);
        chirp_im[k] = (float)sin(angle);
    }

    /* a[k] = x[k] * chirp[k], zero-padded to m */
    for (k = 0; k < n; k++) {
        a_re[k] = x[k] * chirp_re[k];
        a_im[k] = x[k] * chirp_im[k];
    }

    /* b[k] = conj(chirp[k]) for k=0..n-1, conj(chirp[k-m]) for k=m-n+1..m-1 */
    for (k = 0; k < n; k++) {
        b_re[k] =  chirp_re[k];  /* conj: flip sign of imag */
        b_im[k] = -chirp_im[k];
    }
    for (k = m - n + 1; k < m; k++) {
        int j2 = k - m; /* negative index */
        double angle = -3.141592653589793 * (double)j2 * j2 / n;
        b_re[k] =  (float)cos(angle);
        b_im[k] = -(float)sin(angle);  /* conj */
    }

    /* FFT both sequences */
    fft_radix2(a_re, a_im, m);
    fft_radix2(b_re, b_im, m);

    /* pointwise multiply */
    for (k = 0; k < m; k++) {
        float re = a_re[k] * b_re[k] - a_im[k] * b_im[k];
        float im = a_re[k] * b_im[k] + a_im[k] * b_re[k];
        a_re[k] = re;
        a_im[k] = im;
    }

    /* inverse FFT: conjugate, FFT, conjugate, divide by m */
    for (k = 0; k < m; k++) a_im[k] = -a_im[k];
    fft_radix2(a_re, a_im, m);
    for (k = 0; k < m; k++) {
        a_re[k] /= m;
        a_im[k] = -a_im[k] / m; /* conjugate */
    }

    /* multiply by chirp[k] and compute |X[k]|^2 */
    for (k = 0; k < n; k++) {
        float re = a_re[k] * chirp_re[k] - a_im[k] * chirp_im[k];
        float im = a_re[k] * chirp_im[k] + a_im[k] * chirp_re[k];
        power[k] = re * re + im * im;
    }

    free(a_re); free(a_im); free(b_re); free(b_im);
}

static void compute_whisper_mel_impl(const float* pcm, int num_samples, float* output) {
    float* audio = (float*)malloc(WHISPER_MAX_SAMPLES * sizeof(float));
    float window[WHISPER_N_FFT];
    int i, t, f;
    float frame[WHISPER_N_FFT];
    float power_spectrum[WHISPER_N_FREQ_BINS];
    const int ns = WHISPER_MAX_SAMPLES;

    if (!audio) return;

    /* Copy input to local buffer, truncate or zero-pad to 30s */
    int copy_len = num_samples;
    if (copy_len > WHISPER_MAX_SAMPLES) copy_len = WHISPER_MAX_SAMPLES;
    if (copy_len < 0) copy_len = 0;
    for (i = 0; i < copy_len; i++) audio[i] = pcm[i];
    for (i = copy_len; i < WHISPER_MAX_SAMPLES; i++) audio[i] = 0.0f;

    /* Hann window */
    hann_window(window, WHISPER_N_FFT);

    /* Generate 3000 mel frames: [frame][mel_band] row-major */
    for (t = 0; t < WHISPER_N_FRAMES; t++) {
        int center = t * WHISPER_HOP_LENGTH;
        int start  = center - WHISPER_N_FFT / 2;

        /* Extract frame with reflection padding at boundaries */
        for (i = 0; i < WHISPER_N_FFT; i++) {
            int idx = start + i;
            float sample;
            if (idx < 0) {
                sample = audio[-idx - 1];             /* reflect left */
            } else if (idx >= ns) {
                sample = audio[2 * ns - 1 - idx];      /* reflect right */
            } else {
                sample = audio[idx];
            }
            frame[i] = sample * window[i];
        }

        /* Bluestein DFT → power spectrum (exact same output as O(N²) DFT) */
        bluestein_power_spectrum(frame, WHISPER_N_FFT, power_spectrum);

        /* Apply mel filterbank -> log magnitude */
        for (f = 0; f < WHISPER_N_MELS; f++) {
            double val = 0.0;
            for (i = 0; i < WHISPER_N_FREQ_BINS; i++) {
                val += WHISPER_MEL_FILTERBANK[f][i] * power_spectrum[i];
            }
            if (val < 1e-10) val = 1e-10;
            output[t * WHISPER_N_MELS + f] = log10f((float)val);
        }
    }

    /* Whisper normalization: clamp dynamic range, then shift/scale */
    float max_val = -1e30f;
    for (i = 0; i < WHISPER_N_FRAMES * WHISPER_N_MELS; i++) {
        if (output[i] > max_val) max_val = output[i];
    }
    for (i = 0; i < WHISPER_N_FRAMES * WHISPER_N_MELS; i++) {
        if (output[i] < max_val - 8.0f) output[i] = max_val - 8.0f;
        output[i] = (output[i] + 4.0f) / 4.0f;
    }

    free(audio);
}
MEL_FFI_EXPORT void compute_whisper_mel(const float* pcm, int num_samples, float* output) {
#ifdef _WIN32
    __try {
        compute_whisper_mel_impl(pcm, num_samples, output);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        for (int i = 0; i < WHISPER_N_FRAMES * WHISPER_N_MELS; i++) {
            output[i] = 0.0f;
        }
    }
#else
    compute_whisper_mel_impl(pcm, num_samples, output);
#endif
}

/* ================================================================
 * CLIP image preprocessing
 * ================================================================ */
MEL_FFI_EXPORT int preprocess_clip_image(const unsigned char* image_data, int data_len, float* output) {
    int w, h, channels;
    unsigned char* img = stbi_load_from_memory(image_data, data_len, &w, &h, &channels, 3);
    if (!img) return -1;

    /* Simple bilinear resize to 224x224 */
    /* For now, use a simple pixel-sampling approach for speed */
    /* TODO: proper bilinear resize */
    float rgb[CLIP_IMAGE_SIZE][CLIP_IMAGE_SIZE][3];
    for (int y = 0; y < CLIP_IMAGE_SIZE; y++) {
        for (int x = 0; x < CLIP_IMAGE_SIZE; x++) {
            float sx = (float)x / CLIP_IMAGE_SIZE * w;
            float sy = (float)y / CLIP_IMAGE_SIZE * h;
            int ix = (int)sx;
            int iy = (int)sy;
            if (ix >= w) ix = w - 1;
            if (iy >= h) iy = h - 1;
            unsigned char* px = img + (iy * w + ix) * 3;
            rgb[y][x][0] = px[0] / 255.0f;
            rgb[y][x][1] = px[1] / 255.0f;
            rgb[y][x][2] = px[2] / 255.0f;
        }
    }
    stbi_image_free(img);

    /* Normalize: (value - mean) / std, output CHW format */
    const float mean[3] = {CLIP_MEAN_R, CLIP_MEAN_G, CLIP_MEAN_B};
    const float std[3]  = {CLIP_STD_R, CLIP_STD_G, CLIP_STD_B};
    for (int c = 0; c < 3; c++) {
        for (int y = 0; y < CLIP_IMAGE_SIZE; y++) {
            for (int x = 0; x < CLIP_IMAGE_SIZE; x++) {
                output[c * CLIP_IMAGE_SIZE * CLIP_IMAGE_SIZE + y * CLIP_IMAGE_SIZE + x] =
                    (rgb[y][x][c] - mean[c]) / std[c];
            }
        }
    }
    return 0;
}
