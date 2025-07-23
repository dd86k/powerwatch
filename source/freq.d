module freq;

import std.complex : Complex;
import core.math : sqrt;
import std.math.constants : PI;
import std.math.trigonometry : cos, sin, atan2;

// 50 or 60 ±0.5 Hz

// Inspiration: https://halcy.de/blog/2025/02/09/measuring-power-network-frequency-using-junk-you-have-in-your-closet/
// https://gist.github.com/halcy/7fb41ae9457f25eb5d67fa0d2ee57aaf
/* Frequency estimation

# Do a Hann windowed FFT
hann_window = np.hanning(fft_window_size)
windowed = window_samples * hann_window
fft_complex = np.fft.rfft(windowed)

# Slice the magnitude spectrogram to the range we care about
freqs = np.fft.rfftfreq(fft_window_size, 1.0 / sample_rate)
idx_min = np.searchsorted(freqs, FREQ_MIN)
idx_max = np.searchsorted(freqs, FREQ_MAX)
sub_mags = np.abs(fft_complex[idx_min:idx_max])
sub_freqs = freqs[idx_min:idx_max]

# Find the peak
n = np.argmax(sub_mags)

# Quadratic interpolation to refine the peak location
frac_offset = 0.0
if not (n < 1 or n >= len(sub_mags) - 1):
    alpha = sub_mags[n - 1]
    beta  = sub_mags[n]
    gamma = sub_mags[n + 1]
    denom = alpha - 2*beta + gamma
if abs(denom) > 1e-12:
    frac_offset = 0.5 * (alpha - gamma) / denom
n_interp = n + frac_offset

# Compute which frequency this corresponds to
lower_idx = int(np.floor(n_interp))
upper_idx = int(np.ceil(n_interp))
frac = n_interp - lower_idx
if upper_idx >= len(sub_freqs):
    upper_idx = len(sub_freqs) - 1
est_freq = (1 - frac) * sub_freqs[lower_idx] + frac * sub_freqs[upper_idx]
*/

//void find_peak_frequency(double *fft_real, double *fft_imag, int n, uint32_t sample_rate)

/// Calculate the magnitude of a given bin.
/// Params: bin = Selected bin.
/// Returns: Magnitude
F magnitude(F = double)(Complex!F bin)
{
    return sqrt(bin.re * bin.re + bin.im * bin.im);
}

/// Calculate the current phase of a given frequency bin.
/// Params: bin = Selected bin.
/// Returns: Phase
F phase(F = float)(Complex!F bin)
{
    return atan2(bin.im, bin.re); // arctangent
}

// Compute the DFT for the specific frequency bin k
Complex!F dftfreq(F = double, R)(R range, int rate, int target)
{
    enum PI2 = PI * 2;
    
    int N = cast(int)range.length;
    int k = cast(int)(cast(F)target / rate * N); // Calculate the bin index for frequency f0
    Complex!F c = void;
    c.re = 0.0;
    c.im = 0.0;

    for (int n = 0; n < N; n++)
    {
        F angle = PI2 * k * n / N;
        c.re += range[n] * cos(angle);
        c.im -= range[n] * sin(angle);
    }
    
    return c;
}

