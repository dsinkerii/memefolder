#include "mel_ffi.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

int main() {
    /* Load the test PCM file */
    FILE* f = fopen("/tmp/onnx_models/clap_audio_pcm.f32", "rb");
    if (!f) {
        printf("ERROR: could not open PCM file\n");
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    int n = sz / sizeof(float);
    float* pcm = (float*)malloc(sz);
    fread(pcm, sizeof(float), n, f);
    fclose(f);
    printf("Loaded %d PCM samples\n", n);

    /* Compute mel spectrogram */
    float output[CLAP_N_FRAMES * CLAP_N_MELS];
    compute_clap_mel(pcm, n, output);

    printf("Output shape: %d frames x %d mel bands\n", CLAP_N_FRAMES, CLAP_N_MELS);

    /* Print first 5x5 */
    printf("First 5x5:\n");
    for (int t = 0; t < 5; t++) {
        for (int f = 0; f < 5; f++) {
            printf("%8.4f ", output[t * CLAP_N_MELS + f]);
        }
        printf("\n");
    }

    /* Compare with Python reference */
    float ref[CLAP_N_FRAMES * CLAP_N_MELS];
    FILE* rf = fopen("/tmp/clap_mel_ref.f32", "rb");
    if (rf) {
        fread(ref, sizeof(float), CLAP_N_FRAMES * CLAP_N_MELS, rf);
        fclose(rf);

        /* Compute max error */
        float max_err = 0.0f;
        float sum_sq = 0.0f;
        for (int i = 0; i < CLAP_N_FRAMES * CLAP_N_MELS; i++) {
            float err = fabsf(output[i] - ref[i]);
            if (err > max_err) max_err = err;
            sum_sq += err * err;
        }
        float rmse = sqrtf(sum_sq / (CLAP_N_FRAMES * CLAP_N_MELS));
        printf("\nComparison vs Python reference:\n");
        printf("  Max error: %.6f\n", max_err);
        printf("  RMSE:      %.6f\n", rmse);

        /* Print side-by-side for first 5x5 */
        printf("\nFirst 5x5 (C output // Reference):\n");
        for (int t = 0; t < 5; t++) {
            for (int f = 0; f < 5; f++) {
                printf("%8.4f/%-8.4f ", output[t * CLAP_N_MELS + f], ref[t * CLAP_N_MELS + f]);
            }
            printf("\n");
        }
    } else {
        printf("\nReference file not found, skipping comparison\n");
    }

    /* Print stats */
    float min_v = 1e10, max_v = -1e10, sum = 0;
    for (int i = 0; i < CLAP_N_FRAMES * CLAP_N_MELS; i++) {
        if (output[i] < min_v) min_v = output[i];
        if (output[i] > max_v) max_v = output[i];
        sum += output[i];
    }
    printf("\nStats: min=%.4f max=%.4f mean=%.4f\n",
           min_v, max_v, sum / (CLAP_N_FRAMES * CLAP_N_MELS));

    free(pcm);
    return 0;
}