struct ResultFrame
{
    float t0; // seconds
    float t1; // seconds
    float magnitude;
    float phase;
}
struct Result
{
    ResultFrame[] frames;
}
Result analyzedft(short[] samples, int rate, size_t binsize = 16384, int target = 60)
{
    // 1. slices of n samples
    // 2. dft on that thing
    // 3. get magnitude closest to 60 Hz (or 50 Hz as an option)
    // 4. check magnitude against a threshold
    
    import std.range : chunks;

    float r = cast(float)binsize/rate; // time rate
    float t = 0; // total time
    Result results;
    // NOTE: pelp3; suggested me to use 1/256 samples (use 1, skip 255) for downsampling
    foreach (s; samples.chunks(binsize))
    {
        // 1. class Fft only takes base-2 slices
        // 2. not enough data and cutoff would seem weird
        if (s.length != binsize)
            break;
        Complex!float bin = dftfreq!float(s, rate, target);
        // 0-10000 : usually dead, >=1.0e07 (or at least 68595400.0): usually alive
        results.frames ~= ResultFrame(t, t += r, magnitude!float(bin), phase!float(bin));
    }
    return results;
}
Result analyzefft(short[] samples, int rate, size_t binsize = 16384, int target = 60)
{
    // 1. slices of n samples
    // 2. fft on that thing
    // 3. get magnitude closest to 60 Hz (or 50 Hz as an option)
    // 4. check magnitude against a threshold

    import std.numeric : Fft;
    import std.range : chunks;
    // 16384 good enough looking in Audacity spectrum analyzer
    // 44100/16384=~2.69165 Hz slices
    //size_t binidx = floor( (target * FFTSIZE) / fmtchunk.samplerate );
    size_t binidx = (target * binsize) / rate;
    scope Fft f = new Fft(binsize);
    float r = cast(float)binsize/rate; // time rate
    float t = 0; // total time
    Result results;
    // NOTE: pelp3; suggested me to use 1/256 samples (use 1, skip 255) for downsampling
    foreach (s; samples.chunks(binsize))
    {
        // 1. class Fft only takes base-2 slices
        // 2. not enough data and cutoff would seem weird
        if (s.length != binsize)
            break;
        Complex!float[] bins = f.fft!float(s);
        Complex!float bin = bins[binidx];
        // 0-10000 : usually dead, >=1.0e07 (or at least 68595400.0): usually alive
        results.frames ~= ResultFrame(t, t += r, magnitude!float(bin), phase!float(bin));
    }
    return results;
}

import std.numeric : Fft, fft;
/*
The frequencies are all relative to the FFT window.
res[0] is 0 Hz, res[1] corresponds to a sine wave that fits 1 cycle inside your window,
res[2] is 2 cycles etc. The frequency in Hz depends on your sample rate. If it's 44100,
44100 / 4096 = ~10 so your window fits 10 times in 1 second. That means res[1] is
around 10 hz, res[2] 20 hz etc. up to res[4095] which is 40950 hz. Although everything
from res[2048] onwards is just a mirrored copy since 44100 samples/s can only capture
frequencies up to 22 Khz (for more info search 'Nyquist frequency' and 'aliasing').

The closest bucket to 1209Hz is 1209 * (4096 / 44100) = 112.3, which is not an exact
match so it will leak frequencies in all other bins, but it will still mostly contribute
to bins 112 and 113 so it's probably good enough to just check those. If you need better
frequency resolution you can try applying a 'window function' to reduce spectral leakage
or increasing the window size either by including more samples reducing the time resolution,
or by padding the window with 0's which will essentially adds interpolated bins.
*/
class FreqAnalyzer
{
    this(size_t binsize = _32K)
    {
        this.binsize = binsize;
        o = new Fft(binsize);
    }
    
    static
    F blackman_window(F = double)(int n, int N)
    {
        return 0.42 - 0.5 * cos(2 * PI * n / (N - 1)) + 0.08 * cos(4 * PI * n / (N - 1));
    }
    
    ResultFrame analyze(short[] samples, int rate, int target = 60)
    {
        // Apply Blackman window
        int N = cast(int)samples.length;
        for (int i; i < N; i++)
        {
            float f = cast(float)samples[i] / 32767;
            samples[i] = cast(short)(f * blackman_window!float(i, N) * 32767);
        }
        
        // Get bin
        size_t binidx = target * binsize / rate;
        Complex!float[] bins = o.fft!float(samples); // base-2 sizes only
        if (binidx >= bins.length)
            throw new Exception("Frequency out of range");
        Complex!float bin = bins[binidx];
        
        return ResultFrame(0, 0, magnitude!float(bin), phase!float(bin));
    }
    
private:
    enum _64K = 1 << 16;
    enum _32K = 1 << 15;
    enum _16K = 1 << 14;
    enum _8K  = 1 << 13;
    enum _4K  = 1 << 12;
    
    size_t binsize;
    Fft o;
}
